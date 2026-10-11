// The settings page (the gear, or Ctrl+,): every setting with a control
// that fits it, searched, grouped; written to the user's settings file or
// the folder's, reset to its default; a language's own settings.
import {cpSync, existsSync, rmSync} from "node:fs"
import {join} from "node:path"
import {
  activeTab, config, contextMenu, dws, editor, expect, explorerItem, freshBee, menuItem, openBee, openFile, openMenu, read, repo,
  runCommand, tab, test, userSettingsFile, workspaceSettingsFile, write, writeJson,
} from "./helpers.mjs"

freshBee({
  before: () => cpSync(join(repo, "examples/plugins/word-count"), join(config, "plugins/word-count"), {recursive: true}),
})

test.beforeEach(() => {
  rmSync(userSettingsFile, {force: true})
  rmSync(workspaceSettingsFile(dws), {force: true})
})

const page_ = page => page.locator("#settings-editor")
const setting = (page, key) => page.locator(`#settings-editor [data-setting='${key}']`)
const search = page => page_(page).getByRole("searchbox", {name: "Search settings"})
const group = (page, title) => page.locator(`#settings-editor [data-settings-group='${title}']`)
// What a settings file sets (its comments taken out).
const fileSettings = path => {
  const text = read(path)
  return text ? JSON.parse(text.replace(/^\s*\/\/.*$/gm, "").replace(/,(\s*[}\]])/g, "$1")) : {}
}
const user = () => fileSettings(userSettingsFile)
const fontSize = page => editor(page).first().evaluate(el => getComputedStyle(el).fontSize)

const open = async page => {
  await openBee(page)
  await page.keyboard.press("Control+,")
  await expect(page_(page)).toBeVisible()
}

test("opens from the gear, by Ctrl+, and from the palette, in one tab; the File menu has no settings", async ({page}) => {
  await openBee(page)
  await page.locator("#activity-bar").getByRole("button", {name: "Manage"}).click()
  await menuItem(contextMenu(page), /^\s*Open Settings/).first().click()
  await expect(activeTab(page)).toContainText("Settings")
  await expect(page_(page).getByRole("tab", {name: "User"})).toHaveAttribute("aria-selected", "true")

  await page.keyboard.press("Control+,")
  await runCommand(page, "Preferences: Open Settings")
  await expect(page.locator("[data-tabs] [data-tab]")).toHaveCount(1)
  // Opening it writes nothing.
  expect(existsSync(userSettingsFile)).toBe(false)

  // Settings are the gear's: the File menu is about files.
  const file = await openMenu(page, "File")
  await expect(file.getByRole("menuitem")).toHaveText([/Open Folder…/, /Open Folder in New Window…/, /Save/, /Close Editor/])
})

test("every setting is listed in its group, with its description and the control for its kind", async ({page}) => {
  await open(page)
  await expect(page_(page)).toContainText(/\d+ of \d+ settings/)
  for (const title of ["Editor", "Workbench", "Files", "Search", "Terminal", "Plugins", "Git", "Word Count"])
    await expect(group(page, title)).toBeAttached()

  const font = setting(page, "editor.fontSize")
  await expect(font).toContainText("Editor: Font Size")
  await expect(font).toContainText("Font size of the editor in pixels.")
  await expect(font.getByRole("spinbutton")).toHaveValue("14")
  await expect(font).toContainText("6 to 72")

  await expect(setting(page, "editor.formatOnSave").getByRole("switch")).not.toBeChecked()
  await expect(setting(page, "editor.wordWrap").getByRole("combobox")).toHaveValue("off")
  await expect(setting(page, "workbench.colorTheme").getByRole("combobox").locator("option:checked")).toHaveText("Bee Dark")
  await expect(setting(page, "extensions.nodePath").getByRole("textbox")).toHaveValue("node")
  await expect(setting(page, "files.exclude")).toContainText("**/.git")
  // A plugin's settings, from its manifest.
  await expect(group(page, "Word Count").locator("[data-setting='wordCount.countNumbers']").getByRole("switch")).toBeChecked()
  await expect(setting(page, "git.path").getByRole("textbox")).toHaveValue("git")
})

