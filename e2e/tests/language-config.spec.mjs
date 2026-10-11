// A language's configuration (VS Code's language-configuration.json, from
// the tm-lang plugin in fixtures.mjs, for .tml files): comment toggling,
// auto-closing pairs, indentation rules, onEnter rules, folding.
import {expect, freshBee, test} from "./helpers.mjs"
import {rmSync, writeFileSync} from "node:fs"
import {join} from "node:path"
import {dws, openBee} from "./helpers.mjs"

freshBee()

const file = "config.tml"

const open = async (page, text) => {
  writeFileSync(join(dws, file), text)
  await openBee(page, `/?file=${encodeURIComponent(join(dws, file))}`)
  await expect(page.locator(`#tabs [data-path$='/${file}']`)).toBeVisible()
  await expect(page.locator(".cm-content")).toBeVisible()
}

const lines = page => page.locator(".cm-line").allTextContents()

// The cursor at the end of line `n` (1-based).
const endOf = async (page, n) => {
  await page.locator(".cm-line").nth(n - 1).click()
  await page.keyboard.press("End")
}

test.afterEach(() => rmSync(join(dws, file), {force: true}))

test("Ctrl+/ comments with the language's line comment", async ({page}) => {
  await open(page, "def a do\nend\n")
  await endOf(page, 1)
  await page.keyboard.press("Control+/")
  await expect.poll(() => lines(page)).toEqual(["# def a do", "end", ""])
  await page.keyboard.press("Control+/")
  await expect.poll(() => lines(page)).toEqual(["def a do", "end", ""])
})

test("its pairs close, Enter indents and continues comments, end outdents", async ({page}) => {
  await open(page, "\n")
  await page.locator(".cm-line").first().click()

  // ( closes itself; typing ) steps over it.
  await page.keyboard.type("def f(x")
  await expect.poll(() => lines(page)).toEqual(["def f(x)", ""])
  await page.keyboard.type(") do")
  await expect.poll(() => lines(page)).toEqual(["def f(x) do", ""])

  // After do: one level in; it stays there; end goes back out.
  await page.keyboard.press("Enter")
  await page.keyboard.type("body")
  await page.keyboard.press("Enter")
  await page.keyboard.type("end")
  await expect.poll(() => lines(page)).toEqual(["def f(x) do", "  body", "end", ""])

  // Enter in a # comment starts the next line with "# ".
  await page.keyboard.press("Enter")
  await page.keyboard.type("# a note")
  await page.keyboard.press("Enter")
  await page.keyboard.type("more")
  await expect.poll(() => lines(page)).toEqual(["def f(x) do", "  body", "end", "# a note", "# more", ""])
})

test("regions and indented blocks fold", async ({page}) => {
  await open(page, ["#region setup", "a = 1", "b = 2", "#endregion", "def g do", "  body", "end"].join("\n"))

  const foldMarkers = page.locator(".cm-foldGutter span[title='Fold line']")
  await expect(foldMarkers).toHaveCount(2)

  // The region: up to its end marker.
  await foldMarkers.first().click()
  await expect(page.locator(".cm-foldPlaceholder")).toHaveCount(1)
  await expect.poll(() => lines(page)).toEqual(["#region setup…", "def g do", "  body", "end"])

  // A block, by indentation: its end stays.
  await foldMarkers.first().click()
  await expect(page.locator(".cm-foldPlaceholder")).toHaveCount(2)
  await expect.poll(() => lines(page)).toEqual(["#region setup…", "def g do…", "end"])

  // Unfolded again.
  await page.locator(".cm-foldPlaceholder").first().click()
  await page.locator(".cm-foldPlaceholder").first().click()
  await expect.poll(() => lines(page)).toHaveLength(7)
})
