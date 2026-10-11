// What the tests share. They treat Bee as a user does: through its window
// (clicks, keys, what is on screen) and the files on disk – never through
// its internals. The few selectors that name Bee's own elements are here,
// so a change of markup is fixed in one place.
import {expect, test as base} from "@playwright/test"
import {existsSync, readFileSync} from "node:fs"
import {startBee, stopBee} from "../bee.mjs"
import {makeFixtures, token, url} from "../fixtures.mjs"
import {startMockOpenVsx} from "../mock-open-vsx.mjs"

export {expect}
export {config, dws, repo, token, url, work, ws2} from "../fixtures.mjs"

// Pages open on the worker's own Bee.
export const test = base.extend({
  baseURL: async ({}, use) => use(url),
})

// At the top of a test file: a Bee of its own for its tests, started on
// fresh folders (fixtures.mjs) before the first and stopped after the
// last. `env` adds to Bee's environment; `before` runs once the folders
// are made, before Bee starts (to put more into them).
export const freshBee = ({env = {}, before = null} = {}) => {
  test.beforeAll(async () => {
    await stopBee()
    makeFixtures()
    startMockOpenVsx()
    if (before) await before()
    await startBee(env)
  })
  test.afterAll(() => stopBee())
}

const withToken = path => path + (path.includes("?") ? "&" : "?") + "token=" + token

// Opens Bee on `path` (e.g. "/?folder=…"), signing in with its token, and
// waits for the window to be live.
export const openBee = async (page, path = "/") => {
  await page.goto(withToken(path))
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
}

export const folderUrl = folder => `/?folder=${encodeURIComponent(folder)}`
export const fileUrl = file => `/?file=${encodeURIComponent(file)}`

// ---- The Explorer

// The Explorer's row of `rel` (a path in the folder, "lib/a.ex").
export const explorerItem = (page, rel) => page.locator(`#explorer button[phx-value-path='${rel}']`)

// Opens `rel` from the Explorer to stay (a double click; its folders must
// be open) and waits for its tab.
export const openFile = async (page, rel) => {
  await explorerItem(page, rel).dblclick()
  const opened = page.locator(`[data-tabs] [data-path$='/${rel}']`)
  await expect(opened).toBeVisible()
  await expect(preview(opened)).toHaveCount(0)
}

// A single click on `rel` in the Explorer: a preview of it.
export const previewFile = async (page, rel) => {
  await explorerItem(page, rel).click()
  await expect(page.locator(`[data-tabs] [data-path$='/${rel}']`)).toBeVisible()
}

// ---- Tabs

export const tabs = page => page.locator("[data-tabs] [data-tab]")
// The tab of the file (or editor) called `name`.
export const tab = (page, name) => tabs(page).filter({has: page.getByText(name, {exact: true})})
// A tab that is a preview: the next file previewed takes its place.
export const preview = locator => locator.and(locator.page().locator("[data-preview=true]"))
// Whether a tab shows unsaved changes.
export const unsaved = locator => locator.and(locator.page().locator("[data-dirty=true]"))
export const activeTab = page => page.locator("[data-tabs] [data-tab][data-active=true]")

export const tabNames = page =>
  page.$$eval("[data-tabs] [data-tab]", tabs => tabs.map(t => t.dataset.path.split("/").pop()))

// ---- Editor groups (the editor area, split)

export const groups = page => page.locator("#editor section[data-group]")
// The `n`th group (1-based, in reading order) and what is in it.
export const group = (page, n) => {
  const root = groups(page).nth(n - 1)
  return {
    root,
    tabs: root.locator("[data-tabs] [data-tab]"),
    tab: name => root.locator("[data-tabs] [data-tab]").filter({has: page.getByText(name, {exact: true})}),
    activeTab: root.locator("[data-tabs] [data-tab][data-active=true]"),
    lines: root.locator(".cm-line"),
    editor: root.locator(".cm-content"),
    area: root.locator("[data-editor-area]"),
    names: () => root.locator("[data-tabs] [data-tab]").evaluateAll(tabs => tabs.map(t => t.dataset.path.split("/").pop())),
  }
}
export const focusedGroup = page => page.locator("#editor section[data-group][data-focused=true]")

// ---- The editor

export const editor = page => page.locator("#editor .cm-content")
export const editorLines = page => page.locator("#editor .cm-line")
// The text on screen (short files: all of it).
export const editorText = async page => (await editorLines(page).allTextContents()).join("\n")

// Puts the cursor at the end of line `n` (1-based).
export const endOfLine = async (page, n) => {
  // (Away from the text first: a hover's tooltip may be over the line.)
  await page.mouse.move(0, 0)
  await editorLines(page).nth(n - 1).click()
  await page.keyboard.press("End")
}

