// vscode.window.createWebviewPanel: pages of an extension's own HTML in
// editor tabs. Bee shows a panel in a sandboxed frame (Bee.Webviews,
// BeeWeb.WebviewController); here is its extension's side:
//
//   to Bee     webviewOpen {id, extension, viewType, title, scripts, roots}
//              webviewUpdate {id, title?, html?, scripts?, roots?}
//              webviewPost {id, message}, webviewReveal {id}, webviewDispose {id}
//   from Bee   webviewMessage {id, message}   its page's postMessage
//              webviewState {id, active, visible}
//              webviewClosed {id}             its tab was closed
//
// A local file is loaded through `asWebviewUri`: a stand-in address that
// Bee turns into the panel's own (it alone knows where the page is served).
"use strict"

const {Disposable, EventEmitter, Uri, ViewColumn} = require("./types")

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
    this._onDispose.fire()
    this._onDispose.dispose()
    this._onViewState.dispose()
    this.webview._onMessage.dispose()
  }
}

// The host's part: every extension's panels.
class Webviews {
  constructor(host) {
    this.host = host
    this.panels = new Map() // id → panel
    this.next = 0
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
  }

  api(extension) {
    return {
      createWebviewPanel: (viewType, title, showOptions, options) => this.create(extension, viewType, title, showOptions, options),
      // Panels aren't kept over a restart of Bee: nothing to bring back.
      registerWebviewPanelSerializer: () => new Disposable(() => {}),
    }
  }
}

module.exports = {Webviews, RESOURCE}
