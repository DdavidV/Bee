// CodeMirror editor for EditorLive.
//
// One EditorView is shared by all tabs; each open file keeps its own
// EditorState (document, selection, undo history) in `this.states`, and
// switching tabs swaps the state into the view.
//
// Settings arrive in data-settings (editor.* and workbench.colorTheme) and
// are applied through compartments to the active and all inactive states.
//
// Highlighting: the server sends each file's language and the name of the
// mode for it (editor/modes.js); a mode registered later by a plugin is
// applied to the files waiting for it.
//
// Server -> client: cm:open, cm:activate, cm:close, cm:reload, cm:language,
//                   cm:edit (server-side edits, UTF-8 byte offsets)
// Client -> server: doc_changed (throttled), save, selection_changed
//                   (throttled, UTF-8 byte offsets; for plugin commands)
// Client command:   workbench.action.files.save
//
// A `bee:flush` window event sends pending changes and selections at once
// (the Keybindings hook fires it before running a command).

import {EditorState, Compartment} from "@codemirror/state"
import {
  EditorView, keymap, lineNumbers, highlightActiveLineGutter, highlightSpecialChars,
  drawSelection, dropCursor, rectangularSelection, crosshairCursor, highlightActiveLine,
} from "@codemirror/view"
import {history, defaultKeymap, historyKeymap, indentWithTab} from "@codemirror/commands"
import {
  indentUnit, foldGutter, indentOnInput, syntaxHighlighting,
  defaultHighlightStyle, bracketMatching, foldKeymap,
} from "@codemirror/language"
import {highlightSelectionMatches, searchKeymap} from "@codemirror/search"
import {closeBrackets, autocompletion, closeBracketsKeymap, completionKeymap} from "@codemirror/autocomplete"
import {lintKeymap} from "@codemirror/lint"
import {oneDark} from "@codemirror/theme-one-dark"
import {registerCommand} from "../commands/registry"
import {modeExtension, onModeChange} from "../editor/modes"
import "../editor/builtin_modes"
import {toBytes, fromBytes} from "../editor/offsets"
import {setEditor} from "../editor/active"

const SYNC_MS = 300
const SELECTION_MS = 100

