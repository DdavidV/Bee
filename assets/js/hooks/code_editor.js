// CodeMirror editor for EditorLive.
//
// One EditorView is shared by all tabs; each open file keeps its own
// EditorState (document, selection, undo history) in `this.states`, and
// switching tabs swaps the state into the view.
//
// Server -> client: cm:open, cm:activate, cm:close, cm:reload
// Client -> server: doc_changed (throttled), save

import {basicSetup} from "codemirror"
import {EditorState, Prec} from "@codemirror/state"
import {EditorView, keymap} from "@codemirror/view"
import {indentWithTab} from "@codemirror/commands"
import {StreamLanguage, indentUnit} from "@codemirror/language"
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

// Keys are Bee.Lang ids.
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

const TAB_SIZE = 2

const SYNC_MS = 300

const baseTheme = EditorView.theme({
  "&": {height: "100%", fontSize: "14px"},
  ".cm-scroller": {fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"},
})

export const CodeEditor = {
  mounted() {
    this.states = new Map() // path -> EditorState of inactive tabs
    this.active = null
    this.timers = new Map() // path -> throttle timer
    this.pending = new Set() // paths with changes not yet sent

    this.view = new EditorView({parent: this.el, state: EditorState.create()})

    this.handleEvent("cm:open", ({path, text, lang}) => this.open(path, text, lang))
    this.handleEvent("cm:activate", ({path}) => this.activate(path))
    this.handleEvent("cm:close", ({path}) => this.close(path))
    this.handleEvent("cm:reload", ({path, text}) => this.reload(path, text))

    // Ctrl/Cmd+S outside the editor (e.g. after clicking a tab) saves the active
    // file instead of opening the browser's "Save page" dialog.
    this.onKeydown = e => {
      if ((e.ctrlKey || e.metaKey) && e.key === "s") {
        e.preventDefault()
        if (this.active) this.save(this.active)
      }
    }
    window.addEventListener("keydown", this.onKeydown)
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeydown)
    this.timers.forEach(clearTimeout)
    this.view.destroy()
  },

  createState(path, text, lang) {
    const language = LANGUAGES[lang]
    return EditorState.create({
      doc: text,
      extensions: [
        basicSetup,
        Prec.high(keymap.of([
          {key: "Mod-s", preventDefault: true, run: () => (this.save(path), true)},
        ])),
        keymap.of([indentWithTab]),
        language ? language() : [],
        EditorState.tabSize.of(TAB_SIZE),
        indentUnit.of(" ".repeat(TAB_SIZE)),
        oneDark,
        baseTheme,
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