test("a switch, a list of values and a number: changed, written to the file, applied at once", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  expect(await fontSize(page)).toBe("14px")
  await page.keyboard.press("Control+,")

  const size = setting(page, "editor.fontSize").getByRole("spinbutton")
  await size.fill("20")
  await size.press("Enter")
  await expect.poll(() => user()["editor.fontSize"]).toBe(20)
  await expect(setting(page, "editor.fontSize")).toHaveAttribute("data-modified", "true")

  await setting(page, "editor.lineNumbers").getByRole("combobox").selectOption("off")
  await expect.poll(() => user()["editor.lineNumbers"]).toBe("off")

  await setting(page, "editor.formatOnSave").getByRole("switch").check()
  await expect.poll(() => user()["editor.formatOnSave"]).toBe(true)
  await setting(page, "editor.formatOnSave").getByRole("switch").uncheck()
  await expect.poll(() => user()["editor.formatOnSave"]).toBe(false)

  // The editor has them.
  await tab(page, "one.txt").click()
  await expect.poll(() => fontSize(page)).toBe("20px")
  await expect(page.locator("#editor .cm-lineNumbers")).toHaveCount(0)
})

test("the color theme is picked from the themes there are, and changes the window", async ({page}) => {
  await open(page)
  await setting(page, "workbench.colorTheme").getByRole("combobox").selectOption({label: "Bee Light"})
  await expect.poll(() => user()["workbench.colorTheme"]).toBe("light")
  await expect(page.locator("#workbench")).toHaveAttribute("data-theme", "light")
})

test("Reset takes a setting out of the file: its default is back", async ({page}) => {
  writeJson(userSettingsFile, {"editor.fontSize": 22, "editor.tabSize": 4})
  await open(page)
  const font = setting(page, "editor.fontSize")
  await expect(font.getByRole("spinbutton")).toHaveValue("22")
  await expect(font).toContainText("modified")
  // Only what is set can be reset.
  await expect(setting(page, "editor.wordWrap").getByRole("button", {name: /^Reset/})).toHaveCount(0)

  await font.getByRole("button", {name: /^Reset/}).click()
  await expect(font.getByRole("spinbutton")).toHaveValue("14")
  await expect(font).toHaveAttribute("data-modified", "false")
  expect(user()).toEqual({"editor.tabSize": 4})
})

test("comments in the file stay when the page changes it", async ({page}) => {
  write(userSettingsFile, '// my settings\n{\n  // big letters\n  "editor.fontSize": 18,\n  "editor.tabSize": 4\n}\n')
  await open(page)
  const size = setting(page, "editor.fontSize").getByRole("spinbutton")
  await size.fill("19")
  await size.press("Enter")
  await expect.poll(() => read(userSettingsFile)).toContain('"editor.fontSize": 19')
  expect(read(userSettingsFile)).toContain("// my settings")
  expect(read(userSettingsFile)).toContain("// big letters")

  await setting(page, "editor.tabSize").getByRole("button", {name: /^Reset/}).click()
  await expect.poll(() => user()).toEqual({"editor.fontSize": 19})
  expect(read(userSettingsFile)).toContain("// big letters")
})

test("a value that isn't allowed is refused where it is typed, and not written", async ({page}) => {
  await open(page)
  const font = setting(page, "editor.fontSize")
  await font.getByRole("spinbutton").fill("500")
  await font.getByRole("spinbutton").press("Enter")
  // The field knows its range, and Bee says why it won't take it.
  expect(await font.getByRole("spinbutton").evaluate(input => input.validity.valid)).toBe(false)
  await expect(font.getByRole("alert")).toContainText("72")
  expect(user()["editor.fontSize"]).toBeUndefined()

  await font.getByRole("spinbutton").fill("16")
  await font.getByRole("spinbutton").press("Enter")
  await expect(font.getByRole("alert")).toHaveCount(0)
  await expect.poll(() => user()["editor.fontSize"]).toBe(16)
})

