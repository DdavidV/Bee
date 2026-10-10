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
  )
}

function deactivate() {}

module.exports = {activate, deactivate}
