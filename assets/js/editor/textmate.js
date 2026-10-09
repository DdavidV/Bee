// TextMate grammars in CodeMirror, like VS Code highlights: vscode-textmate
// runs the grammars (with the Oniguruma regex engine, WebAssembly), and the
// color theme's tokenColors color the tokens.
//
// The server says which grammars there are (`setGrammars`: scope name ->
// {url, injectTo}, from plugins' `grammars` contributions, Bee.Languages)
// and the theme's rules (`setTokenColors`); a file highlighted by a grammar
// gets `textmate(scopeName)` instead of a CodeMirror mode.
//
// Each file's state keeps every line's tokens and the tokenizer's state at
// its end (`tokenCache`), so switching tabs costs nothing. An edit
// tokenizes again from its line, and stops at the first unchanged line
// that ends in the same state as before: the rest stays as it was. What
// is shown is tokenized first (BUDGET_MS at a time, then in the next
// task), the rest of the file when the browser is idle, so typing never
// waits for it. Lines longer than MAX_LINE aren't tokenized (VS Code's
// editor.maxTokenizationLineLength).

import {Registry, INITIAL, parseRawGrammar} from "vscode-textmate"
import {loadWASM, OnigScanner, OnigString} from "vscode-oniguruma"
import onigWasmUrl from "vscode-oniguruma/release/onig.wasm"
import {StateField, StateEffect, RangeSetBuilder} from "@codemirror/state"
import {ViewPlugin, Decoration} from "@codemirror/view"

const BUDGET_MS = 20
const MAX_LINE = 20000
const LINE_TIME_LIMIT_MS = 500

let grammars = {} // scope -> {scope, url, injectTo}
let grammarsJson = "{}"
let tokenColors = []
let tokenColorsJson = "[]"
let registry = null
// Bumped when grammars or colors change: every file tokenizes again.
let generation = 0
const listeners = new Set()

let onig = null
const onigLib = () =>
  (onig ??= fetch(onigWasmUrl)
    .then(response => {
      if (!response.ok) throw new Error(`can't load ${onigWasmUrl}: ${response.status}`)
      return response.arrayBuffer()
    })
    .then(data => loadWASM(data))
    .then(() => ({
      createOnigScanner: patterns => new OnigScanner(patterns),
      createOnigString: text => new OnigString(text),
    })))

const theme = () => ({name: "bee", settings: tokenColors})

const getRegistry = () =>
  (registry ??= new Registry({
    onigLib: onigLib(),
    theme: theme(),
    loadGrammar: async scope => {
      const grammar = grammars[scope]
      if (!grammar) return null
      const response = await fetch(grammar.url)
      if (!response.ok) throw new Error(`${grammar.url}: ${response.status}`)
      // The path's extension says JSON or plist.
      return parseRawGrammar(await response.text(), decodeURIComponent(new URL(grammar.url, location.href).pathname))
    },
    getInjections: scope =>
      Object.values(grammars)
        .filter(g => g.injectTo?.includes(scope))
        .map(g => g.scope),
  }))

// Loaded grammars by scope, for this generation.
let loaded = new Map()

const loadGrammar = scope => {
  if (!loaded.has(scope)) {
    loaded.set(
      scope,
      getRegistry()
        .loadGrammar(scope)
        .catch(e => {
          console.error(`Bee: TextMate grammar ${scope}`, e)
          return null
        }),
    )
  }
  return loaded.get(scope)
}

const changed = () => {
  generation++
  updateStyles()
  listeners.forEach(listener => listener())
}

// The grammars there are; files using a changed one tokenize again.
export const setGrammars = table => {
  const json = JSON.stringify(table || {})
  if (json === grammarsJson) return
  grammarsJson = json
  grammars = table || {}
  registry = null
  loaded = new Map()
  changed()
}

// The color theme's tokenColors rules (the first one: the editor's colors).
export const setTokenColors = rules => {
  const json = JSON.stringify(rules || [])
  if (json === tokenColorsJson) return
  tokenColorsJson = json
  tokenColors = rules || []
  registry?.setTheme(theme())
  changed()
}

