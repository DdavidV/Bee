//! What a launch names (src/launch.rs).

mod common;

use std::path::Path;

use bee_desktop::launch::{folder_of, launch_paths};
use common::TestDir;

fn args(args: &[&str]) -> Vec<String> {
    args.iter().map(|a| a.to_string()).collect()
}

#[test]
fn a_launch_without_paths_names_its_folder() {
    let tmp = TestDir::new();

    assert_eq!(launch_paths(&args(&["bee"]), &tmp.0), [tmp.0.as_path()]);
    assert_eq!(launch_paths(&[], &tmp.0), [tmp.0.as_path()]);
}

#[test]
fn flags_are_not_paths() {
    let tmp = TestDir::new();
    let file = tmp.file("README.md");

    assert_eq!(
        launch_paths(&args(&["bee", "--verbose", "README.md", "-x"]), &tmp.0),
        [file]
    );
    assert_eq!(
        launch_paths(&args(&["bee", "--verbose"]), &tmp.0),
        [tmp.0.as_path()]
    );
}

#[test]
fn paths_are_relative_to_the_launchs_folder() {
    let tmp = TestDir::new();
    let lib = tmp.dir("lib");
    let file = tmp.file("lib/bee.ex");
    let elsewhere = TestDir::new();

    assert_eq!(
        launch_paths(&args(&["bee", "lib", "lib/../lib/bee.ex", "."]), &tmp.0),
        [lib, file.clone(), tmp.0.clone()]
    );
    // An absolute one is itself.
    assert_eq!(
        launch_paths(&args(&["bee", file.to_str().unwrap()]), &elsewhere.0),
        [file]
    );
}

#[test]
fn a_path_that_is_not_there_is_kept() {
    let tmp = TestDir::new();

    assert_eq!(
        launch_paths(&args(&["bee", "new.txt"]), &tmp.0),
        [tmp.0.join("new.txt")]
    );
}

#[test]
fn the_folder_of_a_folder_is_itself_and_of_a_file_its_own() {
    let tmp = TestDir::new();
    let lib = tmp.dir("lib");
    let file = tmp.file("lib/bee.ex");

    assert_eq!(folder_of(&lib), lib);
    assert_eq!(folder_of(&file), lib);
    // Not there: taken for a file.
    assert_eq!(folder_of(&tmp.0.join("new/file.txt")), tmp.0.join("new"));
    assert_eq!(folder_of(Path::new("/")), Path::new("/"));
}
