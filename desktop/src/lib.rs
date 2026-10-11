//! Bee's desktop shell: windows showing Bee, which runs as a child process
//! in desktop mode (`BEE_MODE=desktop`). The two only talk over Bee's
//! stdin/stdout – no port is opened on either side.
//!
//! One Bee serves every window, one window per folder (`?folder=…`), like
//! VS Code. A window opens for the folder given at launch; Bee asks for more
//! (Open Folder in New Window, `bridge_open_window`, after the native
//! folder dialog, `bridge_pick_folder`); and launching the app
//! again hands its folder to the running one (single instance), which
//! focuses the window showing it or opens one. The app quits with its last
//! window.
//!
//! - The window's requests (`bee://localhost/…`, `http://bee.localhost/…` on
//!   Windows) become `req` frames; Bee's `res` frames answer them. So do
//!   those of webview panels' frames (`beeview://localhost/…`), which have
//!   an origin of their own that way.
//! - LiveView's socket frames come from the page through the `bridge_*`
//!   commands (window.__bridge, src/bridge.js) and go back over a Channel.
//!
//! Its parts:
//!
//! - `frame`: the frames Bee and the app send each other.
//! - `bridge`: the bridge to Bee, what's waiting for its answers.
//! - `process`: Bee, the child process – which one, starting and stopping it.
//! - `launch`: the paths a launch names.
//! - `windows`: the windows, and opening paths in them.
//! - `commands`: what a page asks of the app (`bridge_*`).
//! - `run/0`, here: the app, put together.
//!
//! With `--features selftest` the first window drives itself (src/selftest.rs).
//! The tests of the parts are in tests/, one file each.

pub mod bridge;
pub mod commands;
pub mod frame;
pub mod launch;
pub mod process;
#[cfg(feature = "selftest")]
mod selftest;
pub mod windows;

use std::path::Path;
use std::process::Child;
use std::sync::{Arc, Mutex};
use std::{env, thread};

use tauri::{Manager, RunEvent, UriSchemeContext, UriSchemeResponder, WindowEvent, Wry};

use bridge::Bridge;
use commands::*;
use launch::{folder_of, launch_paths};
use windows::open_paths;

/// A request of a window, on one of Bee's protocols: answered by Bee, on a
/// thread of its own, as Bee serves requests concurrently.
fn serve(
    ctx: UriSchemeContext<'_, Wry>,
    request: tauri::http::Request<Vec<u8>>,
    responder: UriSchemeResponder,
) {
    let bridge = ctx.app_handle().state::<Arc<Bridge>>().inner().clone();
    let win = ctx.webview_label().to_string();
    thread::spawn(move || responder.respond(bridge.request(&win, request)));
}

/// Runs the app until its last window closes or Bee stops.
pub fn run() {
    let args: Vec<String> = env::args().collect();
    let paths = launch_paths(&args, &env::current_dir().unwrap());
    // Bee's own folder (BEE_ROOT): the first one named.
    let folder = folder_of(&paths[0]);

    // Launched again: the running app opens the paths, this one exits.
    let builder =
        tauri::Builder::default().plugin(tauri_plugin_single_instance::init(|app, args, cwd| {
            open_paths(app, &launch_paths(&args, Path::new(&cwd)));
        }));
    // Open Folder's native dialog (bridge_pick_folder); the clipboard
    // (bridge_copy_text); the user's browser (bridge_open_url).
    let builder = builder
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_opener::init());

    #[cfg(not(feature = "selftest"))]
    let builder = builder.invoke_handler(tauri::generate_handler![
        bridge_open,
        bridge_send,
        bridge_close,
        bridge_open_window,
        bridge_pick_folder,
        bridge_copy_text,
        bridge_open_url,
        bridge_title
    ]);

    #[cfg(feature = "selftest")]
    let builder = builder.invoke_handler(tauri::generate_handler![
        bridge_open,
        bridge_send,
        bridge_close,
        bridge_open_window,
        bridge_pick_folder,
        bridge_copy_text,
        bridge_open_url,
        bridge_title,
        selftest::selftest_report,
        selftest::selftest_done,
        selftest::selftest_windows,
        selftest::selftest_close_window,
        selftest::selftest_clipboard
    ]);

    let app = builder
        .register_asynchronous_uri_scheme_protocol("bee", serve)
        // The pages of extensions' webview panels, in frames of the window:
        // another scheme, so another origin than Bee's own page. Bee tells
        // them apart by the address (BeeWeb.WebviewServer).
        .register_asynchronous_uri_scheme_protocol("beeview", serve)
        .setup(move |app| {
            let mut child = process::start(&folder)?;
            let stdout = child.stdout.take().expect("piped");
            let stdin = child.stdin.take().expect("piped");

            let bridge = Arc::new(Bridge::new(stdin));
            app.manage(bridge.clone());
            app.manage(Mutex::new(child));

            // Bee's frames, until it stops; then the app quits.
            let handle = app.handle().clone();
            thread::spawn(move || {
                bridge.read_frames(stdout);
                eprintln!("bee: Bee stopped");
                handle.exit(0);
            });

            open_paths(app.handle(), &paths);
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
            if let Some(bridge) = app.try_state::<Arc<Bridge>>() {
                bridge.window_closed(&label);
            }
        }
        RunEvent::Exit => {
            // Bee stops when its stdin closes.
            if let Some(bridge) = app.try_state::<Arc<Bridge>>() {
                bridge.close();
            }
            if let Some(child) = app.try_state::<Mutex<Child>>() {
                process::stop(&mut child.lock().unwrap());
            }
        }
        _ => {}
    });
}
