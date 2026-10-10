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

import {StateField, StateEffect, EditorState, Prec} from "@codemirror/state"
import {EditorView, hoverTooltip, showTooltip} from "@codemirror/view"
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
  clicks,
  theme,
]

export {startCompletion}
