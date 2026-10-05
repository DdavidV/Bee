// The activity bar: its icons can be dragged to another place, as in VS Code.
//
// Pressing an icon shrinks it a little; holding it (or starting to move)
// lifts it, and it then follows the pointer while the other icons slide
// out of its way. On release it settles into its slot, the new order is
// remembered per workspace (layout/storage.js, sent along when the page
// connects) and goes to the server (`reorder_activity`), which renders the
// icons in that order. A press that didn't move is an ordinary click.
//
// The movement uses the `translate` and `scale` CSS properties (see
// app.css), which LiveView doesn't render, and they are dropped once the
// server has rendered the new order.

import {saveLayout} from "../layout/storage"

const HOLD_MS = 180
const MOVE_PX = 4
const SETTLE_MS = 150

export const ActivityBar = {
  mounted() {
    this.el.addEventListener("pointerdown", e => this.press(e))
    // A drag ends with a click on the icon: it isn't one.
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
  },

  icons() {
    return [...this.el.querySelectorAll(":scope > [data-container]")]
  },

  press(e) {
    const icon = e.target.closest("[data-container]")
    if (e.button !== 0 || !icon || this.settling) return

    const icons = this.icons()
    const from = icons.indexOf(icon)
    const tops = icons.map(i => i.getBoundingClientRect().top)
    // Distance between two icons (height + gap).
    const slot = icons.length > 1 ? tops[1] - tops[0] : icon.getBoundingClientRect().height
    const startY = e.clientY
    let to = from
    let moving = false

    icon.dataset.pressed = ""
    const lift = () => {
      icon.dataset.lifted = ""
      this.el.dataset.dragging = ""
    }
    const holdTimer = setTimeout(lift, HOLD_MS)

    const move = ev => {
      const dy = ev.clientY - startY
      if (!moving && Math.abs(dy) < MOVE_PX) return
      if (!moving) {
        moving = true
        clearTimeout(holdTimer)
        lift()
        icon.setPointerCapture(e.pointerId)
      }

      // The dragged icon stays within the bar.
      const offset = Math.max(-from * slot, Math.min((icons.length - 1 - from) * slot, dy))
      icon.style.translate = `0 ${offset}px`
      to = Math.round(from + offset / slot)

      // Those between its old and new place shift by one slot.
      icons.forEach((other, i) => {
        if (other === icon) return
        const shift = from < to && i > from && i <= to ? -slot : to < from && i >= to && i < from ? slot : 0
        other.style.translate = shift ? `0 ${shift}px` : ""
      })
    }

    const release = () => {
      clearTimeout(holdTimer)
      document.removeEventListener("pointermove", move)
      document.removeEventListener("pointerup", release)
      document.removeEventListener("pointercancel", release)
      delete icon.dataset.pressed

      if (!moving) {
        delete icon.dataset.lifted
        delete this.el.dataset.dragging
        return
      }

      this.dragged = true
      this.settling = true
      // Settle into the slot, then let the server put it there for real.
      icon.style.translate = `0 ${(to - from) * slot}px`
      delete icon.dataset.lifted

      setTimeout(() => {
        const order = icons.map(i => i.dataset.container)
        order.splice(to, 0, ...order.splice(from, 1))
        saveLayout("activity", order)
        this.pushEvent("reorder_activity", {order}, () => this.reset())
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
    this.icons().forEach(i => {
      i.style.transition = "none"
      i.style.translate = ""
    })
    this.el.getBoundingClientRect()
    this.icons().forEach(i => (i.style.transition = ""))
    this.settling = false
  },
}
