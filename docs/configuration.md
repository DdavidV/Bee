# Configuration

Everything that can be configured in Bee: settings, keybindings, the files
they live in, and the environment variables read at startup.

## Where things live

### The configuration folder

`~/.config/bee` by default. Change it with `BEE_CONFIG_DIR`.

| Path | What it is |
|---|---|
| `settings.json` | Your settings |
| `keybindings.json` | Your keybindings |
| `plugins/` | Your plugins, and VS Code extensions you installed |
| `extension-state/` | What VS Code extensions store for themselves, per extension and per folder |
| `recent.json` | Recently opened files of each folder, for Quick Open |
| `token` | The access token for browser mode. Delete it to sign every browser out |
| `secret_key_base` | The secret that signs cookies |

`token` and `secret_key_base` are created on first run and are readable only
by you.

### In a folder you open

| Path | What it is |
|---|---|
| `.bee/settings.json` | Settings for this folder only |
| `.bee/plugins/` | Plugins for this folder only. Loaded only if you allow it, see `plugins.workspace.enabled` |

### In the browser

The sidebar's width, the panel's height, and the order of the activity bar
and panel sections are remembered by the browser, separately for each
folder.

## Settings

Settings files are JSON with comments. `//` and `/* */` comments and
trailing commas are allowed.

Open them from the File menu or the command palette:

- **Preferences: Open User Settings (JSON)** (`Ctrl+,`)
- **Preferences: Open Workspace Settings (JSON)**

A file that does not exist yet is created with every setting listed,
commented out, with its description and default. Uncomment a line and change
it.

Saving applies the change immediately in every window.

### How values are resolved

1. the default of the setting
2. a default given by a plugin
3. your user settings
4. the folder's workspace settings

Later wins. For settings whose value is an object, such as `files.exclude`,
the layers are **merged** rather than replaced: adding one pattern keeps the
defaults, and setting a pattern to `false` switches it off.

Every value is checked against the type and limits of its setting. An
invalid value is ignored, the setting keeps the value from the layer below,
and the problem is counted in the status bar and listed in the Problems
panel. A name Bee does not know is kept
as it is, because the plugin that defines it may simply not be loaded.

### Per-language settings

A block named after a language applies to that language's files only:

```jsonc
{
  "editor.formatOnSave": false,
  "[elixir]": {
    "editor.formatOnSave": true
  },
  "[javascript][typescript]": {
    "editor.tabSize": 4
  }
}
```

A language's value wins over the general one wherever each is set. Between
your block and the workspace's block, the workspace's wins.

At present the per-language values that take effect are the formatter's:
`editor.formatOnSave`, `editor.defaultFormatter`, and `editor.tabSize` as
the formatter is told it.

### Editor

| Setting | Default | Meaning |
|---|---|---|
| `editor.fontSize` | `14` | Font size of the editor in pixels (6–72) |
| `editor.tabSize` | `2` | Number of spaces a tab equals (1–16) |
| `editor.wordWrap` | `"off"` | Whether long lines wrap: `"off"` or `"on"` |
| `editor.lineNumbers` | `"on"` | Whether line numbers are shown: `"on"` or `"off"` |
| `editor.formatOnSave` | `false` | Format a file when it is saved, with a formatter an extension provides for its language |
| `editor.defaultFormatter` | `null` | Which extension formats when several can, by its id (`publisher.name`). Otherwise the one fitting the file best |

### Workbench

| Setting | Default | Meaning |
|---|---|---|
| `workbench.colorTheme` | `"dark"` | The color theme of the workbench, editor and terminal: `"dark"`, `"light"`, or the id of one a plugin or extension contributes |
| `workbench.iconTheme` | `null` | The file icon theme, by id. `null` uses Bee's own icons |
| `workbench.quickOpen.recentFiles` | `10` | How many recently opened files Quick Open lists before you type (0–100) |

Themes can also be picked from a list: **Preferences: Color Theme**
(`Ctrl+K Ctrl+T`) and **Preferences: File Icon Theme**.

