//! Bee, the child process (src/process.rs).

use std::path::{Path, PathBuf};

use bee_desktop::process::release;

#[test]
fn the_release_named_is_the_one_started() {
    let named = Some("/elsewhere/bin/bee".to_string());

    for development in [true, false] {
        assert_eq!(
            release(named.clone(), development, Path::new("/repo")),
            Some(PathBuf::from("/elsewhere/bin/bee"))
        );
    }
}

#[test]
fn a_development_build_runs_the_checkout() {
    assert_eq!(release(None, true, Path::new("/repo")), None);
}

#[test]
fn a_release_build_starts_the_checkouts_release() {
    let script = if cfg!(windows) { "bee.bat" } else { "bee" };

    assert_eq!(
        release(None, false, Path::new("/repo")),
        Some(Path::new("/repo/_build/prod/rel/bee/bin").join(script))
    );
}

#[cfg(unix)]
mod stopping {
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};

    use bee_desktop::process::stop;

    #[test]
    fn a_bee_that_stopped_is_not_waited_for() {
        let mut child = Command::new("true").spawn().unwrap();
        child.wait().unwrap();

        let started = Instant::now();
        stop(&mut child);

        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn a_bee_stops_once_its_stdin_is_closed() {
        let mut child = Command::new("cat")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .spawn()
            .unwrap();

        child.stdin.take();
        stop(&mut child);

        assert!(child.try_wait().unwrap().unwrap().success());
    }
}
