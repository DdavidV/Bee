# Plugins

A plugin adds to Bee: commands, keys, menus, views, settings, languages,
themes, and code that runs in Bee or in the browser. The built-in Git
support is a plugin, written against the same interface described here.

This page has two halves: how plugins work, and a guide to writing one.

VS Code extensions are also loaded as plugins. They are covered in
[VS Code extensions](vscode-extensions.md).

## How plugins work

### What a plugin is

A plugin is a folder with a manifest, `plugin.json`. The manifest says what
the plugin contributes and names the code it brings. Everything but the
manifest is optional.

```
my-plugin/
  plugin.json        the manifest
  lib/               server part: Elixir sources
  src/               server part: Erlang sources
  browser.js         browser part
  style.css          stylesheet for the plugin's own views
  README.md          shown on the plugin's details page
```

A plugin can have up to three kinds of code.

| Part | Runs in | Written in | Good for |
|---|---|---|---|
| Server part | Bee | Elixir or Erlang | Files, processes, the workspace, filling views, anything with state |
| Browser part | The page | JavaScript | The editor itself: decorations, hovers, highlighting, editor commands |
| LiveViews | Bee, drawn in the page | Elixir with HEEx templates | The plugin's own interface, in a view or an editor tab |

A plugin with no code at all is valid: a theme, a language definition or a
set of snippets needs only a manifest and its data files.

### Where plugins come from

| Location | Scope |
|---|---|
| Shipped with Bee | Built-in. Always present. Cannot be uninstalled, but can be disabled |
| `plugins/` in the configuration folder | Yours. Available in every folder you open |
| `.bee/plugins/` in an opened folder | That folder only, and only if you set `plugins.workspace.enabled` in your user settings |

Workspace plugins are off by default because plugins run with your
permissions. Opening someone else's repository must not run their code. The
switch only works from your own settings, so a repository cannot enable it
for itself.

Two plugins cannot share a name, and two plugins cannot contribute the same
command, setting, view or container id.

### From folder to running plugin

```
 found on disk
      │
      ▼
 manifest read and checked ──── invalid ──▶ listed as invalid, with the reason
      │
      ▼
 disabled in settings? ──── yes ──▶ listed as disabled, contributes nothing
      │ no
      ▼
 contributions registered ───── clash ──▶ rejected, with the reason
      │
      │   menus, keys, settings, languages and themes are live.
      │   No plugin code has run yet.
      ▼
 something activates it in a folder
      │
      ▼
 code compiled and loaded, the plugin starts for that folder
```

**Contributions come first, code later.** As soon as a plugin is found, what
its manifest declares is in effect: its commands are in the palette, its
keys are bound, its views have their place. Its code does not run until it
is needed.

**Activation is lazy and per folder.** The server part starts in a folder
when:

- the manifest asks to start with the folder (`*` or `onStartupFinished`);
- the folder contains a file matching a `workspaceContains:` pattern;
- a file of a language named by `onLanguage:` is opened;
- one of the plugin's commands is run;
- one of its views is shown.

The last two always apply, whatever the manifest says.

**One copy per open folder.** With two folders open, a plugin runs twice,
each copy with its own state and each seeing only its own folder: that
folder's files, settings, open files and windows. What a copy puts on screen
appears in the windows of its folder. The compiled code is shared.

**The browser part loads with the page**, in every window of a folder where
the plugin is usable, and is unloaded again when the plugin goes away.
Everything it registered is undone.

### While it runs

- Commands of a plugin run one at a time, each with a time limit of ten
  seconds. One that takes too long or fails is stopped, the user is told,
  and the plugin carries on with the state it had before.
- If the plugin's process itself crashes it is restarted, up to three times
  a minute. After that it is marked as failed in that folder.
- When a file in the plugin's folder changes, the plugin is reloaded:
  stopped, its contributions replaced, its code compiled again when next
  needed. Editing a plugin and saving is enough to try the change.
- **Developer: Reload Plugins** reloads all of them.

### Managing plugins

The Plugins view (`Ctrl+Shift+X`) lists the installed and built-in plugins
with their state. From there a plugin can be enabled, disabled or
uninstalled. Disabling writes its name to `plugins.disabled` in your
settings. Uninstalling deletes its folder from your plugins folder. If that
folder is a link to somewhere else, only the link is removed.

Clicking a plugin opens its details page: the README, what it contributes,
whether each contribution is in effect, and any problems.

### Trust

