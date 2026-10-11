// The Git plugin in the editor: who changed a line (at its end, on hover,
// for the whole file), marks beside changed lines, and the peek that
// opens from them – to stage or revert one change.
import {execFileSync} from "node:child_process"
import {writeFileSync} from "node:fs"
import {join} from "node:path"
import {
  dws, editorLines, endOfLine, expect, expectFile, fileUrl, freshBee, openBee, runCommand, test, userSettingsFile,
  writeJson,
} from "./helpers.mjs"

const poem = join(dws, "poem.txt")
const git = (...args) => execFileSync("git", args, {cwd: dws, encoding: "utf8"}).trim()
const commit = message =>
  git("-c", "user.name=Ada", "-c", "user.email=ada@example.com", "commit", "-qam", message)

freshBee({
  before: () => {
    writeFileSync(poem, "roses are red\nviolets are blue\nhoney is sweet\n")
    git("add", "poem.txt")
    commit("Write a poem")
  },
})

test.beforeEach(() => {
  git("checkout", "-q", "-f", "main")
  git("reset", "-q", "--hard", "HEAD")
})

// What the plugin draws (its own names, kept in one place).
const blameOf = line => line.getAttribute("data-blame")
const fileBlame = page => page.locator("#editor .bee-git-file-blame")
const marks = (page, kind = "") => page.locator(`#editor .bee-git-changes .bee-git-change${kind && ".bee-git-" + kind}`)
const peek = page => page.locator("#editor .bee-git-peek")

test("the line the cursor is on says who last changed it, and when", async ({page}) => {
  await openBee(page, fileUrl(poem))
  await editorLines(page).nth(1).click()
  await expect.poll(() => blameOf(editorLines(page).nth(1))).toMatch(/Ada, .* • Write a poem/)
  // Only the current line.
  expect(await blameOf(editorLines(page).nth(0))).toBeNull()

  await editorLines(page).nth(0).click()
  await expect.poll(() => blameOf(editorLines(page).nth(0))).toMatch(/Ada/)
  await expect.poll(() => blameOf(editorLines(page).nth(1))).toBeNull()
})

test("a line that was edited is yours, not committed yet", async ({page}) => {
  await openBee(page, fileUrl(poem))
  await endOfLine(page, 2)
  await page.keyboard.type(" indeed")
  await expect.poll(() => blameOf(editorLines(page).nth(1))).toMatch(/You, Uncommitted changes/)
  await page.keyboard.press("Control+z")
  await expect.poll(() => blameOf(editorLines(page).nth(1))).toMatch(/Ada/)
})

test("Toggle Line Blame and git.blame.inline switch it off", async ({page}) => {
  await openBee(page, fileUrl(poem))
  await editorLines(page).nth(1).click()
  await expect.poll(() => blameOf(editorLines(page).nth(1))).toMatch(/Ada/)

  await runCommand(page, "Git: Toggle Line Blame")
  await expect.poll(() => blameOf(editorLines(page).nth(1))).toBeNull()
  await runCommand(page, "Git: Toggle Line Blame")
  await expect.poll(() => blameOf(editorLines(page).nth(1))).toMatch(/Ada/)

  writeJson(userSettingsFile, {"git.blame.inline": false})
  await expect.poll(() => blameOf(editorLines(page).nth(1))).toBeNull()
  writeJson(userSettingsFile, {})
})

test("Toggle File Blame shows who wrote each part of the file, beside it", async ({page}) => {
  await openBee(page, fileUrl(poem))
  await editorLines(page).first().click()
  await expect(page.locator("#editor")).not.toContainText("Ada")
  await page.keyboard.press("Control+Alt+b")
  await expect(fileBlame(page)).toContainText("Ada")

  // Its button above the editor does the same.
  await page.getByRole("button", {name: "Toggle File Blame"}).click()
  await expect(page.locator("#editor")).not.toContainText("Ada")
})

