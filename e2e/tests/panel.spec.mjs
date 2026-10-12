// The bottom panel: its sections, the terminal list (pick, drag, right-click),
// maximize. And where the views are: icons and tabs hidden, References moved.
import {expect, freshBee, test} from "./helpers.mjs"
import {openBee} from "./helpers.mjs"

freshBee()

const names = page =>
  page.$$eval("#terminal-list [data-term] [id^=term-tab-]", items => items.map(i => i.textContent.trim()))

test("sections and terminals", async ({page}) => {
  await openBee(page)
  await page.keyboard.press("Control+j")
  await expect(page.locator("#panel-section-terminal[aria-selected=true]")).toHaveText(/Terminal/i)
  await expect(page.locator("#panel-section-console")).toHaveText(/Bee Console/i)
  // The terminal fits its place, with room around it (nothing drawn past
  // the panel's edges).
  const term = page.locator("#panel [id^=term-]:not([id^=term-tab-])").first()
  await expect(term.locator(".xterm-screen")).toBeVisible()
  await page.waitForTimeout(300)
  const panel = await page.locator("#panel-body-terminal").boundingBox()
  const screen = await term.locator(".xterm-screen").boundingBox()
  expect(screen.x - panel.x).toBeGreaterThanOrEqual(8)
  expect(screen.y + screen.height).toBeLessThanOrEqual(panel.y + panel.height - 4)
  expect(screen.x + screen.width).toBeLessThanOrEqual(panel.x + panel.width - 4)

  // One terminal: its name in the header, no list.
  await expect(page.locator("#panel header [id^=term-tab-]")).toHaveText(/sh|bash|zsh/)
  await expect(page.locator("#terminal-list")).toHaveCount(0)

  // A second: the list, the new one selected.
  await page.click("#panel [data-command='workbench.action.terminal.new']")
  await expect(page.locator("#terminal-list [data-term]")).toHaveCount(2)
  await expect(page.locator("#terminal-list [data-term]").last()).toHaveAttribute("aria-selected", "true")

  // Rename the first from its right-click menu.
  const first = page.locator("#terminal-list [data-term]").first().locator("[id^=term-tab-]")
  await first.click({button: "right"})
  await page.click("#context-menu [data-command='workbench.action.terminal.rename']")
  await page.fill("#palette-input", "server")
  await page.keyboard.press("Enter")
  await expect(first).toHaveText(/server/)

  // Its colour, from a list.
  await first.click({button: "right"})
  await page.click("#context-menu [data-command='workbench.action.terminal.changeColor']")
  await page.fill("#palette-input", "green")
  await page.keyboard.press("Enter")
  await expect(first).toHaveAttribute("data-color", "green")

  // Drag it below the other one.
  const items = page.locator("#terminal-list [data-term]")
  const top = await items.first().boundingBox()
  const bottom = await items.last().boundingBox()
  await page.mouse.move(top.x + top.width / 2, top.y + top.height / 2)
  await page.mouse.down()
  await expect(page.locator("#terminal-list [data-lifted]")).toHaveCount(1)
  await page.mouse.move(top.x + top.width / 2, bottom.y + bottom.height, {steps: 8})
  await page.mouse.up()
  await expect.poll(async () => (await names(page)).at(-1)).toBe("server")

  // Maximize, restore.
  await page.click("#panel-actions [data-command='workbench.action.toggleMaximizedPanel']")
  await expect(page.locator("#panel")).toHaveAttribute("data-maximized", "true")
  await page.click("#panel-actions [data-command='workbench.action.toggleMaximizedPanel']")
  await expect(page.locator("#panel")).toHaveAttribute("data-maximized", "false")

  // Hovering an entry shows its kill button.
  const last = page.locator("#terminal-list [data-term]").last()
  await expect(last.locator("[data-kill]")).toBeHidden()
  await last.hover()
  await expect(last.locator("[data-kill]")).toBeVisible()

  // The sections' tabs drag sideways.
  const terminal = await page.locator("#panel-section-terminal").boundingBox()
  const console_ = await page.locator("#panel-section-console").boundingBox()
  await page.mouse.move(terminal.x + terminal.width / 2, terminal.y + terminal.height / 2)
  await page.mouse.down()
  await page.mouse.move(console_.x + console_.width + 10, terminal.y + terminal.height / 2, {steps: 8})
  await page.mouse.up()
  // (Past the console's tab: after it, before or after the Output one.)
  await expect
    .poll(() => page.$$eval("#panel-sections [data-section]", s => s.map(x => x.dataset.section).filter(id => !["output", "references", "problems"].includes(id))))
    .toEqual(["console", "terminal"])
  await expect(page.locator("#panel-section-terminal")).toHaveAttribute("aria-selected", "true")

  // The console section, and back: the terminals are still there.
  await page.click("#panel-section-console")
  await expect(page.locator("#bee-console .xterm-rows")).toContainText("Bee Console")
  await page.click("#panel-section-terminal")
  await expect(page.locator("#terminal-list [data-term]")).toHaveCount(2)
  await page.screenshot({path: "test-results/panel.png"})

  // The kill button kills that terminal: one left, the list goes.
  await last.hover()
  await last.locator("[data-kill]").click()
  await expect(page.locator("#terminal-list")).toHaveCount(0)
})

