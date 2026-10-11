//! Bee's desktop app; see the library (src/lib.rs).

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    bee_desktop::run()
}
