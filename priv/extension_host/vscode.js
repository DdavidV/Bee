// The `vscode` module an extension gets: what Bee implements of VS Code's
// API. Each extension has its own (so Bee knows who registers what), over
// the host's shared state (main.js).
//
// Implemented: commands, messages / quick picks / input boxes, the active
// editor and open documents (read, edit), configuration, status bar items,
// output channels, setContext, the extension context with its state.
// Anything else exists as a stand-in that does nothing: the extension keeps
// running, and Bee lists what it used on the plugin's details page.
"use strict"

const fs = require("node:fs")
const path = require("node:path")
const types = require("./types")
const {TextDocument} = require("./documents")
const {Disposable, EventEmitter, Position, Range, Selection, Uri} = types

const VERSION = "1.95.0"

// A stand-in for API Bee doesn't have: callable, constructible, with any
// member; using it is reported once per name.
const stub = (host, ext, name) => {
  const target = function () {}
  const use = () => {
    host.unsupported(ext, name)
    return stub(host, ext, `${name}()`)
  }
  return new Proxy(target, {
    get(_target, prop) {
      if (prop === "dispose") return () => {}
      if (prop === "prototype") return target.prototype
      // Not a promise, not a primitive.
      if (prop === "then" || typeof prop === "symbol") return undefined
      if (prop === "toString" || prop === "toJSON") return () => `[vscode.${name}]`
      return stub(host, ext, `${name}.${prop}`)
    },
    set: () => true,
    apply: use,
    construct: use,
  })
}

// `object`, with stand-ins for the members it doesn't have.
const withStubs = (host, ext, name, object) =>
  new Proxy(object, {
    get(target, prop, receiver) {
      if (prop in target || typeof prop === "symbol" || prop === "then") return Reflect.get(target, prop, receiver)
      return stub(host, ext, name ? `${name}.${String(prop)}` : String(prop))
    },
  })

// Edits collected by a TextEditor.edit() callback: [{from, to, text}] in
// the document's (UTF-16) offsets.
class EditBuilder {
  constructor(document) {
    this.document = document
    this.edits = []
  }
  replace(location, text) {
    const range = location instanceof Position ? new Range(location, location) : location
    this.edits.push({from: this.document.offsetAt(range.start), to: this.document.offsetAt(range.end), text: String(text)})
  }
  insert(position, text) {
    this.replace(position, text)
  }
  delete(range) {
    this.replace(range, "")
  }
  setEndOfLine() {}
}

class TextEditor {
  constructor(host, document, selections) {
    this._host = host
    this.document = document
    this.viewColumn = types.ViewColumn.One
    this.options = {tabSize: host.settings["editor.tabSize"], insertSpaces: true}
    this._setSelections(selections)
  }
  // [[anchor, active]] offsets.
  _setSelections(selections) {
    const list = selections && selections.length ? selections : [[0, 0]]
    this.selections = list.map(
      ([anchor, active]) => new Selection(this.document.positionAt(anchor), this.document.positionAt(active)),
    )
  }
  get selection() {
    return this.selections[0]
  }
  set selection(selection) {
    this.selections = [selection]
  }
  get visibleRanges() {
    return [new Range(0, 0, Math.max(0, this.document.lineCount - 1), 0)]
  }
  edit(callback) {
    const builder = new EditBuilder(this.document)
    callback(builder)
    return this._host.applyEdits(this.document, builder.edits)
  }
  insertSnippet(snippet, location) {
    const text = String((snippet && snippet.value) || snippet || "").replace(/\$\{\d+:([^}]*)\}|\$\d+/g, "$1")
    const targets = location ? [].concat(location) : this.selections
    return this.edit(edit => targets.forEach(target => edit.replace(target, text)))
  }
  setDecorations() {}
  revealRange() {}
  show() {}
  hide() {}
}

// State of an extension kept between runs, in a JSON file.
class Memento {
  constructor(file) {
    this._file = file
    try {
      this._data = JSON.parse(fs.readFileSync(file, "utf8"))
    } catch (_e) {
      this._data = {}
    }
  }
  keys() {
    return Object.keys(this._data)
  }
  get(key, fallback) {
    return key in this._data ? this._data[key] : fallback
  }
  update(key, value) {
    if (value === undefined) delete this._data[key]
    else this._data[key] = value
    try {
      fs.mkdirSync(path.dirname(this._file), {recursive: true})
      fs.writeFileSync(this._file, JSON.stringify(this._data))
    } catch (e) {
      return Promise.reject(e)
    }
    return Promise.resolve()
  }
  setKeysForSync() {}
}

