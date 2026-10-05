// The git plugin's browser part: GitLens-style blame and VS Code's change
// markers, as CodeMirror extensions. The data comes from the server part
// (BeeGit.handle_request/4): `blame` and `diff` of the file's current text,
// `commit` details for the hover. They are reloaded when the text changes
// (after a pause) and when the repository changes (a message from the
// server part).
//
//   * current line blame: "You, 5 minutes ago • message" after the line
//   * hover on it: hash, author, date and the full commit message
//   * Git: Toggle File Blame (Ctrl+Alt+B): who changed each block of lines
//     when, in a gutter
//   * gutter bars: added (green), modified (blue), deleted (red triangle);
//     clicking one peeks at the change: the old lines (red) and the new ones
//     (green) in a panel below it, with Stage Change, Revert Change,
//     Next / Previous Change and Close (Escape) – VS Code's quick diff peek

const UNCOMMITTED = "0".repeat(40)
const RELOAD_MS = 800

export function activate(bee) {
  const {state: cmState, view: cmView} = bee.codemirror
  const {StateEffect, StateField} = cmState
  const {Decoration, ViewPlugin, WidgetType, EditorView, GutterMarker, gutter, keymap, showTooltip} =
    cmView

  const cache = new Map() // path -> {blame, diff}
  const pending = new Map() // path -> Promise
  const commits = new Map() // hash -> Promise of details
  const options = {lineBlame: true, fileBlame: false}
  const refresh = StateEffect.define() // new data or options: redraw

  const load = path => {
    if (!path) return Promise.resolve(null)
    if (!pending.has(path)) {
      const job = Promise.all([
        bee.request("blame", {path}).catch(() => null),
        bee.request("diff", {path}).catch(() => null),
      ]).then(([blame, diff]) => {
        cache.set(path, {blame, diff})
        pending.delete(path)
        return cache.get(path)
      })
      pending.set(path, job)
    }
    return pending.get(path)
  }

  const dataOf = editorState => cache.get(bee.editor.pathOf(editorState)) || {}

  // The active editor shows `path`: redraw it with the new data.
  const redraw = () => {
    const view = bee.editor.view
    if (view) view.dispatch({effects: refresh.of(null)})
  }

  const reload = path => {
    cache.delete(path)
    pending.delete(path)
    load(path).then(() => bee.editor.path === path && redraw())
  }

  // The repository changed (commit, checkout, …): everything is stale.
  bee.onMessage(() => {
    cache.clear()
    pending.clear()
    commits.clear()
    const path = bee.editor.path
    if (path) load(path).then(redraw)
  })

  // Loads data for each file shown, and again after edits.
  const loader = ViewPlugin.fromClass(
    class {
      constructor(view) {
        this.path = bee.editor.pathOf(view.state)
        this.timer = null
        if (!cache.has(this.path)) load(this.path).then(() => this.alive && redraw())
        this.alive = true
      }
      update(u) {
        if (!u.docChanged) return
        clearTimeout(this.timer)
        this.timer = setTimeout(() => reload(this.path), RELOAD_MS)
      }
      destroy() {
        this.alive = false
        clearTimeout(this.timer)
      }
    }
  )

  const blameOfLine = (editorState, line) => {
    const {blame} = dataOf(editorState)
    if (!blame) return null
    const hash = blame.lines[line - 1]
    return hash ? {hash, ...blame.commits[hash]} : null
  }

  const describe = commit =>
    commit.hash === UNCOMMITTED
      ? "You, Uncommitted changes"
      : `${commit.author}, ${commit.relative} • ${commit.summary}`

  // Current line blame: CSS text after the line (::after, from a line
  // attribute), not a widget – it isn't part of the text, so the cursor
  // never lands behind it, as with VS Code's `after` decorations.
  const lineBlame = ViewPlugin.fromClass(
    class {
      constructor(view) {
        this.decorations = this.build(view)
      }
      update(u) {
        if (u.docChanged || u.selectionSet || u.transactions.some(t => t.effects.some(e => e.is(refresh))))
          this.decorations = this.build(u.view)
      }
      build(view) {
        const {blame} = dataOf(view.state)
        if (!options.lineBlame || !blame || !blame.inline) return Decoration.none
        const head = view.state.selection.main.head
        const line = view.state.doc.lineAt(head)
        const commit = blameOfLine(view.state, line.number)
        if (!commit) return Decoration.none
        // An empty line holds a <br> (for its height and the cursor): after
        // it, the blame would go to the next row – so it gets placed there.
        const className = line.length === 0 ? "bee-git-blamed bee-git-blamed-empty" : "bee-git-blamed"
        const blamed = Decoration.line({class: className, attributes: {"data-blame": describe(commit)}})
        return Decoration.set([blamed.range(line.from)])
      }
    },
    {decorations: v => v.decorations}
  )

  // Hovering the blame (anywhere right of the cursor line's text) shows the
  // commit. The blame isn't text, so this watches the mouse itself.
  const setHover = StateEffect.define()
  let hoverTimer = null

  const hoverField = StateField.define({
    create: () => null,
    update(value, tr) {
      for (const e of tr.effects) if (e.is(setHover)) return e.value
      return tr.docChanged || tr.selection ? null : value
    },
    provide: field => showTooltip.from(field, value => value?.tooltip ?? null),
  })

  const overBlame = (view, event) => {
    const head = view.state.selection.main.head
    const line = view.state.doc.lineAt(head)
    const end = view.coordsAtPos(line.to)
    if (!end || event.clientY < end.top || event.clientY > end.bottom) return null
    return event.clientX > end.right + view.defaultCharacterWidth ? line : null
  }

  const hoverHandlers = EditorView.domEventHandlers({
    mousemove(event, view) {
      const line = overBlame(view, event)
      const current = view.state.field(hoverField, false)
      if (!line) {
        if (current) view.dispatch({effects: setHover.of(null)})
        return false
      }
      if (current && current.line === line.number) return false
      const commit = blameOfLine(view.state, line.number)
      if (!commit || !dataOf(view.state).blame?.inline || !options.lineBlame) return false
      clearTimeout(hoverTimer)
      hoverTimer = setTimeout(async () => {
        const details = commit.hash === UNCOMMITTED ? null : await commitDetails(commit.hash)
        // Still there?
        if (view.state.doc.lineAt(view.state.selection.main.head).number !== line.number) return
        const dom = tooltip(commit, details)
        view.dispatch({
          effects: setHover.of({line: line.number, tooltip: {pos: line.to, above: true, create: () => ({dom})}}),
        })
      }, 250)
      return false
    },
    mouseleave(_event, view) {
      clearTimeout(hoverTimer)
      if (view.state.field(hoverField, false)) view.dispatch({effects: setHover.of(null)})
      return false
    },
  })

  const commitDetails = hash => {
    if (!commits.has(hash)) commits.set(hash, bee.request("commit", {hash}).catch(() => null))
    return commits.get(hash)
  }

  const tooltip = (commit, details) => {
    const dom = document.createElement("div")
    dom.className = "bee-git-hover"
    const head = document.createElement("div")
    head.className = "bee-git-hover-head"
    const body = document.createElement("div")
    body.className = "bee-git-hover-message"
    if (commit.hash === UNCOMMITTED) {
      head.textContent = "You · Uncommitted changes"
      body.textContent = "This line has changes that aren't committed yet."
    } else {
      const date = new Date((details?.time ?? commit.time) * 1000)
      head.textContent = `${commit.author}${details?.mail ? ` <${details.mail}>` : ""} · ${commit.relative} (${date.toLocaleString()})`
      body.textContent = details?.message ?? commit.summary
      const hash = document.createElement("div")
      hash.className = "bee-git-hover-hash"
      hash.textContent = `commit ${commit.hash.slice(0, 8)}`
      dom.append(hash)
    }
    dom.prepend(head)
    dom.append(body)
    return dom
  }

  // File blame gutter: author and age at the first line of each block.
  class TextMarker extends GutterMarker {
    constructor(text, title) {
      super()
      this.text = text
      this.title = title
    }
    eq(other) {
      return other.text === this.text && other.title === this.title
    }
    toDOM() {
      const span = document.createElement("span")
      span.textContent = this.text
      span.title = this.title
      return span
    }
  }

  const redrawn = u => u.transactions.some(t => t.effects.some(e => e.is(refresh))) || u.docChanged

  const fileBlame = gutter({
    class: "bee-git-file-blame",
    lineMarker(view, block) {
      if (!options.fileBlame) return null
      const line = view.state.doc.lineAt(block.from).number
      const commit = blameOfLine(view.state, line)
      if (!commit) return null
      const previous = line > 1 ? blameOfLine(view.state, line - 1) : null
      if (previous && previous.hash === commit.hash) return new TextMarker("", "")
      const who = commit.hash === UNCOMMITTED ? "You" : commit.author
      const when = commit.hash === UNCOMMITTED ? "now" : commit.relative.replace(/ ago$/, "")
      return new TextMarker(`${who.slice(0, 14)} · ${when}`, describe(commit))
    },
    lineMarkerChange: redrawn,
  })

  // Change markers.
  class ChangeMarker extends GutterMarker {
    constructor(kind) {
      super()
      this.kind = kind
    }
    eq(other) {
      return other.kind === this.kind
    }
    toDOM() {
      const span = document.createElement("span")
      span.className = `bee-git-change bee-git-${this.kind}`
      return span
    }
  }

  const markers = {added: new ChangeMarker("added"), modified: new ChangeMarker("modified"), deleted: new ChangeMarker("deleted")}

  const changeOfLine = (editorState, line) => {
    const {diff} = dataOf(editorState)
    if (!diff) return null
    if (diff.added.some(([from, to]) => line >= from && line <= to)) return "added"
    if (diff.modified.some(([from, to]) => line >= from && line <= to)) return "modified"
    if (diff.deleted.includes(line) || (line === 1 && diff.deleted.includes(0))) return "deleted"
    return null
  }

  const changes = gutter({
    class: "bee-git-changes",
    lineMarker(view, block) {
      const kind = changeOfLine(view.state, view.state.doc.lineAt(block.from).number)
      return kind ? markers[kind] : null
    },
    lineMarkerChange: redrawn,
    domEventHandlers: {
      mousedown(view, block) {
        const index = hunkAt(view.state, view.state.doc.lineAt(block.from).number)
        if (index < 0) return false
        const open = view.state.field(peek)
        view.dispatch({effects: open && open.index === index ? closePeek.of(null) : openPeek.of(index)})
        return true
      },
    },
  })

  // The change peek.
  const hunksOf = editorState => dataOf(editorState).diff?.hunks || []

  // The hunk whose marker is on `line`.
  const hunkAt = (editorState, line) =>
    hunksOf(editorState).findIndex(h =>
      h.new_count === 0
        ? Math.max(h.new_start, 1) === line
        : line >= h.new_start && line < h.new_start + h.new_count
    )

  const openPeek = StateEffect.define()
  const closePeek = StateEffect.define()

  // {index} of the peeked hunk, or null. Edits close it (the hunks move).
  const peek = StateField.define({
    create: () => null,
    update(value, tr) {
      for (const e of tr.effects) {
        if (e.is(openPeek)) return {index: e.value}
        if (e.is(closePeek)) return null
        // New data: rebuild the panel from it.
        if (e.is(refresh) && value) return {...value}
      }
      return tr.docChanged ? null : value
    },
    provide: field =>
      EditorView.decorations.compute([field], editorState => {
        const value = editorState.field(field)
        const hunk = value && hunksOf(editorState)[value.index]
        if (!hunk) return Decoration.none
        const doc = editorState.doc
        // Below the hunk's last line (a deletion: below the line before it).
        const last = hunk.new_count === 0 ? hunk.new_start : hunk.new_start + hunk.new_count - 1
        const widget = new PeekWidget(editorState, value.index, hunk)
        if (last < 1) return Decoration.set([Decoration.widget({widget, block: true, side: -1}).range(0)])
        const pos = doc.line(Math.min(last, doc.lines)).to
        return Decoration.set([Decoration.widget({widget, block: true, side: 1}).range(pos)])
      }),
  })

  const newLines = (editorState, hunk) => {
    const lines = []
    for (let n = hunk.new_start; n < hunk.new_start + hunk.new_count; n++) lines.push(editorState.doc.line(n).text)
    return lines
  }

  // Puts the hunk's old lines back (an ordinary, undoable edit).
  const revert = (view, hunk) => {
    const doc = view.state.doc
    const old = hunk.old_lines.join("\n")
    let change
    if (hunk.new_count === 0) {
      change = hunk.new_start === 0 ? {from: 0, insert: old + "\n"} : {from: doc.line(hunk.new_start).to, insert: "\n" + old}
    } else {
      const first = doc.line(hunk.new_start)
      const last = doc.line(hunk.new_start + hunk.new_count - 1)
      if (hunk.old_count > 0) change = {from: first.from, to: last.to, insert: old}
      // Added lines: remove them with their line break.
      else if (last.number < doc.lines) change = {from: first.from, to: last.to + 1}
      else change = {from: Math.max(first.from - 1, 0), to: last.to}
    }
    view.dispatch({changes: change, effects: closePeek.of(null)})
    view.focus()
  }

  // Sends the lines the peek shows: the server's copy of the text may be a
  // moment behind the editor.
  const stage = (view, hunk, lines) => {
    const path = bee.editor.pathOf(view.state)
    const {old_start, old_count, old_lines} = hunk
    bee
      .request("stageHunk", {path, hunk: {old_start, old_count, old_lines}, lines})
      .then(() => view.dispatch({effects: closePeek.of(null)}))
      .catch(e => bee.showMessage(`Git: ${e.message}`, "error"))
  }

  const move = (view, index, delta) => {
    const count = hunksOf(view.state).length
    if (count === 0) return
    const next = (index + delta + count) % count
    const hunk = hunksOf(view.state)[next]
    const line = view.state.doc.line(Math.min(Math.max(hunk.new_start, 1), view.state.doc.lines))
    view.dispatch({effects: [openPeek.of(next), EditorView.scrollIntoView(line.from, {y: "center"})]})
  }

  class PeekWidget extends WidgetType {
    constructor(editorState, index, hunk) {
      super()
      this.index = index
      this.hunk = hunk
      this.count = hunksOf(editorState).length
      this.path = bee.editor.pathOf(editorState)
      this.added = newLines(editorState, hunk)
    }
    eq(other) {
      return (
        other.index === this.index &&
        other.count === this.count &&
        other.hunk.new_start === this.hunk.new_start &&
        other.hunk.new_count === this.hunk.new_count &&
        other.hunk.old_lines.join("\n") === this.hunk.old_lines.join("\n") &&
        other.added.join("\n") === this.added.join("\n")
      )
    }
    ignoreEvent() {
      return true
    }
    toDOM(view) {
      const dom = el("div", "bee-git-peek")
      const head = el("div", "bee-git-peek-head")
      const name = (this.path || "").split("/").pop()
      const title = el("span", "bee-git-peek-title")
      title.append(el("b", null, name), ` Git Local Changes (Working Tree) - ${this.index + 1} of ${this.count} ${this.count === 1 ? "change" : "changes"}`)
      const actions = el("span", "bee-git-peek-actions")
      const button = (label, text, fn) => {
        const b = el("button", null, text)
        b.title = label
        b.setAttribute("aria-label", label)
        b.dataset.action = label
        b.addEventListener("mousedown", e => e.preventDefault())
        b.addEventListener("click", e => {
          e.preventDefault()
          fn()
        })
        actions.append(b)
      }
      button("Stage Change", "+", () => stage(view, this.hunk, this.added))
      button("Revert Change", "↶", () => revert(view, this.hunk))
      button("Next Change", "↓", () => move(view, this.index, 1))
      button("Previous Change", "↑", () => move(view, this.index, -1))
      button("Close", "✕", () => view.dispatch({effects: closePeek.of(null)}))
      head.append(title, actions)

      const body = el("div", "bee-git-peek-body")
      this.hunk.old_lines.forEach((text, i) => body.append(row("removed", this.hunk.old_start + i, text)))
      this.added.forEach((text, i) => body.append(row("added", this.hunk.new_start + i, text)))
      dom.append(head, body)
      return dom
    }
  }

  const el = (tag, className, text) => {
    const node = document.createElement(tag)
    if (className) node.className = className
    if (text != null) node.textContent = text
    return node
  }

  const row = (kind, number, text) => {
    const line = el("div", `bee-git-peek-line bee-git-peek-${kind}`)
    line.append(el("span", "bee-git-peek-number", String(number)), el("span", "bee-git-peek-text", text || " "))
    return line
  }

  const peekKeys = keymap.of([
    {
      key: "Escape",
      run: view => {
        if (!view.state.field(peek, false)) return false
        view.dispatch({effects: closePeek.of(null)})
        return true
      },
    },
  ])

  const theme = EditorView.baseTheme({
    ".bee-git-blamed-empty": {position: "relative"},
    ".bee-git-blamed-empty::after": {position: "absolute", top: "0", left: "0"},
    ".bee-git-blamed::after": {
      content: "attr(data-blame)",
      marginLeft: "3em",
      opacity: "0.45",
      fontStyle: "italic",
      whiteSpace: "pre",
      pointerEvents: "none",
    },
    ".bee-git-hover": {padding: "6px 10px", maxWidth: "36rem", fontSize: "0.9em"},
    ".bee-git-hover-head": {fontWeight: "600", marginBottom: "4px"},
    ".bee-git-hover-hash": {opacity: "0.6", fontFamily: "monospace", marginBottom: "4px"},
    ".bee-git-hover-message": {whiteSpace: "pre-wrap"},
    ".bee-git-file-blame .cm-gutterElement": {
      fontSize: "0.85em",
      opacity: "0.6",
      paddingRight: "8px",
      whiteSpace: "nowrap",
    },
    ".bee-git-changes .cm-gutterElement": {width: "4px", padding: "0 1px", cursor: "pointer"},
    ".bee-git-peek": {
      borderTop: "2px solid #3b82f6",
      borderBottom: "2px solid #3b82f6",
      margin: "2px 0",
      fontFamily: "inherit",
    },
    ".bee-git-peek-head": {
      display: "flex",
      alignItems: "center",
      gap: "8px",
      padding: "2px 8px",
      fontFamily: "ui-sans-serif, system-ui, sans-serif",
      fontSize: "0.85em",
      background: "rgba(59, 130, 246, 0.12)",
    },
    ".bee-git-peek-title": {flex: "1", opacity: "0.85", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis"},
    ".bee-git-peek-actions button": {
      padding: "0 6px",
      cursor: "pointer",
      borderRadius: "3px",
      background: "none",
      border: "none",
      color: "inherit",
      fontSize: "1.1em",
    },
    ".bee-git-peek-actions button:hover": {background: "rgba(127, 127, 127, 0.25)"},
    ".bee-git-peek-body": {padding: "2px 0"},
    ".bee-git-peek-line": {display: "flex", whiteSpace: "pre"},
    ".bee-git-peek-removed": {background: "rgba(248, 113, 113, 0.25)"},
    ".bee-git-peek-added": {background: "rgba(74, 222, 128, 0.2)"},
    ".bee-git-peek-number": {width: "3.5em", paddingRight: "1em", textAlign: "right", opacity: "0.5", flexShrink: "0"},
    ".bee-git-change": {display: "block", height: "100%"},
    ".bee-git-added": {borderLeft: "3px solid #4ade80"},
    ".bee-git-modified": {borderLeft: "3px solid #60a5fa"},
    ".bee-git-deleted": {
      borderLeft: "4px solid transparent",
      borderBottom: "4px solid #f87171",
      height: "4px",
      marginTop: "auto",
    },
  })

  bee.registerEditorExtension([
    loader,
    lineBlame,
    hoverField,
    hoverHandlers,
    fileBlame,
    changes,
    peek,
    peekKeys,
    theme,
  ])

  bee.registerCommand("git.toggleFileBlame", () => {
    options.fileBlame = !options.fileBlame
    redraw()
  })

  bee.registerCommand("git.toggleLineBlame", () => {
    options.lineBlame = !options.lineBlame
    redraw()
  })
}
