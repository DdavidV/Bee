// Language features of VS Code extensions (vscode.languages), with Bee's
// test language extension (bee/test/fixtures/extensions/hello-lang, for .hl
// files), installed for these tests: its code runs in the extension host.
import {expect, freshBee, test} from "./helpers.mjs"
import {cpSync, readFileSync, rmSync, writeFileSync} from "node:fs"
import {dirname, join, resolve} from "node:path"
import {config, dws} from "../fixtures.mjs"
import {openBee, openFile, takeCompletion} from "./helpers.mjs"

freshBee({before: () => install()})

const here = dirname(new URL(import.meta.url).pathname)
const repo = resolve(process.env.BEE_REPO || join(here, "../.."))
const plugin = join(config, "plugins/hello-lang")
const sample = join(dws, "sample.hl")
const settings = join(config, "settings.json")

// Installed before Bee starts: it loads with it.
const install = () => {
  cpSync(join(repo, "test/fixtures/extensions/hello-lang"), plugin, {recursive: true})
  writeFileSync(join(plugin, ".vsix.json"), JSON.stringify({name: "hello-lang"}))
}

test.afterAll(() => {
  rmSync(plugin, {recursive: true, force: true})
  rmSync(sample, {force: true})
  rmSync(join(dws, "other.hl"), {force: true})
  rmSync(settings, {force: true})
  rmSync(join(dws, "fixed.log"), {force: true})
})

test.beforeEach(async ({page}) => {
  writeFileSync(sample, "fine\nthis is BAD here\n# TODO later\n")
  await openBee(page)
  // Bee notices the new plugin folder by itself.
  await page.click("#view-extensions")
  await expect(page.locator("#plugin-hello-lang")).toBeVisible()
  await page.click("#view-explorer")
})

test("diagnostics: underlined, explained on hover, counted, following the text", async ({page}) => {
  await expect(page.locator("#problems")).toHaveCount(0)
  await openFile(page, "sample.hl")
  await expect(page.locator("#status-lang")).toHaveText("Hello Language")

  // The extension starts with the file, and finds its problems.
  const error = page.locator("#editor .cm-lintRange-error")
  const warning = page.locator("#editor .cm-lintRange-warning")
  await expect(error).toHaveText("BAD")
  await expect(warning).toHaveText("TODO")
  await expect(page.locator("#problems")).toHaveText(/2 problems/)
  await expect(page.locator("#problems")).toHaveAttribute("title", /sample\.hl: line 2: BAD is bad\nsample\.hl: line 3: something to do/)

  // Its message, with who found it.
  await error.hover()
  const tooltip = page.locator(".cm-tooltip-lint")
  await expect(tooltip).toContainText("BAD is bad")
  await expect(tooltip).toContainText("Use GOOD instead.")
  await expect(tooltip).toContainText("hello (H001)")
  await page.mouse.move(600, 500)

  // Typing: found again in the new text.
  await page.locator("#editor .cm-line").first().click()
  await page.keyboard.press("End")
  await page.keyboard.type(" and BAD too")
  await expect(error).toHaveCount(2)
  await expect(page.locator("#problems")).toHaveText(/3 problems/)

  // Fixed: gone.
  await page.keyboard.press("Control+a")
  await page.keyboard.type("all good")
  await expect(error).toHaveCount(0)
  await expect(warning).toHaveCount(0)
  await expect(page.locator("#problems")).toHaveCount(0)
})

test("a workspace edit of the extension's: open files in the editor, as one undo step", async ({page}) => {
  await openFile(page, "sample.hl")
  await expect(page.locator("#editor .cm-lintRange-error")).toHaveText("BAD")

  await page.keyboard.press("F1")
  await page.fill("#palette-input", ">Fix All BADs")
  await page.keyboard.press("Enter")
  await expect(page.locator("#flash-info")).toContainText("fixed 1 file(s): true")

  const line = page.locator("#editor .cm-line").nth(1)
  await expect(line).toHaveText("this is GOOD here")
  await expect(page.locator("#editor .cm-lintRange-error")).toHaveCount(0)
  // Unsaved, and undone like any edit.
  await expect(page.locator("[data-tabs] [data-path$='/sample.hl']")).toHaveAttribute("data-dirty", "true")
  await line.click()
  await page.keyboard.press("Control+z")
  await expect(line).toHaveText("this is BAD here")
  await expect(page.locator("#editor .cm-lintRange-error")).toHaveText("BAD")
})