// Settings of VS Code's that extensions read and Bee doesn't have: their
// VS Code defaults, so such an extension finds a value.
const VSCODE_DEFAULTS = {
  "editor.insertSpaces": true,
  "editor.detectIndentation": true,
  "editor.rulers": [],
  "editor.wordWrapColumn": 80,
  "editor.formatOnSave": false,
  "files.eol": "\n",
  "files.encoding": "utf8",
  "files.insertFinalNewline": false,
  "files.trimTrailingWhitespace": false,
}

// workspace.getConfiguration(section): Bee's settings are flat
// ("hello.greeting"); a section's value is assembled from them.
const configuration = (host, section) => {
  const full = key => [section, key].filter(Boolean).join(".")
  const lookup = key => {
    const name = full(key)
    const settings = host.settings
    if (name in settings) return settings[name]
    if (name in VSCODE_DEFAULTS) return VSCODE_DEFAULTS[name]
    const prefix = name ? name + "." : ""
    let found
    for (const [setting, value] of Object.entries(settings)) {
      if (!setting.startsWith(prefix)) continue
      found ??= {}
      const parts = setting.slice(prefix.length).split(".")
      let node = found
      for (const part of parts.slice(0, -1)) node = node[part] = typeof node[part] === "object" && node[part] ? node[part] : {}
      node[parts.at(-1)] = value
    }
    return found
  }
  const config = {
    get: (key, fallback) => {
      const value = lookup(key)
      return value === undefined ? fallback : value
    },
    has: key => lookup(key) !== undefined,
    // Where a value comes from: Bee tells its default and what is in
    // effect (as the user's value, when it isn't the default).
    inspect: key => {
      const value = lookup(key)
      const defaultValue = full(key) in host.defaults ? host.defaults[full(key)] : VSCODE_DEFAULTS[full(key)]
      const set = value !== undefined && JSON.stringify(value) !== JSON.stringify(defaultValue)
      return {
        key: full(key),
        defaultValue,
        globalValue: set ? value : undefined,
        workspaceValue: undefined,
        workspaceFolderValue: undefined,
        defaultLanguageValue: undefined,
        globalLanguageValue: undefined,
        workspaceLanguageValue: undefined,
        workspaceFolderLanguageValue: undefined,
      }
    },
    update: (key, value, target) =>
      host.request("updateConfiguration", {
        key: full(key),
        value: value === undefined ? null : value,
        target: target === types.ConfigurationTarget.Global || target === true ? "user" : "workspace",
        remove: value === undefined,
      }),
  }
  // config.greeting, as some extensions read it.
  return new Proxy(config, {
    get: (target, prop) => (prop in target || typeof prop === "symbol" ? target[prop] : lookup(prop)),
    has: (target, prop) => prop in target || lookup(prop) !== undefined,
  })
}

const messageItems = rest => {
  const items = rest.filter(item => typeof item === "string" || (item && typeof item.title === "string"))
  return {items, labels: items.map(item => (typeof item === "string" ? item : item.title))}
}