Plugins are trusted code. A server part runs inside Bee with everything Bee
can do, and a browser part runs in Bee's page. There is no sandbox. Bee
checks for accidents, such as a plugin defining a module that already
exists, but not for malice. Install only what you would be willing to run as
a program.

---

## Writing a plugin

The examples in this guide are complete plugins in
[`examples/plugins`](../examples/plugins). To try them, link them into your
plugins folder and run **Developer: Reload Plugins**:

```sh
mkdir -p ~/.config/bee/plugins
ln -s "$PWD"/examples/plugins/* ~/.config/bee/plugins/
```

### 1. Start with the manifest

```json
{
  "$schema": "../../../priv/schemas/manifest.schema.json",
  "name": "word-count",
  "displayName": "Word Count",
  "description": "Counts the words of the active file or selection.",
  "version": "0.1.0",
  "contributes": {}
}
```

`name` and `contributes` are required. The name is the plugin's identity:
lowercase letters, digits and dashes.

Pointing `$schema` at Bee's manifest schema gives you completion,
descriptions and validation while you write the manifest, in Bee itself.
The schema is the precise reference for everything below.

Other fields describe the plugin on its details page: `publisher`,
`license`, `repository`, `homepage`, and `icon`, an image in the plugin's
folder.

A mistake in the manifest rejects the whole plugin. The Plugins view shows
why.

### 2. Declare a command

Every action a user can take is a command. Declare it, then say where it
shows up.

```json
"contributes": {
  "commands": [
    {
      "command": "wordCount.count",
      "category": "Word Count",
      "title": "Count Words",
      "runtime": "server",
      "enablement": "activeEditor"
    }
  ],
  "keybindings": [
    {"key": "ctrl+alt+w", "command": "wordCount.count", "when": "editorTextFocus"}
  ]
}
```

- `command` is the id. Prefix it with your plugin's name to keep it unique.
- `runtime` says where your handler is: `server` for the server part,
  `client` for the browser part.
- `enablement` is a when clause. While it is false the command is greyed out
  and its key does nothing.
- `category` and `title` are how it reads in the palette: *Word Count:
  Count Words*.
- `icon` is used where the command is a button. It is a Heroicons outline
  name (`"arrow-path"`), a codicon as in VS Code (`"$(refresh)"`), or a pair
  of images in the plugin for light and dark themes.

A declared command is in the command palette automatically.

