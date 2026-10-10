// Bee's test language extension (see package.json). In .hl files:
//
//   BAD            an error (source "hello", code "H001")
//   TODO           a warning
//   a line "hint"  a hint over the whole line
//
// Diagnostics are kept as a language client keeps them: set when a document
// opens or changes, deleted when it closes.
const vscode = require("vscode")
const path = require("node:path")

const selector = {language: "hellolang", scheme: "file"}

function diagnose(document) {
  const diagnostics = []
  for (let line = 0; line < document.lineCount; line++) {
    const {text} = document.lineAt(line)
    for (const match of text.matchAll(/BAD|TODO/g)) {
      const range = new vscode.Range(line, match.index, line, match.index + match[0].length)
      const bad = match[0] === "BAD"
      const diagnostic = new vscode.Diagnostic(
        range,
        bad ? "BAD is bad\nUse GOOD instead." : "something to do",
        bad ? vscode.DiagnosticSeverity.Error : vscode.DiagnosticSeverity.Warning,
      )
      diagnostic.source = "hello"
      if (bad) diagnostic.code = {value: "H001", target: vscode.Uri.parse("https://example.com/H001")}
      diagnostics.push(diagnostic)
    }
    if (text === "hint") diagnostics.push(new vscode.Diagnostic(document.lineAt(line).range, "a hint", vscode.DiagnosticSeverity.Hint))
  }
  return diagnostics
}

// Completion: after "greet." its members, else the language's words.
// `GOOD` gets its documentation when resolved, `header` also adds a first
// line, `shout` is a snippet whose command runs once it is inserted.
const completion = {
  provideCompletionItems(document, position, _token, context) {
    const before = document.lineAt(position).text.slice(0, position.character)
    if (/greet\.\w*$/.test(before)) {
      const hello = new vscode.CompletionItem("hello", vscode.CompletionItemKind.Method)
      hello.detail = `trigger ${context.triggerKind}${context.triggerCharacter || ""}`
      const world = new vscode.CompletionItem({label: "world", detail: "(name)", description: "greets"}, vscode.CompletionItemKind.Method)
      world.insertText = new vscode.SnippetString("world(${1:name})$0")
      return [hello, world]
    }
    const good = new vscode.CompletionItem("GOOD", vscode.CompletionItemKind.Constant)
    const header = new vscode.CompletionItem("header", vscode.CompletionItemKind.Keyword)
    header.insertText = "header!"
    const shout = new vscode.CompletionItem("shout", vscode.CompletionItemKind.Function)
    shout.insertText = new vscode.SnippetString("SHOUT(${1:what})")
    shout.command = {command: "helloLang.accepted", title: "", arguments: ["shout"]}
    return new vscode.CompletionList([good, header, shout], false)
  },
  resolveCompletionItem(item) {
    if (item.label === "GOOD") item.documentation = new vscode.MarkdownString("**GOOD** is good")
    if (item.label === "header") {
      item.documentation = "adds a *first* line"
      item.additionalTextEdits = [vscode.TextEdit.insert(new vscode.Position(0, 0), "# hello\n")]
    }
    return item
  },
}

// Hover: a word and its length. On SLOW the answer only comes when it
// isn't waited for any more.
const hover = {
  provideHover(document, position, token) {
    const range = document.getWordRangeAtPosition(position)
    if (!range) return undefined
    const word = document.getText(range)
    if (word === "SLOW") {
      return new Promise(resolve => token.onCancellationRequested(() => (console.log("hover cancelled"), resolve(undefined))))
    }
    if (word === "THROW") throw new Error("no hover here")
    return new vscode.Hover(new vscode.MarkdownString(`**${word}**: ${word.length} letters`), range)
  },
}

// Definition: the "def <word>" lines of the workspace's .hl files.
const definition = {
  async provideDefinition(document, position) {
    const range = document.getWordRangeAtPosition(position)
    if (!range) return undefined
    const word = document.getText(range)
    const found = []
    for (const uri of await vscode.workspace.findFiles("**/*.hl")) {
      const other = await vscode.workspace.openTextDocument(uri)
      for (let line = 0; line < other.lineCount; line++) {
        const {text} = other.lineAt(line)
        if (text.startsWith(`def ${word}`)) found.push(new vscode.Location(uri, new vscode.Range(line, 4, line, 4 + word.length)))
      }
    }
    return found
  },
}

// Formatting: runs of spaces become one, spaces at a line's end go – in
// the whole file, or the lines of a range.
const tidy = (document, first, last) => {
  const edits = []
  for (let line = first; line <= last; line++) {
    const {text, range} = document.lineAt(line)
    const tidied = text.replace(/ {2,}/g, " ").replace(/ +$/, "")
    if (tidied !== text) edits.push(vscode.TextEdit.replace(range, tidied))
  }
  return edits
}

const formatting = {
  provideDocumentFormattingEdits: (document, options) => {
    console.log(`formatting with tabSize ${options.tabSize}`)
    return tidy(document, 0, document.lineCount - 1)
  },
  provideDocumentRangeFormattingEdits: (document, range) => tidy(document, range.start.line, range.end.line),
}

