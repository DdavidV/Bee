// ElixirLS, a real language extension: its language client runs in Bee's
// extension host and talks to its language server, which the editor shows
// the diagnostics, completions, hovers and definitions of. This is the one
// test of a language server as users have them (the others use Bee's small
// test extensions): its package comes from Open VSX, downloaded once into
// ./.cache (global-setup.mjs), and is installed here the way a user
// installs a VSIX. Without it (no network on the first run) the test is
// skipped. Slow the first time: the language server builds itself.
import {existsSync, mkdirSync, writeFileSync} from "node:fs"
import {join} from "node:path"
import {elixirLs, work} from "../fixtures.mjs"
import {expect, folderUrl, freshBee, openBee, runCommand, showView, sidebar, takeCompletion, test} from "./helpers.mjs"

const project = join(work, "mixws")

freshBee({
  before: () => {
    mkdirSync(join(project, "lib"), {recursive: true})
    writeFileSync(
      join(project, "mix.exs"),
      'defmodule Mixws.MixProject do\n  use Mix.Project\n\n  def project do\n    [app: :mixws, version: "0.1.0", elixir: "~> 1.15"]\n  end\nend\n',
    )
    writeFileSync(join(project, "lib/greeter.ex"), 'defmodule Greeter do\n  def hello(name) do\n    "hello " <> nam\n  end\nend\n')
    writeFileSync(join(project, "lib/other.ex"), "defmodule Other do\n  @doc \"Says it loudly.\"\n  def shout(text), do: String.upcase(text)\nend\n")
    writeFileSync(join(project, "lib/messy.ex"), "defmodule Messy do\n  def  add( a,b ),   do: a+b\nend\n")
  },
})

test.skip(!existsSync(elixirLs.vsix), "ElixirLS couldn't be downloaded")

