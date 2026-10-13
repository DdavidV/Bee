// A VS Code extension's commands, menus, keybindings and settings: Bee's
// test extension (bee/test/fixtures/extensions/hello), installed the way a
// VSIX is, for these tests only (it changes defaults, like editor.tabSize).
// Its commands run its code, in Bee's extension host (Node.js).
import {expect, freshBee, test} from "./helpers.mjs"
import {cpSync, existsSync, readFileSync, rmSync, writeFileSync} from "node:fs"
import {dirname, join, resolve} from "node:path"
import {config, dws} from "../fixtures.mjs"
import {dismiss, error, info, openBee, openFile} from "./helpers.mjs"

freshBee({before: () => install()})

const here = dirname(new URL(import.meta.url).pathname)
const repo = resolve(process.env.BEE_REPO || join(here, "../.."))
const plugin = join(config, "plugins/hello")
const settings = join(config, "settings.json")

// Installed before Bee starts: it loads with it.
const install = () => {
  cpSync(join(repo, "test/fixtures/extensions/hello"), plugin, {recursive: true})
  writeFileSync(join(plugin, ".vsix.json"), JSON.stringify({name: "hello"}))
}

test.afterAll(() => {
  rmSync(plugin, {recursive: true, force: true})
  rmSync(settings, {force: true})
})

test.beforeEach(async ({page, context, baseURL}) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"], {origin: baseURL})
  await openBee(page)
  // Bee notices the new plugin folder by itself.
  await page.click("#view-extensions")
  await expect(page.locator("#plugin-hello")).toBeVisible()
  await page.click("#view-explorer")
})

const flash = page => info(page)

test("its commands are in the palette, with their keys", async ({page}) => {
  await page.keyboard.press("F1")
  await expect(page.locator("#palette-input")).toHaveValue(">")
  await page.fill("#palette-input", ">hello")
  const items = page.locator("#palette-items [role=option]")
  await expect(items.filter({hasText: "Hello: Say Hello"})).toContainText("Ctrl+Alt+H")
  await expect(items.filter({hasText: "Hello: Pick a Greeting"})).toHaveCount(1)
  // Hidden by its commandPalette entry; needs a selection.
  await expect(items.filter({hasText: "Greet This File"})).toHaveCount(0)
  await expect(items.filter({hasText: "Shout Selection"})).toHaveCount(0)

  // Running one starts the extension's code.
  await items.filter({hasText: "Hello: Say Hello"}).click()
  await expect(flash(page)).toContainText("Hello from the hello extension")
})

test("a quick pick of the extension's, and the setting it writes", async ({page}) => {
  await page.keyboard.press("F1")
  await expect(page.locator("#palette-input")).toHaveValue(">")
  await page.fill("#palette-input", ">pick a greeting")
  await page.keyboard.press("Enter")

  // The extension asks in the palette.
  const input = page.locator("#palette-input")
  await expect(input).toHaveAttribute("placeholder", "Pick a greeting")
  await expect(page.locator("#palette-items [role=option]")).toHaveText([/Hello/, /Hi/, /Howdy/])
  await page.keyboard.type("how")
  await expect(page.locator("#palette-items [role=option]")).toHaveCount(1)
  await page.keyboard.press("Enter")
  await expect(page.locator("#palette")).toHaveCount(0)

  // It wrote the pick to the user's settings, and reads it back.
  await expect.poll(() => existsSync(settings) && readFileSync(settings, "utf8")).toContain('"hello.greeting": "Howdy"')
  await page.keyboard.press("Control+Alt+h")
  await expect(flash(page)).toContainText("Howdy from the hello extension")

  // Escape: no pick.
  await page.keyboard.press("F1")
  await page.fill("#palette-input", ">pick a greeting")
  await page.keyboard.press("Enter")
  await expect(input).toHaveAttribute("placeholder", "Pick a greeting")
  await page.keyboard.press("Escape")
  await expect(page.locator("#palette")).toHaveCount(0)
  rmSync(settings, {force: true})
})

