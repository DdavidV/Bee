// Files that aren't text, opened as VS Code opens them: an image is shown
// and zoomed, audio and video get a player, any other binary file a note
// that it is one – with Open Anyway to see it as text all the same. Open
// With… chooses between the editors a file has (an SVG: seen and edited);
// a very large file isn't opened as text before Open Anyway either.
import {crc32, deflateSync} from "node:zlib"
import {readFileSync, writeFileSync} from "node:fs"
import {join} from "node:path"
import {
  activeTab, binaryEditor, contextMenu, dws, editor, editorLines, expect, expectFile, explorerItem, freshBee, group,
  mediaPreview, mediaStatus, menuItem, openBee, openFile, paletteItems, preview, previewFile, runCommand, shownImage,
  statusBar, tab, tabNames, test, unsaved, url, userSettingsFile, writeJson,
} from "./helpers.mjs"

// A PNG of `width` × `height` pixels, all of one color.
const png = (width, height, [r, g, b, a] = [200, 40, 40, 255]) => {
  const chunk = (type, data) => {
    const body = Buffer.concat([Buffer.from(type), data])
    const size = Buffer.alloc(4)
    size.writeUInt32BE(data.length)
    const sum = Buffer.alloc(4)
    sum.writeUInt32BE(crc32(body))
    return Buffer.concat([size, body, sum])
  }
  const header = Buffer.alloc(13)
  header.writeUInt32BE(width, 0)
  header.writeUInt32BE(height, 4)
  header.set([8, 6, 0, 0, 0], 8)
  const row = Buffer.concat([Buffer.from([0]), Buffer.alloc(width * 4, Buffer.from([r, g, b, a]))])
  const pixels = Buffer.concat(Array.from({length: height}, () => row))
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(pixels)),
    chunk("IEND", Buffer.alloc(0)),
  ])
}

const binary = Buffer.concat([Buffer.from("readable"), Buffer.from([0xff, 0x00, 0xfe]), Buffer.from("tail\n")])

// A tenth of a second of silence.
const wav = (() => {
  const samples = 800
  const header = Buffer.alloc(44)
  header.write("RIFF", 0)
  header.writeUInt32LE(36 + samples, 4)
  header.write("WAVEfmt ", 8)
  header.writeUInt32LE(16, 16)
  header.writeUInt16LE(1, 20)
  header.writeUInt16LE(1, 22)
  header.writeUInt32LE(8000, 24)
  header.writeUInt32LE(8000, 28)
  header.writeUInt16LE(1, 32)
  header.writeUInt16LE(8, 34)
  header.write("data", 36)
  header.writeUInt32LE(samples, 40)
  return Buffer.concat([header, Buffer.alloc(samples, 128)])
})()

const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="30">\n<rect width="40" height="30" fill="teal"/>\n</svg>\n'

// Chooses `name` in the pick that is open.
const choose = (page, name) => paletteItems(page).filter({hasText: name}).first().click()

freshBee({
  before: () => {
    writeFileSync(join(dws, "small.png"), png(40, 20))
    writeFileSync(join(dws, "wide.PNG"), png(4000, 10))
    writeFileSync(join(dws, "broken.png"), "not a picture\n")
    writeFileSync(join(dws, "data.bin"), binary)
    writeFileSync(join(dws, "drawing.svg"), svg)
    writeFileSync(join(dws, "second.svg"), svg)
    writeFileSync(join(dws, "big.log"), "0123456789abcde\n".repeat(100_000))
    writeFileSync(join(dws, "sound.wav"), wav)
    writeFileSync(join(dws, "noise.mp3"), "no sound\n")
  },
})

const width = locator => locator.evaluate(el => el.getBoundingClientRect().width)

test("an image is shown, with its zoom and sizes in the status bar", async ({page}) => {
  await openBee(page)
  await previewFile(page, "small.png")

  await expect(preview(tab(page, "small.png"))).toHaveCount(1)
  await expect(shownImage(page)).toBeVisible()
  expect(await width(shownImage(page))).toBe(40)
  await expect(mediaStatus(page, "zoom")).toHaveText("Whole Image")
  await expect(mediaStatus(page, "dimensions")).toHaveText("40x20")
  await expect(mediaStatus(page, "size")).toHaveText(`${png(40, 20).length}B`)

  // A text file: the status bar is its again.
  await previewFile(page, "one.txt")
  await expect(editorLines(page).first()).toHaveText("one")
  await expect(mediaStatus(page, "zoom")).toHaveCount(0)
  await expect(mediaPreview(page)).toHaveCount(0)
})

