// Editing files: typing, the unsaved mark, saving, undo and redo, closing
// with unsaved changes, and files that change on disk.
import {writeFileSync} from "node:fs"
import {join} from "node:path"
import {
  activeTab, answer, dws, editor, editorLines, endOfLine, expect, expectFile, fileUrl, freshBee, openBee, openFile,
  openMenu, menuItem, paletteItems, read, statusBar, tab, test, unsaved,
} from "./helpers.mjs"

freshBee()

const one = join(dws, "one.txt")

test.beforeEach(() => writeFileSync(one, "one\n"))

test("typing marks the file unsaved; Ctrl+S writes it", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  await expect(editorLines(page).first()).toHaveText("one")
  await expect(unsaved(tab(page, "one.txt"))).toHaveCount(0)

  await endOfLine(page, 1)
  await page.keyboard.type(" and two")
  await expect(unsaved(tab(page, "one.txt"))).toHaveCount(1)
  // Not on disk yet.
  expect(read(one)).toBe("one\n")

  await page.keyboard.press("Control+s")
  await expectFile(one, "one and two\n")
  await expect(unsaved(tab(page, "one.txt"))).toHaveCount(0)
  await expect(statusBar(page)).toContainText("Saved one.txt")
})

test("File › Save saves too; what isn't a file can't be saved", async ({page}) => {
  await openBee(page)
  let menu = await openMenu(page, "File")
  await expect(menuItem(menu, "Save")).toBeDisabled()
  await page.keyboard.press("Escape")

  await openFile(page, "one.txt")
  await endOfLine(page, 1)
  await page.keyboard.type("!")
  menu = await openMenu(page, "File")
  await menuItem(menu, "Save").click()
  await expectFile(one, "one!\n")
})

test("undo and redo, by key and from the Edit menu", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")

  // Nothing to undo in a file just opened.
  let menu = await openMenu(page, "Edit")
  await expect(menuItem(menu, "Undo")).toBeDisabled()
  await expect(menuItem(menu, "Redo")).toBeDisabled()
  await page.keyboard.press("Escape")

  await endOfLine(page, 1)
  await page.keyboard.type("X")
  await expect(editorLines(page).first()).toHaveText("oneX")

  await page.keyboard.press("Control+z")
  await expect(editorLines(page).first()).toHaveText("one")
  await page.keyboard.press("Control+Shift+z")
  await expect(editorLines(page).first()).toHaveText("oneX")

  menu = await openMenu(page, "Edit")
  await expect(menuItem(menu, "Redo")).toBeDisabled()
  await menuItem(menu, "Undo").click()
  await expect(editorLines(page).first()).toHaveText("one")
  menu = await openMenu(page, "Edit")
  await menuItem(menu, "Redo").click()
  await expect(editorLines(page).first()).toHaveText("oneX")
})

test("each tab keeps its own text, cursor and undo history", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  await endOfLine(page, 1)
  await page.keyboard.type("-first")
  await openFile(page, "two.txt")
  await endOfLine(page, 1)
  await page.keyboard.type("-second")

  await tab(page, "one.txt").click()
  await expect(editorLines(page).first()).toHaveText("one-first")
  // Typing goes on where the cursor was left.
  await page.keyboard.type("!")
  await expect(editorLines(page).first()).toHaveText("one-first!")

  await tab(page, "two.txt").click()
  await expect(editorLines(page).first()).toHaveText("two-second")
  await page.keyboard.press("Control+z")
  await expect(editorLines(page).first()).toHaveText("two")
  // The other file's changes are still there.
  await tab(page, "one.txt").click()
  await expect(editorLines(page).first()).toHaveText("one-first!")
})

test("closing a file with unsaved changes asks first", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  await endOfLine(page, 1)
  await page.keyboard.type(" unsaved")

  await tab(page, "one.txt").getByTitle("Close").click()
  await expect(paletteItems(page)).toContainText(["Discard Changes and Close", "Cancel"])
  await paletteItems(page).filter({hasText: "Cancel"}).click()
  await expect(tab(page, "one.txt")).toBeVisible()
  await expect(editorLines(page).first()).toHaveText("one unsaved")

  await tab(page, "one.txt").getByTitle("Close").click()
  await paletteItems(page).filter({hasText: "Discard Changes and Close"}).click()
  await expect(tab(page, "one.txt")).toHaveCount(0)
  expect(read(one)).toBe("one\n")

  // Opened again: the file as it is on disk.
  await openFile(page, "one.txt")
  await expect(editorLines(page).first()).toHaveText("one")
})