const createApi = (host, ext) => {
  const showMessage = level => async (message, ...rest) => {
    const {items, labels} = messageItems(rest)
    const index = await host.request("showMessage", {extension: ext.name, level, text: String(message), items: labels})
    return typeof index === "number" ? items[index] : undefined
  }

  const commands = {
    registerCommand: (id, handler, thisArg) => host.registerCommand(ext, id, handler, thisArg),
    // The handler gets the active editor and an edit builder: its edits
    // are applied when it returns.
    registerTextEditorCommand: (id, handler, thisArg) =>
      host.registerCommand(ext, id, (...args) => {
        const editor = host.activeEditor
        if (!editor) return undefined
        return editor.edit(builder => handler.call(thisArg, editor, builder, ...args))
      }),
    executeCommand: (id, ...args) => host.executeCommand(ext, id, args),
    getCommands: async () => [...new Set([...host.commands.keys(), ...(await host.request("getCommands", {}))])],
  }

  const window = {
    get activeTextEditor() {
      return host.activeEditor
    },
    get visibleTextEditors() {
      return host.activeEditor ? [host.activeEditor] : []
    },
    onDidChangeActiveTextEditor: host.onActiveEditor.event,
    onDidChangeTextEditorSelection: host.onSelection.event,
    onDidChangeVisibleTextEditors: new EventEmitter().event,
    onDidChangeWindowState: new EventEmitter().event,
    state: {focused: true, active: true},
    showInformationMessage: showMessage("info"),
    showWarningMessage: showMessage("warning"),
    showErrorMessage: showMessage("error"),
    showQuickPick: async (items, options = {}) => {
      const list = await items
      const index = await host.request("showQuickPick", {
        extension: ext.name,
        placeholder: options.placeHolder || options.title || "",
        items: list.map(item =>
          typeof item === "string"
            ? {label: item}
            : {label: String(item.label), description: [item.description, item.detail].filter(Boolean).join(" · ")},
        ),
      })
      if (typeof index !== "number") return undefined
      return options.canPickMany ? [list[index]] : list[index]
    },
    showInputBox: async (options = {}) => {
      const value = await host.request("showInputBox", {
        extension: ext.name,
        prompt: options.prompt || options.title || "",
        placeholder: options.placeHolder || "",
        value: options.value || "",
      })
      return typeof value === "string" ? value : undefined
    },
    showTextDocument: async (target, options = {}) => {
      const uri = target instanceof TextDocument ? target.uri : target
      const selection = options && options.selection
      await host.request("openFile", {path: uri.fsPath, line: selection ? selection.start.line + 1 : null})
      return host.activeEditor
    },
    setStatusBarMessage: (text, timeout) => {
      host.notify("setStatus", {text: stripIcons(text)})
      const clear = () => host.notify("setStatus", {text: ""})
      if (typeof timeout === "number") setTimeout(clear, timeout)
      else if (timeout && typeof timeout.then === "function") timeout.then(clear, clear)
      return new Disposable(clear)
    },
    createStatusBarItem: (a, b, c) => {
      // (alignment?, priority?) or (id, alignment?, priority?)
      const [alignment, priority] = typeof a === "string" ? [b, c] : [a, b]
      const id = `${++host.nextId}`
      const item = {
        id, alignment: alignment || types.StatusBarAlignment.Left, priority: priority || 0,
        text: "", tooltip: undefined, command: undefined, name: undefined,
        _shown: false,
        show() {
          this._shown = true
          const command = typeof this.command === "string" ? this.command : this.command && this.command.command
          host.notify("statusItem", {
            extension: ext.name, id,
            item: {
              text: stripIcons(this.text),
              tooltip: typeof this.tooltip === "string" ? this.tooltip : this.tooltip && this.tooltip.value,
              command: command || null,
              arguments: (this.command && this.command.arguments) || [],
              alignment: this.alignment === types.StatusBarAlignment.Right ? "right" : "left",
              priority: this.priority,
            },
          })
        },
        hide() {
          this._shown = false
          host.notify("statusItem", {extension: ext.name, id, item: null})
        },
        dispose() {
          this.hide()
        },
      }
      // Changing a shown item's text shows the new one.
      return new Proxy(item, {
        set(target, prop, value) {
          target[prop] = value
          if (target._shown && ["text", "tooltip", "command"].includes(prop)) target.show()
          return true
        },
      })
    },
    createOutputChannel: name => {
      const line = text => host.notify("log", {extension: ext.name, level: "info", text: `[${name}] ${text}`})
      let pending = ""
      const channel = {
        name,
        append(text) {
          pending += text
          const lines = pending.split("\n")
          pending = lines.pop()
          lines.forEach(line)
        },
        appendLine(text) {
          channel.append(text + "\n")
        },
        replace(text) {
          channel.append(text)
        },
        clear() {},
        show() {},
        hide() {},
        dispose() {},
      }
      for (const level of ["trace", "debug", "info", "warn", "error"]) channel[level] = (...args) => channel.appendLine(args.join(" "))
      channel.logLevel = types.LogLevel.Info
      channel.onDidChangeLogLevel = new EventEmitter().event
      return channel
    },
    withProgress: (_options, task) =>
      Promise.resolve(task({report() {}}, new types.CancellationTokenSource().token)),
  }

  const workspace = {
    get workspaceFolders() {
      return [{uri: Uri.file(host.root), name: path.basename(host.root), index: 0}]
    },
    get rootPath() {
      return host.root
    },
    get name() {
      return path.basename(host.root)
    },
    get textDocuments() {
      return host.documents.all()
    },
    workspaceFile: undefined,
    isTrusted: true,
    getWorkspaceFolder: uri =>
      uri.fsPath === host.root || uri.fsPath.startsWith(host.root + path.sep) ? workspace.workspaceFolders[0] : undefined,
    asRelativePath: target => {
      const file = typeof target === "string" ? target : target.fsPath
      return file.startsWith(host.root + path.sep) ? file.slice(host.root.length + 1) : file
    },
    getConfiguration: section => configuration(host, section),
    onDidChangeConfiguration: host.onConfiguration.event,
    onDidOpenTextDocument: host.documents.onOpen.event,
    onDidCloseTextDocument: host.documents.onClose.event,
    onDidChangeTextDocument: host.documents.onChange.event,
    onDidSaveTextDocument: host.documents.onSave.event,
    onDidChangeWorkspaceFolders: new EventEmitter().event,
    onDidGrantWorkspaceTrust: new EventEmitter().event,
    // An open document, or the file as it is on disk.
    openTextDocument: async target => {
      const file = typeof target === "string" ? target : target.fsPath
      return host.documents.get(file) || new TextDocument(file, await fs.promises.readFile(file, "utf8"), undefined, 1)
    },
    fs: {
      readFile: uri => fs.promises.readFile(uri.fsPath),
      writeFile: (uri, content) => fs.promises.writeFile(uri.fsPath, content),
      delete: (uri, options = {}) => fs.promises.rm(uri.fsPath, {recursive: !!options.recursive}),
      createDirectory: uri => fs.promises.mkdir(uri.fsPath, {recursive: true}),
      rename: (from, to) => fs.promises.rename(from.fsPath, to.fsPath),
      copy: (from, to) => fs.promises.cp(from.fsPath, to.fsPath, {recursive: true}),
      stat: async uri => {
        const stat = await fs.promises.stat(uri.fsPath)
        const type = stat.isDirectory() ? types.FileType.Directory : types.FileType.File
        return {type, ctime: stat.ctimeMs, mtime: stat.mtimeMs, size: stat.size}
      },
      readDirectory: async uri =>
        (await fs.promises.readdir(uri.fsPath, {withFileTypes: true})).map(entry => [
          entry.name,
          entry.isDirectory() ? types.FileType.Directory : types.FileType.File,
        ]),
    },
  }

  const env = {
    appName: "Bee",
    appRoot: host.root,
    appHost: "desktop",
    language: "en",
    machineId: "bee",
    sessionId: host.session,
    uriScheme: "bee",
    shell: process.env.SHELL || "",
    remoteName: undefined,
    uiKind: types.UIKind.Desktop,
    isTelemetryEnabled: false,
    onDidChangeTelemetryEnabled: new EventEmitter().event,
    logLevel: types.LogLevel.Info,
  }

  const extensions = {
    getExtension: id => host.extensionInfo(id),
    get all() {
      return [...host.extensions.values()].map(other => host.extensionInfo(other.id))
    },
    onDidChange: new EventEmitter().event,
  }

  const api = {
    version: VERSION,
    ...types,
    commands: withStubs(host, ext, "commands", commands),
    window: withStubs(host, ext, "window", window),
    workspace: withStubs(host, ext, "workspace", workspace),
    env: withStubs(host, ext, "env", env),
    extensions: withStubs(host, ext, "extensions", extensions),
  }
  // The rest of VS Code's API by name, as stand-ins: a bundled extension
  // copies the module's own properties (its bundler's import helper), so
  // what it may use has to be one.
  for (const name of UNSUPPORTED) api[name] ??= stub(host, ext, name)
  return withStubs(host, ext, "", api)
}

