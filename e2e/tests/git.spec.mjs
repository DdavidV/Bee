// The built-in Git plugin: what changed, staging, committing, discarding,
// branches – checked against the repository itself, with git.
import {execFileSync} from "node:child_process"
import {existsSync, rmSync, writeFileSync} from "node:fs"
import {join} from "node:path"
import {
  answer, dws, expect, expectFile, explorerItem, folderUrl, freshBee, openBee, paletteItems, read, runCommand, showView,
  sidebar, statusBar, test, userSettingsFile, writeJson, ws2,
} from "./helpers.mjs"

freshBee()

const git = (...args) => execFileSync("git", args, {cwd: dws, encoding: "utf8"}).trim()
// A row of the Source Control view: a file, or a group of them.
// (Its own line: a group's item also holds its files.)
const row = (page, name) =>
  sidebar(page).getByRole("treeitem").filter({has: page.getByText(name, {exact: true})}).last().locator("> *").first()
const group = row
const button = async (page, name, title) => {
  await row(page, name).hover()
  await row(page, name).getByTitle(title, {exact: true}).click()
}
const branch = page => statusBar(page).getByRole("button").filter({hasText: /main|feature|topic/})

// Every test starts from the first commit, on main, with nothing changed.
test.beforeEach(() => {
  git("checkout", "-q", "-f", "main")
  git("reset", "-q", "--hard", git("rev-list", "--max-parents=0", "HEAD"))
  git("clean", "-qfd")
  for (const name of git("branch", "--format=%(refname:short)").split("\n")) if (name && name !== "main") git("branch", "-qD", name)
})

test("nothing changed: says so, with the branch in the status bar and the first commit listed", async ({page}) => {
  await openBee(page)
  await expect(branch(page)).toHaveText(/^\s*main\s*$/)
  await showView(page, "Source Control")
  await expect(sidebar(page)).toContainText("No changes.")
  await expect(sidebar(page).getByText("init", {exact: true})).toBeVisible()
})

test("changed and new files are listed as they change, marked in the Explorer and counted", async ({page}) => {
  await openBee(page)
  await showView(page, "Source Control")
  await expect(sidebar(page)).toContainText("No changes.")

  writeFileSync(join(dws, "one.txt"), "one changed\n")
  writeFileSync(join(dws, "brand-new.txt"), "new\n")
  rmSync(join(dws, "two.txt"))

  await expect(group(page, "Changes")).toBeVisible()
  await expect(row(page, "one.txt")).toContainText("M")
  await expect(row(page, "brand-new.txt")).toContainText("U")
  await expect(row(page, "two.txt")).toContainText("D")
  // The branch is marked as having changes, the icon counts them.
  await expect(branch(page)).toHaveText(/main\*/)
  await expect(page.locator("#activity-bar").getByRole("button", {name: "Source Control"})).toContainText("3")

  await showView(page, "Explorer")
  await expect(explorerItem(page, "one.txt")).toHaveAttribute("title", /Modified/i)
  await expect(explorerItem(page, "brand-new.txt")).toHaveAttribute("title", /Untracked/i)
  await expect(explorerItem(page, "b.ex")).not.toHaveAttribute("title", /Modified|Untracked/i)
})

test("stage and unstage a file, and all of them", async ({page}) => {
  writeFileSync(join(dws, "one.txt"), "one changed\n")
  writeFileSync(join(dws, "b.ex"), "# changed\n")
  await openBee(page)
  await showView(page, "Source Control")

  await button(page, "one.txt", "Stage Changes")
  await expect(group(page, "Staged Changes")).toBeVisible()
  await expect.poll(() => git("diff", "--cached", "--name-only")).toBe("one.txt")

  await button(page, "one.txt", "Unstage Changes")
  await expect(group(page, "Staged Changes")).toHaveCount(0)
  await expect.poll(() => git("diff", "--cached", "--name-only")).toBe("")

  await button(page, "Changes", "Stage All Changes")
  await expect.poll(() => git("diff", "--cached", "--name-only")).toBe("b.ex\none.txt")
  await expect(group(page, "Changes")).toHaveCount(0)

  await button(page, "Staged Changes", "Unstage All Changes")
  await expect.poll(() => git("diff", "--cached", "--name-only")).toBe("")
})

