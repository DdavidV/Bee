// The value types of the vscode API that extensions build themselves.
"use strict"

const path = require("node:path")

class Disposable {
  constructor(callOnDispose) {
    this._dispose = callOnDispose
  }
  static from(...disposables) {
    return new Disposable(() => disposables.forEach(d => d && d.dispose && d.dispose()))
  }
  dispose() {
    const dispose = this._dispose
    this._dispose = null
    if (typeof dispose === "function") dispose()
  }
}

class EventEmitter {
  constructor() {
    this._listeners = new Set()
    this.event = (listener, thisArg, disposables) => {
      const entry = {listener, thisArg}
      this._listeners.add(entry)
      const disposable = new Disposable(() => this._listeners.delete(entry))
      if (Array.isArray(disposables)) disposables.push(disposable)
      return disposable
    }
  }
  fire(data) {
    for (const {listener, thisArg} of [...this._listeners]) {
      try {
        listener.call(thisArg, data)
      } catch (e) {
        console.error(e)
      }
    }
  }
  dispose() {
    this._listeners.clear()
  }
}

class Position {
  constructor(line, character) {
    this.line = line
    this.character = character
  }
  compareTo(other) {
    return this.line - other.line || this.character - other.character
  }
  isBefore(other) {
    return this.compareTo(other) < 0
  }
  isBeforeOrEqual(other) {
    return this.compareTo(other) <= 0
  }
  isAfter(other) {
    return this.compareTo(other) > 0
  }
  isAfterOrEqual(other) {
    return this.compareTo(other) >= 0
  }
  isEqual(other) {
    return this.compareTo(other) === 0
  }
  translate(lineDelta = 0, characterDelta = 0) {
    if (lineDelta && typeof lineDelta === "object") ({lineDelta = 0, characterDelta = 0} = lineDelta)
    return new Position(this.line + lineDelta, this.character + characterDelta)
  }
  with(line = this.line, character = this.character) {
    if (line && typeof line === "object") ({line = this.line, character = this.character} = line)
    return new Position(line, character)
  }
}

class Range {
  constructor(a, b, c, d) {
    let start = a
    let end = b
    if (typeof a === "number") {
      start = new Position(a, b)
      end = new Position(c, d)
    }
    if (start.isAfter(end)) [start, end] = [end, start]
    this.start = start
    this.end = end
  }
  get isEmpty() {
    return this.start.isEqual(this.end)
  }
  get isSingleLine() {
    return this.start.line === this.end.line
  }
  contains(other) {
    return other instanceof Range
      ? this.contains(other.start) && this.contains(other.end)
      : other.isAfterOrEqual(this.start) && other.isBeforeOrEqual(this.end)
  }
  isEqual(other) {
    return this.start.isEqual(other.start) && this.end.isEqual(other.end)
  }
  intersection(other) {
    const start = this.start.isAfter(other.start) ? this.start : other.start
    const end = this.end.isBefore(other.end) ? this.end : other.end
    return start.isAfter(end) ? undefined : new Range(start, end)
  }
  union(other) {
    return new Range(
      this.start.isBefore(other.start) ? this.start : other.start,
      this.end.isAfter(other.end) ? this.end : other.end,
    )
  }
  with(start = this.start, end = this.end) {
    if (start && !(start instanceof Position)) ({start = this.start, end = this.end} = start)
    return new Range(start, end)
  }
}

class Selection extends Range {
  constructor(a, b, c, d) {
    let anchor = a
    let active = b
    if (typeof a === "number") {
      anchor = new Position(a, b)
      active = new Position(c, d)
    }
    super(anchor, active)
    this.anchor = anchor
    this.active = active
  }
  get isReversed() {
    return this.anchor.isAfter(this.active)
  }
}

