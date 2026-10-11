// Which language a file is: by its name, its extension, its first line –
// and files.associations over all of them; a plugin's file icon theme.
import {join} from "node:path"
import {
  activeTab, config, dws, expect, explorerItem, fileUrl, freshBee, openBee, openFile, paletteItems,
  runCommand, statusBar, test, userSettingsFile, write, writeJson,
} from "./helpers.mjs"

const files = {
  "detect/module.ex": "defmodule M do\nend\n",
  "detect/script.exs": "IO.puts(1)\n",
  "detect/page.html.heex": "<div></div>\n",
  "detect/app.js": "let a = 1\n",
  "detect/types.ts": "let a: number = 1\n",
  "detect/data.json": "{}\n",
  "detect/tsconfig.json": "{}\n",
  "detect/style.css": "a.link { color: red; margin: 2px }\n",
  "detect/README.md": "# hi\n",
  "detect/run.sh": "echo hi\n",
  "detect/config.yml": "a: 1\n",
  "detect/Cargo.toml": "[package]\n",
  "detect/Dockerfile": "FROM scratch\n",
  "detect/Dockerfile.dev": "FROM scratch\n",
  "detect/Makefile": "all:\n",
  "detect/mix.lock": "%{}\n",
  "detect/server.erl": "-module(server).\n",
  "detect/tool": "#!/usr/bin/env bash\necho hi\n",
  "detect/runner": "#!/usr/bin/env elixir\nIO.puts(1)\n",
  "detect/mystery": "nothing to go by\n",
  "detect/notes.txt": "text\n",
  "detect/UPPER.EX": "defmodule U do\nend\n",
}

const expected = {
  "module.ex": "Elixir",
  "script.exs": "Elixir",
  "page.html.heex": "HEEx",
  "app.js": "JavaScript",
  "types.ts": "TypeScript",
  "data.json": "JSON",
  "tsconfig.json": "JSON with Comments",
  "style.css": "CSS",
  "README.md": "Markdown",
  "run.sh": "Shell Script",
  "config.yml": "YAML",
  "Cargo.toml": "TOML",
  "Dockerfile": "Docker",
  "Dockerfile.dev": "Docker",
  "Makefile": "Makefile",
  "mix.lock": "Elixir",
  "server.erl": "Erlang",
  "tool": "Shell Script",
  "runner": "Elixir",
  "mystery": "Plain Text",
  "notes.txt": "Plain Text",
}

// A file icon theme (VS Code's format) from a plugin.
const icon = color => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" fill="${color}"/></svg>`

freshBee({
  before: () => {
    for (const [rel, text] of Object.entries(files)) write(join(dws, rel), text)
    const dir = join(config, "plugins/dots")
    write(
      join(dir, "plugin.json"),
      JSON.stringify({name: "dots", contributes: {iconThemes: [{id: "dots", label: "Dots", path: "./theme.json"}]}}),
    )
    write(
      join(dir, "theme.json"),
      JSON.stringify({
        iconDefinitions: {
          _file: {iconPath: "./icons/file.svg"},
          _folder: {iconPath: "./icons/folder.svg"},
          _open: {iconPath: "./icons/open.svg"},
          _ex: {iconPath: "./icons/ex.svg"},
          _make: {iconPath: "./icons/make.svg"},
        },
        file: "_file",
        folder: "_folder",
        folderExpanded: "_open",
        fileExtensions: {ex: "_ex"},
        fileNames: {makefile: "_make"},
      }),
    )
    for (const [name, color] of Object.entries({file: "gray", folder: "gold", open: "orange", ex: "purple", make: "green"}))
      write(join(dir, `icons/${name}.svg`), icon(color))
  },
})

const language = page => statusBar(page).locator("#status-lang")

test("every kind of file is the language its name, extension or first line says", async ({page}) => {
  await openBee(page)
  await explorerItem(page, "detect").click()
  for (const [name, label] of Object.entries(expected)) {
    await explorerItem(page, `detect/${name}`).click()
    await expect(activeTab(page), name).toContainText(name)
    await expect(language(page), name).toHaveText(label)
  }
})

test("known languages are highlighted: their words in more than one color", async ({page}) => {
  for (const name of ["module.ex", "app.js", "data.json", "style.css", "server.erl"]) {
    write(join(dws, "detect/data.json"), '{"a": 1, "b": "two", "c": null}\n')
    await openBee(page, fileUrl(join(dws, "detect", name)))
    const colors = () =>
      page.locator("#editor .cm-line span").evaluateAll(spans => new Set(spans.map(s => getComputedStyle(s).color)).size)
    await expect.poll(colors, name).toBeGreaterThan(1)
  }
})

test("files.associations decides before anything else, as it is saved", async ({page}) => {
  await openBee(page, fileUrl(join(dws, "detect/notes.txt")))
  await expect(language(page)).toHaveText("Plain Text")

  writeJson(userSettingsFile, {"files.associations": {"*.txt": "markdown", "detect/mystery": "yaml"}})
  await expect(language(page)).toHaveText("Markdown")
  // A pattern with a slash is matched against the path in the folder.
  await explorerItem(page, "detect").click()
  await openFile(page, "detect/mystery")
  await expect(language(page)).toHaveText("YAML")

  writeJson(userSettingsFile, {})
  await expect(language(page)).toHaveText("Plain Text")
})

test("a file icon theme from a plugin: picked from a list, its icons by name, extension and folder state", async ({page}) => {
  await openBee(page)
  const iconOf = rel => explorerItem(page, rel).locator("img")
  await expect(iconOf("detect")).toHaveCount(0)

  await runCommand(page, "Preferences: File Icon Theme")
  await paletteItems(page).filter({hasText: "Dots"}).click()

  await expect(iconOf("detect")).toHaveAttribute("src", /folder\.svg/)
  await explorerItem(page, "detect").click()
  await expect(iconOf("detect")).toHaveAttribute("src", /open\.svg/)
  await expect(iconOf("detect/module.ex")).toHaveAttribute("src", /ex\.svg/)
  await expect(iconOf("detect/Makefile")).toHaveAttribute("src", /make\.svg/)
  await expect(iconOf("detect/notes.txt")).toHaveAttribute("src", /file\.svg/)
  // The pictures really load, from the plugin.
  await expect.poll(() => iconOf("detect/module.ex").evaluate(img => img.naturalWidth)).toBeGreaterThan(0)
  // Tabs have them too.
  await openFile(page, "detect/module.ex")
  await expect(activeTab(page).locator("img")).toHaveAttribute("src", /ex\.svg/)

  // The choice is a setting: back to Bee's own icons.
  await runCommand(page, "Preferences: File Icon Theme")
  await paletteItems(page).first().click()
  await expect(iconOf("detect/module.ex")).toHaveCount(0)
})
