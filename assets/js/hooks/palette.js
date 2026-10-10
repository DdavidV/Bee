// Command palette (Quick Open) focus handling: focus the input on open, keep
// the selected item scrolled into view, set the query when Bee does, and
// give focus back to whatever had it on close.

export const Palette = {
  mounted() {
    this.previous = document.activeElement
    // The cursor after what it opens with (">" for commands): typing adds
    // to it, as in VS Code.
    const input = this.el.querySelector("input")
    if (input) {
      input.focus()
      input.setSelectionRange(input.value.length, input.value.length)
    }
    // Bee sets the query (Quick Open's ">" for commands): LiveView leaves a
    // focused input's value alone, so it is set here.
    this.handleEvent("palette:query", ({query}) => {
      const input = this.el.querySelector("input")
      if (!input) return
      input.value = query
      input.focus()
      input.setSelectionRange(query.length, query.length)
    })
  },

  updated() {
    this.el.querySelector("[aria-selected=true]")?.scrollIntoView({block: "nearest"})
  },

  destroyed() {
    if (this.previous && document.contains(this.previous)) this.previous.focus()
  },
}