// Files only (and whatever else as an opaque string).
class Uri {
  constructor(scheme, authority, fsPath, query, fragment) {
    this.scheme = scheme
    this.authority = authority || ""
    this.path = fsPath || ""
    this.query = query || ""
    this.fragment = fragment || ""
  }
  static file(fsPath) {
    return new Uri("file", "", path.resolve(fsPath))
  }
  static parse(value) {
    try {
      const url = new URL(value)
      return new Uri(
        url.protocol.replace(/:$/, ""),
        url.host,
        decodeURIComponent(url.pathname),
        url.search.replace(/^\?/, ""),
        decodeURIComponent(url.hash.replace(/^#/, "")),
      )
    } catch (_e) {
      return Uri.file(value)
    }
  }
  static joinPath(base, ...segments) {
    return base.with({path: path.posix.join(base.path, ...segments)})
  }
  static from({scheme, authority, path: fsPath, query, fragment}) {
    return new Uri(scheme, authority, fsPath, query, fragment)
  }
  static isUri(value) {
    return value instanceof Uri
  }
  get fsPath() {
    return this.path
  }
  with({scheme = this.scheme, authority = this.authority, path: fsPath = this.path, query = this.query, fragment = this.fragment}) {
    return new Uri(scheme, authority, fsPath, query, fragment)
  }
  // As VS Code writes it (what language servers get, and send back).
  toString() {
    const encode = text => encodeURIComponent(text).replace(/[!'()*]/g, c => "%" + c.charCodeAt(0).toString(16).toUpperCase())
    const encoded = this.path.split("/").map(encode).join("/")
    const authority = this.authority || this.scheme === "file" ? `//${this.authority}` : ""
    return (
      `${this.scheme}:${authority}${encoded}` +
      (this.query ? `?${this.query}` : "") +
      (this.fragment ? `#${encode(this.fragment)}` : "")
    )
  }
  toJSON() {
    return {$uri: this.scheme === "file" ? this.path : this.toString()}
  }
}

class ThemeIcon {
  constructor(id, color) {
    this.id = id
    this.color = color
  }
}
ThemeIcon.File = new ThemeIcon("file")
ThemeIcon.Folder = new ThemeIcon("folder")

class ThemeColor {
  constructor(id) {
    this.id = id
  }
}

class MarkdownString {
  constructor(value = "", supportThemeIcons = false) {
    this.value = value
    this.supportThemeIcons = supportThemeIcons
    this.isTrusted = false
  }
  appendText(text) {
    this.value += text
    return this
  }
  appendMarkdown(text) {
    this.value += text
    return this
  }
  appendCodeblock(code, language = "") {
    this.value += `\n\`\`\`${language}\n${code}\n\`\`\`\n`
    return this
  }
}

class CancellationTokenSource {
  constructor() {
    const emitter = new EventEmitter()
    this.token = {isCancellationRequested: false, onCancellationRequested: emitter.event}
    this._emitter = emitter
  }
  cancel() {
    if (this.token.isCancellationRequested) return
    this.token.isCancellationRequested = true
    this._emitter.fire()
  }
  dispose() {
    this._emitter.dispose()
  }
}

// ---- What language providers return (and language clients build)

class Location {
  constructor(uri, rangeOrPosition) {
    this.uri = uri
    this.range = rangeOrPosition instanceof Position ? new Range(rangeOrPosition, rangeOrPosition) : rangeOrPosition
  }
}

class DiagnosticRelatedInformation {
  constructor(location, message) {
    this.location = location
    this.message = message
  }
}

class Diagnostic {
  constructor(range, message, severity = 0) {
    this.range = range
    this.message = message
    this.severity = severity
    this.source = undefined
    this.code = undefined
    this.relatedInformation = undefined
    this.tags = undefined
  }
}

class Hover {
  constructor(contents, range) {
    this.contents = Array.isArray(contents) ? contents : [contents]
    this.range = range
  }
}

class SnippetString {
  constructor(value = "") {
    this.value = value
    this._tabstop = 1
  }
  static isSnippetString(thing) {
    return thing instanceof SnippetString
  }
  appendText(text) {
    this.value += String(text).replace(/[$}\\]/g, "\\$&")
    return this
  }
  appendTabstop(number = this._tabstop++) {
    this.value += `$${number}`
    return this
  }
  appendPlaceholder(value, number = this._tabstop++) {
    const text = typeof value === "function" ? (() => { const nested = new SnippetString(); nested._tabstop = this._tabstop; value(nested); this._tabstop = nested._tabstop; return nested.value })() : String(value).replace(/[$}\\]/g, "\\$&")
    this.value += `\${${number}:${text}}`
    return this
  }
  appendChoice(values, number = this._tabstop++) {
    this.value += `\${${number}|${values.map(v => String(v).replace(/[|,\\]/g, "\\$&")).join(",")}|}`
    return this
  }
  appendVariable(name, defaultValue) {
    const text = typeof defaultValue === "function" ? (() => { const nested = new SnippetString(); defaultValue(nested); return nested.value })() : defaultValue === undefined ? "" : String(defaultValue).replace(/[$}\\]/g, "\\$&")
    this.value += text ? `\${${name}:${text}}` : `\${${name}}`
    return this
  }
}

class TextEdit {
  constructor(range, newText) {
    this.range = range
    this.newText = newText
  }
  static isTextEdit(thing) {
    return thing instanceof TextEdit
  }
  static replace(range, newText) {
    return new TextEdit(range, newText)
  }
  static insert(position, newText) {
    return new TextEdit(new Range(position, position), newText)
  }
  static delete(range) {
    return new TextEdit(range, "")
  }
  static setEndOfLine(eol) {
    const edit = new TextEdit(new Range(0, 0, 0, 0), "")
    edit.newEol = eol
    return edit
  }
}

class SnippetTextEdit {
  constructor(range, snippet) {
    this.range = range
    this.snippet = snippet
  }
  static replace(range, snippet) {
    return new SnippetTextEdit(range, snippet)
  }
  static insert(position, snippet) {
    return new SnippetTextEdit(new Range(position, position), snippet)
  }
}

// Text edits by file, and files to create, delete or rename.
class WorkspaceEdit {
  constructor() {
    this._edits = new Map() // uri string → {uri, edits}
    this._files = []
  }
  _entry(uri) {
    const key = uri.toString()
    if (!this._edits.has(key)) this._edits.set(key, {uri, edits: []})
    return this._edits.get(key)
  }
  replace(uri, range, newText) {
    this._entry(uri).edits.push(new TextEdit(range, newText))
  }
  insert(uri, position, newText) {
    this.replace(uri, new Range(position, position), newText)
  }
  delete(uri, range) {
    this.replace(uri, range, "")
  }
  has(uri) {
    return this._edits.has(uri.toString())
  }
  set(uri, edits) {
    if (!edits) this._edits.delete(uri.toString())
    else {
      const entry = this._entry(uri)
      // TextEdit, SnippetTextEdit, or [edit, metadata] pairs.
      entry.edits = edits.map(edit => (Array.isArray(edit) ? edit[0] : edit)).map(edit =>
        edit instanceof SnippetTextEdit ? new TextEdit(edit.range, plainSnippet(edit.snippet.value)) : edit,
      )
    }
  }
  get(uri) {
    const entry = this._edits.get(uri.toString())
    return entry ? [...entry.edits] : []
  }
  createFile(uri, options) {
    this._files.push({kind: "create", uri, options: options || {}})
  }
  deleteFile(uri, options) {
    this._files.push({kind: "delete", uri, options: options || {}})
  }
  renameFile(oldUri, newUri, options) {
    this._files.push({kind: "rename", uri: oldUri, newUri, options: options || {}})
  }
  entries() {
    return [...this._edits.values()].map(({uri, edits}) => [uri, [...edits]])
  }
  get size() {
    return this._edits.size + this._files.length
  }
}

// "foo(${1:bar})$0" → "foo(bar)": a snippet as the text it starts as.
const plainSnippet = value =>
  String(value)
    .replace(/\$\{\d+:([^{}]*)\}/g, "$1")
    .replace(/\$\{\d+\|([^,|}]*)[^}]*\|\}/g, "$1")
    .replace(/\$\{\d+\}|\$\d+/g, "")
    .replace(/\\([$}\\])/g, "$1")

