// Highlights TODO / FIXME in the editor; hovering one asks the server part
// how many there are (bee.request → Todos.handle_request/4).
export function activate(bee) {
  const {view, state: cmState} = bee.codemirror
  const {Decoration, MatchDecorator, ViewPlugin, hoverTooltip} = view

  const mark = Decoration.mark({class: "bee-todo"})
  const matcher = new MatchDecorator({regexp: /\b(TODO|FIXME)\b/g, decoration: () => mark})

  const highlight = ViewPlugin.fromClass(
    class {
      constructor(v) { this.decorations = matcher.createDeco(v) }
      update(u) { this.decorations = matcher.updateDeco(u, this.decorations) }
    },
    {decorations: v => v.decorations}
  )

  const theme = view.EditorView.baseTheme({
    ".bee-todo": {color: "#f59e0b", fontWeight: "bold", textDecoration: "underline dotted"},
  })

  let counts = new Map() // path -> Promise of {file, total}
  bee.onMessage(() => (counts = new Map()))

  const tooltip = hoverTooltip(async (v, pos) => {
    const line = v.state.doc.lineAt(pos)
    const re = /\b(TODO|FIXME)\b/g
    let m
    while ((m = re.exec(line.text))) {
      const from = line.from + m.index
      const to = from + m[0].length
      if (pos < from || pos > to) continue

      const path = bee.editor.pathOf(v.state)
      if (!counts.has(path)) counts.set(path, bee.request("count", {path}))
      const {file, total} = await counts.get(path)
      return {
        pos: from,
        end: to,
        above: true,
        create: () => {
          const dom = document.createElement("div")
          dom.style.padding = "2px 6px"
          dom.textContent = `${file} in this file, ${total} in the workspace`
          return {dom}
        },
      }
    }
    return null
  })

  bee.registerEditorExtension([highlight, theme, tooltip])
}
