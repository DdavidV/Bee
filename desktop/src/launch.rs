//! What a launch names: the folder to open is the first argument (default:
//! the current directory), or files (`bee README.md`), opened in a window
//! for their folder (`windows::open_paths`).

use std::path::{Path, PathBuf};

/// The paths a launch names: its arguments that aren't flags, relative to
/// `cwd`; `cwd` itself without any.
pub fn launch_paths(args: &[String], cwd: &Path) -> Vec<PathBuf> {
    let mut paths: Vec<PathBuf> = args
        .iter()
        .skip(1)
        .filter(|a| !a.starts_with('-'))
        .map(|a| cwd.join(a))
        .collect();

    if paths.is_empty() {
        paths.push(cwd.to_path_buf());
    }

    paths
        .into_iter()
        .map(|p| p.canonicalize().unwrap_or(p))
        .collect()
}

/// A folder: itself; a file: its folder.
pub fn folder_of(path: &Path) -> PathBuf {
    if path.is_dir() {
        path.to_path_buf()
    } else {
        path.parent().unwrap_or(path).to_path_buf()
    }
}
