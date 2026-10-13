// The window itself: its title, the menu bar, the sidebar and the panel
// (shown, hidden, resized, remembered), the activity bar, opening folders.
import {join} from "node:path"
import {
  answer, contextMenu, dws, editorLines, endOfLine, error, expect, explorerItem, folderUrl, freshBee, menuItem, openBee,
  openFile, openMenu, paletteInput, panel, runCommand, sash, sidebar, statusBar, test, ws2,
} from "./helpers.mjs"

freshBee()

test("the window is named after its folder and the file in front", async ({page}) => {
  await openBee(page)
  await expect(page).toHaveTitle(/dws/)
  await expect(statusBar(page)).toContainText(dws)
  await expect(page.locator("#titlebar")).toContainText("dws")

  await openFile(page, "one.txt")
  await expect(page.locator("#titlebar")).toContainText("one.txt")
})

test("with nothing open, the editor area says how to start", async ({page}) => {
  await openBee(page)
  const main = page.getByRole("main")
  await expect(main).toContainText("Open a file from the explorer")
  await expect(main).toContainText("Show All Commands")
  await expect(main).toContainText("Ctrl+Shift+P")
  await expect(main).toContainText("Go to File")
  await expect(main).toContainText("Ctrl+P")
})

test("the menu bar: menus open, close, and run what they list", async ({page}) => {
  await openBee(page)
  const menu = await openMenu(page, "View")
  await expect(menuItem(menu, "Show Search")).toBeVisible()
  await expect(menuItem(menu, "Toggle Panel Visibility")).toBeVisible()

  // Escape closes it without doing anything.
  await page.keyboard.press("Escape")
  await expect(page.locator("#menubar [role=menu]")).toHaveCount(0)

  // So does a click elsewhere.
  await openMenu(page, "File")
  await page.getByRole("main").click()
  await expect(page.locator("#menubar [role=menu]")).toHaveCount(0)

  await menuItem(await openMenu(page, "View"), "Show Search").click()
  await expect(page.locator("#sidebar-title")).toHaveText("Search")
  await expect(page.locator("#menubar [role=menu]")).toHaveCount(0)

  await menuItem(await openMenu(page, "View"), "Toggle Panel Visibility").click()
  await expect(panel(page)).toBeVisible()
  await menuItem(await openMenu(page, "Terminal"), "Open Bee Console").click()
  await expect(panel(page)).toContainText("Bee Console")
})

test("the sidebar and the panel: shown and hidden by key, button and menu", async ({page}) => {
  await openBee(page)
  await expect(sidebar(page)).toBeVisible()
  await page.getByRole("button", {name: "Toggle Primary Side Bar"}).click()
  await expect(sidebar(page)).toBeHidden()
  await page.keyboard.press("Control+b")
  await expect(sidebar(page)).toBeVisible()
  await menuItem(await openMenu(page, "View"), "Toggle Primary Side Bar Visibility").click()
  await expect(sidebar(page)).toBeHidden()
  await page.getByRole("button", {name: "Toggle Primary Side Bar"}).click()

  await page.getByRole("button", {name: "Toggle Panel"}).click()
  await expect(panel(page)).toBeVisible()
  await panel(page).getByTitle("Hide Panel").click()
  await expect(panel(page)).toHaveCount(0)
})

