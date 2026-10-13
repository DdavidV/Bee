# Example plugins

| Plugin        | Shows                                                         |
| ------------- | ------------------------------------------------------------- |
| `word-count`  | Elixir server plugin: command, keybinding, a setting, state    |
| `upcase`      | Erlang server plugin: edits the open file through `Bee.API`    |
| `insert-date` | Browser plugin: a client command using the editor              |
| `dotenv`      | A language and its highlighting (a CodeMirror mode) from a plugin |
| `todos-live`  | LiveViews (`Bee.Plugin.LiveView`): a sidebar view and an editor tab drawn by the plugin itself with HEEx templates (inline `~H`, and a `.html.heex` file), asking the server part and getting its messages, a stylesheet, a `phx-hook` |
| `hex-view`    | A custom editor (`contributes.customEditors` with `live`): a LiveView that shows any file's bytes, a page at a time – the default editor of `*.bin` and `*.dat` files, an option under Open With… for every file, and a command that opens a file in it (`Bee.API.open_file/3` with `with:`) |
| `todos`       | The UI API: its own sidebar view (tree, input box, inline buttons), a quick pick, an input box, a status bar item, editor decorations and a hover that asks the server part |

Install by linking (or copying) them into your plugins folder:

```sh
mkdir -p ~/.config/bee/plugins
ln -s "$PWD"/examples/plugins/* ~/.config/bee/plugins/
```

then run **Developer: Reload Plugins** (or restart Bee). The Plugins view
(Ctrl+Shift+X) lists them; their commands are in the palette.

A plugin is a folder with a `plugin.json` (see
`priv/schemas/manifest.schema.json`), plus

- a server part: `"server": {"module": ...}`, Elixir (`.ex`) and/or Erlang
  (`.erl`) files under `lib/` and `src/`, one module implementing
  `Bee.Plugin` (see its docs), calling `Bee.API`
- a browser part: `"browser": "browser.js"`, an ES module exporting
  `activate(bee)` (see `assets/js/plugins/api.js`)
- its own user interface: LiveViews among the server sources
  (`use Bee.Plugin.LiveView`, see its docs), named by a view's, an
  editor's or a custom editor's `"live"` in the manifest, and a stylesheet
  (`"styles"`)
