// The editor area split into groups, as in VS Code: to the right and
// down, each group with its own tabs; one file in two groups showing the
// same text as it is typed; tabs dragged from group to group.
import {join} from "node:path"
import {
  contextMenu, dws, expect, expectFile, explorerItem, focusedGroup, freshBee, group, groups, menuItem, openBee, openFile,
  openMenu, read, runCommand, test, unsaved, write,
} from "./helpers.mjs"

freshBee({before: () => write(join(dws, "poem.txt"), "roses are red\nviolets are blue\n")})

test.beforeEach(() => write(join(dws, "poem.txt"), "roses are red\nviolets are blue\n"))

const box = locator => locator.boundingBox()
// Drags `tab` to a point: pressed, moved in steps (it lifts), released.
const drag = async (page, tab, to) => {
  const from = await box(tab)
  await page.mouse.move(from.x + from.width / 2, from.y + from.height / 2)
  await page.mouse.down()
  await page.mouse.move(from.x + from.width / 2 + 10, from.y + from.height / 2, {steps: 2})
  await page.mouse.move(to.x, to.y, {steps: 8})
  await page.mouse.up()
}
const middle = async locator => {
  const b = await box(locator)
  return {x: b.x + b.width / 2, y: b.y + b.height / 2}
}

test("Split Editor Right: a second group beside the first, with the same file", async ({page}) => {
  await openBee(page)
  await openFile(page, "poem.txt")
  await expect(groups(page)).toHaveCount(1)

  await runCommand(page, "View: Split Editor Right")
  await expect(groups(page)).toHaveCount(2)
  const [left, right] = [group(page, 1), group(page, 2)]
  expect(await left.names()).toEqual(["poem.txt"])
  expect(await right.names()).toEqual(["poem.txt"])
  await expect(left.lines.first()).toHaveText("roses are red")
  await expect(right.lines.first()).toHaveText("roses are red")

  // Side by side, each about half; the new one has the focus.
  const [a, b] = [await box(left.root), await box(right.root)]
  expect(b.x).toBeGreaterThanOrEqual(a.x + a.width - 2)
  expect(Math.abs(a.width - b.width)).toBeLessThan(10)
  expect(Math.abs(a.y - b.y)).toBeLessThan(2)
  await expect(right.root).toHaveAttribute("data-focused", "true")
  await expect(right.editor).toBeFocused()
})

test("Split Editor Down: below; its button, key and menu entries", async ({page}) => {
  await openBee(page)
  await openFile(page, "poem.txt")

  await page.keyboard.press("Control+k")
  await page.keyboard.press("Control+\\")
  await expect(groups(page)).toHaveCount(2)
  const [a, b] = [await box(group(page, 1).root), await box(group(page, 2).root)]
  expect(b.y).toBeGreaterThanOrEqual(a.y + a.height - 2)
  expect(Math.abs(a.x - b.x)).toBeLessThan(2)

  // The button above the editor splits to the right; so does Ctrl+\.
  await page.getByRole("button", {name: /^Split Editor Right/}).click()
  await expect(groups(page)).toHaveCount(3)
  await page.keyboard.press("Control+\\")
  await expect(groups(page)).toHaveCount(4)

  // In the View menu and a tab's menu too.
  await expect(menuItem(await openMenu(page, "View"), "Split Editor Right")).toBeVisible()
  await page.keyboard.press("Escape")
  await group(page, 1).tab("poem.txt").click({button: "right"})
  await menuItem(contextMenu(page), "Split Editor Down").click()
  await expect(groups(page)).toHaveCount(5)
})

test("nothing to split without a file", async ({page}) => {
  await openBee(page)
  await page.keyboard.press("Control+\\")
  await page.waitForTimeout(300)
  await expect(groups(page)).toHaveCount(1)
})

