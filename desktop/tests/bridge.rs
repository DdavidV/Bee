//! The bridge to Bee (src/bridge.rs), with a stdin and a stdout of the tests'
//! in Bee's place.

use std::io::Write;
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::Duration;

use bee_desktop::bridge::Bridge;
use bee_desktop::frame;
use serde_json::{json, Value};
use tauri::http;
use tauri::ipc::{Channel, InvokeResponseBody};

const SOON: Duration = Duration::from_secs(5);

/// Bee's stdin: every frame written to it, on a channel.
struct ToBee {
    bytes: Vec<u8>,
    frames: mpsc::Sender<Value>,
}

impl Write for ToBee {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        let mut rest = self.bytes.as_slice();
        while let Ok(body) = frame::read(&mut rest) {
            let _ = self.frames.send(serde_json::from_slice(&body).unwrap());
        }
        self.bytes = rest.to_vec();
        Ok(())
    }
}

/// A bridge, and the frames it sends to Bee.
fn bridge() -> (Bridge, mpsc::Receiver<Value>) {
    let (frames, sent) = mpsc::channel();
    let to_bee = ToBee {
        bytes: Vec::new(),
        frames,
    };
    (Bridge::new(to_bee), sent)
}

/// A page's channel, and the frames Bee sends over it.
fn channel() -> (Channel<Value>, mpsc::Receiver<Value>) {
    let (tx, got) = mpsc::channel();
    let channel = Channel::new(move |body| {
        if let InvokeResponseBody::Json(json) = body {
            let _ = tx.send(serde_json::from_str(&json).unwrap());
        }
        Ok(())
    });
    (channel, got)
}

/// Bee's stdout holding `frames`.
fn from_bee(frames: &[Value]) -> Vec<u8> {
    let mut bytes = Vec::new();
    for frame in frames {
        frame::write(&mut bytes, frame).unwrap();
    }
    bytes
}

/// Bee sends `frames`.
fn bee_sends(bridge: &Bridge, frames: &[Value]) {
    bridge.read_frames(from_bee(frames).as_slice());
}

fn get(url: &str) -> http::Request<Vec<u8>> {
    http::Request::builder().uri(url).body(Vec::new()).unwrap()
}

/// What Bee answers `request` of window `w1` with, given its `res` frame
/// (without its id).
fn answered(request: http::Request<Vec<u8>>, mut res: Value) -> http::Response<Vec<u8>> {
    let (bridge, sent) = bridge();
    let bridge = Arc::new(bridge);

    let asking = {
        let bridge = bridge.clone();
        thread::spawn(move || bridge.request("w1", request))
    };

    let req = sent.recv_timeout(SOON).unwrap();
    res["t"] = json!("res");
    res["id"] = req["id"].clone();
    bee_sends(&bridge, &[res]);

    asking.join().unwrap()
}

// Requests.

#[test]
fn a_request_is_a_req_frame() {
    let (bridge, sent) = bridge();
    let bridge = bridge.timeout(Duration::ZERO);

    let request = http::Request::builder()
        .method("POST")
        .uri("bee://localhost/save?folder=/tmp")
        .header("content-type", "text/plain")
        .body(b"hello".to_vec())
        .unwrap();
    bridge.request("w2", request);

    let req = sent.recv_timeout(SOON).unwrap();
    assert_eq!(
        req,
        json!({
            "t": "req",
            "id": req["id"],
            "win": "w2",
            "method": "POST",
            "url": "bee://localhost/save?folder=/tmp",
            "headers": [["content-type", "text/plain"]],
            "body": "aGVsbG8=",
        })
    );
    assert!(req["id"].is_u64());
}

#[test]
fn requests_have_ids_of_their_own() {
    let (bridge, sent) = bridge();
    let bridge = bridge.timeout(Duration::ZERO);

    bridge.request("w1", get("bee://localhost/a"));
    bridge.request("w1", get("bee://localhost/b"));

    let a = sent.recv_timeout(SOON).unwrap();
    let b = sent.recv_timeout(SOON).unwrap();
    assert_ne!(a["id"], b["id"]);
}

