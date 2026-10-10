# Architecture

This page describes the parts of Bee and how work flows between them. It is
about behaviour, not source layout.

## The big picture

```
   browser tab                 desktop window
        │  HTTP + WebSocket          │  frames over stdin/stdout
        │  (127.0.0.1, token)        │  (no port)
        └──────────────┬─────────────┘
                       ▼
┌──────────────────────────── Bee ─────────────────────────────┐
│                                                              │
│   windows ─── one per tab or desktop window                  │
│      │                                                       │
│   workspaces ─── one per open folder, shared by its windows  │
│      │                                                       │
│   buffers · terminals · search · settings · keybindings      │
│   contributions (commands, menus, languages, themes, views)  │
│   plugins ─── one copy of each per workspace                 │
│                                                              │
└───────┬───────────────────┬──────────────────────┬───────────┘
        ▼                   ▼                      ▼
   shells in a pty     Node.js extension      the file system,
   (terminals)         host, one per          git, Open VSX
                       workspace
```

Bee is one program that keeps running while windows come and go. A window
holds very little of its own. It shows what Bee tells it to and reports what
the user does.

## Two ways to reach Bee

Bee starts in one of two modes.

- **Server mode** (the default). Bee listens on the local machine only and
  prints an address containing a token. Opening it in a browser trades the
  token for a cookie.
- **Desktop mode.** The desktop app starts Bee as a child process and talks
  to it over its standard input and output. No port is opened.

The editor is the same in both. The differences are confined to how the page
and its live connection are carried, described in
[LiveView without a web server](desktop-bridge.md).

## Windows

A window is one LiveView. It keeps the state of what the user sees: which
editors are open and which is in front, whether the sidebar and the panel
are shown and how large they are, the terminals, the open menu, the command
palette, the search.

Two rules shape how a window works.

**Every action is a command.** A menu item, a button, a keybinding, a
palette entry and a right-click entry all do the same thing: they run a
command by its id. There is one path in, so a command behaves the same
however it was reached, and a plugin's command is no different from one of
Bee's.

**State changes and side effects are separate.** A command computes the
window's next state and, if something has to happen outside it, a list of
effects: open this file, start a terminal, send this to the browser, run this
plugin command. The window then carries the effects out. This keeps the
window's logic easy to reason about and test.

Layout that belongs to a person rather than to Bee, such as the sidebar's
width, the panel's height and the order of the activity bar, is kept by the
browser, per folder. It is sent along when the window connects, so the first
frame already has the right sizes.

## Workspaces

A workspace is an open folder. Several can be open at once. Each window
shows one, and several windows may show the same one.

A workspace starts when the first window opens its folder and ends a few
seconds after the last one closes it. While it is open:

- its files are watched for changes on disk;
- its own settings file is layered over the user's settings;
- plugins and extensions run for it.

The folder Bee was started for is the default. A window may name another in
its address, which is how *Open Folder* and the desktop app's extra windows
work.

## Files and text

Text lives in two places at once, and the flow between them is the heart of
the editor.

```
  typing                                         a plugin or extension edits
    │                                                       │
    ▼                                                       ▼
┌─────────┐   whole text, throttled    ┌───────────────────────────┐
│ editor  │───────────────────────────▶│ buffer                    │
│ in the  │                            │ (one per open file,       │
│ browser │◀───────────────────────────│  shared by every window)  │
└─────────┘   edits, as ranges         └─────────────┬─────────────┘
                                                     │ announces: opened, changed,
                                                     │ saved, reloaded, closed
                                                     ▼
                                        plugins · extensions · search ·
                                        diagnostics · other windows
```

- **In the browser**, each open file has its own editor state: the document,
  the selection and the undo history. Switching tabs swaps the state into
  the single editor view, so nothing is lost and nothing is rebuilt.
- **In Bee**, each open file has a buffer. It holds the latest text and the
  text last known to be on disk. The file is unsaved when they differ.

As the user types, the browser sends the text to the buffer, throttled. When
something inside Bee edits the file, such as a plugin, a formatter or a
rename, the buffer sends the edit to every editor showing that file, where it
becomes an ordinary undoable change.

Before any command runs, pending text and selections are flushed, so a
command always sees what the user sees.

A buffer exists while at least one window has the file open. If the file
changes on disk while it has no unsaved changes, the buffer reloads it and
the editors follow.

Everything that needs the current text reads the buffer, not the disk. Search
finds matches in unsaved text. Plugins read unsaved text. Extensions are
sent every change.

Two ways of counting positions meet here. Bee counts bytes of UTF-8, the
browser's editor and VS Code extensions count UTF-16 units. Positions are
converted at the boundary.

## Contributions

