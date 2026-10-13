// A file shown as it is (BeeWeb.Workbench.MediaPreview): an image, audio
// or video, as VS Code's media previews show them.
//
// An image starts as large as fits (never larger than it is). A click
// zooms in, a click with Ctrl (Alt on a Mac) out, through VS Code's
// levels; the wheel with that key zooms in small steps. What is in the
// middle stays there. From 3× on its pixels are shown as they are.
//
// The status bar (#status-media) says what the focused group's preview
// shows: an image's zoom and size in pixels, the file's size.
//
// data-media-preview  image, audio or video
// data-src            the file's address; another one once it changed
// data-size           the file's size, in bytes
// data-current        "true" for the focused group's active editor
// data-path, data-group  the tab's, for its commands

import {registerCommand} from "../commands/registry"

const LEVELS = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.5, 2, 3, 5, 7, 10, 15, 20]
const MIN = LEVELS[0]
const MAX = LEVELS[LEVELS.length - 1]
const PIXELATED_FROM = 3
const WHEEL_STEP = 0.075

const mac = /Mac|iPhone|iPad/.test(navigator.platform)
const zoomKey = event => (mac ? event.altKey : event.ctrlKey)

// The preview whose state the status bar shows.
let shown = null

// A file's size as VS Code writes it: 512B, 1.50KB, 2.25MB.
export const formatSize = bytes => {
  const units = ["KB", "MB", "GB", "TB"]
  if (!(bytes >= 1024)) return `${bytes || 0}B`
  let value = bytes / 1024
  let unit = 0
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024
    unit++
  }
  return `${value.toFixed(2)}${units[unit]}`
}

const FAILED = {
  image: "An error occurred while loading the image.",
  audio: "An error occurred while loading the audio file.",
  video: "An error occurred while loading the video file.",
}

