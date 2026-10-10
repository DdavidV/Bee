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