Bee does not have a built-in list of commands, menus or languages. It has a
registry of **contributions**, filled from manifests.

```
 Bee's own manifests ─┐
 built-in plugins ────┤     validate      each kind of         check for
 user plugins ────────┼──▶  against the ─▶ contribution   ─▶   clashes with  ─▶  registry
 workspace plugins ───┤     schema         checks its part     other sources
 VS Code extensions ──┘
```

A manifest declares, among other things:

- commands, their titles, icons and when they are enabled
- keybindings
- the menu bar, menus, and right-click menus
- views and the containers that hold them, in the activity bar or the panel
- settings and their defaults
- languages and how to highlight them
- color themes and file icon themes
- snippets and JSON schemas

Bee's own interface is declared this way, in the same format plugins use.
The File menu, the Explorer, the terminal panel and the default keybindings
are all contributions. Nothing is reserved: whatever Bee can add to itself, a
plugin can add too.

Registration is all or nothing. A manifest that is invalid, or that clashes
with another source (the same command id, the same setting name, the same
view id), is rejected as a whole, with a message naming the problem.

When contributions change because a plugin was installed, removed, enabled
or edited, everything that depends on them is told and updates in place:
windows redraw their menus, keybindings are resolved again, settings are
validated again.

## Commands

A command has an id, a title and a **runtime** that says where it runs.

| Runtime | Runs in | Typical use |
|---|---|---|
| `server` | Bee | Anything that changes the window, the workspace or files |
| `client` | The browser | Anything that needs the editor directly: undo, clipboard, save |
| `extension` | The Node.js extension host | Commands a VS Code extension registers |

```
 keybinding ─┐
 menu ───────┤
 palette ────┼──▶ run command ──┬─ Bee's own server command ──▶ new window state + effects
 button ─────┤                  ├─ plugin's server command ───▶ the plugin's process in this workspace
 right-click ┘                  ├─ client command ────────────▶ the browser
                                └─ extension command ─────────▶ the workspace's extension host
```

A plugin's command does not return a result to the window. The plugin acts
by asking for things: show a message, open a file, fill a view. Those
requests go to the window that ran the command, or to every window of the
workspace when no particular window is involved.

### When clauses and context

Whether a command is enabled, whether a menu item is shown, whether a view
is visible and whether a keybinding applies are all decided by **when
clauses**, the same small expression language VS Code uses, evaluated
against a set of context keys.

The context has two halves.

- **What Bee knows**: the active file and its language, whether there are
  unsaved changes, what is visible, how many terminals exist, the state of
  the search, and keys that plugins set.
- **What only the browser knows**: where the keyboard focus is and which
  platform it is on.

Menus and the palette are evaluated in Bee. Keybindings are evaluated in the
browser, at the moment of the key press, with Bee's half of the context sent
along with the page. A key press therefore never waits for a round trip to
decide what it means.

