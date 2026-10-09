// A language's configuration – VS Code's language-configuration.json, as
// Bee.Languages.configuration/1 sends it – in CodeMirror:
//
//   comments           commentTokens: Ctrl+/ and Shift+Alt+A toggle them
//   autoClosingPairs   closeBrackets: the pairs CodeMirror can close (one
//                      character, or a triple quote, closed by its usual
//                      partner); autoCloseBefore is where it does
//   onEnterRules       Enter: the first rule matching the text before (and
//                      after) the cursor and the line above says how to
//                      indent the new line and what to add to it
//   indentationRules   the indentation of a new or re-indented line; typing
//                      what decreaseIndentPattern matches re-indents
//   folding            markers (#region …), else by indentation, like VS Code
//
// Indentation and folding only for a file without a syntax tree (a TextMate
// grammar, or no highlighting): CodeMirror's languages bring their own.
// The comments and pairs of one of those languages win over these.

import {EditorState, Prec} from "@codemirror/state"
import {keymap} from "@codemirror/view"
import {indentService, foldService, getIndentUnit, indentString} from "@codemirror/language"

const regex = r => {
  if (!r) return null
  try {
    return new RegExp(r.pattern, (r.flags || "").replace(/[^imsuy]/g, ""))
  } catch (e) {
    console.warn(`Bee: language configuration: bad regex ${r.pattern}`, e)
    return null
  }
}

// The closing character closeBrackets inserts for `open` (its own rule).
const PARTNERS = "()[]{}<>«»»«［］｛｝"
const partner = open => {
  const i = PARTNERS.indexOf(open)
  return i >= 0 && i % 2 === 0 ? PARTNERS[i + 1] : open
}

const closeBrackets = config => {
  const pairs = config.autoClosingPairs
  if (!pairs) return null
  const brackets = pairs
    .filter(({open, close}) =>
      open.length === 1 ? partner(open) === close : /^('''|""")$/.test(open) && open === close)
    .map(({open}) => open)
  return {brackets, ...(config.autoCloseBefore ? {before: config.autoCloseBefore} : {})}
}

const languageData = (config, tree) => {
  const data = {}
  const {lineComment, blockComment} = config.comments || {}
  if (lineComment || blockComment) {
    data.commentTokens = {
      ...(lineComment ? {line: lineComment} : {}),
      ...(blockComment ? {block: {open: blockComment[0], close: blockComment[1]}} : {}),
    }
  }
  const close = closeBrackets(config)
  if (close) data.closeBrackets = close
  const decrease = regex(config.indentationRules?.decreaseIndentPattern)
  if (!tree && decrease) data.indentOnInput = decrease
  return Object.keys(data).length ? Prec.low(EditorState.languageData.of(() => [data])) : []
}

// The indentation (columns) of a line's text.
const columns = (text, tabSize) => {
  let n = 0
  for (const ch of text) {
    if (ch === " ") n++
    else if (ch === "\t") n += tabSize - (n % tabSize)
    else break
  }
  return n
}

const indentation = rules => {
  const increase = regex(rules.increaseIndentPattern)
  const decrease = regex(rules.decreaseIndentPattern)
  const next = regex(rules.indentNextLinePattern)
  const unindented = regex(rules.unIndentedLinePattern)
  if (!increase && !decrease && !next) return []

  const usable = text => /\S/.test(text) && !unindented?.test(text)

  return indentService.of((cx, pos) => {
    const line = cx.lineAt(pos)
    // The line before it that counts, and the one before that.
    const before = from => {
      while (from > 0) {
        const l = cx.lineAt(from - 1, -1)
        if (usable(l.text)) return l
        from = l.from
      }
      return null
    }
    const prev = before(line.from)
    if (!prev) return 0
    let indent = cx.lineIndent(prev.from, -1)
    if (increase?.test(prev.text) || next?.test(prev.text)) {
      indent += cx.unit
    } else if (next) {
      // The line after a one-line indent (indentNextLinePattern) goes back.
      const prev2 = before(prev.from)
      if (prev2 && next.test(prev2.text) && !increase?.test(prev2.text)) indent -= cx.unit
    }
    if (decrease?.test(line.text)) indent -= cx.unit
    return Math.max(0, indent)
  })
}

const onEnter = rules => {
  const compiled = rules
    .map(r => ({
      before: regex(r.beforeText),
      after: regex(r.afterText),
      previous: regex(r.previousLineText),
      action: r.action,
    }))
    .filter(r => r.before)
  if (!compiled.length) return []

  return Prec.high(
    keymap.of([
      {
        key: "Enter",
        run: view => {
          const {state} = view
          const range = state.selection.main
          if (state.selection.ranges.length > 1 || !range.empty) return false
          const line = state.doc.lineAt(range.head)
          const before = line.text.slice(0, range.head - line.from)
          const after = line.text.slice(range.head - line.from)
          const previous = line.number > 1 ? state.doc.line(line.number - 1).text : ""
          const rule = compiled.find(
            r => r.before.test(before) && (!r.after || r.after.test(after)) && (!r.previous || r.previous.test(previous)),
          )
          if (!rule) return false

          const unit = indentString(state, getIndentUnit(state))
          const base = /^\s*/.exec(line.text)[0]
          const outdent = text => (text.endsWith(unit) ? text.slice(0, -unit.length) : text.replace(/[ \t]{1,4}$/, ""))
          const {indent, appendText = "", removeText = 0} = rule.action
          let insert
          let cursor
          if (indent === "indentOutdent") {
            const first = "\n" + base + unit + appendText
            insert = first + "\n" + base
            cursor = first.length
          } else {
            let lead = indent === "indent" ? base + unit : indent === "outdent" ? outdent(base) : base
            if (removeText) lead = lead.slice(0, Math.max(0, lead.length - removeText))
            insert = "\n" + lead + appendText
            cursor = insert.length
          }
          view.dispatch({
            changes: {from: range.head, insert},
            selection: {anchor: range.head + cursor},
            scrollIntoView: true,
            userEvent: "input",
          })
          return true
        },
      },
    ]),
  )
}

const MAX_FOLD_LINES = 10000

const folding = folding_ => {
  const start = regex(folding_?.markers?.start)
  const end = regex(folding_?.markers?.end)

  return foldService.of((state, lineStart, lineEnd) => {
    const doc = state.doc
    const line = doc.lineAt(lineStart)
    const last = Math.min(doc.lines, line.number + MAX_FOLD_LINES)

    // A region: to its end marker (nested ones counted).
    if (start && end && start.test(line.text)) {
      let depth = 1
      for (let n = line.number + 1; n <= last; n++) {
        const text = doc.line(n).text
        if (start.test(text)) depth++
        else if (end.test(text) && --depth === 0) return {from: lineEnd, to: doc.line(n).to}
      }
      return null
    }

    // By indentation: the lines after it indented deeper.
    if (!/\S/.test(line.text)) return null
    const tabSize = state.tabSize
    const indent = columns(line.text, tabSize)
    let to = null
    for (let n = line.number + 1; n <= last; n++) {
      const text = doc.line(n).text
      if (!/\S/.test(text)) continue
      if (columns(text, tabSize) <= indent) break
      to = doc.line(n).to
    }
    return to === null ? null : {from: lineEnd, to}
  })
}

// The extensions for `config` (nil: none); `tree`: the file has a syntax
// tree (a CodeMirror language), which indents and folds by itself.
export const languageConfig = (config, tree) => {
  if (!config) return []
  return [
    languageData(config, tree),
    onEnter(config.onEnterRules || []),
    tree ? [] : [indentation(config.indentationRules || {}), folding(config.folding)],
  ]
}