test("the editor's right-click menu: clipboard, the extension's items, a submenu", async ({page}) => {
  await openFile(page, "one.txt")
  // Right-clicks on the first line ("one"; the last one is empty).
  const content = page.locator("#editor .cm-line").first()
  await content.click({button: "right"})

  const menu = page.locator("#context-menu")
  await expect(menu.locator(":scope > [data-command] > span:first-child")).toHaveText([
    "Say Hello", "Cut", "Copy", "Paste", "Show All Commands",
  ])
  await expect(menu.locator("[data-command='hello.sayHello']")).toContainText("Ctrl+Alt+H")

  // The submenu opens beside its item, inside the window.
  const submenu = menu.locator("[data-submenu='hello.more']")
  await expect(submenu).toContainText("More Greetings")
  await expect(submenu.locator("[role=menu]")).toBeHidden()
  await submenu.hover()
  await expect(submenu.locator("[role=menu] [data-command] > span:first-child")).toHaveText([
    "Pick a Greeting", "Insert Text",
  ])
  const box = await submenu.locator("[role=menu]").boundingBox()
  expect(box.x + box.width).toBeLessThanOrEqual(1200)
  await submenu.locator("[data-command='hello.pick']").click()
  await expect(menu).toHaveCount(0)
  await expect(page.locator("#palette-input")).toHaveAttribute("placeholder", "Pick a greeting")
  await page.keyboard.press("Escape")
  await expect(page.locator("#palette")).toHaveCount(0)

  // Copy without a selection: the line. Paste puts it back in.
  await content.click({button: "right"})
  await page.click("#context-menu [data-command='editor.action.clipboardCopyAction']")
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe("one\n")
  await content.click({button: "right"})
  await page.click("#context-menu [data-command='editor.action.clipboardPasteAction']")
  await expect(page.locator("#editor .cm-line")).toHaveCount(3)

  // With a selection: the extension's item for one, and Cut takes it.
  await page.keyboard.press("Control+a")
  await content.click({button: "right"})
  await expect(page.locator("#context-menu [data-command='hello.shout']")).toBeVisible()
  await page.click("#context-menu [data-command='editor.action.clipboardCutAction']")
  await expect(page.locator("#editor .cm-line")).toHaveCount(1)
  // (Pasted where the right-click put the cursor, inside the first line.)
  expect(await page.evaluate(() => navigator.clipboard.readText())).toHaveLength(8)
  await page.keyboard.press("Control+z")
  await page.keyboard.press("Control+z")

  // Escape closes it; with Shift the browser's own menu is left alone.
  await content.click({button: "right"})
  await expect(menu).toBeVisible()
  await page.keyboard.press("Escape")
  await expect(menu).toHaveCount(0)
  await content.click({button: "right", modifiers: ["Shift"]})
  await expect(menu).toHaveCount(0)
})

test("the Explorer's menu and the editor's buttons", async ({page}) => {
  await page.click("#explorer button[phx-value-path='one.txt']", {button: "right"})
  // The command gets the file (a vscode.Uri).
  await page.click("#context-menu [data-command='hello.reveal']")
  await expect(flash(page)).toContainText(/Hello, .*\/dws\/one\.txt/)
  // (The message is over the editor's buttons: clicked away.)
  await dismiss(flash(page))
  await expect(flash(page)).toBeHidden()

  await page.click("#explorer button[phx-value-path='lib']", {button: "right"})
  await expect(page.locator("#context-menu")).toBeVisible()
  await expect(page.locator("#context-menu [data-command='hello.reveal']")).toHaveCount(0)
  await page.keyboard.press("Escape")

  // A codicon, and the extension's own image (the dark one, in the dark theme).
  await openFile(page, "one.txt")
  const say = page.locator("button[data-command='hello.sayHello'][title^='Say Hello']")
  await expect(say.locator("svg")).toBeVisible()
  const shout = page.locator("button[data-command='hello.shout']")
  await expect(shout).toBeDisabled()
  await expect(shout.locator("img[src$='shout-dark.svg']")).toBeVisible()
  await expect(shout.locator("img[src$='shout-light.svg']")).toBeHidden()
  // (Visible before it is loaded: its size comes with the file.)
  await expect.poll(() => shout.locator("img[src$='shout-dark.svg']").evaluate(img => img.naturalWidth)).toBeGreaterThan(0)

  // Selecting text enables it: a text editor command, it edits the selection.
  const lines = page.locator("#editor .cm-line")
  await lines.first().click()
  await page.keyboard.press("Home")
  await page.keyboard.press("Shift+End")
  await expect(shout).toBeEnabled()
  await shout.click()
  await expect(lines.first()).toHaveText("ONE")
  // One undo step, like any edit (back in the editor: the button has the focus).
  await lines.first().click()
  await page.keyboard.press("Control+z")
  await expect(lines.first()).toHaveText("one")
})