test("one file in two groups: what is typed in one shows in the other, as it is typed", async ({page}) => {
  await openBee(page)
  await openFile(page, "poem.txt")
  await runCommand(page, "View: Split Editor Right")
  const [left, right] = [group(page, 1), group(page, 2)]

  await right.lines.first().click()
  await page.keyboard.press("End")
  await page.keyboard.type(", mostly")
  await expect(right.lines.first()).toHaveText("roses are red, mostly")
  await expect(left.lines.first()).toHaveText("roses are red, mostly")
  // Unsaved in both.
  await expect(unsaved(left.tab("poem.txt"))).toHaveCount(1)
  await expect(unsaved(right.tab("poem.txt"))).toHaveCount(1)

  // And the other way; each keeps its own cursor.
  await left.lines.nth(1).click()
  await page.keyboard.press("Home")
  await page.keyboard.type("but ")
  await expect(left.lines.nth(1)).toHaveText("but violets are blue")
  await expect(right.lines.nth(1)).toHaveText("but violets are blue")
  await right.lines.first().click()
  await page.keyboard.press("End")
  await page.keyboard.type("!")
  await expect(left.lines.first()).toHaveText("roses are red, mostly!")
  await expect(left.lines.nth(1)).toHaveText("but violets are blue")

  // New lines and deletions too.
  await page.keyboard.press("Enter")
  await page.keyboard.type("a new line")
  await expect(left.lines).toHaveText(["roses are red, mostly!", "a new line", "but violets are blue", ""])

  // Saved once: on disk, and saved in both.
  await page.keyboard.press("Control+s")
  await expectFile(join(dws, "poem.txt"), "roses are red, mostly!\na new line\nbut violets are blue\n")
  await expect(unsaved(left.tab("poem.txt"))).toHaveCount(0)
  await expect(unsaved(right.tab("poem.txt"))).toHaveCount(0)
})

test("undo takes back what was typed in that group, in both", async ({page}) => {
  await openBee(page)
  await openFile(page, "poem.txt")
  await runCommand(page, "View: Split Editor Right")
  const [left, right] = [group(page, 1), group(page, 2)]
  await right.lines.first().click()
  await page.keyboard.press("End")
  await page.keyboard.type("!!")
  await expect(left.lines.first()).toHaveText("roses are red!!")
  await page.keyboard.press("Control+z")
  await expect(right.lines.first()).toHaveText("roses are red")
  await expect(left.lines.first()).toHaveText("roses are red")
})

test("a file changed on disk, or by a command, changes in both", async ({page}) => {
  await openBee(page)
  await openFile(page, "poem.txt")
  await runCommand(page, "View: Split Editor Right")
  const [left, right] = [group(page, 1), group(page, 2)]
  write(join(dws, "poem.txt"), "all new\n")
  await expect(left.lines.first()).toHaveText("all new")
  await expect(right.lines.first()).toHaveText("all new")
})

test("each group has its own tabs; files open in the focused one", async ({page}) => {
  await openBee(page)
  await openFile(page, "poem.txt")
  await runCommand(page, "View: Split Editor Right")
  const [left, right] = [group(page, 1), group(page, 2)]

  await openFile(page, "one.txt")
  expect(await left.names()).toEqual(["poem.txt"])
  expect(await right.names()).toEqual(["poem.txt", "one.txt"])
  await expect(right.lines.first()).toHaveText("one")
  await expect(left.lines.first()).toHaveText("roses are red")

  // A click into the other group's editor: files open there now.
  await left.lines.first().click()
  await expect(left.root).toHaveAttribute("data-focused", "true")
  await openFile(page, "two.txt")
  expect(await left.names()).toEqual(["poem.txt", "two.txt"])
  expect(await right.names()).toEqual(["poem.txt", "one.txt"])

  // A click on a tab shows it in its group, and focuses that group.
  await right.tab("poem.txt").click()
  await expect(right.activeTab).toContainText("poem.txt")
  await expect(right.root).toHaveAttribute("data-focused", "true")
  await expect(left.activeTab).toContainText("two.txt")
  // The window is about the focused group's file.
  await expect(page.locator("#titlebar")).toContainText("poem.txt")
})

