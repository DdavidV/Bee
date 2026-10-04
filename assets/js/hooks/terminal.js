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

const THEME = {
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

export const Terminal = {
  mounted() {
    this.id = Number(this.el.dataset.id)
    this.ready = false

    this.term = new XTerm({
      cursorBlink: true,
      fontSize: 13,
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace",
      theme: THEME,
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
    this.term.onResize(({cols, rows}) => {
      if (this.ready) this.pushEvent("term_resize", {id: this.id, cols, rows})
    })

    this.observer = new ResizeObserver(() => this.fit())
    this.observer.observe(this.el)

    this.pushEvent("term_ready", {id: this.id, cols: this.term.cols, rows: this.term.rows}, ({data}) => {
      this.ready = true
      if (data) this.term.write(decode(data))
      this.focusIfActive()
    })
  },

  // Called when data-active changes (the only attributes LiveView patches here).
  updated() {
    this.fit()
    this.focusIfActive()
  },

  destroyed() {
    this.observer.disconnect()
    this.term.dispose()
  },

  focusIfActive() {
    if (this.el.dataset.active === "true") this.term.focus()
  },

  fit() {
    // Zero-sized while the panel is being laid out; fitting then would collapse to 1x1.
    if (this.el.clientWidth > 0 && this.el.clientHeight > 0) this.fitAddon.fit()
  },
}