class CompletionItem {
  constructor(label, kind) {
    this.label = label
    this.kind = kind
  }
}

class CompletionList {
  constructor(items = [], isIncomplete = false) {
    this.items = items
    this.isIncomplete = isIncomplete
  }
}

class ParameterInformation {
  constructor(label, documentation) {
    this.label = label
    this.documentation = documentation
  }
}

class SignatureInformation {
  constructor(label, documentation) {
    this.label = label
    this.documentation = documentation
    this.parameters = []
  }
}

class SignatureHelp {
  constructor() {
    this.signatures = []
    this.activeSignature = 0
    this.activeParameter = 0
  }
}

class DocumentSymbol {
  constructor(name, detail, kind, range, selectionRange) {
    this.name = name
    this.detail = detail
    this.kind = kind
    this.range = range
    this.selectionRange = selectionRange
    this.children = []
  }
}

class SymbolInformation {
  // (name, kind, containerName, location) or the older (name, kind, range, uri, containerName)
  constructor(name, kind, a, b, c) {
    this.name = name
    this.kind = kind
    if (a instanceof Range) {
      this.location = new Location(b, a)
      this.containerName = c
    } else {
      this.containerName = a
      this.location = b
    }
  }
}

class CodeActionKind {
  constructor(value) {
    this.value = value
  }
  append(part) {
    return new CodeActionKind(this.value ? `${this.value}.${part}` : part)
  }
  contains(other) {
    return this.value === other.value || other.value.startsWith(this.value + ".") || this.value === ""
  }
  intersects(other) {
    return this.contains(other) || other.contains(this)
  }
}
CodeActionKind.Empty = new CodeActionKind("")
CodeActionKind.QuickFix = new CodeActionKind("quickfix")
CodeActionKind.Refactor = new CodeActionKind("refactor")
CodeActionKind.RefactorExtract = new CodeActionKind("refactor.extract")
CodeActionKind.RefactorInline = new CodeActionKind("refactor.inline")
CodeActionKind.RefactorMove = new CodeActionKind("refactor.move")
CodeActionKind.RefactorRewrite = new CodeActionKind("refactor.rewrite")
CodeActionKind.Source = new CodeActionKind("source")
CodeActionKind.SourceOrganizeImports = new CodeActionKind("source.organizeImports")
CodeActionKind.SourceFixAll = new CodeActionKind("source.fixAll")
CodeActionKind.Notebook = new CodeActionKind("notebook")