test("Focus Next Editor Group moves between them by key", async ({page}) => {
  await openBee(page)
  await openFile(page, "poem.txt")
  await runCommand(page, "View: Split Editor Right")
  await expect(group(page, 2).root).toHaveAttribute("data-focused", "true")

  await page.keyboard.press("Control+k")
  await page.keyboard.press("Control+ArrowLeft")
  await expect(group(page, 1).root).toHaveAttribute("data-focused", "true")
  await expect(group(page, 1).editor).toBeFocused()
  // Typing goes there.
  await page.keyboard.type("X")
  await expect(group(page, 2).lines.first()).toContainText("X")
  await page.keyboard.press("Control+z")

  await page.keyboard.press("Control+k")
  await page.keyboard.press("Control+ArrowRight")
  await expect(group(page, 2).root).toHaveAttribute("data-focused", "true")
})

test("a group goes with its last tab; the file stays open in the other", async ({page}) => {
  await openBee(page)
  await openFile(page, "poem.txt")
  await runCommand(page, "View: Split Editor Right")
  await group(page, 2).lines.first().click()
  await page.keyboard.press("End")
  await page.keyboard.type(" unsaved")

  // Unsaved, but still open on the left: closed without a question.
  await group(page, 2).tab("poem.txt").getByTitle("Close").click()
  await expect(groups(page)).toHaveCount(1)
  await expect(group(page, 1).lines.first()).toHaveText("roses are red unsaved")
  await expect(unsaved(group(page, 1).tab("poem.txt"))).toHaveCount(1)
  // The group left fills the area again.
  const area = await box(page.locator("#editor"))
  expect(Math.abs((await box(group(page, 1).root)).width - area.width)).toBeLessThan(2)
  expect(read(join(dws, "poem.txt"))).toBe("roses are red\nviolets are blue\n")
  await group(page, 1).lines.first().click()
  await page.keyboard.press("Control+z")
})

test("Close All closes the focused group's tabs only", async ({page}) => {
  await openBee(page)
  await openFile(page, "poem.txt")
  await openFile(page, "one.txt")
  await runCommand(page, "View: Split Editor Right")
  await openFile(page, "two.txt")
  expect(await group(page, 2).names()).toEqual(["one.txt", "two.txt"])

  await runCommand(page, "View: Close All")
  await expect(groups(page)).toHaveCount(1)
  expect(await group(page, 1).names()).toEqual(["poem.txt", "one.txt"])
})

test("a tab dragged onto another group's tabs moves there", async ({page}) => {
  await openBee(page)
  await openFile(page, "poem.txt")
  await openFile(page, "one.txt")
  await runCommand(page, "View: Split Editor Right")
  await openFile(page, "two.txt")
  const [left, right] = [group(page, 1), group(page, 2)]
  expect(await left.names()).toEqual(["poem.txt", "one.txt"])
  expect(await right.names()).toEqual(["one.txt", "two.txt"])

  // poem.txt: from the left group to the front of the right one's tabs.
  const first = await box(right.tabs.first())
  await drag(page, left.tab("poem.txt"), {x: first.x + 4, y: first.y + first.height / 2})
  await expect.poll(right.names).toEqual(["poem.txt", "one.txt", "two.txt"])
  expect(await left.names()).toEqual(["one.txt"])
  await expect(right.activeTab).toContainText("poem.txt")
  await expect(right.lines.first()).toHaveText("roses are red")
  await expect(right.root).toHaveAttribute("data-focused", "true")
})