test("an image larger than the editor is shown whole, whatever the case of its name", async ({page}) => {
  await openBee(page)
  await openFile(page, "wide.PNG")
  await expect(shownImage(page)).toBeVisible()
  await expect(mediaStatus(page, "dimensions")).toHaveText("4000x10")
  await expect(mediaStatus(page, "zoom")).toHaveText("Whole Image")
  const shown = await width(shownImage(page))
  expect(shown).toBeLessThan(4000)
  expect(shown).toBeLessThanOrEqual(await width(mediaPreview(page)))
})

test("a click zooms in, a click with Ctrl out; so do the commands", async ({page}) => {
  await openBee(page)
  await openFile(page, "small.png")
  await expect(shownImage(page)).toBeVisible()

  await shownImage(page).click()
  await expect(mediaStatus(page, "zoom")).toHaveText("150%")
  expect(await width(shownImage(page))).toBe(60)

  await shownImage(page).click()
  await expect(mediaStatus(page, "zoom")).toHaveText("200%")

  await shownImage(page).click({modifiers: ["Control"]})
  await shownImage(page).click({modifiers: ["Control"]})
  await expect(mediaStatus(page, "zoom")).toHaveText("100%")
  expect(await width(shownImage(page))).toBe(40)

  await runCommand(page, "Image Preview: Zoom Out")
  await expect(mediaStatus(page, "zoom")).toHaveText("90%")
  await runCommand(page, "Image Preview: Zoom In")
  await runCommand(page, "Image Preview: Zoom In")
  await expect(mediaStatus(page, "zoom")).toHaveText("150%")

  // The wheel with Ctrl: in small steps.
  await shownImage(page).hover()
  await page.keyboard.down("Control")
  await page.mouse.wheel(0, -100)
  await page.keyboard.up("Control")
  await expect(mediaStatus(page, "zoom")).toHaveText("161%")

  // Zoomed, it stays so while another tab is shown.
  await openFile(page, "one.txt")
  await tab(page, "small.png").click()
  await expect(mediaStatus(page, "zoom")).toHaveText("161%")
})

test("an image that changes on disk is shown as it is now", async ({page}) => {
  await openBee(page)
  await openFile(page, "small.png")
  await expect(mediaStatus(page, "dimensions")).toHaveText("40x20")

  writeFileSync(join(dws, "small.png"), png(64, 32, [40, 40, 200, 255]))
  await expect(mediaStatus(page, "dimensions")).toHaveText("64x32")
  writeFileSync(join(dws, "small.png"), png(40, 20))
  await expect(mediaStatus(page, "dimensions")).toHaveText("40x20")
})

test("an image's file is the signed-in page's alone", async ({page, request}) => {
  await openBee(page)
  await openFile(page, "small.png")
  const src = await mediaPreview(page).getAttribute("data-src")

  const mine = await page.request.get(url + src)
  expect(mine.status()).toBe(200)
  expect(mine.headers()["content-type"]).toBe("image/png")
  expect((await mine.body()).equals(png(40, 20))).toBe(true)

  // Without Bee's cookie: nothing. With it, only addresses Bee made.
  expect((await request.get(url + src)).status()).toBe(401)
  expect((await page.request.get(`${url}/media/made-up/small.png`)).status()).toBe(404)
})

test("an image as text: Reopen Editor With Text Editor, or the link of one that can't be shown", async ({page}) => {
  await openBee(page)
  await openFile(page, "broken.png")
  await expect(mediaPreview(page)).toContainText("An error occurred while loading the image.")
  await mediaPreview(page).getByRole("button", {name: /standard text\/binary editor/}).click()
  await expect(editorLines(page).first()).toHaveText("not a picture")
  await expect(mediaPreview(page)).toHaveCount(0)
  expect(await tabNames(page)).toEqual(["broken.png"])

  await openFile(page, "small.png")
  await expect(shownImage(page)).toBeVisible()
  await runCommand(page, "Reopen Editor With Text Editor")
  await expect(editor(page)).toBeVisible()
  await expect(editor(page)).toContainText("PNG")
  await expect(shownImage(page)).toHaveCount(0)
  expect(await tabNames(page)).toEqual(["broken.png", "small.png"])
})

test("a binary file isn't shown as text until asked: Open Anyway", async ({page}) => {
  await openBee(page)
  await previewFile(page, "data.bin")

  await expect(activeTab(page)).toContainText("data.bin")
  await expect(binaryEditor(page)).toContainText(
    "The file is not displayed in the text editor because it is either binary or uses an unsupported text encoding.",
  )

  await binaryEditor(page).getByRole("button", {name: "Open Anyway"}).click()
  await expect(editorLines(page).first()).toContainText("readable")
  await expect(editorLines(page).first()).toContainText("tail")
  await expect(binaryEditor(page)).toHaveCount(0)
  expect(await tabNames(page)).toEqual(["data.bin"])

  // Looked at, not changed.
  await expect(unsaved(tab(page, "data.bin"))).toHaveCount(0)
  expect(readFileSync(join(dws, "data.bin")).equals(binary)).toBe(true)
})

