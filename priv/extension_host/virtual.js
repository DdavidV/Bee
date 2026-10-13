// Documents that aren't files, and the diffs extensions show of them:
//
//   workspace.registerFileSystemProvider(scheme, provider)
//   workspace.registerTextDocumentContentProvider(scheme, provider)
//       what a document of another scheme than "file" has in it: asked
//       when it is opened (workspace.openTextDocument) or compared
//   commands.executeCommand("vscode.diff", original, modified, title)
//       a tab comparing two documents. It is one of the window's tabs
//       (window.tabGroups, input: TabInputTextDiff); while it is the tab
//       shown, its modified side is a visible text editor
//       (window.visibleTextEditors), as in VS Code
//
//   to Bee     diffOpen {id, title, original: {uri, path, text}, modified: {…}}
//              diffClose {id}             window.tabGroups.close(tab)
//   from Bee   diffState {id, active}     its tab is the one shown, or not
//              diffClosed {id}            its tab was closed
"use strict"

const fs = require("node:fs")
const {TextDocument} = require("./documents")
const {CancellationTokenSource, Disposable, FileSystemError, TabInputTextDiff, Uri} = require("./types")

class Virtual {
  constructor(host) {
    this.host = host
    this.fileSystems = new Map() // scheme → FileSystemProvider
    this.contents = new Map() // scheme → TextDocumentContentProvider
    this.documents = new Map() // uri → TextDocument
    this.diffs = new Map() // id → {id, title, original, modified, document, active}
    this.next = 0
  }

  register(table, scheme, provider) {
    const name = String(scheme)
    if (table.has(name)) throw new Error(`a provider for the scheme '${name}' is already registered`)
    table.set(name, provider)
    return new Disposable(() => {
      if (table.get(name) === provider) table.delete(name)
    })
  }

  // The text of `uri`: an open file's, the file's, or what its scheme's
  // provider says.
  async read(uri) {
    if (uri.scheme === "file") {
      const open = this.host.documents.get(uri.fsPath)
      return open ? open.getText() : fs.promises.readFile(uri.fsPath, "utf8")
    }
    const files = this.fileSystems.get(uri.scheme)
    if (files) return Buffer.from(await files.readFile(uri)).toString("utf8")
    const contents = this.contents.get(uri.scheme)
    if (contents) {
      const source = new CancellationTokenSource()
      try {
        return String((await contents.provideTextDocumentContent(uri, source.token)) ?? "")
      } finally {
        source.dispose()
      }
    }
    throw FileSystemError.FileNotFound(uri)
  }

  // workspace.openTextDocument of a uri that isn't a file.
  async open(uri) {
    const text = await this.read(uri)
    const key = uri.toString()
    let document = this.documents.get(key)
    if (document) {
      if (document.getText() !== text) document._set(text)
    } else {
      document = new TextDocument(uri.path, text, undefined, 1)
      document.uri = uri
      this.documents.set(key, document)
    }
    return document
  }

  async diff(original, modified, title) {
    if (!(original instanceof Uri) || !(modified instanceof Uri)) throw new Error("vscode.diff(original, modified, title?)")
    const [before, after] = await Promise.all([this.read(original).catch(() => ""), this.read(modified)])
    const id = String(++this.next)
    const document = modified.scheme === "file" ? this.host.documents.get(modified.fsPath) : await this.open(modified)
    const diff = {id, title: String(title ?? `${original.path} ↔ ${modified.path}`), original, modified, document, active: false}
    this.diffs.set(id, diff)
    const side = (uri, text) => ({uri: uri.toString(), path: uri.scheme === "file" ? uri.fsPath : uri.path, text})
    this.host.notify("diffOpen", {id, title: diff.title, original: side(original, before), modified: side(modified, after)})
    this.host.onTabs.fire({opened: [this.tab(diff)], closed: [], changed: []})
    return undefined
  }

  tab(diff, group) {
    return {
      label: diff.title,
      input: new TabInputTextDiff(diff.original, diff.modified),
      isActive: diff.active,
      isDirty: false,
      isPinned: false,
      isPreview: false,
      group,
      _diff: diff.id,
    }
  }

  tabs(group) {
    return [...this.diffs.values()].map(diff => this.tab(diff, group))
  }

  // The diff whose tab is shown: the documents of its modified side are
  // what the user sees.
  shown() {
    return [...this.diffs.values()].filter(diff => diff.active && diff.document)
  }

  // window.tabGroups.close(tab | tabs): of the diffs among them.
  close(tabs) {
    let closed = false
    for (const tab of [].concat(tabs || [])) {
      const diff = tab && this.find(tab)
      if (!diff) continue
      this.host.notify("diffClose", {id: diff.id})
      closed = true
    }
    return closed
  }

  find(tab) {
    if (tab._diff && this.diffs.has(tab._diff)) return this.diffs.get(tab._diff)
    const input = tab.input
    if (!(input instanceof TabInputTextDiff)) return undefined
    return [...this.diffs.values()].find(
      diff => diff.original.toString() === String(input.original) && diff.modified.toString() === String(input.modified),
    )
  }

  // From Bee.
  state({id, active}) {
    const diff = this.diffs.get(id)
    if (!diff || diff.active === !!active) return
    diff.active = !!active
    this.host.onTabs.fire({opened: [], closed: [], changed: [this.tab(diff)]})
    this.host.onVisibleEditors.fire(this.host.visibleEditors())
  }

  closed({id}) {
    const diff = this.diffs.get(id)
    if (!diff) return
    this.diffs.delete(id)
    const was = diff.active
    diff.active = false
    this.host.onTabs.fire({opened: [], closed: [this.tab(diff)], changed: []})
    if (was) this.host.onVisibleEditors.fire(this.host.visibleEditors())
  }

  api() {
    return {
      registerFileSystemProvider: (scheme, provider) => this.register(this.fileSystems, scheme, provider),
      registerTextDocumentContentProvider: (scheme, provider) => this.register(this.contents, scheme, provider),
    }
  }
}

module.exports = {Virtual}
