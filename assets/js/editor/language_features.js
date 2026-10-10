// Language features of extensions in the editor (Bee.Languages.Features on
// the server, the providers of VS Code extensions behind it): completion,
// hover, and going to where a symbol is defined.
//
// The CodeEditor hook is asked through `setLanguageRequester`:
//
//   request(feature, state, params)  a promise of the answer (null: none);
//                                    its `cancel()` gives up on it
//   goTo(feature, state, pos)        the server opens the place itself
//
// and tells each file's state which features there are for it
// (`setFeatures`: {completion: {triggerCharacters}, hover: {…}, …}), so
// that nothing is asked when nobody would answer. Positions go as
// {line, character}, which CodeMirror and the extensions count alike.

import {StateField, StateEffect, EditorState, Prec, RangeSet} from "@codemirror/state"
import {Decoration, EditorView, GutterMarker, ViewPlugin, gutter, hoverTooltip, keymap, showTooltip} from "@codemirror/view"
import {insertCompletionText, pickedCompletion, startCompletion} from "@codemirror/autocomplete"
import {insertSnippet} from "./snippets"
import {render} from "../hooks/markdown"

let requester = null
export const setLanguageRequester = hook => (requester = hook)

// ---- Which features a file has

export const setFeatures = StateEffect.define()

const featuresField = StateField.define({
  create: () => ({}),
  update: (value, tr) => tr.effects.reduce((v, effect) => (effect.is(setFeatures) ? effect.value || {} : v), value),
})

const featuresOf = state => state.field(featuresField, false) || {}

// ---- Positions

export const toPosition = (state, pos) => {
  const line = state.doc.lineAt(pos)
  return {line: line.number - 1, character: pos - line.from}
}

export const toOffset = (state, {line, character}) => {
  if (line >= state.doc.lines) return state.doc.length
  const at = state.doc.line(line + 1)
  return Math.min(at.from + Math.max(character, 0), at.to)
}

// ---- Documentation

// Markdown of an extension as DOM (sanitized, like a plugin's README).
const markdown = text => {
  const dom = document.createElement("div")
  dom.className = "markdown cm-language-doc"
  dom.append(render(text, "/"))
  return dom
}

const box = (...children) => {
  const dom = document.createElement("div")
  dom.className = "cm-language-info"
  dom.append(...children.filter(Boolean))
  return dom
}

const code = text => {
  const dom = document.createElement("div")
  dom.className = "cm-language-signature"
  dom.textContent = text
  return dom
}

// ---- Completion

const WORD_BEFORE = /[\p{L}\p{N}_$]+/u
const WORD = /^[\p{L}\p{N}_$]*$/u

// VS Code's kinds as CodeMirror's types (its icons).
const TYPES = {
  method: "method", function: "function", constructor: "function", field: "property", variable: "variable",
  class: "class", interface: "interface", module: "namespace", property: "property", unit: "constant",
  value: "constant", enum: "enum", keyword: "keyword", snippet: "text", color: "constant", file: "text",
  reference: "variable", folder: "text", enummember: "enum", constant: "constant", struct: "class",
  event: "variable", operator: "keyword", typeparameter: "type", text: "text",
}

// What resolving an item added (documentation, edits), asked once.
const resolved = (item, session) => {
  if (!item.resolvable) return Promise.resolve(item)
  item.resolving ??= requester.request("completionResolve", null, {session, index: item.index}).then(more => {
    if (more) Object.assign(item, {...more, resolvable: true, resolvedNow: true})
    return item
  })
  return item.resolving
}

const info = (item, session) => async () => {
  await resolved(item, session)
  if (!item.info && !item.documentation) return null
  return box(item.info && code(item.info), item.documentation && markdown(item.documentation))
}

