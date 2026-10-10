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
