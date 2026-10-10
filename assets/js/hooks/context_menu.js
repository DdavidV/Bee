// Right-click menus, data-driven: an element names its menu and what the
// menu's commands get –
//
//   data-menu="explorer/context"
//   data-menu-args='["/abs/path"]'          the commands' arguments (JSON)
//   data-menu-context='{"explorerResourceIsFolder": true}'   `when` keys
//
// The editor's menu ("editor/context") also gets the editor's own keys
// (its selection…). With Shift held, the browser's menu shows instead.
//
// ContextMenus (once per page) catches right-clicks on such elements (the
// innermost one wins) and asks the server to open the menu there
// (`open_context_menu`); the server renders it (BeeWeb.Workbench.ContextMenu)
// from the contributed menu entries. Elsewhere the browser's own menu shows.

import {editorContext} from "../editor/active"

const json = (value, fallback) => {
  try {
    return value ? JSON.parse(value) : fallback
  } catch (_e) {
    return fallback
  }
}

export const ContextMenus = {
  mounted() {
    this.onContextMenu = e => {
      const target = e.target.closest("[data-menu]")
      if (!target || e.target.closest("#context-menu") || e.shiftKey) return
      e.preventDefault()
      const menu = target.dataset.menu
      const context = json(target.dataset.menuContext, {})
      if (menu === "editor/context") Object.assign(context, editorContext(), {editorFocus: true, editorTextFocus: true})
      this.pushEvent("open_context_menu", {
        menu,
        x: e.clientX,
        y: e.clientY,
        args: json(target.dataset.menuArgs, []),
        context,
      })
    }
    document.addEventListener("contextmenu", this.onContextMenu)
  },

  destroyed() {
    document.removeEventListener("contextmenu", this.onContextMenu)
  },
}

// The open menu: kept inside the window (opened near the right or bottom
// edge it goes left of / above the pointer).
export const ContextMenu = {
  mounted() {
    this.place()
  },

  updated() {
    this.place()
  },

  place() {
    const rect = this.el.getBoundingClientRect()
    if (rect.right > window.innerWidth - 4) this.el.style.left = `${Math.max(4, rect.left - rect.width)}px`
    if (rect.bottom > window.innerHeight - 4) this.el.style.top = `${Math.max(4, window.innerHeight - rect.height - 4)}px`
    // Submenus open to the right of their item, or to its left when there
    // is no room (measured while hidden: shown for a moment, unseen).
    for (const item of this.el.querySelectorAll("[data-submenu]")) {
      const sub = item.lastElementChild
      sub.style.cssText = "display: block; visibility: hidden"
      const edge = item.getBoundingClientRect().right + sub.getBoundingClientRect().width
      sub.style.cssText = edge > window.innerWidth - 4 ? "left: auto; right: 100%" : ""
    }
  },
}
