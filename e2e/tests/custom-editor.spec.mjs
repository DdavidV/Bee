// A plugin's own editor for files (contributes.customEditors with a
// LiveView): Bee's hex-view example (bee/examples/plugins/hex-view),
// installed for these tests – the default editor of *.bin files, an
// option for every other file, in the plugin's styles.
import {cpSync, rmSync, writeFileSync} from "node:fs"
import {join} from "node:path"
import {config, dws, repo} from "../fixtures.mjs"
import {
  binaryEditor, contextMenu, editorLines, expect, explorerItem, freshBee, menuItem, openBee, openFile, paletteItems,
  previewFile, runCommand, tab, tabNames, test,
} from "./helpers.mjs"

const plugin = join(config, "plugins/hex-view")

freshBee({
  // Installed before Bee starts: it loads with it.
  before: () => {
    writeFileSync(join(dws, "data.bin"), Buffer.concat([Buffer.from([0, 1, 2, 0xff]), Buffer.from("Bee!")]))
    writeFileSync(join(dws, "long.bin"), Buffer.alloc(1000, 0xab))
    cpSync(join(repo, "examples/plugins/hex-view"), plugin, {recursive: true})
  },
})

test.afterAll(() => rmSync(plugin, {recursive: true, force: true}))

// The plugin's editor in the focused group's shown tab.
const hex = page => page.locator("#editor [data-custom-editor='hexView.editor']:not(.hidden) .hex-view")
const choose = (page, name) => paletteItems(page).filter({hasText: name}).first().click()

test("a file the plugin's editor is for opens in it", async ({page}) => {
  await openBee(page)
  await previewFile(page, "data.bin")

  await expect(hex(page)).toBeVisible()
  await expect(hex(page).locator("tr")).toHaveText(/00000000\s*00 01 02 FF 42 65 65 21\s*\.\.\.\.Bee!/)
  await expect(hex(page)).toContainText("bytes 0–7 of 8")
  await expect(binaryEditor(page)).toHaveCount(0)
  // In the plugin's stylesheet: a fixed-width table.
  await expect(hex(page).locator("table")).toHaveCSS("white-space", "pre")
  expect(await tabNames(page)).toEqual(["data.bin"])
})

test("the editor is the plugin's LiveView: its buttons turn its pages", async ({page}) => {
  await openBee(page)
  await openFile(page, "long.bin")
  await expect(hex(page)).toContainText("bytes 0–511 of 1000")
  await hex(page).getByRole("button", {name: "Next"}).click()
  await expect(hex(page)).toContainText("bytes 512–999 of 1000")
  await expect(hex(page).getByRole("button", {name: "Next"})).toBeDisabled()

  // Another tab and back: where it was.
  await openFile(page, "one.txt")
  await tab(page, "long.bin").click()
  await expect(hex(page)).toContainText("bytes 512–999 of 1000")
})

test("Open With… offers it for any file, and the text editor to come back", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  await explorerItem(page, "one.txt").click({button: "right"})
  await menuItem(contextMenu(page), "Open With…").click()
  await expect(paletteItems(page)).toHaveText([/Text Editor\s+Active and Default/, /Hex Viewer/, /Configure default editor/])
  await choose(page, "Hex Viewer")
  await expect(hex(page).locator("tr")).toHaveText(/6F 6E 65 0A\s*one\./)

  await runCommand(page, "Reopen Editor With…")
  await choose(page, "Text Editor")
  await expect(editorLines(page).first()).toHaveText("one")
  await expect(hex(page)).toHaveCount(0)
})

test("the plugin's own command, in the Explorer's menu", async ({page}) => {
  await openBee(page)
  await explorerItem(page, "two.txt").click({button: "right"})
  await menuItem(contextMenu(page), "Open in Hex Viewer").click()
  await expect(hex(page).locator("tr")).toHaveText(/74 77 6F 0A\s*two\./)
})
