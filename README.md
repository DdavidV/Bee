# Bee

A code editor built on Phoenix LiveView. Use it in your browser, or as a
desktop app.

## Requirements

- Elixir 1.17+ and Erlang/OTP 26+
- Git
- Linux or macOS (Windows support is planned)

To run the code of VS Code extensions (optional: their themes, grammars,
keybindings and settings work without it):

- [Node.js](https://nodejs.org) 20+, on the `PATH` or named by the
  `extensions.nodePath` setting

For the desktop app, also:

- [Rust](https://rustup.rs)
- Your system's webview and build tools: see
  [Tauri's prerequisites](https://tauri.app/start/prerequisites/)
  (on Ubuntu, including WSL2, that's the `apt install` line there)

## Getting started

```sh
mix setup
mix phx.server
```

Open the address Bee prints (`http://127.0.0.1:4000/?token=…`). After the
first visit, `http://127.0.0.1:4000` is enough. Bee opens the current folder,
or `BEE_ROOT`.

## Desktop app

```sh
cd desktop
cargo run -- /path/to/folder
```

This starts Bee and opens the folder in a window. Bee and its windows talk
over stdin/stdout, so no port is opened.

Each folder gets its own window: File → Open Folder in New Window…, or
start the app again with another folder, which hands it to the running app
instead of starting a second Bee. File → Open Folder… shows the system's
folder dialog. Closing the last window stops Bee.

## Web release

Release:

```sh
mix bee.release
```

Start:

```sh
BEE_ROOT=/path/to/folder _build/prod/rel/bee/bin/bee start
```

It prints the address to open, on a free port.

## Desktop release

Release:

```sh
mix bee.release.desktop
```

Start:

```sh
desktop/target/release/bee-desktop /path/to/folder
```

The app starts the release built by `mix bee.release.desktop`
(`_build/prod/rel/bee`) in desktop mode: no port, only the window talks to
it.

### The `bee` command

```sh
scripts/install-bee-command.sh
```

Adds a `bee` shell function to `~/.bashrc` / `~/.zshrc` (and builds the
desktop release if there is none), and installs Bee's desktop entry and
icon in `~/.local/share`, so the taskbar shows Bee's logo and app menus
list Bee. In a new terminal:

```sh
bee .          # this folder
bee ~/project  # another one
```

The app starts in the background, or opens the folder in a new window of
the running app. Its output goes to `~/.local/state/bee/desktop.log`.
Remove the function with `scripts/install-bee-command.sh --uninstall`.

## Tests

```sh
mix precommit
```

The desktop app has a self-test that drives its window. It opens, edits and
saves `lib/a.ex`, checks the git plugin, and runs a terminal command, so
point it at a git repository with that file:

```sh
cd desktop
cargo run --features selftest -- /path/to/repo
```

## Reference

**Environment variables**

| Variable | Meaning |
|---|---|
| `BEE_ROOT` | The folder to open (default: the current directory) |
| `BEE_CONFIG_DIR` | Where settings, keybindings, plugins, the token and the secret live (default `~/.config/bee`) |
| `BEE_PORT` / `PORT` | The browser mode's port (default 4000; a release picks a free one) |
| `BEE_TOKEN` | A fixed access token instead of the generated one |
| `BEE_OPEN_VSX_URL` | The Open VSX server the Plugins view searches and installs from (default `https://open-vsx.org`) |
| `BEE_TARGET_PLATFORM` | Which platform's packages to install from Open VSX, e.g. `linux-arm64` (default: the one Bee runs on) |
| `BEE_ALLOWED_HOSTS` | Extra host names Bee answers to, comma separated (e.g. for a tunnel) |
| `BEE_MODE` | `server` (default) or `desktop`; the desktop app sets it |
| `BEE_RELEASE` | Another release for the desktop app to start (`…/bin/bee`) |

**Access.** In the browser Bee only listens on `127.0.0.1` and needs its
token. The token is kept in `~/.config/bee/token`; delete it to sign out
every browser. The cookie secret (`secret_key_base`) is in the same folder;
`SECRET_KEY_BASE` overrides it.

**Releases** don't run Erlang distribution. Stop one with Ctrl+C or SIGTERM,
or set `RELEASE_DISTRIBUTION=sname` to use `bin/bee remote`.
