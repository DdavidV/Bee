// Searching Open VSX from the Plugins view, like VS Code's Extensions view:
// typing searches (debounced: not a request per key), results replace the
// installed plugins, a result's details page, installing one (a color
// theme, so it shows up in the theme picker) – the package for this
// machine's platform –, Escape, and Open VSX's rate limit. Open VSX is the stand-in from mock-open-vsx.mjs.
import {expect, freshBee, test} from "./helpers.mjs"
import {hostPlatform, mockUrl} from "../mock-open-vsx.mjs"
import {openBee} from "./helpers.mjs"

freshBee()

const requests = async () => (await (await fetch(`${mockUrl}/__requests`)).json()).requests
const resetRequests = () => fetch(`${mockUrl}/__reset`)
const downloadedPlatforms = async () => (await (await fetch(`${mockUrl}/__downloads`)).json()).platforms

const rocketRow = page => page.locator("#openvsx-acme\\.rocket")

test("search, details, install and uninstall", async ({page}) => {
  await resetRequests()
  await openBee(page)
  await page.click("#view-extensions")

  const box = page.locator("#marketplace-query")
  await expect(box).toBeVisible()
  await expect(page.locator("#plugins-workbench\\.extensions\\.installed")).toBeVisible()

  // Typed key by key: one search once typing stops.
  await box.pressSequentially("rocket", {delay: 60})
  await expect(rocketRow(page)).toBeVisible()
  await expect(page.locator("#plugins-workbench\\.extensions\\.installed")).toHaveCount(0)
  expect(await requests()).toBe(1)

  await expect(rocketRow(page)).toContainText("Rocket")
  await expect(rocketRow(page)).toContainText("12.3K")
  await expect(rocketRow(page).locator("img")).toHaveJSProperty("complete", true)
  await expect(page.locator("#marketplace > [data-id]")).toHaveCount(30)
  await page.click("#marketplace-more")
  await expect(page.locator("#marketplace > [data-id]")).toHaveCount(41)
  await expect(page.locator("#marketplace-more")).toHaveCount(0)
  expect(await requests()).toBe(2)

  // Its details: the README from Open VSX, sanitized.
  await rocketRow(page).locator("span", {hasText: "Rocket"}).first().click()
  const tab = page.locator("#tabs [data-path='extension:acme.rocket']")
  await expect(tab).toHaveText(/Extension: Rocket/)
  const details = page.locator("#extension-acme\\.rocket")
  await expect(details.locator("header h1")).toHaveText("Rocket")
  await expect(details).toContainText("ACME Corp")
  const readme = page.locator("#extension-acme\\.rocket-readme")
  await expect(readme.locator("strong")).toHaveText("theme")
  await expect(readme.locator("script")).toHaveCount(0)
  expect(await page.evaluate(() => window.readmeRan)).toBeUndefined()

  // The package for this machine's platform.
  await expect(page.locator("#extension-acme\\.rocket-platform")).toHaveAttribute("data-platform", hostPlatform)

  // Install, from the page: that package.
  await details.locator("button", {hasText: "Install"}).click()
  await expect(details.locator("button", {hasText: "Uninstall"})).toBeVisible()
  expect((await downloadedPlatforms()).at(-1)).toBe(hostPlatform)
  await expect(rocketRow(page)).toContainText("installed")
  await expect(rocketRow(page).locator("button", {hasText: "Install"})).toHaveCount(0)

  // Its theme is there to pick.
  await page.keyboard.press("Control+k")
  await page.keyboard.press("Control+t")
  await expect(page.locator("#palette-items")).toContainText("Rocket Theme")
  await page.keyboard.press("Escape")

  // Escape in the box: the installed plugins again, with it.
  await box.click()
  await page.keyboard.press("Escape")
  await expect(box).toHaveValue("")
  await expect(page.locator("#plugin-rocket")).toBeVisible()
  await expect(page.locator("#marketplace")).toHaveCount(0)

  // Uninstalled (confirmed), the search shows Install again – the
  // results come from the cache.
  const before = await requests()
  await page.locator("#plugin-rocket [data-command='bee.plugins.uninstall']").click()
  await page.locator("#palette-items [role=option]", {hasText: "Uninstall"}).click()
  await expect(page.locator("#plugin-rocket")).toHaveCount(0)
  await box.fill("rocket")
  await expect(rocketRow(page).locator("button", {hasText: "Install"})).toBeVisible()
  expect(await requests()).toBe(before)
  await box.fill("")
})

test("an extension without a package for this platform can't be installed", async ({page}) => {
  await openBee(page)
  await page.click("#view-extensions")
  await page.locator("#marketplace-query").fill("alien")
  await page.locator("#openvsx-acme\\.alien").click()
  await expect(page.locator("#extension-acme\\.alien-unavailable")).toHaveText(
    `Not available for ${hostPlatform} (only for web).`,
  )
  await expect(page.locator("#extension-acme\\.alien button", {hasText: "Install"})).toHaveCount(0)
  await page.locator("#tabs [data-path='extension:acme.alien'] [data-close]").click()
  await page.locator("#marketplace-query").fill("")
})

test("Open VSX's rate limit is shown, not retried", async ({page}) => {
  await openBee(page)
  await page.click("#view-extensions")
  await resetRequests()
  await page.locator("#marketplace-query").fill("ratelimit")
  await expect(page.locator("#marketplace-error")).toContainText("limiting Bee's requests")
  // Try again while it lasts: not sent.
  await page.locator("#marketplace-error button", {hasText: "Try again"}).click()
  await expect(page.locator("#marketplace-error")).toContainText("try again in")
  expect(await requests()).toBe(1)
  // Its Retry-After is a second; then other searches work.
  await page.waitForTimeout(1100)
  await page.locator("#marketplace-query").fill("rocket")
  await expect(rocketRow(page)).toBeVisible()
  await page.locator("#marketplace-query").fill("")
})
