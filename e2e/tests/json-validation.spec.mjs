// JSON validation: a plugin's schema (pets-schema in fixtures.mjs, for
// *.pets.json) checks a file as it's edited – underlined, the message on
// hover, counted in the status bar's problems – and syntax errors show in
// any JSON file; it completes keys and values, and describes them on hover.
import {expect, freshBee, test} from "./helpers.mjs"
import {rmSync, writeFileSync} from "node:fs"
import {join} from "node:path"
import {dws, openBee, takeCompletion} from "./helpers.mjs"

freshBee()

const open = async (page, file, text) => {
  writeFileSync(join(dws, file), text)
  await openBee(page, `/?file=${encodeURIComponent(join(dws, file))}`)
  await expect(page.locator(`#tabs [data-path$='/${file}']`)).toBeVisible()
}

test.afterEach(() => {
  for (const file of ["a.pets.json", "plain.json"]) rmSync(join(dws, file), {force: true})
})

test("a schema's errors: underlined, on hover, in the problems; gone when fixed", async ({page}) => {
  await open(page, "a.pets.json", '{\n  "name": "ab",\n  "age": "old",\n  "extra": 1\n}\n')

  const warnings = page.locator(".cm-lintRange-warning")
  await expect(warnings).toHaveCount(3)
  await expect(warnings.nth(0)).toHaveText('"ab"')
  await expect(warnings.nth(1)).toHaveText('"old"')
  await expect(warnings.nth(2)).toHaveText('"extra"')
  await expect(page.locator("#problems")).toContainText("3 problems")

  // The message, on hover.
  await warnings.nth(1).hover()
  await expect(page.locator(".cm-tooltip-lint")).toContainText('Incorrect type. Expected "integer".')

  // Fixed: as you type.
  await page.locator(".cm-line", {hasText: '"extra": 1'}).click()
  await page.keyboard.press("Home")
  await page.keyboard.press("Shift+End")
  await page.keyboard.type('"x": 0')
  await expect(warnings).toHaveCount(3)
  await expect(warnings.nth(2)).toHaveText('"x"')
  await page.keyboard.press("Control+a")
  await page.keyboard.type('{"name": "rex", "age": 3}')
  await expect(warnings).toHaveCount(0)
  await expect(page.locator("#problems")).toHaveCount(0)
})

test("a syntax error in any JSON file", async ({page}) => {
  await open(page, "plain.json", '{"a": 1,\n "b" 2}\n')
  await expect(page.locator(".cm-lintRange-error")).toHaveCount(1)
  await expect(page.locator("#problems")).toContainText("1 problem")
  await expect(page.locator("#problems")).toHaveAttribute("title", /plain\.json: line 2: Colon expected/)
})

const lines = page => page.locator(".cm-line").allTextContents()
const completion = page => page.locator(".cm-tooltip-autocomplete li")

// Accepts completion `label` (CodeMirror ignores Enter for 75 ms after the
// list shows).
const accept = async (page, label) => {
  await expect(completion(page).filter({hasText: label}).first()).toBeVisible()
  await takeCompletion(page)
}

test("the schema completes keys and values, and describes them", async ({page}) => {
  await open(page, "a.pets.json", "{\n  \n}\n")
  await page.locator(".cm-line").nth(1).click()
  await page.keyboard.press("End")

  // Keys: the schema's, with a value to fill in.
  await page.keyboard.type('"')
  await expect(completion(page)).toHaveText([/age/, /kind/, /name/])
  await page.keyboard.type("na")
  await accept(page, "name")
  await expect.poll(() => lines(page)).toEqual(["{", '  "name": ""', "}", ""])
  await page.keyboard.type("Rex")
  await expect.poll(() => lines(page)).toEqual(["{", '  "name": "Rex"', "}", ""])

  // The next one: name is there already.
  await page.keyboard.press("End")
  await page.keyboard.type(",")
  await page.keyboard.press("Enter")
  await page.keyboard.type('"')
  await expect(completion(page)).toHaveText([/age/, /kind/])
  await page.keyboard.type("k")
  await accept(page, "kind")
  // Its values.
  await page.keyboard.type('"')
  await expect(completion(page)).toHaveText(['"cat"', '"dog"'])
  await page.keyboard.type("d")
  await accept(page, '"dog"')
  await expect.poll(() => lines(page)).toEqual(["{", '  "name": "Rex",', '  "kind": "dog"', "}", ""])
  await expect(page.locator(".cm-lintRange-warning")).toHaveCount(0)

  // Hover: what the schema says.
  await page.locator(".cm-line", {hasText: '"name"'}).getByText('"name"').hover()
  await expect(page.locator(".cm-json-hover")).toHaveText("The pet's name\n\nType: string")
})
