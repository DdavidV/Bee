// Editor tabs: dragging, middle click, the right-click menu.
import {expect, freshBee, test} from "./helpers.mjs"
import {openBee, openFile, tabNames} from "./helpers.mjs"

freshBee()

test.beforeEach(async ({page, context, baseURL}) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"], {origin: baseURL})
  await openBee(page)
  await openFile(page, "one.txt")
  await openFile(page, "two.txt")
  await page.click("#explorer button[phx-value-path='src']")
  await page.click("#explorer button[phx-value-path='src/deep']")
  await openFile(page, "src/deep/needle_file.ex")
  expect(await tabNames(page)).toEqual(["one.txt", "two.txt", "needle_file.ex"])
})

test("a held tab lifts and drags to another place", async ({page}) => {
  const one = await page.locator("#tabs [data-path$='/one.txt']").boundingBox()
  const two = await page.locator("#tabs [data-path$='/two.txt']").boundingBox()

  await page.mouse.move(one.x + one.width / 2, one.y + one.height / 2)
  await page.mouse.down()
  await expect(page.locator("#tabs [data-path$='/one.txt'][data-lifted]")).toBeVisible()
  await page.mouse.move(two.x + two.width * 0.9, one.y + one.height / 2, {steps: 8})
  await page.mouse.up()

  await expect.poll(() => tabNames(page)).toEqual(["two.txt", "one.txt", "needle_file.ex"])
})

// A tab moves past another once it covers half of it: a wide tab past a
// narrow one, and a narrow one past a wide one, either way.
for (const [wide, narrow] of [["a_much_longer_file_name.md", "b.ex"], ["b.ex", "a_much_longer_file_name.md"]]) {
  test(`${wide} drags past ${narrow} and back`, async ({page}) => {
    await openFile(page, wide)
    await openFile(page, narrow)
    const drag = async (name, past) => {
      const box = await page.locator(`#tabs [data-path$='/${name}']`).boundingBox()
      const target = await page.locator(`#tabs [data-path$='/${past}']`).boundingBox()
      const y = box.y + box.height / 2
      // Grabbed by its icon (an image): native image dragging mustn't take over.
      await page.mouse.move(box.x + 14, y)
      await page.mouse.down()
      const right = target.x > box.x
      await page.mouse.move(right ? target.x + target.width + 20 : target.x - 20, y, {steps: 10})
      await page.mouse.up()
    }

    await drag(wide, narrow)
    await expect.poll(async () => (await tabNames(page)).slice(-2)).toEqual([narrow, wide])
    await drag(wide, narrow)
    await expect.poll(async () => (await tabNames(page)).slice(-2)).toEqual([wide, narrow])
  })
}

test("a middle click closes a tab", async ({page}) => {
  await page.click("#tabs [data-path$='/two.txt']", {button: "middle"})
  await expect(page.locator("#tabs [data-path$='/two.txt']")).toHaveCount(0)
})

test("the right-click menu: Copy Path, Close Others", async ({page}) => {
  const tab = page.locator("#tabs [data-path$='/needle_file.ex']")
  await tab.click({button: "right"})
  await expect(page.locator("#context-menu [data-command] > span:first-child")).toHaveText([
    "Close",
    "Close Others",
    "Close All",
    "Copy Path",
  ])

  await page.click("#context-menu [data-command='copyFilePath']")
  await expect(page.locator("#context-menu")).toHaveCount(0)
  expect(await page.evaluate(() => navigator.clipboard.readText())).toMatch(/\/src\/deep\/needle_file\.ex$/)

  await tab.click({button: "right"})
  await page.click("#context-menu [data-command='workbench.action.closeOtherEditors']")
  await expect.poll(() => tabNames(page)).toEqual(["needle_file.ex"])
})