// Takes the suggestion at the top of the editor's list with `key`. The
// list takes no keys for a moment after it was filled (so that typing on
// isn't taken for choosing), and it may be filled again as answers come in:
// a key that went to the text instead (a new line, an indent) is taken
// back, the list asked for again, and the key pressed once more.
export const takeCompletion = async (page, key = "Enter") => {
  const list = page.locator(".cm-tooltip-autocomplete")
  const squeezed = async () => (await editorText(page)).replace(/\s/g, "")
  const before = await squeezed()
  await expect(async () => {
    if (await list.isHidden()) await page.keyboard.press("Control+Space")
    await expect(list).toBeVisible({timeout: 2000})
    await page.waitForTimeout(150)
    const text = await editorText(page)
    await page.keyboard.press(key)
    try {
      await expect.poll(squeezed, {timeout: 2500}).not.toBe(before)
    } catch (e) {
      if ((await editorText(page)) !== text) await page.keyboard.press("Control+z")
      throw e
    }
  }).toPass({timeout: 20_000})
}

// ---- Commands, the palette

export const palette = page => page.locator("#palette")
export const paletteInput = page => page.locator("#palette-input")
export const paletteItems = page => page.locator("#palette [role=option]")

// Runs the command titled `title` from the command palette, as a user
// would: F1, its name, Enter.
export const runCommand = async (page, title) => {
  await page.keyboard.press("F1")
  await expect(paletteInput(page)).toBeFocused()
  await paletteInput(page).fill(`>${title}`)
  await expect(paletteItems(page).filter({hasText: title}).first()).toBeVisible()
  await page.keyboard.press("Enter")
}

// Answers the title bar's input (a name, a message…) and confirms.
export const answer = async (page, text) => {
  await expect(paletteInput(page)).toBeFocused()
  await paletteInput(page).fill(text)
  await page.keyboard.press("Enter")
}

// ---- Menus

// The menu bar's menu `name` ("File"), opened.
export const openMenu = async (page, name) => {
  await page.locator("#menubar").getByRole("button", {name, exact: true}).click()
  return page.locator("#menubar [role=menu]")
}

export const contextMenu = page => page.locator("#context-menu")
export const menuItem = (menu, name) => menu.getByRole("menuitem", {name})

// ---- Around the window

export const sidebar = page => page.locator("#sidebar")
export const panel = page => page.locator("#panel")
export const statusBar = page => page.locator("#workbench > footer")
export const info = page => page.locator("#flash-info")
export const error = page => page.locator("#flash-error")

// The edge that is dragged to resize the "sidebar" or the "panel".
export const sash = (page, part) => page.locator(`#sash-${part}`)

// Shows the activity bar's view called `name` ("Explorer", "Search"…).
export const showView = async (page, name) => {
  const icon = page.locator("#activity-bar").getByRole("button", {name, exact: true})
  if ((await sidebar(page).isHidden()) || (await page.locator("#sidebar-title").textContent()) !== name) await icon.click()
  await expect(page.locator("#sidebar-title")).toHaveText(name)
}

// The panel's terminal, ready for keys; `run` types a command into it.
export const terminal = {
  rows: page => page.locator("#panel .xterm-rows").last(),
  async open(page) {
    if (await panel(page).isHidden()) await page.keyboard.press("Control+j")
    await expect(page.locator("#panel .xterm-helper-textarea").last()).toBeAttached()
    // Its shell has started once it shows a prompt.
    await expect(terminal.rows(page)).toContainText(/[$#%>]/)
    await page.locator("#panel .xterm-helper-textarea").last().focus()
  },
  async run(page, command) {
    await page.locator("#panel .xterm-helper-textarea").last().focus()
    await page.keyboard.type(command + "\n")
  },
}

// ---- Files on disk

export const read = path => (existsSync(path) ? readFileSync(path, "utf8") : null)
// Waits for `path` to hold `expected` (a string, or a RegExp to match).
export const expectFile = (path, expected) =>
  expected instanceof RegExp
    ? expect.poll(() => read(path) ?? "").toMatch(expected)
    : expect.poll(() => read(path)).toBe(expected)

// ---- Settings, as a user writes them: the JSON files

import {mkdirSync, writeFileSync} from "node:fs"
import {dirname, join} from "node:path"
import {config as configDir} from "../fixtures.mjs"

export const userSettingsFile = join(configDir, "settings.json")
export const keybindingsFile = join(configDir, "keybindings.json")
export const workspaceSettingsFile = folder => join(folder, ".bee/settings.json")

export const write = (path, text) => {
  mkdirSync(dirname(path), {recursive: true})
  writeFileSync(path, text)
}
export const writeJson = (path, value) => write(path, JSON.stringify(value, null, 2) + "\n")
