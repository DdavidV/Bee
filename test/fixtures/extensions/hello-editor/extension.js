// Bee's test custom editor extension (see package.json).
//
// Cards (*.cards): a CustomTextEditorProvider. The file is a text
// document, a card per line; the page lists them, and its "add" button
// has the extension append a line – an edit of the document, so the file
// has unsaved changes and Save writes it. The page follows the document,
// whoever changes it.
//
// Tally (*.tally): a CustomEditorProvider with a document of its own, a
// number. "bump" adds one in the document (not in the file): it says it
// changed, and saveCustomDocument writes it.
const vscode = require("vscode")
const fs = require("fs")

const page = body => `<!DOCTYPE html><html><body>${body}
  <script>
    const api = acquireVsCodeApi()
    for (const button of document.querySelectorAll("button"))
      button.addEventListener("click", () => api.postMessage({type: button.id}))
    window.addEventListener("message", event => {
      for (const [id, text] of Object.entries(event.data)) {
        const element = document.getElementById(id)
        if (element) element.textContent = text
      }
    })
    api.postMessage({type: "ready"})
  </script></body></html>`

const cards = {
  resolveCustomTextEditor(document, panel) {
    panel.webview.options = {enableScripts: true}
    panel.webview.html = page(`<h1 id="name"></h1><ol id="cards"></ol><p id="count"></p><button id="add">add</button>`)
    const show = () =>
      panel.webview.postMessage({
        name: "cards of " + document.fileName.split("/").pop(),
        cards: document.getText().trim(),
        count: document.getText().split("\n").filter(Boolean).length + " cards",
      })
    const changes = vscode.workspace.onDidChangeTextDocument(event => {
      if (event.document.uri.toString() === document.uri.toString()) show()
    })
    panel.onDidDispose(() => changes.dispose())
    panel.webview.onDidReceiveMessage(async message => {
      if (message.type === "ready") show()
      if (message.type === "add") {
        const edit = new vscode.WorkspaceEdit()
        const count = document.getText().split("\n").filter(Boolean).length
        edit.insert(document.uri, document.lineAt(document.lineCount - 1).range.end, "card " + (count + 1) + "\n")
        await vscode.workspace.applyEdit(edit)
      }
    })
  },
}

const changed = new vscode.EventEmitter()
const opened = []
const tally = {
  onDidChangeCustomDocument: changed.event,
  openCustomDocument(uri) {
    const document = {
      uri,
      count: Number(fs.readFileSync(uri.fsPath, "utf8")) || 0,
      dispose: () => fs.writeFileSync(uri.fsPath + ".closed", "closed"),
    }
    opened.push(document)
    return document
  },
  resolveCustomEditor(document, panel) {
    panel.webview.options = {enableScripts: true}
    panel.webview.html = page(`<h1 id="count"></h1><button id="bump">bump</button><button id="close">close</button>`)
    const show = () => panel.webview.postMessage({count: "tally " + document.count})
    panel.webview.onDidReceiveMessage(message => {
      if (message.type === "ready") show()
      if (message.type === "close") panel.dispose()
      if (message.type === "bump") {
        document.count++
        changed.fire({document})
        show()
      }
    })
  },
  async saveCustomDocument(document) {
    fs.writeFileSync(document.uri.fsPath, String(document.count) + "\n")
  },
}

const broken = {
  openCustomDocument() {
    throw new Error("can't <read> it")
  },
  resolveCustomEditor() {},
}

exports.activate = context => {
  context.subscriptions.push(
    vscode.window.registerCustomEditorProvider("helloEditor.cards", cards),
    vscode.window.registerCustomEditorProvider("helloEditor.tally", tally, {supportsMultipleEditorsPerDocument: false}),
    vscode.window.registerCustomEditorProvider("helloEditor.broken", broken),
  )
}
