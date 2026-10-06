//! Bee's desktop shell: windows showing Bee, which runs as a child process
//! in desktop mode (`BEE_MODE=desktop`). The two only talk over Bee's
//! stdin/stdout – no port is opened on either side.
//!
//! One Bee serves every window, one window per folder (`?folder=…`), like
//! VS Code. A window opens for the folder given at launch; Bee asks for more
//! (Open Folder in New Window, `bridge_open_window`); and launching the app
//! again hands its folder to the running one (single instance), which
//! focuses the window showing it or opens one. The app quits with its last
//! window.
//!
//! - The window's requests (`bee://localhost/…`, `http://bee.localhost/…` on
//!   Windows) become `req` frames; Bee's `res` frames answer them.
//! - LiveView's socket frames come from the page through the `bridge_*`
//!   commands (window.__bridge, src/bridge.js) and go back over a Channel.
//!
//! Frames are a 4-byte big-endian length followed by JSON; see
//! `Desktop.Bridge` in Bee for the protocol.
//!
//! Which Bee (`bee_release/0`): `BEE_RELEASE=/path/to/bin/bee` if set; else
//! a release build of this app starts the checkout's release
//! (`mix bee.release.desktop`), a development build (`cargo run`) the
//! checkout itself, through mix. The folder to open is the first argument
//! (default: the current directory).
//! With `--features selftest` the first window drives itself (src/selftest.rs).

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;
use std::{env, thread};

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde_json::{json, Value};
use tauri::ipc::Channel;
use tauri::{
    http, AppHandle, Manager, RunEvent, Url, WebviewUrl, WebviewWindowBuilder, WindowEvent,
};

const BRIDGE_JS: &str = include_str!("bridge.js");

#[cfg(feature = "selftest")]
mod selftest;

/// Bee, the child process, and what's waiting for its answers.
struct Bee {
    stdin: Mutex<Option<ChildStdin>>,
    child: Mutex<Child>,
    next_id: AtomicU64,
    /// HTTP requests waiting for their `res` frame, by id.
    pending: Mutex<HashMap<u64, mpsc::Sender<Value>>>,
    /// LiveView sockets: where their frames go and their window, by sid.
    sockets: Mutex<HashMap<String, (Channel<Value>, String)>>,
}