// CodeMirror's basicSetup, minus lineNumbers (a setting, see below).
const setup = [
  highlightSpecialChars(),
  history(),
  foldGutter(),
  drawSelection(),
  dropCursor(),
  EditorState.allowMultipleSelections.of(true),
  indentOnInput(),
  syntaxHighlighting(defaultHighlightStyle, {fallback: true}),
  bracketMatching(),
  closeBrackets(),
  autocompletion(),
  rectangularSelection(),
  crosshairCursor(),
  highlightActiveLine(),
  highlightSelectionMatches(),
  keymap.of([
    ...closeBracketsKeymap, ...defaultKeymap, ...searchKeymap, ...historyKeymap,
    ...foldKeymap, ...completionKeymap, ...lintKeymap, indentWithTab,
  ]),
  EditorView.theme({
    "&": {height: "100%"},
    "&.cm-focused": {outline: "none"},
    ".cm-scroller": {fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"},
  }),
]

// One compartment per setting group, shared by all states.
const compartments = {
  theme: new Compartment(),
  fontSize: new Compartment(),
  tabSize: new Compartment(),
  wordWrap: new Compartment(),
  lineNumbers: new Compartment(),
}

// Per state: the file's highlighting mode.
const languageCompartment = new Compartment()

const DEFAULTS = {fontSize: 14, tabSize: 2, wordWrap: "off", lineNumbers: "on", theme: "dark"}

const settingExtensions = s => ({
  theme: s.theme === "light" ? [] : oneDark,
  fontSize: EditorView.theme({"&": {fontSize: `${s.fontSize}px`}}),
  tabSize: [EditorState.tabSize.of(s.tabSize), indentUnit.of(" ".repeat(s.tabSize))],
  wordWrap: s.wordWrap === "on" ? EditorView.lineWrapping : [],
  lineNumbers: s.lineNumbers === "on" ? [lineNumbers(), highlightActiveLineGutter()] : [],
})

export const CodeEditor = {
  mounted() {
    this.states = new Map() // path -> EditorState of inactive tabs
    this.active = null
    this.timers = new Map() // path -> throttle timer
    this.pending = new Set() // paths with changes not yet sent
    this.modes = new Map() // path -> mode name
    this.selectionTimer = null
    this.settings = this.readSettings()

    this.view = new EditorView({parent: this.el, state: EditorState.create()})

    this.handleEvent("cm:open", ({path, text, mode}) => this.open(path, text, mode))
    this.handleEvent("cm:activate", ({path}) => this.activate(path))
    this.handleEvent("cm:close", ({path}) => this.close(path))
    this.handleEvent("cm:reload", ({path, text}) => this.reload(path, text))
    this.handleEvent("cm:language", ({path, mode}) => this.setMode(path, mode))
    this.handleEvent("cm:edit", ({path, edits, text}) => this.edit(path, edits, text))

    this.unregisterSave = registerCommand("workbench.action.files.save", () => {
      if (this.active) this.save(this.active)
    })
    this.unregisterEditor = setEditor(this)
    // A plugin registered a mode: re-apply it to the files using it.
    this.offModeChange = onModeChange(name => {
      for (const [path, mode] of this.modes) if (mode === name) this.setMode(path, mode)
    })
    this.onFlush = () => this.flushAll()
    window.addEventListener("bee:flush", this.onFlush)
  },

  // LiveView patches data-settings even though the content is ignored.
  updated() {
    const settings = this.readSettings()
    if (JSON.stringify(settings) !== JSON.stringify(this.settings)) this.configure(settings)
  },

  destroyed() {
    this.unregisterSave()
    this.unregisterEditor()
    this.offModeChange()
    window.removeEventListener("bee:flush", this.onFlush)
    clearTimeout(this.selectionTimer)
    this.timers.forEach(clearTimeout)
    this.view.destroy()
  },

  readSettings() {
    return {...DEFAULTS, ...JSON.parse(this.el.dataset.settings || "{}")}
  },

  configure(settings) {
    this.settings = settings
    const exts = settingExtensions(settings)
    const effects = Object.entries(compartments).map(([name, c]) => c.reconfigure(exts[name]))
    this.view.dispatch({effects})
    for (const [path, state] of this.states) this.states.set(path, state.update({effects}).state)
  },

  createState(path, text, mode) {
    const exts = settingExtensions(this.settings)
    return EditorState.create({
      doc: text,
      extensions: [
        setup,
        languageCompartment.of(modeExtension(mode)),
        Object.entries(compartments).map(([name, c]) => c.of(exts[name])),
        EditorView.updateListener.of(update => {
          if (update.docChanged) this.changed(path)
          if (update.docChanged || update.selectionSet) this.selectionChanged()
        }),
      ],
    })
  },

  // Applies `spec` to the state of `path`, whether shown or not.
  updateState(path, spec) {
    if (path === this.active) {
      this.view.dispatch(spec)
    } else if (this.states.has(path)) {
      this.states.set(path, this.states.get(path).update(spec).state)
    }
  },

  setMode(path, mode) {
    if (!this.stateOf(path)) return
    this.modes.set(path, mode)
    this.updateState(path, {effects: languageCompartment.reconfigure(modeExtension(mode))})
  },

  stateOf(path) {
    return path === this.active ? this.view.state : this.states.get(path)
  },

  open(path, text, mode) {
    // Always start from the server's text, even if we had a stale state.
    const state = this.createState(path, text, mode)
    this.modes.set(path, mode)
    this.stash()
    this.active = path
    this.states.delete(path)
    this.view.setState(state)
    this.view.focus()
    this.selectionChanged()
  },

  activate(path) {
    if (path === this.active || !this.states.has(path)) return
    this.stash()
    this.active = path
    this.view.setState(this.states.get(path))
    this.states.delete(path)
    this.view.focus()
    this.selectionChanged()
  },

  close(path) {
    clearTimeout(this.timers.get(path))
    this.timers.delete(path)
    this.pending.delete(path)
    this.states.delete(path)
    this.modes.delete(path)
    if (path === this.active) {
      this.active = null
      this.view.setState(EditorState.create())
    }
  },

  reload(path, text) {
    const state = this.stateOf(path)
    if (!state || state.doc.toString() === text) return
    this.updateState(path, {changes: {from: 0, to: state.doc.length, insert: text}})
  },

  // Edits made on the server (plugins), `edits` = [[from, to, insert]] in
  // UTF-8 bytes against the text the server had. Applied as one undoable
  // change if they lead to the server's `text`; if our document diverged in
  // the meantime (unsent typing), ours wins and is sent instead.
  edit(path, edits, text) {
    const state = this.stateOf(path)
    if (!state) return
    const doc = state.doc.toString()
    if (doc === text) return

    const offsets = fromBytes(doc, edits.flatMap(([from, to]) => [from, to]))
    let transaction = null
    if (edits.every(([from, to]) => offsets.has(from) && offsets.has(to))) {
      const changes = edits.map(([from, to, insert]) => ({from: offsets.get(from), to: offsets.get(to), insert}))
      try {
        transaction = state.update({changes, userEvent: "input.bee"})
      } catch (_e) {
        transaction = null
      }
    }

    if (transaction && transaction.state.doc.toString() === text) {
      if (path === this.active) this.view.dispatch(transaction)
      else this.states.set(path, transaction.state)
    } else {
      this.pushText("doc_changed", path)
    }
  },

  // Selections of the active editor, throttled like changes.
  selectionChanged() {
    if (this.selectionTimer) {
      this.selectionPending = true
      return
    }
    this.pushSelection()
    this.selectionTimer = setTimeout(() => {
      this.selectionTimer = null
      if (this.selectionPending) this.selectionChanged()
    }, SELECTION_MS)
  },

  pushSelection() {
    this.selectionPending = false
    if (!this.active) return
    const state = this.view.state
    const ranges = state.selection.ranges.map(r => [r.from, r.to])
    const bytes = toBytes(state.doc.toString(), ranges.flat())
    this.pushEvent("selection_changed", {
      path: this.active,
      ranges: ranges.map(([from, to]) => [bytes.get(from), bytes.get(to)]),
    })
  },

  // Sends what's waiting in the throttles right away.
  flushAll() {
    for (const path of [...this.timers.keys()]) {
      clearTimeout(this.timers.get(path))
      this.timers.delete(path)
      if (this.pending.delete(path)) this.pushText("doc_changed", path)
    }
    if (this.selectionTimer) {
      clearTimeout(this.selectionTimer)
      this.selectionTimer = null
      if (this.selectionPending) this.pushSelection()
    }
  },

  // Keep the active tab's state when switching away from it.
  stash() {
    if (this.active) this.states.set(this.active, this.view.state)
  },

  // Throttle with a trailing call: the first change is sent right away (so the
  // dirty marker shows up immediately), later ones at most every SYNC_MS.
  changed(path) {
    if (this.timers.has(path)) {
      this.pending.add(path)
      return
    }
    this.pushText("doc_changed", path)
    this.timers.set(path, setTimeout(() => this.flush(path), SYNC_MS))
  },

  flush(path) {
    this.timers.delete(path)
    if (this.pending.delete(path)) this.changed(path)
  },

  save(path) {
    clearTimeout(this.timers.get(path))
    this.timers.delete(path)
    this.pending.delete(path)
    this.pushText("save", path)
  },

  pushText(event, path) {
    const state = this.stateOf(path)
    if (state) this.pushEvent(event, {path, text: state.doc.toString()})
  },
}
