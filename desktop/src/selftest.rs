//! The GUI self-test (`cargo run --features selftest -- <repo>`): a script
//! (tests/selftest.js) drives Bee's real UI in the window and reports each
//! check here, on stderr; then the app quits, with exit code 0 when all
//! passed. Not part of normal builds.

use tauri::{AppHandle, Manager};

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

/// The folder of every window (`?folder=`).
#[tauri::command]
pub fn selftest_windows(app: AppHandle) -> Vec<String> {
    app.webview_windows()
        .into_values()
        .filter_map(|w| w.url().ok())
        .filter_map(|u| {
            u.query_pairs()
                .find(|(k, _)| k == "folder")
                .map(|(_, v)| v.into_owned())
        })
        .collect()
}

/// Closes the window of `folder`.
#[tauri::command]
pub fn selftest_close_window(app: AppHandle, folder: String) {
    for window in app.webview_windows().into_values() {
        let shows = window.url().ok().is_some_and(|u| {
            u.query_pairs()
                .any(|(k, v)| k == "folder" && v.as_ref() == folder)
        });
        if shows {
            let _ = window.close();
        }
    }
}