### Files

| Setting | Default | Meaning |
|---|---|---|
| `files.exclude` | `**/.git`, `**/.elixir_ls`, `**/.expert` | Glob patterns hidden from the Explorer. Merged with the defaults. Set a pattern to `false` to show it again |
| `files.associations` | `{}` | Glob pattern to language id, for example `{"*.conf": "shellscript"}`. A pattern with a slash matches the path relative to the folder, others the file name. Wins over what languages declare |

Glob patterns: `*` matches anything except `/`, `?` one character except
`/`, `**` anything including `/`, and `{a,b}` alternatives.

### Search

| Setting | Default | Meaning |
|---|---|---|
| `search.exclude` | `{}` | Glob patterns left out of searches, on top of `files.exclude` |
| `search.maxResults` | `20000` | A search stops after this many matches |

### Terminal

| Setting | Default | Meaning |
|---|---|---|
| `terminal.integrated.shell` | `$SHELL`, else `/bin/bash` | The shell new terminals start |
| `terminal.integrated.fontSize` | `13` | Font size of the terminal in pixels (6–72) |

### Plugins and extensions

| Setting | Default | Meaning |
|---|---|---|
| `plugins.disabled` | `[]` | Names of installed plugins not to load. The Plugins view's Enable and Disable buttons edit this |
| `plugins.workspace.enabled` | `false` | Load plugins from the folder's `.bee/plugins`. Plugins run with your permissions, so only enable this for folders you trust. **Only takes effect in user settings**: a folder cannot switch it on for itself |
| `extensions.nodePath` | `"node"` | The Node.js executable that runs the code of VS Code extensions: a name on the `PATH`, or a path |
| `extensions.disabledCode` | `[]` | Names of installed VS Code extensions whose code is not run. Their themes, grammars and settings stay. Their commands and language features do not work |

### Git (built-in plugin)

| Setting | Default | Meaning |
|---|---|---|
| `git.path` | `"git"` | The git executable |
| `git.blame.inline` | `true` | Show who last changed the current line, and when, at its end |
| `git.decorations.gutter` | `true` | Mark added, modified and deleted lines in the editor's gutter |

### Settings from plugins

Plugins and VS Code extensions add their own settings. They appear in the
generated settings file alongside Bee's, are validated the same way, and can
be set per folder. A plugin can also change the default of one of Bee's
settings.

## Keybindings

`keybindings.json` in the configuration folder is a list of entries. Open it
with **Preferences: Open Keyboard Shortcuts (JSON)** (`Ctrl+K Ctrl+S`).
Saving applies it at once.

```jsonc
[
  // bind a key
  {"key": "ctrl+alt+t", "command": "workbench.action.terminal.new"},

  // only in some situations
  {"key": "ctrl+w", "command": "workbench.action.closeActiveEditor", "when": "activeEditor"},

  // remove a default binding
  {"key": "ctrl+b", "command": "-workbench.action.toggleSidebarVisibility"},

  // pass arguments to the command
  {"key": "ctrl+alt+o", "command": "bee.openFile", "args": ["/etc/hosts"]}
]
```

| Field | Meaning |
|---|---|
| `key` | A key, or a chord of two separated by a space: `"ctrl+shift+p"`, `"ctrl+k ctrl+s"` |
| `command` | The command's id. Find ids in the command palette or with the Bee Console's `commands()` |
| `when` | A condition under which the binding applies, see below |
| `args` | What the command receives. A list is its arguments, anything else its single argument |

Rules:

- Your entries come after Bee's and plugins' defaults, and **later entries
  win**.
- A command prefixed with `-` removes earlier bindings of that command. With
  `key` or `when` given, only the bindings that match them are removed.
- Key names are case-insensitive. Modifiers are `ctrl`, `shift`, `alt` and
  `meta` (also written `cmd`, `win` or `super`). `control` and `option` are
  accepted too.
- Keys are matched by physical position, so a binding works the same on any
  keyboard layout.
