// Color themes: picked with Preferences: Color Theme (Ctrl+K Ctrl+T), the
// selected one previewed; a theme's colors reach every part of the
// workbench, the editor and the terminal.
import {expect, freshBee, test} from "./helpers.mjs"
import {themeColors} from "../fixtures.mjs"
import {openBee, openFile} from "./helpers.mjs"

freshBee()

const rgb = hex => `rgb(${[1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16)).join(", ")})`
const bg = (page, selector) => page.locator(selector).first().evaluate(el => getComputedStyle(el).backgroundColor)

// Part → [selector, the theme color it shows].
const parts = {
  editor: [".cm-editor", "editor.background"],
  sidebar: ["#sidebar", "sideBar.background"],
  activityBar: ["#activity-bar", "activityBar.background"],
  statusBar: ["#workbench > footer", "statusBar.background"],
  activeTab: ["[data-tabs] [data-tab]", "tab.activeBackground"],
  panel: ["#panel", "panel.background"],
  terminal: ["#panel .xterm-scrollable-element", "terminal.background"],
}

// The panel with its terminal (it may be open already, after a reload);
// then the editor gets the keys back from the terminal.
const openPanel = async page => {
  if ((await page.locator("#panel").count()) === 0) await page.keyboard.press("Control+j")
  await expect(page.locator("#panel .xterm-screen").first()).toBeVisible()
  await page.waitForTimeout(300)
  await page.click(".cm-content")
}

const selectTheme = async page => {
  await page.keyboard.press("Control+k")
  await page.keyboard.press("Control+t")
  await expect(page.locator("#palette-input")).toBeFocused()
}

const expectColors = async (page, theme) => {
  for (const [part, [selector, key]] of Object.entries(parts)) {
    const color = await bg(page, selector)
    if (theme) expect(color, part).toBe(rgb(themeColors[key]))
    else expect(color, part).not.toBe(rgb(themeColors[key]))
  }
}

test("pick, preview and apply a color theme", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  await openPanel(page)
  await expectColors(page, false)

  await selectTheme(page)
  await expect(page.locator("#palette-items [aria-selected=true]")).toHaveText(/Bee Dark/)

  // Down to Test Theme: shown at once, not saved.
  await page.keyboard.press("ArrowDown")
  await expect(page.locator("#palette-items [aria-selected=true]")).toHaveText(/Test Theme/)
  await expect(page.locator("#workbench")).toHaveAttribute("data-color-theme", "Test Theme")
  await page.waitForTimeout(200)
  await expectColors(page, true)

  // Escape: back.
  await page.keyboard.press("Escape")
  await expect(page.locator("#workbench")).toHaveAttribute("data-color-theme", "dark")
  await page.waitForTimeout(200)
  await expectColors(page, false)

  // Picked: kept after a reload.
  await selectTheme(page)
  await page.fill("#palette-input", "test theme")
  await page.keyboard.press("Enter")
  await expect(page.locator("#workbench")).toHaveAttribute("data-color-theme", "Test Theme")
  await page.reload()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  await openFile(page, "one.txt")
  await openPanel(page)
  await page.waitForTimeout(200)
  await expectColors(page, true)

  // Back to Bee's, for the other tests.
  await selectTheme(page)
  await page.fill("#palette-input", "bee dark")
  await page.keyboard.press("Enter")
  await expect(page.locator("#workbench")).toHaveAttribute("data-color-theme", "dark")
})
