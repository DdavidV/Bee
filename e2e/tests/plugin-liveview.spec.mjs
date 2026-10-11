// A plugin's own LiveViews (Bee.Plugin.LiveView): Bee's todos-live example
// (bee/examples/plugins/todos-live), installed for these tests – a view in
// the sidebar and a board in an editor tab, with the plugin's stylesheet
// and its hook; a crash in it, and a reload of it.
import {expect, freshBee, test} from "./helpers.mjs"
import {cpSync, readFileSync, rmSync, writeFileSync} from "node:fs"
import {dirname, join, resolve} from "node:path"
import {config, dws} from "../fixtures.mjs"
import {info, openBee} from "./helpers.mjs"

freshBee({before: () => install()})

const here = dirname(new URL(import.meta.url).pathname)
const repo = resolve(process.env.BEE_REPO || join(here, "../.."))
const plugin = join(config, "plugins/todos-live")
const notes = join(dws, "todo-notes.md")

// Installed before Bee starts: it loads with it.
const install = () => {
  writeFileSync(notes, "- TODO: buy milk\n- FIXME: the door squeaks\n")
  cpSync(join(repo, "examples/plugins/todos-live"), plugin, {recursive: true})
}

test.afterAll(() => {
  rmSync(plugin, {recursive: true, force: true})
  rmSync(notes, {force: true})
})

const list = page => page.locator("#todos-live-list")
const items = page => page.locator("#todos-live-list li")

test.beforeEach(async ({page}) => {
  await openBee(page)
  // Bee notices the new plugin folder by itself: its icon appears.
  await page.click("#view-todos-live")
  await expect(list(page)).toBeVisible()
})

test("a view drawn by the plugin's LiveView, in the plugin's styles", async ({page}) => {
  await expect(page.locator("#sidebar-title")).toHaveText("TODOs (LiveView)")
  await expect(items(page)).toHaveText([/TODO\s*buy milk\s*todo-notes\.md:1/, /FIXME\s*the door squeaks\s*todo-notes\.md:2/])

  // Its stylesheet is the page's, with the theme's colors.
  const input = page.locator("#todos-live-filter")
  const [background, expected] = await input.evaluate(el => [
    getComputedStyle(el).backgroundColor,
    (() => {
      const probe = document.createElement("div")
      probe.style.background = "var(--vscode-input-background)"
      el.parentElement.append(probe)
      const color = getComputedStyle(probe).backgroundColor
      probe.remove()
      return color
    })(),
  ])
  expect(background).toBe(expected)
  expect(await items(page).first().evaluate(el => getComputedStyle(el).cursor)).toBe("pointer")

  // Its own events and state: the filter.
  await input.fill("door")
  await expect(items(page)).toHaveCount(1)
  await expect(items(page)).toContainText("the door squeaks")
  await input.fill("nothing like it")
  await expect(list(page)).toContainText("No TODO matches.")

  // Its hook, from the plugin's browser part: Escape empties the box.
  await input.press("Escape")
  await expect(input).toHaveValue("")
  await expect(items(page)).toHaveCount(2)

  // A click runs the plugin's command in the window: the file, at the line.
  await items(page).nth(1).click()
  await expect(page.locator("[data-tabs] [data-path$='/todo-notes.md']")).toHaveAttribute("data-active", "true")
  await expect(page.locator("#editor .cm-activeLine")).toHaveText("- FIXME: the door squeaks")
})

