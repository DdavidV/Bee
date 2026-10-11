// Plugins as a user manages them: folders that appear, change and go;
// enabling and disabling; mistakes in them; a folder's own plugins; and
// installing an extension from a .vsix file.
import {cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync} from "node:fs"
import {join} from "node:path"
import {zip} from "../mock-open-vsx.mjs"
import {
  config, dismiss, dws, error, expect, freshBee, info, openBee, openFile, paletteItems, read, repo, runCommand, showView, sidebar,
  test, userSettingsFile, work, workspaceSettingsFile, write, writeJson,
} from "./helpers.mjs"

const plugins = join(config, "plugins")

// A small plugin: a command that greets and counts, and one that fails.
const greeter = (dir, {name = "greeter", title = "Say Hi", greeting = "Hi", module = "Greeter"} = {}) => {
  write(
    join(dir, "plugin.json"),
    JSON.stringify({
      name,
      displayName: "Greeter",
      description: "Greets.",
      version: "1.0.0",
      server: {module},
      contributes: {
        commands: [
          {command: `${name}.hi`, category: "Greeter", title, runtime: "server"},
          {command: `${name}.fail`, category: "Greeter", title: "Fail", runtime: "server"},
        ],
      },
    }),
  )
  write(
    join(dir, "lib/greeter.ex"),
    `defmodule ${module} do
  use Bee.Plugin

  @impl true
  def activate(_ctx), do: {:ok, 0}

  @command "${name}.hi"
  def hi(ctx, count) do
    Bee.API.show_message(ctx, :info, "${greeting} number #{count + 1}")
    {:ok, count + 1}
  end

  @command "${name}.fail"
  def fail(_ctx, _count), do: raise("it broke on purpose")
end
`,
  )
}

freshBee({before: () => greeter(join(plugins, "greeter"))})

const row = (page, name) => sidebar(page).locator(`#plugin-${name}`)
const rowButton = async (page, name, title) => {
  await row(page, name).hover()
  await row(page, name).getByTitle(title, {exact: true}).click()
}
const offered = async (page, title) => {
  await page.keyboard.press("F1")
  await page.locator("#palette-input").fill(`>${title}`)
  const found = await paletteItems(page)
    .filter({hasText: title})
    .first()
    .waitFor({timeout: 700})
    .then(() => true, () => false)
  await page.keyboard.press("Escape")
  await expect(page.locator("#palette")).toHaveCount(0)
  return found
}

test("the Plugins view lists what is installed and what is built in", async ({page}) => {
  await openBee(page)
  await showView(page, "Plugins")
  await expect(row(page, "greeter")).toContainText("Greeter")
  await expect(row(page, "greeter")).toContainText("1.0.0")
  await expect(row(page, "greeter")).toContainText("Greets.")
  await expect(row(page, "git")).toContainText("Git")
  // Built-in plugins can be switched off, not removed.
  await row(page, "git").hover()
  await expect(row(page, "git").getByTitle("Disable")).toBeVisible()
  await expect(row(page, "git").getByTitle("Uninstall")).toHaveCount(0)
  await row(page, "greeter").hover()
  await expect(row(page, "greeter").getByTitle("Uninstall")).toBeVisible()
})

test("a plugin's command runs its code, which keeps its state", async ({page}) => {
  await openBee(page)
  await runCommand(page, "Greeter: Say Hi")
  await expect(info(page)).toContainText("Hi number 1")
  await dismiss(info(page))
  await runCommand(page, "Greeter: Say Hi")
  await expect(info(page)).toContainText("Hi number 2")
})

test("a command that fails is reported; the plugin goes on as it was", async ({page}) => {
  await openBee(page)
  await runCommand(page, "Greeter: Say Hi")
  await expect(info(page)).toContainText(/Hi number \d+/)
  const before = Number((await info(page).textContent()).match(/number (\d+)/)[1])
  await dismiss(info(page))

  await runCommand(page, "Greeter: Fail")
  await expect(error(page)).toContainText("it broke on purpose")
  await dismiss(error(page))

  await runCommand(page, "Greeter: Say Hi")
  await expect(info(page)).toContainText(`Hi number ${before + 1}`)
})

test("disabled: its commands go, the setting records it; enabled: they are back", async ({page}) => {
  await openBee(page)
  await showView(page, "Plugins")
  await rowButton(page, "greeter", "Disable")
  await expect(row(page, "greeter")).toContainText("disabled")
  expect(await offered(page, "Greeter: Say Hi")).toBe(false)
  expect(JSON.parse(read(userSettingsFile).replace(/^\s*\/\/.*$/gm, ""))["plugins.disabled"]).toEqual(["greeter"])

  await rowButton(page, "greeter", "Enable")
  await expect(row(page, "greeter")).not.toContainText("disabled")
  expect(await offered(page, "Greeter: Say Hi")).toBe(true)
})

