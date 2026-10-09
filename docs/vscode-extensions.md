# VS Code extensions in Bee

What Bee can take from a VS Code extension today, and what supporting the
rest would take.

## Today

Bee has its own plugins: a folder with a `plugin.json` manifest, with
server code in Elixir or Erlang and browser code in JavaScript (`browser`).
The manifest's `contributes` section follows VS Code's format, and these
contribution points are registered (`Bee.Contributions`):

| Point | Module | VS Code counterpart |
|---|---|---|
| `commands`, `keybindings`, `menus` | `Bee.Commands.Registry` | Same, in the same key format |
| `languages`, `grammars` | `Bee.Languages` | `languages`; but `grammars` names a CodeMirror mode, not a TextMate grammar |
| `configuration` | `Bee.Settings.Configuration` | Same |
| `viewsContainers`, `views` | `Bee.Views` | Same idea; views are drawn from data the plugin sends |
| `iconThemes` | `Bee.IconThemes` | Same, file for file |
| `themes` | `Bee.ColorThemes` | Same; `tokenColors` not applied yet |

**From a `.vsix`** (the "Install from VSIX…" command, `Bee.Plugins.Vsix`)
Bee installs any extension: it unpacks the package into the plugins folder
and writes a `plugin.json` for the parts it understands, which for now are
**file icon themes and color themes**. The rest of an extension is kept
but does nothing yet.

