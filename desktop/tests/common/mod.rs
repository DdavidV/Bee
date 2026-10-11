//! What the tests share.

#![allow(dead_code)]

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

/// A folder of its own for a test, removed with it.
pub struct TestDir(pub PathBuf);

impl TestDir {
    pub fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(1);

        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("bee-desktop-{}-{n}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // As a launch names it (macOS's /tmp is a link).
        TestDir(dir.canonicalize().unwrap())
    }

    /// The folder `name` in it, made.
    pub fn dir(&self, name: &str) -> PathBuf {
        let path = self.0.join(name);
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    /// The file `name` in it, made (and its folder).
    pub fn file(&self, name: &str) -> PathBuf {
        let path = self.0.join(name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "").unwrap();
        path
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
