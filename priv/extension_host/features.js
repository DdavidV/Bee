// Language features for the editor: asks the providers extensions
// registered (languages.js) and gives what they answer as plain data.
//
//   provide(host, {feature, path, …}, token)
//
//   completion         {position, context: {triggerKind, triggerCharacter}}
//                      → {session, incomplete, items: [item]}
//   completionResolve  {session, index} → what the item's provider adds
//   completionAccept   {session, index} → runs the accepted item's command
//   hover              {position} → {contents: [markdown], range} | null
//   definition, typeDefinition, declaration, implementation
//                      {position} → [{path, from, to}]
//   formatting         {options: {tabSize, insertSpaces}, formatter}
//   rangeFormatting    {range, options, formatter}
//                      → {edits: [{from, to, text}], extension} | null
//   references         {position, includeDeclaration} → [{path, from, to}]
//   documentHighlight  {position} → [{from, to, kind: "text"|"read"|"write"}]
//   documentSymbol     → [{name, detail, kind, container, depth, from, to}]
//                        (the outline, flattened, in file order)
//   workspaceSymbol    {query} → [{name, kind, container, path, from, to}]
//                        (no file: every provider is asked)
//   prepareRename      {position} → {placeholder, from, to} | {error}
//   rename             {position, newName} → {applied, files, edits} | {error}
//                        (its edits are applied here, through Bee)
//   codeAction         {range, context: {triggerKind, only}}
//                      → {session, actions: [{index, title, kind, preferred, disabled}]}
//                        (quick fixes and refactorings for the range, with
//                        the diagnostics there as their context)
//   codeActionApply    {session, index} → {applied} | {error}
//                        (resolved if need be; its edit, then its command)
//   signatureHelp      {position, context: {triggerKind, triggerCharacter, isRetrigger}}
//                      → {signatures: [{label, documentation, parameters:
//                         [{label, documentation}]}], activeSignature,
//                         activeParameter} | null
//
// Positions are {line, character}, ranges {from, to} of them (convert.js).
// A provider that throws is logged and left out: the others still answer.
"use strict"

const convert = require("./convert")
const {Position, Range, SnippetString, MarkdownString, CompletionItemKind, SymbolKind, WorkspaceEdit} = require("./types")

const SESSIONS = 4
const KINDS = Object.fromEntries(Object.entries(CompletionItemKind).map(([name, value]) => [value, name.toLowerCase()]))

// What the last completions were made of, for resolve and accept.
const sessions = new Map() // id → [{item, entry}]
let nextSession = 0

const asked = async (entry, method, args, token) => {
  try {
    if (typeof entry.provider[method] !== "function") return undefined
    return await entry.provider[method](...args)
  } catch (e) {
    if (!token.isCancellationRequested && !(e && e.name === "Canceled")) {
      console.error(`${entry.extension.name}: ${entry.feature} failed: ${(e && e.stack) || e}`)
    }
    return undefined
  }
}

