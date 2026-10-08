// Lists whose items can be dragged to another place, as in VS Code: the
// activity bar's icons, the editor tabs (hooks/tabs.js), the panel's
// section tabs and its terminal list. Down or across, items of any size.
//
// Pressing an item shrinks it a little; holding it (or starting to move)
// lifts it, and it then follows the pointer while the items it passes
// slide out of its way by its size. It passes an item once its leading
// edge crosses that item's middle (its own middle couldn't get past a
// smaller neighbour). On release it settles into its place and the new
// order goes to the server (`event`, `{order: [ids]}`), which renders the
// items in that order. A press that didn't move is an ordinary click.
//
// The movement uses the `translate` and `scale` CSS properties (see
// app.css), which LiveView doesn't render, and they are dropped once the
// server has rendered the new order.
//
// sortable({item, key, event, axis, save, ignore}) makes a hook:
//   item    the items are the children with a data-<item> attribute
//   key     the dataset property with an item's id (default: item)
//   event   the server event for the new order
//   axis    "y" (a column, the default) or "x" (a row)
//   save    also gets the new order (optional; e.g. to remember it)
//   ignore  a selector: pressing such a control in an item isn't a drag

import {saveLayout} from "../layout/storage"

const HOLD_MS = 180
const MOVE_PX = 4
const SETTLE_MS = 150

export const sortable = ({item, key = item, event, axis = "y", save, ignore}) => {
  const [start, end, size, coord] =
    axis === "x" ? ["left", "right", "width", "clientX"] : ["top", "bottom", "height", "clientY"]
  const translate = px => (axis === "x" ? `${px}px 0` : `0 ${px}px`)

  return {
    mounted() {
      this.el.addEventListener("pointerdown", e => this.press(e))
      // A drag ends with a click on the item: it isn't one.
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

    items() {
      return [...this.el.querySelectorAll(`:scope > [data-${item}]`)]
    },

    press(e) {
      const el = e.target.closest(`[data-${item}]`)
      if (e.button !== 0 || !el || el.parentElement !== this.el || this.settling) return
      if (ignore && e.target.closest(ignore)) return

      const items = this.items()
      const from = items.indexOf(el)
      const rects = items.map(i => i.getBoundingClientRect())
      const length = rects[from][size]
      const origin = e[coord]
      let to = from
      let moving = false

      el.dataset.pressed = ""
      const lift = () => {
        el.dataset.lifted = ""
        this.el.dataset.dragging = ""
      }
      const holdTimer = setTimeout(lift, HOLD_MS)

      const middle = i => rects[i][start] + rects[i][size] / 2

      // Where it lands: past each item its leading edge crossed the middle of.
      const target = offset => {
        let index = from
        if (offset > 0) {
          const edge = rects[from][end] + offset
          while (index < items.length - 1 && edge > middle(index + 1)) index++
        } else {
          const edge = rects[from][start] + offset
          while (index > 0 && edge < middle(index - 1)) index--
        }
        return index
      }

      // How far it moves to sit at `index`.
      const settleOffset = index =>
        index > from
          ? rects[index][end] - rects[from][end]
          : index < from
            ? rects[index][start] - rects[from][start]
            : 0

      const move = ev => {
        const delta = ev[coord] - origin
        if (!moving && Math.abs(delta) < MOVE_PX) return
        if (!moving) {
          moving = true
          clearTimeout(holdTimer)
          lift()
          el.setPointerCapture(e.pointerId)
        }

        // It stays within the list.
        const min = rects[0][start] - rects[from][start]
        const max = rects[items.length - 1][end] - rects[from][end]
        const offset = Math.max(min, Math.min(max, delta))
        el.style.translate = translate(offset)
        to = target(offset)

        // Those between its old and new place shift by its size.
        items.forEach((other, i) => {
          if (other === el) return
          const shift =
            from < to && i > from && i <= to ? -length : to < from && i >= to && i < from ? length : 0
          other.style.translate = shift ? translate(shift) : ""
        })
      }

      const release = () => {
        clearTimeout(holdTimer)
        document.removeEventListener("pointermove", move)
        document.removeEventListener("pointerup", release)
        document.removeEventListener("pointercancel", release)
        delete el.dataset.pressed

        if (!moving) {
          delete el.dataset.lifted
          delete this.el.dataset.dragging
          return
        }

        this.dragged = true
        this.settling = true
        // Settle into its place, then let the server put it there for real.
        el.style.translate = translate(settleOffset(to))
        delete el.dataset.lifted

        setTimeout(() => {
          const order = items.map(i => i.dataset[key])
          order.splice(to, 0, ...order.splice(from, 1))
          save?.(order)
          this.pushEvent(event, {order}, () => this.reset())
        }, SETTLE_MS)
      }

      document.addEventListener("pointermove", move)
      document.addEventListener("pointerup", release)
      document.addEventListener("pointercancel", release)
    },

    // The server has rendered the new order: the shifts are no longer
    // needed. No transition, so nothing moves on screen.
    reset() {
      delete this.el.dataset.dragging
      this.items().forEach(i => {
        i.style.transition = "none"
        i.style.translate = ""
      })
      this.el.getBoundingClientRect()
      this.items().forEach(i => (i.style.transition = ""))
      this.settling = false
    },
  }
}

// The activity bar; its order is also remembered per workspace
// (layout/storage.js, sent along when the page connects).
export const ActivityBar = sortable({
  item: "container",
  event: "reorder_activity",
  save: order => saveLayout("activity", order),
})

// The panel's section tabs (remembered like the activity bar's) and its
// terminal list (each entry's kill button isn't a handle).
export const PanelSections = sortable({
  item: "section",
  event: "reorder_panel",
  axis: "x",
  save: order => saveLayout("panelSections", order),
})

export const TerminalList = sortable({item: "term", event: "reorder_terminals", ignore: "[data-kill]"})
