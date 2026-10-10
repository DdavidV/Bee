// The text documents Bee has open in the host's workspace, as the vscode
// API shows them. Bee sends their text; positions are computed here.
"use strict"

const {EventEmitter, Position, Range, Uri, EndOfLine} = require("./types")

class TextDocument {
  constructor(fsPath, text, languageId, version) {
    this.uri = Uri.file(fsPath)
    this.fileName = fsPath
    this.languageId = languageId || "plaintext"
    this.isUntitled = false
    this.isClosed = false
    this.isDirty = false
    this._set(text, version)
  }

  _set(text, version) {
    this._text = text
    this.version = version || (this.version || 0) + 1
    this._lines = null
    this.eol = text.includes("\r\n") ? EndOfLine.CRLF : EndOfLine.LF
  }

  // Offsets at which each line starts.
  _starts() {
    if (!this._lines) {
      const starts = [0]
      for (let i = 0; i < this._text.length; i++) if (this._text[i] === "\n") starts.push(i + 1)
      this._lines = starts
    }
    return this._lines
  }

  get lineCount() {
    return this._starts().length
  }

  getText(range) {
    if (!range) return this._text
    return this._text.slice(this.offsetAt(range.start), this.offsetAt(range.end))
  }

  lineAt(lineOrPosition) {
    const starts = this._starts()
    let line = typeof lineOrPosition === "number" ? lineOrPosition : lineOrPosition.line
    line = Math.max(0, Math.min(line, starts.length - 1))
    const end = line + 1 < starts.length ? starts[line + 1] : this._text.length
    const full = this._text.slice(starts[line], end)
    const text = full.replace(/\r?\n$/, "")
    const firstNonWhitespace = text.search(/\S/)
    return {
      lineNumber: line,
      text,
      range: new Range(line, 0, line, text.length),
      rangeIncludingLineBreak: new Range(line, 0, line, full.length),
      firstNonWhitespaceCharacterIndex: firstNonWhitespace < 0 ? text.length : firstNonWhitespace,
      isEmptyOrWhitespace: firstNonWhitespace < 0,
    }
  }

  offsetAt(position) {
    const starts = this._starts()
    const line = Math.max(0, Math.min(position.line, starts.length - 1))
    const end = line + 1 < starts.length ? starts[line + 1] - 1 : this._text.length
    return Math.max(starts[line], Math.min(starts[line] + position.character, end))
  }

  positionAt(offset) {
    const starts = this._starts()
    offset = Math.max(0, Math.min(offset, this._text.length))
    let low = 0
    let high = starts.length - 1
    while (low < high) {
      const mid = Math.ceil((low + high) / 2)
      if (starts[mid] <= offset) low = mid
      else high = mid - 1
    }
    return new Position(low, offset - starts[low])
  }

  validatePosition(position) {
    return this.positionAt(this.offsetAt(position))
  }

  validateRange(range) {
    return new Range(this.validatePosition(range.start), this.validatePosition(range.end))
  }

  getWordRangeAtPosition(position, regex = /[\p{L}\p{N}_]+/gu) {
    const {text} = this.lineAt(position)
    const pattern = new RegExp(regex.source, regex.flags.includes("g") ? regex.flags : regex.flags + "g")
    for (const match of text.matchAll(pattern)) {
      const end = match.index + match[0].length
      if (match[0] && match.index <= position.character && position.character <= end) {
        return new Range(position.line, match.index, position.line, end)
      }
    }
    return undefined
  }

  save() {
    return Promise.resolve(false)
  }
}

class Documents {
  constructor() {
    this.byPath = new Map()
    this.onOpen = new EventEmitter()
    this.onClose = new EventEmitter()
    this.onChange = new EventEmitter()
    this.onSave = new EventEmitter()
  }

  get(fsPath) {
    return this.byPath.get(fsPath)
  }

  all() {
    return [...this.byPath.values()]
  }

  // Bee's text of an open file: a new document, or a changed one.
  put({path, text, languageId, version}) {
    const existing = this.byPath.get(path)
    if (!existing) {
      const document = new TextDocument(path, text, languageId, version)
      this.byPath.set(path, document)
      this.onOpen.fire(document)
      return document
    }
    if (existing._text === text) return existing
    const before = existing._text
    existing._set(text, version)
    existing.isDirty = true
    this.onChange.fire({document: existing, contentChanges: [change(existing, before, text)], reason: undefined})
    return existing
  }

  saved(fsPath) {
    const document = this.byPath.get(fsPath)
    if (!document) return
    document.isDirty = false
    this.onSave.fire(document)
  }

  close(fsPath) {
    const document = this.byPath.get(fsPath)
    if (!document) return
    this.byPath.delete(fsPath)
    document.isClosed = true
    this.onClose.fire(document)
  }
}

// One change covering what differs between two texts.
const change = (document, before, after) => {
  let start = 0
  const max = Math.min(before.length, after.length)
  while (start < max && before[start] === after[start]) start++
  let endBefore = before.length
  let endAfter = after.length
  while (endBefore > start && endAfter > start && before[endBefore - 1] === after[endAfter - 1]) {
    endBefore--
    endAfter--
  }
  const old = new TextDocument(document.fileName, before, document.languageId, 1)
  return {
    range: new Range(old.positionAt(start), old.positionAt(endBefore)),
    rangeOffset: start,
    rangeLength: endBefore - start,
    text: after.slice(start, endAfter),
  }
}

module.exports = {TextDocument, Documents}
