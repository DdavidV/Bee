//! The bridge to Bee: the frames that go to its stdin and come from its
//! stdout, and what's waiting for its answers.
//!
//! - A window's requests become `req` frames; Bee's `res` frames answer them.
//! - LiveView's socket frames (`open`, `msg`, `close`) come from the page
//!   through the `bridge_*` commands (src/commands.rs) and go back over a
//!   Channel (`opened`, `msg`, `closed`).

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Mutex};
use std::time::Duration;

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde_json::{json, Value};
use tauri::http;
use tauri::ipc::Channel;

use crate::frame;

/// How long a request waits for Bee's answer, unless told (`timeout/1`).
const TIMEOUT: Duration = Duration::from_secs(120);

pub struct Bridge {
    /// Bee's stdin; None once closed.
    to_bee: Mutex<Option<Box<dyn Write + Send>>>,
    next_id: AtomicU64,
    /// How long a request waits for Bee's answer.
    timeout: Duration,
    /// HTTP requests waiting for their `res` frame, by id.
    pending: Mutex<HashMap<u64, mpsc::Sender<Value>>>,
    /// LiveView sockets: where their frames go and their window, by sid.
    sockets: Mutex<HashMap<String, (Channel<Value>, String)>>,
}

impl Bridge {
    /// A bridge that writes its frames to `to_bee`, Bee's stdin.
    pub fn new(to_bee: impl Write + Send + 'static) -> Self {
        Bridge {
            to_bee: Mutex::new(Some(Box::new(to_bee))),
            next_id: AtomicU64::new(1),
            timeout: TIMEOUT,
            pending: Mutex::new(HashMap::new()),
            sockets: Mutex::new(HashMap::new()),
        }
    }

    /// The bridge, its requests waiting `timeout` for Bee's answer.
    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    fn send(&self, frame: &Value) {
        if let Some(to_bee) = self.to_bee.lock().unwrap().as_mut() {
            if let Err(e) = frame::write(to_bee, frame) {
                eprintln!("bee: can't write to Bee: {e}");
            }
        }
    }

    /// Reads Bee's frames from `from`, its stdout, until it ends (blocks).
    pub fn read_frames(&self, mut from: impl Read) {
        while let Ok(body) = frame::read(&mut from) {
            match serde_json::from_slice(&body) {
                Ok(frame) => self.dispatch(frame),
                Err(e) => eprintln!("bee: a frame from Bee isn't JSON: {e}"),
            }
        }
    }

    /// A frame from Bee: an HTTP answer, or one for a socket.
    fn dispatch(&self, frame: Value) {
        match frame["t"].as_str() {
            Some("res") => {
                let id = frame["id"].as_u64().unwrap_or(0);
                if let Some(tx) = self.pending.lock().unwrap().remove(&id) {
                    let _ = tx.send(frame);
                }
            }
            Some(t @ ("opened" | "msg" | "closed")) => {
                let sid = frame["sid"].as_str().unwrap_or_default().to_string();
                let mut sockets = self.sockets.lock().unwrap();

                if let Some((channel, _win)) = sockets.get(&sid) {
                    let _ = channel.send(frame.clone());
                }
                if t == "closed" {
                    sockets.remove(&sid);
                }
            }
            _ => eprintln!("bee: unknown frame from Bee: {frame}"),
        }
    }

    /// One HTTP request of window `win`, answered by Bee (blocks).
    pub fn request(&self, win: &str, request: http::Request<Vec<u8>>) -> http::Response<Vec<u8>> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = mpsc::channel();
        self.pending.lock().unwrap().insert(id, tx);

        self.send(&request_frame(id, win, &request));

        match rx.recv_timeout(self.timeout) {
            Ok(res) => response(&res),
            Err(_) => {
                self.pending.lock().unwrap().remove(&id);
                plain(504, "Bee didn't answer")
            }
        }
    }

    /// A page of window `win` opens socket `sid` to `url`; Bee's frames for
    /// it go to `channel`.
    pub fn open_socket(&self, sid: String, win: String, url: &str, channel: Channel<Value>) {
        self.sockets
            .lock()
            .unwrap()
            .insert(sid.clone(), (channel, win.clone()));
        self.send(&json!({"t": "open", "sid": sid, "win": win, "url": url}));
    }

    /// A page's frame on its socket `sid`.
    pub fn send_socket(&self, sid: &str, data: &str, bin: bool) {
        self.send(&json!({"t": "msg", "sid": sid, "data": data, "bin": bin}));
    }

    /// A page closes its socket `sid`.
    pub fn close_socket(&self, sid: &str) {
        self.sockets.lock().unwrap().remove(sid);
        self.send(&json!({"t": "close", "sid": sid}));
    }

    /// Window `win` closed: its sockets close, so Bee lets go of its folder.
    pub fn window_closed(&self, win: &str) {
        let sids: Vec<String> = {
            let mut sockets = self.sockets.lock().unwrap();
            let sids: Vec<String> = sockets
                .iter()
                .filter(|(_, (_, w))| w == win)
                .map(|(sid, _)| sid.clone())
                .collect();
            for sid in &sids {
                sockets.remove(sid);
            }
            sids
        };

        for sid in sids {
            self.send(&json!({"t": "close", "sid": sid}));
        }
    }

    /// Closes Bee's stdin: Bee stops.
    pub fn close(&self) {
        self.to_bee.lock().unwrap().take();
    }
}

/// The `req` frame of `request`, a request of window `win`.
fn request_frame(id: u64, win: &str, request: &http::Request<Vec<u8>>) -> Value {
    let headers: Vec<[String; 2]> = request
        .headers()
        .iter()
        .map(|(k, v)| [k.to_string(), v.to_str().unwrap_or_default().to_string()])
        .collect();

    json!({
        "t": "req",
        "id": id,
        "win": win,
        "method": request.method().as_str(),
        "url": request.uri().to_string(),
        "headers": headers,
        "body": B64.encode(request.body()),
    })
}

/// The response a `res` frame holds.
fn response(res: &Value) -> http::Response<Vec<u8>> {
    let status = res["status"].as_u64().unwrap_or(500) as u16;
    let mut builder = http::Response::builder().status(status);

    for pair in res["headers"].as_array().into_iter().flatten() {
        if let (Some(k), Some(v)) = (pair[0].as_str(), pair[1].as_str()) {
            builder = builder.header(k, v);
        }
    }

    let body = B64
        .decode(res["body"].as_str().unwrap_or_default())
        .unwrap_or_default();
    builder
        .body(body)
        .unwrap_or_else(|_| plain(502, "bad response from Bee"))
}

fn plain(status: u16, text: &str) -> http::Response<Vec<u8>> {
    http::Response::builder()
        .status(status)
        .header("content-type", "text/plain")
        .body(text.as_bytes().to_vec())
        .unwrap()
}
