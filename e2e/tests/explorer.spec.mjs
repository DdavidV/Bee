// The Explorer: the folder's files as a tree, kept up with the disk; new
// files and folders, renaming, deleting, cut / copy / paste; what
// files.exclude hides.
import {existsSync, mkdirSync, rmSync, writeFileSync} from "node:fs"
import {join} from "node:path"
import {
  activeTab, contextMenu, dws, editorLines, expect, expectFile, explorerItem, freshBee, menuItem, openBee, openFile,
  paletteInput, paletteItems, read, sidebar, tab, test, userSettingsFile, writeJson,
} from "./helpers.mjs"

freshBee()

const nameInput = (page, label) => page.getByRole("textbox", {name: label})
const rightClick = (page, rel, item) =>
  explorerItem(page, rel)
    .click({button: "right"})
    .then(() => menuItem(contextMenu(page), item).click())

test("shows the folder's files; folders open and close; .git is hidden", async ({page}) => {
  await openBee(page)
  await expect(explorerItem(page, "lib")).toBeVisible()
  await expect(explorerItem(page, "one.txt")).toBeVisible()
  await expect(explorerItem(page, ".git")).toHaveCount(0)
  await expect(explorerItem(page, "lib/a.ex")).toHaveCount(0)

  await explorerItem(page, "lib").click()
  await expect(explorerItem(page, "lib/a.ex")).toBeVisible()
  await explorerItem(page, "src").click()
  await explorerItem(page, "src/deep").click()
  await expect(explorerItem(page, "src/deep/needle_file.ex")).toBeVisible()

  await explorerItem(page, "lib").click()
  await expect(explorerItem(page, "lib/a.ex")).toHaveCount(0)
  // The other folder stays open.
  await expect(explorerItem(page, "src/deep/needle_file.ex")).toBeVisible()
})

test("follows the disk: files made, changed and removed outside Bee", async ({page}) => {
  await openBee(page)
  await expect(explorerItem(page, "from-outside.txt")).toHaveCount(0)

  writeFileSync(join(dws, "from-outside.txt"), "hello\n")
  await expect(explorerItem(page, "from-outside.txt")).toBeVisible()

  mkdirSync(join(dws, "outside-dir"))
  writeFileSync(join(dws, "outside-dir/inner.txt"), "")
  await explorerItem(page, "outside-dir").click()
  await expect(explorerItem(page, "outside-dir/inner.txt")).toBeVisible()

  rmSync(join(dws, "from-outside.txt"))
  rmSync(join(dws, "outside-dir"), {recursive: true})
  await expect(explorerItem(page, "from-outside.txt")).toHaveCount(0)
  await expect(explorerItem(page, "outside-dir")).toHaveCount(0)
})

test("New File…: named in the tree, created, opened; a path makes its folders", async ({page}) => {
  await openBee(page)
  await sidebar(page).getByRole("button", {name: "New File…"}).click()
  await nameInput(page, "New file name").fill("fresh.txt")
  await page.keyboard.press("Enter")

  await expect(explorerItem(page, "fresh.txt")).toBeVisible()
  await expect(activeTab(page)).toContainText("fresh.txt")
  expect(read(join(dws, "fresh.txt"))).toBe("")

  // Typed into, saved: an ordinary file.
  await page.keyboard.type("content")
  await page.keyboard.press("Control+s")
  await expectFile(join(dws, "fresh.txt"), "content")

  await sidebar(page).getByRole("button", {name: "New File…"}).click()
  await nameInput(page, "New file name").fill("made/on/the/way.md")
  await page.keyboard.press("Enter")
  await expect(explorerItem(page, "made/on/the/way.md")).toBeVisible()
  expect(existsSync(join(dws, "made/on/the/way.md"))).toBe(true)
})

test("New Folder…, and a new file inside a folder from its menu", async ({page}) => {
  await openBee(page)
  await sidebar(page).getByRole("button", {name: "New Folder…"}).click()
  await nameInput(page, "New folder name").fill("docs")
  await page.keyboard.press("Enter")
  await expect(explorerItem(page, "docs")).toBeVisible()
  expect(existsSync(join(dws, "docs"))).toBe(true)

  await rightClick(page, "docs", "New File…")
  await nameInput(page, "New file name").fill("intro.md")
  await page.keyboard.press("Enter")
  await expect(explorerItem(page, "docs/intro.md")).toBeVisible()
  expect(existsSync(join(dws, "docs/intro.md"))).toBe(true)
})

test("a name that can't be used is refused where it is typed; Escape gives up", async ({page}) => {
  await openBee(page)
  await sidebar(page).getByRole("button", {name: "New File…"}).click()
  const input = nameInput(page, "New file name")

  await input.fill("one.txt")
  await page.keyboard.press("Enter")
  await expect(sidebar(page).getByRole("alert")).toContainText(/exists/i)
  await expect(input).toBeVisible()

  // Out of the folder: no.
  await input.fill("../escaped.txt")
  await page.keyboard.press("Enter")
  await expect(sidebar(page).getByRole("alert")).toContainText("not a valid name")
  expect(existsSync(join(dws, "../escaped.txt"))).toBe(false)

  await page.keyboard.press("Escape")
  await expect(input).toHaveCount(0)
  expect(read(join(dws, "one.txt"))).not.toBeNull()
})