// Namespaces, classes and enums of the vscode module Bee doesn't implement.
const UNSUPPORTED = `
  languages debug tasks scm tests notebooks authentication comments l10n chat lm
  TreeItem TreeItemCollapsibleState TreeItemCheckboxState TreeDataProvider
  CompletionItem CompletionItemKind CompletionItemTag CompletionList CompletionTriggerKind
  Hover Location LocationLink Diagnostic DiagnosticRelatedInformation DiagnosticTag
  CodeAction CodeActionKind CodeActionTriggerKind CodeLens DocumentLink DocumentHighlight
  DocumentHighlightKind DocumentSymbol SymbolInformation SymbolKind SymbolTag
  SignatureHelp SignatureInformation ParameterInformation SignatureHelpTriggerKind
  SnippetString TextEdit WorkspaceEdit SnippetTextEdit FoldingRange FoldingRangeKind SelectionRange
  CallHierarchyItem CallHierarchyIncomingCall CallHierarchyOutgoingCall TypeHierarchyItem
  SemanticTokens SemanticTokensBuilder SemanticTokensLegend SemanticTokensEdit SemanticTokensEdits
  InlayHint InlayHintKind InlayHintLabelPart InlineCompletionItem InlineCompletionList
  InlineCompletionTriggerKind InlineValueText InlineValueVariableLookup InlineValueEvaluatableExpression
  Color ColorInformation ColorPresentation EvaluatableExpression LinkedEditingRanges
  DocumentDropEdit DocumentPasteEdit DataTransfer DataTransferItem
  DebugAdapterExecutable DebugAdapterServer DebugAdapterNamedPipeServer DebugAdapterInlineImplementation
  DebugConfigurationProviderTriggerKind Breakpoint SourceBreakpoint FunctionBreakpoint DebugConsoleMode
  Task TaskGroup TaskScope TaskRevealKind TaskPanelKind ShellExecution ProcessExecution CustomExecution
  ShellQuoting TerminalLink TerminalProfile TerminalLocation TerminalExitReason
  FileSystemError FileChangeType FilePermission RelativePattern QuickPickItemKind QuickInputButtons
  TextEditorCursorStyle TextEditorLineNumbersStyle TextEditorSelectionChangeKind
  TextDocumentChangeReason TextDocumentSaveReason DecorationRangeBehavior OverviewRulerLane
  FileDecoration TabInputText TabInputTextDiff TabInputCustom TabInputWebview TabInputNotebook
  NotebookCellKind NotebookCellData NotebookData NotebookRange NotebookCellOutput NotebookCellOutputItem
  NotebookCellStatusBarItem NotebookEditorRevealType TestRunProfileKind TestMessage TestTag TestRunRequest
  CommentMode CommentThreadCollapsibleState CommentThreadState SourceControlInputBoxValidationType
  LanguageStatusSeverity InputBoxValidationSeverity EnvironmentVariableMutatorType
  LanguageModelChatMessage LanguageModelChatMessageRole LanguageModelError TelemetryTrustedValue
  ChatResultFeedbackKind ChatRequestTurn ChatResponseTurn McpStdioServerDefinition McpHttpServerDefinition
  PortAutoForwardAction ExtensionRuntime StandardTokenType SyntaxTokenType CancellationError
`.split(/\s+/).filter(Boolean)