When clauses and context keys are described in
[Configuration](configuration.md#when-clauses).

### 3. Write the server part

Name the module in the manifest:

```json
"server": {"module": "WordCount"}
```

Bee compiles the Elixir and Erlang files under `lib/` and `src/`. Other
locations can be listed under `"sources"`.

```elixir
defmodule WordCount do
  use Bee.Plugin

  @impl true
  def activate(_ctx), do: {:ok, %{runs: 0}}

  @command "wordCount.count"
  def count(%{active_editor: nil} = ctx, _state),
    do: Bee.API.show_message(ctx, :error, "Open a file first")

  def count(ctx, state) do
    text = Bee.API.text(ctx.active_editor) || ""
    words = text |> String.split(~r/\s+/, trim: true) |> length()
    Bee.API.show_message(ctx, :info, "#{words} words (counted #{state.runs + 1}×)")
    {:ok, %{state | runs: state.runs + 1}}
  end
end
```

The pattern:

- The function tagged with a command's id handles that command. The server
  commands in the manifest and the tagged functions must match exactly. A
  command without a handler, or a handler without a command, stops the
  plugin from starting and says which.
- A handler receives a **context** and the plugin's **state**. It returns
  `:ok` to keep the state or `{:ok, new_state}` to change it.
- The state is whatever `activate` returned. It is private to this copy of
  the plugin, which belongs to one folder.

#### The context

| Field | What it holds |
|---|---|
| `root` | The folder this copy of the plugin runs for |
| `window` | The window that ran the command. Empty during activation and events |
| `active_editor` | The absolute path of the file in front, if any |
| `language` | That file's language id |
| `selections` | The selections in that file, as start and end positions |
| `args` | The command's arguments: from a view item, an input box, a keybinding |

Positions on the server are byte offsets into the UTF-8 text.

#### Lifecycle and events

All of these are optional.

| Callback | When it is called |
|---|---|
| `activate` | Once, when the plugin starts in a folder. Returns the initial state |
| `deactivate` | When it stops |
| `handle_event` | Something happened in the folder: a file was opened, changed, saved or closed in an editor, a file changed on disk, the settings changed |
| `handle_info` | A message sent to the plugin's own process, for example by a timer it set |
| `handle_request` | The browser part or one of the plugin's LiveViews asked something |

File changes arrive in bursts. A plugin that rescans on change should wait a
moment and scan once. The `todos` example does this with a timer.

#### What the server part can do

Everything goes through `Bee.API`. Calls return immediately. Windows are
separate and act on a request when they get to it.

| Area | What you can do |
|---|---|
| Messages | Show a notification, set the status bar text |
| Files | Open a file at a line or a selection. Read the current text of a file, including unsaved changes. Edit an open file as an undoable change |
| Selections | Read the active editor's selections and their text |
| Views | Set the content of one of your views. Clear a view's input box |
| Status bar | Add, update and remove your own items |
| Explorer | Give files a colour and a badge, as the Git plugin does for changed files |
| Context | Set a context key for when clauses |
| Asking | Show an input box or a pick list. The answer arrives as a command |
| Commands | Run any command, yours or Bee's |
| Settings | Read a setting as your folder sees it |
| Workspace | The folder, and the list of its files |
| Browser part | Send it a message |
| LiveViews | Open one of your editors in a tab. Send a message to your LiveViews |

A request made with a context that has a window goes to that window. Made
during activation or from an event, it goes to every window of the folder.

**Asking is not waiting.** An input box or pick list does not return the
answer. You name a command, and the answer is delivered as that command's
last argument when the user confirms. This keeps the plugin free while the
user thinks. A common shape is one command that asks when it has no
argument and acts when it has one, as `todos.add` does in the example.

#### In Erlang

The same plugin interface works from Erlang. Commands are declared with a
module attribute, and the context is a map.

```erlang
-module(bee_upcase).
-behaviour('Elixir.Bee.Plugin').
-export([upcase/2]).
-command({<<"upcase.selection">>, upcase}).

upcase(#{active_editor := nil}, _State) -> ok;
upcase(#{active_editor := Path} = Ctx, _State) ->
    Edits = [{From, To, string:uppercase(Text)}
             || {From, To, Text} <- 'Elixir.Bee.API':selected(Ctx), From < To],
    'Elixir.Bee.API':edit(Path, Edits),
    ok.
```

Erlang files are compiled first, so Elixir code in the same plugin can call
them.

#### Module names

A plugin's modules live alongside Bee's and every other plugin's. Bee
refuses to load a plugin that defines a module which already exists. Give
your modules a prefix of your own.

### 4. Add settings

```json
"configuration": {
  "title": "Word Count",
  "properties": {
    "wordCount.countNumbers": {
      "type": "boolean",
      "default": true,
      "description": "Whether numbers count as words."
    }
  }
}
```

Each property is a JSON Schema with a default and a description. From then
on the setting behaves like one of Bee's: it appears in the generated
settings file, is validated, can be set per folder, and your plugin is told
when it changes.

Setting names must contain a dot and are unique across Bee and all plugins.

`configurationDefaults` changes the default of a setting that is not yours,
for example `{"editor.tabSize": 4}`.

### 5. Put it in menus

```json
"menus": {
  "view/title": [
    {"command": "todos.refresh", "group": "navigation@1", "when": "view == todos.list"}
  ],
  "view/item/context": [
    {"command": "todos.hide", "group": "inline", "when": "view == todos.list && viewItem == todo"}
  ],
  "commandPalette": [
    {"command": "todos.open", "when": "false"}
  ]
}
```

| Menu | Where it appears | What commands receive |
|---|---|---|
| `menubar/<id>` | A menu of the menu bar: `file`, `edit`, `view`, `terminal`, or one you add under `menubar` | |
| `editor/title` | Buttons above the editor | |
| `editor/title/context` | Right-click on an editor tab | The file's path |
| `editor/context` | Right-click in the editor | The file's path |
| `explorer/context` | Right-click in the Explorer | The file's or folder's path |
| `view/title` | Buttons in a view's header | |
| `view/item/context` | Buttons on a view's items, with group `inline` | The item's arguments |
| `commandPalette` | Not a place: a `when` of `false` hides a command from the palette | |

`group` is `"name@order"`. Items sort by order within a group, groups sort
by name, and a line separates groups. Right-click menus use VS Code's group
names, such as `navigation`, `5_cutcopypaste` and `7_modification`, so your
items land beside related ones.

A menu item can open a submenu instead of running a command. Declare it
under `submenus` and contribute its items under its id.

Hide commands that only make sense with arguments from the palette, as
above.

### 6. Add a view

A view lives in a container: an icon in the activity bar, or a section of
the bottom panel. Declare a container of your own, or add your view to one
of Bee's, such as `explorer`.

```json
"viewsContainers": {
  "activitybar": [{"id": "todos", "title": "TODOs", "icon": "check-circle"}]
},
"views": {
  "todos": [{"id": "todos.list", "name": "TODOs"}]
}
```

A view can have a `when` clause that hides it.

There are two ways to fill a view.

#### As data

Describe the content and Bee draws it. This is the quick way, and it matches
the rest of the interface without effort.

A view's content can have:

- **items**, a tree. Each has a label and may have a description, a
  tooltip, an icon, a coloured badge, children, a command to run when
  clicked, and a kind that menu when clauses can test as `viewItem`;
- a **message**, shown above the items, for example when there are none;
- **buttons**;
- an **input box** with an action button, whose text is delivered to a
  command;
- a **badge** number on the container's icon in the activity bar.

An item that stands for a file can name it, and it then gets the icon the
file icon theme gives that file.

Set the content whenever your data changes. Every window of the folder
updates. See the `todos` example.

#### As a LiveView

When a tree is not enough, draw the view yourself. Name a LiveView in the
manifest:

```json
"views": {
  "todos-live": [{"id": "todosLive.list", "name": "TODOs", "live": "TodosLive.ListLive"}]
},
"editors": [
  {"id": "todosLive.board", "title": "TODO Board", "live": "TodosLive.BoardLive"}
]
```

```elixir
defmodule TodosLive.ListLive do
  use Bee.Plugin.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok, todos} = request(socket, "todos")
    {:ok, assign(socket, todos: todos)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <ul>
      <li :for={todo <- @todos} phx-click="open" phx-value-id={todo.id}>{todo.text}</li>
    </ul>
    """
  end

  @impl true
  def handle_event("open", %{"id" => id}, socket),
    do: {:noreply, run_command(socket, "todosLive.open", [id])}

  @impl true
  def handle_info({:todos, todos}, socket), do: {:noreply, assign(socket, todos: todos)}
end
```

It is an ordinary Phoenix LiveView, compiled with the plugin's server
sources. Templates can be inline or `.html.heex` files beside the module.

How the pieces talk:

```
┌────────────── the plugin's LiveView ──────────────┐
│                                                   │
│   asks a question ────────────────────────────────┼──▶ server part answers (handle_request)
│   runs a command ─────────────────────────────────┼──▶ the window runs it, like any command
│   receives a message ◀────────────────────────────┼─── server part pushes to its LiveViews
│                                                   │
└───────────────────────────────────────────────────┘
```

- The LiveView **asks** the server part for data and waits for the answer.
- It **runs commands** in the window, the plugin's own or Bee's.
- The server part **pushes messages** to the LiveViews of a view or editor,
  in every window of the folder.

A LiveView knows where it is: the plugin, the folder, its view or editor id,
and for an editor the parameters it was opened with.

**Editors** are LiveViews shown in an editor tab. The server part opens
one, optionally with a title, parameters and a key. One tab is kept per key,
so the same editor can be open for several things at once.

**Styling.** A LiveView can use the color theme's CSS variables, named as in
VS Code (`--vscode-editor-background` and so on), and the classes of Bee's
own styles, so it follows the theme. Anything more goes in a stylesheet
named by `"styles"` in the manifest. The stylesheet is loaded into the page
as a whole, so prefix your class names with your plugin's name.

**Hooks.** A `phx-hook` used in your templates is registered by your
browser part.

### 7. Write the browser part

```json
"browser": "browser.js"
```

An ES module that exports `activate`. It receives one object, its interface
to Bee.

```js
export function activate(bee) {
  bee.registerCommand("insertDate.insert", () => {
    const today = new Date().toISOString().slice(0, 10)
    if (!bee.editor.insert(today)) bee.showMessage("Open a file first", "error")
  })
}
```

| It can | For |
|---|---|
| Register a command | Implementing a command whose runtime is `client` |
| Read and change the active editor | Its path, text and selections. Insert text, replace selections |
| Register an editor extension | Decorations, gutters, hovers, key handling, in every file |
| Register a highlighting mode | A language's highlighting |
| Register a LiveView hook | The `phx-hook`s of your LiveViews |
| Show a message | |
| Ask the server part | A request with a reply |
| Receive messages from the server part | |

Everything registered is undone when the plugin unloads, so a reload leaves
nothing behind.

**Use Bee's editor modules.** The editor is CodeMirror. An editor extension
must be built from the same copy of CodeMirror that the editor runs, and a
second copy bundled into your plugin would not work with it. The object
your plugin receives carries Bee's own copy. Take the classes you need from
there.

**Positions** in the browser are the editor's, counted in UTF-16 units.
Positions on the server are UTF-8 bytes. They differ as soon as the text has
non-ASCII characters. Send paths and line numbers between the two parts, or
convert.

**The two parts together.** The browser part asks, the server part answers.
The server part can also send a message without being asked, for example to
say that cached data is stale. The `todos` example highlights TODO comments
in the editor from its browser part and, on hover, asks its server part how
many there are.

### 8. Add a language

```json
"languages": [
  {
    "id": "dotenv",
    "aliases": ["Dotenv"],
    "filenames": [".env"],
    "filenamePatterns": [".env.*", "*.env"]
  }
],
"grammars": [{"language": "dotenv", "mode": "dotenv"}]
```

A language says which files are its own: by `extensions`, `filenames`,
`filenamePatterns`, or a `firstLine` pattern. The first alias is its display
name. Contributing an id that already exists adds to that language, which is
how a plugin teaches Bee new file names for a known language.

Highlighting is one of:

- a **mode** registered by your browser part, as above;
- a **TextMate grammar** file, as VS Code uses: give `scopeName` and
  `path`. Grammars can embed other languages and can be injected into other
  grammars.

A language can also name a **language configuration** file in VS Code's
format, for comments, brackets, auto-closing pairs, indentation and folding.

### 9. Other contributions

| Contribution | What it adds |
|---|---|
| `themes` | Color themes in VS Code's format |
| `iconThemes` | File icon themes in VS Code's format. Only image icons, not icon fonts |
| `snippets` | Snippet files in VS Code's format, for one language or all |
| `jsonValidation` | A JSON Schema for JSON files matching a pattern. Gives them validation, completion and hover |
| `menubar` | A new menu in the menu bar |

### 10. Choose when to start

```json
"activationEvents": ["*"]
```

| Event | Starts the server part |
|---|---|
| `*`, `onStartupFinished` | With the folder |
| `workspaceContains:<glob>` | With the folder, if it has a matching file |
| `onLanguage:<id>` | When a file of that language is opened |
| *(nothing)* | When one of its commands runs or one of its views is shown |

Prefer starting late. A plugin that only reacts to its own commands needs no
activation events at all. A plugin that must fill a status bar item or watch
files from the start needs `*`.

### Developing

- Link your plugin's folder into the plugins folder rather than copying it.
  Saving a file then reloads the plugin.
- A compile error, a manifest error or a failed activation is shown on the
  plugin in the Plugins view and on its details page, with the file and
  line.
- What your server part prints appears with Bee's own log output: in the
  terminal Bee was started from, or the desktop app's log.
- The [Bee Console](development.md#the-bee-console) runs inside Bee:
  `plugins()` shows every plugin's state, `features()` shows what each
  contributes and whether it is in effect, and `run("your.command")` runs a
  command in the window.

### A checklist

- [ ] The name and every id are prefixed and unique.
- [ ] Every `server` command has a handler, and every handler a command.
- [ ] Commands that need arguments are hidden from the palette.
- [ ] Commands that need an open file have an `enablement`.
- [ ] Nothing blocks for long: slow work is done in the background and
      reported when finished.
- [ ] The plugin works with two folders open at once.
- [ ] Class names in the stylesheet are prefixed.
- [ ] The browser part uses Bee's editor modules.

### The examples

| Plugin | Shows |
|---|---|
| `word-count` | A server part in Elixir: a command, a keybinding, a setting, state |
| `upcase` | A server part in Erlang: editing the open file |
| `insert-date` | A browser part: a client command using the editor |
| `dotenv` | A language and its highlighting mode |
| `todos` | Views as data: a tree, an input box, inline buttons, a pick list, a status bar item, editor decorations, and a hover that asks the server part |
| `todos-live` | LiveViews: a sidebar view and an editor tab drawn by the plugin, asking the server part and receiving its messages, a stylesheet, a hook |

The built-in Git plugin, in `priv/plugins/git`, is a larger example of all
of it together.
