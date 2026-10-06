use std::fs;

use resvg::{tiny_skia, usvg};

/// Bee's logo: the one source of its icons, the web UI's and this app's.
const LOGO: &str = "../priv/static/images/bee.svg";
const ICON: &str = "icons/icon.png";
const SIZE: u32 = 512;

fn main() {
    println!("cargo:rerun-if-changed={LOGO}");
    render_icon();
    tauri_build::build()
}

/// icons/icon.png (tauri.conf.json) from the logo. Written only when it
/// changes: Tauri watches its icons, and a rewrite would rebuild every time.
fn render_icon() {
    let svg = fs::read(LOGO).expect("Bee's logo");
    let tree = usvg::Tree::from_data(&svg, &usvg::Options::default()).expect("a valid SVG");
    let mut pixmap = tiny_skia::Pixmap::new(SIZE, SIZE).unwrap();
    let scale = SIZE as f32 / tree.size().width().max(tree.size().height());
    resvg::render(&tree, tiny_skia::Transform::from_scale(scale, scale), &mut pixmap.as_mut());

    let png = pixmap.encode_png().expect("a PNG");
    if fs::read(ICON).ok().as_deref() != Some(png.as_slice()) {
        fs::create_dir_all("icons").unwrap();
        fs::write(ICON, png).unwrap();
    }
}