test("plugins.disabled in the settings file does the same", async ({page}) => {
  await openBee(page)
  expect(await offered(page, "Greeter: Say Hi")).toBe(true)
  writeJson(userSettingsFile, {"plugins.disabled": ["greeter"]})
  await expect.poll(() => offered(page, "Greeter: Say Hi")).toBe(false)
  writeJson(userSettingsFile, {})
  await expect.poll(() => offered(page, "Greeter: Say Hi")).toBe(true)
})

test("a built-in plugin can be disabled too: Git's views and status go", async ({page}) => {
  await openBee(page)
  const scm = page.locator("#activity-bar").getByRole("button", {name: "Source Control"})
  await expect(scm).toBeVisible()
  writeJson(userSettingsFile, {"plugins.disabled": ["git"]})
  await expect(scm).toHaveCount(0)
  writeJson(userSettingsFile, {})
  await expect(scm).toBeVisible()
})

test("a plugin folder that appears is loaded; changed, reloaded; removed, gone", async ({page}) => {
  await openBee(page)
  await showView(page, "Plugins")
  await expect(row(page, "waver")).toHaveCount(0)

  const dir = join(plugins, "waver")
  greeter(dir, {name: "waver", title: "Wave", greeting: "Wave", module: "Waver"})
  await expect(row(page, "waver")).toBeVisible()
  await runCommand(page, "Greeter: Wave")
  await expect(info(page)).toContainText("Wave number 1")
  await dismiss(info(page))

  // Its code and its manifest, edited: in effect without a restart.
  greeter(dir, {name: "waver", title: "Wave Twice", greeting: "Waving", module: "Waver"})
  await expect.poll(() => offered(page, "Greeter: Wave Twice")).toBe(true)
  await runCommand(page, "Greeter: Wave Twice")
  await expect(info(page)).toContainText("Waving number 1")

  rmSync(dir, {recursive: true})
  await expect(row(page, "waver")).toHaveCount(0)
  expect(await offered(page, "Greeter: Wave Twice")).toBe(false)
})

test("a plugin with a broken manifest is listed with what is wrong; the others work", async ({page}) => {
  write(join(plugins, "broken-manifest/plugin.json"), JSON.stringify({name: "broken-manifest", contributes: {commands: [{command: "x.y"}]}}))
  write(join(plugins, "not-json/plugin.json"), "{ this is not json")
  await openBee(page)
  await showView(page, "Plugins")
  await expect(row(page, "broken-manifest")).toContainText("invalid")
  await expect(row(page, "broken-manifest")).toContainText(/title|runtime|required/i)
  await expect(row(page, "not-json")).toContainText("invalid")

  await runCommand(page, "Greeter: Say Hi")
  await expect(info(page)).toContainText("Hi number")
  rmSync(join(plugins, "broken-manifest"), {recursive: true})
  rmSync(join(plugins, "not-json"), {recursive: true})
})

test("a plugin whose code doesn't compile fails when it is started, saying where", async ({page}) => {
  const dir = join(plugins, "typo")
  greeter(dir, {name: "typo", title: "Typo", module: "Typo"})
  writeFileSync(join(dir, "lib/greeter.ex"), "defmodule Typo do\n  use Bee.Plugin\n  def broken( do\nend\n")
  await openBee(page)
  await runCommand(page, "Greeter: Typo")
  await showView(page, "Plugins")
  await expect(row(page, "typo")).toContainText("failed")
  await expect(row(page, "typo")).toContainText(/line 3/)
  rmSync(dir, {recursive: true})
})

test("a plugin may not take a name Bee's own code has", async ({page}) => {
  const dir = join(plugins, "squatter")
  greeter(dir, {name: "squatter", title: "Squat", module: "Enum"})
  await openBee(page)
  await runCommand(page, "Greeter: Squat")
  await showView(page, "Plugins")
  await expect(row(page, "squatter")).toContainText("failed")
  await expect(row(page, "squatter")).toContainText(/already exists/)
  // Bee is unharmed.
  await runCommand(page, "Greeter: Say Hi")
  await expect(info(page)).toContainText("Hi number")
  rmSync(dir, {recursive: true})
})

