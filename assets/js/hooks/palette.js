// Command palette focus handling: focus the input on open, keep the selected
// item scrolled into view, and give focus back to whatever had it on close.

export const Palette = {
  mounted() {
    this.previous = document.activeElement
    this.el.querySelector("input")?.focus()
  },

  updated() {
    this.el.querySelector("[aria-selected=true]")?.scrollIntoView({block: "nearest"})
  },

  destroyed() {
    if (this.previous && document.contains(this.previous)) this.previous.focus()
  },
}