// "$(sync~spin) Syncing" → "Syncing": Bee's status bar shows the text.
const stripIcons = text => String(text ?? "").replace(/\$\([a-z0-9-]+(~spin)?\)\s*/g, "").trim()

// What activate(context) gets.
const createContext = (host, ext, {storage, globalStorage}) => ({
  subscriptions: ext.subscriptions,
  extensionPath: ext.dir,
  extensionUri: Uri.file(ext.dir),
  extensionMode: types.ExtensionMode.Production,
  extension: host.extensionInfo(ext.id),
  asAbsolutePath: relative => path.join(ext.dir, relative),
  globalState: new Memento(path.join(globalStorage, "state.json")),
  workspaceState: new Memento(path.join(storage, "state.json")),
  globalStorageUri: Uri.file(globalStorage),
  globalStoragePath: globalStorage,
  storageUri: Uri.file(storage),
  storagePath: storage,
  logUri: Uri.file(path.join(globalStorage, "logs")),
  logPath: path.join(globalStorage, "logs"),
  secrets: {get: async () => undefined, store: async () => {}, delete: async () => {}, onDidChange: new EventEmitter().event},
  environmentVariableCollection: stub(host, ext, "ExtensionContext.environmentVariableCollection"),
})

module.exports = {createApi, createContext, TextEditor, VERSION}
