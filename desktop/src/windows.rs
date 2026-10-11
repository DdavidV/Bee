//! Windows: one per folder (`?folder=…`), like VS Code. `open_paths` opens
//! what a launch (or Bee, `bridge_open_window`) names, in the window showing
//! it or a new one.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::json;
use tauri::{AppHandle, Manager, Url, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

use crate::launch::folder_of;

const BRIDGE_JS: &str = include_str!("bridge.js");

/// `path` (`/…`) on Bee's protocol.
pub fn page_url(path: &str) -> Option<Url> {
    if !path.starts_with('/') || path.starts_with("//") {
        return None;
    }
    Url::parse("bee://localhost/").ok()?.join(path).ok()
}

/// The folder a page of Bee shows (`?folder=`).
pub fn url_folder(url: &Url) -> Option<PathBuf> {
    url.query_pairs()
        .find(|(k, _)| k == "folder")
        .map(|(_, v)| PathBuf::from(v.as_ref()))
}

fn window_folder(window: &WebviewWindow) -> Option<PathBuf> {
    window.url().ok().and_then(|url| url_folder(&url))
}

/// The page of Bee for `folder`, opening `files` once it is there.
pub fn folder_url(folder: &Path, files: &[PathBuf]) -> Url {
    let mut url = Url::parse("bee://localhost/").unwrap();
    url.query_pairs_mut()
        .append_pair("folder", &folder.to_string_lossy());
    for file in files {
        url.query_pairs_mut()
            .append_pair("file[]", &file.to_string_lossy());
    }
    url
}

/// The innermost of `folders` that holds `path`.
fn innermost<T>(path: &Path, folders: impl Iterator<Item = (PathBuf, T)>) -> Option<(PathBuf, T)> {
    folders
        .filter(|(folder, _)| path.starts_with(folder))
        .max_by_key(|(folder, _)| folder.components().count())
}

/// Something to open in a window that is there, by its place among them.
#[derive(Debug, PartialEq)]
pub enum Open {
    /// Its folder was named: focused.
    Focus { window: usize },
    /// `file` of its folder was named: opened in it.
    ShowFile { window: usize, file: PathBuf },
}

/// How to open paths (`plan/2`).
#[derive(Debug, Default, PartialEq)]
pub struct Plan {
    /// What windows that are there open, in the paths' order.
    pub existing: Vec<Open>,
    /// The windows to open: their folder and the files to open in it.
    pub new: Vec<(PathBuf, Vec<PathBuf>)>,
}

/// How to open `paths` given the windows' `folders`, like VS Code's
/// `code PATH…`: a folder in its window (focused) or a new one; a file in the
/// window whose folder holds it, else in a new window for the file's folder.
/// Files for the same new window go together: they go in its URL
/// (`folder_url/2`), as a window still loading would miss them.
pub fn plan(paths: &[PathBuf], folders: &[PathBuf]) -> Plan {
    let mut plan = Plan::default();

    for path in paths {
        let windows = folders.iter().cloned().zip(0..);

        if path.is_dir() {
            match folders.iter().position(|folder| folder == path) {
                Some(window) => plan.existing.push(Open::Focus { window }),
                None => {
                    if !plan.new.iter().any(|(folder, _)| folder == path) {
                        plan.new.push((path.clone(), Vec::new()));
                    }
                }
            }
        } else if let Some((_, window)) = innermost(path, windows) {
            plan.existing.push(Open::ShowFile {
                window,
                file: path.clone(),
            });
        } else {
            let pending = plan
                .new
                .iter()
                .enumerate()
                .map(|(i, (f, _))| (f.clone(), i));
            match innermost(path, pending) {
                Some((_, i)) => plan.new[i].1.push(path.clone()),
                None => plan.new.push((folder_of(path), vec![path.clone()])),
            }
        }
    }

    plan
}

/// Opens `paths` as planned (`plan/2`).
pub fn open_paths(app: &AppHandle, paths: &[PathBuf]) {
    let (folders, windows): (Vec<PathBuf>, Vec<WebviewWindow>) = app
        .webview_windows()
        .into_values()
        .filter_map(|w| window_folder(&w).map(|f| (f, w)))
        .unzip();

    let plan = plan(paths, &folders);

    for open in plan.existing {
        let (path, result) = match open {
            Open::Focus { window } => (folders[window].clone(), focus(&windows[window])),
            Open::ShowFile { window, file } => {
                let result = show_file(&windows[window], &file);
                (file, result)
            }
        };

        if let Err(e) = result {
            eprintln!("bee: can't open {}: {e}", path.display());
        }
    }

    for (folder, files) in plan.new {
        if let Err(e) = open_window(app, &folder, &files) {
            eprintln!("bee: can't open a window for {}: {e}", folder.display());
        }
    }
}

fn focus(window: &WebviewWindow) -> tauri::Result<()> {
    let _ = window.unminimize();
    window.set_focus()
}

/// Opens `file` in `window`, which shows its folder (`bee:open_file` in
/// assets/js/app.js).
fn show_file(window: &WebviewWindow, file: &Path) -> tauri::Result<()> {
    let detail = json!({"path": file.to_string_lossy()});
    window.eval(format!(
        "window.dispatchEvent(new CustomEvent('bee:open_file', {{detail: {detail}}}))"
    ))?;
    focus(window)
}

/// A new window for `folder`, opening `files` once it is there.
fn open_window(app: &AppHandle, folder: &Path, files: &[PathBuf]) -> tauri::Result<()> {
    static NEXT: AtomicUsize = AtomicUsize::new(1);
    let n = NEXT.fetch_add(1, Ordering::Relaxed);

    let url = folder_url(folder, files);
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
        window.initialization_script(crate::selftest::SCRIPT)
    } else {
        window
    };

    window.build()?;
    Ok(())
}
