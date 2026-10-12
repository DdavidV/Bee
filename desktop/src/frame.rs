//! Frames, what Bee and the app send each other: a 4-byte big-endian length
//! followed by JSON; see `Desktop.Bridge` in Bee for the protocol.

use std::io::{self, Read, Write};

use serde_json::Value;

/// Writes `frame` to `to`, flushed: in one piece (a pipe is written to as
/// it is told, and two writes would be two wake-ups of the reader).
pub fn write(to: &mut impl Write, frame: &Value) -> io::Result<()> {
    let mut bytes = vec![0u8; 4];
    serde_json::to_writer(&mut bytes, frame).expect("a frame is JSON");
    let len = (bytes.len() - 4) as u32;
    bytes[..4].copy_from_slice(&len.to_be_bytes());
    to.write_all(&bytes)?;
    to.flush()
}

/// The body of the next frame of `from`; an error at its end.
pub fn read(from: &mut impl Read) -> io::Result<Vec<u8>> {
    let mut len = [0u8; 4];
    from.read_exact(&mut len)?;

    let mut body = vec![0u8; u32::from_be_bytes(len) as usize];
    from.read_exact(&mut body)?;
    Ok(body)
}
