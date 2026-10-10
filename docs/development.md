# Developing Bee

Running Bee from source, checking changes, building releases, and looking
inside a running Bee. The [README](../README.md) has the exact commands and
requirements. This page explains what they do and when to use which.

## Running from source

### In the browser

After the one-time setup, starting the server compiles Bee, builds the page's
scripts and styles, and prints the address to open. While it runs:

- scripts and styles are rebuilt as you edit them;
- changed server code is recompiled on the next request;
- the page reloads itself when templates, components or assets change;
- server logs are also streamed to the browser's console.

Bee opens the current directory, or the one named by `BEE_ROOT`.

A development dashboard with metrics and a view of the running processes is
available at `/dev/dashboard`.

### As the desktop app

Running the desktop app from its folder compiles the checkout first, then
starts Bee from it in desktop mode and opens a window. Compiling first
matters: the app would otherwise start a stale build.

Bee's logs appear in the terminal the app was started from.

### Which to use

Work in the browser when changing the editor itself: reload is faster and
the browser's developer tools are at hand. Use the desktop app when the
change touches what only it has: the bridge, windows, the native folder
dialog, the clipboard, opening links.

## Checking a change

One command runs everything expected before a commit: it compiles with
warnings treated as errors, removes unused dependencies from the lock file,
formats the code and runs the tests.

The tests run against a temporary folder and a temporary configuration
folder, with no token, no file watching and no built-in plugins, so they
never touch your own setup. Open VSX and remote JSON schemas are replaced by
stand-ins, so the tests need no network.

### The desktop self-test

The desktop app can be built to test itself. The first window then drives
Bee's real interface with a script and reports each check:

- the page connected over the bridge;
- a file opened, was edited, showed as unsaved, and was saved;
- *Copy Path* reached the system clipboard;
- the Git plugin showed the change;
- a webview page had an origin of its own;
- a terminal command produced output;
- a folder opened in a second window, opening it again focused that window,
  and the window closed;
- the first window was still alive afterwards.

The app exits with success only if every check passed. Point it at a git
repository containing the file it edits, as the README describes.

This is the test that covers what the unit tests cannot: the real webview,
the real pipes, the real windows.

## Releases

A **web release** is a self-contained build of Bee: it brings its own
runtime and needs neither Elixir nor Erlang installed where it runs. When
started it picks a free port and prints its address.

A **desktop release** is the web release plus the desktop app, which starts
that release in desktop mode. For now the app looks for the release where
the build put it, beside the checkout. `BEE_RELEASE` points it at another.

Releases do not use Erlang distribution. Stop one with `Ctrl+C` or by
sending it a termination signal.

The install script adds a `bee` shell command that starts the desktop app in
the background, or hands the folder to the app if it is already running, and
registers the app with the desktop so that it has an icon and a menu entry.

## The Bee Console

*Developer: Open Bee Console* opens an Elixir shell in the panel, beside the
terminals. Unlike a terminal, it runs **inside Bee**. Whatever you type is
evaluated in the running editor.

It works the same in the browser and the desktop app, because it travels
over the window's own connection. Nothing extra is opened for it, which
matters in the desktop app where there is no port to attach a remote shell
to.

It behaves like a shell: line editing, history, tab completion, expressions
that continue over several lines, and `Ctrl+C` to stop one that is running.
Variables, aliases and imports carry over from one expression to the next.

Beyond plain Elixir, it has helpers for looking at and driving Bee:

| Helper | Shows or does |
|---|---|
| `help()` | Lists the helpers |
| `commands()`, `commands("term")` | Every command with its title and key, or those matching |
| `run(id)`, `run(id, args)` | Runs a command in this window, as if you had |
| `window()` | This window's state: folder, editors, panel |
| `root()` | This window's folder |
| `workspaces()` | The open folders |
| `plugins()` | The plugins of this folder and their status |
| `grammars()`, `grammars("erlang")` | Who contributes each language's highlighting and which one is used |
| `features()`, `features("grammars")` | What each plugin contributes, whether it is in effect, and what Bee does not support yet |
| `memory()` | Bee's memory, CPU time and process count |

It is the quickest way to answer questions such as *why is this grammar not
used?*, *is my plugin running in this folder?* and *what is this command's
id?*

The console belongs to the window that opened it and stops with it.

## Working on plugins

Plugin development needs no build step and no restart. See
[Plugins](plugins.md#developing).

## Where Bee's own behaviour is declared

Much of what looks built in is data, checked when Bee is compiled:

- Bee's commands, default keybindings, menus, views and themes are in a
  contributions manifest, in the same format plugins use.
- The built-in languages and their highlighting are in another.
- The schemas for settings, keybindings and manifests define what is valid
  and supply defaults and descriptions.

A mistake in any of these fails the build rather than the next start. Adding
a command to Bee means declaring it there and writing its handler. The two
are checked against each other: a declared server command without a handler,
or a handler without a declaration, is an error.

The same rule holds for anything new that Bee itself needs: add it as a
contribution, not as a special case, so that plugins can do the same.

## Tunable internals

A few values are not user settings but can be set in the application's
configuration, mostly for tests:

| Value | Default | Meaning |
|---|---|---|
| Plugin callback timeout | 10 seconds | How long a plugin command or callback may run |
| Workspace idle time | 10 seconds | How long a folder stays open after its last window closed |
| File watching | On | Off in tests, which simulate change notices |
| Built-in plugins | On | Off in tests |

## Platforms

Bee runs on Linux and macOS. Windows support is planned. The desktop app and
the bridge already account for how Windows' webview names custom address
schemes.
