// Settings: the user's settings.json and a folder's .bee/settings.json,
// applied as they are saved; what isn't valid is reported and ignored.
import {existsSync, rmSync} from "node:fs"
import {join} from "node:path"
import {
  activeTab, dws, editor, editorLines, expect, expectFile, folderUrl, freshBee, openBee, openFile, read, runCommand,
  statusBar, test, userSettingsFile, workspaceSettingsFile, write, writeJson, ws2,
} from "./helpers.mjs"

freshBee()

const fontSize = page => editor(page).evaluate(el => getComputedStyle(el).fontSize)
const problems = page => statusBar(page).getByRole("button", {name: /problems?$/})

test.beforeEach(() => {
  rmSync(userSettingsFile, {force: true})
  rmSync(workspaceSettingsFile(dws), {force: true})
  rmSync(workspaceSettingsFile(ws2), {force: true})
})

test("the editor's settings apply as the file is saved", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  expect(await fontSize(page)).toBe("14px")
  await expect(page.locator("#editor .cm-lineNumbers")).toBeVisible()

  writeJson(userSettingsFile, {"editor.fontSize": 22, "editor.lineNumbers": "off", "editor.wordWrap": "on"})
  await expect.poll(() => fontSize(page)).toBe("22px")
  await expect(page.locator("#editor .cm-lineNumbers")).toHaveCount(0)
  await expect(editor(page)).toHaveClass(/cm-lineWrapping/)

  // Taken out again: the defaults are back.
  writeJson(userSettingsFile, {})
  await expect.poll(() => fontSize(page)).toBe("14px")
  await expect(page.locator("#editor .cm-lineNumbers")).toBeVisible()
  await expect(editor(page)).not.toHaveClass(/cm-lineWrapping/)
})

test("comments and trailing commas are fine in the file", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  write(userSettingsFile, '// mine\n{\n  /* bigger */ "editor.fontSize": 19, // yes\n}\n')
  await expect.poll(() => fontSize(page)).toBe("19px")
  await expect(problems(page)).toHaveCount(0)
})

test("a value that isn't valid is reported and ignored; the others apply", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  writeJson(userSettingsFile, {"editor.fontSize": "huge", "editor.lineNumbers": "off", "made.up.setting": 1})

  await expect(problems(page)).toHaveText(/1 problem/)
  await expect(problems(page)).toHaveAttribute("title", /editor\.fontSize/)
  expect(await fontSize(page)).toBe("14px")
  await expect(page.locator("#editor .cm-lineNumbers")).toHaveCount(0)

  // Out of range is not valid either.
  writeJson(userSettingsFile, {"editor.fontSize": 500})
  await expect(problems(page)).toHaveAttribute("title", /editor\.fontSize/)
  expect(await fontSize(page)).toBe("14px")

  writeJson(userSettingsFile, {"editor.fontSize": 16})
  await expect(problems(page)).toHaveCount(0)
  await expect.poll(() => fontSize(page)).toBe("16px")
})

test("a file that isn't JSON is reported; the settings stay as they were", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  write(userSettingsFile, '{"editor.fontSize": 18,,, oops')
  await expect(problems(page)).toBeVisible()
  await expect(problems(page)).toHaveAttribute("title", /settings\.json/)
  expect(await fontSize(page)).toBe("14px")
})

test("a folder's settings win over the user's, in that folder only", async ({context}) => {
  writeJson(userSettingsFile, {"editor.fontSize": 18})
  writeJson(workspaceSettingsFile(ws2), {"editor.fontSize": 24})

  const here = await context.newPage()
  await openBee(here)
  await openFile(here, "one.txt")
  const there = await context.newPage()
  await openBee(there, folderUrl(ws2))
  await there.locator("#explorer button[phx-value-path='src']").click()
  await openFile(there, "src/two.txt")

  await expect.poll(() => fontSize(here)).toBe("18px")
  await expect.poll(() => fontSize(there)).toBe("24px")

  // The folder's file changed: only its window follows.
  writeJson(workspaceSettingsFile(ws2), {"editor.fontSize": 12})
  await expect.poll(() => fontSize(there)).toBe("12px")
  expect(await fontSize(here)).toBe("18px")

  // Without its own, the folder has the user's.
  rmSync(workspaceSettingsFile(ws2))
  await expect.poll(() => fontSize(there)).toBe("18px")
})

test("Open User Settings makes the file, with every setting explained, and opens it", async ({page}) => {
  await openBee(page)
  expect(existsSync(userSettingsFile)).toBe(false)
  await runCommand(page, "Preferences: Open User Settings (JSON)")
  await expect(activeTab(page)).toContainText("settings.json")
  await expect(statusBar(page)).toContainText("JSON with Comments")

  const text = read(userSettingsFile)
  for (const setting of ["editor.fontSize", "workbench.colorTheme", "files.exclude", "terminal.integrated.shell", "git.path"])
    expect(text).toContain(`"${setting}"`)
  // All of them commented out: nothing is set by it.
  expect(text).toMatch(/\/\/ "editor\.fontSize": 14,/)
  await expect(problems(page)).toHaveCount(0)
})

test("a setting written in Bee's own editor applies when saved", async ({page}) => {
  await openBee(page)
  await runCommand(page, "Open User Settings (JSON)")
  await expect(activeTab(page)).toContainText("settings.json")
  await editorLines(page).filter({hasText: /^\{$/}).first().click()
  await page.keyboard.press("End")
  await page.keyboard.press("Enter")
  await page.keyboard.insertText('"editor.fontSize": 21,')
  await page.keyboard.press("Control+s")
  await expectFile(userSettingsFile, /^\s*"editor\.fontSize": 21,$/m)
  await expect.poll(() => fontSize(page)).toBe("21px")
})

test("Open Workspace Settings makes the folder's file", async ({page}) => {
  await openBee(page)
  await runCommand(page, "Open Workspace Settings (JSON)")
  await expect(activeTab(page)).toContainText("settings.json")
  expect(read(workspaceSettingsFile(dws))).toContain("Workspace settings")
})

test("the color theme setting changes the whole window", async ({page}) => {
  // Red + green + blue of the window's background, as it is painted.
  const brightness = () =>
    page.locator("#workbench").evaluate(el => {
      const canvas = document.createElement("canvas")
      canvas.width = canvas.height = 1
      const context = canvas.getContext("2d")
      context.fillStyle = getComputedStyle(el).backgroundColor
      context.fillRect(0, 0, 1, 1)
      const [r, g, b] = context.getImageData(0, 0, 1, 1).data
      return r + g + b
    })
  await openBee(page)
  expect(await brightness()).toBeLessThan(200)

  writeJson(userSettingsFile, {"workbench.colorTheme": "light"})
  await expect.poll(brightness).toBeGreaterThan(600)

  // A theme that doesn't exist: reported? At least the window stays usable.
  writeJson(userSettingsFile, {"workbench.colorTheme": "no-such-theme"})
  await openFile(page, "one.txt")
  await expect(editorLines(page).first()).toHaveText("one")
})

test("the terminal's font size", async ({page}) => {
  await openBee(page)
  await page.keyboard.press("Control+j")
  const rows = page.locator("#panel .xterm-rows").first()
  await expect(rows).toBeVisible()
  const size = () => rows.evaluate(el => getComputedStyle(el).fontSize)
  await expect.poll(size).toBe("13px")
  writeJson(userSettingsFile, {"terminal.integrated.fontSize": 20})
  await expect.poll(size).toBe("20px")
})
