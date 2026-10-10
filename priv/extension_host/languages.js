// vscode.languages: what extensions (and their language clients) register
// to give the editor its language features, and the diagnostics they find.
//
// A provider is kept with its selector and its extension; the host asks
// the ones matching a document (`providers(feature, document)`). Bee is
// told which features exist for which documents (`providers`), and each
// change of a file's diagnostics (`diagnostics`).
"use strict"

const glob = require("./glob")
const {Disposable, EventEmitter, Uri} = require("./types")

// register*Provider → the feature's name in Bee.
const FEATURES = {
  registerCompletionItemProvider: "completion",
  registerHoverProvider: "hover",
  registerDefinitionProvider: "definition",
  registerTypeDefinitionProvider: "typeDefinition",
  registerDeclarationProvider: "declaration",
  registerImplementationProvider: "implementation",
  registerReferenceProvider: "references",
  registerDocumentHighlightProvider: "documentHighlight",
  registerDocumentSymbolProvider: "documentSymbol",
  registerCodeActionsProvider: "codeAction",
  registerCodeLensProvider: "codeLens",
  registerDocumentFormattingEditProvider: "formatting",
  registerDocumentRangeFormattingEditProvider: "rangeFormatting",
  registerOnTypeFormattingEditProvider: "onTypeFormatting",
  registerRenameProvider: "rename",
  registerSignatureHelpProvider: "signatureHelp",
  registerDocumentLinkProvider: "documentLink",
  registerColorProvider: "color",
  registerFoldingRangeProvider: "foldingRange",
  registerSelectionRangeProvider: "selectionRange",
  registerCallHierarchyProvider: "callHierarchy",
  registerTypeHierarchyProvider: "typeHierarchy",
  registerDocumentSemanticTokensProvider: "semanticTokens",
  registerDocumentRangeSemanticTokensProvider: "rangeSemanticTokens",
  registerInlayHintsProvider: "inlayHint",
  registerInlineValuesProvider: "inlineValue",
  registerLinkedEditingRangeProvider: "linkedEditingRange",
  registerEvaluatableExpressionProvider: "evaluatableExpression",
  registerInlineCompletionItemProvider: "inlineCompletion",
  registerDocumentDropEditProvider: "documentDrop",
  registerDocumentPasteEditProvider: "documentPaste",
}

// How well `selector` fits `document`: 0 when it doesn't (VS Code's
// languages.match: 10 for a language, 5 for "*").
const score = (selector, document, root) => {
  if (Array.isArray(selector)) return Math.max(0, ...selector.map(one => score(one, document, root)))
  if (typeof selector === "string") return selector === "*" ? 5 : selector === document.languageId ? 10 : 0
  if (!selector || typeof selector !== "object") return 0
  let result = 0
  if (selector.notebookType) return 0
  if (selector.scheme) {
    if (selector.scheme !== "*" && selector.scheme !== document.uri.scheme) return 0
    result = selector.scheme === "*" ? 5 : 10
  }
  if (selector.language) {
    if (selector.language !== "*" && selector.language !== document.languageId) return 0
    result = Math.max(result, selector.language === "*" ? 5 : 10)
  }
  if (selector.pattern) {
    if (!glob.matches(selector.pattern, document.uri.fsPath, root)) return 0
    result = Math.max(result, 10)
  }
  return result
}

// A selector as data, for Bee to tell which languages a feature exists for.
const describe = selector =>
  [].concat(selector).map(one =>
    typeof one === "string"
      ? {language: one}
      : {
          language: one && one.language,
          scheme: one && one.scheme,
          pattern: one && one.pattern ? String(one.pattern.pattern || one.pattern) : undefined,
        },
  )

const severityName = ["error", "warning", "info", "hint"]

// A Diagnostic as data: line/character positions (the file may not be open).
const plainDiagnostic = diagnostic => ({
  from: {line: diagnostic.range.start.line, character: diagnostic.range.start.character},
  to: {line: diagnostic.range.end.line, character: diagnostic.range.end.character},
  severity: severityName[diagnostic.severity] || "error",
  message: String(diagnostic.message),
  source: diagnostic.source ? String(diagnostic.source) : null,
  code:
    diagnostic.code === undefined || diagnostic.code === null
      ? null
      : String(typeof diagnostic.code === "object" ? diagnostic.code.value : diagnostic.code),
  tags: diagnostic.tags || [],
})

// The host's part: every extension's providers and diagnostics.
class Languages {
  constructor(host) {
    this.host = host
    this.entries = [] // {feature, selector, provider, extension, options}
    this.collections = new Set()
    this.onDiagnostics = new EventEmitter()
    this.nextCollection = 0
    this.announced = null
  }

  // The providers of `feature` for `document`, best fit first.
  providers(feature, document) {
    return this.entries
      .filter(entry => entry.feature === feature)
      .map(entry => ({entry, score: score(entry.selector, document, this.host.root)}))
      .filter(({score}) => score > 0)
      .sort((a, b) => b.score - a.score)
      .map(({entry}) => entry)
  }

  register(extension, feature, selector, provider, options) {
    const entry = {feature, selector, provider, extension, options}
    this.entries.push(entry)
    this.announce()
    return new Disposable(() => {
      const index = this.entries.indexOf(entry)
      if (index >= 0) this.entries.splice(index, 1)
      this.announce()
    })
  }