test("its keybindings", async ({page}) => {
  await openFile(page, "one.txt")
  await page.locator("#editor .cm-content").click()
  await page.keyboard.press("Control+Alt+h")
  await expect(flash(page)).toContainText("from the hello extension")

  // A binding with arguments ({"text": "inserted"}), at the cursor.
  const first = page.locator("#editor .cm-line").first()
  await first.click()
  await page.keyboard.press("End")
  await page.keyboard.press("Control+Alt+i")
  await expect(first).toHaveText("oneinserted")
  await page.keyboard.press("Control+z")
  await expect(first).toHaveText("one")

  // Its Linux keys (others: Ctrl+Alt+U), only with the editor focused.
  await page.keyboard.press("Home")
  await page.keyboard.press("Shift+End")
  await page.keyboard.press("Control+Alt+Shift+u")
  await expect(first).toHaveText("ONE")
  await page.keyboard.press("Control+z")
  await expect(first).toHaveText("one")

  // A key of the extension's for one of Bee's commands (oem_3 is `).
  await expect(page.locator("#panel")).toHaveCount(0)
  await page.keyboard.press("Control+Alt+Backquote")
  await expect(page.locator("#panel")).toBeVisible()
  await page.keyboard.press("Control+Alt+Backquote")
  await expect(page.locator("#panel")).toHaveCount(0)
})

test("its settings are checked, and listed on its details page", async ({page}) => {
  writeFileSync(settings, JSON.stringify({"hello.volume": 12, "hello.style": "fancy"}))
  await expect(page.locator("#problems")).toHaveAttribute("title", /settings\.json: "hello\.volume"/)
  writeFileSync(settings, JSON.stringify({"hello.volume": 11, "hello.style": "fancy"}))
  await expect(page.locator("#problems")).toHaveCount(0)

  await page.click("#view-extensions")
  await page.click("#plugin-hello")
  const details = page.locator("#extension-hello")
  await expect(details.locator("h1")).toHaveText("Hello Extension")
  await expect(details.locator("summary")).toContainText("8 part(s) of this extension aren't used")
  await page.click("#extension-hello-tab-features")
  const features = page.locator("#extension-hello-features")
  await expect(features).toContainText("hello.sayHello")
  await expect(features).toContainText("Hello: Say Hello")
  await expect(features).toContainText("hello.greeting")
  await expect(features).toContainText("What it says.")
})

// A command of the extension's that isn't in its package.json (registered
// when its code runs): run as a keybinding would.
const run = (page, command, args = []) =>
  page.evaluate(([command, args]) => {
    const main = document.querySelector("[data-phx-main]")
    window.liveSocket.execJS(main, JSON.stringify([["push", {event: "run_command", value: {command, args: JSON.stringify(args)}}]]))
  }, [command, args])