impl Bee {
    fn send(&self, frame: &Value) {
        let body = serde_json::to_vec(frame).expect("a frame is JSON");
        if let Some(stdin) = self.stdin.lock().unwrap().as_mut() {
            let result = stdin
                .write_all(&(body.len() as u32).to_be_bytes())
                .and_then(|_| stdin.write_all(&body))
                .and_then(|_| stdin.flush());

            if let Err(e) = result {
                eprintln!("bee: can't write to Bee: {e}");
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
    fn request(&self, win: &str, request: http::Request<Vec<u8>>) -> http::Response<Vec<u8>> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = mpsc::channel();
        self.pending.lock().unwrap().insert(id, tx);

        let headers: Vec<[String; 2]> = request
            .headers()
            .iter()
            .map(|(k, v)| [k.to_string(), v.to_str().unwrap_or_default().to_string()])
            .collect();

        self.send(&json!({
            "t": "req",
            "id": id,
            "win": win,
            "method": request.method().as_str(),
            "url": request.uri().to_string(),
            "headers": headers,
            "body": B64.encode(request.body()),
        }));

        match rx.recv_timeout(Duration::from_secs(120)) {
            Ok(res) => response(&res),
            Err(_) => {
                self.pending.lock().unwrap().remove(&id);
                plain(504, "Bee didn't answer")
            }
        }
    }

    /// Window `win` closed: its sockets close, so Bee lets go of its folder.
    fn window_closed(&self, win: &str) {
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

    /// Closes Bee's stdin: Bee stops. Kills it if it hasn't after a while.
    fn stop(&self) {
        self.stdin.lock().unwrap().take();
        let mut child = self.child.lock().unwrap();

        for _ in 0..50 {
            if let Ok(Some(_)) = child.try_wait() {
                return;
            }
            thread::sleep(Duration::from_millis(100));
        }
        let _ = child.kill();
    }
}

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

// LiveView's socket (window.__bridge, src/bridge.js).

#[tauri::command]
fn bridge_open(
    webview: tauri::Webview,
    bee: tauri::State<'_, Arc<Bee>>,
    sid: String,
    url: String,
    channel: Channel<Value>,
) {
    let win = webview.label().to_string();
    bee.sockets
        .lock()
        .unwrap()
        .insert(sid.clone(), (channel, win.clone()));
    bee.send(&json!({"t": "open", "sid": sid, "win": win, "url": url}));
}

#[tauri::command]
fn bridge_send(bee: tauri::State<'_, Arc<Bee>>, sid: String, data: String, bin: bool) {
    bee.send(&json!({"t": "msg", "sid": sid, "data": data, "bin": bin}));
}

#[tauri::command]
fn bridge_close(bee: tauri::State<'_, Arc<Bee>>, sid: String) {
    bee.sockets.lock().unwrap().remove(&sid);
    bee.send(&json!({"t": "close", "sid": sid}));
}

// Windows.

/// Bee asks for a window: `url` is a page of Bee, `/?folder=…`.
#[tauri::command]
fn bridge_open_window(app: AppHandle, url: String) -> Result<(), String> {
    let url = page_url(&url).ok_or_else(|| format!("not a page of Bee: {url}"))?;
    let folder = url_folder(&url).ok_or_else(|| format!("no folder in {url}"))?;
    open_window(&app, &folder).map_err(|e| e.to_string())
}

/// The page's title changed (another folder): so does the window's.
#[tauri::command]
fn bridge_title(window: tauri::WebviewWindow, title: String) {
    let _ = window.set_title(&title);
}

/// `path` (`/…`) on Bee's protocol.
fn page_url(path: &str) -> Option<Url> {
    if !path.starts_with('/') || path.starts_with("//") {
        return None;
    }
    Url::parse("bee://localhost/").ok()?.join(path).ok()
}

fn url_folder(url: &Url) -> Option<PathBuf> {
    url.query_pairs()
        .find(|(k, _)| k == "folder")
        .map(|(_, v)| PathBuf::from(v.as_ref()))
}

/// Focuses the window showing `folder`, or opens one for it.
fn open_window(app: &AppHandle, folder: &Path) -> tauri::Result<()> {
    let existing = app.webview_windows().into_values().find(|w| {
        w.url()
            .ok()
            .and_then(|u| url_folder(&u))
            .is_some_and(|f| f == folder)
    });

    if let Some(window) = existing {
        let _ = window.unminimize();
        return window.set_focus();
    }

    static NEXT: AtomicUsize = AtomicUsize::new(1);
    let n = NEXT.fetch_add(1, Ordering::Relaxed);

    let mut url = Url::parse("bee://localhost/").unwrap();
    url.query_pairs_mut()
        .append_pair("folder", &folder.to_string_lossy());

    let name = folder
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();

    let window = WebviewWindowBuilder::new(app, format!("w{n}"), WebviewUrl::CustomProtocol(url))
        .title(format!("{name} — Bee"))
        .inner_size(1280.0, 800.0)
        .initialization_script(BRIDGE_JS);

    // The first window tests itself.
    #[cfg(feature = "selftest")]
    let window = if n == 1 {
        window.initialization_script(selftest::SCRIPT)
    } else {
        window
    };

    window.build()?;
    Ok(())
}

/// The folder of a launch: its first argument that isn't a flag, relative
/// to `cwd`; `cwd` itself without one.
fn folder_arg(args: &[String], cwd: &Path) -> PathBuf {
    let path = args
        .iter()
        .skip(1)
        .find(|a| !a.starts_with('-'))
        .map(|a| cwd.join(a))
        .unwrap_or_else(|| cwd.to_path_buf());
    path.canonicalize().unwrap_or(path)
}

/// The Bee release to start, or None to run the checkout through mix
/// (development builds). Until the app bundles its release (packaging), a
/// release build uses the one `mix bee.release.desktop` built next to it.
fn bee_release(repo: &Path) -> Option<PathBuf> {
    if let Ok(path) = env::var("BEE_RELEASE") {
        return Some(PathBuf::from(path));
    }
    if cfg!(debug_assertions) {
        return None;
    }

    let script = if cfg!(windows) { "bee.bat" } else { "bee" };
    Some(repo.join("_build/prod/rel/bee/bin").join(script))
}

/// Starts Bee in desktop mode for `folder`, its stdin/stdout piped to us.
fn start_bee(folder: &Path) -> std::io::Result<Child> {
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();

    let mut command = match bee_release(repo) {
        Some(release) if !release.exists() => {
            return Err(std::io::Error::other(format!(
                "no Bee release at {} (build it with `mix bee.release.desktop`)",
                release.display()
            )));
        }
        Some(release) => {
            let mut c = Command::new(release);
            c.arg("start");
            c
        }
        None => {
            // Development: the checkout, compiled first (a stale build would
            // start without the bridge).
            let status = Command::new("mix")
                .arg("compile")
                .current_dir(repo)
                .stdout(Stdio::from(std::io::stderr()))
                .status()?;
            if !status.success() {
                return Err(std::io::Error::other("mix compile failed"));
            }

            let mut c = Command::new("elixir");
            c.args([
                "--erl",
                "-noinput",
                "-S",
                "mix",
                "run",
                "--no-halt",
                "--no-compile",
            ])
            .current_dir(repo);
            c
        }
    };

    command
        .env("BEE_MODE", "desktop")
        .env("BEE_ROOT", folder)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
}

/// Reads Bee's frames until it stops; then the app quits.
fn read_frames(mut stdout: impl Read + Send + 'static, bee: Arc<Bee>, app: AppHandle) {
    thread::spawn(move || {
        let mut len = [0u8; 4];

        while stdout.read_exact(&mut len).is_ok() {
            let mut body = vec![0u8; u32::from_be_bytes(len) as usize];
            if stdout.read_exact(&mut body).is_err() {
                break;
            }

            match serde_json::from_slice(&body) {
                Ok(frame) => bee.dispatch(frame),
                Err(e) => eprintln!("bee: a frame from Bee isn't JSON: {e}"),
            }
        }

        eprintln!("bee: Bee stopped");
        app.exit(0);
    });
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let folder = folder_arg(&args, &env::current_dir().unwrap());

    // Launched again: the running app opens the folder, this one exits.
    let builder =
        tauri::Builder::default().plugin(tauri_plugin_single_instance::init(|app, args, cwd| {
            let folder = folder_arg(&args, Path::new(&cwd));
            if let Err(e) = open_window(app, &folder) {
                eprintln!("bee: can't open a window for {}: {e}", folder.display());
            }
        }));

    #[cfg(not(feature = "selftest"))]
    let builder = builder.invoke_handler(tauri::generate_handler![
        bridge_open,
        bridge_send,
        bridge_close,
        bridge_open_window,
        bridge_title
    ]);

    #[cfg(feature = "selftest")]
    let builder = builder.invoke_handler(tauri::generate_handler![
        bridge_open,
        bridge_send,
        bridge_close,
        bridge_open_window,
        bridge_title,
        selftest::selftest_report,
        selftest::selftest_done,
        selftest::selftest_windows,
        selftest::selftest_close_window
    ]);

    let app = builder
        .register_asynchronous_uri_scheme_protocol("bee", |ctx, request, responder| {
            let bee = ctx.app_handle().state::<Arc<Bee>>().inner().clone();
            let win = ctx.webview_label().to_string();
            // Answered on a thread of its own: Bee serves requests concurrently.
            thread::spawn(move || responder.respond(bee.request(&win, request)));
        })
        .setup(move |app| {
            let mut child = start_bee(&folder)?;
            let stdout = child.stdout.take().expect("piped");
            let stdin = child.stdin.take().expect("piped");

            let bee = Arc::new(Bee {
                stdin: Mutex::new(Some(stdin)),
                child: Mutex::new(child),
                next_id: AtomicU64::new(1),
                pending: Mutex::new(HashMap::new()),
                sockets: Mutex::new(HashMap::new()),
            });

            app.manage(bee.clone());
            read_frames(stdout, bee, app.handle().clone());
            open_window(app.handle(), &folder)?;
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building Bee's window");

    app.run(|app, event| match event {
        RunEvent::WindowEvent {
            label,
            event: WindowEvent::Destroyed,
            ..
        } => {
            if let Some(bee) = app.try_state::<Arc<Bee>>() {
                bee.window_closed(&label);
            }
        }
        RunEvent::Exit => {
            if let Some(bee) = app.try_state::<Arc<Bee>>() {
                bee.stop();
            }
        }
        _ => {}
    });
}
