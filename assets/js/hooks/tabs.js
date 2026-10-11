// An editor group's tabs: dragged to another place, as in VS Code (sideways,
// tabs of different widths: hooks/sortable.js; the new order goes to the
// server as `reorder_tabs`) – or to another group: onto its tabs (there),
// onto its editor (after its tabs), or onto the right or bottom part of an
// editor, which splits it (`move_tab`). Closed with a middle click, which
// runs workbench.action.closeEditor for the tab (it asks first when the tab
// has unsaved changes). Pressing a tab's × isn't a drag.
//
// Also the client side of copyFilePath (Copy Path): the tab's path, or the
// active one's, to the clipboard.

import {registerCommand} from "../commands/registry"
import {sortable} from "./sortable"

const groupOf = el => Number(el.closest("[data-group]").dataset.group)

// Where a tab dragged out of its row would land: {to, zone, index, area}
// – a group, "center" (among its tabs, at `index` or last), "right" or
// "down" (a new group there); `area`: the editor it is over. null: nowhere
// else (its own row).
const landing = (hook, ev) => {
  const under = document.elementFromPoint(ev.clientX, ev.clientY)
  const group = under?.closest("section[data-group]")
  if (!group) return null
  const from = groupOf(hook.el)
  const to = Number(group.dataset.group)

  const area = under.closest("[data-editor-area]")
  if (area) {
    const box = area.getBoundingClientRect()
    const zone =
      ev.clientX > box.left + box.width * 0.67 ? "right" : ev.clientY > box.top + box.height * 0.67 ? "down" : "center"
    // (Its own editor's middle: it stays.)
    if (to === from && zone === "center") return {stay: true}
    return {to, zone, index: null, area}
  }

  const bar = under.closest("[data-tabs]")
  if (!bar || to === from) return null
  const tabs = [...bar.querySelectorAll(":scope > [data-tab]")]
  const index = tabs.findIndex(tab => {
    const box = tab.getBoundingClientRect()
    return ev.clientX < box.left + box.width / 2
  })
  return {to, zone: "center", index: index < 0 ? tabs.length : index, area: group.querySelector("[data-editor-area]")}
}

// Shows where it would land (app.css: [data-drop]).
const mark = target => {
  document.querySelectorAll("[data-drop]").forEach(el => el !== target?.area && delete el.dataset.drop)
  if (target?.area) target.area.dataset.drop = target.zone
}

const row = sortable({
  item: "tab",
  key: "path",
  event: "reorder_tabs",
  axis: "x",
  ignore: "[data-close]",
  params: hook => ({group: groupOf(hook.el)}),
  over: (hook, ev) => mark(landing(hook, ev)),
  drop: (hook, ev, el) => {
    const target = landing(hook, ev)
    mark(null)
    if (!target) return false
    if (!target.stay) {
      hook.pushEvent("move_tab", {
        path: el.dataset.path,
        from: groupOf(hook.el),
        to: target.to,
        zone: target.zone,
        index: target.index,
      })
    }
    return true
  },
})

export const Tabs = {
  ...row,

  mounted() {
    row.mounted.call(this)

    // (Every group's tabs register it: the same, whichever is asked.)
    this.unregister = registerCommand("copyFilePath", path =>
      copy(path || document.querySelector("section[data-focused=true] [data-tab][data-active=true]")?.dataset.path),
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
        args: JSON.stringify([tab.dataset.path, groupOf(this.el)]),
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
