// CodeMirror editor for EditorLive.
//
// One EditorView is shared by all tabs; each open file keeps its own
// EditorState (document, selection, undo history) in `this.states`, and
// switching tabs swaps the state into the view.
//
// Settings arrive in data-settings (editor.* and the color theme) and are
// applied through compartments to the active and all inactive states.
//
// Color: `theme` is the color theme's base, "dark" or "light". Bee's own
// themes use One Dark or CodeMirror's light default; a theme with colors
// of its own (`themeColors`) colors the editor with them, through the
// --vscode-* CSS variables it sets on the page (Bee.ColorThemes.Theme).
//
// Highlighting: the server sends each file's language and how to highlight
// it: the name of a CodeMirror mode (editor/modes.js; one registered later
// by a plugin is applied to the files waiting for it), or the scope name of
// a TextMate grammar (editor/textmate.js; data-grammars lists them,
// data-token-colors has the color theme's tokenColors). With them comes the
// language's configuration, if it has one (editor/language_config.js).
//
// Server -> client: cm:open, cm:activate, cm:deactivate (an editor that
//                   isn't a file is shown), cm:close, cm:reload, cm:language,
//                   cm:edit (server-side edits, UTF-8 byte offsets),
//                   cm:reveal (select a range / go to a line),
//                   cm:snippet (Insert Snippet), cm:diagnostics (a file's
//                   problems, JSON validation), cm:language_diagnostics
//                   (those extensions found), cm:language_features (what
//                   extensions provide for a file), language:reply
// Client -> server: doc_changed (throttled), save, selection_changed
//                   (throttled, UTF-8 byte offsets; for plugin commands)
//                   history_changed (whether the active file can undo/redo)
//                   language_request, language_cancel, language_goto, language_rename,
//                   language_code_actions
//                   (editor/language_features.js)
// Client commands:  workbench.action.files.save, undo, redo
//
// A `bee:flush` window event sends pending changes and selections at once
// (the Keybindings hook fires it before running a command).

import {EditorState, Compartment, Prec} from "@codemirror/state"
import {
  EditorView, keymap, lineNumbers, highlightActiveLineGutter, highlightSpecialChars,
  drawSelection, dropCursor, rectangularSelection, crosshairCursor, highlightActiveLine,
} from "@codemirror/view"
import {
  history, defaultKeymap, historyKeymap, indentWithTab, undo, redo, undoDepth, redoDepth,
} from "@codemirror/commands"
import {
  indentUnit, foldGutter, indentOnInput, syntaxHighlighting,
  defaultHighlightStyle, bracketMatching, foldKeymap,
} from "@codemirror/language"
import {highlightSelectionMatches, searchKeymap} from "@codemirror/search"
import {closeBrackets, autocompletion, closeBracketsKeymap, completionKeymap, acceptCompletion} from "@codemirror/autocomplete"
import {lintKeymap, setDiagnostics} from "@codemirror/lint"
import {oneDark, oneDarkHighlightStyle} from "@codemirror/theme-one-dark"
import {registerCommand} from "../commands/registry"
import {modeExtension, onModeChange} from "../editor/modes"
import "../editor/builtin_modes"
import {toBytes, fromBytes} from "../editor/offsets"
import {setEditor} from "../editor/active"
import {filePath, pluginExtensions, onExtensionsChange} from "../editor/extensions"
import {textmate, setGrammars, setTokenColors, onTextMateChange} from "../editor/textmate"
import {languageConfig} from "../editor/language_config"
import {snippetCompletions, insertSnippet, setSnippetRoot} from "../editor/snippets"
import {jsonAssist, setJsonRequester} from "../editor/json_assist"
import {
  languageFeatures, setFeatures, setLanguageRequester, goTo, quickFix, rename, showHover, startCompletion,
  triggerSignatureHelp,
} from "../editor/language_features"