// Accepts the selected completion. (CodeMirror ignores the key for a
// moment after the list changed, so that what is typed isn't taken for it.)
const accept = page => takeCompletion(page)

test("completion: offered while typing, documented, inserted with its snippet and edits", async ({page}) => {
  await openFile(page, "sample.hl")
  await expect(page.locator("#editor .cm-lintRange-error")).toHaveText("BAD")
  const lines = page.locator("#editor .cm-line")
  const list = page.locator(".cm-tooltip-autocomplete")

  // A word: the language's, the best match first; its documentation comes
  // when it is looked at (resolved).
  await lines.first().click()
  await page.keyboard.press("End")
  await page.keyboard.type(" GO")
  await expect(list.locator("li").first()).toContainText("GOOD")
  await expect(page.locator(".cm-completionInfo strong")).toHaveText("GOOD")
  await expect(page.locator(".cm-completionInfo")).toContainText("is good")
  await accept(page)
  await expect(lines.first()).toHaveText("fine GOOD")

  // Its trigger character asks without a word; a snippet's field is selected.
  await page.keyboard.type(" greet.")
  await expect(list.locator("li")).toHaveCount(2)
  await expect(list).toContainText("hello")
  await expect(list.locator("li").nth(1)).toContainText("world(name) greets")
  await page.keyboard.type("wo")
  await expect(list.locator("li")).toHaveCount(1)
  await accept(page)
  await expect(lines.first()).toHaveText("fine GOOD greet.world(name)")
  await page.keyboard.type("you")
  await expect(lines.first()).toHaveText("fine GOOD greet.world(you)")
  await page.keyboard.press("Escape")

  // Asked for (Ctrl+Space); an item's edit elsewhere comes with it.
  await page.keyboard.press("End")
  await page.keyboard.type(" ")
  await page.keyboard.press("Control+Space")
  await expect(list.locator("li")).toHaveCount(3)
  await page.keyboard.type("hea")
  await expect(list.locator("li")).toHaveCount(1)
  await expect(page.locator(".cm-completionInfo")).toContainText("adds a *first* line")
  await accept(page)
  await expect(lines.first()).toHaveText("# hello")
  await expect(lines.nth(1)).toHaveText("fine GOOD greet.world(you) header!")
  // One step to undo.
  await page.keyboard.press("Control+z")
  await expect(lines.first()).toHaveText("fine GOOD greet.world(you) hea")
})

test("hover: the extension's Markdown, by mouse and by key", async ({page}) => {
  await openFile(page, "sample.hl")
  await expect(page.locator("#editor .cm-lintRange-warning")).toHaveText("TODO")
  const info = page.locator(".cm-language-info")

  await page.locator("#editor .cm-line").first().hover({position: {x: 10, y: 8}})
  await expect(info).toHaveText("fine: 4 letters")
  await expect(info.locator("strong")).toHaveText("fine")
  await page.mouse.move(700, 500)
  await expect(info).toHaveCount(0)

  // Show Hover, at the cursor; gone when it moves.
  await page.locator("#editor .cm-line").nth(2).click()
  await page.keyboard.press("End")
  await page.keyboard.press("Control+k")
  await page.keyboard.press("Control+i")
  await expect(info).toHaveText("later: 5 letters")
  await page.keyboard.press("ArrowLeft")
  await expect(info).toHaveCount(0)
})

