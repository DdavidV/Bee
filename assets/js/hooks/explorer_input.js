// The Explorer's name input (new file / folder, rename; see FileTree):
// focused with the name selected (without its extension when renaming a
// file, as in VS Code). Enter submits; Escape cancels; leaving it submits
// what was typed, or cancels when nothing was.

export const ExplorerInput = {
  mounted() {
    this.el.focus()
    this.el.setSelectionRange(0, Number(this.el.dataset.select || 0))

    this.el.addEventListener("keydown", e => {
      if (e.key === "Escape") {
        e.preventDefault()
        e.stopPropagation()
        this.cancel()
      }
    })

    this.el.addEventListener("blur", () => {
      // Gone (done or cancelled): nothing left to submit.
      if (this.cancelled || !this.el.isConnected) return
      if (this.el.value.trim() === "" || this.el.value === this.el.defaultValue) this.cancel()
      else this.el.form.requestSubmit()
    })
  },

  destroyed() {
    this.cancelled = true
  },

  cancel() {
    this.cancelled = true
    this.pushEventTo(this.el, "edit_cancel", {})
  },
}
