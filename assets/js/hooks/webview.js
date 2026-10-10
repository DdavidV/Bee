// A webview panel of a VS Code extension (BeeWeb.Workbench.Webview): the
// link between its frame – the extension's page, sandboxed, of another
// origin – and the window. Bee's part of the page
// (BeeWeb.WebviewController) posts {__bee: type, data} to us:
//
//   message  for the extension (acquireVsCodeApi().postMessage) → webview_message
//   state    what the page keeps (setState)                     → webview_state
//   open     a link to the web: the user's browser
//   key      a key pressed in the page: Bee's keybindings see it
//
// The extension's messages (webview:message) are posted into the frame,
// once its page has loaded: until then they wait.
//
// data-webview  the panel's id

import {openExternal} from "../external"

export const Webview = {
  mounted() {
    this.id = this.el.dataset.webview
    this.waiting = []
    this.bind()
    this.onMessage = event => {
      const frame = this.frame
      if (!frame || event.source !== frame.contentWindow || !event.data || typeof event.data.__bee !== "string") return
      const {__bee: type, data} = event.data
      if (type === "message") this.pushEvent("webview_message", {id: this.id, message: data ?? null})
      else if (type === "state") this.pushEvent("webview_state", {id: this.id, state: data ?? null})
      else if (type === "open" && typeof data === "string") openExternal(data)
      else if (type === "key" && data) this.el.dispatchEvent(new KeyboardEvent("keydown", {...data, bubbles: true, cancelable: true}))
    }
    window.addEventListener("message", this.onMessage)
    this.handleEvent("webview:message", ({id, message}) => {
      if (id !== this.id) return
      if (this.loaded) this.post(message)
      else this.waiting.push(message)
    })
  },

  // The page was loaded afresh (new HTML): a new frame.
  updated() {
    this.bind()
  },

  destroyed() {
    window.removeEventListener("message", this.onMessage)
  },

  bind() {
    const frame = this.el.querySelector("iframe")
    if (frame === this.frame) return
    this.frame = frame
    this.loaded = false
    frame?.addEventListener("load", () => {
      if (frame !== this.frame) return
      this.loaded = true
      this.waiting.splice(0).forEach(message => this.post(message))
    })
  },

  post(message) {
    this.frame?.contentWindow?.postMessage({__bee: "message", data: message}, "*")
  },
}