// Markdown, whatever documentation came as: a MarkdownString, plain text
// (escaped), or a {language, value} code block.
const escapeMarkdown = text => String(text).replace(/[\\`*_{}[\]()#+\-.!|<>~]/g, "\\$&")
const markdown = (value, plainStrings) => {
  if (value === undefined || value === null) return null
  if (typeof value === "string") return plainStrings ? escapeMarkdown(value) : value
  if (value instanceof MarkdownString || typeof value.value === "string") {
    if (typeof value.language === "string") return "```" + value.language + "\n" + value.value + "\n```"
    return value.value
  }
  return null
}

const plainEdits = edits =>
  (edits || []).filter(edit => edit && edit.range).map(edit => ({...convert.range(edit.range), text: String(edit.newText ?? "")}))

const plainItem = (item, index, entry) => {
  const label = typeof item.label === "string" ? {label: item.label} : item.label || {label: ""}
  const insert = item.textEdit ? item.textEdit.newText : item.insertText
  const snippet = insert instanceof SnippetString
  const range = item.textEdit ? item.textEdit.range : item.range
  return {
    index,
    label: String(label.label),
    detail: label.detail || null,
    description: label.description || null,
    info: item.detail || null,
    kind: KINDS[item.kind] || "text",
    sortText: item.sortText || null,
    filterText: item.filterText || null,
    insertText: snippet ? insert.value : String(insert ?? label.label),
    snippet,
    // An {inserting, replacing} pair: what is before the cursor is replaced.
    range: range ? convert.range(range instanceof Range ? range : range.inserting || range) : null,
    edits: plainEdits(item.additionalTextEdits),
    documentation: markdown(item.documentation, true),
    preselect: !!item.preselect,
    deprecated: (item.tags || []).includes(1),
    commitCharacters: item.commitCharacters || [],
    command: !!item.command,
    resolvable: typeof entry.provider.resolveCompletionItem === "function",
  }
}

const features = {
  async completion(host, document, {position, context}, token) {
    const at = new Position(position.line, position.character)
    const trigger = {triggerKind: (context && context.triggerKind) || 0, triggerCharacter: (context && context.triggerCharacter) || undefined}
    const entries = host.languages
      .providers("completion", document)
      // Asked for a character: only those that wanted it.
      .filter(entry => trigger.triggerKind !== 1 || entry.options.triggerCharacters.includes(trigger.triggerCharacter))
    const results = await Promise.all(entries.map(entry => asked(entry, "provideCompletionItems", [document, at, token, trigger], token)))

    const session = []
    let incomplete = false
    results.forEach((result, i) => {
      if (!result) return
      if (!Array.isArray(result)) incomplete ||= !!result.isIncomplete
      for (const item of Array.isArray(result) ? result : result.items || []) if (item) session.push({item, entry: entries[i]})
    })

    const id = ++nextSession
    sessions.set(id, session)
    for (const old of sessions.keys()) if (old <= id - SESSIONS) sessions.delete(old)
    return {session: id, incomplete, items: session.map(({item, entry}, index) => plainItem(item, index, entry))}
  },

  async completionResolve(host, _document, {session, index}, token) {
    const kept = (sessions.get(session) || [])[index]
    if (!kept) return null
    kept.resolved ??= asked(kept.entry, "resolveCompletionItem", [kept.item, token], token).then(resolved => {
      if (resolved) kept.item = resolved
      return kept.item
    })
    return plainItem(await kept.resolved, index, kept.entry)
  },

  // The item was inserted: its command runs (as it would in VS Code).
  async completionAccept(host, _document, {session, index}) {
    const kept = (sessions.get(session) || [])[index]
    if (!kept) return null
    const item = kept.resolved ? await kept.resolved : kept.item
    if (item.command && item.command.command) {
      await host.executeCommand(kept.entry.extension, item.command.command, item.command.arguments || [])
    }
    return null
  },

  async hover(host, document, {position}, token) {
    const at = new Position(position.line, position.character)
    const entries = host.languages.providers("hover", document)
    const results = await Promise.all(entries.map(entry => asked(entry, "provideHover", [document, at, token], token)))
    const contents = []
    let range = null
    for (const result of results) {
      if (!result) continue
      const parts = [].concat(result.contents ?? []).map(part => markdown(part, false))
      const filled = parts.filter(part => part && part.trim())
      if (filled.length === 0) continue
      contents.push(...filled)
      if (!range && result.range) range = convert.range(result.range)
    }
    return contents.length ? {contents, range} : null
  },
}

// One formatter formats: the one asked for (`formatter`: an extension's id
// or its plugin's name, editor.defaultFormatter), else the best fitting.
const formatter = (host, feature, document, wanted) => {
  const entries = host.languages.providers(feature, document)
  const name = String(wanted || "").toLowerCase()
  return entries.find(entry => name && [entry.extension.id, entry.extension.name].some(id => id.toLowerCase() === name)) || entries[0]
}

const formatted = (entry, edits) => (Array.isArray(edits) ? {edits: plainEdits(edits), extension: entry.extension.name} : null)

features.formatting = async (host, document, {options, formatter: wanted}, token) => {
  const entry = formatter(host, "formatting", document, wanted)
  if (!entry) return null
  return formatted(entry, await asked(entry, "provideDocumentFormattingEdits", [document, options || {}, token], token))
}

features.rangeFormatting = async (host, document, {range, options, formatter: wanted}, token) => {
  const entry = formatter(host, "rangeFormatting", document, wanted)
  if (!entry) return null
  const where = new Range(range.from.line, range.from.character, range.to.line, range.to.character)
  return formatted(entry, await asked(entry, "provideDocumentRangeFormattingEdits", [document, where, options || {}, token], token))
}

// The parameters of the call the cursor is in: the first provider with an answer.
features.signatureHelp = async (host, document, {position, context}, token) => {
  const at = new Position(position.line, position.character)
  const asking = {
    triggerKind: (context && context.triggerKind) || 1,
    triggerCharacter: (context && context.triggerCharacter) || undefined,
    isRetrigger: !!(context && context.isRetrigger),
    activeSignatureHelp: undefined,
  }
  for (const entry of host.languages.providers("signatureHelp", document)) {
    const help = await asked(entry, "provideSignatureHelp", [document, at, token, asking], token)
    if (!help || !help.signatures || help.signatures.length === 0) continue
    return {
      signatures: help.signatures.map(signature => ({
        label: String(signature.label),
        documentation: markdown(signature.documentation, true),
        activeParameter: signature.activeParameter ?? null,
        parameters: (signature.parameters || []).map(parameter => ({
          label: Array.isArray(parameter.label) ? parameter.label : String(parameter.label),
          documentation: markdown(parameter.documentation, true),
        })),
      })),
      activeSignature: help.activeSignature || 0,
      activeParameter: help.activeParameter || 0,
    }
  }
  return null
}

const SYMBOLS = Object.fromEntries(Object.entries(SymbolKind).map(([name, value]) => [value, name.toLowerCase()]))

features.documentHighlight = async (host, document, {position}, token) => {
  const at = new Position(position.line, position.character)
  for (const entry of host.languages.providers("documentHighlight", document)) {
    const found = await asked(entry, "provideDocumentHighlights", [document, at, token], token)
    if (!Array.isArray(found) || found.length === 0) continue
    return found.filter(one => one && one.range).map(one => ({...convert.range(one.range), kind: ["text", "read", "write"][one.kind] || "text"}))
  }
  return []
}

// The file's outline: DocumentSymbols (a tree) or SymbolInformations
// (flat, with the name of what contains them), as one list.
features.documentSymbol = async (host, document, _params, token) => {
  const entries = host.languages.providers("documentSymbol", document)
  const results = await Promise.all(entries.map(entry => asked(entry, "provideDocumentSymbols", [document, token], token)))
  const list = []
  const walk = (symbols, depth, container) => {
    for (const symbol of symbols || []) {
      if (!symbol) continue
      const range = symbol.selectionRange || (symbol.location && symbol.location.range) || symbol.range
      if (!range) continue
      list.push({
        name: String(symbol.name),
        detail: symbol.detail || null,
        kind: SYMBOLS[symbol.kind] || "variable",
        container: symbol.containerName || container || null,
        depth,
        ...convert.range(range),
      })
      if (Array.isArray(symbol.children)) walk(symbol.children, depth + 1, String(symbol.name))
    }
  }
  for (const result of results) if (Array.isArray(result)) walk(result, 0, null)
  return list.sort((a, b) => a.from.line - b.from.line || a.from.character - b.from.character)
}

features.workspaceSymbol = async (host, _document, {query}, token) => {
  const entries = host.languages.entries.filter(entry => entry.feature === "workspaceSymbol")
  const results = await Promise.all(entries.map(entry => asked(entry, "provideWorkspaceSymbols", [String(query || ""), token], token)))
  const list = []
  for (const symbol of results.flatMap(result => (Array.isArray(result) ? result : []))) {
    const location = symbol && symbol.location
    if (!location || !location.uri || location.uri.scheme !== "file") continue
    // (A location without a range is one to be resolved: its file's start.)
    const range = location.range || new Range(0, 0, 0, 0)
    list.push({
      name: String(symbol.name),
      kind: SYMBOLS[symbol.kind] || "variable",
      container: symbol.containerName || null,
      path: location.uri.fsPath,
      ...convert.range(range),
    })
  }
  return list.slice(0, 500)
}

// Quick fixes and refactorings for a range: what every provider offers,
// told the diagnostics that are there.
features.codeAction = async (host, document, {range, context}, token) => {
  const where = new Range(range.from.line, range.from.character, range.to.line, range.to.character)
  const diagnostics = host.languages.diagnosticsOf(document.uri).filter(diagnostic => diagnostic.range && diagnostic.range.intersection(where))
  const only = context && context.only
  const asking = {
    diagnostics,
    only: only ? {value: only, contains: other => other.value === only || other.value.startsWith(only + ".")} : undefined,
    triggerKind: (context && context.triggerKind) || 1,
  }
  const entries = host.languages.providers("codeAction", document)
  const results = await Promise.all(entries.map(entry => asked(entry, "provideCodeActions", [document, where, asking, token], token)))
  const session = []
  results.forEach((result, i) => {
    for (const action of Array.isArray(result) ? result : []) if (action && action.title) session.push({item: action, entry: entries[i]})
  })
  const id = ++nextSession
  sessions.set(id, session)
  for (const old of sessions.keys()) if (old <= id - SESSIONS) sessions.delete(old)
  return {
    session: id,
    actions: session.map(({item}, index) => ({
      index,
      title: String(item.title),
      kind: (item.kind && item.kind.value) || null,
      preferred: !!item.isPreferred,
      disabled: (item.disabled && item.disabled.reason) || null,
    })),
  }
}

features.codeActionApply = async (host, _document, {session, index}, token) => {
  const kept = (sessions.get(session) || [])[index]
  if (!kept) return {error: "The code action isn't there any more."}
  let action = kept.item
  // A CodeAction without its edit yet: its provider fills it in.
  if (!action.edit && typeof action.command !== "string" && typeof kept.entry.provider.resolveCodeAction === "function") {
    action = (await asked(kept.entry, "resolveCodeAction", [action, token], token)) || action
  }
  if (action.edit && typeof action.edit.entries === "function") {
    const applied = await host.request("applyWorkspaceEdit", convert.workspaceEdit(action.edit))
    if (!applied) return {error: "Its changes couldn't be applied."}
  }
  // A Command (its `command` is the id), or a CodeAction's command.
  const command = typeof action.command === "string" ? action : action.command
  try {
    if (command && command.command) await host.executeCommand(kept.entry.extension, command.command, command.arguments || [])
  } catch (e) {
    return {error: String((e && e.message) || e)}
  }
  return {applied: true}
}

// What Rename Symbol would rename: its provider's say, or the word there.
features.prepareRename = async (host, document, {position}, token) => {
  const at = new Position(position.line, position.character)
  const entry = host.languages.providers("rename", document)[0]
  if (!entry) return null
  let range
  let placeholder
  if (typeof entry.provider.prepareRename === "function") {
    try {
      const prepared = await entry.provider.prepareRename(document, at, token)
      if (prepared && prepared.range) ({range, placeholder} = prepared)
      else if (prepared) range = prepared
    } catch (e) {
      return {error: String((e && e.message) || e)}
    }
  }
  range ??= document.getWordRangeAtPosition(at)
  if (!range) return {error: "The element can't be renamed."}
  return {placeholder: placeholder ?? document.getText(range), ...convert.range(range)}
}

// Renames: the first provider's edits (of any files), applied through Bee.
features.rename = async (host, document, {position, newName}, token) => {
  const at = new Position(position.line, position.character)
  for (const entry of host.languages.providers("rename", document)) {
    let edit
    try {
      edit = await entry.provider.provideRenameEdits(document, at, String(newName), token)
    } catch (e) {
      return {error: String((e && e.message) || e)}
    }
    if (!(edit instanceof WorkspaceEdit) && !(edit && typeof edit.entries === "function")) continue
    const plain = convert.workspaceEdit(edit)
    const applied = await host.request("applyWorkspaceEdit", plain)
    return {applied: !!applied, files: plain.files.length, edits: plain.files.reduce((n, file) => n + file.edits.length, 0)}
  }
  return {error: "No result."}
}

// Where something is: Location, Location[] or LocationLink[] of every
// provider, files only, each place once.
const locations = (method, extra = () => []) => async (host, document, params, token, feature) => {
  const at = new Position(params.position.line, params.position.character)
  const entries = host.languages.providers(feature, document)
  const results = await Promise.all(entries.map(entry => asked(entry, method, [document, at, ...extra(params), token], token)))
  const found = new Map()
  for (const one of results.flatMap(result => [].concat(result ?? []))) {
    const uri = one && (one.targetUri || one.uri)
    const range = one && (one.targetSelectionRange || one.targetRange || one.range)
    if (!uri || uri.scheme !== "file" || !range) continue
    const place = {path: uri.fsPath, ...convert.range(range)}
    found.set(JSON.stringify(place), place)
  }
  return [...found.values()]
}

features.definition = locations("provideDefinition")
features.typeDefinition = locations("provideTypeDefinition")
features.declaration = locations("provideDeclaration")
features.implementation = locations("provideImplementation")
features.references = locations("provideReferences", params => [{includeDeclaration: params.includeDeclaration !== false}])

// What Bee asked: null for a feature there isn't, or a file that isn't open.
const provide = (host, params, token) => {
  const feature = features[params.feature]
  if (!feature) return Promise.resolve(null)
  const document = host.documents.get(params.path)
  // (Not about a file: an item of an earlier completion, the workspace's symbols.)
  if (!document && !params.session && params.feature !== "workspaceSymbol") return Promise.resolve(null)
  // A provider may never answer: once cancelled, Bee is.
  const cancelled = new Promise(resolve => token.onCancellationRequested(() => resolve(null)))
  return Promise.race([feature(host, document, params, token, params.feature), cancelled])
}

module.exports = {provide}
