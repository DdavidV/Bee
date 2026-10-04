// The input box of a plugin view (e.g. a commit message): Ctrl/Cmd+Enter
// submits its form. The server can set its value (`view:input`), also while
// it has focus (LiveView leaves focused inputs alone).

export const ViewInput = {
  mounted() {
    this.el.addEventListener("keydown", e => {
      if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
        e.preventDefault()
        this.el.form.requestSubmit()
      }
    })
    this.handleEvent("view:input", ({view, value}) => {
      if (this.el.form.querySelector("input[name=view]")?.value === view) this.el.value = value
    })
  },
}
