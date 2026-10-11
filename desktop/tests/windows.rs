//! Windows, and opening paths in them (src/windows.rs).

mod common;

use std::path::{Path, PathBuf};

use bee_desktop::windows::{folder_url, page_url, plan, url_folder, Open, Plan};
use common::TestDir;

#[test]
fn a_page_of_bee_is_a_path_on_its_protocol() {
    assert_eq!(
        page_url("/?folder=/home/me/bee").unwrap().as_str(),
        "bee://localhost/?folder=/home/me/bee"
    );
    assert_eq!(
        page_url("/settings").unwrap().as_str(),
        "bee://localhost/settings"
    );
}

#[test]
fn another_address_is_not_a_page_of_bee() {
    for url in ["", "settings", "https://example.com/", "//example.com/x"] {
        assert_eq!(page_url(url), None, "{url:?}");
    }
}

#[test]
fn a_pages_folder_is_in_its_query() {
    let folder = |path| url_folder(&page_url(path).unwrap());

    assert_eq!(folder("/?folder=/home/me/bee"), Some("/home/me/bee".into()));
    assert_eq!(
        folder("/?file[]=/a/b.txt&folder=%2Fhome%2Fme%2Fmy%20notes"),
        Some("/home/me/my notes".into())
    );
    assert_eq!(folder("/"), None);
    assert_eq!(folder("/?file[]=/a/b.txt"), None);
}

#[test]
fn a_folders_page_names_it_and_its_files() {
    let folder = Path::new("/home/me/my notes & more");
    let files = [folder.join("a.txt"), folder.join("ő/b=c.txt")];

    let url = folder_url(folder, &files);
    let named: Vec<(String, String)> = url.query_pairs().into_owned().collect();

    assert_eq!(url.scheme(), "bee");
    assert_eq!(url_folder(&url), Some(folder.to_path_buf()));
    assert_eq!(
        named,
        [
            ("folder".to_string(), "/home/me/my notes & more".to_string()),
            (
                "file[]".to_string(),
                "/home/me/my notes & more/a.txt".to_string()
            ),
            (
                "file[]".to_string(),
                "/home/me/my notes & more/ő/b=c.txt".to_string()
            ),
        ]
    );
    assert_eq!(
        url_folder(&folder_url(folder, &[])),
        Some(folder.to_path_buf())
    );
}

fn new(folder: &Path, files: &[&PathBuf]) -> (PathBuf, Vec<PathBuf>) {
    (
        folder.to_path_buf(),
        files.iter().map(|f| (*f).clone()).collect(),
    )
}

#[test]
fn a_folder_that_has_a_window_is_focused() {
    let tmp = TestDir::new();
    let (a, b) = (tmp.dir("a"), tmp.dir("b"));

    assert_eq!(
        plan(std::slice::from_ref(&b), &[a, b.clone()]),
        Plan {
            existing: vec![Open::Focus { window: 1 }],
            new: vec![],
        }
    );
}

#[test]
fn a_folder_without_a_window_gets_one() {
    let tmp = TestDir::new();
    let (a, b) = (tmp.dir("a"), tmp.dir("b"));
    // A window of the folder it is in is not its window.
    let inner = tmp.dir("a/inner");

    assert_eq!(
        plan(&[b.clone(), inner.clone(), b.clone()], &[a]),
        Plan {
            existing: vec![],
            new: vec![new(&b, &[]), new(&inner, &[])],
        }
    );
}

#[test]
fn a_file_opens_in_the_innermost_window_that_holds_it() {
    let tmp = TestDir::new();
    let (a, inner) = (tmp.dir("a"), tmp.dir("a/inner"));
    let (outer_file, inner_file) = (tmp.file("a/x.txt"), tmp.file("a/inner/deep/y.txt"));
    // A folder whose name only starts the same does not hold it.
    let other = tmp.dir("a/inn");

    for folders in [
        [a.clone(), inner.clone(), other.clone()],
        [other.clone(), inner.clone(), a.clone()],
    ] {
        let at = |folder| folders.iter().position(|f| f == folder).unwrap();

        assert_eq!(
            plan(&[outer_file.clone(), inner_file.clone()], &folders),
            Plan {
                existing: vec![
                    Open::ShowFile {
                        window: at(&a),
                        file: outer_file.clone()
                    },
                    Open::ShowFile {
                        window: at(&inner),
                        file: inner_file.clone()
                    },
                ],
                new: vec![],
            }
        );
    }
}

#[test]
fn a_file_no_window_holds_gets_a_window_for_its_folder() {
    let tmp = TestDir::new();
    let open = tmp.dir("open");
    let (x, y, z) = (
        tmp.file("a/x.txt"),
        tmp.file("a/y.txt"),
        tmp.file("b/z.txt"),
    );

    // Files of one folder share its window.
    assert_eq!(
        plan(&[x.clone(), z.clone(), y.clone()], &[open]),
        Plan {
            existing: vec![],
            new: vec![
                new(&tmp.0.join("a"), &[&x, &y]),
                new(&tmp.0.join("b"), &[&z])
            ],
        }
    );
}

#[test]
fn a_file_goes_to_a_window_about_to_open_for_a_folder_that_holds_it() {
    let tmp = TestDir::new();
    let a = tmp.dir("a");
    let (x, deep) = (tmp.file("a/x.txt"), tmp.file("a/inner/deep.txt"));

    assert_eq!(
        plan(&[a.clone(), x.clone(), deep.clone()], &[]),
        Plan {
            existing: vec![],
            new: vec![new(&a, &[&x, &deep])],
        }
    );
    // Only one named before it: a folder named later gets a window of its own.
    assert_eq!(
        plan(&[x.clone(), a.clone()], &[]),
        Plan {
            existing: vec![],
            new: vec![new(&a, &[&x])],
        }
    );
    assert_eq!(
        plan(&[deep.clone(), a.clone()], &[]),
        Plan {
            existing: vec![],
            new: vec![new(&tmp.0.join("a/inner"), &[&deep]), new(&a, &[])],
        }
    );
}

#[test]
fn a_file_that_is_not_there_opens_like_one_that_is() {
    let tmp = TestDir::new();
    let a = tmp.dir("a");
    let (held, alone) = (a.join("new.txt"), tmp.0.join("b/new.txt"));

    assert_eq!(
        plan(&[held.clone(), alone.clone()], &[a]),
        Plan {
            existing: vec![Open::ShowFile {
                window: 0,
                file: held
            }],
            new: vec![new(&tmp.0.join("b"), &[&alone])],
        }
    );
}

#[test]
fn nothing_to_open_is_an_empty_plan() {
    assert_eq!(plan(&[], &[PathBuf::from("/a")]), Plan::default());
}
