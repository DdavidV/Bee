// The command palette and its lists: finding a command by parts of its
// name, the keys that move in it, and what it leaves out.
import {expect, freshBee, openBee, openFile, palette, paletteInput, paletteItems, panel, sidebar, test} from "./helpers.mjs"

freshBee()

const selected = page => page.locator("#palette [role=option][aria-selected=true]")

test("typing narrows the commands; parts of words in any case are enough", async ({page}) => {
  await openBee(page)
  await page.keyboard.press("F1")
  await expect(paletteItems(page).first()).toBeVisible()
  const all = await paletteItems(page).count()
  expect(all).toBeGreaterThan(20)

  await paletteInput(page).fill(">TOGGLE PANEL")
  await expect(paletteItems(page).filter({hasText: "Toggle Panel Visibility"})).toBeVisible()
  expect(await paletteItems(page).count()).toBeLessThan(all)

  await paletteInput(page).fill(">tog pan")
  await expect(paletteItems(page).filter({hasText: "Toggle Panel Visibility"})).toBeVisible()

  await paletteInput(page).fill(">zzzz no such command")
  await expect(paletteItems(page).filter({hasText: "Toggle"})).toHaveCount(0)
})

test("commands are listed with their category and their key", async ({page}) => {
  await openBee(page)
  await page.keyboard.press("F1")
  await paletteInput(page).fill(">Open Keyboard Shortcuts")
  const item = paletteItems(page).filter({hasText: "Open Keyboard Shortcuts (JSON)"})
  await expect(item).toContainText("Preferences")
  await expect(item).toContainText("Ctrl+K Ctrl+S")
})

test("the arrows choose, Enter runs, Escape and a click elsewhere give up", async ({page}) => {
  await openBee(page)
  await page.keyboard.press("F1")
  await paletteInput(page).fill(">Toggle P")
  await expect(selected(page)).toHaveCount(1)
  const first = await selected(page).textContent()
  await page.keyboard.press("ArrowDown")
  await expect(selected(page)).not.toHaveText(first)
  await page.keyboard.press("ArrowUp")
  await expect(selected(page)).toHaveText(first)

  await page.keyboard.press("Escape")
  await expect(palette(page)).toHaveCount(0)
  await expect(panel(page)).toHaveCount(0)

  await page.keyboard.press("F1")
  await paletteInput(page).fill(">Toggle Panel Visibility")
  await expect(palette(page)).toBeVisible()
  await page.getByRole("main").click({position: {x: 300, y: 400}})
  await expect(palette(page)).toHaveCount(0)

  await page.keyboard.press("F1")
  await paletteInput(page).fill(">Toggle Panel Visibility")
  await expect(selected(page)).toContainText("Toggle Panel Visibility")
  await page.keyboard.press("Enter")
  await expect(panel(page)).toBeVisible()
  await expect(palette(page)).toHaveCount(0)
})

test("a click on a command runs it", async ({page}) => {
  await openBee(page)
  await page.keyboard.press("F1")
  await paletteInput(page).fill(">Toggle Primary Side Bar")
  await paletteItems(page).filter({hasText: "Toggle Primary Side Bar Visibility"}).click()
  await expect(sidebar(page)).toBeHidden()
})

test("commands that need something are left out until it is there", async ({page}) => {
  await openBee(page)
  const offered = async title => {
    await page.keyboard.press("F1")
    await paletteInput(page).fill(`>${title}`)
    const found = await paletteItems(page).filter({hasText: title}).first().waitFor({timeout: 700}).then(() => true, () => false)
    await page.keyboard.press("Escape")
    await expect(palette(page)).toHaveCount(0)
    return found
  }
  // No file open: nothing to save or close. No terminal: none to kill.
  expect(await offered("File: Save")).toBe(false)
  expect(await offered("View: Close Editor")).toBe(false)
  expect(await offered("Terminal: Kill Terminal")).toBe(false)

  await openFile(page, "one.txt")
  expect(await offered("File: Save")).toBe(true)
  expect(await offered("View: Close Editor")).toBe(true)

  // Commands that are only steps of others are never listed.
  expect(await offered("Delete (confirmed)")).toBe(false)
  expect(await offered("Open File (path)")).toBe(false)
})

test("View: Close All and Close Others", async ({page}) => {
  await openBee(page)
  for (const name of ["one.txt", "two.txt", "b.ex"]) await openFile(page, name)
  const run = async title => {
    await page.keyboard.press("F1")
    await paletteInput(page).fill(`>${title}`)
    await paletteItems(page).filter({hasText: title}).first().click()
  }
  await run("View: Close Others")
  await expect(page.locator("[data-tabs] [data-tab]")).toHaveCount(1)
  await expect(page.locator("[data-tabs]")).toContainText("b.ex")
  await run("View: Close All")
  await expect(page.locator("[data-tabs] [data-tab]")).toHaveCount(0)
})

test("Quick Open remembers the files opened, most recent first, across windows", async ({page, context}) => {
  await openBee(page)
  await openFile(page, "two.txt")
  await openFile(page, "one.txt")

  const other = await context.newPage()
  await openBee(other)
  await other.keyboard.press("Control+p")
  const files = other.locator("#palette [data-file]")
  await expect(files.first()).toContainText("one.txt")
  await expect(files.nth(1)).toContainText("two.txt")
  await files.first().click()
  await expect(other.locator("[data-tabs]")).toContainText("one.txt")
})