test("the activity bar's icons drag too", async ({page}) => {
  await openBee(page)
  const order = () => page.$$eval("#activity-bar [data-container]", s => s.map(x => x.dataset.container))
  expect((await order()).slice(0, 2)).toEqual(["explorer", "search"])
  const explorer = await page.locator("#activity-bar [data-container='explorer']").boundingBox()
  const search = await page.locator("#activity-bar [data-container='search']").boundingBox()
  await page.mouse.move(explorer.x + explorer.width / 2, explorer.y + explorer.height / 2)
  await page.mouse.down()
  // Past the middle of Search (not of Extensions).
  await page.mouse.move(explorer.x + explorer.width / 2, search.y + search.height / 2 + 2, {steps: 8})
  await page.mouse.up()
  await expect.poll(async () => (await order()).slice(0, 2)).toEqual(["search", "explorer"])
})

test("icons and tabs can be hidden, References moved to the panel: remembered", async ({page}) => {
  await openBee(page)
  const icons = () => page.$$eval("#activity-bar [data-container]", s => s.map(x => x.dataset.container))
  const item = command => page.locator(`#context-menu [data-command='workbench.action.${command}']`)
  expect(await icons()).toContain("references")

  // An icon's right-click menu hides it. Explorer has no "Move".
  await page.locator("#view-explorer").click({button: "right"})
  await expect(item("hideViewContainer")).toBeVisible()
  await expect(item("moveViewContainerToPanel")).toHaveCount(0)
  await page.keyboard.press("Escape")
  await page.locator("#view-search").click({button: "right"})
  await item("hideViewContainer").click()
  await expect.poll(icons).not.toContain("search")

  // References: to the panel, a tab there, its view in it.
  await page.locator("#view-references").click({button: "right"})
  await item("moveViewContainerToPanel").click()
  await expect.poll(icons).not.toContain("references")
  await expect(page.locator("#panel-section-references")).toHaveAttribute("aria-selected", "true")
  await expect(page.locator("#panel #references-empty")).toBeVisible()
  await page.screenshot({path: "test-results/references-in-panel.png"})

  // The browser remembers both.
  await page.reload()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  expect(await icons()).toContain("explorer")
  expect(await icons()).not.toContain("search")
  expect(await icons()).not.toContain("references")

  // Show or Hide Views…: the hidden one, picked from the list, is back.
  await page.locator("#activity-bar").click({button: "right", position: {x: 20, y: 300}})
  await item("toggleViewContainer").click()
  await page.fill("#palette-input", "search")
  await page.keyboard.press("Enter")
  await expect.poll(icons).toContain("search")
  await expect(page.locator("#sidebar-title")).toHaveText("Search")

  // The tab's menu takes References back to the activity bar.
  await page.keyboard.press("Control+j")
  await page.locator("#panel-section-references").click({button: "right"})
  await item("moveViewContainerToSideBar").click()
  await expect.poll(icons).toContain("references")
  await expect(page.locator("#panel-section-references")).toHaveCount(0)
  await expect(page.locator("#sidebar-title")).toHaveText("References")
  await page.screenshot({path: "test-results/references-in-sidebar.png"})
})