// Inserts the item: its text over its range (or the word being typed),
// its edits elsewhere, then its command.
const apply = (item, session) => (view, completion, from, to) => {
  const state = view.state
  if (item.range) {
    from = Math.min(toOffset(state, item.range.from), from)
    to = Math.max(toOffset(state, item.range.to), to)
  }
  const edits = (item.edits || []).map(edit => ({
    from: toOffset(state, edit.from),
    to: toOffset(state, edit.to),
    insert: edit.text,
  }))
  if (item.snippet) {
    // The edits first: the snippet's fields are placed in what they left.
    if (edits.length) {
      const changes = state.changes(edits)
      view.dispatch({changes})
      from = changes.mapPos(from, 1)
      to = changes.mapPos(to, 1)
    }
    insertSnippet(view, item.insertText, from, to, completion)
  } else {
    let spec = insertCompletionText(state, item.insertText, from, to)
    if (edits.length) {
      const changes = state.changes([{from, to, insert: item.insertText}, ...edits])
      spec = {changes, selection: {anchor: changes.mapPos(to, 1)}, userEvent: "input.complete", scrollIntoView: true}
    }
    view.dispatch({...spec, annotations: pickedCompletion.of(completion)})
  }
  if (item.command) requester.request("completionAccept", null, {session, index: item.index})
}

const option = (item, session, boost) => ({
  // CodeMirror filters by the label: what the item wants to be found by.
  label: item.filterText || item.label,
  displayLabel: item.label,
  detail: [item.detail, item.description].filter(Boolean).join(" ") || undefined,
  type: TYPES[item.kind] || "text",
  boost,
  commitCharacters: item.commitCharacters?.length ? item.commitCharacters : undefined,
  info: item.resolvable || item.info || item.documentation ? info(item, session) : undefined,
  apply: apply(item, session),
})

const complete = async context => {
  const spec = featuresOf(context.state).completion
  if (!spec || !requester) return null
  const word = context.matchBefore(WORD_BEFORE)
  const before = context.state.sliceDoc(Math.max(0, context.pos - 1), context.pos)
  const trigger = !word && (spec.triggerCharacters || []).includes(before) ? before : null
  if (!word && !trigger && !context.explicit) return null

  const asking = requester.request("completion", context.state, {
    position: toPosition(context.state, context.pos),
    context: {triggerKind: trigger ? 1 : 0, triggerCharacter: trigger},
  })
  context.addEventListener("abort", () => asking.cancel())
  const reply = await asking
  if (context.aborted || !reply?.items?.length) return null

  // The items in their own order (sortText), as far as matching allows.
  const sorted = [...reply.items].sort((a, b) => {
    if (a.preselect !== b.preselect) return a.preselect ? -1 : 1
    const [x, y] = [a.sortText || a.label, b.sortText || b.label]
    return x < y ? -1 : x > y ? 1 : 0
  })
  // What is typed is matched from where the items begin, when they agree.
  let from = word ? word.from : context.pos
  const starts = new Set(sorted.filter(item => item.range).map(item => toOffset(context.state, item.range.from)))
  if (starts.size === 1 && sorted.every(item => item.range)) from = Math.min(context.pos, [...starts][0])

  return {
    from,
    options: sorted.map((item, i) => option(item, reply.session, 99 - Math.floor((i * 198) / sorted.length))),
    // Incomplete: asked again as more is typed.
    validFor: reply.incomplete ? undefined : WORD,
  }
}

// One source for good (CodeMirror tells sources apart by identity).
const completionData = [{autocomplete: complete}]

// ---- Hover

const hoverContent = reply => () => ({dom: box(...reply.contents.map(markdown))})

const hoverAt = async (state, pos) => {
  if (!featuresOf(state).hover || !requester) return null
  // Not over blank space.
  if (!/\S/.test(state.sliceDoc(Math.max(0, pos - 1), Math.min(state.doc.length, pos + 1)))) return null
  const reply = await requester.request("hover", state, {position: toPosition(state, pos)})
  if (!reply?.contents?.length) return null
  const from = reply.range ? toOffset(state, reply.range.from) : pos
  const to = reply.range ? toOffset(state, reply.range.to) : pos
  return {pos: Math.min(from, pos), end: Math.max(to, pos), above: true, create: hoverContent(reply)}
}

const hover = hoverTooltip((view, pos) => hoverAt(view.state, pos), {hoverTime: 350})

// Show Hover (the keyboard's): at the cursor, until it moves.
const showHoverEffect = StateEffect.define()
const keyboardHover = StateField.define({
  create: () => null,
  update(value, tr) {
    for (const effect of tr.effects) if (effect.is(showHoverEffect)) return effect.value
    return tr.docChanged || tr.selection ? null : value
  },
  provide: field => showTooltip.from(field),
})

