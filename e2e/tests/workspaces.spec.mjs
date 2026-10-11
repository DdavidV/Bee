// Two windows on two folders: each sees its own files, terminal, search
// and git.
import {expect, freshBee, test} from "./helpers.mjs"
import {dws, folderUrl, openBee, ws2} from "./helpers.mjs"

freshBee()

test("each window works in its own folder", async ({context}) => {
  const a = await context.newPage()
  await openBee(a)
  const b = await context.newPage()
  await openBee(b, folderUrl(ws2))

  await expect(a.locator("#explorer button[phx-value-path='lib']")).toBeVisible()
  await expect(a.locator("#explorer button[phx-value-path='src/two.txt']")).toHaveCount(0)
  await expect(b.locator("#explorer button[phx-value-path='src']")).toBeVisible()
  await expect(b.locator("#explorer button[phx-value-path='lib']")).toHaveCount(0)
  await expect(b).toHaveTitle(/^ws2/)

  // B's terminal starts in its folder.
  await b.keyboard.press("Control+j")
  await expect(b.locator(".xterm-helper-textarea")).toBeAttached()
  await b.waitForTimeout(1000)
  await b.focus(".xterm-helper-textarea")
  await b.keyboard.type("pwd\n")
  await expect(b.locator(".xterm-rows").last()).toContainText(ws2)

  // B's search finds only its files.
  await b.keyboard.press("Control+Shift+F")
  await b.fill("#search-view [name=query]", "needle")
  await expect(b.locator("[data-search-file]")).toHaveCount(1)
  await expect(b.locator("[data-search-file]")).toHaveAttribute("data-search-file", /two\.txt/)

  // Git: A (a repository) has a branch; B (none) offers to make one.
  await expect(a.locator("#status-item-git-branch")).toContainText("main")
  await b.click("#view-scm")
  await expect(b.getByText("Initialize Repository")).toBeVisible()
  await expect(b.locator("#status-item-git-branch")).toHaveCount(0)
})