const SYNC_MS = 300
const SELECTION_MS = 100
// How long an extension's language feature is waited for.
const LANGUAGE_MS = 10000

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
  // Tab takes the selected suggestion, like Enter (before a snippet's next
  // field, and before indenting); with no suggestions it does what it did.
  Prec.highest(keymap.of([{key: "Tab", run: acceptCompletion}])),
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
// Shared by all states: extensions of browser plugins.
const pluginCompartment = new Compartment()

const DEFAULTS = {fontSize: 14, tabSize: 2, wordWrap: "off", lineNumbers: "on", theme: "dark"}

// The editor in a color theme's colors (VS Code's keys, as CSS variables).
const v = key => `var(--vscode-${key.replaceAll(".", "-")})`
const themeColors = dark => [
  EditorView.theme(
    {
      "&": {color: v("editor.foreground"), backgroundColor: v("editor.background")},
      ".cm-content": {caretColor: v("editorCursor.foreground")},
      ".cm-cursor, .cm-dropCursor": {borderLeftColor: v("editorCursor.foreground")},
      ".cm-selectionBackground": {backgroundColor: v("editor.inactiveSelectionBackground")},
      "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-content ::selection":
        {backgroundColor: v("editor.selectionBackground")},
      ".cm-activeLine": {backgroundColor: v("editor.lineHighlightBackground")},
      ".cm-selectionMatch": {backgroundColor: v("editor.selectionHighlightBackground")},
      ".cm-searchMatch": {backgroundColor: v("editor.findMatchHighlightBackground")},
      ".cm-searchMatch.cm-searchMatch-selected": {backgroundColor: v("editor.findMatchBackground")},
      "&.cm-focused .cm-matchingBracket, &.cm-focused .cm-nonmatchingBracket": {
        backgroundColor: v("editorBracketMatch.background"),
        outline: `1px solid ${v("editorBracketMatch.border")}`,
      },
      ".cm-gutters": {
        backgroundColor: v("editorGutter.background"),
        color: v("editorLineNumber.foreground"),
        border: "none",
      },
      ".cm-activeLineGutter": {backgroundColor: "transparent", color: v("editorLineNumber.activeForeground")},
      ".cm-foldPlaceholder": {backgroundColor: "transparent", border: "none", color: v("editorLineNumber.foreground")},
      ".cm-panels": {backgroundColor: v("editorWidget.background"), color: v("editorWidget.foreground")},
      ".cm-tooltip": {
        backgroundColor: v("editorWidget.background"),
        color: v("editorWidget.foreground"),
        border: `1px solid ${v("editorWidget.border")}`,
      },
      ".cm-tooltip-autocomplete": {
        backgroundColor: v("editorSuggestWidget.background"),
        color: v("editorSuggestWidget.foreground"),
      },
      ".cm-tooltip-autocomplete > ul > li[aria-selected]": {
        backgroundColor: v("editorSuggestWidget.selectedBackground"),
        color: v("editorSuggestWidget.selectedForeground"),
      },
    },
    {dark},
  ),
  // Syntax: still Bee's own colors for now.
  syntaxHighlighting(dark ? oneDarkHighlightStyle : defaultHighlightStyle),
]

// A file's highlighting – a TextMate grammar, a CodeMirror mode, or none –
// its language configuration (editor/language_config.js) and snippets
// (editor/snippets.js).
const highlighting = ({mode, scope, config, snippets, json}) => [
  scope ? textmate(scope) : modeExtension(mode),
  languageConfig(config, !scope && !!mode),
  snippetCompletions(snippets),
  jsonAssist(json),
]