  // Tells Bee what there is (once per turn: registrations come in bursts).
  announce() {
    if (this.announced) return
    this.announced = setImmediate(() => {
      this.announced = null
      this.host.notify("providers", {
        providers: this.entries.map(entry => ({
          feature: entry.feature,
          extension: entry.extension.name,
          selector: describe(entry.selector),
          triggerCharacters: entry.options.triggerCharacters || [],
        })),
      })
    })
  }

  // Every collection's diagnostics of a file.
  diagnosticsOf(uri) {
    return [...this.collections].flatMap(collection => collection.get(uri) || [])
  }

  // Everything of an extension that is going away.
  forget(extension) {
    this.entries = this.entries.filter(entry => entry.extension !== extension)
    for (const collection of [...this.collections]) if (collection._extension === extension) collection.dispose()
    this.announce()
  }

  api(extension) {
    const languages = this
    const host = this.host
    const api = {
      match: (selector, document) => score(selector, document, host.root),
      getLanguages: () => host.request("getLanguages", {}),
      setTextDocumentLanguage: async document => document,
      createDiagnosticCollection: name => new DiagnosticCollection(languages, extension, name),
      getDiagnostics: uri => {
        if (uri) return [...languages.collections].flatMap(collection => collection.get(uri) || [])
        const all = new Map()
        for (const collection of languages.collections) {
          collection.forEach((fileUri, diagnostics) => {
            const key = fileUri.toString()
            if (!all.has(key)) all.set(key, [fileUri, []])
            all.get(key)[1].push(...diagnostics)
          })
        }
        return [...all.values()]
      },
      onDidChangeDiagnostics: languages.onDiagnostics.event,
      // Shown nowhere yet: kept so its owner can set and dispose it.
      createLanguageStatusItem: (id, selector) => ({
        id, selector, name: undefined, text: "", detail: undefined, severity: 0, busy: false,
        command: undefined, accessibilityInformation: undefined, dispose() {},
      }),
      setLanguageConfiguration: () => new Disposable(() => {}),
      registerWorkspaceSymbolProvider: provider => languages.register(extension, "workspaceSymbol", "*", provider, {}),
    }
    for (const [method, feature] of Object.entries(FEATURES)) {
      api[method] = (selector, provider, ...rest) => languages.register(extension, feature, selector, provider, options(feature, rest))
    }
    return api
  }
}

// What follows the provider in register*Provider(selector, provider, …).
const options = (feature, rest) => {
  if (feature === "completion") return {triggerCharacters: rest.filter(c => typeof c === "string")}
  if (feature === "signatureHelp") {
    const meta = rest[0] && typeof rest[0] === "object" ? rest[0] : {triggerCharacters: rest}
    return {triggerCharacters: meta.triggerCharacters || [], retriggerCharacters: meta.retriggerCharacters || []}
  }
  if (feature === "onTypeFormatting") return {triggerCharacters: rest.filter(c => typeof c === "string")}
  if (feature === "codeAction") return rest[0] || {}
  if (feature === "semanticTokens" || feature === "rangeSemanticTokens") return {legend: rest[0]}
  return rest[0] && typeof rest[0] === "object" ? rest[0] : {}
}

class DiagnosticCollection {
  constructor(languages, extension, name) {
    this._languages = languages
    this._extension = extension
    this.name = name || `diagnostics-${++languages.nextCollection}`
    // What Bee files its diagnostics under.
    this._owner = `${extension.name}/${this.name}/${++languages.nextCollection}`
    this._files = new Map() // uri string → {uri, diagnostics}
    languages.collections.add(this)
  }

  // set(uri, diagnostics) or set([[uri, diagnostics], …])
  set(first, diagnostics) {
    if (Array.isArray(first)) {
      const byFile = new Map()
      for (const [uri, list] of first) {
        const key = uri.toString()
        if (!byFile.has(key)) byFile.set(key, {uri, diagnostics: []})
        if (list) byFile.get(key).diagnostics.push(...list)
      }
      for (const {uri, diagnostics: list} of byFile.values()) this._put(uri, list)
    } else {
      this._put(first, diagnostics || [])
    }
  }

  _put(uri, diagnostics) {
    const key = uri.toString()
    if (diagnostics.length === 0) {
      if (!this._files.delete(key)) return
    } else {
      this._files.set(key, {uri, diagnostics: [...diagnostics]})
    }
    this._tell([uri])
  }

  delete(uri) {
    this._put(uri, [])
  }

  clear() {
    const uris = [...this._files.values()].map(file => file.uri)
    this._files.clear()
    if (uris.length) this._tell(uris)
  }

  forEach(callback, thisArg) {
    for (const {uri, diagnostics} of this._files.values()) callback.call(thisArg, uri, diagnostics, this)
  }

  get(uri) {
    const file = this._files.get(uri.toString())
    return file ? [...file.diagnostics] : undefined
  }

  has(uri) {
    return this._files.has(uri.toString())
  }

  [Symbol.iterator]() {
    return [...this._files.values()].map(({uri, diagnostics}) => [uri, diagnostics])[Symbol.iterator]()
  }

  dispose() {
    this.clear()
    this._languages.collections.delete(this)
  }

  _tell(uris) {
    for (const uri of uris) {
      if (uri.scheme !== "file") continue
      const file = this._files.get(uri.toString())
      this._languages.host.notify("diagnostics", {
        owner: this._owner,
        path: uri.fsPath,
        diagnostics: file ? file.diagnostics.map(plainDiagnostic) : [],
      })
    }
    this._languages.onDiagnostics.fire({uris})
  }
}

module.exports = {Languages, score, FEATURES}
