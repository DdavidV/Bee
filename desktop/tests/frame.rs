//! Frames (src/frame.rs).

use bee_desktop::frame::{read, write};
use serde_json::{json, Value};

#[test]
fn a_frame_is_its_length_then_json() {
    let mut bytes = Vec::new();
    write(&mut bytes, &json!({"t": "x"})).unwrap();

    assert_eq!(&bytes[..4], &[0, 0, 0, 9]);
    assert_eq!(&bytes[4..], br#"{"t":"x"}"#);
}

#[test]
fn frames_are_read_back_one_by_one() {
    let frames = [json!({"t": "open", "sid": "w1:s1"}), json!({"t": "ő"})];
    let mut bytes = Vec::new();
    for frame in &frames {
        write(&mut bytes, frame).unwrap();
    }

    let mut from = bytes.as_slice();
    for frame in &frames {
        let body = read(&mut from).unwrap();
        assert_eq!(&serde_json::from_slice::<Value>(&body).unwrap(), frame);
    }
    assert!(read(&mut from).is_err());
}

#[test]
fn a_frame_cut_short_is_an_error() {
    let mut bytes = Vec::new();
    write(&mut bytes, &json!({"t": "msg"})).unwrap();
    bytes.pop();

    assert!(read(&mut bytes.as_slice()).is_err());
    assert!(read(&mut &bytes[..2]).is_err());
}