const settingExtensions = s => ({
  theme: s.themeColors ? themeColors(s.theme !== "light") : s.theme === "light" ? [] : oneDark,
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
    this.modes = new Map() // path -> {mode, scope, config, snippets}
    this.selectionTimer = null
    this.settings = this.readSettings()
    this.readTextMate()
    setSnippetRoot(this.el.dataset.root)
    setJsonRequester((kind, state, pos) => this.jsonRequest(kind, state, pos))

    this.view = new EditorView({parent: this.el, state: EditorState.create()})

    this.handleEvent("cm:open", ({path, text, mode, scope, config, snippets, json}) =>
      this.open(path, text, {mode, scope, config, snippets, json}),
    )
    this.handleEvent("cm:activate", ({path}) => this.activate(path))
    this.handleEvent("cm:deactivate", () => this.deactivate())
    this.handleEvent("cm:close", ({path}) => this.close(path))
    this.handleEvent("cm:reload", ({path, text}) => this.reload(path, text))
    this.handleEvent("cm:language", ({path, mode, scope, config, snippets, json}) =>
      this.setMode(path, {mode, scope, config, snippets, json}),
    )
    this.handleEvent("cm:snippet", ({path, body}) => this.insertSnippet(path, body))
    this.handleEvent("cm:diagnostics", d => this.setDiagnostics(d))
    this.handleEvent("cm:language_diagnostics", d => this.setLanguageDiagnostics(d))
    // A file's problems, by who found them: path -> CodeMirror diagnostics
    // (JSON validation), path -> [{from: {line, character}, to, …}] (extensions).
    this.jsonDiagnostics = new Map()
    this.languageDiagnostics = new Map()
    // Language features of extensions (editor/language_features.js):
    // path -> what there is for the file, ref -> who waits for an answer.
    this.languageFeatures = new Map()
    this.languageRequests = new Map()
    this.nextLanguageRef = 0
    setLanguageRequester({
      request: (feature, state, params) => this.languageRequest(feature, state, params),
      goTo: (feature, state, position) => {
        const path = state.facet(filePath)
        if (!path || path !== this.active) return
        this.flushAll()
        this.pushEvent("language_goto", {feature, path, position})
      },
      codeActions: (state, range) => {
        const path = state.facet(filePath)
        if (!path || path !== this.active) return
        this.flushAll()
        this.pushEvent("language_code_actions", {path, range})
      },
      rename: (state, position) => {
        const path = state.facet(filePath)
        if (!path || path !== this.active) return
        this.flushAll()
        this.pushEvent("language_rename", {path, position})
      },
    })
    this.handleEvent("cm:language_features", ({path, features}) => {
      this.languageFeatures.set(path, features)
      this.updateState(path, {effects: setFeatures.of(features)})
    })
    this.handleEvent("language:reply", ({ref, result}) => this.languageRequests.get(ref)?.(result ?? null))
    this.handleEvent("cm:edit", ({path, edits, text}) => this.edit(path, edits, text))
    this.handleEvent("cm:reveal", target => this.reveal(target))

    this.unregisterCommands = [
      registerCommand("workbench.action.files.save", () => {
        if (this.active) this.save(this.active)
      }),
      registerCommand("undo", () => this.runHistory(undo)),
      registerCommand("redo", () => this.runHistory(redo)),
      registerCommand("editor.action.clipboardCutAction", () => this.clipboard("cut")),
      registerCommand("editor.action.clipboardCopyAction", () => this.clipboard("copy")),
      registerCommand("editor.action.clipboardPasteAction", () => this.clipboard("paste")),
      registerCommand("editor.action.triggerSuggest", () => this.inFile(startCompletion)),
      registerCommand("editor.action.showHover", () => this.inFile(showHover)),
      registerCommand("editor.action.triggerParameterHints", () => this.inFile(triggerSignatureHelp)),
      registerCommand("editor.action.rename", () => this.inFile(rename)),
      registerCommand("editor.action.quickFix", () => this.inFile(quickFix)),
      ...Object.entries({
        "editor.action.revealDefinition": "definition",
        "editor.action.revealDeclaration": "declaration",
        "editor.action.goToTypeDefinition": "typeDefinition",
        "editor.action.goToImplementation": "implementation",
        "editor.action.goToReferences": "references",
      }).map(([id, feature]) => registerCommand(id, () => this.inFile(view => goTo(view, feature)))),
    ]
    this.history = null // last {canUndo, canRedo} sent
    this.unregisterEditor = setEditor(this)
    // A plugin registered a mode: re-apply it to the files using it.
    this.offModeChange = onModeChange(name => {
      for (const [path, h] of this.modes) if (h.mode === name && !h.scope) this.setMode(path, h, true)
    })
    // Grammars or token colors changed: the shown file highlights again
    // (the others when shown).
    this.offTextMateChange = onTextMateChange(() => this.view.dispatch({}))
    this.offExtensionsChange = onExtensionsChange(() => {
      const effects = pluginCompartment.reconfigure(pluginExtensions())
      this.view.dispatch({effects})
      for (const [path, state] of this.states) this.states.set(path, state.update({effects}).state)
    })
    this.onFlush = () => this.flushAll()
    window.addEventListener("bee:flush", this.onFlush)
  },

  // LiveView patches data-settings even though the content is ignored.
  updated() {
    this.readTextMate()
    const settings = this.readSettings()
    if (JSON.stringify(settings) !== JSON.stringify(this.settings)) this.configure(settings)
  },

  // Unchanged strings are ignored cheaply (textmate.js compares them too).
  readTextMate() {
    const {grammars, tokenColors} = this.el.dataset
    if (grammars !== this.grammarsJson) {
      this.grammarsJson = grammars
      setGrammars(JSON.parse(grammars || "{}"))
    }
    if (tokenColors !== this.tokenColorsJson) {
      this.tokenColorsJson = tokenColors
      setTokenColors(JSON.parse(tokenColors || "[]"))
    }
  },

  destroyed() {
    this.unregisterCommands.forEach(unregister => unregister())
    this.unregisterEditor()
    this.offModeChange()
    this.offTextMateChange()
    this.offExtensionsChange()
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

  createState(path, text, highlight) {
    const exts = settingExtensions(this.settings)
    return EditorState.create({
      doc: text,
      extensions: [
        setup,
        filePath.of(path),
        languageFeatures(this.languageFeatures.get(path)),
        languageCompartment.of(highlighting(highlight)),
        pluginCompartment.of(pluginExtensions()),
        Object.entries(compartments).map(([name, c]) => c.of(exts[name])),
        // Leaving the editor (for another tab, say): the server has the
        // text before it hears of what was clicked.
        EditorView.domEventHandlers({blur: () => void this.flushAll()}),
        EditorView.updateListener.of(update => {
          if (update.docChanged) this.changed(path)
          if (update.transactions.length) this.historyChanged()
          if (update.docChanged || update.selectionSet) this.selectionChanged()
        }),
      ],
    })
  },

  // Runs an editor command in the shown file.
  inFile(command) {
    if (!this.active) return
    this.view.focus()
    command(this.view)
  },

  // Asks the extensions for a language feature (editor/language_features.js);
  // the server gets the file's text first. The promise's `cancel()` gives
  // up on the answer, as does taking too long: it is null then.
  languageRequest(feature, state, params) {
    const path = state ? state.facet(filePath) : this.active
    let ref = null
    const promise = new Promise(resolve => {
      if (!path || path !== this.active) return resolve(null)
      this.flushAll()
      ref = `l${++this.nextLanguageRef}`
      const timer = setTimeout(() => promise.cancel(), LANGUAGE_MS)
      this.languageRequests.set(ref, result => {
        clearTimeout(timer)
        this.languageRequests.delete(ref)
        resolve(result)
      })
      this.pushEvent("language_request", {ref, feature, path, params})
    })
    promise.cancel = () => {
      const done = this.languageRequests.get(ref)
      if (!done) return
      done(null)
      this.pushEvent("language_cancel", {ref})
    }
    return promise
  },

  runHistory(command) {
    if (!this.active) return
    command(this.view)
    this.view.focus()
  },

  contextKeys() {
    const state = this.active && this.view.state
    return {
      canUndo: !!state && undoDepth(state) > 0,
      canRedo: !!state && redoDepth(state) > 0,
      editorHasSelection: !!state && state.selection.ranges.some(r => !r.empty),
    }
  },

  // Cut, Copy and Paste of the editor's right-click menu, on the main
  // selection (the whole line when it is empty, as with the keys). Reading
  // the clipboard is the browser's to allow: the keys always work.
  async clipboard(action) {
    if (!this.active) return
    const view = this.view
    const {state} = view
    const main = state.selection.main
    const line = state.doc.lineAt(main.head)
    const range = main.empty ? {from: line.from, to: Math.min(line.to + 1, state.doc.length)} : main
    try {
      if (action === "paste") {
        const text = await navigator.clipboard.readText()
        view.dispatch(view.state.replaceSelection(text), {scrollIntoView: true, userEvent: "input.paste"})
      } else {
        await navigator.clipboard.writeText(state.sliceDoc(range.from, range.to))
        if (action === "cut") view.dispatch({changes: range, userEvent: "delete.cut"})
      }
    } catch (_e) {
      const keys = {cut: "Ctrl+X", copy: "Ctrl+C", paste: "Ctrl+V"}
      this.pushEvent("plugin_message", {plugin: "bee", level: "error", text: `The browser didn't allow the clipboard here: use ${keys[action]}.`})
    }
    view.focus()
  },

  // Tells the server when undo/redo become (un)available for the active file.
  historyChanged() {
    const history = this.contextKeys()
    if (this.history && history.canUndo === this.history.canUndo && history.canRedo === this.history.canRedo) return
    this.history = history
    this.pushEvent("history_changed", history)
  },

  // Applies `spec` to the state of `path`, whether shown or not.
  updateState(path, spec) {
    if (path === this.active) {
      this.view.dispatch(spec)
    } else if (this.states.has(path)) {
      this.states.set(path, this.states.get(path).update(spec).state)
    }
  },

  // `highlight`: {mode, scope, config, snippets}; the same again changes nothing,
  // unless `force`.
  setMode(path, highlight, force = false) {
    if (!this.stateOf(path)) return
    const old = this.modes.get(path)
    if (!force && old && JSON.stringify(old) === JSON.stringify(highlight)) return
    this.modes.set(path, highlight)
    this.updateState(path, {effects: languageCompartment.reconfigure(highlighting(highlight))})
  },

  stateOf(path) {
    return path === this.active ? this.view.state : this.states.get(path)
  },

  open(path, text, highlight) {
    // Always start from the server's text, even if we had a stale state.
    const state = this.createState(path, text, highlight)
    this.modes.set(path, highlight)
    this.stash()
    this.active = path
    this.states.delete(path)
    this.view.setState(state)
    this.view.focus()
    this.selectionChanged()
    this.historyChanged()
    // Problems that came before the file did.
    this.jsonDiagnostics.delete(path)
    this.applyDiagnostics(path)
  },

  activate(path) {
    if (path === this.active || !this.states.has(path)) return
    this.stash()
    this.active = path
    this.view.setState(this.states.get(path))
    this.states.delete(path)
    this.view.focus()
    this.selectionChanged()
    this.historyChanged()
  },

  // Another kind of editor is shown: the file is put away until activated.
  deactivate() {
    if (this.active === null) return
    this.stash()
    this.active = null
    this.view.setState(EditorState.create())
    this.view.contentDOM.blur()
    this.historyChanged()
  },

  close(path) {
    clearTimeout(this.timers.get(path))
    this.timers.delete(path)
    this.pending.delete(path)
    this.states.delete(path)
    this.modes.delete(path)
    this.jsonDiagnostics.delete(path)
    this.languageDiagnostics.delete(path)
    this.languageFeatures.delete(path)
    if (path === this.active) {
      this.active = null
      this.view.setState(EditorState.create())
      this.historyChanged()
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

  // A file's problems (JSON validation): underlined, with their message on
  // hover. UTF-8 byte offsets in the text of `size` bytes: when ours isn't
  // that one any more (typed since), they're dropped; newer ones follow.
  setDiagnostics({path, size, diagnostics}) {
    const state = this.stateOf(path)
    if (!state) return
    const doc = state.doc.toString()
    if (new TextEncoder().encode(doc).length !== size) return
    const offsets = fromBytes(doc, diagnostics.flatMap(d => [d.from, d.to]))
    const list = diagnostics
      .filter(d => offsets.has(d.from) && offsets.has(d.to))
      .map(d => ({from: offsets.get(d.from), to: offsets.get(d.to), severity: d.severity, message: d.message, source: "JSON"}))
    this.jsonDiagnostics.set(path, list)
    this.applyDiagnostics(path)
  },

  // A file's problems found by extensions' language features (Bee.Diagnostics):
  // line and character positions, as language servers count them.
  setLanguageDiagnostics({path, diagnostics}) {
    this.languageDiagnostics.set(path, diagnostics)
    this.applyDiagnostics(path)
  },

  // Underlines a file's problems of both kinds, with their message on hover.
  applyDiagnostics(path) {
    const state = this.stateOf(path)
    if (!state) return
    const doc = state.doc
    const offset = ({line, character}) => {
      if (line >= doc.lines) return doc.length
      const at = doc.line(line + 1)
      return Math.min(at.from + character, at.to)
    }
    const language = (this.languageDiagnostics.get(path) || []).map(d => {
      const from = offset(d.from)
      let to = Math.max(from, offset(d.to))
      // Nothing to underline: the word there, or the next character.
      if (to === from) to = state.wordAt(from)?.to ?? Math.min(from + 1, doc.lineAt(from).to)
      return {
        from,
        to: Math.max(to, from),
        severity: d.severity,
        message: d.message,
        source: [d.source, d.code && `(${d.code})`].filter(Boolean).join(" ") || undefined,
      }
    })
    const all = [...(this.jsonDiagnostics.get(path) || []), ...language].sort((a, b) => a.from - b.from)
    this.updateState(path, setDiagnostics(state, all))
  },

  // Completion or hover from a JSON file's schemas (editor/json_assist.js):
  // the server gets the text first, then the question, in that order.
  jsonRequest(kind, state, pos) {
    const path = state.facet(filePath)
    if (!path || path !== this.active) return Promise.resolve(null)
    this.flushAll()
    const doc = state.doc.toString()
    const offset = toBytes(doc, [pos]).get(pos)
    const size = new TextEncoder().encode(doc).length
    return new Promise(resolve => this.pushEvent("json_assist", {path, kind, offset, size}, reply => resolve(reply)))
  },

  // Insert Snippet: over the active file's selection (TM_SELECTED_TEXT).
  insertSnippet(path, body) {
    if (path !== this.active) return
    const {from, to} = this.view.state.selection.main
    insertSnippet(this.view, body, from, to)
    this.view.focus()
  },

  // Selects `from`-`to` (UTF-8 bytes) or goes to `line` (1-based) in the
  // active file, scrolled into view.
  reveal({path, from, to, line}) {
    if (path !== this.active) return
    const state = this.view.state
    let anchor, head
    if (line != null) {
      const l = state.doc.line(Math.min(Math.max(1, line), state.doc.lines))
      anchor = head = l.from
    } else {
      const offsets = fromBytes(state.doc.toString(), [from, to])
      if (!offsets.has(from) || !offsets.has(to)) return
      anchor = offsets.get(from)
      head = offsets.get(to)
    }
    this.view.dispatch({selection: {anchor, head}, scrollIntoView: true})
    this.view.focus()
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