test("its diagnostics, completion, parameter hints, hover, definitions, formatting, symbols, references and quick fixes work in the editor", async ({page}) => {
  test.setTimeout(240_000)
  await openBee(page, folderUrl(project))

  // Installed from its package, as a user does: Plugins: Install from VSIX…
  const chooser = page.waitForEvent("filechooser")
  await runCommand(page, "Install from VSIX")
  await (await chooser).setFiles(elixirLs.vsix)
  await showView(page, "Plugins")
  await expect(sidebar(page).getByText("ElixirLS", {exact: false}).first()).toBeVisible({timeout: 60_000})
  await showView(page, "Explorer")
  await page.click("#explorer button[phx-value-path='lib']")
  await page.click("#explorer button[phx-value-path='lib/greeter.ex']")
  await expect(page.locator("#tabs [data-path$='/lib/greeter.ex']")).toBeVisible()

  // The language server compiles the project, and reports.
  const error = page.locator("#editor .cm-lintRange-error")
  await expect(error.filter({hasText: "nam"})).toBeVisible({timeout: 200_000})
  await expect(page.locator("#editor .cm-lintRange-warning")).toHaveText("name")
  await expect(page.locator("#problems")).toHaveAttribute("title", /greeter\.ex: line 3: undefined variable "nam"/)

  await error.filter({hasText: "nam"}).hover()
  await expect(page.locator(".cm-tooltip-lint")).toContainText('undefined variable "nam"')
  await expect(page.locator(".cm-tooltip-lint")).toContainText("Elixir")
  await page.mouse.move(600, 600)

  // Quick Fix on the unused variable's line: a lightbulb, and its fix offered.
  await page.locator("#editor .cm-line").nth(1).click()
  await expect(page.locator("#editor .cm-language-lightbulb")).toHaveCount(1, {timeout: 30_000})
  await page.keyboard.press("Control+.")
  await expect(page.locator("#palette [data-pick]")).toContainText(["Rename to _name"], {timeout: 30_000})
  await page.keyboard.press("Escape")

  // The Problems section lists both, with who found them.
  await page.click("#problems")
  await expect(page.locator("#problems-view [data-problem][data-severity='error']", {hasText: 'undefined variable "nam"'})).toBeVisible()
  await expect(page.locator("#problems-view [data-problem][data-severity='warning']", {hasText: 'variable "name" is unused'})).toBeVisible()
  await page.keyboard.press("Control+j")

  // Its client's log is in the panel's Output section, on its own channel.
  await page.keyboard.press("F1")
  await page.fill("#palette-input", ">Show Output")
  await page.keyboard.press("Enter")
  const channel = await page.locator("#output-channel option", {hasText: "ElixirLS"}).first().textContent()
  await page.selectOption("#output-channel", channel.trim())
  await expect(page.locator("#output-text")).toContainText("Started ElixirLS")
  await expect(page.locator("#output-text")).toContainText("Compile took")
  await page.keyboard.press("Control+j")

  // Fixed and saved: it compiles again, the problems go.
  await page.locator("#editor .cm-line").nth(2).click()
  await page.keyboard.press("End")
  await page.keyboard.type("e")
  await page.keyboard.press("Control+s")
  await expect(page.locator("#editor .cm-lintRange-error")).toHaveCount(0, {timeout: 60_000})
  await expect(page.locator("#editor .cm-lintRange-warning")).toHaveCount(0)

  // Completion: a module's functions after its dot, with their documentation.
  const lines = page.locator("#editor .cm-line")
  const list = page.locator(".cm-tooltip-autocomplete")
  await page.keyboard.press("Enter")
  await page.keyboard.type("Other.")
  await expect(list).toContainText("shout", {timeout: 30_000})
  await page.keyboard.type("sh")
  await expect(list.locator("li")).toHaveCount(1)
  await expect(page.locator(".cm-completionInfo")).toContainText("Says it loudly.")
  await takeCompletion(page)
  await expect(lines.nth(3)).toHaveText(/^\s*Other\.shout\(/)
  // (The cursor is between its parentheses.) Its parameters are hinted:
  // ElixirLS asks for that as its completion is taken.
  const hints = page.locator(".cm-language-signature-help")
  await expect(hints).toContainText("shout(text)", {timeout: 30_000})
  await expect(hints.locator(".cm-language-parameter")).toHaveText("text")
  await page.keyboard.type("name")
  await page.keyboard.press("Escape")
  await page.keyboard.press("Control+s")
  await expect(lines.nth(3)).toHaveText(/^\s*Other\.shout\(name\)$/)

  // Hover: the function's documentation.
  await page.mouse.move(0, 0)
  const box = await lines.nth(3).boundingBox()
  const text = await lines.nth(3).textContent()
  // (A character is about 8.4px wide at the default size.)
  const x = box.x + (text.indexOf("shout") + 2) * 8.4
  await page.mouse.move(x, box.y + box.height / 2)
  await expect(page.locator(".cm-language-info")).toContainText("Says it loudly.", {timeout: 30_000})

  // Go to definition: Ctrl+click opens the other module at the function.
  await page.keyboard.down("Control")
  await page.mouse.click(x, box.y + box.height / 2)
  await page.keyboard.up("Control")
  await expect(page.locator("#tabs [data-path$='/lib/other.ex']")).toHaveAttribute("data-active", "true", {timeout: 30_000})
  await expect(page.locator("#editor .cm-activeLine")).toContainText("def shout(text)")

  // Format Document: mix format's way.
  await page.click("#explorer button[phx-value-path='lib/messy.ex']")
  await expect(page.locator("#tabs [data-path$='/lib/messy.ex']")).toHaveAttribute("data-active", "true")
  await expect(page.locator("#editor .cm-line").nth(1)).toHaveText("  def  add( a,b ),   do: a+b")
  await page.locator("#editor .cm-line").first().click()
  // (Its key works once the server has said it formats this file.)
  await expect(async () => {
    await page.keyboard.press("Shift+Alt+f")
    await expect(page.locator("#editor .cm-line").nth(1)).toHaveText("  def add(a, b), do: a + b", {timeout: 3000})
  }).toPass({timeout: 60_000})

  // Go to Symbol in Editor: the module and its function.
  await page.keyboard.press("Control+Shift+o")
  await expect(page.locator("#palette [data-symbol]").filter({hasText: "add"})).toBeVisible({timeout: 30_000})
  await page.keyboard.press("Escape")

  // Find All References, from the function's definition: its call in the other module.
  await page.locator("#tabs [data-path$='/lib/other.ex']").click()
  await page.locator("#editor .cm-line", {hasText: "def shout"}).click()
  await page.keyboard.press("Home")
  for (let i = 0; i < 7; i++) await page.keyboard.press("ArrowRight")
  await page.keyboard.press("Shift+F12")
  await expect(page.locator("#references [data-reference-file$='/lib/greeter.ex'] [data-reference]")).toContainText("Other.shout(name)", {timeout: 30_000})
  // (This ElixirLS doesn't rename: Rename Symbol isn't offered for its files.)
  await expect(page.locator("#workbench")).toHaveAttribute("data-context", /"editorHasRenameProvider":false/)
})
