// Search across the folder's files: options, the files to look in, going
// to a match, unsaved text, and replacing.
import {writeFileSync} from "node:fs"
import {join} from "node:path"
import {
  activeTab, dws, editorLines, endOfLine, expect, expectFile, freshBee, openBee, openFile, read, sidebar, test,
  userSettingsFile, write, writeJson,
} from "./helpers.mjs"

freshBee({
  before: () => {
    write(join(dws, "notes/alpha.md"), "Honey is sweet.\nThe honeycomb holds honey.\nNo bees here.\n")
    write(join(dws, "notes/beta.txt"), "HONEY in capitals\nhoneyed words\n")
    write(join(dws, "code/hive.ex"), "def honey(count), do: count * 2\n# honey 42 and honey 7\n")
  },
})

const query = page => sidebar(page).getByPlaceholder("Search", {exact: true})
const status = page => page.locator("#search-status")
const files = page => page.locator("#search-results [data-search-file]")
const matches = page => page.locator("#search-results [data-search-match]")
const option = (page, name) => sidebar(page).getByTitle(name)

const search = async (page, text) => {
  await page.keyboard.press("Control+Shift+F")
  await expect(query(page)).toBeFocused()
  await query(page).fill(text)
}

test("finds every match, grouped by file, with a count", async ({page}) => {
  await openBee(page)
  await search(page, "honey")
  await expect(status(page)).toHaveText(/8 results in 3 files/)
  await expect(files(page)).toHaveCount(3)
  await expect(matches(page)).toHaveCount(8)
  // A match shows the text around it.
  await expect(matches(page).filter({hasText: "holds honey"})).toHaveCount(2)
})

test("nothing found says so; an empty query clears", async ({page}) => {
  await openBee(page)
  await search(page, "there-is-no-such-text-anywhere")
  await expect(status(page)).toContainText("No results found")
  await expect(files(page)).toHaveCount(0)

  await query(page).fill("")
  await expect(status(page)).toHaveText("")
})

test("Match Case, Whole Word and Regular Expression narrow it", async ({page}) => {
  await openBee(page)
  await search(page, "honey")
  await expect(matches(page)).toHaveCount(8)

  await option(page, /Match Case/).click()
  await expect(status(page)).toHaveText(/6 results in 3 files/)
  await option(page, /Match Case/).click()

  // Not "honeycomb", not "honeyed".
  await option(page, /Match Whole Word/).click()
  await expect(status(page)).toHaveText(/6 results in 3 files/)
  await option(page, /Match Whole Word/).click()

  await option(page, /Use Regular Expression/).click()
  await query(page).fill("honey \\d+")
  await expect(status(page)).toHaveText(/2 results in 1 file/)
  // A broken expression is explained, not searched.
  await query(page).fill("honey (")
  await expect(status(page)).not.toHaveText(/result/)
  await option(page, /Use Regular Expression/).click()
  // As plain text, the same characters are just text.
  await query(page).fill("honey(")
  await expect(status(page)).toHaveText(/1 result in 1 file/)
})

test("the keys of the options work with the focus in the search", async ({page}) => {
  await openBee(page)
  await search(page, "honey")
  await expect(matches(page)).toHaveCount(8)
  await page.keyboard.press("Alt+c")
  await expect(status(page)).toHaveText(/6 results/)
  await page.keyboard.press("Alt+c")
  await expect(status(page)).toHaveText(/8 results/)
})

test("files to include and to exclude", async ({page}) => {
  await openBee(page)
  await search(page, "honey")
  await sidebar(page).getByTitle("Toggle Search Details").click()
  const include = page.locator("#search-include")
  const exclude = page.locator("#search-exclude")

  await include.fill("*.md")
  await expect(status(page)).toHaveText(/3 results in 1 file/)
  await include.fill("notes")
  await expect(status(page)).toHaveText(/5 results in 2 files/)
  await exclude.fill("*.txt")
  await expect(status(page)).toHaveText(/3 results in 1 file/)
  await include.fill("")
  await expect(status(page)).toHaveText(/6 results in 2 files/)
})

test("search.exclude leaves files out; files.exclude too", async ({page}) => {
  await openBee(page)
  await search(page, "honey")
  await expect(files(page)).toHaveCount(3)

  writeJson(userSettingsFile, {"search.exclude": {"code/**": true}})
  await sidebar(page).getByTitle("Refresh").click()
  await expect(status(page)).toHaveText(/5 results in 2 files/)

  writeJson(userSettingsFile, {"files.exclude": {"**/*.md": true}})
  await sidebar(page).getByTitle("Refresh").click()
  await expect(status(page)).toHaveText(/5 results in 2 files/)
  await expect(files(page).filter({hasText: "alpha.md"})).toHaveCount(0)
  writeJson(userSettingsFile, {})
})