**From Open VSX** (the Plugins view's search box, `Bee.Plugins.OpenVsx`)
Bee searches [Open VSX](https://open-vsx.org) like VS Code's Extensions
view searches its marketplace: results replace the installed plugins while
there is a query, a result's details page shows its README, and Install /
Update download its `.vsix` and install it as above (the plugin remembers
its Open VSX id). Like VS Code, it installs the package built for the
platform Bee runs on (`linux-x64`, `darwin-arm64`, …), else the universal
one, from the latest version that has one; an extension with neither says
it isn't available for this platform. Open VSX rate limits, so its answers are cached (Cachex),
the same request in flight is made once, Bee sends at most 60 requests a
minute, and a `429` stops requests until its `Retry-After`.

No extension code runs: Bee doesn't load an extension's JavaScript or
provide VS Code's `vscode` API.

## The kinds of extensions

### Declarative: `package.json` and data files, no code

These can be supported one at a time, like the icon themes were: read the
contribution in `Vsix`, add a contribution point, and implement the
feature.

| Kind | Contribution | Status | What Bee needs |
|---|---|---|---|
| File icon themes | `iconThemes` | Done | |
| Colour themes | `themes` | Partial: workbench, editor and terminal colours | Syntax colours, see [Colour themes](#colour-themes) |
| Product icon themes | `productIconThemes` | Missing | A map from codicon names to Bee's icons; icon fonts |
| Language basics | `languages` + `language-configuration.json` | Partial (ids, extensions) | Comments, brackets, auto-closing pairs, indentation and folding rules applied in CodeMirror |
| Syntax highlighting | `grammars` (TextMate) | Missing | TextMate highlighting, see [TextMate grammars](#textmate-grammars) |
| Snippets | `snippets` | Missing | Snippet completion in CodeMirror (`@codemirror/autocomplete` has snippets) |
| Keymaps | `keybindings` | Mostly there | The commands they bind must exist in Bee under VS Code's ids |
| Settings | `configuration`, `configurationDefaults` | Mostly there | Read them from a `.vsix`; per-language defaults (`"[python]": {…}`) |
| Extension packs | `extensionPack`, `extensionDependencies` | Missing | Install a list of extensions, from Open VSX (`Bee.Plugins.OpenVsx.install/1` installs one) |
| JSON schemas | `jsonValidation` | Missing | JSON validation and completion in the editor (Bee has a JSON Schema validator) |
| UI translations | `localizations` | Missing | Bee's UI strings going through gettext and a loader for VS Code's format |
| Tasks | `taskDefinitions`, `problemMatchers` | Missing | A tasks system, and problems from their output |
| Smaller ones | `icons`, `colors`, `walkthroughs`, `viewsWelcome`, `terminal.profiles` | Missing | Each is small |

### Programmatic: JavaScript using the `vscode` API

Most popular extensions are this kind. `package.json` names a `main`
(run by Node.js) or a `browser` entry (run in a web worker), and the code
calls the `vscode` module, for example:

- **Language support**, the biggest group (Python, Go, rust-analyzer,
  ElixirLS). Mostly a thin client that starts a language server and talks
  LSP to it.
- **Debuggers**: a debug adapter speaking DAP, plus VS Code's debug UI.
- **Formatters and linters**: Prettier, ESLint.
- **Source control providers, tree views, status bar items, code lenses,
  decorations.** Bee's own plugin API has counterparts for several of
  these.
- **Webviews and custom editors**: an HTML UI in an editor tab or a view
  (Markdown preview, diagram editors).
- **Notebooks**: Jupyter.
- **Test explorers, tasks, file system providers, authentication, remote
  development, AI and chat.**

## What to do

### Colour themes

A theme is listed in `contributes.themes` (`label`, `uiTheme`: `vs-dark`,
`vs`, `hc-black` or `hc-light`, and `path`). Its JSON file (comments
allowed) may `include` another theme file, and has:

- `colors`: named UI colours, such as `editor.background`,
  `sideBar.background`, `tab.activeBackground`, `terminal.ansiRed`;
- `tokenColors`: syntax colours, as rules on TextMate scopes
  (`keyword.control`, `entity.name.function`…);
- `semanticTokenColors`: colours for semantic tokens, which come from a
  language server.

Done (steps 1, 2, 3, 5 and 6 below): `Bee.ColorThemes` registers the
themes (Bee's own "dark" and "light" in `priv/contributions/bee.json`,
plugins' and VSIX ones); `Bee.ColorThemes.Theme` reads a theme with its
`include`s and fills in VS Code's defaults (`priv/color_themes/defaults.json`).
The page gets the colours as `--vscode-*` CSS variables, named like VS
Code's webview variables; components use them through per-part tokens in
`app.css` (`bg-sidebar`, `text-tab-active-fg`…), and daisyUI's colours are
set from them too. Preferences: Color Theme (Ctrl+K Ctrl+T) previews the
selected theme. Left: syntax colours (step 4).

The steps:

1. **Installer and registry.** `Vsix` also takes `contributes.themes`,
   resolving `include`s. A `Bee.ColorThemes` contribution point registers
   them, like `Bee.IconThemes`.
2. **Bee's colour variables.** CSS variables for the parts VS Code names:
   editor, sidebar, activity bar, title bar, status bar, tabs, panel,
   lists, inputs, buttons, borders. Components use them instead of
   daisyUI's colours (a one-time pass over the components). Bee's dark and
   light themes become ordinary themes that set them. About 50–80 of VS
   Code's keys cover what Bee draws.
3. **Applying a theme.** Set the variables from its `colors`; anything it
   leaves out falls back to Bee's dark or light theme, chosen by `uiTheme`.
4. **Syntax colours.** CodeMirror tags tokens with Lezer highlight tags,
   not TextMate scopes. First, map the common scopes to tags (`keyword`,
   `string`, `comment`, `entity.name.function`…): most themes look right,
   not every detail does. Exact colours come with TextMate highlighting
   (below).
5. **Terminal.** `terminal.background`, `terminal.foreground` and
   `terminal.ansi*` go into xterm's theme.
6. **Choosing one.** `workbench.colorTheme` lists the installed themes,
   and a Color Theme quick pick previews each as you move through it, like
   the icon theme picker.

### TextMate grammars

VS Code highlights with TextMate grammars: `vscode-textmate` plus the
Oniguruma regex engine compiled to WebAssembly (`vscode-oniguruma`).
Running those in the browser and feeding the tokens to CodeMirror (a
`StreamLanguage` or a view plugin with decorations) gives:

- every language extension's highlighting, without a CodeMirror mode;
- colour themes' `tokenColors` applied exactly.

It is a large change, and highlighting a big file must stay fast (tokenize
line by line, keeping each line's end state, only for visible lines and
edits). The bundled CodeMirror modes can stay as the default where they
are good.

### Language servers and debuggers

LSP and DAP are open protocols, independent of VS Code. A native LSP
client in Bee (the dropped M6 milestone: an LSP process per language and
workspace, diagnostics, hover, completion, go to definition, rename,
formatting) gives most of what language extensions offer without running
their JavaScript. The server to start can come from settings, as VS Code
extensions mostly just start one. DAP and a debug UI (breakpoints, call
stack, variables, debug console) come after.

### An extension host

Running programmatic extensions as they are needs what VS Code calls an
extension host: a Node.js process that loads an extension's `main`,
provides the `vscode` module, and forwards each API call to Bee (and
Bee's events back). Eclipse Theia and OpenSumi do exactly this.

- The `vscode` API is very large. Build it up by what real extensions
  use: commands, messages, configuration, the status bar, workspace files
  and documents, tree views, then the language providers (which map onto
  the LSP client's features).
- One host per workspace, so a misbehaving extension only affects its
  window; on the BEAM side, one process per host, supervised.
- Activation events (`onLanguage:`, `onCommand:`, `workspaceContains:`…)
  map onto Bee's existing lazy plugin start.
- Node becomes a runtime dependency of Bee.
- `browser` entries (web extensions) could run in a web worker instead,
  with the same API forwarded over the LiveView connection.

### Webviews

Webview extensions render their own HTML and talk to their code with
`postMessage`. Bee would show them in a sandboxed iframe in an editor tab
or a view, with VS Code's `acquireVsCodeApi()` shim and its
content-security rules.

## Suggested order

1. Colour themes.
2. Language packs: language configuration, snippets, TextMate grammars.
3. Keymaps, `configurationDefaults`, extension packs, JSON validation.
4. LSP client.
5. DAP and a debug UI.
6. A Node extension host with a growing `vscode` API.
7. Webviews and custom editors.

Each step is useful by itself, and the earlier ones make the later ones
smaller: TextMate highlighting serves both themes and languages, the LSP
client's features become the extension host's language providers.

## Where extensions come from

The Visual Studio Marketplace's terms allow its extensions only in
Microsoft's VS Code products. Bee should install from **Open VSX**
(open-vsx.org), the open registry VSCodium, Gitpod and Theia use, which
has an API for searching and downloading `.vsix` files. Installing a
`.vsix` file the user downloaded themselves keeps working either way.
