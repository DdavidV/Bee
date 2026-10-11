// Notifications, like VS Code's: messages pop up at the bottom right and
// stay in the list the status bar's bell opens; what an extension is busy
// with (window.withProgress) spins there until it is done. With Bee's test
// extension (bee/test/fixtures/extensions/hello).
import {cpSync, rmSync, writeFileSync} from "node:fs"
import {dirname, join, resolve} from "node:path"
import {config} from "../fixtures.mjs"
import {
  bell, dismiss, error, expect, freshBee, info, notificationCenter, openBee, runCommand, statusBar, test, warning,
} from "./helpers.mjs"

freshBee({before: () => install()})

const here = dirname(new URL(import.meta.url).pathname)
const repo = resolve(process.env.BEE_REPO || join(here, "../.."))
const plugin = join(config, "plugins/hello")

const install = () => {
  cpSync(join(repo, "test/fixtures/extensions/hello"), plugin, {recursive: true})
  writeFileSync(join(plugin, ".vsix.json"), JSON.stringify({name: "hello"}))
}

test.afterAll(() => rmSync(plugin, {recursive: true, force: true}))

test.beforeEach(async ({page}) => {
  await openBee(page)
  await page.click("#view-extensions")
  await expect(page.locator("#plugin-hello")).toBeVisible()
  await page.click("#view-explorer")
})

// A command the extension registers as it runs (not in its package.json).
const run = (page, command, args = []) =>
  page.evaluate(([command, args]) => {
    const main = document.querySelector("[data-phx-main]")
    window.liveSocket.execJS(main, JSON.stringify([["push", {event: "run_command", value: {command, args: JSON.stringify(args)}}]]))
  }, [command, args])

test("messages pop up at the bottom right and stay in the bell's list", async ({page}) => {
  await expect(bell(page)).toHaveAttribute("title", "No Notifications")
  await runCommand(page, "Hello: Say Hello")
  await expect(info(page)).toContainText("Hello from the hello extension")

  // At the bottom right, above the status bar.
  const box = await info(page).boundingBox()
  const bar = await statusBar(page).boundingBox()
  const width = page.viewportSize().width
  expect(box.x + box.width).toBeGreaterThan(width - 40)
  expect(box.y + box.height).toBeLessThanOrEqual(bar.y)
  expect(box.y).toBeGreaterThan(bar.y / 2)

  await run(page, "hello.broken")
  await expect(error(page)).toContainText("broken on purpose")
  await expect(bell(page)).toHaveAttribute("title", "2 Notifications")

  // The bell: the list instead of the toasts; Escape hides it.
  await bell(page).click()
  await expect(page.locator("#notification-toasts")).toHaveCount(0)
  await expect(notificationCenter(page)).toContainText("Notifications")
  await expect(notificationCenter(page).locator("li")).toHaveCount(2)
  await expect(notificationCenter(page).locator("li").first()).toContainText("broken on purpose")
  await page.keyboard.press("Escape")
  await expect(notificationCenter(page)).toHaveCount(0)

  // One by one, or all at once.
  await bell(page).click()
  await dismiss(notificationCenter(page).locator("li").first())
  await expect(notificationCenter(page).locator("li")).toHaveCount(1)
  await page.click("#notifications-clear")
  await expect(notificationCenter(page)).toHaveCount(0)
  await expect(bell(page)).toHaveAttribute("title", "No Notifications")
  await bell(page).click()
  await expect(notificationCenter(page)).toContainText("No New Notifications")
})

test("what an extension is busy with spins until it is done, or cancelled", async ({page}) => {
  await runCommand(page, "Hello: Say Hello")
  await expect(info(page)).toContainText("from the hello extension")
  await dismiss(info(page))

  await run(page, "hello.progress")
  const spinner = page.locator("#status-progress")
  await expect(spinner).toContainText("Building: step 1")
  const toast = page.locator("#notification-toasts [data-progress=hello]")
  await expect(toast).toContainText("40%")

  // In the list too, with where it comes from.
  await spinner.click()
  const entry = notificationCenter(page).locator("[data-progress=hello]")
  await expect(entry).toContainText("Building: step 1")
  await expect(entry).toContainText("Source: hello")

  await entry.getByRole("button", {name: "Cancel"}).click()
  await expect(spinner).toHaveCount(0)
  await expect(entry).toHaveCount(0)
  // (What the extension says about it: a warning.)
  await expect(notificationCenter(page).locator("li[data-severity=warning]")).toContainText("cancelled")
  await page.keyboard.press("Escape")
  await run(page, "hello.progress")
  await expect(spinner).toBeVisible()
  await expect(warning(page)).toHaveCount(0)
})
