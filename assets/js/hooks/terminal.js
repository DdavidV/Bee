// xterm.js view of one Bee.Terminal process.
//
// On mount the hook reports its size with `term_ready`; the reply carries the
// scrollback so far, after which the server forwards new output as
// `term:data` events (base64, since pty output isn't necessarily UTF-8).
//
// Server -> client: term:data
// Client -> server: term_ready, term_input, term_resize

import {Terminal as XTerm} from "@xterm/xterm"
import {FitAddon} from "@xterm/addon-fit"

const decode = base64 => Uint8Array.from(atob(base64), c => c.charCodeAt(0))

const DARK = {
  background: "#282c34",
  foreground: "#abb2bf",
  cursor: "#528bff",
  selectionBackground: "#3e4451",
  black: "#282c34",
  red: "#e06c75",
  green: "#98c379",
  yellow: "#e5c07b",
  blue: "#61afef",
  magenta: "#c678dd",
  cyan: "#56b6c2",
  white: "#abb2bf",
  brightBlack: "#5c6370",
  brightRed: "#e06c75",
  brightGreen: "#98c379",
  brightYellow: "#e5c07b",
  brightBlue: "#61afef",
  brightMagenta: "#c678dd",
  brightCyan: "#56b6c2",
  brightWhite: "#ffffff",
}

const LIGHT = {
  background: "#ffffff",
  foreground: "#383a42",
  cursor: "#526fff",
  selectionBackground: "#e5e5e6",
  black: "#383a42",
  red: "#e45649",
  green: "#50a14f",
  yellow: "#c18401",
  blue: "#4078f2",
  magenta: "#a626a4",
  cyan: "#0184bc",
  white: "#a0a1a7",
  brightBlack: "#696c77",
  brightRed: "#e45649",
  brightGreen: "#50a14f",
  brightYellow: "#c18401",
  brightBlue: "#4078f2",
  brightMagenta: "#a626a4",
  brightCyan: "#0184bc",
  brightWhite: "#ffffff",
}

// data-settings: {fontSize, theme, colors} – terminal.integrated.fontSize,
// the color theme's base ("dark"/"light") and its terminal colors (xterm's
// theme; null for Bee's own themes, which use the ones here).
const readSettings = el => ({fontSize: 13, theme: "dark", ...JSON.parse(el.dataset.settings || "{}")})
const xtermTheme = s => s.colors || (s.theme === "light" ? LIGHT : DARK)

export const Terminal = {
  mounted() {
    this.id = Number(this.el.dataset.id)
    this.ready = false

    this.settings = readSettings(this.el)
    this.term = new XTerm({
      cursorBlink: true,
      fontSize: this.settings.fontSize,
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace",
      theme: xtermTheme(this.settings),
      scrollback: 5000,
    })
    this.fitAddon = new FitAddon()
    this.term.loadAddon(this.fitAddon)
    this.term.open(this.el)
    this.fit()

    this.handleEvent("term:data", ({id, data}) => {
      if (id === this.id) this.term.write(decode(data))
    })
    this.term.onData(data => this.pushEvent("term_input", {id: this.id, data}))
    // While a sash is dragged the size changes on every mouse move: tell the
    // shell (which redraws on SIGWINCH) only once it settles.
    this.term.onResize(({cols, rows}) => {
      clearTimeout(this.resizeTimer)
      this.resizeTimer = setTimeout(() => {
        if (this.ready) this.pushEvent("term_resize", {id: this.id, cols, rows})
      }, 150)
    })

    // At most one fit per frame.
    this.observer = new ResizeObserver(() => {
      if (this.fitFrame) return
      this.fitFrame = requestAnimationFrame(() => {
        this.fitFrame = null
        this.fit()
      })
    })
    this.observer.observe(this.el)

    this.pushEvent("term_ready", {id: this.id, cols: this.term.cols, rows: this.term.rows}, ({data}) => {
      this.ready = true
      if (data) this.term.write(decode(data))
      this.focusIfActive()
    })
  },

  // Called when data-active or data-settings change (the only attributes
  // LiveView patches here). Focus moves here only when this one becomes
  // the active terminal – not when, say, a color theme is previewed.
  updated() {
    const settings = readSettings(this.el)
    if (JSON.stringify(settings) !== JSON.stringify(this.settings)) {
      this.settings = settings
      this.term.options.fontSize = settings.fontSize
      this.term.options.theme = xtermTheme(settings)
    }
    this.fit()
    if (this.el.dataset.active !== this.wasActive) this.focusIfActive()
  },

  destroyed() {
    clearTimeout(this.resizeTimer)
    cancelAnimationFrame(this.fitFrame)
    this.observer.disconnect()
    this.term.dispose()
  },

  focusIfActive() {
    this.wasActive = this.el.dataset.active
    if (this.wasActive === "true") this.term.focus()
  },

  fit() {
    // Zero-sized while the panel is being laid out; fitting then would collapse to 1x1.
    if (this.el.clientWidth > 0 && this.el.clientHeight > 0) this.fitAddon.fit()
  },
}