class CodeAction {
  constructor(title, kind) {
    this.title = title
    this.kind = kind
  }
}

class CodeLens {
  constructor(range, command) {
    this.range = range
    this.command = command
  }
  get isResolved() {
    return !!this.command
  }
}

class DocumentHighlight {
  constructor(range, kind = 0) {
    this.range = range
    this.kind = kind
  }
}

class DocumentLink {
  constructor(range, target) {
    this.range = range
    this.target = target
  }
}

class FoldingRange {
  constructor(start, end, kind) {
    this.start = start
    this.end = end
    this.kind = kind
  }
}

class SelectionRange {
  constructor(range, parent) {
    this.range = range
    this.parent = parent
  }
}

class CallHierarchyItem {
  constructor(kind, name, detail, uri, range, selectionRange) {
    Object.assign(this, {kind, name, detail, uri, range, selectionRange})
  }
}

class CallHierarchyIncomingCall {
  constructor(from, fromRanges) {
    this.from = from
    this.fromRanges = fromRanges
  }
}

class CallHierarchyOutgoingCall {
  constructor(to, fromRanges) {
    this.to = to
    this.fromRanges = fromRanges
  }
}

class TypeHierarchyItem {
  constructor(kind, name, detail, uri, range, selectionRange) {
    Object.assign(this, {kind, name, detail, uri, range, selectionRange})
  }
}

class InlayHintLabelPart {
  constructor(value) {
    this.value = value
  }
}

class InlayHint {
  constructor(position, label, kind) {
    this.position = position
    this.label = label
    this.kind = kind
  }
}

class Color {
  constructor(red, green, blue, alpha) {
    Object.assign(this, {red, green, blue, alpha})
  }
}

class ColorInformation {
  constructor(range, color) {
    this.range = range
    this.color = color
  }
}

class ColorPresentation {
  constructor(label) {
    this.label = label
  }
}

class SemanticTokensLegend {
  constructor(tokenTypes, tokenModifiers = []) {
    this.tokenTypes = tokenTypes
    this.tokenModifiers = tokenModifiers
  }
}

class SemanticTokens {
  constructor(data, resultId) {
    this.data = data
    this.resultId = resultId
  }
}

class SemanticTokensEdit {
  constructor(start, deleteCount, data) {
    Object.assign(this, {start, deleteCount, data})
  }
}

class SemanticTokensEdits {
  constructor(edits, resultId) {
    this.edits = edits
    this.resultId = resultId
  }
}

class SemanticTokensBuilder {
  constructor() {
    this._data = []
  }
  push() {}
  build(resultId) {
    return new SemanticTokens(new Uint32Array(this._data), resultId)
  }
}

class InlineValueText {
  constructor(range, text) {
    this.range = range
    this.text = text
  }
}

class InlineValueVariableLookup {
  constructor(range, variableName, caseSensitiveLookup = true) {
    Object.assign(this, {range, variableName, caseSensitiveLookup})
  }
}

class InlineValueEvaluatableExpression {
  constructor(range, expression) {
    this.range = range
    this.expression = expression
  }
}

class EvaluatableExpression {
  constructor(range, expression) {
    this.range = range
    this.expression = expression
  }
}

class LinkedEditingRanges {
  constructor(ranges, wordPattern) {
    this.ranges = ranges
    this.wordPattern = wordPattern
  }
}

