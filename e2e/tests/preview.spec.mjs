// Preview editors, as in VS Code: a single click shows a file in a tab
// that the next click reuses (its name in italics); a double click – on
// the file or on its tab – an edit, or Keep Open keeps it.
import {join} from "node:path"
import {
  activeTab, contextMenu, dws, editorLines, endOfLine, expect, explorerItem, freshBee, menuItem, openBee, openFile,
  paletteInput, preview,
  previewFile, read, sidebar, tab, tabNames, tabs, test, userSettingsFile, writeJson,
} from "./helpers.mjs"

freshBee()

// Opens the file called `name` with Quick Open (Ctrl+P).
const quickOpen = async (page, name) => {
  await page.keyboard.press("Control+p")
  await expect(paletteInput(page)).toBeFocused()
  await paletteInput(page).fill(name)
  await page.locator(`#palette [data-file$='/${name}']`).click()
}

test("a click previews a file; the next click shows another in the same tab", async ({page}) => {
  await openBee(page)
  await previewFile(page, "one.txt")
  await expect(tabs(page)).toHaveCount(1)
  await expect(preview(tab(page, "one.txt"))).toHaveCount(1)
  await expect(tab(page, "one.txt").getByText("one.txt")).toHaveCSS("font-style", "italic")
  await expect(editorLines(page).first()).toHaveText("one")

  await previewFile(page, "two.txt")
  await expect(tabs(page)).toHaveCount(1)
  await expect(tab(page, "one.txt")).toHaveCount(0)
  await expect(preview(tab(page, "two.txt"))).toHaveCount(1)
  await expect(editorLines(page).first()).toHaveText("two")

  // Back again: the file is as it is on disk.
  await previewFile(page, "one.txt")
  await expect(editorLines(page).first()).toHaveText("one")
  expect(await tabNames(page)).toEqual(["one.txt"])
})

test("a double click on the file keeps it: the next preview gets a tab of its own", async ({page}) => {
  await openBee(page)
  await explorerItem(page, "one.txt").dblclick()
  await expect(tab(page, "one.txt")).toBeVisible()
  await expect(preview(tab(page, "one.txt"))).toHaveCount(0)
  await expect(tab(page, "one.txt").getByText("one.txt")).not.toHaveCSS("font-style", "italic")

  await previewFile(page, "two.txt")
  await previewFile(page, "b.ex")
  expect(await tabNames(page)).toEqual(["one.txt", "b.ex"])
  await expect(preview(tab(page, "b.ex"))).toHaveCount(1)
})

test("a double click on a preview's tab keeps it", async ({page}) => {
  await openBee(page)
  await previewFile(page, "one.txt")
  await tab(page, "one.txt").getByText("one.txt").dblclick()
  await expect(preview(tab(page, "one.txt"))).toHaveCount(0)

  await previewFile(page, "two.txt")
  expect(await tabNames(page)).toEqual(["one.txt", "two.txt"])
})

test("editing a preview keeps it", async ({page}) => {
  await openBee(page)
  await previewFile(page, "one.txt")
  await endOfLine(page, 1)
  await page.keyboard.type("!")
  await expect(preview(tab(page, "one.txt"))).toHaveCount(0)

  await previewFile(page, "two.txt")
  expect(await tabNames(page)).toEqual(["one.txt", "two.txt"])
  // What was typed is still there, unsaved.
  await tab(page, "one.txt").click()
  await expect(editorLines(page).first()).toHaveText("one!")
  expect(read(join(dws, "one.txt"))).toBe("one\n")
  await page.keyboard.press("Control+z")
})

test("Keep Open: in a preview tab's menu, and by Ctrl+K Enter", async ({page}) => {
  await openBee(page)
  await previewFile(page, "one.txt")
  await tab(page, "one.txt").click({button: "right"})
  await menuItem(contextMenu(page), "Keep Open").click()
  await expect(preview(tab(page, "one.txt"))).toHaveCount(0)
  // A kept tab's menu doesn't offer it.
  await tab(page, "one.txt").click({button: "right"})
  await expect(menuItem(contextMenu(page), "Close", {exact: true}).first()).toBeVisible()
  await expect(menuItem(contextMenu(page), "Keep Open")).toHaveCount(0)
  await page.keyboard.press("Escape")

  await previewFile(page, "two.txt")
  await page.keyboard.press("Control+k")
  await page.keyboard.press("Enter")
  await expect(preview(tab(page, "two.txt"))).toHaveCount(0)
  expect(await tabNames(page)).toEqual(["one.txt", "two.txt"])
})

test("a preview keeps its place among the tabs; a file already open is just shown", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  await previewFile(page, "two.txt")
  await quickOpen(page, "b.ex")
  await expect(tab(page, "b.ex")).toBeVisible()
  expect(await tabNames(page)).toEqual(["one.txt", "two.txt", "b.ex"])

  // The preview (in the middle) is the one replaced.
  await previewFile(page, "a_much_longer_file_name.md")
  expect(await tabNames(page)).toEqual(["one.txt", "a_much_longer_file_name.md", "b.ex"])

  // A double click on another file: the first click takes the preview's
  // tab, the second keeps it.
  await openFile(page, "two.txt")
  expect(await tabNames(page)).toEqual(["one.txt", "two.txt", "b.ex"])

  // A click on a kept file shows its tab; nothing is replaced.
  await explorerItem(page, "one.txt").click()
  await expect(activeTab(page)).toContainText("one.txt")
  expect(await tabNames(page)).toEqual(["one.txt", "two.txt", "b.ex"])
  await expect(preview(tab(page, "one.txt"))).toHaveCount(0)
})

test("a search result is previewed too", async ({page}) => {
  await openBee(page)
  await previewFile(page, "one.txt")
  await page.keyboard.press("Control+Shift+F")
  await sidebar(page).getByPlaceholder("Search", {exact: true}).fill("needle")
  await page.locator("#search-results [data-search-match]").first().click()
  await expect(preview(tab(page, "needle_file.ex"))).toHaveCount(1)
  expect(await tabNames(page)).toEqual(["needle_file.ex"])
})

test("files opened another way are kept: Quick Open, a file of the address", async ({page}) => {
  await openBee(page, `/?file=${encodeURIComponent(join(dws, "one.txt"))}`)
  await expect(tab(page, "one.txt")).toBeVisible()
  await expect(preview(tab(page, "one.txt"))).toHaveCount(0)

  await quickOpen(page, "two.txt")
  await expect(tab(page, "two.txt")).toBeVisible()
  await expect(preview(tab(page, "two.txt"))).toHaveCount(0)
  expect(await tabNames(page)).toEqual(["one.txt", "two.txt"])
})

test("workbench.editor.enablePreview: false gives every file its own tab", async ({page}) => {
  writeJson(userSettingsFile, {"workbench.editor.enablePreview": false})
  await openBee(page)
  await previewFile(page, "one.txt")
  await previewFile(page, "two.txt")
  expect(await tabNames(page)).toEqual(["one.txt", "two.txt"])
  await expect(preview(tabs(page))).toHaveCount(0)
  writeJson(userSettingsFile, {})
})