// Signature help: inside "world(" its parameters, the one being typed
// by the commas before the cursor.
const signatures = {
  provideSignatureHelp(document, position, _token, context) {
    const before = document.lineAt(position).text.slice(0, position.character)
    const call = /world\(([^()]*)$/.exec(before)
    if (!call) return undefined
    const help = new vscode.SignatureHelp()
    const signature = new vscode.SignatureInformation("world(name, loudly)", new vscode.MarkdownString("Greets the **world**."))
    signature.parameters = [
      new vscode.ParameterInformation("name", `who to greet (asked by ${context.triggerCharacter || "hand"})`),
      new vscode.ParameterInformation([12, 18], "whether to shout"),
    ]
    help.signatures = [signature]
    help.activeSignature = 0
    help.activeParameter = call[1].split(",").length - 1
    return help
  },
}

// Every place a word is, in the workspace's .hl files (open ones as they
// are in their editors): `{uri, range, definition}`.
async function occurrences(word) {
  const found = []
  for (const uri of await vscode.workspace.findFiles("**/*.hl")) {
    const document = await vscode.workspace.openTextDocument(uri)
    for (let line = 0; line < document.lineCount; line++) {
      const {text} = document.lineAt(line)
      for (const match of text.matchAll(new RegExp(`\\b${word}\\b`, "g"))) {
        found.push({
          uri,
          range: new vscode.Range(line, match.index, line, match.index + word.length),
          definition: text.startsWith(`def ${word}`) && match.index === 4,
        })
      }
    }
  }
  return found.sort((a, b) => a.uri.fsPath.localeCompare(b.uri.fsPath) || a.range.start.line - b.range.start.line)
}

const wordAt = (document, position) => {
  const range = document.getWordRangeAtPosition(position)
  return range && document.getText(range)
}

const references = {
  async provideReferences(document, position, context) {
    const word = wordAt(document, position)
    if (!word) return []
    return (await occurrences(word))
      .filter(one => context.includeDeclaration || !one.definition)
      .map(one => new vscode.Location(one.uri, one.range))
  },
}

const highlights = {
  async provideDocumentHighlights(document, position) {
    const word = wordAt(document, position)
    if (!word) return []
    return (await occurrences(word))
      .filter(one => one.uri.fsPath === document.uri.fsPath)
      .map(one => new vscode.DocumentHighlight(one.range, one.definition ? vscode.DocumentHighlightKind.Write : vscode.DocumentHighlightKind.Read))
  },
}

// Symbols: the "def <name>" lines, each with the "  var <name>" lines under it.
const symbols = {
  provideDocumentSymbols(document) {
    const list = []
    for (let line = 0; line < document.lineCount; line++) {
      const {text, range} = document.lineAt(line)
      const def = /^def (\w+)/.exec(text)
      const variable = /^  var (\w+)/.exec(text)
      if (def) {
        list.push(new vscode.DocumentSymbol(def[1], "definition", vscode.SymbolKind.Function, range, new vscode.Range(line, 4, line, 4 + def[1].length)))
      } else if (variable && list.length) {
        const child = new vscode.DocumentSymbol(variable[1], "", vscode.SymbolKind.Variable, range, new vscode.Range(line, 6, line, 6 + variable[1].length))
        list[list.length - 1].children.push(child)
      }
    }
    return list
  },
  async provideWorkspaceSymbols(query) {
    const found = []
    for (const uri of await vscode.workspace.findFiles("**/*.hl")) {
      const document = await vscode.workspace.openTextDocument(uri)
      for (let line = 0; line < document.lineCount; line++) {
        const def = /^def (\w+)/.exec(document.lineAt(line).text)
        if (def && def[1].includes(query)) {
          found.push(new vscode.SymbolInformation(def[1], vscode.SymbolKind.Function, path.basename(uri.fsPath), new vscode.Location(uri, new vscode.Range(line, 4, line, 4 + def[1].length))))
        }
      }
    }
    return found
  },
}

// Rename: every occurrence in the workspace. BAD keeps its name.
const rename = {
  prepareRename(document, position) {
    const range = document.getWordRangeAtPosition(position)
    if (range && document.getText(range) === "BAD") throw new Error("BAD can't be renamed")
    return range
  },
  async provideRenameEdits(document, position, newName) {
    if (!/^\w+$/.test(newName)) throw new Error(`'${newName}' isn't a name`)
    const edit = new vscode.WorkspaceEdit()
    for (const one of await occurrences(wordAt(document, position))) edit.replace(one.uri, one.range, newName)
    return edit
  },
}

// Code actions: a quick fix for each BAD in the range ("Replace with
// GOOD", its edit filled in when it is resolved), a refactoring that is a
// command ("Shout the line"), and one that can't be done.
const actions = {
  provideCodeActions(document, range, context) {
    const list = []
    for (const diagnostic of context.diagnostics) {
      if (diagnostic.code && diagnostic.code.value === "H001") {
        const fix = new vscode.CodeAction("Replace with GOOD", vscode.CodeActionKind.QuickFix)
        fix.diagnostics = [diagnostic]
        fix.isPreferred = true
        fix.uri = document.uri
        list.push(fix)
      }
    }
    if (context.only && !context.only.contains(vscode.CodeActionKind.Refactor)) return list
    const {text} = document.lineAt(range.start.line)
    if (/[a-z]/.test(text)) {
      const shout = new vscode.CodeAction("Shout the line", vscode.CodeActionKind.Refactor)
      shout.command = {command: "helloLang.shout", title: "Shout", arguments: [document.uri, range.start.line]}
      list.push(shout)
    }
    if (text.includes("frozen")) {
      const frozen = new vscode.CodeAction("Thaw", vscode.CodeActionKind.Refactor)
      frozen.disabled = {reason: "too cold"}
      list.push(frozen)
    }
    return list
  },
  resolveCodeAction(action) {
    if (action.title !== "Replace with GOOD") return action
    action.edit = new vscode.WorkspaceEdit()
    action.edit.replace(action.uri, action.diagnostics[0].range, "GOOD")
    return action
  },
}

function activate(context) {
  const collection = vscode.languages.createDiagnosticCollection("hello")
  const refresh = document => {
    if (vscode.languages.match(selector, document)) collection.set(document.uri, diagnose(document))
  }
  vscode.workspace.textDocuments.forEach(refresh)

  // Files of the language changing on disk, as a language client watches them.
  const watcher = vscode.workspace.createFileSystemWatcher("**/*.hl")
  const seen = kind => uri => console.log(`watched ${kind} ${path.basename(uri.fsPath)}`)

  context.subscriptions.push(
    collection,
    watcher,
    vscode.languages.registerCompletionItemProvider(selector, completion, "."),
    vscode.languages.registerHoverProvider(selector, hover),
    vscode.languages.registerDefinitionProvider(selector, definition),
    vscode.languages.registerCodeActionsProvider(selector, actions, {providedCodeActionKinds: [vscode.CodeActionKind.QuickFix, vscode.CodeActionKind.Refactor]}),
    vscode.commands.registerCommand("helloLang.shout", async (uri, line) => {
      const document = await vscode.workspace.openTextDocument(uri)
      const edit = new vscode.WorkspaceEdit()
      edit.replace(uri, document.lineAt(line).range, document.lineAt(line).text.toUpperCase())
      return vscode.workspace.applyEdit(edit)
    }),
    vscode.languages.registerReferenceProvider(selector, references),
    vscode.languages.registerDocumentHighlightProvider(selector, highlights),
    vscode.languages.registerDocumentSymbolProvider(selector, symbols),
    vscode.languages.registerWorkspaceSymbolProvider(symbols),
    vscode.languages.registerRenameProvider(selector, rename),
    vscode.languages.registerDocumentFormattingEditProvider(selector, formatting),
    vscode.languages.registerDocumentRangeFormattingEditProvider(selector, formatting),
    vscode.languages.registerSignatureHelpProvider(selector, signatures, "(", ","),
    vscode.commands.registerCommand("helloLang.accepted", what => console.log(`accepted ${what}`)),
    watcher.onDidCreate(seen("created")),
    watcher.onDidChange(seen("changed")),
    watcher.onDidDelete(seen("deleted")),
    vscode.workspace.onDidOpenTextDocument(refresh),
    vscode.workspace.onDidChangeTextDocument(event => refresh(event.document)),
    vscode.workspace.onDidCloseTextDocument(document => collection.delete(document.uri)),

    // A workspace edit over every .hl file of the workspace: open or not.
    vscode.commands.registerCommand("helloLang.fixAll", async () => {
      const edit = new vscode.WorkspaceEdit()
      for (const uri of await vscode.workspace.findFiles("**/*.hl", "**/skipped/**")) {
        const document = await vscode.workspace.openTextDocument(uri)
        for (let line = 0; line < document.lineCount; line++) {
          for (const match of document.lineAt(line).text.matchAll(/BAD/g)) {
            edit.replace(uri, new vscode.Range(line, match.index, line, match.index + 3), "GOOD")
          }
        }
      }
      const root = vscode.workspace.workspaceFolders[0].uri
      edit.createFile(vscode.Uri.joinPath(root, "fixed.log"), {ignoreIfExists: true})
      const applied = await vscode.workspace.applyEdit(edit)
      return vscode.window.showInformationMessage(`fixed ${edit.size - 1} file(s): ${applied}`)
    }),

    vscode.commands.registerCommand("helloLang.report", () => {
      const tabs = vscode.window.tabGroups.all.flatMap(group => group.tabs)
      const all = vscode.languages.getDiagnostics()
      return vscode.window.showInformationMessage(
        `${tabs.filter(tab => tab.input instanceof vscode.TabInputText).length} tab(s), ` +
          `${all.reduce((n, [, list]) => n + list.length, 0)} diagnostic(s) in ${all.length} file(s), ` +
          `vscode ${vscode.version}`,
      )
    }),
  )
}

module.exports = {activate}