test("commit what is staged, with the message typed in the view", async ({page}) => {
  writeFileSync(join(dws, "one.txt"), "one changed\n")
  writeFileSync(join(dws, "b.ex"), "# not part of it\n")
  await openBee(page)
  await showView(page, "Source Control")
  await button(page, "one.txt", "Stage Changes")
  await expect(group(page, "Staged Changes")).toBeVisible()

  const message = sidebar(page).getByPlaceholder(/Message/)
  await message.fill("Change one")
  await page.keyboard.press("Control+Enter")

  await expect.poll(() => git("log", "-1", "--format=%s")).toBe("Change one")
  expect(git("log", "-1", "--format=%an")).toBe("Bee")
  expect(git("show", "--name-only", "--format=", "HEAD")).toBe("one.txt")
  // The box is empty again, the commit listed, the other change still there.
  await expect(message).toHaveValue("")
  await expect(sidebar(page).getByText("Change one", {exact: true})).toBeVisible()
  await expect(row(page, "b.ex")).toBeVisible()
  await expect(group(page, "Staged Changes")).toHaveCount(0)
})

test("Git: Commit from the palette asks for the message", async ({page}) => {
  writeFileSync(join(dws, "one.txt"), "one again\n")
  git("add", "one.txt")
  await openBee(page)
  await runCommand(page, "Git: Commit")
  await answer(page, "From the palette")
  await expect.poll(() => git("log", "-1", "--format=%s")).toBe("From the palette")
})

test("a commit needs a message", async ({page}) => {
  writeFileSync(join(dws, "one.txt"), "one again\n")
  git("add", "one.txt")
  const before = git("rev-parse", "HEAD")
  await openBee(page)
  await showView(page, "Source Control")
  await sidebar(page).getByRole("button", {name: /Commit/}).first().click()
  await page.waitForTimeout(500)
  expect(git("rev-parse", "HEAD")).toBe(before)
})

test("Discard Changes asks, then puts the file back", async ({page}) => {
  writeFileSync(join(dws, "one.txt"), "ruined\n")
  await openBee(page)
  await showView(page, "Source Control")

  await button(page, "one.txt", "Discard Changes")
  await expect(paletteItems(page)).toContainText(["Discard Changes"])
  await page.keyboard.press("Escape")
  expect(read(join(dws, "one.txt"))).toBe("ruined\n")

  await button(page, "one.txt", "Discard Changes")
  await paletteItems(page).filter({hasText: "Discard Changes"}).click()
  await expectFile(join(dws, "one.txt"), "one\n")
  await expect(sidebar(page)).toContainText("No changes.")
})

test("a click on a changed file opens it", async ({page}) => {
  writeFileSync(join(dws, "one.txt"), "one changed\n")
  await openBee(page)
  await showView(page, "Source Control")
  await row(page, "one.txt").click()
  await expect(page.locator("[data-tabs]")).toContainText("one.txt")
  await expect(page.locator("#editor .cm-line").first()).toHaveText("one changed")
})

test("a new branch, and back: from the palette and the status bar", async ({page}) => {
  await openBee(page)
  await runCommand(page, "Git: Create Branch")
  await answer(page, "feature-x")
  await expect(branch(page)).toHaveText(/feature-x/)
  expect(git("branch", "--show-current")).toBe("feature-x")

  await branch(page).click()
  await expect(paletteItems(page).filter({hasText: "main"})).toBeVisible()
  await paletteItems(page).filter({hasText: "main"}).click()
  await expect(branch(page)).toHaveText(/^\s*main\s*$/)
  expect(git("branch", "--show-current")).toBe("main")
})

test("a branch switched outside Bee shows up", async ({page}) => {
  await openBee(page)
  await expect(branch(page)).toHaveText(/main/)
  git("checkout", "-q", "-b", "topic")
  await expect(branch(page)).toHaveText(/topic/)
})

test("a folder that isn't a repository offers to make one", async ({page}) => {
  await openBee(page, folderUrl(ws2))
  await showView(page, "Source Control")
  await expect(statusBar(page)).not.toContainText("main")
  await sidebar(page).getByRole("button", {name: "Initialize Repository"}).click()
  await expect.poll(() => existsSync(join(ws2, ".git"))).toBe(true)
  await expect(sidebar(page).getByRole("button", {name: "Initialize Repository"})).toHaveCount(0)
  // Its file is new to the repository.
  await expect(row(page, "two.txt")).toContainText("U")
})

test("git.path: without git, it says so instead of breaking", async ({page}) => {
  writeJson(userSettingsFile, {"git.path": "/no/such/git"})
  await openBee(page)
  await showView(page, "Source Control")
  await expect(statusBar(page)).not.toContainText("main")
  // The rest of Bee is fine.
  await showView(page, "Explorer")
  await expect(explorerItem(page, "one.txt")).toBeVisible()
  rmSync(userSettingsFile)
  await expect(statusBar(page)).toContainText("main")
})