export const showHover = async view => {
  const state = view.state
  const tooltip = await hoverAt(state, state.selection.main.head)
  if (tooltip && view.state === state) view.dispatch({effects: showHoverEffect.of(tooltip)})
}

// ---- Signature help (parameter hints)

// The call the cursor is in: its signature above the cursor, the
// parameter being typed in bold. Opened by the characters its providers
// ask for ("(", ","), or Trigger Parameter Hints; asked again as the text
// or the cursor changes, until there is no answer (or Escape).
const setSignature = StateEffect.define()

const signatureDom = help => {
  const signature = help.signatures[help.activeSignature] || help.signatures[0]
  const index = signature.activeParameter ?? help.activeParameter
  const parameter = signature.parameters[index]
  const label = document.createElement("div")
  label.className = "cm-language-signature"
  // A parameter's label: its text, or where it is in the signature's.
  let range = null
  if (parameter && Array.isArray(parameter.label)) range = parameter.label
  else if (parameter) {
    const at = signature.label.indexOf(parameter.label)
    if (at >= 0) range = [at, at + parameter.label.length]
  }
  if (range) {
    const active = document.createElement("strong")
    active.className = "cm-language-parameter"
    active.textContent = signature.label.slice(range[0], range[1])
    label.append(signature.label.slice(0, range[0]), active, signature.label.slice(range[1]))
  } else {
    label.textContent = signature.label
  }
  if (help.signatures.length > 1) {
    const count = document.createElement("span")
    count.style.opacity = "0.6"
    count.textContent = ` ${(help.activeSignature || 0) + 1}/${help.signatures.length}`
    label.append(count)
  }
  const dom = box(label, parameter?.documentation && markdown(parameter.documentation), signature.documentation && markdown(signature.documentation))
  dom.classList.add("cm-language-signature-help")
  return dom
}

const signatureField = StateField.define({
  create: () => null,
  update(value, tr) {
    for (const effect of tr.effects) if (effect.is(setSignature)) return effect.value
    return value
  },
  provide: field => showTooltip.from(field),
})

const signaturePlugin = ViewPlugin.fromClass(
  class {
    constructor(view) {
      this.view = view
      this.asking = null
    }

    update(update) {
      const state = update.state
      const spec = featuresOf(state).signatureHelp
      if (!spec) return
      const open = state.field(signatureField, false)
      if (update.docChanged && update.transactions.some(tr => tr.isUserEvent("input"))) {
        const head = state.selection.main.head
        const typed = state.sliceDoc(Math.max(0, head - 1), head)
        if ((spec.triggerCharacters || []).includes(typed)) return this.ask({triggerKind: 2, triggerCharacter: typed, isRetrigger: !!open})
      }
      if (open && (update.docChanged || update.selectionSet)) this.ask({triggerKind: 3, isRetrigger: true})
    }

    // Asked after the update (a view can't be changed while it updates).
    ask(context) {
      this.asking?.cancel()
      const view = this.view
      queueMicrotask(async () => {
        if (!requester) return
        const state = view.state
        const head = state.selection.main.head
        const asking = (this.asking = requester.request("signatureHelp", state, {position: toPosition(state, head), context}))
        const help = await asking
        if (this.asking !== asking || view.state.selection.main.head !== head) return
        this.asking = null
        const tooltip = help?.signatures?.length ? {pos: head, above: true, create: () => ({dom: signatureDom(help)})} : null
        if (tooltip || view.state.field(signatureField, false)) view.dispatch({effects: setSignature.of(tooltip)})
      })
    }

    destroy() {
      this.asking?.cancel()
    }
  },
)

// Trigger Parameter Hints: asks at the cursor.
export const triggerSignatureHelp = view => view.plugin(signaturePlugin)?.ask({triggerKind: 1, isRetrigger: false})

const closeSignature = view => {
  if (!view.state.field(signatureField, false)) return false
  view.dispatch({effects: setSignature.of(null)})
  return true
}

const signatureHelp = [signatureField, signaturePlugin, Prec.high(keymap.of([{key: "Escape", run: closeSignature}]))]

// ---- Occurrences of the symbol at the cursor