class InlineCompletionItem {
  constructor(insertText, range, command) {
    Object.assign(this, {insertText, range, command})
  }
}

class InlineCompletionList {
  constructor(items) {
    this.items = items
  }
}

// A glob below a folder.
class RelativePattern {
  constructor(base, pattern) {
    this.baseUri = typeof base === "string" ? Uri.file(base) : base.uri || base
    this.base = this.baseUri.fsPath
    this.pattern = pattern
  }
}

// What an editor tab shows.
class TabInputText {
  constructor(uri) {
    this.uri = uri
  }
}

class TabInputTextDiff {
  constructor(original, modified) {
    this.original = original
    this.modified = modified
  }
}

class TabInputCustom {
  constructor(uri, viewType) {
    this.uri = uri
    this.viewType = viewType
  }
}

class TabInputWebview {
  constructor(viewType) {
    this.viewType = viewType
  }
}

class TabInputNotebook {
  constructor(uri, notebookType) {
    this.uri = uri
    this.notebookType = notebookType
  }
}

class TabInputNotebookDiff {
  constructor(original, modified, notebookType) {
    Object.assign(this, {original, modified, notebookType})
  }
}

class FileSystemError extends Error {
  constructor(messageOrUri, code = "Unknown") {
    super(typeof messageOrUri === "string" ? messageOrUri : messageOrUri ? messageOrUri.toString() : code)
    this.code = code
    this.name = `${code} (FileSystemError)`
  }
  static FileNotFound(m) {
    return new FileSystemError(m, "FileNotFound")
  }
  static FileExists(m) {
    return new FileSystemError(m, "FileExists")
  }
  static FileNotADirectory(m) {
    return new FileSystemError(m, "FileNotADirectory")
  }
  static FileIsADirectory(m) {
    return new FileSystemError(m, "FileIsADirectory")
  }
  static NoPermissions(m) {
    return new FileSystemError(m, "NoPermissions")
  }
  static Unavailable(m) {
    return new FileSystemError(m, "Unavailable")
  }
}

class CancellationError extends Error {
  constructor() {
    super("Canceled")
    this.name = "Canceled"
  }
}

const languageTypes = {
  Location, Diagnostic, DiagnosticRelatedInformation, Hover, SnippetString, TextEdit, SnippetTextEdit,
  WorkspaceEdit, CompletionItem, CompletionList, ParameterInformation, SignatureInformation,
  SignatureHelp, DocumentSymbol, SymbolInformation, CodeActionKind, CodeAction, CodeLens,
  DocumentHighlight, DocumentLink, FoldingRange, SelectionRange, CallHierarchyItem,
  CallHierarchyIncomingCall, CallHierarchyOutgoingCall, TypeHierarchyItem, InlayHintLabelPart,
  InlayHint, Color, ColorInformation, ColorPresentation, SemanticTokensLegend, SemanticTokens,
  SemanticTokensEdit, SemanticTokensEdits, SemanticTokensBuilder, InlineValueText,
  InlineValueVariableLookup, InlineValueEvaluatableExpression, EvaluatableExpression,
  LinkedEditingRanges, InlineCompletionItem, InlineCompletionList, RelativePattern,
  FileSystemError, CancellationError, TabInputText, TabInputTextDiff, TabInputCustom,
  TabInputWebview, TabInputNotebook, TabInputNotebookDiff,
}