test("Rename…: on disk, in the tree, and the open tab follows", async ({page}) => {
  writeFileSync(join(dws, "old-name.txt"), "kept\n")
  await openBee(page)
  await openFile(page, "old-name.txt")

  await rightClick(page, "old-name.txt", "Rename…")
  const input = nameInput(page, "New name")
  await expect(input).toHaveValue("old-name.txt")
  await input.fill("new-name.txt")
  await page.keyboard.press("Enter")

  await expect(explorerItem(page, "new-name.txt")).toBeVisible()
  await expect(explorerItem(page, "old-name.txt")).toHaveCount(0)
  await expect(tab(page, "new-name.txt")).toBeVisible()
  await expect(tab(page, "old-name.txt")).toHaveCount(0)
  expect(read(join(dws, "new-name.txt"))).toBe("kept\n")
  expect(existsSync(join(dws, "old-name.txt"))).toBe(false)

  // Its text is still there, and saves to the new name.
  await expect(editorLines(page).first()).toHaveText("kept")
  await editorLines(page).first().click()
  await page.keyboard.press("End")
  await page.keyboard.type("!")
  await page.keyboard.press("Control+s")
  await expectFile(join(dws, "new-name.txt"), "kept!\n")
})

test("Delete asks first; a deleted file's tab closes", async ({page}) => {
  writeFileSync(join(dws, "doomed.txt"), "bye\n")
  await openBee(page)
  await openFile(page, "doomed.txt")

  await rightClick(page, "doomed.txt", "Delete")
  await expect(paletteItems(page)).toContainText(["Delete", "Cancel"])
  await paletteItems(page).filter({hasText: "Cancel"}).click()
  expect(existsSync(join(dws, "doomed.txt"))).toBe(true)
  await expect(explorerItem(page, "doomed.txt")).toBeVisible()

  await rightClick(page, "doomed.txt", "Delete")
  await paletteItems(page).filter({hasText: "Delete"}).first().click()
  await expect(explorerItem(page, "doomed.txt")).toHaveCount(0)
  await expect(tab(page, "doomed.txt")).toHaveCount(0)
  expect(existsSync(join(dws, "doomed.txt"))).toBe(false)
})

test("a folder is deleted with what is in it", async ({page}) => {
  mkdirSync(join(dws, "junk/deeper"), {recursive: true})
  writeFileSync(join(dws, "junk/deeper/file.txt"), "")
  await openBee(page)

  await rightClick(page, "junk", "Delete")
  await expect(paletteInput(page)).toHaveAttribute("placeholder", /the folder 'junk' and its contents/)
  await paletteItems(page).filter({hasText: "Delete"}).first().click()
  await expect(explorerItem(page, "junk")).toHaveCount(0)
  expect(existsSync(join(dws, "junk"))).toBe(false)
})

test("Copy and Paste make a copy; Cut and Paste move", async ({page}) => {
  writeFileSync(join(dws, "original.txt"), "payload\n")
  mkdirSync(join(dws, "target"), {recursive: true})
  await openBee(page)

  // Nothing to paste yet.
  await explorerItem(page, "target").click({button: "right"})
  await expect(menuItem(contextMenu(page), "Paste")).toBeDisabled()
  await page.keyboard.press("Escape")

  await rightClick(page, "original.txt", "Copy")
  await rightClick(page, "target", "Paste")
  await expectFile(join(dws, "target/original.txt"), "payload\n")
  expect(read(join(dws, "original.txt"))).toBe("payload\n")
  if (!(await explorerItem(page, "target/original.txt").isVisible())) await explorerItem(page, "target").click()
  await expect(explorerItem(page, "target/original.txt")).toBeVisible()

  await rightClick(page, "two.txt", "Cut")
  await rightClick(page, "target", "Paste")
  await expect(explorerItem(page, "target/two.txt")).toBeVisible()
  await expect(explorerItem(page, "two.txt")).toHaveCount(0)
  expect(existsSync(join(dws, "two.txt"))).toBe(false)
  expect(read(join(dws, "target/two.txt"))).toBe("two\n")
})

test("the folder itself can't be renamed, cut or deleted", async ({page}) => {
  await openBee(page)
  // Below the files: the folder's own menu.
  const tree = page.locator("#explorer")
  const box = await tree.boundingBox()
  await page.mouse.click(box.x + box.width / 2, box.y + box.height - 10, {button: "right"})
  const menu = contextMenu(page)
  await expect(menuItem(menu, "New File…")).toBeVisible()
  await expect(menuItem(menu, "Rename…")).toHaveCount(0)
  await expect(menuItem(menu, "Delete")).toHaveCount(0)
  await expect(menuItem(menu, "Cut")).toHaveCount(0)
})

test("files.exclude hides files, at once; false shows a default again", async ({page}) => {
  await openBee(page)
  await expect(explorerItem(page, "one.txt")).toBeVisible()

  writeJson(userSettingsFile, {"files.exclude": {"**/*.txt": true, "**/.git": false}})
  await expect(explorerItem(page, "one.txt")).toHaveCount(0)
  await expect(explorerItem(page, "b.ex")).toBeVisible()
  await expect(explorerItem(page, ".git")).toBeVisible()

  writeJson(userSettingsFile, {})
  await expect(explorerItem(page, "one.txt")).toBeVisible()
  await expect(explorerItem(page, ".git")).toHaveCount(0)
})
