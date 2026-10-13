// vscode.window.createWebviewPanel: pages of an extension's own HTML in
// editor tabs. Bee shows a panel in a sandboxed frame (Bee.Webviews,
// BeeWeb.WebviewController); here is its extension's side:
//
// And window.registerWebviewViewProvider: such a page as a view, in the
// sidebar or the panel (a view of "type": "webview" in package.json). Bee
// asks for it when the view is first shown (webviewViewResolve); it is a
// webview like a panel's, with the id "view:<view id>".
//
//   to Bee     webviewOpen {id, extension, viewType, title, scripts, roots, view?}
//              webviewUpdate {id, title?, html?, scripts?, roots?}
//              webviewPost {id, message}, webviewReveal {id}, webviewDispose {id}
//   from Bee   webviewMessage {id, message}   its page's postMessage
//              webviewState {id, active, visible}
//              webviewClosed {id}             its tab was closed
//              webviewViewResolve {view}      a webview view is shown: draw it
//
// And window.registerCustomEditorProvider: such a page as the editor of a
// file (a customEditors entry of package.json; Bee.CustomEditors). Bee
// asks for it when a file opens in the editor (customEditorResolve), with
// the id it gave the tab's page: a panel like any other, drawn by the
// provider –
//
//   resolveCustomTextEditor(document, panel)   the file as a text document
//                                              (Bee's, when it has it open)
//   openCustomDocument(uri), then
//   resolveCustomEditor(document, panel)       a document of the provider's
//
// A custom document that says it changed (onDidChangeCustomDocument) has
// unsaved changes, until saveCustomDocument (customEditorSave) wrote them.
// Undoing its edits, reverting and backups aren't there.
//
//   to Bee     webviewOpen {…, custom: {viewType, path, text}}
//              customEditorDirty {id, dirty}
//   from Bee   customEditorResolve {id, viewType, path}
//              customEditorSave {id}
//
// A local file is loaded through `asWebviewUri`: a stand-in address that
// Bee turns into the panel's own (it alone knows where the page is served).
"use strict"

const fs = require("fs")
const path = require("path")
const {CancellationTokenSource, Disposable, EventEmitter, Uri, ViewColumn} = require("./types")
const {TextDocument} = require("./documents")

// Replaced in the page's HTML by BeeWeb.WebviewController.
const RESOURCE = "file.bee-webview.invalid"
const CSP_SOURCE = "'self'"

class Webview {
  constructor(panel, options) {
    this._panel = panel
    this._html = ""
    this._options = options || {}
    this._onMessage = new EventEmitter()
    this.onDidReceiveMessage = this._onMessage.event
    this.cspSource = CSP_SOURCE
  }

  get html() {
    return this._html
  }
  set html(value) {
    this._html = String(value ?? "")
    this._panel._update({html: this._html})
  }

  get options() {
    return this._options
  }
  set options(value) {
    this._options = value || {}
    this._panel._update(plainOptions(this._panel, this._options))
  }

  postMessage(message) {
    if (this._panel._disposed) return Promise.resolve(false)
    this._panel._webviews.host.notify("webviewPost", {id: this._panel._id, message: message ?? null})
    return Promise.resolve(true)
  }

  asWebviewUri(uri) {
    if (uri.scheme !== "file") return uri
    return new Uri("https", RESOURCE, uri.path, uri.query, uri.fragment)
  }
}

// The folders a panel's page may load files from: its own, or the
// workspace and its extension's.
const plainOptions = (panel, options) => ({
  scripts: !!options.enableScripts,
  roots: (options.localResourceRoots || [Uri.file(panel._webviews.host.root), Uri.file(panel._extension.dir)])
    .filter(uri => uri && uri.scheme === "file")
    .map(uri => uri.fsPath),
})