test("go to definition: F12 and Ctrl+click, in this file or another; Alt+click adds a cursor", async ({page}) => {
  writeFileSync(sample, "def once\nuses once and twice\ndef twice\n")
  writeFileSync(join(dws, "other.hl"), "\n\ndef twice\n")
  await page.reload()
  await openFile(page, "sample.hl")
  const lines = page.locator("#editor .cm-line")
  await expect(page.locator("#workbench")).toHaveAttribute("data-context", /"editorHasDefinitionProvider":true/)

  // Ctrl+click: the cursor goes to the definition (one place, this file).
  await lines.nth(1).click({position: {x: 50, y: 8}, modifiers: ["Control"]})
  await expect(page.locator("#editor .cm-activeLine")).toHaveText("def once")
  await page.keyboard.type("X")
  await expect(lines.first()).toHaveText("def Xonce")
  await page.keyboard.press("Backspace")

  // F12 with several places: picked in the palette; the other file opens there.
  await lines.nth(1).click()
  await page.keyboard.press("End")
  await page.keyboard.press("F12")
  await expect(page.locator("#palette-input")).toHaveAttribute("placeholder", "Go to definition")
  await page.locator("#palette-items li", {hasText: "other.hl:3"}).click()
  await expect(page.locator("[data-tabs] [data-path$='/other.hl']")).toHaveAttribute("data-active", "true")
  await expect(page.locator("#editor .cm-activeLine")).toHaveText("def twice")
  await page.keyboard.type("Y")
  await expect(lines.nth(2)).toHaveText("def Ytwice")

  // The right-click menu has it too.
  await page.locator("[data-tabs] [data-path$='/sample.hl']").click()
  await lines.nth(1).click({button: "right"})
  await expect(page.locator("#context-menu")).toContainText("Go to Definition")
  await page.keyboard.press("Escape")

  // Alt+click: another cursor (what Ctrl+click was).
  await lines.first().click()
  await page.keyboard.press("Home")
  await lines.nth(2).click({position: {x: 2, y: 8}, modifiers: ["Alt"]})
  await page.keyboard.type("//")
  await expect(lines.first()).toHaveText("//def once")
  await expect(lines.nth(2)).toHaveText("//def twice")
})

test("completion: the arrows choose a suggestion, Tab takes it", async ({page}) => {
  await openFile(page, "sample.hl")
  await expect(page.locator("#editor .cm-lintRange-error")).toHaveText("BAD")
  const lines = page.locator("#editor .cm-line")
  const list = page.locator(".cm-tooltip-autocomplete")

  await lines.first().click()
  await page.keyboard.press("End")
  await page.keyboard.type(" greet.")
  await expect(list.locator("li")).toHaveCount(2)
  await expect(list.locator("li[aria-selected]")).toContainText("hello")
  // (The list takes keys a moment after it shows, so that typing on isn't
  // taken for choosing.)
  await page.waitForTimeout(150)
  await page.keyboard.press("ArrowDown")
  await expect(list.locator("li[aria-selected]")).toContainText("world")
  await page.keyboard.press("ArrowUp")
  await expect(list.locator("li[aria-selected]")).toContainText("hello")
  await page.keyboard.press("ArrowDown")
  await page.waitForTimeout(200)
  await page.keyboard.press("Tab")
  await expect(list).toHaveCount(0)
  await expect(lines.first()).toHaveText("fine greet.world(name)")

  // In the snippet's field, a suggestion is still taken by Tab.
  await page.keyboard.type("GO")
  await expect(list.locator("li").first()).toContainText("GOOD")
  await takeCompletion(page, "Tab")
  await expect(lines.first()).toHaveText("fine greet.world(GOOD)")

  // No suggestions: Tab indents, as before.
  await page.keyboard.press("Escape")
  await page.keyboard.press("Home")
  await page.keyboard.press("Tab")
  await expect(lines.first()).toHaveText(/^\s+fine greet\.world\(GOOD\)$/)
})

// The editor's text, exactly (toHaveText takes runs of spaces for one).
const text = page => page.evaluate(() => document.querySelector("#editor .cm-content").cmTile.root.view.state.doc.toString())

