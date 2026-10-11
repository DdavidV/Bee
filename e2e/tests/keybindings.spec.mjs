// Keybindings: Bee's defaults, and the user's keybindings.json over them –
// new keys, chords, conditions, arguments, removing a default.
import {existsSync, rmSync} from "node:fs"
import {join} from "node:path"
import {
  activeTab, dws, editorLines, expect, freshBee, keybindingsFile, menuItem, openBee, openFile, openMenu, paletteItems,
  panel, read, sidebar, statusBar, test, write, writeJson,
} from "./helpers.mjs"

freshBee()

test.beforeEach(() => rmSync(keybindingsFile, {force: true}))

const problems = page => statusBar(page).getByRole("button", {name: /problems?$/})

test("the defaults: sidebar, panel, palette, Quick Open", async ({page}) => {
  await openBee(page)
  await expect(sidebar(page)).toBeVisible()
  await page.keyboard.press("Control+b")
  await expect(sidebar(page)).toBeHidden()
  await page.keyboard.press("Control+b")
  await expect(sidebar(page)).toBeVisible()

  await expect(panel(page)).toHaveCount(0)
  await page.keyboard.press("Control+j")
  await expect(panel(page)).toBeVisible()
  await page.keyboard.press("Control+j")
  await expect(panel(page)).toHaveCount(0)

  await page.keyboard.press("Control+p")
  await expect(page.locator("#palette-input")).toHaveValue("")
  await page.keyboard.press("Escape")
  await page.keyboard.press("F1")
  await expect(page.locator("#palette-input")).toHaveValue(">")
  await page.keyboard.press("Escape")
  await expect(page.locator("#palette")).toHaveCount(0)
})

test("menus and the palette show a command's key", async ({page}) => {
  await openBee(page)
  const menu = await openMenu(page, "File")
  await expect(menuItem(menu, "Save")).toContainText("Ctrl+S")
  await expect(menuItem(menu, "Open Folder…")).toContainText("Ctrl+K Ctrl+O")
  await page.keyboard.press("Escape")

  await page.keyboard.press("F1")
  await page.locator("#palette-input").fill(">Toggle Panel Visibility")
  await expect(paletteItems(page).first()).toContainText("Ctrl+J")
})

test("a key of the user's own works as the file is saved, and is shown", async ({page}) => {
  await openBee(page)
  await page.keyboard.press("Control+Alt+y")
  await expect(sidebar(page)).toBeVisible()

  writeJson(keybindingsFile, [{key: "ctrl+alt+y", command: "workbench.action.toggleSidebarVisibility"}])
  await expect(async () => {
    await page.keyboard.press("Control+Alt+y")
    await expect(sidebar(page)).toBeHidden({timeout: 500})
  }).toPass()
  // The default still works too.
  await page.keyboard.press("Control+b")
  await expect(sidebar(page)).toBeVisible()

  // The newest key is the one shown.
  const menu = await openMenu(page, "View")
  await expect(menuItem(menu, "Toggle Primary Side Bar Visibility")).toContainText("Ctrl+Alt+Y")
})

test("a default is taken away with a - before its command", async ({page}) => {
  await openBee(page)
  writeJson(keybindingsFile, [{key: "ctrl+b", command: "-workbench.action.toggleSidebarVisibility"}])
  const menu = await openMenu(page, "View")
  await expect(menuItem(menu, "Toggle Primary Side Bar Visibility")).not.toContainText("Ctrl+B")
  await page.keyboard.press("Escape")

  await page.keyboard.press("Control+b")
  await page.waitForTimeout(300)
  await expect(sidebar(page)).toBeVisible()

  // Without the file, it is back.
  rmSync(keybindingsFile)
  await expect(async () => {
    await page.keyboard.press("Control+b")
    await expect(sidebar(page)).toBeHidden({timeout: 500})
  }).toPass()
})

test("a chord: two keys, the first shown while it waits for the second", async ({page}) => {
  writeJson(keybindingsFile, [{key: "ctrl+k ctrl+y", command: "workbench.action.togglePanel"}])
  await openBee(page)
  await page.keyboard.press("Control+k")
  await expect(statusBar(page)).toContainText(/Ctrl\+K/)
  await page.keyboard.press("Control+y")
  await expect(panel(page)).toBeVisible()

  // Another key after the first: nothing happens, the chord is over.
  await page.keyboard.press("Control+k")
  await page.keyboard.press("Control+q")
  await page.waitForTimeout(200)
  await expect(panel(page)).toBeVisible()
})

test("a key with a condition only works when it holds", async ({page}) => {
  writeJson(keybindingsFile, [{key: "ctrl+alt+y", command: "workbench.action.togglePanel", when: "editorTextFocus"}])
  await openBee(page)
  // No editor has the focus.
  await page.keyboard.press("Control+Alt+y")
  await page.waitForTimeout(300)
  await expect(panel(page)).toHaveCount(0)

  await openFile(page, "one.txt")
  await editorLines(page).first().click()
  await page.keyboard.press("Control+Alt+y")
  await expect(panel(page)).toBeVisible()
})

test("a key can give its command arguments", async ({page}) => {
  writeJson(keybindingsFile, [{key: "ctrl+alt+y", command: "bee.openFile", args: [join(dws, "lib/a.ex")]}])
  await openBee(page)
  await page.keyboard.press("Control+Alt+y")
  await expect(activeTab(page)).toContainText("a.ex")
})

test("mistakes are reported one by one; the good entries still work", async ({page}) => {
  writeJson(keybindingsFile, [
    {key: "ctrl+alt+y", command: "workbench.action.togglePanel"},
    {command: "workbench.action.togglePanel"},
    {key: "ctrl+alt+u", command: "no.such.command"},
    {key: "ctrl+alt+i", command: "workbench.action.togglePanel", when: "a &&"},
  ])
  await openBee(page)
  await expect(problems(page)).toHaveText(/3 problems/)
  await expect(problems(page)).toHaveAttribute("title", /keybindings\.json/)
  await expect(problems(page)).toHaveAttribute("title", /no\.such\.command/)

  await page.keyboard.press("Control+Alt+y")
  await expect(panel(page)).toBeVisible()
})

test("Open Keyboard Shortcuts makes the file, with examples, and opens it", async ({page}) => {
  await openBee(page)
  expect(existsSync(keybindingsFile)).toBe(false)
  await page.keyboard.press("Control+k")
  await page.keyboard.press("Control+s")
  await expect(activeTab(page)).toContainText("keybindings.json")
  expect(read(keybindingsFile)).toContain('"command"')
  await expect(problems(page)).toHaveCount(0)
})

test("a file that isn't a list is reported", async ({page}) => {
  write(keybindingsFile, '{"key": "ctrl+b"}')
  await openBee(page)
  await expect(problems(page)).toHaveAttribute("title", /keybindings\.json/)
  // The defaults are untouched.
  await page.keyboard.press("Control+b")
  await expect(sidebar(page)).toBeHidden()
})