test("a click on a match opens the file there", async ({page}) => {
  await openBee(page)
  await search(page, "honeycomb")
  await expect(matches(page)).toHaveCount(1)
  await matches(page).first().click()

  await expect(activeTab(page)).toContainText("alpha.md")
  await expect(page.locator("#editor .cm-activeLine")).toHaveText("The honeycomb holds honey.")
  // The match is selected: typing replaces it.
  await page.keyboard.type("hive")
  await expect(page.locator("#editor .cm-activeLine")).toHaveText("The hive holds honey.")
  await page.keyboard.press("Control+z")
})

test("a file's matches fold away under its name", async ({page}) => {
  await openBee(page)
  await search(page, "honey")
  await expect(matches(page)).toHaveCount(8)
  await files(page).filter({hasText: "alpha.md"}).click()
  await expect(matches(page)).toHaveCount(5)
  await files(page).filter({hasText: "alpha.md"}).click()
  await expect(matches(page)).toHaveCount(8)

  await sidebar(page).getByTitle("Collapse All").click()
  await expect(matches(page)).toHaveCount(0)
  await expect(files(page)).toHaveCount(3)
})

test("text not saved yet is searched too", async ({page}) => {
  await openBee(page)
  await openFile(page, "one.txt")
  await endOfLine(page, 1)
  await page.keyboard.type(" unsavedneedle")

  await search(page, "unsavedneedle")
  await expect(status(page)).toHaveText(/1 result in 1 file/)
  await expect(files(page)).toContainText("one.txt")
  expect(read(join(dws, "one.txt"))).toBe("one\n")
})

test("Clear Search Results empties it", async ({page}) => {
  await openBee(page)
  await search(page, "honey")
  await expect(files(page)).toHaveCount(3)
  await sidebar(page).getByTitle("Clear Search Results").click()
  await expect(files(page)).toHaveCount(0)
  await expect(query(page)).toHaveValue("")
})

test.describe("replacing", () => {
  const hive = join(dws, "replace/hive.txt")
  const comb = join(dws, "replace/comb.txt")

  test.beforeEach(() => {
    write(hive, "wax and wax\nmore wax\n")
    write(comb, "wax once\n")
  })

  const openReplace = async (page, text, replacement) => {
    await page.keyboard.press("Control+Shift+H")
    await query(page).fill(text)
    await sidebar(page).getByPlaceholder("Replace").fill(replacement)
    await expect(status(page)).toHaveText(/4 results in 2 files/)
  }

  test("one match", async ({page}) => {
    await openBee(page)
    await openReplace(page, "wax", "resin")
    const first = matches(page).filter({hasText: "and wax"}).first()
    await first.hover()
    await first.getByTitle("Replace", {exact: true}).click()
    await expectFile(hive, "resin and wax\nmore wax\n")
    await expect(status(page)).toHaveText(/3 results in 2 files/)
    expect(read(comb)).toBe("wax once\n")
  })

  test("all of a file", async ({page}) => {
    await openBee(page)
    await openReplace(page, "wax", "resin")
    const file = files(page).filter({hasText: "hive.txt"})
    await file.hover()
    await file.getByTitle("Replace All in File").click()
    await expectFile(hive, "resin and resin\nmore resin\n")
    expect(read(comb)).toBe("wax once\n")
    await expect(status(page)).toHaveText(/1 result in 1 file/)
  })

  test("everything, after a question", async ({page}) => {
    await openBee(page)
    await openReplace(page, "wax", "resin")

    // Declined: nothing changes.
    page.once("dialog", dialog => dialog.dismiss())
    await sidebar(page).getByTitle("Replace All", {exact: true}).click()
    await page.waitForTimeout(300)
    expect(read(hive)).toBe("wax and wax\nmore wax\n")

    let question = ""
    page.once("dialog", dialog => {
      question = dialog.message()
      dialog.accept()
    })
    await sidebar(page).getByTitle("Replace All", {exact: true}).click()
    await expectFile(hive, "resin and resin\nmore resin\n")
    await expectFile(comb, "resin once\n")
    expect(question).toMatch(/Replace 4 occurrences across 2 files/)
    await expect(status(page)).toContainText("No results found")
  })

  test("with a regular expression's groups", async ({page}) => {
    writeFileSync(hive, "kk1: vv1\nkk2: vv2\n")
    await openBee(page)
    await page.keyboard.press("Control+Shift+H")
    await option(page, /Use Regular Expression/).click()
    await query(page).fill("(kk\\d): (vv\\d)")
    await sidebar(page).getByPlaceholder("Replace").fill("$2 = $1")
    await expect(status(page)).toHaveText(/2 results in 1 file/)
    const file = files(page).filter({hasText: "hive.txt"})
    await file.hover()
    await file.getByTitle("Replace All in File").click()
    await expectFile(hive, "vv1 = kk1\nvv2 = kk2\n")
  })

  test("an open file is changed in its editor, as something to undo", async ({page}) => {
    await openBee(page)
    await page.locator("#explorer button[phx-value-path='replace']").click()
    await openFile(page, "replace/comb.txt")
    await openReplace(page, "wax", "resin")
    const file = files(page).filter({hasText: "comb.txt"})
    await file.hover()
    await file.getByTitle("Replace All in File").click()
    await expect(editorLines(page).first()).toHaveText("resin once")
  })
})
