//! What a page asks of the app (window.__bridge, src/bridge.js): LiveView's
//! socket, windows, and what the webview doesn't let a page do itself.

use std::sync::Arc;

use serde_json::Value;
use tauri::ipc::Channel;
use tauri::AppHandle;

use crate::bridge::Bridge;
use crate::windows::{open_paths, page_url, url_folder};

// LiveView's socket.

#[tauri::command]
pub fn bridge_open(
    webview: tauri::Webview,
    bridge: tauri::State<'_, Arc<Bridge>>,
    sid: String,
    url: String,
    channel: Channel<Value>,
) {
    let win = webview.label().to_string();
    let sid = socket_id(&win, &sid);
    bridge.open_socket(sid, win, &url, channel);
}

#[tauri::command]
pub fn bridge_send(
    webview: tauri::Webview,
    bridge: tauri::State<'_, Arc<Bridge>>,
    sid: String,
    data: String,
    bin: bool,
) {
    bridge.send_socket(&socket_id(webview.label(), &sid), &data, bin);
}

#[tauri::command]
pub fn bridge_close(webview: tauri::Webview, bridge: tauri::State<'_, Arc<Bridge>>, sid: String) {
    bridge.close_socket(&socket_id(webview.label(), &sid));
}

/// The socket id of a page of window `win`, unique among all windows'
/// (`w2:s1`): pages number their sockets themselves, so two windows have an
/// `s1` each.
pub fn socket_id(win: &str, sid: &str) -> String {
    format!("{win}:{sid}")
}

// Windows.

/// Bee asks for a window: `url` is a page of Bee, `/?folder=…`.
#[tauri::command]
pub fn bridge_open_window(app: AppHandle, url: String) -> Result<(), String> {
    let url = page_url(&url).ok_or_else(|| format!("not a page of Bee: {url}"))?;
    let folder = url_folder(&url).ok_or_else(|| format!("no folder in {url}"))?;
    open_paths(&app, &[folder]);
    Ok(())
}

/// Open Folder: the native folder dialog, over the window that asked. The
/// folder picked, or None.
#[tauri::command]
pub async fn bridge_pick_folder(
    window: tauri::WebviewWindow,
    title: String,
    start: String,
) -> Option<String> {
    use tauri_plugin_dialog::DialogExt;

    window
        .dialog()
        .file()
        .set_title(title)
        .set_directory(start)
        .set_parent(&window)
        .blocking_pick_folder()
        .and_then(|path| path.into_path().ok())
        .map(|path| path.to_string_lossy().into_owned())
}

/// The page's title changed (another folder): so does the window's.
#[tauri::command]
pub fn bridge_title(window: tauri::WebviewWindow, title: String) {
    let _ = window.set_title(&title);
}

// The system.

/// Copy Path and the like: text to the system clipboard (the webview only
/// lets a page write it in some cases).
#[tauri::command]
pub fn bridge_copy_text(app: AppHandle, text: String) -> Result<(), String> {
    use tauri_plugin_clipboard_manager::ClipboardExt;
    app.clipboard().write_text(text).map_err(|e| e.to_string())
}

/// A web link (a plugin's README, its repository): opened in the user's
/// browser, not in Bee's window. Only http(s) URLs.
#[tauri::command]
pub fn bridge_open_url(app: AppHandle, url: String) -> Result<(), String> {
    use tauri_plugin_opener::OpenerExt;
    if !is_web_link(&url) {
        return Err(format!("not a web link: {url}"));
    }
    app.opener()
        .open_url(url, None::<&str>)
        .map_err(|e| e.to_string())
}

/// Whether `url` is one for the user's browser: http(s).
pub fn is_web_link(url: &str) -> bool {
    url.starts_with("https://") || url.starts_with("http://")
}
