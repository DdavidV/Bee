// Webview panels of VS Code extensions (window.createWebviewPanel), with
// Bee's test webview extension (bee/test/fixtures/extensions/hello-webview),
// installed for these tests: its page is shown in a sandboxed frame.
import {expect, freshBee, test} from "./helpers.mjs"
import {cpSync, rmSync, writeFileSync} from "node:fs"
import {dirname, join, resolve} from "node:path"
import {config} from "../fixtures.mjs"
import {openBee, openFile} from "./helpers.mjs"

freshBee({before: () => install()})

const here = dirname(new URL(import.meta.url).pathname)
const repo = resolve(process.env.BEE_REPO || join(here, "../.."))
const plugin = join(config, "plugins/hello-webview")

// Installed before Bee starts: it loads with it.
const install = () => {
  cpSync(join(repo, "test/fixtures/extensions/hello-webview"), plugin, {recursive: true})
  writeFileSync(join(plugin, ".vsix.json"), JSON.stringify({name: "hello-webview"}))
}

test.afterAll(() => rmSync(plugin, {recursive: true, force: true}))

const run = async (page, title) => {
  await page.keyboard.press("F1")
  await page.fill("#palette-input", `>${title}`)
  await page.keyboard.press("Enter")
}

test.beforeEach(async ({page}) => {
  await openBee(page)
  await page.click("#view-extensions")
  await expect(page.locator("#plugin-hello-webview")).toBeVisible()
  await page.click("#view-explorer")
})

test.afterEach(async ({page}) => {
  // The panels are the workspace's: closed for the next test.
  const tabs = page.locator("#tabs [data-path^='webview:']")
  for (let left = await tabs.count(); left > 0; left--) {
    await tabs.first().locator("[data-close]").click()
    await expect(tabs).toHaveCount(left - 1)
  }
})

test("a panel: the extension's page in a tab, themed, with its files; messages both ways", async ({page}) => {
  await run(page, "Hello Webview: Open Panel")
  const tab = page.locator("#tabs [data-path^='webview:']")
  await expect(tab).toHaveAttribute("data-active", "true")
  await expect(tab).toContainText("Hello Webview")

  const frame = page.frameLocator("[data-webview] iframe")
  await expect(frame.locator("#heading")).toHaveText("first")
  // Its stylesheet and image, from its own folder; not a file outside it.
  await expect(frame.locator("#styled")).toHaveCSS("text-decoration-line", "underline")
  expect(await frame.locator("#logo").evaluate(img => img.complete && img.naturalWidth)).toBe(24)
  await expect(frame.locator("#outside")).toHaveText("outside: 404")
  // VS Code's theme class and colors.
  await expect(frame.locator("#theme")).toHaveText(/^vscode-dark rgb\(/)
  expect(await frame.locator("body").evaluate(body => getComputedStyle(body).getPropertyValue("--vscode-editor-background"))).toMatch(/^#/)
  // What the extension posted before the page was there.
  await expect(frame.locator("#out")).toHaveText("hello")

  // To the extension and back; it renames the panel.
  await frame.locator("#ping").click()
  await expect(frame.locator("#out")).toHaveText("pong 1")
  await expect(tab).toContainText("Pong 1")
  await frame.locator("#ping").click()
  await expect(frame.locator("#state")).toHaveText("pings: 2")

  // New HTML: the page loads again, with the state it kept.
  await run(page, "Hello Webview: Update Panel")
  await expect(frame.locator("#heading")).toHaveText("second")
  await expect(frame.locator("#state")).toHaveText("pings: 2")

  // Another tab and back: the page is as it was (not loaded again).
  await frame.locator("#ping").click()
  await expect(frame.locator("#out")).toHaveText("pong 3")
  await openFile(page, "one.txt")
  await expect(page.locator("[data-webview]")).toBeHidden()
  await tab.click()
  await expect(frame.locator("#out")).toHaveText("pong 3")

  // Bee's keys work with the focus in the page.
  await frame.locator("#heading").click()
  await page.keyboard.press("Control+p")
  await expect(page.locator("#palette-input")).toBeVisible()
  await page.keyboard.press("Escape")

  // Closed by its extension.
  await run(page, "Hello Webview: Close Panel")
  await expect(tab).toHaveCount(0)
  await expect(page.locator("[data-webview]")).toHaveCount(0)
})

test("the page is apart from Bee's: another origin, no way to its page, cookies or storage; no scripts unless allowed", async ({page}) => {
  // Something of Bee's own to keep from the page.
  await page.evaluate(() => localStorage.setItem("bee-secret", "1"))
  await run(page, "Hello Webview: Open Panel")
  const frame = page.frameLocator("[data-webview] iframe")
  await expect(frame.locator("#heading")).toHaveText("first")
  // Served from a port of its own: an origin that isn't Bee's.
  const src = await page.locator("[data-webview] iframe").getAttribute("src")
  expect(src).toMatch(/^http:\/\/127\.0\.0\.1:\d+\/webview\//)
  expect(new URL(src).origin).not.toBe(new URL(page.url()).origin)
  await expect(page.locator("[data-webview] iframe")).toHaveAttribute("sandbox", /^allow-scripts/)

  // What its script found, as its extension logged it.
  await run(page, "View: Show Output")
  await page.selectOption("#output-channel", "Extension Host")
  await expect(page.locator("#output-text")).toContainText(
    `webview loaded: parent blocked, cookie [], storage [], origin ${new URL(src).origin}`,
  )
  await page.keyboard.press("Control+j")

  // Bee's own pages aren't served there.
  const other = await page.request.get(new URL(src).origin + "/")
  expect(other.status()).toBe(404)

  // A panel without enableScripts.
  await run(page, "Hello Webview: Open Plain Panel")
  const plain = page.frameLocator("[data-webview]:not(.hidden) iframe")
  await expect(plain.locator("#plain")).toHaveText("no scripts")
  await expect(page.locator("[data-webview]:not(.hidden) iframe")).toHaveAttribute("sandbox", "allow-forms allow-same-origin")
})

test("links to the web, and addresses the extension opens, go to the browser", async ({page, context}) => {
  await context.route("https://example.com/**", route => route.fulfill({body: "example"}))
  await run(page, "Hello Webview: Open Panel")
  const frame = page.frameLocator("[data-webview] iframe")

  const [fromPage] = await Promise.all([context.waitForEvent("page"), frame.locator("#link").click()])
  expect(fromPage.url()).toBe("https://example.com/docs")
  await fromPage.close()
  // The panel's page stays.
  await expect(frame.locator("#heading")).toHaveText("first")

  const [fromExtension] = await Promise.all([context.waitForEvent("page"), run(page, "Hello Webview: Open Example")])
  expect(fromExtension.url()).toBe("https://example.com/from-extension")
  await fromExtension.close()
})

test("a page that embeds its extension's local server: the frame inside has its origin and works", async ({page}) => {
  await run(page, "Hello Webview: Open Nested Panel")
  const tab = page.locator("#tabs [data-path^='webview:']")
  // The inner frame talked to its server, from its own origin (a page
  // without an origin can't: that is why webviews have one).
  await expect(tab).toContainText("Nested: pong from its own origin")
  const inner = page.frameLocator("[data-webview] iframe").frameLocator("#nested")
  await expect(inner.locator("#inner")).toHaveText("inner pong")
})