test("changed, added and removed lines are marked as the text is edited", async ({page}) => {
  await openBee(page, fileUrl(poem))
  await expect(editorLines(page).first()).toHaveText("roses are red")
  await expect(marks(page)).toHaveCount(0)

  await endOfLine(page, 1)
  await page.keyboard.type("!")
  await expect(marks(page, "modified")).toHaveCount(1)

  await endOfLine(page, 3)
  await page.keyboard.press("Enter")
  await page.keyboard.type("and so are you")
  await expect(marks(page, "added")).toHaveCount(1)

  // Undone: no marks.
  for (let i = 0; i < 4; i++) await page.keyboard.press("Control+z")
  await expect(marks(page)).toHaveCount(0)

  // A line removed: marked where it was.
  await editorLines(page).nth(1).click()
  await page.keyboard.press("Home")
  await page.keyboard.press("Shift+ArrowDown")
  await page.keyboard.press("Delete")
  await expect(marks(page, "deleted")).toHaveCount(1)
  await page.keyboard.press("Control+z")
})

test("changes made outside Bee are marked too; git.decorations.gutter hides the marks", async ({page}) => {
  await openBee(page, fileUrl(poem))
  await expect(marks(page)).toHaveCount(0)
  writeFileSync(poem, "roses are red\nviolets are purple\nhoney is sweet\n")
  await expect(editorLines(page).nth(1)).toHaveText("violets are purple")
  await expect(marks(page, "modified")).toHaveCount(1)

  writeJson(userSettingsFile, {"git.decorations.gutter": false})
  await expect(marks(page)).toHaveCount(0)
  writeJson(userSettingsFile, {})
  await expect(marks(page, "modified")).toHaveCount(1)
})

// Opens the peek from `mark` and waits for `text` in it. (Under load the
// plugin may draw its marks again just as one is clicked: asked again.)
const openPeek = (page, mark, text) =>
  expect(async () => {
    if (!(await peek(page).isVisible())) await mark.click({timeout: 2000})
    await expect(peek(page)).toContainText(text, {timeout: 1500})
  }).toPass()

// Clicks the peek's button `name` until `done` holds.
const peekButton = (page, mark, name, done) =>
  expect(async () => {
    if (!(await peek(page).isVisible())) await mark.click({timeout: 2000})
    await peek(page).getByRole("button", {name}).click({timeout: 2000})
    await done()
  }).toPass()

test("a mark opens a peek at the change: the old line and the new; Revert puts it back", async ({page}) => {
  writeFileSync(poem, "roses are red\nviolets are purple\nhoney is sweet\n")
  await openBee(page, fileUrl(poem))
  const mark = marks(page, "modified")
  await openPeek(page, mark, "1 of 1 change")
  await expect(peek(page)).toContainText("poem.txt")
  await expect(peek(page)).toContainText("violets are blue")
  await expect(peek(page)).toContainText("violets are purple")

  // Escape closes it; the mark opens it again.
  await page.keyboard.press("Escape")
  await expect(peek(page)).toHaveCount(0)
  await openPeek(page, mark, "1 of 1 change")

  await peekButton(page, mark, "Revert Change", () =>
    expect(editorLines(page).nth(1)).toHaveText("violets are blue", {timeout: 1500}),
  )
  await expect(peek(page)).toHaveCount(0)
  await expect(marks(page)).toHaveCount(0)
})

test("Stage Change stages just that change; Next Change goes to the other", async ({page}) => {
  writeFileSync(poem, "roses are crimson\nviolets are blue\nhoney is golden\n")
  await openBee(page, fileUrl(poem))
  await expect(marks(page, "modified")).toHaveCount(2)
  const first = marks(page, "modified").first()
  await openPeek(page, first, "1 of 2 changes")
  await expect(peek(page)).toContainText("roses are crimson")

  await peekButton(page, first, "Next Change", () => expect(peek(page)).toContainText("2 of 2 changes", {timeout: 1500}))
  await expect(peek(page)).toContainText("honey is golden")
  await peekButton(page, first, "Previous Change", () => expect(peek(page)).toContainText("1 of 2 changes", {timeout: 1500}))

  await peek(page).getByRole("button", {name: "Stage Change"}).click()
  await expect.poll(() => git("diff", "--cached")).toContain("+roses are crimson")
  expect(git("diff", "--cached")).not.toContain("golden")
  // What is staged is no longer a change to show; the other one is.
  await expect(marks(page, "modified")).toHaveCount(1)
  expect(git("diff")).toContain("+honey is golden")
  await expectFile(poem, "roses are crimson\nviolets are blue\nhoney is golden\n")
})
