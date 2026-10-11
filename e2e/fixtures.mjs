// The folders the tests open, made fresh for every test file in ./work/w<n>
// (n: the worker running the file):
//
//   work/dws     a git repository (lib/a.ex, src/deep/needle_file.ex,
//                one.txt, two.txt, a_much_longer_file_name.md, b.ex),
//                Bee's folder (BEE_ROOT)
//   work/ws2     a plain folder (src/two.txt), for a second window
//   work/config  Bee's config folder (BEE_CONFIG_DIR): settings, recent
//                files… – never yours; with a color theme plugin, "Test
//                Theme" (themeColors below), and tm-lang, TextMate
//                grammars for .tml (JSON) and .tmlp (plist) files, and a
//                language configuration and snippets for .tml; and
//                pets-schema, a JSON schema for *.pets.json files
import {execFileSync} from "node:child_process"
import {mkdirSync, rmSync, writeFileSync} from "node:fs"
import {dirname, join, resolve} from "node:path"

export const here = dirname(new URL(import.meta.url).pathname)
// Bee's checkout: this folder's parent (BEE_REPO for another one).
export const repo = resolve(process.env.BEE_REPO || join(here, ".."))
// What a run downloads once and keeps (a real language extension).
export const cache = join(here, ".cache")

// Test files run side by side, each worker with a Bee of its own, on its
// own port and folders: `index` is the worker's place (0, 1, …).
export const index = Number(process.env.TEST_PARALLEL_INDEX || 0)
export const port = Number(process.env.BEE_TEST_PORT || 4114) + index
export const url = `http://127.0.0.1:${port}`
export const token = "bee-e2e"

// The real language extension (a language client and its server): its
// package from Open VSX, kept in ./.cache (global-setup.mjs).
export const elixirLs = (() => {
  const version = process.env.BEE_TEST_ELIXIR_LS_VERSION || "0.31.1"
  return {
    version,
    url: `https://open-vsx.org/api/elixir-lsp/elixir-ls/${version}/file/elixir-lsp.elixir-ls-${version}.vsix`,
    vsix: join(cache, `elixir-ls-${version}.vsix`),
  }
})()

export const workRoot = join(here, "work")
export const work = join(workRoot, `w${index}`)
export const dws = join(work, "dws")
export const ws2 = join(work, "ws2")
export const config = join(work, "config")

const files = (root, contents) => {
  for (const [rel, text] of Object.entries(contents)) {
    mkdirSync(dirname(join(root, rel)), {recursive: true})
    writeFileSync(join(root, rel), text)
  }
}