#[test]
fn a_request_is_answered_by_its_res_frame() {
    let (bridge, sent) = bridge();
    let bridge = Arc::new(bridge);

    let asking = {
        let bridge = bridge.clone();
        thread::spawn(move || bridge.request("w1", get("bee://localhost/")))
    };
    let req = sent.recv_timeout(SOON).unwrap();

    bee_sends(
        &bridge,
        &[
            // Not its answer: another request's.
            json!({"t": "res", "id": 999, "status": 500}),
            json!({"t": "res", "id": req["id"], "status": 200, "body": "b2s="}),
        ],
    );

    let res = asking.join().unwrap();
    assert_eq!(res.status(), 200);
    assert_eq!(res.body(), b"ok");
}

#[test]
fn a_res_frame_is_a_response() {
    let res = answered(
        get("bee://localhost/"),
        json!({
            "status": 404,
            "headers": [["content-type", "text/html"], ["x-bee", "1"], ["bad"], [1, 2]],
            "body": "aGVsbG8=",
        }),
    );

    assert_eq!(res.status(), 404);
    assert_eq!(res.headers().len(), 2);
    assert_eq!(res.headers()["content-type"], "text/html");
    assert_eq!(res.headers()["x-bee"], "1");
    assert_eq!(res.body(), b"hello");
}

#[test]
fn a_res_frame_missing_its_parts_is_an_empty_500() {
    let res = answered(get("bee://localhost/"), json!({}));

    assert_eq!(res.status(), 500);
    assert!(res.body().is_empty());
}

#[test]
fn a_res_frame_that_makes_no_response_is_a_502() {
    let bad_status = answered(get("bee://localhost/"), json!({"status": 99}));
    assert_eq!(bad_status.status(), 502);
    assert_eq!(bad_status.body(), b"bad response from Bee");

    let bad_header = answered(
        get("bee://localhost/"),
        json!({"status": 200, "headers": [["a b", "c"]]}),
    );
    assert_eq!(bad_header.status(), 502);
}

#[test]
fn a_request_bee_does_not_answer_is_a_504() {
    let (bridge, _sent) = bridge();
    let bridge = bridge.timeout(Duration::from_millis(10));

    let res = bridge.request("w1", get("bee://localhost/"));

    assert_eq!(res.status(), 504);
    assert_eq!(res.body(), b"Bee didn't answer");
}

// LiveView's sockets.

#[test]
fn a_sockets_frames_go_to_bee_and_come_back_over_its_channel() {
    let (bridge, sent) = bridge();
    let (channel, got) = channel();

    bridge.open_socket("w1:s1".into(), "w1".into(), "/live/websocket", channel);
    assert_eq!(
        sent.recv_timeout(SOON).unwrap(),
        json!({"t": "open", "sid": "w1:s1", "win": "w1", "url": "/live/websocket"})
    );

    bridge.send_socket("w1:s1", "[1]", false);
    assert_eq!(
        sent.recv_timeout(SOON).unwrap(),
        json!({"t": "msg", "sid": "w1:s1", "data": "[1]", "bin": false})
    );

    let opened = json!({"t": "opened", "sid": "w1:s1"});
    let msg = json!({"t": "msg", "sid": "w1:s1", "data": "[2]"});
    // Another socket's: not for this channel.
    let other = json!({"t": "msg", "sid": "w2:s1", "data": "[3]"});
    bee_sends(&bridge, &[opened.clone(), other, msg.clone()]);

    assert_eq!(got.try_recv().unwrap(), opened);
    assert_eq!(got.try_recv().unwrap(), msg);
    assert!(got.try_recv().is_err());
}