test("the gear at the bottom of the activity bar: a menu of what is managed", async ({page}) => {
  await openBee(page)
  const gear = page.locator("#activity-bar").getByRole("button", {name: "Manage"})
  // Below the views' icons, at the bottom.
  const [bar, box] = [await page.locator("#activity-bar").boundingBox(), await gear.boundingBox()]
  expect(box.y + box.height).toBeGreaterThan(bar.y + bar.height - 20)

  await gear.click()
  const menu = contextMenu(page)
  await expect(menu.getByRole("menuitem")).toHaveText([
    /Show All Commands/,
    /^\s*Open Settings/,
    /Open Workspace Settings\s*$/,
    /Open User Settings \(JSON\)/,
    /Open Workspace Settings \(JSON\)/,
    /Open Keyboard Shortcuts \(JSON\)/,
    /Show Plugins/,
    /Color Theme/,
    /File Icon Theme/,
  ])
  // It opens upwards, inside the window, beside the gear.
  const shown = await menu.boundingBox()
  expect(shown.y + shown.height).toBeLessThanOrEqual(page.viewportSize().height)
  expect(shown.x).toBeGreaterThanOrEqual(box.x + box.width - 1)

  // A click on the gear again, or Escape, closes it.
  await gear.click()
  await expect(menu).toHaveCount(0)
  await gear.click()
  await expect(menu).toBeVisible()
  await page.keyboard.press("Escape")
  await expect(menu).toHaveCount(0)

  // Its entries run their commands.
  await gear.click()
  await menuItem(menu, "Open User Settings (JSON)").click()
  await expect(page.locator("[data-tabs]")).toContainText("settings.json")
  await gear.click()
  await menuItem(menu, "Color Theme").click()
  await expect(paletteInput(page)).toBeFocused()
  await page.keyboard.press("Escape")
})

test("the activity bar switches views; the active one's icon hides the sidebar", async ({page}) => {
  await openBee(page)
  const bar = page.locator("#activity-bar")
  await expect(page.locator("#sidebar-title")).toHaveText("Explorer")

  await bar.getByRole("button", {name: "Search", exact: true}).click()
  await expect(page.locator("#sidebar-title")).toHaveText("Search")
  await bar.getByRole("button", {name: "Plugins", exact: true}).click()
  await expect(page.locator("#sidebar-title")).toHaveText("Plugins")
  await expect(sidebar(page)).toContainText("Git")

  await bar.getByRole("button", {name: "Plugins", exact: true}).click()
  await expect(sidebar(page)).toBeHidden()
  await bar.getByRole("button", {name: "Explorer", exact: true}).click()
  await expect(sidebar(page)).toBeVisible()
  await expect(page.locator("#sidebar-title")).toHaveText("Explorer")

  await page.keyboard.press("Control+Shift+f")
  await expect(page.locator("#sidebar-title")).toHaveText("Search")
  await page.keyboard.press("Control+Shift+e")
  await expect(page.locator("#sidebar-title")).toHaveText("Explorer")
  await page.keyboard.press("Control+Shift+x")
  await expect(page.locator("#sidebar-title")).toHaveText("Plugins")
})

test("the sidebar is resized by dragging its edge; the width is remembered, a double click resets it", async ({page}) => {
  await openBee(page)
  const width = async () => Math.round((await sidebar(page).boundingBox()).width)
  const start = await width()
  const edge = async () => {
    const box = await sash(page, "sidebar").boundingBox()
    return {x: box.x + box.width / 2, y: box.y + box.height / 2}
  }

  let at = await edge()
  await page.mouse.move(at.x, at.y)
  await page.mouse.down()
  await page.mouse.move(at.x + 120, at.y, {steps: 6})
  await page.mouse.up()
  await expect.poll(width).toBeGreaterThan(start + 100)
  const wide = await width()

  // Still so after a reload, from the first moment.
  await page.reload()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  expect(Math.abs((await width()) - wide)).toBeLessThanOrEqual(2)

  at = await edge()
  await page.mouse.dblclick(at.x, at.y)
  await expect.poll(width).toBe(start)
})

