// The editor tabs: dragged to another place, as in VS Code (like the
// activity bar's icons, hooks/activity_bar.js, but sideways and with tabs
// of different widths), and closed with a middle click.
//
// Pressing a tab shrinks it a little; holding it (or starting to move)
// lifts it, and it follows the pointer while the tabs it passes slide out
// of its way by its width. On release it settles into its place and the
// new order goes to the server (`reorder_tabs`), which renders the tabs in
// it. A press that didn't move is an ordinary click (activating the tab).
//
// A middle click runs workbench.action.closeEditor for the tab, which asks
// first when it has unsaved changes.
//
// Also the client side of copyFilePath (Copy Path): the tab's path, or the
// active one's, to the clipboard.

import {registerCommand} from "../commands/registry"

const HOLD_MS = 180
const MOVE_PX = 4
const SETTLE_MS = 150

export const Tabs = {
  mounted() {
    this.unregister = registerCommand("copyFilePath", path =>
      copy(path || this.el.querySelector("[data-tab][data-active=true]")?.dataset.path),
    )
    this.el.addEventListener("pointerdown", e => this.press(e))
    // A drag ends with a click on the tab: it isn't one.
    this.el.addEventListener(
      "click",
      e => {
        if (this.dragged) {
          e.stopPropagation()
          e.preventDefault()
          this.dragged = false
        }
      },
      true,
    )
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

  tabs() {
    return [...this.el.querySelectorAll(":scope > [data-tab]")]
  },

  press(e) {
    const tab = e.target.closest("[data-tab]")
    // No autoscroll on a middle press: it closes the tab.
    if (e.button === 1 && tab) e.preventDefault()
    if (e.button !== 0 || !tab || e.target.closest("[data-close]") || this.settling) return

    const tabs = this.tabs()
    const from = tabs.indexOf(tab)
    const rects = tabs.map(t => t.getBoundingClientRect())
    const width = rects[from].width
    const startX = e.clientX
    let to = from
    let moving = false

    tab.dataset.pressed = ""
    const lift = () => {
      tab.dataset.lifted = ""
      this.el.dataset.dragging = ""
    }
    const holdTimer = setTimeout(lift, HOLD_MS)

    // Where the dragged tab lands: past each tab its leading edge has
    // crossed the middle of. (Not its own middle: a wide tab can only move
    // as far as a narrow neighbour is wide, never past the middle of it.)
    const middle = i => rects[i].left + rects[i].width / 2
    const target = offset => {
      let index = from
      if (offset > 0) {
        const edge = rects[from].right + offset
        while (index < tabs.length - 1 && edge > middle(index + 1)) index++
      } else {
        const edge = rects[from].left + offset
        while (index > 0 && edge < middle(index - 1)) index--
      }
      return index
    }

    // How far it moves to sit at `index`.
    const settleOffset = index =>
      index > from ? rects[index].right - rects[from].right : index < from ? rects[index].left - rects[from].left : 0

    const move = ev => {
      const dx = ev.clientX - startX
      if (!moving && Math.abs(dx) < MOVE_PX) return
      if (!moving) {
        moving = true
        clearTimeout(holdTimer)
        lift()
        tab.setPointerCapture(e.pointerId)
      }

      // It stays within the tabs.
      const min = rects[0].left - rects[from].left
      const max = rects[tabs.length - 1].right - rects[from].right
      const offset = Math.max(min, Math.min(max, dx))
      tab.style.translate = `${offset}px 0`
      to = target(offset)

      // Those between its old and new place shift by its width.
      tabs.forEach((other, i) => {
        if (other === tab) return
        const shift = from < to && i > from && i <= to ? -width : to < from && i >= to && i < from ? width : 0
        other.style.translate = shift ? `${shift}px 0` : ""
      })
    }

    const release = () => {
      clearTimeout(holdTimer)
      document.removeEventListener("pointermove", move)
      document.removeEventListener("pointerup", release)
      document.removeEventListener("pointercancel", release)
      delete tab.dataset.pressed

      if (!moving) {
        delete tab.dataset.lifted
        delete this.el.dataset.dragging
        return
      }

      this.dragged = true
      this.settling = true
      // Settle into its place, then let the server put it there for real.
      tab.style.translate = `${settleOffset(to)}px 0`
      delete tab.dataset.lifted

      setTimeout(() => {
        const order = tabs.map(t => t.dataset.path)
        order.splice(to, 0, ...order.splice(from, 1))
        this.pushEvent("reorder_tabs", {order}, () => this.reset())
      }, SETTLE_MS)
    }

    document.addEventListener("pointermove", move)
    document.addEventListener("pointerup", release)
    document.addEventListener("pointercancel", release)
  },

  // The server has rendered the new order: the shifts are no longer needed.
  // No transition, so nothing moves on screen.
  reset() {
    delete this.el.dataset.dragging
    this.tabs().forEach(t => {
      t.style.transition = "none"
      t.style.translate = ""
    })
    this.el.getBoundingClientRect()
    this.tabs().forEach(t => (t.style.transition = ""))
    this.settling = false
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