const enums = {
  ConfigurationTarget: {Global: 1, Workspace: 2, WorkspaceFolder: 3},
  StatusBarAlignment: {Left: 1, Right: 2},
  ViewColumn: {Active: -1, Beside: -2, One: 1, Two: 2, Three: 3},
  EndOfLine: {LF: 1, CRLF: 2},
  ExtensionMode: {Production: 1, Development: 2, Test: 3},
  ExtensionKind: {UI: 1, Workspace: 2},
  UIKind: {Desktop: 1, Web: 2},
  ProgressLocation: {SourceControl: 1, Window: 10, Notification: 15},
  TextEditorRevealType: {Default: 0, InCenter: 1, InCenterIfOutsideViewport: 2, AtTop: 3},
  DiagnosticSeverity: {Error: 0, Warning: 1, Information: 2, Hint: 3},
  FileType: {Unknown: 0, File: 1, Directory: 2, SymbolicLink: 64},
  LogLevel: {Off: 0, Trace: 1, Debug: 2, Info: 3, Warning: 4, Error: 5},
  ColorThemeKind: {Light: 1, Dark: 2, HighContrast: 3, HighContrastLight: 4},
  DiagnosticTag: {Unnecessary: 1, Deprecated: 2},
  CompletionItemKind: {
    Text: 0, Method: 1, Function: 2, Constructor: 3, Field: 4, Variable: 5, Class: 6, Interface: 7,
    Module: 8, Property: 9, Unit: 10, Value: 11, Enum: 12, Keyword: 13, Snippet: 14, Color: 15,
    File: 16, Reference: 17, Folder: 18, EnumMember: 19, Constant: 20, Struct: 21, Event: 22,
    Operator: 23, TypeParameter: 24, User: 25, Issue: 26,
  },
  CompletionItemTag: {Deprecated: 1},
  CompletionTriggerKind: {Invoke: 0, TriggerCharacter: 1, TriggerForIncompleteCompletions: 2},
  SymbolKind: {
    File: 0, Module: 1, Namespace: 2, Package: 3, Class: 4, Method: 5, Property: 6, Field: 7,
    Constructor: 8, Enum: 9, Interface: 10, Function: 11, Variable: 12, Constant: 13, String: 14,
    Number: 15, Boolean: 16, Array: 17, Object: 18, Key: 19, Null: 20, EnumMember: 21, Struct: 22,
    Event: 23, Operator: 24, TypeParameter: 25,
  },
  SymbolTag: {Deprecated: 1},
  DocumentHighlightKind: {Text: 0, Read: 1, Write: 2},
  SignatureHelpTriggerKind: {Invoke: 1, TriggerCharacter: 2, ContentChange: 3},
  CodeActionTriggerKind: {Invoke: 1, Automatic: 2},
  FoldingRangeKind: {Comment: 1, Imports: 2, Region: 3},
  InlayHintKind: {Type: 1, Parameter: 2},
  InlineCompletionTriggerKind: {Invoke: 0, Automatic: 1},
  TextDocumentSaveReason: {Manual: 1, AfterDelay: 2, FocusOut: 3},
  TextDocumentChangeReason: {Undo: 1, Redo: 2},
  FileChangeType: {Changed: 1, Created: 2, Deleted: 3},
  IndentAction: {None: 0, Indent: 1, IndentOutdent: 2, Outdent: 3},
  LanguageStatusSeverity: {Information: 0, Warning: 1, Error: 2},
  TextEditorSelectionChangeKind: {Keyboard: 1, Mouse: 2, Command: 3},
  TextEditorCursorStyle: {Line: 1, Block: 2, Underline: 3, LineThin: 4, BlockOutline: 5, UnderlineThin: 6},
  TextEditorLineNumbersStyle: {Off: 0, On: 1, Relative: 2, Interval: 3},
  DecorationRangeBehavior: {OpenOpen: 0, ClosedClosed: 1, OpenClosed: 2, ClosedOpen: 3},
  OverviewRulerLane: {Left: 1, Center: 2, Right: 4, Full: 7},
  QuickPickItemKind: {Separator: -1, Default: 0},
  TreeItemCollapsibleState: {None: 0, Collapsed: 1, Expanded: 2},
  TreeItemCheckboxState: {Unchecked: 0, Checked: 1},
  InputBoxValidationSeverity: {Info: 1, Warning: 2, Error: 3},
  NotebookCellKind: {Markup: 1, Code: 2},
  TerminalLocation: {Panel: 1, Editor: 2},
  TaskRevealKind: {Always: 1, Silent: 2, Never: 3},
  TaskPanelKind: {Shared: 1, Dedicated: 2, New: 3},
  TaskScope: {Global: 1, Workspace: 2},
  ShellQuoting: {Escape: 1, Strong: 2, Weak: 3},
  DebugConsoleMode: {Separate: 0, MergeWithParent: 1},
  DebugConfigurationProviderTriggerKind: {Initial: 1, Dynamic: 2},
  TestRunProfileKind: {Run: 1, Debug: 2, Coverage: 3},
  CommentMode: {Editing: 0, Preview: 1},
  CommentThreadCollapsibleState: {Collapsed: 0, Expanded: 1},
  StandardTokenType: {Other: 0, Comment: 1, String: 2, RegEx: 3},
  SyntaxTokenType: {Other: 0, Comment: 1, String: 2, RegEx: 3},
}

module.exports = {
  Disposable, EventEmitter, Position, Range, Selection, Uri, ThemeIcon, ThemeColor,
  MarkdownString, CancellationTokenSource, ...languageTypes, ...enums, plainSnippet,
}