- A mistake in one entry is listed in the Problems panel and that entry is
  skipped. The rest still apply.

A browser reserves some keys for itself and never lets a page see them.
`Ctrl+W` is the common one, which is why *Close Editor* has no default key.
In the desktop app those keys are free to bind.

### Default keybindings

On macOS, `Ctrl` is `Cmd` for the entries below unless noted.

**General**

| Key | Command |
|---|---|
| `F1`, `Ctrl+Shift+P` | Show All Commands |
| `Ctrl+P`, `Ctrl+E` | Go to File |
| `Ctrl+K Ctrl+O` | Open Folder |
| `Ctrl+S` | Save |
| `Ctrl+,` | Open User Settings |
| `Ctrl+K Ctrl+S` | Open Keyboard Shortcuts |
| `Ctrl+K Ctrl+T` | Color Theme |

**Views**

| Key | Command |
|---|---|
| `Ctrl+B` | Toggle the sidebar |
| `Ctrl+J` | Toggle the panel |
| `Ctrl+Shift+E` | Show Explorer |
| `Ctrl+Shift+F` | Find in Files |
| `Ctrl+Shift+H` | Replace in Files |
| `Ctrl+Shift+X` | Show Plugins |
| `Ctrl+Shift+M` | Show Problems |

**Editing**

| Key | Command |
|---|---|
| `Ctrl+Z` | Undo |
| `Ctrl+Shift+Z` | Redo |
| `Ctrl+Space` | Trigger Suggest (same key on macOS) |
| `Ctrl+K Ctrl+I` | Show Hover |
| `Ctrl+Shift+Space` | Trigger Parameter Hints |
| `Ctrl+.` | Quick Fix |
| `Shift+Alt+F` | Format Document |
| `Ctrl+K Ctrl+F` | Format Selection |
| `F2` | Rename Symbol |

**Navigation**

| Key | Command |
|---|---|
| `F12` | Go to Definition |
| `Ctrl+F12` | Go to Implementations |
| `Shift+F12` | Find All References |
| `Ctrl+Shift+O` | Go to Symbol in Editor |
| `Ctrl+T` | Go to Symbol in Workspace |

**In the Search view**

| Key | Command |
|---|---|
| `Alt+C` | Toggle Match Case (`Cmd+Alt+C` on macOS) |
| `Alt+W` | Toggle Match Whole Word (`Cmd+Alt+W`) |
| `Alt+R` | Toggle Use Regular Expression (`Cmd+Alt+R`) |

**Git plugin**

| Key | Command |
|---|---|
| `Ctrl+Alt+B` | Toggle File Blame |

The language keys only apply when an extension provides that feature for the
file.

## When clauses

A `when` clause is a condition over context keys. It is the same language
VS Code uses.

| Form | Meaning |
|---|---|
| `key` | True when the key has a value that is not empty, zero or false |
| `!expr` | Not |
| `a && b`, `a \|\| b` | And, or. `&&` binds tighter |
| `( … )` | Grouping |
| `key == value`, `key != value` | Equal, not equal. Compared loosely: `2 == '2'` |
| `key < n`, `<=`, `>`, `>=` | Number comparisons |
| `key =~ /regex/flags` | The value matches the regular expression |
| `a in b`, `a not in b` | `b`'s value is a list containing `a`'s value, or an object with that key |
| `true`, `false` | Constants |

Values are bare words or `'single quoted'` strings.

### Context keys

**The active editor**

| Key | Value |
|---|---|
| `activeEditor` | Set when an editor is open and in front |
| `activeEditorIsDirty` | The active file has unsaved changes |
| `editorIsOpen` | Any editor is open |
| `resourceScheme` | `file` for a file, `extension` for a plugin's details page |
| `resourcePath`, `resourceFilename`, `resourceExtname`, `resourceDirname` | Parts of the active file's path |
| `resourceLangId`, `editorLangId` | The active file's language id |
| `canUndo`, `canRedo` | Whether the active file can undo or redo |
| `editorHasSelection` | Text is selected |