test("the Output section: what extensions write, a channel at a time", async ({page}) => {
  // Its code starts with its first command.
  await page.keyboard.press("Control+Alt+h")
  await expect(flash(page)).toContainText("from the hello extension")
  await dismiss(flash(page))

  // An extension shows its output channel: the panel opens on it.
  await run(page, "hello.output", ["first line"])
  const text = page.locator("#output-text")
  await expect(text).toBeVisible()
  await expect(text).toHaveText("first line\n")
  await expect(page.locator("#output-channel")).toHaveValue("Hello")
  await expect(page.locator("#panel-sections [data-section=output]")).toHaveAttribute("aria-selected", "true")

  // What it writes then is added, as it comes.
  await run(page, "hello.output", ["second line", false])
  await expect(text).toHaveText("first line\nsecond line\n")

  // A failing command: the extension host's channel has where it was raised.
  await run(page, "hello.broken")
  await expect(error(page)).toContainText("broken on purpose")
  await page.selectOption("#output-channel", "Extension Host")
  await expect(text).toContainText("command hello.broken failed: Error: broken on purpose")
  await expect(text).toContainText("extension.js")
  await expect(text).not.toContainText("first line")

  // Back, and Clear Output: that channel only.
  await page.selectOption("#output-channel", "Hello")
  await expect(text).toHaveText("first line\nsecond line\n")
  await page.click("#panel button[data-command='workbench.output.action.clearOutput']")
  await expect(text).toHaveText("")
  await page.selectOption("#output-channel", "Extension Host")
  await expect(text).toContainText("broken on purpose")

  // Closed and opened again (View: Show Output): still there.
  await page.keyboard.press("Control+j")
  await expect(page.locator("#panel")).toHaveCount(0)
  await page.keyboard.press("F1")
  await page.fill("#palette-input", ">Show Output")
  await page.keyboard.press("Enter")
  await expect(text).toContainText("broken on purpose")

  // A terminal of the extension's: in the panel beside the user's, with
  // its name, what it typed and the environment it asked for.
  await run(page, "hello.terminal")
  await expect(page.locator("#panel-sections [data-section=terminal]")).toHaveAttribute("aria-selected", "true")
  await expect(page.locator("#panel [id^=term-tab-]")).toHaveText("Hello Shell")
  await expect(page.locator("#panel .xterm-rows")).toContainText("mine-everywhere")
  // Disposed of by the extension: gone.
  await run(page, "hello.terminalClose")
  await expect(page.locator("#panel [id^=term-tab-]")).toHaveCount(0)
})

test("a diff of the extension's: a tab with what differs; its Accept button writes the file and closes it", async ({page}) => {
  writeFileSync(join(dws, "one.txt"), "first\nsecond thing\nthird\n")
  await page.reload()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  await openFile(page, "one.txt")
  // Its code starts with its first command.
  await page.keyboard.press("Control+Alt+h")
  await expect(flash(page)).toContainText("from the hello extension")
  await dismiss(flash(page))
  await run(page, "hello.diff")

  // The tab: named by the extension, the lines that differ in it.
  const tab = page.locator("[data-tabs] [data-path^='diff:']")
  await expect(tab).toHaveText(/Shout ↔ notes/)
  await expect(tab).toHaveAttribute("data-active", "true")
  const diff = page.locator("[data-diff]")
  await expect(diff.locator("[data-diff-row=del]")).toHaveText(/2\s*−\s*second thing/)
  await expect(diff.locator("[data-diff-row=ins]")).toHaveText([/2\s*\+\s*SECOND thing/, /4\s*\+\s*added/])
  await expect(diff.locator("[data-diff-row=eq]")).toHaveCount(2)
  await page.screenshot({path: "test-results/diff-tab.png"})

  // While it is shown, the extension's buttons are in the tab bar; not for a file.
  const accept = page.locator("#editor-actions [data-command='hello.acceptDiff']")
  await expect(accept).toBeVisible()
  await page.locator("[data-tabs] [data-path$='/one.txt']").click()
  await expect(accept).toHaveCount(0)
  await tab.click()

  // Accept: the file has the change, the tab is gone.
  await accept.click()
  await expect(tab).toHaveCount(0)
  await expect.poll(() => readFileSync(join(dws, "one.txt"), "utf8")).toBe("first\nSECOND thing\nthird\nadded\n")

  // Again, and closed by hand: the extension hears of it (its buttons go).
  await run(page, "hello.diff")
  await expect(tab).toHaveCount(1)
  await expect(page.locator("[data-diff-row=ins]")).toHaveText(/5\s*\+\s*added/)
  await tab.locator("[data-close]").click()
  await expect(tab).toHaveCount(0)
  await expect(accept).toHaveCount(0)
})
