// Quick Open: the title bar's search box (Ctrl+P): recent files, files by
// name, ">" for commands.
import {expect, freshBee, test} from "./helpers.mjs"
import {openBee, openFile} from "./helpers.mjs"

freshBee()

test("recent files, then files by name; > switches to commands", async ({page}) => {
  await openBee(page)
  await page.click("#explorer button[phx-value-path='lib']")
  await openFile(page, "lib/a.ex")

  await page.click("#command-center")
  await expect(page.locator("#palette-input")).toBeFocused()
  await expect(page.locator("#palette [data-mode='>']")).toHaveText(/Show and Run Commands/)
  await expect(page.locator("#palette [data-file$='/lib/a.ex']")).toBeVisible()

  // Typing searches the folder's files, deep ones too.
  await page.keyboard.type("needle")
  await expect(page.locator("#palette [data-file$='/src/deep/needle_file.ex']")).toBeVisible()
  await expect(page.locator("#palette-busy")).toHaveCount(0)
  await page.keyboard.press("Enter")
  await expect(page.locator("[data-tabs] [data-path$='/needle_file.ex']")).toBeVisible()
  await expect(page.locator("#palette")).toHaveCount(0)

  // The commands entry turns the query into ">".
  await page.keyboard.press("Control+p")
  await page.click("#palette [data-mode='>']")
  await expect(page.locator("#palette-input")).toHaveValue(">")
  await page.keyboard.type("toggle panel")
  await expect(page.locator("#palette [data-command='workbench.action.togglePanel'][aria-selected=true]")).toBeVisible()

  // Without the ">", files again.
  await page.fill("#palette-input", "a.e")
  await expect(page.locator("#palette [data-file$='/lib/a.ex']")).toBeVisible()
  await page.keyboard.press("Escape")

  await page.keyboard.press("Control+Shift+P")
  await expect(page.locator("#palette-input")).toHaveValue(">")
})

test("the palette opens with the cursor after its >: typing adds to it", async ({page}) => {
  await openBee(page)
  await page.keyboard.press("Control+Shift+p")
  await expect(page.locator("#palette-input")).toHaveValue(">")
  await page.keyboard.type("toggle panel")
  await expect(page.locator("#palette-input")).toHaveValue(">toggle panel")
  await expect(page.locator("#palette [data-command='workbench.action.togglePanel']")).toBeVisible()
  await page.keyboard.press("Escape")
})