test("an editor tab drawn by the plugin's LiveView", async ({page}) => {
  await page.click("#todos-live-list button:has-text('Open Board')")
  const tab = page.locator("[data-tabs] [data-path='live:todos-live/todosLive.board']")
  await expect(tab).toHaveText(/TODO Board/)
  await expect(tab).toHaveAttribute("data-active", "true")

  const board = page.locator("#todos-live-board")
  await expect(board.locator("h1")).toHaveText("TODO Board")
  await expect(board.locator("[data-column=TODO] .todos-live-card")).toHaveText(/buy milk/)
  await expect(board.locator("[data-column=FIXME] .todos-live-card")).toHaveText(/the door squeaks/)
  // Two columns side by side (the stylesheet's grid).
  const [todo, fixme] = await Promise.all(["TODO", "FIXME"].map(kind => board.locator(`[data-column=${kind}]`).boundingBox()))
  expect(fixme.x).toBeGreaterThan(todo.x + todo.width - 1)

  // Its state stays while the tab is open, also behind another tab.
  await board.locator("[data-column=TODO] input[type=checkbox]").check()
  await expect(board.locator(".todos-live-count")).toContainText("1 ticked off")
  await page.click("#view-explorer")
  await page.click("#explorer button[phx-value-path='one.txt']")
  await expect(board).toBeHidden()
  await tab.click()
  await expect(board.locator(".todos-live-count")).toContainText("1 ticked off")
  await expect(board.locator("[data-column=TODO] input[type=checkbox]")).toBeChecked()

  // The server part tells its LiveViews about changes: the board and the view.
  writeFileSync(notes, "- TODO: buy milk\n- FIXME: the door squeaks\n- TODO: call mum\n")
  await expect(board.locator("[data-column=TODO] .todos-live-card")).toHaveCount(2)
  await page.click("#view-todos-live")
  await expect(items(page)).toHaveCount(3)
  writeFileSync(notes, "- TODO: buy milk\n- FIXME: the door squeaks\n")
  await expect(items(page)).toHaveCount(2)

  // Closing the tab ends it.
  await tab.locator("[data-close]").click()
  await expect(board).toHaveCount(0)
})

test("a crash in the plugin's LiveView is its own: the window goes on", async ({page}) => {
  const errors = []
  page.on("pageerror", error => errors.push(error.message))
  await page.locator("#todos-live-filter").fill("milk")
  await expect(items(page)).toHaveCount(1)

  // An event its code raises on ("line" isn't a number).
  const window_ = await page.evaluate(() => (window.beeTestSamePage = true))
  expect(window_).toBe(true)
  await page.evaluate(() => {
    const el = document.querySelector("#todos-live-list li")
    window.liveSocket.execJS(el, JSON.stringify([["push", {event: "open", value: {path: "a", line: "x"}}]]))
  })

  // It starts again by itself: a new process (LiveView gives it the form
  // back as it was, so the filter is applied again)…
  await expect(page.locator("#todos-live-list")).toBeVisible()
  await expect(page.locator("#todos-live-filter")).toHaveValue("milk")
  await expect(items(page)).toHaveCount(1)
  await expect(async () => {
    await page.locator("#todos-live-filter").fill("")
    await expect(items(page)).toHaveCount(2, {timeout: 1500})
  }).toPass()
  // …and the window never went away: the same page, still connected.
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  expect(await page.evaluate(() => window.beeTestSamePage)).toBe(true)
  await expect(page.locator("#sidebar-title")).toHaveText("TODOs (LiveView)")
  await page.click("#view-explorer")
  await page.click("#explorer button[phx-value-path='two.txt']")
  await expect(page.locator("[data-tabs] [data-path$='/two.txt']")).toBeVisible()
  expect(errors).toEqual([])
})

// (Developer: Reload Plugins, not Bee's file watcher: that one can miss
// the folders of a plugin copied in while Bee runs.)
const reloadPlugins = async page => {
  await page.keyboard.press("F1")
  await page.fill("#palette-input", ">Reload Plugins")
  await page.keyboard.press("Enter")
  await expect(info(page)).toContainText("Plugins reloaded")
}

test("a changed plugin, reloaded: its LiveView is mounted afresh", async ({page}) => {
  const file = join(plugin, "lib/todos_live/list_live.ex")
  const source = readFileSync(file, "utf8")
  await expect(page.locator("#todos-live-filter")).toHaveAttribute("placeholder", "Filter TODOs")
  try {
    writeFileSync(file, source.replace("Filter TODOs", "Find a TODO"))
    await reloadPlugins(page)
    await expect(page.locator("#todos-live-filter")).toHaveAttribute("placeholder", "Find a TODO")
    await expect(items(page)).toHaveCount(2)
  } finally {
    writeFileSync(file, source)
  }
  await reloadPlugins(page)
  await expect(page.locator("#todos-live-filter")).toHaveAttribute("placeholder", "Filter TODOs")
})