export const MediaPreview = {
  mounted() {
    this.box = this.el.querySelector("[data-media-box]")
    this.kind = this.el.dataset.mediaPreview
    this.scale = "fit"
    this.commands = []

    this.box.addEventListener("click", event => {
      if (event.button !== 0 || !this.ready() || event.target.closest("a, button")) return
      if (zoomKey(event)) this.zoomOut()
      else this.zoomIn()
    })
    this.box.addEventListener(
      "wheel",
      event => {
        if (!this.ready() || !zoomKey(event)) return
        event.preventDefault()
        event.stopPropagation()
        this.setScale(this.current() * (1 - (event.deltaY > 0 ? 1 : -1) * WHEEL_STEP))
      },
      {passive: false},
    )
    // The pointer says what a click does.
    this.onKey = event => this.box.classList.toggle("zoom-out", zoomKey(event))
    window.addEventListener("keydown", this.onKey)
    window.addEventListener("keyup", this.onKey)
    this.onBlur = () => this.box.classList.remove("zoom-out")
    window.addEventListener("blur", this.onBlur)

    this.load()
    this.sync()
  },

  updated() {
    if (this.el.dataset.src !== this.src) this.load()
    this.sync()
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKey)
    window.removeEventListener("keyup", this.onKey)
    window.removeEventListener("blur", this.onBlur)
    this.commands.splice(0).forEach(unregister => unregister())
    if (shown === this) {
      shown = null
      this.status()?.replaceChildren()
    }
  },

  // Whether there is an image to zoom.
  ready() {
    return this.kind === "image" && this.loaded
  },

  // Shows the file (again: it changed), keeping an image's zoom.
  load() {
    this.src = this.el.dataset.src
    this.loaded = false

    if (this.kind === "image") {
      const image = new Image()
      image.draggable = false
      image.alt = ""
      image.addEventListener("load", () => {
        if (image !== this.image) return
        this.loaded = true
        this.box.replaceChildren(image)
        // (An SVG may not say how large it is: as large as it is drawn, then.)
        image.classList.add("fit")
        this.natural = {
          width: image.naturalWidth || image.clientWidth || 300,
          height: image.naturalHeight || image.clientHeight || 150,
        }
        this.setScale(this.scale)
      })
      image.addEventListener("error", () => image === this.image && this.failed())
      this.image = image
      image.src = this.src
    } else {
      const player = document.createElement(this.kind === "video" ? "video" : "audio")
      player.controls = true
      if (this.kind === "video") player.playsInline = true
      player.addEventListener("error", () => this.failed())
      player.src = this.src
      this.box.replaceChildren(player)
    }
  },

  // The file can't be shown: as VS Code says it, with the way out.
  failed() {
    this.loaded = false
    const note = document.createElement("div")
    note.className = "media-error"
    const message = document.createElement("p")
    message.textContent = FAILED[this.kind]
    const link = document.createElement("button")
    link.type = "button"
    link.className = "link link-primary cursor-pointer"
    link.textContent = "Open file using Bee's standard text/binary editor?"
    link.addEventListener("click", () =>
      this.pushEvent("run_command", {
        command: "workbench.action.reopenTextEditor",
        args: JSON.stringify([this.el.dataset.path, Number(this.el.dataset.group)]),
      }),
    )
    note.append(message, link)
    this.box.replaceChildren(note)
    this.sync()
  },

  // The scale the image is shown at now, as a number.
  current() {
    if (this.scale !== "fit") return this.scale
    return this.image.clientWidth / this.natural.width
  },

  zoomIn() {
    const scale = this.current()
    this.setScale(LEVELS.find(level => level > scale + 1e-9) ?? MAX)
  },

  zoomOut() {
    const scale = this.current()
    this.setScale([...LEVELS].reverse().find(level => level < scale - 1e-9) ?? MIN)
  },

  setScale(scale) {
    const {image, box} = this
    if (!this.ready()) return

    if (scale === "fit") {
      image.classList.add("fit")
      image.classList.remove("pixelated")
      image.style.width = image.style.height = ""
    } else {
      scale = Math.min(MAX, Math.max(MIN, scale))
      // What is in the middle of the view stays there.
      const x = (box.scrollLeft + box.clientWidth / 2) / box.scrollWidth
      const y = (box.scrollTop + box.clientHeight / 2) / box.scrollHeight
      image.classList.remove("fit")
      image.classList.toggle("pixelated", scale >= PIXELATED_FROM)
      image.style.width = `${this.natural.width * scale}px`
      image.style.height = `${this.natural.height * scale}px`
      box.scrollLeft = box.scrollWidth * x - box.clientWidth / 2
      box.scrollTop = box.scrollHeight * y - box.clientHeight / 2
    }

    this.scale = scale
    this.sync()
  },

  status() {
    return document.getElementById("status-media")
  },

  // The status bar and the zoom commands are the focused group's preview's.
  sync() {
    const current = this.el.dataset.current === "true"

    if (current && this.kind === "image" && this.commands.length === 0) {
      this.commands = [
        registerCommand("imagePreview.zoomIn", () => this.zoomIn()),
        registerCommand("imagePreview.zoomOut", () => this.zoomOut()),
      ]
    } else if (!current) {
      this.commands.splice(0).forEach(unregister => unregister())
    }

    const status = this.status()
    if (!status) return

    if (current) {
      shown = this
      const parts = []
      if (this.ready()) {
        parts.push(["zoom", this.scale === "fit" ? "Whole Image" : `${Math.round(this.scale * 100)}%`])
        parts.push(["dimensions", `${this.natural.width}x${this.natural.height}`])
      }
      parts.push(["size", formatSize(Number(this.el.dataset.size))])
      status.replaceChildren(
        ...parts.map(([name, text]) => {
          const part = document.createElement("span")
          part.dataset.media = name
          part.textContent = text
          return part
        }),
      )
    } else if (shown === this) {
      shown = null
      status.replaceChildren()
    }
  },
}
