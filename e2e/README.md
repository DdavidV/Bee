# Bee's end-to-end tests

Playwright drives Bee the way a user does: a real browser (Chromium),
clicks and keys, what is on screen, and the files on disk. The tests know
nothing of Bee's code. They cover what `mix test` can't see, like dragging,
the clipboard, the terminal, highlighting, extensions' pages – and whole
journeys: edit, save, search, commit.

## Setup

On a machine that can build Bee (see the [README](../README.md)):

```sh
./setup.sh
```

It installs Bee's dependencies, Playwright and its Chromium. Nothing else
of the machine is used: not your `~/.config/bee`, not your git identity,
not your shell's startup files.

## Run

```sh
npm test                                # everything
npx playwright test tests/tabs.spec.mjs # one file
npx playwright test -g "middle click"   # by test name
npm run report                          # the last run's HTML report
```

A run:

1. builds Bee's release from this checkout, if its sources changed since
   the last run (`mix bee.release`; a few seconds when little changed)
2. downloads the one real extension the tests use, ElixirLS, from Open
   VSX – once: it is kept in `./.cache`
3. runs the test files side by side. **Every file gets a Bee of its own**,
   started for it on fresh folders (about a second) and stopped after it,
   so no file depends on what another left behind
4. stops every Bee and removes the test folders (`./work`)

Each Bee has its own port, config folder, test folders and stand-in for
Open VSX (`mock-open-vsx.mjs`): the real one is only reached for step 2.

| Variable | Meaning |
|---|---|
| `BEE_TEST_WORKERS` | How many files run at once (default: half the processors, at most 8) |
| `BEE_TEST_PORT` | The first Bee's port (default 4114; the others follow) |
| `BEE_TEST_OPEN_VSX_PORT` | The first Open VSX stand-in's port (default 4214) |
| `BEE_TEST_TRACE=1` | Keep a trace of every failed test (`npx playwright show-trace <file>`) |
| `BEE_TEST_KEEP=1` | Leave `./work` (the test folders, each Bee's log) after the run |
| `BEE_TEST_OFFLINE=1` | Don't download anything: the ElixirLS test is skipped without its package |
| `BEE_RELEASE` | Test this release (`…/bin/bee`) instead of building one |
| `BEE_REPO` | Another checkout of Bee (default: the one this folder is in) |

A failed test leaves a screenshot and a description of the page in
`test-results/`.

## Writing tests

- A test file starts with `freshBee()` (`tests/helpers.mjs`): its Bee.
  What the file needs before Bee starts – plugins, files – goes in its
  `before`.
- Act as a user: prefer what they see (a button's name, a menu item, a
  placeholder, text) to how the page is built. The selectors that do name
  Bee's own elements live in `tests/helpers.mjs`, so a change of markup is
  fixed in one place.
- Check results where a user would: on screen, and on disk (`expectFile`,
  `git`).
- Wait for what should happen (`expect(…)`, `expect.poll`), not for time.

## What is covered

| File | What it covers |
|---|---|
| `access.spec.mjs` | who gets in: the token, the cookie it is traded for, local names only, plugin files and webview pages |
| `editing.spec.mjs` | typing, the unsaved mark, saving, undo and redo, closing with unsaved changes, files changed on disk, text of every script |
| `explorer.spec.mjs` | the Explorer: following the disk, new files and folders, rename, delete, cut / copy / paste, `files.exclude` |
| `search.spec.mjs` | search: options, files to include and exclude, going to a match, unsaved text; replacing one, a file's, all |
| `settings.spec.mjs` | user and folder settings applied as saved, invalid values, the commands that open them, themes, the terminal's font |
| `keybindings.spec.mjs` | default keys, the user's own, chords, conditions, arguments, removing a default, mistakes |
| `palette.spec.mjs` | the command palette: finding, choosing, what it leaves out; recent files in Quick Open |
| `quick-open.spec.mjs` | Quick Open: recent files, file search, `>` for commands |
| `tabs.spec.mjs` | editor tabs: dragging, middle click, the right-click menu |
| `preview.spec.mjs` | preview editors: a click reuses one tab; a double click, an edit or Keep Open keeps it; the setting that turns it off |
| `workbench.spec.mjs` | the window: title, menu bar, sidebar and panel (shown, hidden, resized, remembered), activity bar, opening folders, two windows |
| `workspaces.spec.mjs` | two windows on two folders: files, terminal, search, git |
| `panel.spec.mjs` | the bottom panel: sections, the terminal list (rename, colour, drag), maximize |
| `terminal.spec.mjs` | terminals: a shell in the folder, several of them, kept while hidden, ended with the window |
| `console.spec.mjs` | the Bee Console |
| `git.spec.mjs` | the Git plugin: changes, staging, committing, discarding, branches, a new repository – checked with git |
| `git-editor.spec.mjs` | Git in the editor: line and file blame, marks beside changed lines, the peek to stage or revert a change |
| `languages.spec.mjs` | which language a file is, `files.associations`, highlighting, a plugin's file icon theme |
| `color-theme.spec.mjs` | color themes: the picker's preview, every part's colors |
| `textmate.spec.mjs` | TextMate grammars: JSON and plist grammars, token colors, big files (idle tokenizing, no stalls, random edits; `BEE_TEST_SEED`) |
| `language-config.spec.mjs` | a language configuration: comments, auto-closing pairs, indentation, folding |
| `snippets.spec.mjs`, `snippet-syntax.spec.mjs` | snippets in the editor; VS Code's snippet syntax converted (in Node, no browser) |
| `json-validation.spec.mjs` | JSON files checked against a plugin's schema: errors, completion, hover |
| `plugins.spec.mjs` | plugins as folders that appear, change and go; enable and disable; broken ones; a folder's own plugins; Install from VSIX |
| `example-plugins.spec.mjs` | Bee's example plugins: `word-count`, `upcase`, `insert-date`, `dotenv`, `todos` |
| `plugin-liveview.spec.mjs` | a plugin's own LiveViews (the `todos-live` example) |
| `extension-details.spec.mjs` | a plugin's details page: README (sanitized), Features |
| `open-vsx.spec.mjs` | searching and installing from Open VSX (the stand-in), the rate limit |
| `vscode-extension.spec.mjs` | a VS Code extension's commands, menus, keys, settings, output (Bee's `hello` test extension) |
| `language-features.spec.mjs` | language features of extensions (Bee's `hello-lang`): diagnostics, completion, hover, definitions, formatting, references, rename, symbols, quick fixes, Problems |
| `webview.spec.mjs` | extensions' webview pages (Bee's `hello-webview`): shown, themed, messages, kept apart from Bee's page |
| `elixir-ls.spec.mjs` | a real language server through a real extension (ElixirLS), installed from its package |
| `desktop-bridge.spec.mjs` | desktop mode without the desktop app: the page, its files and LiveView's socket as frames over Bee's stdin/stdout, no port (in Node, no browser) |

The desktop app's own window has a self-test:
`cd ../desktop && cargo run --features selftest -- /path/to/repo`.