test("audio gets a player; a file that is none says so", async ({page}) => {
  await openBee(page)
  await openFile(page, "sound.wav")
  const player = mediaPreview(page).locator("audio[controls]")
  await expect(player).toBeVisible()
  await expect.poll(() => player.evaluate(el => el.duration)).toBeCloseTo(0.1)
  await expect(mediaStatus(page, "size")).toHaveText("844B")
  await expect(statusBar(page)).not.toContainText("Whole Image")

  await openFile(page, "noise.mp3")
  await expect(mediaPreview(page)).toContainText("An error occurred while loading the audio file.")
})

test("an SVG is shown; Open With… opens it as text, and as an image again", async ({page}) => {
  await openBee(page)
  await openFile(page, "drawing.svg")
  await expect(shownImage(page)).toBeVisible()
  await expect(mediaStatus(page, "dimensions")).toHaveText("40x30")

  await explorerItem(page, "drawing.svg").click({button: "right"})
  await menuItem(contextMenu(page), "Open With…").click()
  await expect(paletteItems(page)).toHaveText([
    /^\s*Text Editor\s*$/,
    /Image Preview\s+Active and Default/,
    /Configure default editor for '\*\.svg'…/,
  ])
  await choose(page, "Text Editor")
  await expect(editorLines(page).first()).toContainText("<svg xmlns")
  await expect(shownImage(page)).toHaveCount(0)
  expect(await tabNames(page)).toEqual(["drawing.svg"])

  await tab(page, "drawing.svg").click({button: "right"})
  await menuItem(contextMenu(page), "Reopen Editor With…").click()
  await choose(page, "Image Preview")
  await expect(shownImage(page)).toBeVisible()
  expect(await tabNames(page)).toEqual(["drawing.svg"])
})

test("an SVG edited beside its picture: the picture follows what is saved", async ({page}) => {
  await openBee(page)
  await openFile(page, "drawing.svg")
  await expect(shownImage(page)).toBeVisible()

  await runCommand(page, "Split Editor Right")
  const [left, right] = [group(page, 1), group(page, 2)]
  await expect(right.tab("drawing.svg")).toBeVisible()
  await runCommand(page, "Reopen Editor With…")
  await choose(page, "Text Editor")
  await expect(right.lines.first()).toContainText("<svg xmlns")

  // height="30" becomes height="300".
  await right.lines.first().click()
  await page.keyboard.press("End")
  await page.keyboard.press("ArrowLeft")
  await page.keyboard.press("ArrowLeft")
  await page.keyboard.type("0")
  await page.keyboard.press("Control+s")
  await expectFile(join(dws, "drawing.svg"), svg.replace('height="30">', 'height="300">'))

  const picture = left.root.locator("[data-media-preview] img")
  await expect.poll(() => picture.evaluate(el => el.naturalHeight)).toBe(300)
})

test("Configure default editor: SVGs open as text from then on", async ({page}) => {
  await openBee(page)
  try {
    await explorerItem(page, "second.svg").click({button: "right"})
    await menuItem(contextMenu(page), "Open With…").click()
    await choose(page, "Configure default editor")
    await choose(page, "Text Editor")
    await expectFile(userSettingsFile, /"workbench\.editorAssociations":\s*\{\s*"\*\.svg":\s*"default"\s*\}/)

    await openFile(page, "second.svg")
    await expect(editorLines(page).first()).toContainText("<svg xmlns")
    await expect(shownImage(page)).toHaveCount(0)
  } finally {
    writeJson(userSettingsFile, {})
  }
})

test("a very large file isn't opened as text before Open Anyway", async ({page}) => {
  writeJson(userSettingsFile, {"workbench.editorLargeFileConfirmation": 1})
  try {
    await openBee(page)
    await previewFile(page, "big.log")
    await expect(binaryEditor(page)).toContainText(
      "The file is not displayed in the text editor because it is very large (1.53MB).",
    )

    await binaryEditor(page).getByRole("button", {name: "Configure Limit"}).click()
    await expect(page.getByRole("searchbox")).toHaveValue("workbench.editorLargeFileConfirmation")
    await expect(page.locator("#editor")).toContainText("Editor Large File Confirmation")

    await tab(page, "big.log").click()
    await binaryEditor(page).getByRole("button", {name: "Open Anyway"}).click()
    await expect(editorLines(page).first()).toHaveText("0123456789abcde")
    await expect(binaryEditor(page)).toHaveCount(0)
  } finally {
    writeJson(userSettingsFile, {})
  }
})