**Language features**, true when an extension provides the feature for the
active file: `editorHasDefinitionProvider`, `editorHasDeclarationProvider`,
`editorHasTypeDefinitionProvider`, `editorHasImplementationProvider`,
`editorHasReferenceProvider`, `editorHasRenameProvider`,
`editorHasHoverProvider`, `editorHasCodeActionsProvider`,
`editorHasSignatureHelpProvider`, `editorHasDocumentSymbolProvider`,
`editorHasDocumentFormattingProvider`,
`editorHasDocumentSelectionFormattingProvider`.

**The workbench**

| Key | Value |
|---|---|
| `sideBarVisible`, `activeViewlet` | Whether the sidebar is shown, and which container |
| `panelVisible`, `activePanel`, `panelMaximized` | The same for the panel |
| `terminalCount` | Number of terminals |
| `inQuickOpen`, `menuOpen` | Quick Open or a menu is open |
| `searchHasQuery`, `hasSearchResult`, `searchCaseSensitive`, `searchWholeWord`, `searchRegex` | State of the Search view |
| `explorerCanPaste` | Something was cut or copied in the Explorer |
| `searchMarketplaceExtensions` | The Plugins view is showing search results |

**Focus and platform**, known in the browser, so usable in keybindings

| Key | Value |
|---|---|
| `editorFocus`, `editorTextFocus` | Focus is in the editor |
| `terminalFocus` | Focus is in a terminal |
| `searchViewletFocus` | Focus is in the Search view |
| `inputFocus`, `textInputFocus` | Focus is in a text field |
| `isMac`, `isLinux`, `isWindows`, `isWeb` | The platform of the browser or window |

**In menus only**

| Key | Where |
|---|---|
| `view` | View header and view item menus: the view's id |
| `viewItem` | View item menus: the item's kind, as the plugin named it |
| `explorerResourceIsFolder`, `explorerResourceIsRoot` | The Explorer's right-click menu |

**From plugins.** A plugin can set its own keys, by convention named after
it. The Git plugin sets `git.repository`.

## Environment variables

Read once, when Bee starts.

| Variable | Meaning |
|---|---|
| `BEE_ROOT` | The folder to open. Default: the current directory |
| `BEE_CONFIG_DIR` | The configuration folder. Default: `~/.config/bee` |
| `BEE_MODE` | `server` (default) or `desktop`. The desktop app sets it |
| `BEE_PORT`, `PORT` | The port in browser mode. Default 4000 from source. A release picks a free one |
| `BEE_TOKEN` | A fixed access token instead of the generated one |
| `BEE_ALLOWED_HOSTS` | Extra host names Bee answers to, comma separated, for example for a tunnel |
| `BEE_OPEN_VSX_URL` | The Open VSX server the Plugins view searches and installs from. Default `https://open-vsx.org` |
| `BEE_TARGET_PLATFORM` | Which platform's extension packages to install, for example `linux-arm64`. Default: the one Bee runs on |
| `BEE_RELEASE` | For the desktop app: another Bee release to start |
| `SECRET_KEY_BASE` | Overrides the cookie secret kept in the configuration folder |
| `SHELL` | The default of `terminal.integrated.shell` |
| `RELEASE_DISTRIBUTION` | Releases run without Erlang distribution. Set to `sname` to turn it on, for example to attach a remote shell |

`BEE_PORT`, `BEE_TOKEN` and `BEE_ALLOWED_HOSTS` only matter in browser mode.
The desktop app opens no port and needs no token.

## The desktop app's command line

```
bee-desktop [PATH…]
```

- With no path, the current directory opens.
- A folder opens in its own window, or focuses the window already showing
  it.
- A file opens in the window whose folder contains it, or in a new window
  for the file's folder.
- If the app is already running, the paths are handed to it.

`scripts/install-bee-command.sh` installs a `bee` shell command that does
this in the background. See the [README](../README.md).