The full list of keys is in [Configuration](configuration.md#context-keys).

### Keybindings

Bee resolves the active keybindings in one place: the contributed defaults
first, then the user's file on top. The result is sent to the browser, which
matches key presses against it.

Keys are matched by their physical position rather than by the character
they produce, so bindings behave the same on any keyboard layout. Chords,
such as `ctrl+k ctrl+s`, are supported.

## Settings

Settings are layered:

```
 defaults from the schema
        ▲ overridden by
 defaults contributed by plugins
        ▲ overridden by
 the user's settings file
        ▲ overridden by
 the workspace's settings file
        ▲ overridden, per language, by
 language blocks in either file
```

Every value is checked against the schema of its setting. An invalid value
does not break anything: that one setting falls back to the layer below, and
the problem is listed in the Problems panel.

The settings files are watched. Saving one applies it at once, in every
window, and plugins and extensions are told.

Details are in [Configuration](configuration.md).

## Languages

A language is known by its id. The id ties together detection,
highlighting, when clauses, per-language settings, snippets and the features
extensions provide.

**Detection** works like VS Code's. The first match wins: the user's file
associations, then exact file names, then file name patterns, then
extensions, then the file's first line, then plain text.

**Highlighting** comes in two kinds, and the last one contributed for a
language wins.

- An editor mode that runs natively in the browser's editor. Bee bundles
  modes for its built-in languages, and a plugin can register more.
- A TextMate grammar, the format VS Code uses. These run in the browser
  with the same grammar engine VS Code uses, coloured by the color theme's
  token rules. What is on screen is tokenized first and the rest when the
  browser is idle, so typing never waits for highlighting.

**Language features** such as completion, hover, go to definition,
references, rename, formatting, code actions, signature help and symbols
are not built into Bee. They come from VS Code extensions, whose code runs
in a Node.js process beside Bee. The editor only asks for a feature when an
extension has said it provides it for that file. See
[VS Code extensions](vscode-extensions.md).

**Problems** found by extensions are kept per workspace and file. The editor
underlines them, the status bar counts them, and the Problems panel lists
them.

**JSON** is the exception: validation, completion and hover for JSON files
against a JSON Schema are built in, driven by schemas that plugins and
extensions contribute. Bee's own settings, keybindings and plugin manifests
are checked the same way.

## Themes

A **color theme** is a file in VS Code's format. Bee turns its colors into
CSS variables with VS Code's names, which the whole interface uses: the
workbench, the editor, the terminal, plugin views and extension webviews.
Colors a theme leaves out take VS Code's defaults for a dark or light
theme.

A **file icon theme** is also VS Code's format. It decides the icon of a
file or folder by name, extension and language, in the Explorer, on tabs and
in views.

Both are picked by a setting and switch live.

## The panel

**Terminals.** Each terminal tab is a real shell running in a pseudo
terminal, owned by the window that opened it. Its output is broadcast to the
window and also kept in a bounded scrollback. A terminal view that attaches
late, for example after the panel was hidden, first replays the scrollback
and then continues with live output, skipping what it has already seen. A
terminal ends with its window.

**Bee Console.** An Elixir shell running inside Bee itself, shown like a
terminal. It is for looking into Bee and driving it. See
[Developing Bee](development.md#the-bee-console).

**Output.** What extensions write for the user to read, in named channels,
plus an *Extension Host* channel with what extensions print and their
failures. Only the most recent part of each channel is kept.

**Problems** and **References** list what language extensions found.

Plugins can add panel sections of their own.

## Search and Quick Open

**Search** runs outside the window, reading and matching files in parallel
and sending results back in batches, so results appear as they are found and
the window stays responsive. Files that are open are searched with their
unsaved text. Large and binary files are skipped. A new search drops the
results of the previous one.

**Quick Open** lists the workspace's files in the background. In a git
repository it asks git, so ignored files are left out. Otherwise it walks
the folder. Each batch of names is matched against the current query as it
arrives. Typing faster than it can answer skips straight to the latest
query. Its prefixes switch what it searches: `>` for commands, `@` for
symbols in the file, `#` for symbols in the workspace.

## Watching the file system

Bee watches two kinds of places: its own configuration folder, and the
folder of every open workspace. One stream of change notices feeds
everything that cares:

- settings and keybindings reload when their files change;
- a plugin reloads when its folder changes;
- the Explorer refreshes;
- unmodified open files reload;
- plugins and extensions that asked are told.

## How news travels

Parts of Bee do not call each other to announce changes. They publish, and
whoever is interested subscribes. Most topics are per workspace, so a window
only hears about its own folder.

This is what makes several windows on one folder behave as one editor: a
file saved in one window loses its unsaved mark in the other, a plugin's
view updates everywhere, a setting change reaches every window.

It also keeps the parts loosely coupled. A plugin learns that a file was
saved the same way a window does.

## Reads are cheap

The things asked for constantly, such as settings, keybindings,
contributions, plugin state and what plugins put on screen, are kept where
any part of Bee can read them directly without waiting in line behind
anything else. Only changes go through a single owner, which keeps them
consistent.

## Processes beside Bee

Bee starts other programs, and takes care that they see the user's
environment rather than Bee's own.

- **Shells**, one per terminal.
- **Node.js**, one extension host per workspace that has an active VS Code
  extension. Language servers are started by extensions, from there.
- **git**, by the built-in Git plugin.

When Bee runs from a release, the variables and paths that belong to its
own runtime are removed from the environment these programs inherit.
Otherwise a tool such as `elixir` started in a terminal would try to boot
as Bee.

## Failure and recovery

The parts are isolated so that one failing does not take the rest down.

- A plugin command that is slow or crashes is stopped and reported. The
  plugin keeps running with the state it had before.
- A plugin whose process crashes is restarted, a limited number of times a
  minute, then marked as failed.
- The extension host exiting restarts the extensions that ran in it, with
  the same limit.
- A plugin's own LiveView is nested in the window as a separate process. If
  it crashes, the window stays.
- A terminal, a search and each open file are each on their own.

## What it is built with

| Layer | Technology |
|---|---|
| Server | Elixir, Phoenix, Phoenix LiveView |
| Web server (browser mode) | Bandit |
| Editor | CodeMirror 6 |
| Terminal | xterm.js, with shells run through erlexec |
| TextMate grammars | vscode-textmate with Oniguruma (WebAssembly) |
| Styles | Tailwind CSS with daisyUI |
| Desktop shell | Tauri (Rust) and the system webview |
| VS Code extensions | Node.js |
