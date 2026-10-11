// Snippets (VS Code's format, from the tm-lang plugin in fixtures.mjs, for
// .tml files): offered while typing their prefix, Tab through their fields,
// variables, linked fields, and Insert Snippet over a selection.
import {expect, freshBee, test} from "./helpers.mjs"
import {rmSync, writeFileSync} from "node:fs"
import {join} from "node:path"
import {dws, openBee, takeCompletion} from "./helpers.mjs"

freshBee()

const file = "snip.tml"

const open = async (page, text) => {
  writeFileSync(join(dws, file), text)
  await openBee(page, `/?file=${encodeURIComponent(join(dws, file))}`)
  await expect(page.locator(`#tabs [data-path$='/${file}']`)).toBeVisible()
  await page.locator(".cm-line").first().click()
  await page.keyboard.press("Control+End")
}

const lines = page => page.locator(".cm-line").allTextContents()
const completion = page => page.locator(".cm-tooltip-autocomplete li")

// Accepts the completion `label`: CodeMirror ignores Enter for 75 ms after
// the list shows (so a quick Enter isn't taken by accident).
const accept = async (page, label) => {
  await expect(completion(page).filter({hasText: label})).toBeVisible()
  await takeCompletion(page)
}

test.afterEach(() => rmSync(join(dws, file), {force: true}))

test("a prefix offers the snippet; Tab goes through its fields", async ({page}) => {
  await open(page, "")
  await page.keyboard.type("de")
  await accept(page, "Define a function")
  await expect.poll(() => lines(page)).toEqual(["def name(args) do", "  ", "end"])

  // name is selected first, then args, then the body.
  await page.keyboard.type("greet")
  await page.keyboard.press("Tab")
  await page.keyboard.type("who")
  await page.keyboard.press("Tab")
  await page.keyboard.type("hello")
  await expect.poll(() => lines(page)).toEqual(["def greet(who) do", "  hello", "end"])
})

test("variables, and a choice whose number repeats", async ({page}) => {
  await open(page, "")
  await page.keyboard.type("hdr")
  await accept(page, "File header")
  await expect.poll(() => lines(page)).toEqual([`# ${file} ${new Date().getFullYear()}`])

  await page.keyboard.press("Enter")
  await page.keyboard.type("pick")
  await accept(page, "Pick")
  // (Enter after a # comment line continues it: the language's onEnter rule.)
  await expect.poll(() => lines(page)).toEqual([`# ${file} ${new Date().getFullYear()}`, "# alpha alpha"])
  // Both places at once.
  await page.keyboard.type("z")
  await expect.poll(async () => (await lines(page))[1]).toBe("# z z")
})

test("Insert Snippet puts the selection into it", async ({page}) => {
  await open(page, "word")
  await page.keyboard.press("Shift+Home")
  await page.keyboard.press("Control+Shift+p")
  await page.locator("#palette-input").fill(">Insert Snippet")
  await page.keyboard.press("Enter")
  await expect(page.locator("#palette-input")).toHaveAttribute("placeholder", "Select a snippet")
  await page.locator("#palette-input").fill("Wrap")
  await page.keyboard.press("Enter")
  await expect.poll(() => lines(page)).toEqual(["(word)"])
})
