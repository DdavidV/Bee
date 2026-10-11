// Terminals: real shells in the panel, in the window's folder, each its
// own; they keep what they showed while the panel is hidden.
import {
  dws, expect, freshBee, menuItem, openBee, openMenu, panel, runCommand, terminal, test, userSettingsFile, writeJson,
} from "./helpers.mjs"

freshBee()

const terminals = page => page.locator("#terminal-list [data-term]")

test("a shell in the folder: commands run, their output shows", async ({page}) => {
  await openBee(page)
  await terminal.open(page)
  await terminal.run(page, "pwd")
  await expect(terminal.rows(page)).toContainText(dws)

  await terminal.run(page, "echo $((6 * 7))-done")
  await expect(terminal.rows(page)).toContainText("42-done")

  // It sees the folder's files.
  await terminal.run(page, "cat one.txt | tr a-z A-Z")
  await expect(terminal.rows(page)).toContainText("ONE")
})

test("what a shell does to files shows in the Explorer", async ({page}) => {
  await openBee(page)
  await terminal.open(page)
  await terminal.run(page, "echo made > from-terminal.txt")
  await expect(page.locator("#explorer")).toContainText("from-terminal.txt")
  await terminal.run(page, "rm from-terminal.txt")
  await expect(page.locator("#explorer")).not.toContainText("from-terminal.txt")
})

test("hidden and shown again, a terminal still has what it showed, and is still running", async ({page}) => {
  await openBee(page)
  await terminal.open(page)
  await terminal.run(page, "KEPT=still-here; echo first-output")
  await expect(terminal.rows(page)).toContainText("first-output")

  await page.keyboard.press("Control+j")
  await expect(panel(page)).toHaveCount(0)
  await terminal.open(page)
  await expect(terminal.rows(page)).toContainText("first-output")
  // The same shell: its variable is set.
  await terminal.run(page, "echo $KEPT")
  await expect(terminal.rows(page)).toContainText("still-here")
})

test("several terminals, each its own shell; killing one leaves the others", async ({page}) => {
  await openBee(page)
  await terminal.open(page)
  await terminal.run(page, "WHO=first; echo started-$WHO")
  await expect(terminal.rows(page)).toContainText("started-first")

  const menu = await openMenu(page, "Terminal")
  await menuItem(menu, "Create New Terminal").click()
  await expect(terminals(page)).toHaveCount(2)
  await terminal.open(page)
  const visible = page.locator("#panel .xterm-rows:visible")
  await terminal.run(page, 'echo "who=[$WHO]"')
  await expect(visible).toContainText("who=[]")

  // Back to the first: it is as it was.
  await terminals(page).first().click()
  await expect(visible).toContainText("started-first")

  await runCommand(page, "Terminal: Kill Terminal")
  await expect(terminals(page)).toHaveCount(0)
  await expect(visible).toContainText("who=[]")
})

test("a shell that ends closes its terminal", async ({page}) => {
  await openBee(page)
  await terminal.open(page)
  await terminal.run(page, "echo before-exit")
  await expect(terminal.rows(page)).toContainText("before-exit")
  await terminal.run(page, "exit")
  // Gone, or marked as ended: no shell takes keys any more.
  await expect(async () => {
    const text = (await page.locator("#panel").count()) ? await page.locator("#panel").innerText() : ""
    expect(text).not.toMatch(/before-exit[\s\S]*\$ $/)
  }).toPass()
})

test("terminal.integrated.shell picks the shell", async ({page}) => {
  writeJson(userSettingsFile, {"terminal.integrated.shell": "/bin/sh"})
  await openBee(page)
  await terminal.open(page)
  await terminal.run(page, "echo shell=$0")
  await expect(terminal.rows(page)).toContainText(/shell=\S*sh/)
})

test("a window's terminals end with it: a reloaded page starts afresh", async ({page}) => {
  await openBee(page)
  await terminal.open(page)
  await terminal.run(page, "echo only-in-the-old-window")
  await expect(terminal.rows(page)).toContainText("only-in-the-old-window")

  await page.reload()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  await terminal.open(page)
  await expect(terminal.rows(page)).not.toContainText("only-in-the-old-window")
})