test("formatting: Format Document as one undo step, Format Selection, and on save", async ({page}) => {
  writeFileSync(sample, "one   two\nthree    four\nfive   six\n")
  await page.reload()
  await openFile(page, "sample.hl")
  const lines = page.locator("#editor .cm-line")
  await expect(page.locator("#workbench")).toHaveAttribute("data-context", /"editorHasDocumentFormattingProvider":true/)

  // The selection's lines only.
  await lines.nth(1).click()
  await page.keyboard.press("Home")
  await page.keyboard.press("Shift+End")
  await page.keyboard.press("F1")
  await page.fill("#palette-input", ">Format Selection")
  await page.keyboard.press("Enter")
  await expect.poll(() => text(page)).toBe("one   two\nthree four\nfive   six\n")

  // The whole file, by its key; undone in one step.
  await lines.first().click()
  await page.keyboard.press("Shift+Alt+f")
  await expect.poll(() => text(page)).toBe("one two\nthree four\nfive six\n")
  await page.keyboard.press("Control+z")
  await expect.poll(() => text(page)).toBe("one   two\nthree four\nfive   six\n")

  // Saved as it is…
  await page.keyboard.press("Control+s")
  await expect(page.locator("#status")).toContainText("Saved sample.hl")
  expect(readFileSync(sample, "utf8")).toBe("one   two\nthree four\nfive   six\n")

  // …unless editor.formatOnSave: formatted, then saved.
  writeFileSync(settings, JSON.stringify({"editor.formatOnSave": true}))
  await expect(page.locator("#workbench")).toHaveAttribute("data-context", /"config\.editor\.formatOnSave":true/)
  await lines.first().click()
  await page.keyboard.press("End")
  await page.keyboard.type("   more")
  await page.keyboard.press("Control+s")
  await expect.poll(() => text(page)).toBe("one two more\nthree four\nfive six\n")
  await expect.poll(() => readFileSync(sample, "utf8")).toBe("one two more\nthree four\nfive six\n")
  await expect(page.locator("[data-tabs] [data-path$='/sample.hl']")).not.toHaveAttribute("data-dirty", "true")
  rmSync(settings, {force: true})
})

test("parameter hints: shown in a call, following the parameter being typed", async ({page}) => {
  await openFile(page, "sample.hl")
  await expect(page.locator("#editor .cm-lintRange-error")).toHaveText("BAD")
  const help = page.locator(".cm-language-signature-help")

  await page.locator("#editor .cm-line").first().click()
  await page.keyboard.press("End")
  await page.keyboard.type(" greet.world(")
  await expect(help.locator(".cm-language-signature")).toHaveText("world(name, loudly)")
  await expect(help.locator(".cm-language-parameter")).toHaveText("name")
  await expect(help).toContainText("who to greet (asked by ()")
  await expect(help).toContainText("Greets the world.")

  // The next parameter.
  await page.keyboard.type("you, ")
  await expect(help.locator(".cm-language-parameter")).toHaveText("loudly")
  await expect(help).toContainText("whether to shout")

  // Out of the call: gone. Asked for by its key: back.
  await page.keyboard.type("yes) ")
  await expect(help).toHaveCount(0)
  await page.keyboard.press("ArrowLeft")
  await page.keyboard.press("ArrowLeft")
  await page.keyboard.press("Control+Shift+Space")
  await expect(help.locator(".cm-language-parameter")).toHaveText("loudly")
  await page.keyboard.press("Escape")
  await expect(help).toHaveCount(0)
})