test("two plugins can't contribute the same command", async ({page}) => {
  const dir = join(plugins, "copycat")
  greeter(dir, {name: "copycat", module: "Copycat"})
  // The same command id as greeter's.
  const manifest = JSON.parse(readFileSync(join(dir, "plugin.json"), "utf8"))
  manifest.contributes.commands[0].command = "greeter.hi"
  writeFileSync(join(dir, "plugin.json"), JSON.stringify(manifest))
  await openBee(page)
  await showView(page, "Plugins")
  await expect(row(page, "copycat")).toContainText("invalid")
  await expect(row(page, "copycat")).toContainText("greeter.hi")
  rmSync(dir, {recursive: true})
})

test("Uninstall asks, then removes the plugin's folder", async ({page}) => {
  const dir = join(plugins, "goner")
  greeter(dir, {name: "goner", title: "Gone", module: "Goner"})
  await openBee(page)
  await showView(page, "Plugins")
  await rowButton(page, "goner", "Uninstall")
  await page.keyboard.press("Escape")
  expect(existsSync(dir)).toBe(true)

  await rowButton(page, "goner", "Uninstall")
  await paletteItems(page).filter({hasText: /Uninstall/}).first().click()
  await expect(row(page, "goner")).toHaveCount(0)
  expect(existsSync(dir)).toBe(false)
})

test("a folder's own plugins run only when the user's settings allow it", async ({page}) => {
  greeter(join(dws, ".bee/plugins/local"), {name: "local", title: "Local Hello", greeting: "Local", module: "LocalGreeter"})
  // The folder can't allow it for itself.
  writeJson(workspaceSettingsFile(dws), {"plugins.workspace.enabled": true})
  await openBee(page)
  expect(await offered(page, "Greeter: Local Hello")).toBe(false)

  writeJson(userSettingsFile, {"plugins.workspace.enabled": true})
  await expect.poll(() => offered(page, "Greeter: Local Hello")).toBe(true)
  await runCommand(page, "Greeter: Local Hello")
  await expect(info(page)).toContainText("Local number 1")

  writeJson(userSettingsFile, {})
  await expect.poll(() => offered(page, "Greeter: Local Hello")).toBe(false)
  rmSync(join(dws, ".bee"), {recursive: true})
})

test.describe("Install from VSIX…", () => {
  const vsix = join(work, "sky.vsix")
  const pack = version =>
    writeFileSync(
      vsix,
      zip({
        "extension/package.json": JSON.stringify({
          name: "sky",
          displayName: "Sky",
          publisher: "acme",
          version,
          contributes: {themes: [{label: "Sky Theme", uiTheme: "vs", path: "./themes/sky.json"}]},
        }),
        "extension/themes/sky.json": JSON.stringify({colors: {"editor.background": "#cceeff"}}),
        "extension/README.md": "# Sky\n",
      }),
    )

  const install = async (page, file) => {
    const chooser = page.waitForEvent("filechooser")
    await runCommand(page, "Plugins: Install from VSIX…")
    await (await chooser).setFiles(file)
  }

  test("installs the extension: listed, its theme can be picked; again: updated", async ({page}) => {
    pack("1.0.0")
    await openBee(page)
    await showView(page, "Plugins")
    await install(page, vsix)
    await expect(row(page, "sky")).toContainText("1.0.0")
    expect(existsSync(join(plugins, "sky/package.json"))).toBe(true)

    await runCommand(page, "Preferences: Color Theme")
    await expect(paletteItems(page).filter({hasText: "Sky Theme"})).toBeVisible()
    await page.keyboard.press("Escape")

    pack("1.1.0")
    await install(page, vsix)
    await expect(row(page, "sky")).toContainText("1.1.0")
  })

  test("a file that isn't a package is refused", async ({page}) => {
    const bogus = join(work, "bogus.vsix")
    writeFileSync(bogus, "this is not a zip")
    await openBee(page)
    await install(page, bogus)
    await expect(error(page)).toBeVisible()
    await showView(page, "Plugins")
    await expect(row(page, "bogus")).toHaveCount(0)
  })

  test("a package can't write outside its own folder", async ({page}) => {
    const sneaky = join(work, "sneaky.vsix")
    writeFileSync(
      sneaky,
      zip({
        "extension/package.json": JSON.stringify({name: "sneaky", publisher: "acme", version: "1.0.0"}),
        "extension/../../escaped.txt": "out",
      }),
    )
    await openBee(page)
    await install(page, sneaky)
    await expect(error(page)).toBeVisible()
    expect(existsSync(join(plugins, "escaped.txt"))).toBe(false)
    expect(existsSync(join(config, "escaped.txt"))).toBe(false)
  })
})
