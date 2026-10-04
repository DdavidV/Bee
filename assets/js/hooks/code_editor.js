// CodeMirror editor for EditorLive.
//
// One EditorView is shared by all tabs; each open file keeps its own
// EditorState (document, selection, undo history) in `this.states`, and
// switching tabs swaps the state into the view.
//
// Settings arrive in data-settings (editor.* and workbench.colorTheme) and
// are applied through compartments to the active and all inactive states.
//
// Server -> client: cm:open, cm:activate, cm:close, cm:reload
// Client -> server: doc_changed (throttled), save
// Client command:   workbench.action.files.save

import {EditorState, Compartment} from "@codemirror/state"
import {
  EditorView, keymap, lineNumbers, highlightActiveLineGutter, highlightSpecialChars,
  drawSelection, dropCursor, rectangularSelection, crosshairCursor, highlightActiveLine,
} from "@codemirror/view"
import {history, defaultKeymap, historyKeymap, indentWithTab} from "@codemirror/commands"
import {
  StreamLanguage, indentUnit, foldGutter, indentOnInput, syntaxHighlighting,
  defaultHighlightStyle, bracketMatching, foldKeymap,
} from "@codemirror/language"
import {highlightSelectionMatches, searchKeymap} from "@codemirror/search"
import {closeBrackets, autocompletion, closeBracketsKeymap, completionKeymap} from "@codemirror/autocomplete"
import {lintKeymap} from "@codemirror/lint"
import {oneDark} from "@codemirror/theme-one-dark"
import {javascript} from "@codemirror/lang-javascript"
import {json} from "@codemirror/lang-json"
import {css} from "@codemirror/lang-css"
import {html} from "@codemirror/lang-html"
import {markdown} from "@codemirror/lang-markdown"
import {elixir} from "codemirror-lang-elixir"
import {erlang} from "@codemirror/legacy-modes/mode/erlang"
import {shell} from "@codemirror/legacy-modes/mode/shell"
import {yaml} from "@codemirror/legacy-modes/mode/yaml"
import {toml} from "@codemirror/legacy-modes/mode/toml"
import {dockerFile} from "@codemirror/legacy-modes/mode/dockerfile"
import {registerCommand} from "../commands/registry"

// Keys are Bee.Editor.Lang ids.
const LANGUAGES = {
  elixir: () => elixir(),
  erlang: () => StreamLanguage.define(erlang),
  javascript: () => javascript({jsx: true}),
  typescript: () => javascript({jsx: true, typescript: true}),
  json: () => json(),
  css: () => css(),
  html: () => html(),
  markdown: () => markdown(),
  shell: () => StreamLanguage.define(shell),
  yaml: () => StreamLanguage.define(yaml),
  toml: () => StreamLanguage.define(toml),
  dockerfile: () => StreamLanguage.define(dockerFile),
}

const SYNC_MS = 300

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
    this.settings = this.readSettings()

    this.view = new EditorView({parent: this.el, state: EditorState.create()})

    this.handleEvent("cm:open", ({path, text, lang}) => this.open(path, text, lang))
    this.handleEvent("cm:activate", ({path}) => this.activate(path))
    this.handleEvent("cm:close", ({path}) => this.close(path))
    this.handleEvent("cm:reload", ({path, text}) => this.reload(path, text))

    this.unregisterSave = registerCommand("workbench.action.files.save", () => {
      if (this.active) this.save(this.active)
    })
  },

  // LiveView patches data-settings even though the content is ignored.
  updated() {
    const settings = this.readSettings()
    if (JSON.stringify(settings) !== JSON.stringify(this.settings)) this.configure(settings)
  },

  destroyed() {
    this.unregisterSave()
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

  createState(path, text, lang) {
    const language = LANGUAGES[lang]
    const exts = settingExtensions(this.settings)
    return EditorState.create({
      doc: text,
      extensions: [
        setup,
        language ? language() : [],
        Object.entries(compartments).map(([name, c]) => c.of(exts[name])),
        EditorView.updateListener.of(update => {
          if (update.docChanged) this.changed(path)
        }),
      ],
    })
  },

  stateOf(path) {
    return path === this.active ? this.view.state : this.states.get(path)
  },

  open(path, text, lang) {
    // Always start from the server's text, even if we had a stale state.
    const state = this.createState(path, text, lang)
    this.stash()
    this.active = path
    this.states.delete(path)
    this.view.setState(state)
    this.view.focus()
  },

  activate(path) {
    if (path === this.active || !this.states.has(path)) return
    this.stash()
    this.active = path
    this.view.setState(this.states.get(path))
    this.states.delete(path)
    this.view.focus()
  },

  close(path) {
    clearTimeout(this.timers.get(path))
    this.timers.delete(path)
    this.pending.delete(path)
    this.states.delete(path)
    if (path === this.active) {
      this.active = null
      this.view.setState(EditorState.create())
    }
  },

  reload(path, text) {
    const state = this.stateOf(path)
    if (!state || state.doc.toString() === text) return
    const spec = {changes: {from: 0, to: state.doc.length, insert: text}}
    if (path === this.active) {
      this.view.dispatch(spec)
    } else {
      this.states.set(path, state.update(spec).state)
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
