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
  toString() {
    const encoded = this.path.split("/").map(encodeURIComponent).join("/")
    return (
      `${this.scheme}://${this.authority}${encoded}` +
      (this.query ? `?${this.query}` : "") +
      (this.fragment ? `#${encodeURIComponent(this.fragment)}` : "")
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
}

module.exports = {
  Disposable, EventEmitter, Position, Range, Selection, Uri, ThemeIcon, ThemeColor,
  MarkdownString, CancellationTokenSource, ...enums,
}
