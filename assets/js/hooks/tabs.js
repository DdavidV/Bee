// The editor tabs: dragged to another place, as in VS Code (sideways, tabs
// of different widths: hooks/sortable.js; the new order goes to the server
// as `reorder_tabs`), and closed with a middle click, which runs
// workbench.action.closeEditor for the tab (it asks first when the tab has
// unsaved changes). Pressing a tab's × isn't a drag.
//
// Also the client side of copyFilePath (Copy Path): the tab's path, or the
// active one's, to the clipboard.

import {registerCommand} from "../commands/registry"
import {sortable} from "./sortable"

const row = sortable({item: "tab", key: "path", event: "reorder_tabs", axis: "x", ignore: "[data-close]"})

export const Tabs = {
  ...row,

  mounted() {
    row.mounted.call(this)

    this.unregister = registerCommand("copyFilePath", path =>
      copy(path || this.el.querySelector("[data-tab][data-active=true]")?.dataset.path),
    )

    // No autoscroll on a middle press: it closes the tab.
    this.el.addEventListener("pointerdown", e => {
      if (e.button === 1 && e.target.closest("[data-tab]")) e.preventDefault()
    })
    this.el.addEventListener("auxclick", e => {
      const tab = e.target.closest("[data-tab]")
      if (e.button !== 1 || !tab) return
      e.preventDefault()
      this.pushEvent("run_command", {
        command: "workbench.action.closeEditor",
        args: JSON.stringify([tab.dataset.path]),
      })
    })
  },

  destroyed() {
    this.unregister()
  },
}

// Text to the clipboard: through the desktop app's shell when there is one
// (its webview lets pages write the clipboard only in some cases), else
// execCommand – which works where the Clipboard API isn't offered, as long
// as it runs in a click – then the Clipboard API.
const copy = text => {
  if (!text) return
  if (window.__bridge?.copyText) return window.__bridge.copyText(text).catch(e => console.warn("Bee: can't copy:", e))

  const area = document.createElement("textarea")
  area.value = text
  area.style.position = "fixed"
  area.style.opacity = "0"
  document.body.appendChild(area)
  area.select()
  const copied = document.execCommand("copy")
  area.remove()
  if (!copied) navigator.clipboard?.writeText(text).catch(e => console.warn("Bee: can't copy:", e))
}