class WebviewPanel {
  constructor(webviews, extension, id, viewType, title, options) {
    this._webviews = webviews
    this._extension = extension
    this._id = id
    this._title = String(title ?? "")
    this._disposed = false
    this._onDispose = new EventEmitter()
    this._onViewState = new EventEmitter()
    this.viewType = viewType
    this.options = {
      enableFindWidget: !!(options && options.enableFindWidget),
      retainContextWhenHidden: !!(options && options.retainContextWhenHidden),
    }
    this.webview = new Webview(this, options)
    this.viewColumn = ViewColumn.One
    this.active = true
    this.visible = true
    this.iconPath = undefined
    this.onDidDispose = this._onDispose.event
    this.onDidChangeViewState = this._onViewState.event
  }

  get title() {
    return this._title
  }
  set title(value) {
    this._title = String(value ?? "")
    this._update({title: this._title})
  }

  _update(changes) {
    if (!this._disposed) this._webviews.host.notify("webviewUpdate", {id: this._id, ...changes})
  }

  reveal() {
    if (!this._disposed) this._webviews.host.notify("webviewReveal", {id: this._id})
  }

  dispose() {
    if (this._disposed) return
    this._disposed = true
    this._webviews.panels.delete(this._id)
    this._webviews.host.notify("webviewDispose", {id: this._id})
    // (A custom editor's: its document may go with it.)
    if (this._closed) this._closed()
    this._onDispose.fire()
    this._onDispose.dispose()
    this._onViewState.dispose()
    this.webview._onMessage.dispose()
  }
}

// A webview view: what its provider's resolveWebviewView gets. (It has
// what a Webview asks of its panel: _id, _disposed, _update, _webviews,
// _extension.)
class WebviewView {
  constructor(webviews, extension, viewType, options) {
    this._webviews = webviews
    this._extension = extension
    this._id = `view:${viewType}`
    this._disposed = false
    this._onDispose = new EventEmitter()
    this._onVisibility = new EventEmitter()
    this.viewType = viewType
    this.webview = new Webview(this, options)
    this.title = undefined
    this.description = undefined
    this.badge = undefined
    this.visible = true
    this.onDidDispose = this._onDispose.event
    this.onDidChangeVisibility = this._onVisibility.event
  }

  _update(changes) {
    if (!this._disposed) this._webviews.host.notify("webviewUpdate", {id: this._id, ...changes})
  }

  // Its container is shown, in the sidebar or the panel.
  show() {
    if (!this._disposed) this._webviews.host.notify("webviewReveal", {id: this._id})
  }

  dispose() {
    if (this._disposed) return
    this._disposed = true
    this._webviews.panels.delete(this._id)
    this._webviews.host.notify("webviewDispose", {id: this._id})
    this._onDispose.fire()
    this._onDispose.dispose()
    this._onVisibility.dispose()
    this.webview._onMessage.dispose()
  }
}

// The host's part: every extension's panels and views.
class Webviews {
  constructor(host) {
    this.host = host
    this.panels = new Map() // id → panel (or view)
    this.next = 0
    this.providers = new Map() // view id → {extension, provider, options}
    this.wanted = new Set() // views shown before their provider was there
    this.editors = new Map() // viewType → {extension, provider, options, documents}
    this.wantedEditors = [] // files opened before their editor's provider was there
  }

  registerCustomEditorProvider(extension, viewType, provider, options) {
    const type = String(viewType)
    if (this.editors.has(type)) throw new Error(`a custom editor provider for '${type}' is already registered`)
    // documents: path → {ready: a promise of the custom document, panels, dirty}
    const entry = {extension, provider, options: options || {}, documents: new Map()}
    this.editors.set(type, entry)
    if (provider && typeof provider.onDidChangeCustomDocument === "function") {
      entry.changes = provider.onDidChangeCustomDocument(event => this.customChanged(entry, event && event.document))
    }
    const waiting = this.wantedEditors.filter(wanted => wanted.viewType === type)
    this.wantedEditors = this.wantedEditors.filter(wanted => wanted.viewType !== type)
    for (const wanted of waiting) queueMicrotask(() => this.resolveCustomEditor(wanted))
    return new Disposable(() => {
      if (this.editors.get(type) !== entry) return
      this.editors.delete(type)
      if (entry.changes) entry.changes.dispose()
      for (const panel of [...this.panels.values()]) if (panel._entry === entry) panel.dispose()
    })
  }

