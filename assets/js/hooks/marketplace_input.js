// The Plugins view's Open VSX search box: `marketplace:focus` (Search Open
// VSX) focuses and selects it; Escape clears it, showing the installed
// plugins again.
export const MarketplaceInput = {
  mounted() {
    this.handleEvent("marketplace:focus", () => {
      // The view may have just been shown; wait for it to be visible.
      requestAnimationFrame(() => {
        this.el.focus()
        this.el.select()
      })
    })
    this.el.addEventListener("keydown", e => {
      if (e.key !== "Escape" || this.el.value === "") return
      e.preventDefault()
      e.stopPropagation()
      this.el.value = ""
      this.pushEvent("marketplace_search", {query: ""})
    })
  },
}