test("search: by name, by words of the description; nothing found says so", async ({page}) => {
  await open(page)
  await search(page).fill("font size")
  await expect(page.locator("#settings-editor [data-setting]")).toHaveCount(2)
  await expect(setting(page, "editor.fontSize")).toBeVisible()
  await expect(setting(page, "terminal.integrated.fontSize")).toBeVisible()
  await expect(page_(page)).toContainText(/2 of \d+ settings/)
  // Groups with nothing found aren't shown, nor listed at the side.
  await expect(group(page, "Files")).toHaveCount(0)
  await expect(page_(page).getByRole("navigation", {name: "Setting groups"}).getByRole("button")).toHaveText([/Editor/, /Terminal/])

  await search(page).fill("git.path")
  await expect(page.locator("#settings-editor [data-setting]")).toHaveCount(1)
  await search(page).fill("COUNT numbers")
  await expect(setting(page, "wordCount.countNumbers")).toBeVisible()

  await search(page).fill("no setting is called this")
  await expect(page_(page)).toContainText("No settings found.")
  await search(page).fill("")
  await expect(setting(page, "files.exclude")).toBeAttached()
})

test("a group at the side brings its settings into view", async ({page}) => {
  await open(page)
  const terminal = group(page, "Terminal")
  await expect(terminal).not.toBeInViewport()
  await page_(page).getByRole("navigation", {name: "Setting groups"}).getByRole("button", {name: /Terminal/}).click()
  await expect(terminal).toBeInViewport()
})

test("a list: items added and removed", async ({page}) => {
  await open(page)
  const disabled = setting(page, "plugins.disabled")
  await expect(disabled).toContainText("None.")
  await disabled.getByRole("textbox").fill("word-count")
  await disabled.getByRole("button", {name: "Add"}).click()
  await expect.poll(() => user()["plugins.disabled"]).toEqual(["word-count"])
  await expect(disabled.getByRole("textbox")).toHaveValue("")
  // It took effect: the plugin's settings are gone from the page.
  await expect(group(page, "Word Count")).toHaveCount(0)

  await disabled.getByRole("button", {name: "Remove word-count"}).click()
  await expect.poll(() => user()["plugins.disabled"]).toEqual([])
  await expect(group(page, "Word Count")).toBeAttached()
})

test("a table of patterns: a default switched off, one added, taken out again", async ({page}) => {
  await open(page)
  const exclude = setting(page, "files.exclude")
  await expect(explorerItem(page, ".git")).toHaveCount(0)

  await exclude.getByRole("switch", {name: "**/.git"}).uncheck()
  await expect.poll(() => user()["files.exclude"]).toEqual({"**/.git": false})
  await expect(explorerItem(page, ".git")).toBeVisible()

  await exclude.getByRole("textbox").fill("**/*.txt")
  await exclude.getByRole("button", {name: "Add"}).click()
  await expect.poll(() => user()["files.exclude"]).toEqual({"**/.git": false, "**/*.txt": true})
  await expect(explorerItem(page, "one.txt")).toHaveCount(0)

  // A default can be switched, not removed; what was added can.
  await expect(exclude.getByRole("button", {name: "Remove **/.elixir_ls"})).toBeHidden()
  await exclude.getByRole("button", {name: "Remove **/*.txt"}).click()
  await expect(explorerItem(page, "one.txt")).toBeVisible()

  const associations = setting(page, "files.associations")
  await associations.getByRole("textbox", {name: "Add to Associations", exact: true}).fill("*.txt")
  await associations.getByRole("textbox", {name: "Value to add"}).fill("markdown")
  await associations.getByRole("button", {name: "Add"}).click()
  await expect.poll(() => user()["files.associations"]).toEqual({"*.txt": "markdown"})
})

test("Workspace: the folder's own file; what it doesn't set shows the user's value", async ({page}) => {
  writeJson(userSettingsFile, {"editor.fontSize": 18})
  await open(page)
  await page_(page).getByRole("tab", {name: "Workspace"}).click()
  await expect(page_(page).getByRole("tab", {name: "Workspace"})).toHaveAttribute("aria-selected", "true")

  const font = setting(page, "editor.fontSize")
  await expect(font.getByRole("spinbutton")).toHaveValue("18")
  await expect(font).toHaveAttribute("data-modified", "false")

  await font.getByRole("spinbutton").fill("24")
  await font.getByRole("spinbutton").press("Enter")
  await expect.poll(() => fileSettings(workspaceSettingsFile(dws))["editor.fontSize"]).toBe(24)
  expect(user()).toEqual({"editor.fontSize": 18})

  // The user's page still shows the user's.
  await page_(page).getByRole("tab", {name: "User"}).click()
  await expect(font.getByRole("spinbutton")).toHaveValue("18")
  await page_(page).getByRole("tab", {name: "Workspace"}).click()
  await font.getByRole("button", {name: /^Reset/}).click()
  await expect(font.getByRole("spinbutton")).toHaveValue("18")

  // What a folder can't set for itself is shown, and can't be changed here.
  const own = setting(page, "plugins.workspace.enabled")
  await expect(own.getByRole("switch")).toBeDisabled()
  await expect(own).toContainText("Only takes effect in the user settings")
})

