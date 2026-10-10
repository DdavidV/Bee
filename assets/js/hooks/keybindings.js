// Keyboard dispatcher, mounted on #workbench.
//
// data-keybindings: resolved bindings from Bee.Commands.Keybindings
//   [{key: ["ctrl+k", "ctrl+s"], mac: [...], linux: [...], win: [...], command,
//     when: <Bee.Commands.When AST>, args: [...]}]
//   the strokes per platform (key: any other), null where the binding doesn't exist
// data-context: the server half of the `when` context (Bee.Workbench.context/2);
//   focus-related keys are added here.
//
// Matching follows VS Code: the last binding whose keys match and whose
// `when` holds wins; a stroke that starts a chord waits for the next one.
// Client commands (`client: true`, with their `enablement` AST) run right
// here; the others go through the server (`run_command`), which checks
// enablement and runs them.
// Listens in the capture phase so it sees keys before CodeMirror and xterm.

import {strokeFromEvent, label, isMac} from "../commands/keys"
import {evaluate} from "../commands/when"
import {exec} from "../commands/registry"
import {editorContext} from "../editor/active"

const startsWith = (strokes, prefix) => prefix.every((s, i) => strokes[i] === s)

export const Keybindings = {
  mounted() {
    this.pending = null
    this.load()
    this.handleEvent("bee:exec", ({command, args}) => exec(command, args || []))
    this.onKeydown = e => this.keydown(e)
    window.addEventListener("keydown", this.onKeydown, true)
  },

  updated() {
    this.load()
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeydown, true)
  },

  load() {
    const platform = isMac ? "mac" : navigator.platform.startsWith("Win") ? "win" : navigator.platform.includes("Linux") ? "linux" : "key"
    this.bindings = JSON.parse(this.el.dataset.keybindings || "[]")
      .map(b => ({...b, strokes: b[platform]}))
      .filter(b => b.strokes)
    this.serverContext = JSON.parse(this.el.dataset.context || "{}")
  },

  context() {
    const el = document.activeElement
    const inEditor = !!el?.closest?.("#editor .cm-editor")
    const inTerminal = !!el?.closest?.(".xterm")
    const textInput = !!el && (el.isContentEditable || el.tagName === "INPUT" || el.tagName === "TEXTAREA")
    const platform = navigator.platform
    return {
      ...this.serverContext,
      ...editorContext(),
      editorFocus: inEditor,
      editorTextFocus: inEditor,
      terminalFocus: inTerminal,
      searchViewletFocus: !!el?.closest?.("#search-view"),
      textInputFocus: textInput,
      inputFocus: textInput,
      isMac,
      isLinux: platform.includes("Linux"),
      isWindows: platform.startsWith("Win"),
      isWeb: true,
    }
  },

  keydown(e) {
    const stroke = strokeFromEvent(e)
    if (!stroke) return

    const seq = this.pending ? [...this.pending, stroke] : [stroke]
    const ctx = this.context()
    const candidates = this.bindings.filter(b => startsWith(b.strokes, seq) && evaluate(b.when, ctx))

    // A longer chord starting with these strokes takes precedence, as in VS Code.
    if (candidates.some(b => b.strokes.length > seq.length)) {
      this.stop(e)
      this.pending = seq
      this.status(`(${seq.map(label).join(" ")}) was pressed. Waiting for second key of chord...`)
      return
    }

    const wasChord = this.pending !== null
    this.pending = null
    const match = candidates.findLast(b => b.strokes.length === seq.length)

    if (match) {
      this.stop(e)
      this.status("")
      if (match.client) {
        if (evaluate(match.enablement, ctx)) exec(match.command, match.args || [])
      } else {
        // The server should see the latest text and selection first.
        window.dispatchEvent(new Event("bee:flush"))
        this.pushEvent("run_command", match.args ? {command: match.command, args: match.args} : {command: match.command})
      }
    } else if (wasChord) {
      this.stop(e)
      this.status(`The key combination (${seq.map(label).join(" ")}) is not a command.`, 3000)
    }
  },

  stop(e) {
    e.preventDefault()
    e.stopPropagation()
  },

  status(text, clearAfter) {
    const el = document.getElementById("keybinding-status")
    if (!el) return
    clearTimeout(this.statusTimer)
    el.textContent = text
    if (clearAfter) this.statusTimer = setTimeout(() => (el.textContent = ""), clearAfter)
  },
}
