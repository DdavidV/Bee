// Bee's test extension (see package.json): what its commands do is used by
// the extension host's tests.
const vscode = require("vscode")

function activate(context) {
  const greeting = () => vscode.workspace.getConfiguration("hello").get("greeting")

  context.subscriptions.push(
    vscode.commands.registerCommand("hello.sayHello", () =>
      vscode.window.showInformationMessage(`${greeting()} from the hello extension`),
    ),
    vscode.commands.registerTextEditorCommand("hello.shout", (editor, edit) => {
      for (const selection of editor.selections) edit.replace(selection, editor.document.getText(selection).toUpperCase())
    }),
    vscode.commands.registerCommand("hello.pick", async () => {
      const pick = await vscode.window.showQuickPick(["Hello", "Hi", "Howdy"], {placeHolder: "Pick a greeting"})
      if (pick) await vscode.workspace.getConfiguration("hello").update("greeting", pick, vscode.ConfigurationTarget.Global)
      return pick
    }),
    vscode.commands.registerCommand("hello.insert", async args => {
      const editor = vscode.window.activeTextEditor
      if (editor) await editor.edit(edit => edit.insert(editor.selection.active, (args && args.text) || "hello"))
    }),
    vscode.commands.registerCommand("hello.reveal", uri =>
      vscode.window.showInformationMessage(`${greeting()}, ${uri ? uri.fsPath : "nobody"}`),
    ),
    vscode.commands.registerCommand("hello.broken", () => {
      throw new Error("broken on purpose")
    }),

    // Not in package.json: commands an extension registers as it runs.
    vscode.commands.registerCommand("hello.ask", async () => {
      const name = await vscode.window.showInputBox({prompt: "Who?", value: "you"})
      if (name === undefined) return vscode.window.showInformationMessage("Nobody")
      const answer = await vscode.window.showWarningMessage(`Greet ${name}?`, {modal: true}, "Yes", {title: "No"})
      const said = answer === "Yes" ? "Yes" : answer ? answer.title : "nothing"
      return vscode.window.showInformationMessage(`${name}: ${said}`)
    }),
    vscode.commands.registerCommand("hello.context", (value = true) =>
      vscode.commands.executeCommand("setContext", "hello.ready", value),
    ),
    vscode.commands.registerCommand("hello.status", () => {
      const item = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 5)
      item.text = "$(megaphone) Hello"
      item.command = "hello.sayHello"
      item.show()
      item.text = `$(megaphone) ${greeting()}`
      context.subscriptions.push(item)
    }),
    vscode.commands.registerCommand("hello.describe", () => {
      const editor = vscode.window.activeTextEditor
      const state = context.globalState
      const runs = state.get("runs", 0) + 1
      state.update("runs", runs)
      return vscode.window.showInformationMessage(
        editor
          ? `${vscode.workspace.asRelativePath(editor.document.uri)} ${editor.document.languageId} ` +
              `${editor.document.lineCount} lines, selected "${editor.document.getText(editor.selection)}" ` +
              `at ${editor.selection.start.line}:${editor.selection.start.character}, run ${runs}`
          : "no editor",
      )
    }),
    vscode.commands.registerCommand("hello.bee", () => vscode.commands.executeCommand("workbench.action.togglePanel")),
    vscode.commands.registerCommand("hello.unsupported", () => {
      const factory = vscode.debug.registerDebugAdapterDescriptorFactory("hello", {createDebugAdapterDescriptor: () => null})
      context.subscriptions.push(factory)
      // As a bundled extension sees the module: a copy of its own properties.
      const bundled = Object.assign({}, vscode)
      new bundled.TreeItem("x", bundled.TreeItemCollapsibleState.None)
      return vscode.window.showInformationMessage("still running")
    }),
    // Output channels: plain text, and a log with times and levels.
    vscode.commands.registerCommand("hello.output", (text = "first line", show = true) => {
      context.output ??= vscode.window.createOutputChannel("Hello")
      context.output.appendLine(text)
      if (show) context.output.show()
    }),
    vscode.commands.registerCommand("hello.log", () => {
      const log = vscode.window.createOutputChannel("Hello Log", {log: true})
      log.info("started", {port: 1})
      log.error(new Error("boom"))
      console.log("printed by hello")
    }),
    vscode.commands.registerCommand("hello.crash", () => process.exit(3)),
    vscode.workspace.onDidChangeConfiguration(event => {
      if (event.affectsConfiguration("hello.greeting")) console.log(`greeting is now ${greeting()}`)
    }),
  )
}

function deactivate() {}

module.exports = {activate, deactivate}
