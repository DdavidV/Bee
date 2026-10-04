// Workbench-wide shortcuts, mounted on #workbench.
//
// Listens in the capture phase so shortcuts work while focus is inside
// CodeMirror or xterm (which would otherwise consume the key).

const BINDINGS = [
  // Ctrl/Cmd+B. Like VS Code, this wins over the terminal (so ^B never reaches the shell).
  {match: e => (e.ctrlKey || e.metaKey) && !e.shiftKey && !e.altKey && e.code === "KeyB", event: "toggle_sidebar"},
  // Ctrl/Cmd+J, as in VS Code (also overrides the browser's Downloads shortcut; ^J never reaches the shell).
  {match: e => (e.ctrlKey || e.metaKey) && !e.shiftKey && !e.altKey && e.code === "KeyJ", event: "toggle_panel"},]

export const Keybindings = {
  mounted() {
    this.onKeydown = e => {
      const binding = BINDINGS.find(b => b.match(e))
      if (!binding) return
      e.preventDefault()
      e.stopPropagation()
      this.pushEvent(binding.event, {})
    }
    window.addEventListener("keydown", this.onKeydown, true)
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeydown, true)
  },
}