// Where the symbol under the cursor is in the file (its extension's
// document highlights), marked a moment after the cursor rests there.
const HIGHLIGHT_MS = 250
const setHighlights = StateEffect.define()
const highlightMarks = {
  text: Decoration.mark({class: "cm-language-highlight"}),
  read: Decoration.mark({class: "cm-language-highlight"}),
  write: Decoration.mark({class: "cm-language-highlight cm-language-highlight-write"}),
}

const highlightField = StateField.define({
  create: () => Decoration.none,
  update(value, tr) {
    for (const effect of tr.effects) if (effect.is(setHighlights)) return effect.value
    // Typing: they are of the text before it.
    return tr.docChanged ? Decoration.none : value
  },
  provide: field => EditorView.decorations.from(field),
})

const highlightPlugin = ViewPlugin.fromClass(
  class {
    constructor(view) {
      this.view = view
      this.timer = null
      this.asking = null
    }

    update(update) {
      if (!update.docChanged && !update.selectionSet) return
      if (!featuresOf(update.state).documentHighlight) return
      clearTimeout(this.timer)
      this.asking?.cancel()
      this.timer = setTimeout(() => this.ask(), HIGHLIGHT_MS)
    }

    async ask() {
      const view = this.view
      const state = view.state
      const main = state.selection.main
      const clear = () => {
        if (view.state.field(highlightField, false)?.size) view.dispatch({effects: setHighlights.of(Decoration.none)})
      }
      if (!requester || !main.empty || !state.wordAt(main.head)) return clear()
      const asking = (this.asking = requester.request("documentHighlight", state, {position: toPosition(state, main.head)}))
      const found = await asking
      if (this.asking !== asking || view.state.doc !== state.doc) return
      this.asking = null
      if (!found?.length) return clear()
      const marks = found
        .map(one => ({from: toOffset(state, one.from), to: toOffset(state, one.to), kind: one.kind}))
        .filter(one => one.to > one.from)
        .sort((a, b) => a.from - b.from)
        .map(one => (highlightMarks[one.kind] || highlightMarks.text).range(one.from, one.to))
      view.dispatch({effects: setHighlights.of(Decoration.set(marks, true))})
    }

    destroy() {
      clearTimeout(this.timer)
      this.asking?.cancel()
    }
  },
)

const highlights = [highlightField, highlightPlugin]

// ---- Quick Fix (code actions)

// The range code actions are asked for: the selection, or (none) the
// cursor's whole line – the problems on it are theirs to fix.
const actionRange = state => {
  const main = state.selection.main
  const line = state.doc.lineAt(main.head)
  const [from, to] = main.empty ? [line.from, line.to] : [main.from, main.to]
  return {from: toPosition(state, from), to: toPosition(state, to)}
}

// Ctrl+.: the server asks what can be done there, and offers it.
export const quickFix = view => {
  if (requester) requester.codeActions(view.state, actionRange(view.state))
}

// A lightbulb in the gutter of the cursor's line when something can be
// done there (asked a moment after the cursor rests); a click is Quick Fix.
const LIGHTBULB_MS = 400
const setLightbulb = StateEffect.define()

class Lightbulb extends GutterMarker {
  toDOM() {
    const dom = document.createElement("span")
    dom.className = "cm-language-lightbulb"
    dom.title = "Quick Fix… (Ctrl+.)"
    dom.textContent = "\u{1F4A1}"
    return dom
  }
}
const lightbulb = new Lightbulb()

// What keeps the gutter's width when there is none.
class LightbulbSpace extends GutterMarker {
  toDOM() {
    const dom = document.createElement("span")
    dom.textContent = "\u{1F4A1}"
    dom.style.cssText = "font-size: 0.8em; line-height: 1"
    return dom
  }
}
const lightbulbSpace = new LightbulbSpace()

// The start of the line it is on, or -1.
const lightbulbField = StateField.define({
  create: () => -1,
  update(value, tr) {
    for (const effect of tr.effects) if (effect.is(setLightbulb)) return effect.value
    return tr.docChanged || tr.selection ? -1 : value
  },
})