test("references, highlights and rename: every place a symbol is, in this file and others", async ({page}) => {
  writeFileSync(sample, "def once\nuses once and once\ndef last\n")
  writeFileSync(join(dws, "other.hl"), "also once\n")
  await page.reload()
  await openFile(page, "sample.hl")
  const lines = page.locator("#editor .cm-line")
  await expect(page.locator("#workbench")).toHaveAttribute("data-context", /"editorHasRenameProvider":true/)

  // The cursor resting on a symbol marks its occurrences in the file.
  await lines.nth(1).click({position: {x: 50, y: 8}})
  await expect(page.locator("#editor .cm-language-highlight")).toHaveText(["once", "once", "once"])
  await expect(page.locator("#editor .cm-language-highlight-write")).toHaveText("once")
  await lines.nth(2).click()
  await page.keyboard.press("End")
  await expect(page.locator("#editor .cm-language-highlight")).toHaveText(["last"])

  // Find All References (Shift+F12): the panel's section, by file.
  await lines.nth(1).click({position: {x: 50, y: 8}})
  await page.keyboard.press("Shift+F12")
  await expect(page.locator("#references-count")).toHaveText("4 references in 2 files")
  await expect(page.locator("#references [data-reference-file] h3")).toHaveText([/other\.hl\s*1/, /sample\.hl\s*3/])
  await expect(page.locator("#references [data-reference] mark")).toHaveText(["once", "once", "once", "once"])
  // A row: its file, at the place.
  await page.locator("#references [data-reference-file$='/other.hl'] [data-reference]").click()
  await expect(page.locator("[data-tabs] [data-path$='/other.hl']")).toHaveAttribute("data-active", "true")
  await page.keyboard.type("X")
  await expect.poll(() => text(page)).toBe("also Xonce\n")
  await page.keyboard.press("Backspace")
  await page.keyboard.press("Control+j")

  // Rename Symbol (F2): the old name to type over; both files change.
  await page.locator("[data-tabs] [data-path$='/sample.hl']").click()
  await lines.first().click()
  await page.keyboard.press("End")
  await page.keyboard.press("F2")
  await expect(page.locator("#palette-input")).toHaveValue("once")
  await page.fill("#palette-input", "twice")
  await page.keyboard.press("Enter")
  await expect(page.locator("#status")).toHaveText("Renamed once to twice: 4 places in 2 files")
  await expect.poll(() => text(page)).toBe("def twice\nuses twice and twice\ndef last\n")
  // One step to undo, in each file.
  await lines.first().click()
  await page.keyboard.press("Control+z")
  await expect.poll(() => text(page)).toBe("def once\nuses once and once\ndef last\n")
  await page.locator("[data-tabs] [data-path$='/other.hl']").click()
  await expect.poll(() => text(page)).toBe("also twice\n")
})

test("go to symbol: the file's outline with @, the workspace's with #", async ({page}) => {
  writeFileSync(sample, "def first\n  var inner\nmiddle\ndef second\n")
  writeFileSync(join(dws, "other.hl"), "\ndef elsewhere\n")
  await page.reload()
  await openFile(page, "sample.hl")
  await expect(page.locator("#workbench")).toHaveAttribute("data-context", /"editorHasDocumentSymbolProvider":true/)
  const symbols = page.locator("#palette [data-symbol]")

  // Ctrl+Shift+O: the outline; typing narrows it; Enter goes there.
  await page.locator("#editor .cm-line").first().click()
  await page.keyboard.press("Control+Shift+o")
  await expect(page.locator("#palette-input")).toHaveValue("@")
  await expect(symbols).toHaveText([/first\s*function · definition\s*line 1/, /inner\s*variable\s*line 2/, /second/])
  await page.keyboard.type("sec")
  await expect(symbols).toHaveCount(1)
  await page.keyboard.press("Enter")
  await expect(page.locator("#editor .cm-activeLine")).toHaveText("def second")

  // From Quick Open, by its prefix: the workspace's symbols for a query.
  await page.keyboard.press("Control+p")
  await expect(page.locator("#palette [data-mode='#']")).toContainText("Go to Symbol in Workspace")
  await page.keyboard.type("#else")
  await expect(symbols).toHaveText([/elsewhere\s*function · other\.hl\s*other\.hl:2/])
  await page.keyboard.press("Enter")
  await expect(page.locator("[data-tabs] [data-path$='/other.hl']")).toHaveAttribute("data-active", "true")
  await expect(page.locator("#editor .cm-activeLine")).toHaveText("def elsewhere")
})

