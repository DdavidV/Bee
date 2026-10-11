// TextMate grammars: a plugin's (tm-lang, see fixtures.mjs) highlight its
// languages in the editor, in the color theme's token colors (Bee's own
// themes: VS Code's Dark+ and Light+), JSON and plist grammars alike; a
// state spanning lines (a block comment) carries over, also through a
// long file whose end is tokenized after the start. Big files: the rest
// is tokenized while idle, an edit keeps the tokens after it when the
// tokenizer's state is the same again, and the page never stalls.
import {expect, freshBee, test} from "./helpers.mjs"
import {rmSync, writeFileSync} from "node:fs"
import {join} from "node:path"
import {dws, openBee} from "./helpers.mjs"

freshBee()

const rgb = hex => `rgb(${[1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16)).join(", ")})`

// The color of the editor's span with text `text` (the first one).
const colorOf = (page, text) =>
  page
    .locator(".cm-line span", {hasText: new RegExp(`^${text}$`)})
    .first()
    .evaluate(el => getComputedStyle(el).color)

const openInBee = async (page, rel) => {
  await openBee(page, `/?file=${encodeURIComponent(join(dws, rel))}`)
  await expect(page.locator(`[data-tabs] [data-path$='/${rel}']`)).toBeVisible()
}

const write = (rel, text) => {
  writeFileSync(join(dws, rel), text)
  test.info().attach(rel, {body: text.slice(0, 200)})
}

test.afterEach(() => {
  for (const rel of ["hello.tml", "hello.tmlp", "long.tml", "big.tml", "huge.tml"]) rmSync(join(dws, rel), {force: true})
})

const selectTheme = async (page, label) => {
  await page.keyboard.press("Control+k")
  await page.keyboard.press("Control+t")
  await page.locator("#palette-input").fill(label)
  await page.keyboard.press("Enter")
}

test("a plugin's TextMate grammar highlights its files, in the theme's colors", async ({page}) => {
  write("hello.tml", ['def greet "world"', "# a comment", "/* block", "still comment */ end"].join("\n"))
  await openInBee(page, "hello.tml")
  await expect(page.locator("#status-language, footer")).toContainText("TML")

  // Bee Dark: VS Code's Dark+ colors.
  await expect.poll(() => colorOf(page, "def")).toBe(rgb("#C586C0"))
  expect(await colorOf(page, "greet")).toBe(rgb("#DCDCAA"))
  expect(await colorOf(page, '"world"')).toBe(rgb("#ce9178"))
  expect(await colorOf(page, "# a comment")).toBe(rgb("#6A9955"))
  // The block comment's second line: its state carried over.
  expect(await colorOf(page, "still comment \\*/")).toBe(rgb("#6A9955"))
  expect(await colorOf(page, "end")).toBe(rgb("#C586C0"))

  // Typing re-highlights the changed line.
  await page.locator(".cm-line").first().click()
  await page.keyboard.press("End")
  await page.keyboard.type(" # added")
  await expect.poll(() => colorOf(page, "# added")).toBe(rgb("#6A9955"))
  await page.keyboard.press("Control+z")

  // Bee Light: Light+ colors; and back.
  await selectTheme(page, "Bee Light")
  await expect.poll(() => colorOf(page, "def")).toBe(rgb("#AF00DB"))
  expect(await colorOf(page, '"world"')).toBe(rgb("#a31515"))
  await selectTheme(page, "Bee Dark")
  await expect.poll(() => colorOf(page, "def")).toBe(rgb("#C586C0"))
})

test("a plist grammar works too", async ({page}) => {
  write("hello.tmlp", "x do y\n")
  await openInBee(page, "hello.tmlp")
  await expect.poll(() => colorOf(page, "do")).toBe(rgb("#C586C0"))
})

test("a long file: its end, past a comment spanning most of it", async ({page}) => {
  const lines = ["/* opened"]
  for (let i = 0; i < 5000; i++) lines.push(`def inside${i} "x"`)
  lines.push("closed */", "def last")
  write("long.tml", lines.join("\n"))
  await openInBee(page, "long.tml")
  await expect.poll(() => colorOf(page, "/\\* opened")).toBe(rgb("#6A9955"))

  await page.locator(".cm-content").click()
  await page.keyboard.press("Control+End")
  await expect.poll(() => colorOf(page, "last")).toBe(rgb("#DCDCAA"))
  expect(await colorOf(page, "closed \\*/")).toBe(rgb("#6A9955"))
  // Inside the comment, def is no keyword.
  expect(await colorOf(page, 'def inside4999 "x"')).toBe(rgb("#6A9955"))
})

const tokenized = page => page.evaluate(() => window.__beeTextMate?.tokenizedLines ?? 0)

// `count` lines of function definitions after a comment line.
const bigFile = (rel, count) => {
  const lines = ["# top"]
  for (let i = 0; i < count; i++) lines.push(`def fun${i} "x"`)
  write(rel, lines.join("\n"))
  return count + 1
}