  // From Bee: the file at `path` is opened in the editor `viewType`, in a
  // tab whose page is `id`.
  async resolveCustomEditor({id, viewType, path: file}) {
    const entry = this.editors.get(viewType)
    if (!entry) return this.wantedEditors.push({id, viewType, path: file})
    if (this.panels.has(id)) return
    const {provider} = entry
    const text = typeof provider.resolveCustomTextEditor === "function"
    const panel = new WebviewPanel(this, entry.extension, id, viewType, path.basename(file), entry.options.webviewOptions)
    panel._entry = entry
    this.panels.set(id, panel)
    this.host.notify("webviewOpen", {
      id,
      custom: {viewType, path: file, text},
      extension: entry.extension.name,
      viewType,
      title: panel.title,
      ...plainOptions(panel, panel.webview.options),
    })
    const source = new CancellationTokenSource()
    try {
      if (text) {
        // Bee's document when it has the file open: what the provider
        // edits (workspace.applyEdit) and hears of. Else as it is on disk.
        const document =
          this.host.documents.get(file) || new TextDocument(file, await fs.promises.readFile(file, "utf8"), undefined, 1)
        await provider.resolveCustomTextEditor(document, panel, source.token)
      } else {
        let held = entry.documents.get(file)
        if (!held) {
          held = {panels: new Set(), dirty: false}
          held.ready = Promise.resolve(
            provider.openCustomDocument(Uri.file(file), {backupId: undefined, untitledDocumentData: undefined}, source.token),
          )
          entry.documents.set(file, held)
        }
        held.panels.add(panel)
        panel._closed = () => this.customClosed(entry, file, held, panel)
        const document = await held.ready
        held.document = document
        if (panel._disposed) return
        if (held.dirty) this.host.notify("customEditorDirty", {id, dirty: true})
        await provider.resolveCustomEditor(document, panel, source.token)
      }
    } catch (e) {
      console.error(`custom editor ${viewType} failed to open ${file}: ${(e && e.stack) || e}`)
      if (!panel._disposed && !panel.webview.html) {
        const message = String((e && e.message) || e).replace(/[&<>]/g, c => ({"&": "&amp;", "<": "&lt;", ">": "&gt;"})[c])
        panel.webview.html = `<!DOCTYPE html><html><body><p>The editor could not open this file: ${message}</p></body></html>`
      }
    }
  }

  // The last editor of a custom document closed: the document goes.
  customClosed(entry, file, held, panel) {
    held.panels.delete(panel)
    if (held.panels.size > 0 || entry.documents.get(file) !== held) return
    entry.documents.delete(file)
    held.ready.then(document => document && typeof document.dispose === "function" && document.dispose()).catch(() => {})
  }

  // A provider's onDidChangeCustomDocument: the document has unsaved changes.
  customChanged(entry, document) {
    for (const held of entry.documents.values()) {
      if (held.document !== document) continue
      held.dirty = true
      for (const panel of held.panels) this.host.notify("customEditorDirty", {id: panel._id, dirty: true})
    }
  }

  // From Bee: Save, in the tab whose page is `id`.
  async saveCustomEditor({id}) {
    const panel = this.panels.get(id)
    const entry = panel && panel._entry
    if (!entry) return
    for (const held of entry.documents.values()) {
      if (!held.panels.has(panel) || !held.document) continue
      if (typeof entry.provider.saveCustomDocument !== "function") return
      try {
        await entry.provider.saveCustomDocument(held.document, new CancellationTokenSource().token)
        held.dirty = false
        for (const other of held.panels) this.host.notify("customEditorDirty", {id: other._id, dirty: false})
      } catch (e) {
        console.error(`saving ${held.document.uri && held.document.uri.fsPath} failed: ${(e && e.stack) || e}`)
        this.host
          .request("showMessage", {extension: entry.extension.name, level: "error", text: `Could not save: ${(e && e.message) || e}`, items: []})
          .catch(() => {})
      }
    }
  }