test("a tab dragged onto another group's editor moves there; its unsaved text with it", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  await openFile(page, "poem.txt")
  await runCommand(page, "View: Split Editor Right")
  await openFile(page, "two.txt")
  const [left, right] = [group(page, 1), group(page, 2)]
  await right.tab("poem.txt").getByTitle("Close").click()
  await left.lines.first().click()
  await page.keyboard.press("End")
  await page.keyboard.type(" (edited)")

  const area = await box(right.area)
  await drag(page, left.tab("poem.txt"), {x: area.x + area.width * 0.3, y: area.y + area.height * 0.3})
  await expect.poll(right.names).toEqual(["two.txt", "poem.txt"])
  expect(await left.names()).toEqual(["one.txt"])
  await expect(right.lines.first()).toHaveText("roses are red (edited)")
  await expect(unsaved(right.tab("poem.txt"))).toHaveCount(1)
  // Still something to undo there? At least it saves from there.
  await page.keyboard.press("Control+s")
  await expectFile(join(dws, "poem.txt"), "roses are red (edited)\nviolets are blue\n")
})

test("a group's last tab dragged away takes the group with it", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  await runCommand(page, "View: Split Editor Right")
  await openFile(page, "two.txt")
  await group(page, 2).tab("one.txt").getByTitle("Close").click()
  expect(await group(page, 2).names()).toEqual(["two.txt"])

  await drag(page, group(page, 2).tab("two.txt"), await middle(group(page, 1).area))
  await expect(groups(page)).toHaveCount(1)
  expect(await group(page, 1).names()).toEqual(["one.txt", "two.txt"])
})

test("a tab dropped on the right or the bottom of an editor splits it there", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  await openFile(page, "two.txt")
  await openFile(page, "poem.txt")

  // The right part of its own editor: a group to the right, with it.
  let area = await box(group(page, 1).area)
  await drag(page, group(page, 1).tab("poem.txt"), {x: area.x + area.width * 0.9, y: area.y + area.height * 0.4})
  await expect(groups(page)).toHaveCount(2)
  expect(await group(page, 1).names()).toEqual(["one.txt", "two.txt"])
  expect(await group(page, 2).names()).toEqual(["poem.txt"])
  expect((await box(group(page, 2).root)).x).toBeGreaterThan((await box(group(page, 1).root)).x + 100)

  // The bottom of the first group's editor: a group below it.
  area = await box(group(page, 1).area)
  await drag(page, group(page, 1).tab("two.txt"), {x: area.x + area.width * 0.3, y: area.y + area.height * 0.9})
  await expect(groups(page)).toHaveCount(3)
  const below = page.locator("#editor section[data-group]").filter({has: page.getByText("two.txt", {exact: true})})
  expect((await box(below)).y).toBeGreaterThan((await box(group(page, 1).root)).y + 100)
  await expect(below.locator(".cm-line").first()).toHaveText("two")
})

test("a tab still reorders within its own group", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  await openFile(page, "two.txt")
  await runCommand(page, "View: Split Editor Right")
  const left = group(page, 1)
  const last = await box(left.tab("two.txt"))
  await drag(page, left.tab("one.txt"), {x: last.x + last.width - 2, y: last.y + last.height / 2})
  await expect.poll(left.names).toEqual(["two.txt", "one.txt"])
  expect(await group(page, 2).names()).toEqual(["two.txt"])
})

test("the Explorer, the status bar and the tab's menu follow the focused group", async ({page}) => {
  await openBee(page)
  await explorerItem(page, "lib").click()
  await openFile(page, "lib/a.ex")
  await runCommand(page, "View: Split Editor Right")
  await openFile(page, "one.txt")
  await expect(page.locator("#status-lang")).toHaveText("Plain Text")

  await group(page, 1).lines.first().click()
  await expect(page.locator("#status-lang")).toHaveText("Elixir")
  await expect(focusedGroup(page).locator("[data-tab][data-active=true]")).toContainText("a.ex")

  // A right-click on a tab of the other group acts there.
  await group(page, 2).tab("one.txt").click({button: "right"})
  await menuItem(contextMenu(page), "Close", {exact: true}).first().click()
  expect(await group(page, 2).names()).toEqual(["a.ex"])
  expect(await group(page, 1).names()).toEqual(["a.ex"])
})