test("a big file: tokenized while idle; an edit keeps the tokens after it", async ({page}) => {
  const total = bigFile("big.tml", 30000)
  await openInBee(page, "big.tml")
  await expect.poll(() => colorOf(page, "# top")).toBe(rgb("#6A9955"))

  // All of it, without scrolling there.
  await expect.poll(() => tokenized(page), {timeout: 20000}).toBeGreaterThanOrEqual(total)

  // Typing in the comment: its line again, not the 30000 after it.
  let before = await tokenized(page)
  await page.locator(".cm-line").first().click()
  await page.keyboard.press("End")
  await page.keyboard.type("!")
  await page.keyboard.press("Control+End")
  await expect.poll(() => colorOf(page, "fun29999")).toBe(rgb("#DCDCAA"))
  expect((await tokenized(page)) - before).toBeLessThan(20)

  // A change of state – a comment opened at the top – reaches the end.
  await page.keyboard.press("Control+Home")
  await page.keyboard.type("/* ")
  await page.keyboard.press("Control+End")
  await expect.poll(() => colorOf(page, 'def fun29999 "x"'), {timeout: 20000}).toBe(rgb("#6A9955"))

  // And closing it again.
  await page.keyboard.press("Control+Home")
  await page.keyboard.press("Delete")
  await page.keyboard.press("Delete")
  await page.keyboard.press("Delete")
  await page.keyboard.press("Control+End")
  await expect.poll(() => colorOf(page, "fun29999"), {timeout: 20000}).toBe(rgb("#DCDCAA"))
})

test("a huge file never stalls the page", async ({page}) => {
  const total = bigFile("huge.tml", 100000)
  await openInBee(page, "huge.tml")
  await expect.poll(() => colorOf(page, "# top"), {timeout: 20000}).toBe(rgb("#6A9955"))

  // From now on: the page's long tasks (over 50 ms, Chromium).
  await page.evaluate(() => {
    window.longTasks = []
    new PerformanceObserver(list => window.longTasks.push(...list.getEntries().map(e => e.duration))).observe({
      type: "longtask",
    })
  })

  // Typing and going to the end while it tokenizes the rest.
  await page.locator(".cm-line").first().click()
  await page.keyboard.press("End")
  await page.keyboard.type(" typed")
  await page.keyboard.press("Control+End")
  await expect.poll(() => colorOf(page, "fun99999"), {timeout: 30000}).toBe(rgb("#DCDCAA"))
  await expect.poll(() => tokenized(page), {timeout: 30000}).toBeGreaterThanOrEqual(total)

  const longest = Math.max(0, ...(await page.evaluate(() => window.longTasks)))
  test.info().annotations.push({type: "longest task", description: `${Math.round(longest)} ms`})
  expect(longest).toBeLessThan(100)
})

// What's shown, line text -> its spans, at `positions` (scroll fractions).
const snapshot = async (page, positions) => {
  const shown = {}
  for (const at of positions) {
    await page.locator(".cm-scroller").evaluate((el, at) => (el.scrollTop = at * el.scrollHeight), at)
    await page.waitForTimeout(100)
    // Only lines on screen: CodeMirror also renders the cursor's line
    // when scrolled away, undecorated.
    const lines = await page.locator(".cm-scroller").evaluate(scroller => {
      const box = scroller.getBoundingClientRect()
      return [...scroller.querySelectorAll(".cm-line")]
        .filter(l => {
          const r = l.getBoundingClientRect()
          return r.bottom > box.top && r.top < box.bottom
        })
        .map(l => [l.textContent, l.innerHTML])
    })
    for (const [text, html] of lines) shown[text] = html
  }
  return shown
}

// Until the tokenizer has been idle for a while.
const settled = async page => {
  let last = -1
  for (;;) {
    const now = await tokenized(page)
    if (now === last) return
    last = now
    await page.waitForTimeout(400)
  }
}

test("random edits: the same tokens as tokenizing all of it again", async ({page}) => {
  test.setTimeout(90000)
  bigFile("big.tml", 2000)
  await openInBee(page, "big.tml")
  await expect.poll(() => colorOf(page, "# top")).toBe(rgb("#6A9955"))

  // A fixed sequence, so a failure can be replayed; BEE_TEST_SEED for others.
  let seed = Number(process.env.BEE_TEST_SEED || 7)
  const random = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648)
  const snippets = ["/* ", " */", '"', "# ", "def ", "x"]
  for (let i = 0; i < 30; i++) {
    await page.locator(".cm-scroller").evaluate((el, at) => (el.scrollTop = at * el.scrollHeight), random())
    await page.waitForTimeout(30)
    const lines = page.locator(".cm-line")
    await lines.nth(Math.floor(random() * Math.max(1, (await lines.count()) - 1))).click()
    await page.keyboard.press(random() < 0.5 ? "Home" : "End")
    await page.keyboard.type(snippets[Math.floor(random() * snippets.length)])
  }
  await settled(page)
  const positions = [0, 0.1, 0.25, 0.4, 0.5, 0.6, 0.75, 0.9, 1]
  const incremental = await snapshot(page, positions)

  // From scratch: another theme and back tokenizes everything again.
  await selectTheme(page, "Bee Light")
  await selectTheme(page, "Bee Dark")
  await page.locator(".cm-content").click()
  await settled(page)
  const fresh = await snapshot(page, positions)

  const compared = Object.keys(incremental).filter(text => text in fresh)
  expect(compared.length).toBeGreaterThan(100)
  for (const text of compared) expect(incremental[text], text).toBe(fresh[text])
})
