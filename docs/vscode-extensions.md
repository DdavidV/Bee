# VS Code extensions

Bee can install extensions made for VS Code and use a large part of what
they offer: themes, icons, grammars, snippets, settings, commands, and
language features such as completion and go to definition.

An installed extension is a plugin like any other. It appears in the Plugins
view, can be enabled, disabled and uninstalled, and contributes through the
same registry. See [Plugins](plugins.md) for that side. This page covers
what is specific to extensions.

## Requirements

An extension's themes, grammars, snippets, keybindings and settings need
nothing extra.

To run an extension's **code**, which is what provides commands and
language features, Bee needs [Node.js](https://nodejs.org) 20 or later,
either on the `PATH` or named by the `extensions.nodePath` setting. Without
it the extension still loads, and its code is reported as unable to start.

## Installing

### From Open VSX

Open the Plugins view (`Ctrl+Shift+X`) and type in the search box. The
Installed and Built-in lists give way to results from
[Open VSX](https://open-vsx.org), the open extension registry. Each result
has an Install button, or Update when a newer version than the installed one
exists. Clicking a result opens its details page with its README.

Bee installs the package for the platform it runs on, which matters for
extensions that ship native programs. If there is none for the platform it
takes the universal package, and if the latest version has neither, the
newest version that does.

Bee is careful with the registry, which limits requests by address:

- answers are cached, searches for ten minutes and extension details for an
  hour;
- identical requests made at the same time are sent once;
- Bee limits itself to a fixed number of requests a minute, and past that
  fails at once without touching the network;
- when the registry says to slow down, Bee stops asking until the time it
  gave has passed.

A different registry can be used with `BEE_OPEN_VSX_URL`, and a different
platform with `BEE_TARGET_PLATFORM`.

### From a file

**Plugins: Install from VSIX…**, also a button in the Installed view's
header, takes a `.vsix` file from your machine.

### What installing does

The package is unpacked into your plugins folder, under the extension's
name, with a small marker recording that it is a VS Code extension and where
it came from. Installing again replaces an extension that was installed this
way, which is how updates work. It never replaces a folder of another kind,
or a different extension that happens to share the name.

Packages are checked before unpacking: one that is unreasonably large, has
too many files, or contains paths that would land outside its folder is
refused.

## What Bee uses

Bee reads the extension's own `package.json` each time the plugin loads.
Nothing is converted at install time. As Bee learns to use more of what
extensions declare, extensions already installed benefit without being
installed again.

| Declared by the extension | In Bee |
|---|---|
| Commands, keybindings, menus, submenus | Yes |
| Settings and default overrides | Yes |
| Color themes | Yes |
| File icon themes | Yes, for themes made of image files. Icon font themes fall back to Bee's icons |
| Languages and language configuration | Yes |
| TextMate grammars, including embedded and injected ones | Yes |
| Snippets | Yes |
| JSON schema associations | Yes |
| Localized texts (`%key%`) | Resolved from the extension's default language file |
| Anything else | Ignored for now |

Reading is **lenient**. A plugin's own manifest is rejected for a single
mistake, but an extension was not written for Bee. An entry Bee cannot use,
such as one pointing at a missing file or using a value Bee does not know,
is left out with a warning and the rest of the extension loads.

The plugin's details page has a Features tab listing everything the
extension contributes and whether each item is in effect.

## Running the extension's code

### The extension host

An extension's code expects to run in Node.js with VS Code's programming
interface available. Bee provides both.

```
┌───────────── Bee ─────────────┐         ┌──────── Node.js ────────┐
│                               │         │  extension host         │
│  workspace  ◀────────────────▶│ messages│                         │
│   settings, open files,       │◀───────▶│  Bee's own "vscode"     │
│   active editor, file changes │         │  module                 │
│                               │         │      ▲          ▲       │
│  windows                      │         │  extension  extension   │
│   messages, pick lists,       │         │      A          B       │
│   edits, status bar           │         │                 │       │
└───────────────────────────────┘         └─────────────────┼───────┘
                                                            ▼
                                                     language server
                                                 (started by the extension)
```

- There is **one host per open folder**, started when the first extension
  becomes active there. All of that folder's extensions share it.
- Each extension is given its own copy of the programming interface, so Bee
  knows which extension registered what.
- The host and Bee exchange messages over the host's standard input and
  output, the same way the desktop app talks to Bee.

To the extensions, Bee plays the part of the editor:

- it sends the **settings** at the start and whenever they change;
- it sends the text of **open files** as they change, so the extension can
  read a document without waiting;
- it reports the **active editor** and its selections, taken from the window
  that last ran a command or changed editor;
- it reports **file changes** on disk while an extension is watching for
  them.

And Bee carries out what extensions ask: show a message, offer a pick list
or an input box in a window and return the answer, edit files, change a
setting, set a context key, show a status bar item, run a command.

### When code starts

As with plugins, declaring is immediate and running is lazy. An extension's
code starts in a folder on its activation events: with the folder, when the
folder contains a matching file, when a file of one of its languages is
opened, when one of its commands is run, or when one of its views is shown.
An extension that declares a language is started for that language's files
even if it did not say so.

An extension that depends on others starts after them, and only when they
are installed and their code runs.

### What the programming interface covers

| Area | Supported |
|---|---|
| Commands | Registering and running commands, including Bee's own |
| Messages | Information, warning and error messages with buttons, pick lists, input boxes, progress |
| Editors and documents | The active editor, open documents, reading and editing text, opening files |
| Configuration | Reading and updating settings, change notifications |
| Workspace | The folder, finding files, file watchers, edits spanning several files |
| Status bar | Items |
| Output | Output channels |
| Context | Setting context keys |
| Extension state | Global and per-folder state and storage folders |
| Languages | See below |
| Webview panels | See below |
| Opening links | In the user's browser |

**Anything else is a stand-in.** The interface is large, and extensions call
parts of it Bee does not have. Rather than fail, an unknown part behaves as
an object that accepts any use and does nothing. The extension keeps
running, and Bee notes what it reached for. Those notes are listed as
warnings on the plugin's details page, so it is clear what an extension
wanted that Bee could not give it.

### Language features

An extension registers providers for the languages it supports. Bee keeps
track of which features exist for which files, and the editor asks only
when there is something to answer. These reach the editor:

| Feature | In the editor |
|---|---|
| Completion | Suggestions as you type and with `Ctrl+Space`, with details resolved on demand |
| Hover | `Ctrl+K Ctrl+I` or the mouse |
| Signature help | `Ctrl+Shift+Space` |
| Definition, declaration, type definition, implementation | `F12`, `Ctrl+F12`, the right-click menu |
| References | `Shift+F12`, listed in the References panel |
| Document highlights | Other occurrences of the symbol under the cursor |
| Document symbols | `Ctrl+Shift+O`, or `@` in Quick Open |
| Workspace symbols | `Ctrl+T`, or `#` in Quick Open |
| Code actions | `Ctrl+.` |
| Rename | `F2`, applied across files |
| Formatting | Document and selection, and on save with `editor.formatOnSave` |
| Diagnostics | Underlined in the editor, counted in the status bar, listed in the Problems panel |

Other kinds of provider can be registered without error but have no effect
yet.

When several extensions can format a file, `editor.defaultFormatter` picks
one. Otherwise the one that fits the file best is used.

Edits that span several files, such as a rename, are applied to open files
as undoable changes and to the others on disk.

**Language servers.** Bee has no language server client of its own. Most
VS Code language extensions start a language server themselves and connect
it to the editor through the providers above. Because Bee supplies those
providers and the workspace services a language client relies on, such
extensions work and bring their servers with them.

### Webview panels

An extension can show a page of its own HTML in an editor tab, for example a
preview. Bee shows these in a sandboxed frame.

The page gets what it expects from VS Code: the color theme as CSS
variables, a body class saying whether the theme is light or dark, VS
Code's default styles, and the messaging object for talking to its
extension, including state that survives a reload. Links to the web open in
the user's browser. Key presses with a modifier are passed on to Bee, so
Bee's keybindings keep working while the focus is in the page.

The page may only load local files from the folders its extension allowed.

How these pages are kept apart from Bee's own is described in
[Security and access](security.md#webview-pages).

### Output and failures

What extensions print, and their failures, go to the **Extension Host**
channel of the Output panel. Channels an extension creates, such as a
language server's log, appear there too.

If the Node.js process exits, the extensions that were running in it are
started again in a new one, up to three times a minute.

### Turning code off

`extensions.disabledCode` lists extensions whose code is not to run. Their
themes, grammars, snippets and settings stay in effect. Their commands and
language features do not work. This is useful for an extension wanted only
for its grammar or theme.

Disabling the plugin entirely, from the Plugins view, removes all of it.

## One package for VS Code and Bee

An extension can carry Bee-specific parts in a `bee` section of its
`package.json`. VS Code ignores the section. Bee reads it and adds a server
part, a browser part, a stylesheet, and views and editors drawn by Bee:

```json
"bee": {
  "server": {"module": "MyExt"},
  "browser": "bee/browser.js",
  "contributes": {
    "editors": [{"id": "myExt.board", "title": "Board", "live": "MyExt.BoardLive"}]
  }
}
```

One package then works in both editors, with the richer integration in Bee.

## Limits worth knowing

- Only what the tables above list is used. Tree views, custom editors,
  debuggers, tasks, notebooks, source control providers and terminals
  created by extensions are not available. An extension built mainly around
  one of those will load and do little.
- Icon themes that use an icon font are not drawn.
- Per-language default overrides declared by an extension are read but not
  applied yet.
- Extensions run with your permissions, as in VS Code. See
  [Security and access](security.md).
