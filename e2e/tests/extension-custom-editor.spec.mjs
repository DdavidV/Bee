// Custom editors of VS Code extensions (window.registerCustomEditorProvider),
// with Bee's test extension (bee/test/fixtures/extensions/hello-editor),
// installed for these tests: a file's tab shows the extension's page, which
// edits the file through its document; Save writes it.
import {cpSync, rmSync, writeFileSync} from "node:fs"
import {join} from "node:path"
import {config, dws, repo} from "../fixtures.mjs"
import {
  contextMenu, editorLines, expect, expectFile, explorerItem, freshBee, group, menuItem, openBee, openFile,
  paletteItems, runCommand, tab, tabNames, test, unsaved,
} from "./helpers.mjs"

const plugin = join(config, "plugins/hello-editor")

freshBee({
  // Installed before Bee starts: it loads with it.
  before: () => {
    cpSync(join(repo, "test/fixtures/extensions/hello-editor"), plugin, {recursive: true})
    writeFileSync(join(plugin, ".vsix.json"), JSON.stringify({name: "hello-editor"}))
  },
})

test.beforeEach(() => {
  writeFileSync(join(dws, "deck.cards"), "ace\nking\n")
  writeFileSync(join(dws, "score.tally"), "3\n")
})

test.afterAll(() => rmSync(plugin, {recursive: true, force: true}))

// The page of the extension's editor that is shown.
const page_ = page => page.frameLocator("#editor [data-custom-editor]:not(.hidden) iframe")
const choose = (page, name) => paletteItems(page).filter({hasText: name}).first().click()

test("a file opens in the extension's editor: its page, in the file's tab", async ({page}) => {
  await openBee(page)
  await openFile(page, "deck.cards")
  await expect(page_(page).locator("#name")).toHaveText("cards of deck.cards")
  await expect(page_(page).locator("#cards")).toHaveText("ace\nking")
  await expect(page_(page).locator("#count")).toHaveText("2 cards")
  expect(await tabNames(page)).toEqual(["deck.cards"])
})

test("the page edits the file through its document; Ctrl+S saves it", async ({page}) => {
  await openBee(page)
  await openFile(page, "deck.cards")
  await page_(page).getByRole("button", {name: "add"}).click()
  await expect(page_(page).locator("#count")).toHaveText("3 cards")
  await expect(unsaved(tab(page, "deck.cards"))).toHaveCount(1)
  await expectFile(join(dws, "deck.cards"), "ace\nking\n")

  // (The focus is in the page: its keys are Bee's too.)
  await page.keyboard.press("Control+s")
  await expectFile(join(dws, "deck.cards"), "ace\nking\ncard 3\n")
  await expect(unsaved(tab(page, "deck.cards"))).toHaveCount(0)
})

test("Open With… switches between the extension's editor and the text editor; its editor is open once", async ({page}) => {
  await openBee(page)
  await openFile(page, "deck.cards")
  await expect(page_(page).locator("#count")).toHaveText("2 cards")

  await explorerItem(page, "deck.cards").click({button: "right"})
  await menuItem(contextMenu(page), "Open With…").click()
  await expect(paletteItems(page)).toHaveText([/^\s*Text Editor\s*$/, /Cards\s+Active and Default/, /Configure default editor/])
  await choose(page, "Text Editor")
  await expect(editorLines(page).first()).toHaveText("ace")

  // Back in its editor, which has one page: it doesn't split.
  await runCommand(page, "Reopen Editor With…")
  await choose(page, "Cards")
  await expect(page_(page).locator("#count")).toHaveText("2 cards")
  await runCommand(page, "Split Editor Right")
  await expect(group(page, 2).root).toHaveCount(0)
})

test("a document of the extension's own: changed in its page, saved by it", async ({page}) => {
  await openBee(page)
  await openFile(page, "score.tally")
  await expect(page_(page).locator("#count")).toHaveText("tally 3")
  await page_(page).getByRole("button", {name: "bump"}).click()
  await page_(page).getByRole("button", {name: "bump"}).click()
  await expect(page_(page).locator("#count")).toHaveText("tally 5")
  await expect(unsaved(tab(page, "score.tally"))).toHaveCount(1)

  await runCommand(page, "File: Save")
  await expectFile(join(dws, "score.tally"), "5\n")
  await expect(unsaved(tab(page, "score.tally"))).toHaveCount(0)

  // The extension closes its editor: the tab goes.
  await page_(page).getByRole("button", {name: "close"}).click()
  await expect(tab(page, "score.tally")).toHaveCount(0)
})