test("quick fix: a lightbulb where something can be done, Ctrl+. offering it; one undo step", async ({page}) => {
  writeFileSync(sample, "fine\nthis is BAD here\n\n")
  await page.reload()
  await openFile(page, "sample.hl")
  const lines = page.locator("#editor .cm-line")
  await expect(page.locator("#editor .cm-lintRange-error")).toHaveText("BAD")
  const bulb = page.locator("#editor .cm-language-lightbulb")

  // Nothing to do on an empty line: no lightbulb, and Ctrl+. says so.
  await lines.nth(2).click()
  await page.waitForTimeout(700)
  await expect(bulb).toHaveCount(0)
  await page.keyboard.press("Control+.")
  await expect(page.locator("#status")).toHaveText("No code actions available")

  // On the problem's line: the lightbulb, beside that line.
  await lines.nth(1).click()
  await expect(bulb).toHaveCount(1)
  const [bulbBox, lineBox] = [await bulb.boundingBox(), await lines.nth(1).boundingBox()]
  expect(Math.abs(bulbBox.y + bulbBox.height / 2 - (lineBox.y + lineBox.height / 2))).toBeLessThan(8)

  // Ctrl+.: its fixes, the preferred one first; Enter does it.
  await page.keyboard.press("Control+.")
  await expect(page.locator("#palette-input")).toHaveAttribute("placeholder", "Quick Fix…")
  await expect(page.locator("#palette [data-pick]")).toHaveText([/Replace with GOOD\s*preferred/, /Shout the line/])
  await page.keyboard.press("Enter")
  await expect.poll(() => text(page)).toBe("fine\nthis is GOOD here\n\n")
  await expect(page.locator("#editor .cm-lintRange-error")).toHaveCount(0)
  await lines.nth(1).click()
  await page.keyboard.press("Control+z")
  await expect.poll(() => text(page)).toBe("fine\nthis is BAD here\n\n")

  // The lightbulb itself: a click offers the same; a refactoring that is a command.
  await lines.nth(1).click()
  await bulb.click()
  await page.locator("#palette [data-pick]", {hasText: "Shout the line"}).click()
  await expect.poll(() => text(page)).toBe("fine\nTHIS IS BAD HERE\n\n")
})

test("the Problems section: every problem by file, filtered by severity, a click going there", async ({page}) => {
  writeFileSync(sample, "fine\nthis is BAD here\n# TODO later\n")
  await page.reload()
  await openFile(page, "sample.hl")
  await expect(page.locator("#problems")).toHaveText(/2 problems/)

  // The status bar's count opens it.
  await page.click("#problems")
  await expect(page.locator("#problems-view")).toBeVisible()
  await expect(page.locator("#problems-filter-error")).toHaveText(/Errors 1/)
  await expect(page.locator("#problems-filter-warning")).toHaveText(/Warnings 1/)
  await expect(page.locator("#problems-view [data-problem-file] h3")).toHaveText(/sample\.hl\s*2/)
  const rows = page.locator("#problems-view [data-problem]")
  await expect(rows).toHaveText([/BAD is bad\s*hello \(H001\)\s*\[Ln 2, Col 9\]/, /something to do\s*hello\s*\[Ln 3, Col 3\]/])

  // Warnings hidden.
  await page.click("#problems-filter-warning")
  await expect(rows).toHaveCount(1)
  await expect(page.locator("#problems-filter-warning")).toHaveAttribute("aria-pressed", "false")
  await page.click("#problems-filter-warning")
  await expect(rows).toHaveCount(2)

  // A problem: the cursor goes to it.
  await page.locator("#editor .cm-line").first().click()
  await rows.nth(1).click()
  await expect(page.locator("#editor .cm-activeLine")).toHaveText("# TODO later")
  await page.keyboard.type("X")
  await expect.poll(() => text(page)).toBe("fine\nthis is BAD here\n# XTODO later\n")

  // Fixed: the list follows; closed and opened by its key.
  await page.keyboard.press("Control+a")
  await page.keyboard.type("all good")
  await expect(page.locator("#problems-empty")).toBeVisible()
  await page.keyboard.press("Control+j")
  await expect(page.locator("#problems-view")).toHaveCount(0)
  await page.keyboard.press("Control+Shift+m")
  await expect(page.locator("#problems-empty")).toBeVisible()
})