export const makeFixtures = () => {
  rmSync(work, {recursive: true, force: true})

  files(dws, {
    "lib/a.ex": "defmodule A do\nend\n",
    "src/deep/needle_file.ex": "# needle\n",
    "one.txt": "one\n",
    "two.txt": "two\n",
    // Tabs of different widths (dragging a wide one past a narrow one).
    "a_much_longer_file_name.md": "# long\n",
    "b.ex": "",
  })
  const git = (...args) => execFileSync("git", args, {cwd: dws, stdio: "ignore"})
  git("init", "-q", "-b", "main")
  git("add", ".")
  git("-c", "user.name=Bee", "-c", "user.email=bee@example.com", "commit", "-qm", "init")

  files(ws2, {"src/two.txt": "needle\n"})
  mkdirSync(config, {recursive: true})

  // A plugin highlighting two languages with TextMate grammars.
  files(join(config, "plugins/tm-lang"), {
    "plugin.json": JSON.stringify({
      name: "tm-lang",
      contributes: {
        languages: [
          {id: "tml", aliases: ["TML"], extensions: [".tml"], configuration: "./language-configuration.json"},
          {id: "tmlp", extensions: [".tmlp"]},
        ],
        snippets: [{language: "tml", path: "./snippets/tml.json"}],
        grammars: [
          {language: "tml", scopeName: "source.tml", path: "./syntaxes/tml.tmLanguage.json"},
          {language: "tmlp", scopeName: "source.tmlp", path: "./syntaxes/tmlp.tmLanguage"},
        ],
      },
    }),
    "syntaxes/tml.tmLanguage.json": JSON.stringify(tmlGrammar),
    "snippets/tml.json": JSON.stringify(tmlSnippets),
    // VS Code's format: comments allowed.
    "language-configuration.json": "// # comments, do … end blocks\n" + JSON.stringify(tmlConfiguration, null, 2),
    "syntaxes/tmlp.tmLanguage": tmlpGrammar,
  })

  // A JSON schema for *.pets.json files (jsonValidation).
  files(join(config, "plugins/pets-schema"), {
    "plugin.json": JSON.stringify({
      name: "pets-schema",
      contributes: {jsonValidation: [{fileMatch: "*.pets.json", url: "./schema.json"}]},
    }),
    "schema.json": JSON.stringify({
      $schema: "http://json-schema.org/draft-07/schema#",
      type: "object",
      required: ["name"],
      additionalProperties: false,
      properties: {
        name: {type: "string", minLength: 3, description: "The pet's name"},
        age: {type: "integer"},
        kind: {enum: ["cat", "dog"], description: "What it is"},
      },
    }),
  })

  files(join(config, "plugins/test-theme"), {
    "plugin.json": JSON.stringify({
      name: "test-theme",
      contributes: {themes: [{label: "Test Theme", uiTheme: "vs-dark", path: "./theme.json"}]},
    }),
    "theme.json": JSON.stringify({colors: themeColors}),
    // Its details page's README: Markdown, and HTML that must not run.
    "README.md": [
      "# Test Theme",
      "",
      "A **theme** for [Bee](https://example.com/bee).",
      "",
      "<script>window.readmeRan = true</script>",
      '<img src="x.png" onerror="window.readmeRan = true">',
      "",
      "```js",
      "const a = 1",
      "```",
    ].join("\n"),
  })
}

// tm-lang's grammars: TextMate, one JSON (.tml), one plist (.tmlp).
export const tmlGrammar = {
  scopeName: "source.tml",
  patterns: [
    {begin: "/\\*", end: "\\*/", name: "comment.block.tml"},
    {match: "#.*$", name: "comment.line.number-sign.tml"},
    {match: '"[^"]*"', name: "string.quoted.double.tml"},
    {match: "\\b(def)\\s+(\\w+)", captures: {1: {name: "keyword.control.tml"}, 2: {name: "entity.name.function.tml"}}},
    {match: "\\bend\\b", name: "keyword.control.tml"},
  ],
}

// tm-lang's language configuration for .tml.
export const tmlConfiguration = {
  comments: {lineComment: "#", blockComment: ["/*", "*/"]},
  brackets: [["(", ")"], ["[", "]"]],
  autoClosingPairs: [["(", ")"], ["[", "]"], {open: '"', close: '"'}],
  indentationRules: {increaseIndentPattern: "\\bdo\\s*$", decreaseIndentPattern: "^\\s*end\\b"},
  onEnterRules: [{beforeText: "^\\s*#(?!region|endregion)", action: {indent: "none", appendText: "# "}}],
  folding: {markers: {start: "^\\s*#region\\b", end: "^\\s*#endregion\\b"}},
}

// tm-lang's snippets for .tml (VS Code's format).
export const tmlSnippets = {
  "Define a function": {prefix: "def", body: ["def ${1:name}(${2:args}) do", "\t$0", "end"], description: "A function"},
  "File header": {prefix: "hdr", body: "# ${TM_FILENAME} ${CURRENT_YEAR}"},
  "Wrap": {prefix: "wrap", body: "(${TM_SELECTED_TEXT:x})"},
  "Pick": {prefix: "pick", body: "${1|alpha,beta|} $1"},
}

const tmlpGrammar = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>scopeName</key><string>source.tmlp</string>
  <key>patterns</key>
  <array>
    <dict><key>match</key><string>\\bdo\\b</string><key>name</key><string>keyword.control.tmlp</string></dict>
  </array>
</dict>
</plist>
`

// Test Theme's colors: one per part, easy to tell apart.
export const themeColors = {
  "editor.background": "#102030",
  "sideBar.background": "#203040",
  "activityBar.background": "#304050",
  "titleBar.activeBackground": "#405060",
  "statusBar.background": "#506070",
  "tab.activeBackground": "#607080",
  "panel.background": "#708090",
  "terminal.background": "#112233",
}
