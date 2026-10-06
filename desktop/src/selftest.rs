//! The GUI self-test (`cargo run --features selftest -- <repo>`): a script
//! (tests/selftest.js) drives Bee's real UI in the window and reports each
//! check here, on stderr; then the app quits, with exit code 0 when all
//! passed. Not part of normal builds.

use tauri::AppHandle;

pub const SCRIPT: &str = include_str!("../tests/selftest.js");

#[tauri::command]
pub fn selftest_report(line: String) {
    eprintln!("selftest: {line}");
}

#[tauri::command]
pub fn selftest_done(app: AppHandle, ok: bool) {
    eprintln!("selftest: {}", if ok { "all passed" } else { "FAILED" });
    app.exit(if ok { 0 } else { 1 });
}
