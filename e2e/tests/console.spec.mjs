// The Bee Console: Elixir inside Bee, the panel's BEE CONSOLE section.
import {expect, freshBee, test} from "./helpers.mjs"
import {openBee} from "./helpers.mjs"

freshBee()

test("evaluates, keeps variables, completes, runs commands", async ({page}) => {
  await openBee(page)
  await page.keyboard.press("Control+Shift+P")
  await expect(page.locator("#palette-input")).toBeFocused()
  await page.keyboard.press("End")
  await page.keyboard.type("open bee console")
  await expect(page.locator("#palette [data-command='bee.console.open'][aria-selected=true]")).toBeVisible()
  await page.keyboard.press("Enter")
  await expect(page.locator("#panel-section-console[aria-selected=true]")).toBeVisible()

  const output = page.locator("#bee-console .xterm-rows")
  await expect(output).toContainText("Bee Console")

  await page.keyboard.type("x = Enum.sum(1..10)\n")
  await expect(output).toContainText("55")
  await page.keyboard.type("x * 2\n")
  await expect(output).toContainText("110")

  await page.keyboard.type("Enum.redu")
  await page.keyboard.press("Tab")
  await expect(output).toContainText("Enum.reduce")
  await page.keyboard.press("Control+u")

  await page.keyboard.type('run("workbench.action.toggleSidebarVisibility")\n')
  await expect(page.locator("#sidebar")).toHaveClass(/\bhidden\b/)
})
