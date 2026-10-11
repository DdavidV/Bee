//! What a page asks of the app (src/commands.rs).

use bee_desktop::commands::{is_web_link, socket_id};

#[test]
fn a_socket_id_is_unique_among_the_windows() {
    assert_eq!(socket_id("w2", "s1"), "w2:s1");
    assert_ne!(socket_id("w1", "s1"), socket_id("w2", "s1"));
}

#[test]
fn only_http_links_are_for_the_browser() {
    assert!(is_web_link("https://example.com/readme"));
    assert!(is_web_link("http://example.com"));

    for url in [
        "file:///etc/passwd",
        "javascript:alert(1)",
        "bee://localhost/",
        "mailto:a@example.com",
        " https://example.com",
        "HTTPS://example.com",
        "example.com",
        "",
    ] {
        assert!(!is_web_link(url), "{url:?}");
    }
}
