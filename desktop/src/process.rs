//! Bee, the child process: which one to start, starting it in desktop mode
//! (`BEE_MODE=desktop`) and stopping it.
//!
//! Which Bee (`release/3`): `BEE_RELEASE=/path/to/bin/bee` if set; else a
//! release build of this app starts the checkout's release
//! (`mix bee.release.desktop`), a development build (`cargo run`) the
//! checkout itself, through mix.

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::Duration;
use std::{env, io, thread};

/// The Bee release to start, or None to run the checkout through mix
/// (development builds). Until the app bundles its release (packaging), a
/// release build uses the one `mix bee.release.desktop` built next to it.
///
/// `named` is the one `BEE_RELEASE` names; `development` whether this is a
/// development build.
pub fn release(named: Option<String>, development: bool, repo: &Path) -> Option<PathBuf> {
    if let Some(path) = named {
        return Some(PathBuf::from(path));
    }
    if development {
        return None;
    }

    let script = if cfg!(windows) { "bee.bat" } else { "bee" };
    Some(repo.join("_build/prod/rel/bee/bin").join(script))
}

/// Starts Bee in desktop mode for `folder`, its stdin/stdout piped to us.
pub fn start(folder: &Path) -> io::Result<Child> {
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();

    let mut command = match release(env::var("BEE_RELEASE").ok(), cfg!(debug_assertions), repo) {
        Some(release) if !release.exists() => {
            return Err(io::Error::other(format!(
                "no Bee release at {} (build it with `mix bee.release.desktop`)",
                release.display()
            )));
        }
        Some(release) => {
            let mut c = Command::new(release);
            c.arg("start");
            c
        }
        None => {
            // Development: the checkout, compiled first (a stale build would
            // start without the bridge).
            let status = Command::new("mix")
                .arg("compile")
                .current_dir(repo)
                .stdout(Stdio::from(io::stderr()))
                .status()?;
            if !status.success() {
                return Err(io::Error::other("mix compile failed"));
            }

            let mut c = Command::new("elixir");
            c.args([
                "--erl",
                "-noinput",
                "-S",
                "mix",
                "run",
                "--no-halt",
                "--no-compile",
            ])
            .current_dir(repo);
            c
        }
    };

    command
        .env("BEE_MODE", "desktop")
        .env("BEE_ROOT", folder)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
}

/// Waits for Bee, whose stdin is closed, to stop. Kills it if it hasn't
/// after a while.
pub fn stop(child: &mut Child) {
    for _ in 0..50 {
        if let Ok(Some(_)) = child.try_wait() {
            return;
        }
        thread::sleep(Duration::from_millis(100));
    }
    let _ = child.kill();
}
