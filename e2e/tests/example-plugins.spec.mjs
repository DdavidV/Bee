// Bee's example plugins (bee/examples/plugins), installed as the README
// says: what a plugin's server part, browser part and views do in the
// window. (todos-live has its own file: plugin-liveview.spec.mjs.)
import {cpSync, writeFileSync} from "node:fs"
import {join} from "node:path"
import {
  activeTab, config, dws, editorLines, endOfLine, expect, expectFile, fileUrl, freshBee, info, error, openBee, openFile,
  paletteItems, repo, runCommand, showView, sidebar, statusBar, test, userSettingsFile, write, writeJson,
} from "./helpers.mjs"

freshBee({
  before: () => {
    for (const name of ["word-count", "upcase", "insert-date", "dotenv", "todos"])
      cpSync(join(repo, "examples/plugins", name), join(config, "plugins", name), {recursive: true})
    write(join(dws, "words.txt"), "three little words\n")
    write(join(dws, "numbers.txt"), "alpha 1 beta 22\n")
    write(join(dws, "tasks/chores.md"), "# Chores\n- TODO: water the plants\n- FIXME: the tap drips\n")
    write(join(dws, ".env"), "# settings\nexport API_KEY=secret\nNAME=\"bee\"\n")
  },
})

test.describe("word-count (a server part in Elixir)", () => {
  test("counts the file's words, and remembers how often it ran", async ({page}) => {
    await openBee(page, fileUrl(join(dws, "words.txt")))
    await expect(activeTab(page)).toContainText("words.txt")
    await runCommand(page, "Word Count: Count Words")
    await expect(info(page)).toContainText("3 words in words.txt (counted 1×)")
    await info(page).click()
    await runCommand(page, "Word Count: Count Words")
    await expect(info(page)).toContainText("(counted 2×)")
  })

  test("counts the selection when there is one, by its key", async ({page}) => {
    await openBee(page, fileUrl(join(dws, "words.txt")))
    await editorLines(page).first().dblclick()
    await page.keyboard.press("Control+Alt+w")
    await expect(info(page)).toContainText("1 word in selection")
  })

  test("its setting changes what it counts; unsaved text counts", async ({page}) => {
    await openBee(page, fileUrl(join(dws, "numbers.txt")))
    await runCommand(page, "Word Count: Count Words")
    await expect(info(page)).toContainText("4 words in numbers.txt")
    await info(page).click()

    writeJson(userSettingsFile, {"wordCount.countNumbers": false})
    await endOfLine(page, 1)
    await page.keyboard.type(" gamma")
    await runCommand(page, "Word Count: Count Words")
    await expect(info(page)).toContainText("3 words in numbers.txt")
    writeJson(userSettingsFile, {})
    await page.keyboard.press("Control+z")
  })

  test("without a file open its command can't be run", async ({page}) => {
    await openBee(page)
    await page.keyboard.press("F1")
    await page.locator("#palette-input").fill(">Count Words")
    // Not offered, and its key does nothing.
    await expect(paletteItems(page).filter({hasText: "Toggle"}).first()).toBeHidden()
    await expect(paletteItems(page).filter({hasText: "Count Words"})).toHaveCount(0)
    await page.keyboard.press("Escape")
    await page.keyboard.press("Control+Alt+w")
    await page.waitForTimeout(300)
    await expect(info(page)).toHaveCount(0)
    await expect(error(page)).toHaveCount(0)
  })
})

test.describe("upcase (a server part in Erlang)", () => {
  test("upper-cases the selection in the editor, as one step to undo", async ({page}) => {
    await openBee(page, fileUrl(join(dws, "words.txt")))
    await editorLines(page).first().click()
    await page.keyboard.press("Control+a")
    await runCommand(page, "Upcase: Transform to Uppercase")
    await expect(editorLines(page).first()).toHaveText("THREE LITTLE WORDS")

    await editorLines(page).first().click()
    await page.keyboard.press("Control+z")
    await expect(editorLines(page).first()).toHaveText("three little words")
  })

  test("with nothing selected it says so", async ({page}) => {
    await openBee(page, fileUrl(join(dws, "words.txt")))
    await editorLines(page).first().click()
    await page.keyboard.press("Control+Alt+u")
    await expect(info(page)).toContainText("Select some text first")
  })
})