test("Open Workspace Settings opens the page on the folder's settings", async ({page}) => {
  await openBee(page)
  await runCommand(page, "Preferences: Open Workspace Settings")
  await expect(page_(page).getByRole("tab", {name: "Workspace"})).toHaveAttribute("aria-selected", "true")
})

test("for one language: its own values, in its block of the file", async ({page}) => {
  writeJson(userSettingsFile, {"editor.tabSize": 2})
  await open(page)
  const language = page_(page).getByRole("combobox", {name: "Language"})
  await language.selectOption({label: "Elixir"})
  await expect(page_(page)).toContainText('"[elixir]"')

  // The settings a language can have its own value for.
  await expect(setting(page, "editor.formatOnSave")).toBeVisible()
  await expect(setting(page, "editor.fontSize")).toHaveCount(0)

  await setting(page, "editor.formatOnSave").getByRole("switch").check()
  const tabSize = setting(page, "editor.tabSize").getByRole("spinbutton")
  await expect(tabSize).toHaveValue("2")
  await tabSize.fill("8")
  await tabSize.press("Enter")
  await expect.poll(() => user()).toEqual({"editor.tabSize": 2, "[elixir]": {"editor.formatOnSave": true, "editor.tabSize": 8}})
  // The language is marked as having settings of its own.
  await expect(language.locator("option", {hasText: "Elixir"})).toHaveText(/Elixir •/)

  // Another language still has the general value.
  await language.selectOption({label: "Erlang"})
  await expect(setting(page, "editor.tabSize").getByRole("spinbutton")).toHaveValue("2")

  // Reset, one by one: the block goes with its last setting.
  await language.selectOption("elixir")
  await setting(page, "editor.tabSize").getByRole("button", {name: /^Reset/}).click()
  await expect.poll(() => user()["[elixir]"]).toEqual({"editor.formatOnSave": true})
  await setting(page, "editor.formatOnSave").getByRole("button", {name: /^Reset/}).click()
  await expect.poll(() => user()).toEqual({"editor.tabSize": 2})

  await language.selectOption({label: "all languages"})
  await expect(setting(page, "editor.fontSize")).toBeVisible()
})

test("a number or a text is written when its field is left, not as it is typed", async ({page}) => {
  await open(page)
  const node = setting(page, "extensions.nodePath").getByRole("textbox")
  await node.fill("/opt/node/bin/no")
  await page.waitForTimeout(300)
  expect(user()["extensions.nodePath"]).toBeUndefined()
  await node.pressSequentially("de")
  await node.blur()
  await expect.poll(() => user()["extensions.nodePath"]).toBe("/opt/node/bin/node")

  // A field only passed through writes nothing.
  await setting(page, "git.path").getByRole("textbox").focus()
  await setting(page, "git.path").getByRole("textbox").blur()
  await page.waitForTimeout(300)
  expect(user()).toEqual({"extensions.nodePath": "/opt/node/bin/node"})
})

test("the file edited elsewhere shows on the page; Open Settings (JSON) opens it", async ({page}) => {
  await open(page)
  await expect(setting(page, "editor.fontSize").getByRole("spinbutton")).toHaveValue("14")
  writeJson(userSettingsFile, {"editor.fontSize": 30})
  await expect(setting(page, "editor.fontSize").getByRole("spinbutton")).toHaveValue("30")

  await page_(page).getByRole("button", {name: "Open Settings (JSON)"}).click()
  await expect(activeTab(page)).toContainText("settings.json")
})