const lightbulbPlugin = ViewPlugin.fromClass(
  class {
    constructor(view) {
      this.view = view
      this.timer = null
      this.asking = null
    }

    update(update) {
      if (!update.docChanged && !update.selectionSet && !update.focusChanged) return
      clearTimeout(this.timer)
      this.asking?.cancel()
      if (!featuresOf(update.state).codeAction || !update.view.hasFocus) return
      this.timer = setTimeout(() => this.ask(), LIGHTBULB_MS)
    }

    async ask() {
      const view = this.view
      const state = view.state
      if (!requester) return
      const asking = (this.asking = requester.request("codeAction", state, {range: actionRange(state), context: {triggerKind: 2}}))
      const reply = await asking
      if (this.asking !== asking || view.state !== state) return
      this.asking = null
      if (reply?.actions?.some(action => !action.disabled)) {
        view.dispatch({effects: setLightbulb.of(state.doc.lineAt(state.selection.main.head).from)})
      }
    }

    destroy() {
      clearTimeout(this.timer)
      this.asking?.cancel()
    }
  },
)

const lightbulbGutter = gutter({
  class: "cm-language-lightbulbs",
  markers: view => {
    const at = view.state.field(lightbulbField, false) ?? -1
    return at >= 0 && at <= view.state.doc.length ? RangeSet.of([lightbulb.range(at)]) : RangeSet.empty
  },
  initialSpacer: () => lightbulbSpace,
  domEventHandlers: {
    mousedown(view, line) {
      if (view.state.field(lightbulbField, false) !== line.from) return false
      view.focus()
      quickFix(view)
      return true
    },
  },
})

const codeActions = [lightbulbField, lightbulbPlugin, lightbulbGutter]

// ---- Rename Symbol

// F2: the server asks what is renamed, then its new name, and renames.
export const rename = view => {
  if (requester) requester.rename(view.state, toPosition(view.state, view.state.selection.main.head))
}

// ---- Go to definition

// F12, and its relatives: the server opens the place (or asks which).
export const goTo = (view, feature, pos = view.state.selection.main.head) => {
  if (requester) requester.goTo(feature, view.state, toPosition(view.state, pos))
}

// Ctrl+click (Cmd on a Mac) goes to the definition, as in VS Code; another
// cursor is added with Alt+click.
const clicks = [
  EditorView.clickAddsSelectionRange.of(event => event.altKey && !event.shiftKey),
  Prec.highest(
    EditorView.domEventHandlers({
      mousedown(event, view) {
        if (event.button !== 0 || !(event.ctrlKey || event.metaKey) || event.altKey || event.shiftKey) return false
        const pos = view.posAtCoords({x: event.clientX, y: event.clientY})
        if (pos === null) return false
        event.preventDefault()
        view.dispatch({selection: {anchor: pos}})
        if (featuresOf(view.state).definition) goTo(view, "definition", pos)
        return true
      },
    }),
  ),
]

const theme = EditorView.baseTheme({
  ".cm-language-info": {maxWidth: "36rem", maxHeight: "20rem", overflow: "auto", padding: "4px 8px"},
  ".cm-language-info > * + *": {marginTop: "4px", paddingTop: "4px", borderTop: "1px solid color-mix(in srgb, currentColor 15%, transparent)"},
  ".cm-language-signature": {fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace", whiteSpace: "pre-wrap"},
  ".cm-language-parameter": {textDecoration: "underline"},
  ".cm-language-lightbulbs": {width: "1.2em"},
  ".cm-language-lightbulb": {cursor: "pointer", fontSize: "0.8em", lineHeight: "1"},
  ".cm-language-highlight": {backgroundColor: "color-mix(in srgb, currentColor 14%, transparent)", borderRadius: "2px"},
  ".cm-language-highlight-write": {backgroundColor: "color-mix(in srgb, currentColor 24%, transparent)"},
  ".cm-language-doc": {fontSize: "0.9em"},
  ".cm-language-doc pre": {whiteSpace: "pre-wrap"},
  ".cm-language-doc h1, .cm-language-doc h2, .cm-language-doc h3, .cm-language-doc h4": {
    fontSize: "1.05em",
    fontWeight: "600",
    margin: "6px 0 2px",
    border: "none",
    padding: "0",
  },
})

// For every file's state; `features`: what there is for the file so far.
export const languageFeatures = features => [
  featuresField.init(() => features || {}),
  EditorState.languageData.of(() => completionData),
  hover,
  keyboardHover,
  signatureHelp,
  highlights,
  codeActions,
  clicks,
  theme,
]

export {startCompletion}