test("the secondary side bar: on the right, shown by button, key and menu, resized by its edge", async ({page}) => {
  await openBee(page)
  const bar = page.locator("#auxiliarybar")
  await expect(bar).toBeHidden()
  await page.getByRole("button", {name: "Toggle Secondary Side Bar"}).click()
  await expect(bar).toBeVisible()

  // At the window's right edge, right of the editors, as tall as they and the panel.
  await page.keyboard.press("Control+j")
  const box = await bar.boundingBox()
  const editor = await page.locator("#editor").boundingBox()
  const bottom = await panel(page).boundingBox()
  expect(Math.round(box.x + box.width)).toBe(page.viewportSize().width)
  expect(Math.round(box.x)).toBe(Math.round(editor.x + editor.width))
  expect(Math.round(box.y)).toBe(Math.round(editor.y))
  expect(Math.round(box.y + box.height)).toBe(Math.round(bottom.y + bottom.height))
  await page.screenshot({path: "test-results/secondary-side-bar.png"})
  await page.keyboard.press("Control+j")

  // Its left edge drags: to the left it grows.
  const width = async () => Math.round((await bar.boundingBox()).width)
  const start = await width()
  const edge = await sash(page, "auxiliarybar").boundingBox()
  await page.mouse.move(edge.x + edge.width / 2, edge.y + edge.height / 2)
  await page.mouse.down()
  await page.mouse.move(edge.x - 120, edge.y + edge.height / 2, {steps: 6})
  await page.mouse.up()
  await expect.poll(width).toBeGreaterThan(start + 100)
  const wide = await width()

  // The key hides and shows it, the View menu too; the width is remembered over a reload.
  await page.keyboard.press("Control+Alt+b")
  await expect(bar).toBeHidden()
  await page.reload()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  await menuItem(await openMenu(page, "View"), "Toggle Secondary Side Bar Visibility").click()
  await expect(bar).toBeVisible()
  expect(Math.abs((await width()) - wide)).toBeLessThanOrEqual(2)
  await page.keyboard.press("Control+Alt+b")
  await expect(bar).toBeHidden()
})

test("the panel is resized by dragging its top edge, and can fill the window", async ({page}) => {
  await openBee(page)
  await page.keyboard.press("Control+j")
  const height = async () => Math.round((await panel(page).boundingBox()).height)
  const start = await height()
  const box = await sash(page, "panel").boundingBox()
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
  await page.mouse.down()
  await page.mouse.move(box.x + box.width / 2, box.y - 100, {steps: 6})
  await page.mouse.up()
  await expect.poll(height).toBeGreaterThan(start + 80)

  const before = await height()
  await panel(page).getByTitle("Maximize Panel Size").click()
  await expect.poll(height).toBeGreaterThan(before + 100)
})

test("another folder: asked for by name, opened in this window", async ({page}) => {
  await openBee(page)
  await runCommand(page, "File: Open Folder…")
  // The box starts at the folder this one is in.
  await expect(paletteInput(page)).toHaveValue(join(dws, "..") .replace(/\/$/, "") + "/")
  await answer(page, ws2)

  await expect(page).toHaveTitle(/ws2/)
  await expect(explorerItem(page, "src")).toBeVisible()
  await expect(explorerItem(page, "lib")).toHaveCount(0)
  await expect(statusBar(page)).toContainText(ws2)
})

test("a folder that doesn't exist is refused", async ({page}) => {
  await openBee(page)
  await runCommand(page, "File: Open Folder…")
  await answer(page, join(dws, "no/such/folder"))
  await expect(error(page)).toContainText(/not a folder/i)
  await expect(page).toHaveTitle(/dws/)

  // In the address too: Bee's own folder opens, with the reason.
  await openBee(page, folderUrl(join(dws, "nope")))
  await expect(error(page)).toContainText("not a folder")
  await expect(explorerItem(page, "one.txt")).toBeVisible()
})

test("unsaved changes keep the window on its folder", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  await endOfLine(page, 1)
  await page.keyboard.type(" unsaved")
  await runCommand(page, "File: Open Folder…")
  await answer(page, ws2)
  await expect(error(page)).toContainText(/Save or close one\.txt first/)
  await expect(page).toHaveTitle(/dws/)
  await expect(editorLines(page).first()).toHaveText("one unsaved")
  await page.keyboard.press("Control+z")
})

test("Open Folder in New Window opens another window on it", async ({page, context}) => {
  await openBee(page)
  await runCommand(page, "File: Open Folder in New Window…")
  const [other] = await Promise.all([context.waitForEvent("page"), answer(page, ws2)])
  await expect(other.locator("[data-phx-main].phx-connected")).toBeVisible()
  await expect(other).toHaveTitle(/ws2/)
  // This one stays where it was.
  await expect(page).toHaveTitle(/dws/)
})
