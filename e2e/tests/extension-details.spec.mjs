// A plugin's details page (VS Code's extension editor): opened from the
// Plugins view in an editor tab, its README rendered (and sanitized), its
// Features, its theme buttons; keys there never reach the file behind it.
import {expect, freshBee, test} from "./helpers.mjs"
import {openBee, openFile} from "./helpers.mjs"

freshBee()

test("plugin details in an editor tab", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  await page.click("#view-extensions")
  await page.click("#plugin-test-theme")

  const tab = page.locator("[data-tabs] [data-path='extension:test-theme']")
  await expect(tab).toHaveText(/Extension: test-theme/)
  await expect(tab).toHaveAttribute("data-active", "true")

  // The README: Markdown rendered, its script and handlers gone.
  const readme = page.locator("#extension-test-theme-readme")
  await expect(readme.locator("h1")).toHaveText("Test Theme")
  await expect(readme.locator("strong")).toHaveText("theme")
  await expect(readme.locator("a")).toHaveAttribute("href", "https://example.com/bee")
  await expect(readme.locator("pre code")).toContainText("const a = 1")
  await expect(readme.locator("script")).toHaveCount(0)
  expect(await readme.locator("img").getAttribute("onerror")).toBeNull()
  expect(await page.evaluate(() => window.readmeRan)).toBeUndefined()

  // Features: its color theme.
  await page.click("#extension-test-theme-tab-features")
  await expect(page.locator("#extension-test-theme-features")).toContainText("Test Theme")
  await expect(page.locator("#extension-test-theme-details")).toBeHidden()

  // Set Color Theme: a pick of its themes only.
  await page.click("#extension-test-theme [data-command='workbench.action.selectTheme']")
  await expect(page.locator("#palette-items [role=option]")).toHaveCount(1)
  await expect(page.locator("#palette-items")).toContainText("Test Theme")
  await page.keyboard.press("Escape")

  // Typing here doesn't edit the file behind the page.
  await page.click("#extension-test-theme h1")
  await page.keyboard.type("xyz")
  await page.click("[data-tabs] [data-path$='/one.txt']")
  await expect(page.locator(".cm-content")).toHaveText("one")
  await expect(page.locator("[data-tabs] [data-path$='/one.txt']")).not.toHaveAttribute("data-dirty", "true")

  // And back: the page again; closed with its tab's x.
  await tab.click()
  await expect(page.locator("#extension-test-theme")).toBeVisible()
  await tab.locator("[data-close]").click()
  await expect(tab).toHaveCount(0)
  await expect(page.locator(".cm-content")).toHaveText("one")
})