  registerViewProvider(extension, viewId, provider, options) {
    const id = String(viewId)
    if (this.providers.has(id)) throw new Error(`a webview view provider for '${id}' is already registered`)
    const entry = {extension, provider, options: options || {}}
    this.providers.set(id, entry)
    if (this.wanted.delete(id)) queueMicrotask(() => this.resolveView({view: id}))
    return new Disposable(() => {
      if (this.providers.get(id) !== entry) return
      this.providers.delete(id)
      this.panels.get(`view:${id}`)?.dispose()
    })
  }

  // From Bee: view `view` is shown, and has no page yet.
  resolveView({view: id}) {
    const entry = this.providers.get(id)
    if (!entry) return this.wanted.add(id)
    if (this.panels.has(`view:${id}`)) return
    const view = new WebviewView(this, entry.extension, id, entry.options.webviewOptions)
    this.panels.set(view._id, view)
    this.host.notify("webviewOpen", {
      id: view._id,
      view: id,
      extension: entry.extension.name,
      viewType: id,
      title: "",
      ...plainOptions(view, view.webview.options),
    })
    const source = new CancellationTokenSource()
    Promise.resolve()
      .then(() => entry.provider.resolveWebviewView(view, {state: undefined}, source.token))
      .catch(e => console.error(`resolveWebviewView of ${id} failed: ${(e && e.stack) || e}`))
  }

  create(extension, viewType, title, _showOptions, options) {
    const id = String(++this.next)
    const panel = new WebviewPanel(this, extension, id, viewType, title, options)
    this.panels.set(id, panel)
    this.host.notify("webviewOpen", {
      id,
      extension: extension.name,
      viewType: String(viewType),
      title: panel.title,
      ...plainOptions(panel, panel.webview.options),
    })
    return panel
  }

  // From Bee.
  message({id, message}) {
    this.panels.get(id)?.webview._onMessage.fire(message)
  }

  state({id, active, visible}) {
    const panel = this.panels.get(id)
    if (panel instanceof WebviewView) {
      if (panel.visible === !!visible) return
      panel.visible = !!visible
      return panel._onVisibility.fire()
    }
    if (!panel || (panel.active === !!active && panel.visible === !!visible)) return
    panel.active = !!active
    panel.visible = !!visible
    panel._onViewState.fire({webviewPanel: panel})
  }

  closed({id}) {
    this.panels.get(id)?.dispose()
  }

  // The panels of an extension that is going away.
  forget(extension) {
    for (const panel of [...this.panels.values()]) if (panel._extension === extension) panel.dispose()
    for (const [id, entry] of [...this.providers]) if (entry.extension === extension) this.providers.delete(id)
    for (const [type, entry] of [...this.editors]) {
      if (entry.extension !== extension) continue
      this.editors.delete(type)
      if (entry.changes) entry.changes.dispose()
    }
  }

  api(extension) {
    return {
      createWebviewPanel: (viewType, title, showOptions, options) => this.create(extension, viewType, title, showOptions, options),
      // Panels aren't kept over a restart of Bee: nothing to bring back.
      registerWebviewPanelSerializer: () => new Disposable(() => {}),
      registerWebviewViewProvider: (viewId, provider, options) => this.registerViewProvider(extension, viewId, provider, options),
      registerCustomEditorProvider: (viewType, provider, options) =>
        this.registerCustomEditorProvider(extension, viewType, provider, options),
    }
  }
}

module.exports = {Webviews, RESOURCE}
