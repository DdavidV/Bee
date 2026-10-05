// The search view's query input: `search:focus` (Find in Files) focuses and
// selects it.
export const SearchInput = {
  mounted() {
    this.handleEvent("search:focus", () => {
      // The view may have just been shown; wait for it to be visible.
      requestAnimationFrame(() => {
        this.el.focus()
        this.el.select()
      })
    })
  },
}