test("insert-date (a browser part): today's date at the cursor", async ({page}) => {
  await openBee(page, fileUrl(join(dws, "words.txt")))
  await endOfLine(page, 1)
  await page.keyboard.press("Control+Alt+d")
  const today = await page.evaluate(() => new Date().toISOString().slice(0, 10))
  await expect(editorLines(page).first()).toHaveText(`three little words${today}`)
  await page.keyboard.press("Control+z")
})

test("dotenv (a language and its highlighting): .env files are Dotenv, in colors", async ({page}) => {
  await openBee(page, fileUrl(join(dws, ".env")))
  await expect(statusBar(page)).toContainText("Dotenv")
  // The comment, the keyword and the value are told apart.
  const color = text =>
    editorLines(page)
      .locator("span", {hasText: text})
      .first()
      .evaluate(el => getComputedStyle(el).color)
  await expect(editorLines(page).locator("span", {hasText: "# settings"})).toBeVisible()
  const colors = new Set([await color("# settings"), await color("export"), await color("secret")])
  expect(colors.size).toBe(3)
})

test.describe("todos (views as data, a status bar item, editor decorations)", () => {
  const todo = (page, text) => sidebar(page).getByRole("treeitem").filter({hasText: text}).last().locator("> *").first()

  test("lists the folder's TODOs by file, counts them, and opens one", async ({page}) => {
    await openBee(page)
    await expect(statusBar(page)).toContainText("2 TODOs")
    await expect(page.locator("#activity-bar").getByRole("button", {name: "TODOs", exact: true})).toContainText("2")

    await showView(page, "TODOs")
    await expect(todo(page, "chores.md")).toBeVisible()
    await todo(page, "FIXME: the tap drips").click()
    await expect(activeTab(page)).toContainText("chores.md")
    await expect(page.locator("#editor .cm-activeLine")).toHaveText("- FIXME: the tap drips")
  })

  test("follows the files as they change", async ({page}) => {
    await openBee(page)
    await expect(statusBar(page)).toContainText("2 TODOs")
    writeFileSync(join(dws, "tasks/more.md"), "TODO: one more\n")
    await expect(statusBar(page)).toContainText("3 TODOs")
    writeFileSync(join(dws, "tasks/more.md"), "done\n")
    await expect(statusBar(page)).toContainText("2 TODOs")
  })

  test("its input box adds one; a button on a row hides it", async ({page}) => {
    await openBee(page)
    await showView(page, "TODOs")
    await sidebar(page).getByPlaceholder(/New TODO/).fill("buy honey")
    await sidebar(page).getByRole("button", {name: "Add"}).click()
    await expect(info(page)).toContainText("Added to TODO.md")
    await expectFile(join(dws, "TODO.md"), /- TODO: buy honey\n$/)
    await expect(sidebar(page).getByPlaceholder(/New TODO/)).toHaveValue("")
    await expect(todo(page, "TODO: buy honey")).toBeVisible()

    await todo(page, "TODO: buy honey").hover()
    await todo(page, "TODO: buy honey").getByTitle("Hide").click()
    await expect(todo(page, "TODO: buy honey")).toHaveCount(0)
    await expect(sidebar(page)).toContainText("1 hidden")
    await sidebar(page).getByTitle("Show Hidden TODOs").click()
    await expect(todo(page, "TODO: buy honey")).toBeVisible()
  })

  test("its status bar item offers a list to go to one", async ({page}) => {
    await openBee(page)
    await statusBar(page).getByRole("button", {name: /TODOs/}).click()
    await paletteItems(page).filter({hasText: "water the plants"}).click()
    await expect(activeTab(page)).toContainText("chores.md")
    await expect(page.locator("#editor .cm-activeLine")).toHaveText("- TODO: water the plants")
  })

  test("its browser part marks them in the editor, and a hover asks its server part", async ({page}) => {
    await openBee(page, fileUrl(join(dws, "tasks/chores.md")))
    const mark = page.locator("#editor .cm-line").nth(1).getByText("TODO", {exact: true})
    await expect(mark).toHaveCSS("font-weight", "700")
    await mark.hover()
    await expect(page.locator(".cm-tooltip")).toContainText(/2 in this file, \d+ in the workspace/)
  })
})
