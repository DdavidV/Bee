// Completion and hover in JSON files from their JSON schemas
// (Bee.JSONValidation.Assist on the server, which has the schemas). The
// CodeEditor hook answers `request(kind, view, pos)` – it sends the file's
// text first, then asks – with what the server says, in UTF-8 bytes:
//
//   complete  {from, to, items: [{label, display, detail, info, snippet}]}
//   hover     {from, to, text}
//
// A completion inserts its `snippet` (VS Code's syntax, editor/snippets.js).

import {EditorState} from "@codemirror/state"
import {hoverTooltip} from "@codemirror/view"
import {insertSnippet} from "./snippets"
import {fromBytes} from "./offsets"

let request = null
// The hook's request function: (kind, view or state, pos) => Promise.
export const setJsonRequester = fn => (request = fn)

const toOffsets = (doc, from, to) => {
  const offsets = fromBytes(doc, [from, to])
  return offsets.has(from) && offsets.has(to) ? [offsets.get(from), offsets.get(to)] : null
}

// The end of the key or value being completed from `from`, the cursor at
// `to`: past its closing quote, or the rest of a word (true, 12…).
const tokenEnd = (state, from, to) => {
  const rest = state.sliceDoc(to, Math.min(state.doc.length, to + 500))
  const m = state.sliceDoc(from, from + 1) === '"' ? /^[^"\n]*"/.exec(rest) : /^[\w.+-]*/.exec(rest)
  return m ? to + m[0].length : to
}

const complete = async context => {
  if (!request) return null
  // Not on every key: after a quote, a colon, a comma or a bracket, inside
  // a word, or when asked.
  if (!context.explicit && !context.matchBefore(/["\w:,[{]\s*$|"[^"\n]*$/)) return null
  const reply = await request("complete", context.state, context.pos)
  if (context.aborted || !reply?.items?.length) return null
  const range = toOffsets(context.state.doc.toString(), reply.from, reply.to)
  if (!range) return null
  // CodeMirror filters by the text from `from` to the cursor; an item
  // replaces it up to the end of the key or value (tokenEnd).
  const [from] = range
  return {
    from,
    options: reply.items.map(item => ({
      label: item.label,
      displayLabel: item.display,
      detail: item.detail || undefined,
      info: item.info || undefined,
      type: item.label.startsWith('"') && item.snippet.includes(":") ? "property" : "constant",
      apply: (view, completion, from, to) =>
        insertSnippet(view, item.snippet, from, tokenEnd(view.state, from, to), completion),
    })),
  }
}

const hover = hoverTooltip(async (view, pos) => {
  if (!request) return null
  const reply = await request("hover", view.state, pos)
  if (!reply?.text) return null
  const range = toOffsets(view.state.doc.toString(), reply.from, reply.to)
  if (!range) return null
  return {
    pos: range[0],
    end: range[1],
    create: () => {
      const dom = document.createElement("div")
      dom.className = "cm-json-hover"
      dom.style.cssText = "max-width: 32rem; padding: 4px 8px; white-space: pre-wrap"
      dom.textContent = reply.text
      return {dom}
    },
  }
})

// For a JSON file (`json`: Bee.JSONValidation validates its language).
export const jsonAssist = json =>
  json ? [EditorState.languageData.of(() => jsonData), hover] : []

// One source for good (CodeMirror tells sources apart by identity).
const jsonData = [{autocomplete: complete}]
