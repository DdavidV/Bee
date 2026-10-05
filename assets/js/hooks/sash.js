// A sash: the handle between two parts of the layout, VS Code style.
// data-part: "sidebar" (drag horizontally: the sidebar's width) or "panel"
// (drag vertically: the panel's height).
//
// While dragging, the size goes into a CSS variable of its own on <html>
// (--drag-sidebar-width / --drag-panel-height), which the layout prefers
// over the one the server renders on #workbench. LiveView never touches
// <html>, so no update can put an old size back mid-drag. On release the
// size goes to the server (`layout_resize`); once it has rendered it, the
// drag variable is dropped. Double-click restores the default (size null). Sizes are kept
// per workspace (layout/storage.js) and sent along when the page connects.
//
// Like VS Code, pulling well past the minimum (below half of it) collapses
// the part while dragging; releasing there hides it (`layout_hide`) and
// keeps its previous size for when it is shown again.

import {saveLayout as save} from "../layout/storage"

const DRAG_VARS = {sidebar: "--drag-sidebar-width", panel: "--drag-panel-height"}
// Bee.Workbench.resize/3 clamps the same way; the editor keeps some room.
const MIN = {sidebar: 170, panel: 80}
const max = part =>
  part === "sidebar" ? Math.min(800, window.innerWidth - 300) : Math.min(1200, window.innerHeight - 150)

export const Sash = {
  mounted() {
    this.part = this.el.dataset.part

    this.el.addEventListener("pointerdown", e => this.start(e))
    this.el.addEventListener("dblclick", () => {
      save(this.part, null)
      this.pushEvent("layout_resize", {part: this.part, size: null})
    })
  },

  // The part may go away (hidden by a drag) before the server answers.
  destroyed() {
    this.clearDrag()
  },

  setDrag(value) {
    document.documentElement.style.setProperty(DRAG_VARS[this.part], value)
  },

  clearDrag() {
    document.documentElement.style.removeProperty(DRAG_VARS[this.part])
  },

  start(e) {
    if (e.button !== 0) return
    e.preventDefault()
    const part = this.part
    const target = document.getElementById(part === "sidebar" ? "sidebar" : "panel").getBoundingClientRect()
    // The sidebar grows from its left edge, the panel from its bottom edge.
    const measure = ev => (part === "sidebar" ? ev.clientX - target.left : target.bottom - ev.clientY)
    // Where on the sash it was grabbed, so the size doesn't jump on the first move.
    const offset = (part === "sidebar" ? target.width : target.height) - measure(e)

    let size = null
    let hide = false
    const move = ev => {
      const raw = measure(ev) + offset
      hide = raw < MIN[part] / 2
      size = Math.min(max(part), Math.max(MIN[part], Math.round(raw)))
      this.setDrag(hide ? "0px" : `${size}px`)
    }
    const stop = () => {
      this.el.releasePointerCapture(e.pointerId)
      this.el.removeEventListener("pointermove", move)
      this.el.removeEventListener("pointerup", stop)
      this.el.removeEventListener("pointercancel", stop)
      delete this.el.dataset.dragging
      document.body.style.cursor = ""
      document.body.classList.remove("select-none")

      // Keep showing the dragged size until the server has rendered it.
      if (hide) {
        this.pushEvent("layout_hide", {part}, () => this.clearDrag())
      } else if (size != null) {
        save(part, size)
        this.pushEvent("layout_resize", {part, size}, () => this.clearDrag())
      }
    }

    this.el.setPointerCapture(e.pointerId)
    this.el.dataset.dragging = ""
    document.body.style.cursor = part === "sidebar" ? "col-resize" : "row-resize"
    document.body.classList.add("select-none")
    this.el.addEventListener("pointermove", move)
    this.el.addEventListener("pointerup", stop)
    this.el.addEventListener("pointercancel", stop)
  },
}

// The sash between two open views of the sidebar (Source Control's
// Changes and Commits, say): dragging moves the border between this view
// and the nearest open one above it.
//
// Each view's `flex-grow` is the height of its body, rendered by the
// server as `var(--pane-…, size)`. During a drag the bodies' heights go
// into those variables on <html> (out of LiveView's reach, as above); on
// release they go to the server (`view_resize`) and the variables are
// dropped once it has rendered them. Double-click shares the height evenly.
const PANE_MIN = 40

export const PaneSash = {
  mounted() {
    this.el.addEventListener("pointerdown", e => this.start(e))
    this.el.addEventListener("dblclick", () => {
      const views = this.panes().map(p => p.dataset.pane)
      this.pushEvent("view_resize", {reset: views})
    })
  },

  // The sash may go away (its view folded) before the server answers.
  destroyed() {
    this.clear?.()
  },

  panes() {
    return [...this.el.closest("#sidebar").querySelectorAll(":scope > [data-pane]")]
  },

  // The height of a pane's body: the pane without its header.
  body(pane) {
    return pane.lastElementChild.getBoundingClientRect().height
  },

  start(e) {
    if (e.button !== 0) return
    e.preventDefault()
    const open = this.panes().filter(p => p.dataset.open === "true")
    const below = this.el.closest("[data-pane]")
    const above = open[open.indexOf(below) - 1]
    if (!above) return

    const root = document.documentElement
    const sizes = new Map(open.map(p => [p, this.body(p)]))
    const set = () => sizes.forEach((size, p) => root.style.setProperty(p.dataset.var, size))
    const clear = (this.clear = () => {
      open.forEach(p => root.style.removeProperty(p.dataset.var))
      delete root.dataset.paneDrag
    })
    const total = sizes.get(above) + sizes.get(below)
    const startAbove = sizes.get(above)
    const startY = e.clientY

    root.dataset.paneDrag = ""
    set()

    const move = ev => {
      const size = Math.min(total - PANE_MIN, Math.max(PANE_MIN, startAbove + ev.clientY - startY))
      sizes.set(above, Math.round(size))
      sizes.set(below, Math.round(total - size))
      set()
    }
    const stop = () => {
      this.el.releasePointerCapture(e.pointerId)
      this.el.removeEventListener("pointermove", move)
      this.el.removeEventListener("pointerup", stop)
      this.el.removeEventListener("pointercancel", stop)
      delete this.el.dataset.dragging
      document.body.style.cursor = ""
      document.body.classList.remove("select-none")

      const payload = Object.fromEntries([...sizes].map(([p, size]) => [p.dataset.pane, size]))
      this.pushEvent("view_resize", {sizes: payload}, clear)
    }

    this.el.setPointerCapture(e.pointerId)
    this.el.dataset.dragging = ""
    document.body.style.cursor = "row-resize"
    document.body.classList.add("select-none")
    this.el.addEventListener("pointermove", move)
    this.el.addEventListener("pointerup", stop)
    this.el.addEventListener("pointercancel", stop)
  },
}