test("a saved file closes without a question", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  await openFile(page, "two.txt")
  await tab(page, "two.txt").getByTitle("Close").click()
  await expect(tab(page, "two.txt")).toHaveCount(0)
  // The tab next to it comes to the front.
  await expect(activeTab(page)).toContainText("one.txt")
  await expect(editorLines(page).first()).toHaveText("one")
})

test("a file changed on disk is shown again, unless it has unsaved changes", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  await expect(editorLines(page).first()).toHaveText("one")

  writeFileSync(one, "changed outside\n")
  await expect(editorLines(page).first()).toHaveText("changed outside")
  await expect(unsaved(tab(page, "one.txt"))).toHaveCount(0)

  await endOfLine(page, 1)
  await page.keyboard.type(" + mine")
  await expect(unsaved(tab(page, "one.txt"))).toHaveCount(1)
  writeFileSync(one, "changed again\n")
  // What was typed isn't thrown away: still there a while later, and
  // saving it wins.
  await page.waitForTimeout(500)
  await expect(editorLines(page).first()).toHaveText("changed outside + mine")
  await page.keyboard.press("Control+s")
  await expectFile(one, "changed outside + mine\n")
})

test("text of every script survives a save", async ({page}) => {
  const text = "naïve café – 日本語 – 🐝🍯"
  await openBee(page)
  await openFile(page, "one.txt")
  await endOfLine(page, 1)
  await page.keyboard.press("Enter")
  await page.keyboard.insertText(text)
  await page.keyboard.type(" end")
  await page.keyboard.press("Control+s")
  await expectFile(one, `one\n${text} end\n`)

  // And comes back the same.
  await page.reload()
  await openFile(page, "one.txt")
  await expect(editorLines(page).nth(1)).toHaveText(`${text} end`)
})

test("typing sends what was typed, not the file, however large it is", async ({page}) => {
  // A megabyte of text.
  const big = join(dws, "big.txt")
  const line = "a line of text, some forty characters long\n"
  writeFileSync(big, line.repeat(25_000))

  // What the page sends to Bee, frame by frame.
  const sent = []
  page.on("websocket", socket => socket.on("framesent", frame => sent.push(String(frame.payload).length)))

  await openBee(page)
  await openFile(page, "big.txt")
  await endOfLine(page, 1)
  sent.length = 0

  await page.keyboard.type(" – typed")
  await expect(unsaved(tab(page, "big.txt"))).toHaveCount(1)
  // At its far end too, where the place has to be found past every line.
  await page.keyboard.press("Control+End")
  await page.keyboard.type("the end")
  await page.keyboard.press("Control+s")

  await expectFile(big, line.trimEnd() + " – typed\n" + line.repeat(24_999) + "the end")
  await expect(unsaved(tab(page, "big.txt"))).toHaveCount(0)
  expect(sent.length).toBeGreaterThan(0)
  expect(Math.max(...sent)).toBeLessThan(2_000)
})

test("text of several bytes a character and Windows line ends is changed where it was typed", async ({page}) => {
  const mixed = join(dws, "mixed.txt")
  writeFileSync(mixed, "héllo 🐝 wörld\r\nsecond ünïcode 日本 line\r\nthird\r\nfourth\r\n")
  await openBee(page)
  await openFile(page, "mixed.txt")

  // After characters of two, three and four bytes; a line's start.
  await endOfLine(page, 1)
  await page.keyboard.type("!")
  await endOfLine(page, 2)
  await page.keyboard.type("?")
  await endOfLine(page, 3)
  await page.keyboard.press("Home")
  await page.keyboard.type("3: ")
  // A line joined to the one before it: its line end goes whole.
  await endOfLine(page, 4)
  await page.keyboard.press("Home")
  await page.keyboard.press("Backspace")
  await expect(editorLines(page).nth(2)).toHaveText("3: thirdfourth")
  await page.keyboard.press("Control+s")

  // The lines not touched keep their ends.
  await expectFile(mixed, "héllo 🐝 wörld!\r\nsecond ünïcode 日本 line?\r\n3: thirdfourth\r\n")
})

test("a file named in the address opens; its language is in the status bar", async ({page}) => {
  await openBee(page, fileUrl(join(dws, "lib/a.ex")))
  await expect(activeTab(page)).toContainText("a.ex")
  await expect(editorLines(page).first()).toHaveText("defmodule A do")
  await expect(statusBar(page)).toContainText("Elixir")

  await openFile(page, "one.txt")
  await expect(statusBar(page)).toContainText("Plain Text")
  await expect(statusBar(page)).not.toContainText("Elixir")
})

test("a reloaded page is a fresh window: no editors, the Explorer as before", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  await page.reload()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  await expect(editor(page)).toBeAttached()
  await expect(page.getByText("Open a file from the explorer")).toBeVisible()
})
