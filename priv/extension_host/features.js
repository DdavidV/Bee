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
//
// Positions are {line, character}, ranges {from, to} of them (convert.js).
// A provider that throws is logged and left out: the others still answer.
"use strict"

const convert = require("./convert")
const {Position, Range, SnippetString, MarkdownString, CompletionItemKind} = require("./types")

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

// Where something is: Location, Location[] or LocationLink[] of every
// provider, files only, each place once.
const locations = method => async (host, document, {position}, token, feature) => {
  const at = new Position(position.line, position.character)
  const entries = host.languages.providers(feature, document)
  const results = await Promise.all(entries.map(entry => asked(entry, method, [document, at, token], token)))
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

// What Bee asked: null for a feature there isn't, or a file that isn't open.
const provide = (host, params, token) => {
  const feature = features[params.feature]
  if (!feature) return Promise.resolve(null)
  const document = host.documents.get(params.path)
  if (!document && !params.session) return Promise.resolve(null)
  // A provider may never answer: once cancelled, Bee is.
  const cancelled = new Promise(resolve => token.onCancellationRequested(() => resolve(null)))
  return Promise.race([feature(host, document, params, token, params.feature), cancelled])
}

module.exports = {provide}