export const onTextMateChange = listener => {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

// Token colors as classes: tm-f<index> (the registry's color map), and
// font styles. The default foreground (1) gets none: the editor's color.
let styleElement = null
const updateStyles = () => {
  if (!registry) return
  styleElement ??= document.head.appendChild(document.createElement("style"))
  styleElement.id = "bee-textmate"
  const colors = registry.getColorMap()
  const rules = colors.map((color, i) => (i > 1 && color ? `.tm-f${i}{color:${color}}` : "")).join("")
  styleElement.textContent =
    rules +
    ".tm-i{font-style:italic}.tm-b{font-weight:bold}.tm-u{text-decoration:underline}" +
    ".tm-s{text-decoration:line-through}.tm-u.tm-s{text-decoration:underline line-through}"
}

const marks = new Map()
const mark = (foreground, fontStyle) => {
  const key = foreground * 16 + fontStyle
  if (!marks.has(key)) {
    const classes = []
    if (foreground > 1) classes.push(`tm-f${foreground}`)
    if (fontStyle & 1) classes.push("tm-i")
    if (fontStyle & 2) classes.push("tm-b")
    if (fontStyle & 4) classes.push("tm-u")
    if (fontStyle & 8) classes.push("tm-s")
    marks.set(key, Decoration.mark({class: classes.join(" ")}))
  }
  return marks.get(key)
}

// Counters, for tests and debugging (window.__beeTextMate).
const stats = {tokenizedLines: 0}
if (typeof window !== "undefined") window.__beeTextMate = stats

// Per file: `lines[i]` = {tokens, end} for line i+1 (tokens as
// tokenizeLine2 gives them, `end` the tokenizer's state after the line),
// or null. The first `valid` are up to date; the ones after are from
// before an edit (moved with their lines; null for changed lines): shown
// until tokenized again, and kept when tokenizing again reaches an
// unchanged line in the same state as before – then all lines up to the
// next changed one are valid as they are, like VS Code does. Where
// tokenizing again stopped short of that, the old line after the new ones
// is `broken`: it followed another version of the line before it, so the
// lines after an equal state are only valid up to it.
const tokenCache = StateField.define({
  create: () => ({generation, scope: null, lines: [], valid: 0}),
  update(cache, tr) {
    if (!tr.docChanged) return cache
    let fromA = Infinity
    let toA = 0
    let toB = 0
    tr.changes.iterChangedRanges((fa, ta, _fb, tb) => {
      fromA = Math.min(fromA, fa)
      toA = Math.max(toA, ta)
      toB = Math.max(toB, tb)
    })
    const first = tr.startState.doc.lineAt(fromA).number
    const valid = Math.min(cache.valid, first - 1)
    const {lines} = cache
    if (lines.length < first) return {...cache, lines: lines.slice(), valid}

    const lastOld = tr.startState.doc.lineAt(toA).number
    const lastNew = tr.state.doc.lineAt(toB).number
    return {
      ...cache,
      lines: lines.slice(0, first - 1).concat(new Array(lastNew - first + 1).fill(null), lines.slice(lastOld)),
      valid,
    }
  },
})

const refresh = StateEffect.define()

// Background work when the browser is idle (setTimeout where there's no
// requestIdleCallback, as in some webviews).
const idle = callback =>
  typeof requestIdleCallback === "function"
    ? requestIdleCallback(deadline => callback(Math.min(BUDGET_MS, deadline.timeRemaining())))
    : setTimeout(() => callback(BUDGET_MS), 50)

const plugin = scope =>
  ViewPlugin.fromClass(
    class {
      constructor(view) {
        this.view = view
        this.grammar = null
        this.generation = -1
        this.scheduled = false
        this.decorations = Decoration.none
        this.load()
      }

      load() {
        const generation_ = generation
        this.generation = generation_
        this.grammar = null
        loadGrammar(scope).then(grammar => {
          if (this.destroyed || this.generation !== generation_) return
          this.grammar = grammar
          updateStyles()
          this.view.dispatch({effects: refresh.of(null)})
        })
      }

      update(update) {
        if (this.generation !== generation) this.load()
        if (
          update.docChanged ||
          update.viewportChanged ||
          update.transactions.some(tr => tr.effects.some(e => e.is(refresh)))
        ) {
          this.decorations = this.build()
        }
      }

      cache() {
        const cache = this.view.state.field(tokenCache)
        // Tokens of another grammar (the file's language changed) or
        // another generation are dropped.
        if (cache.generation !== generation || cache.scope !== scope) {
          cache.generation = generation
          cache.scope = scope
          cache.lines.length = 0
          cache.valid = 0
        }
        return cache
      }

      lastShown() {
        return this.view.state.doc.lineAt(this.view.viewport.to).number
      }

      // Tokenizes up to line `last` (1-based), for at most `budget` ms;
      // whether it got there.
      tokenize(last, budget) {
        const cache = this.cache()
        const {lines} = cache
        const doc = this.view.state.doc
        const start = performance.now()
        while (cache.valid < last) {
          const i = cache.valid
          const state = i ? lines[i - 1].end : INITIAL
          const text = doc.line(i + 1).text
          const old = lines[i]
          let entry
          if (text.length > MAX_LINE) {
            entry = {tokens: null, end: state}
          } else {
            const result = this.grammar.tokenizeLine2(text, state, LINE_TIME_LIMIT_MS)
            entry = {tokens: result.tokens, end: result.ruleStack}
          }
          stats.tokenizedLines++
          lines[i] = entry
          cache.valid = i + 1
          // Unchanged and ending as before: so do the lines after it, up
          // to the next changed or broken one.
          if (old && old.end.equals(entry.end)) {
            let next = i + 1
            while (next < lines.length && lines[next] && !lines[next].broken) next++
            cache.valid = next
          }
          if (performance.now() - start > budget) break
        }
        // Stopped before the old lines: the first of them was tokenized
        // after another line than the one before it now; see tokenCache.
        const next = lines[cache.valid]
        if (next && !next.broken && cache.valid > 0) lines[cache.valid] = {...next, broken: true}
        return cache.valid >= last
      }

      build() {
        if (!this.grammar) return Decoration.none
        const view = this.view
        const doc = view.state.doc
        if (!this.tokenize(this.lastShown(), BUDGET_MS) || this.cache().valid < doc.lines) this.schedule()

        const {lines} = this.cache()
        const builder = new RangeSetBuilder()
        // The whole viewport (the lines rendered), not just what's visible:
        // they're tokenized anyway, and scrolling shows no uncolored line.
        for (const {from, to} of [view.viewport]) {
          const end = doc.lineAt(to).number
          for (let n = doc.lineAt(from).number; n <= end && n <= lines.length; n++) {
            const tokens = lines[n - 1]?.tokens
            if (!tokens) continue
            const line = doc.line(n)
            const count = tokens.length / 2
            for (let i = 0; i < count; i++) {
              const metadata = tokens[2 * i + 1]
              const foreground = (metadata >>> 15) & 0x1ff
              const fontStyle = (metadata >>> 11) & 0xf
              if (foreground <= 1 && fontStyle === 0) continue
              const tokenFrom = line.from + tokens[2 * i]
              const tokenTo = Math.min(i + 1 < count ? line.from + tokens[2 * i + 2] : line.to, line.to)
              if (tokenTo > tokenFrom) builder.add(tokenFrom, tokenTo, mark(foreground, fontStyle))
            }
          }
        }
        return builder.finish()
      }

      // The rest, in slices: what's shown right away (then shown again),
      // the lines after it when the browser is idle, to the end of the file.
      schedule() {
        if (this.scheduled) return
        this.scheduled = true
        const shownDone = this.cache().valid >= this.lastShown()
        const run = budget => {
          this.scheduled = false
          if (this.destroyed || !this.grammar) return
          const last = this.lastShown()
          const wasShown = this.cache().valid >= last
          this.tokenize(this.view.state.doc.lines, budget)
          if (!wasShown && this.cache().valid >= last) this.view.dispatch({effects: refresh.of(null)})
          if (this.cache().valid < this.view.state.doc.lines) this.schedule()
        }
        if (shownDone) idle(run)
        else setTimeout(() => run(BUDGET_MS), 0)
      }

      destroy() {
        this.destroyed = true
      }
    },
    {decorations: v => v.decorations},
  )

// The extension highlighting a file with grammar `scope`.
export const textmate = scope => [tokenCache, plugin(scope)]