#[test]
fn a_socket_bee_closed_gets_no_more_frames() {
    let (bridge, _sent) = bridge();
    let (channel, got) = channel();
    bridge.open_socket("w1:s1".into(), "w1".into(), "/live", channel);

    let closed = json!({"t": "closed", "sid": "w1:s1"});
    let late = json!({"t": "msg", "sid": "w1:s1", "data": "late"});
    bee_sends(&bridge, &[closed.clone(), late]);

    assert_eq!(got.try_recv().unwrap(), closed);
    assert!(got.try_recv().is_err());
}

#[test]
fn a_socket_its_page_closed_is_closed_in_bee() {
    let (bridge, sent) = bridge();
    let (channel, got) = channel();
    bridge.open_socket("w1:s1".into(), "w1".into(), "/live", channel);
    sent.recv_timeout(SOON).unwrap();

    bridge.close_socket("w1:s1");
    bee_sends(
        &bridge,
        &[json!({"t": "msg", "sid": "w1:s1", "data": "late"})],
    );

    assert_eq!(
        sent.recv_timeout(SOON).unwrap(),
        json!({"t": "close", "sid": "w1:s1"})
    );
    assert!(got.try_recv().is_err());
}

#[test]
fn a_closed_window_closes_its_sockets_only() {
    let (bridge, sent) = bridge();
    let mut got = Vec::new();
    for (sid, win) in [("w1:s1", "w1"), ("w1:s2", "w1"), ("w2:s1", "w2")] {
        let (channel, frames) = channel();
        bridge.open_socket(sid.into(), win.into(), "/live", channel);
        sent.recv_timeout(SOON).unwrap();
        got.push(frames);
    }

    bridge.window_closed("w1");

    let mut closed = vec![
        sent.recv_timeout(SOON).unwrap(),
        sent.recv_timeout(SOON).unwrap(),
    ];
    closed.sort_by_key(|frame| frame["sid"].as_str().unwrap().to_string());
    assert_eq!(
        closed,
        [
            json!({"t": "close", "sid": "w1:s1"}),
            json!({"t": "close", "sid": "w1:s2"})
        ]
    );
    assert!(sent.try_recv().is_err());

    // The other window's socket still gets its frames; the closed one's don't.
    let msg = |sid: &str| json!({"t": "msg", "sid": sid, "data": "[1]"});
    bee_sends(&bridge, &[msg("w1:s1"), msg("w1:s2"), msg("w2:s1")]);

    assert!(got[0].try_recv().is_err());
    assert!(got[1].try_recv().is_err());
    assert_eq!(got[2].try_recv().unwrap(), msg("w2:s1"));
}

// Bee's stdout and stdin.

#[test]
fn bees_frames_are_read_until_its_stdout_ends() {
    let (bridge, _sent) = bridge();
    let (channel, got) = channel();
    bridge.open_socket("w1:s1".into(), "w1".into(), "/live", channel);

    let first = json!({"t": "msg", "sid": "w1:s1", "data": "1"});
    let second = json!({"t": "msg", "sid": "w1:s1", "data": "2"});
    // A frame of a kind not known is passed over.
    let mut bytes = from_bee(&[first.clone(), json!({"t": "what"})]);
    // So is one that isn't JSON: not the end either.
    bytes.extend_from_slice(&[0, 0, 0, 3]);
    bytes.extend_from_slice(b"{no");
    bytes.extend(from_bee(std::slice::from_ref(&second)));
    // Cut short: Bee stopped.
    bytes.extend_from_slice(&[0, 0, 0, 9, b'{']);

    bridge.read_frames(bytes.as_slice());

    assert_eq!(got.try_recv().unwrap(), first);
    assert_eq!(got.try_recv().unwrap(), second);
    assert!(got.try_recv().is_err());
}

#[test]
fn a_closed_bridge_sends_nothing() {
    let (bridge, sent) = bridge();

    bridge.close();
    bridge.send_socket("w1:s1", "[1]", false);

    // Its stdin is dropped, which is what stops Bee.
    assert!(matches!(
        sent.recv_timeout(SOON),
        Err(mpsc::RecvTimeoutError::Disconnected)
    ));
}
