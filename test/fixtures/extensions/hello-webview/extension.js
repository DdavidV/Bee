// Bee's test webview extension (see package.json).
//
// Open Panel: a panel whose page loads a stylesheet and an image from the
// extension's media folder (and tries a file outside it), under a
// Content-Security-Policy as extensions write them. Its "ping" button
// posts to the extension, which answers "pong <n>" and puts that in the
// panel's title; the page keeps the count with setState.
const vscode = require("vscode")

let panel

function page(webview, extensionUri, heading) {
  const media = name => webview.asWebviewUri(vscode.Uri.joinPath(extensionUri, "media", name))
  const outside = webview.asWebviewUri(vscode.Uri.joinPath(extensionUri, "package.json"))
  const nonce = "n0nce"
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src ${webview.cspSource}; style-src ${webview.cspSource}; script-src 'nonce-${nonce}'; connect-src ${webview.cspSource};">
  <link rel="stylesheet" href="${media("style.css")}">
</head>
<body>
  <h1 id="heading">${heading}</h1>
  <p id="styled">styled</p>
  <img id="logo" src="${media("bee.svg")}" alt="bee">
  <button id="ping">ping</button>
  <a id="link" href="https://example.com/docs">docs</a>
  <p id="out"></p>
  <p id="state"></p>
  <p id="theme"></p>
  <p id="outside"></p>
  <script nonce="${nonce}">
    const api = acquireVsCodeApi()
    const state = api.getState() || {pings: 0}
    const show = () => {
      document.getElementById("state").textContent = "pings: " + state.pings
      document.getElementById("theme").textContent = document.body.className + " " + getComputedStyle(document.body).color
    }
    show()
    document.getElementById("ping").addEventListener("click", () => {
      state.pings++
      api.setState(state)
      show()
      api.postMessage({type: "ping", n: state.pings})
    })
    window.addEventListener("message", event => {
      document.getElementById("out").textContent = [event.data.type, event.data.n].filter(Boolean).join(" ")
    })
    fetch("${outside}").then(r => r.status, () => "failed").then(status => {
      document.getElementById("outside").textContent = "outside: " + status
    })
    // What a page must not reach: Bee's page, its cookies, its storage.
    let reach = "none"
    try { reach = String(window.parent.document.title) } catch (e) { reach = "blocked" }
    let cookie = "blocked"
    try { cookie = "[" + document.cookie + "]" } catch (e) {}
    let storage = "blocked"
    try { storage = "[" + Object.keys(localStorage).join(",") + "]" } catch (e) {}
    api.postMessage({type: "loaded", reach, cookie, storage, origin: location.origin})
  </script>
</body>
</html>`
}

function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand("helloWebview.open", () => {
      if (panel) return panel.reveal()
      panel = vscode.window.createWebviewPanel("helloWebview", "Hello Webview", vscode.ViewColumn.One, {
        enableScripts: true,
        localResourceRoots: [vscode.Uri.joinPath(context.extensionUri, "media")],
      })
      panel.webview.html = page(panel.webview, context.extensionUri, "first")
      panel.webview.onDidReceiveMessage(message => {
        if (message.type === "loaded") console.log(`webview loaded: parent ${message.reach}, cookie ${message.cookie}, storage ${message.storage}, origin ${message.origin}`)
        if (message.type !== "ping") return
        panel.title = `Pong ${message.n}`
        panel.webview.postMessage({type: "pong", n: message.n})
      })
      panel.onDidChangeViewState(event => console.log(`webview active ${event.webviewPanel.active}`))
      panel.onDidDispose(() => {
        console.log("webview disposed")
        panel = undefined
      })
      // Right away, before its page is there: delivered once it is.
      panel.webview.postMessage({type: "hello"})
    }),
    vscode.commands.registerCommand("helloWebview.update", () => {
      if (panel) panel.webview.html = page(panel.webview, context.extensionUri, "second")
    }),
    vscode.commands.registerCommand("helloWebview.close", () => panel && panel.dispose()),
    // No scripts allowed: only what the HTML says.
    vscode.commands.registerCommand("helloWebview.plain", () => {
      const plain = vscode.window.createWebviewPanel("helloPlain", "Plain", vscode.ViewColumn.One)
      plain.webview.html = '<p id="plain">no scripts <script>document.getElementById("plain").textContent = "scripts ran"</script></p>'
    }),
    // A page that embeds a local server of the extension's (as previews
    // do): the frame inside reports whether it has an origin of its own
    // and can talk to its server; the panel's title says what it found.
    vscode.commands.registerCommand("helloWebview.nested", async () => {
      const http = require("node:http")
      const server = http.createServer((request, response) => {
        if (request.url === "/ping") return response.end("pong")
        response.setHeader("content-type", "text/html")
        response.end(`<p id="inner">inner</p><script>
          fetch("/ping").then(r => r.text(), () => "failed").then(answer => {
            document.getElementById("inner").textContent = "inner " + answer
            parent.postMessage({nested: true, origin: self.origin, answer}, "*")
          })
        </script>`)
      })
      await new Promise(resolve => server.listen(0, "127.0.0.1", resolve))
      const url = await vscode.env.asExternalUri(vscode.Uri.parse(`http://127.0.0.1:${server.address().port}/`))
      const nested = vscode.window.createWebviewPanel("helloNested", "Nested", vscode.ViewColumn.One, {enableScripts: true})
      nested.webview.onDidReceiveMessage(message => {
        nested.title = `Nested: ${message.answer} from ${message.origin === url.toString().replace(/\/$/, "") ? "its own origin" : message.origin}`
      })
      nested.onDidDispose(() => server.close())
      nested.webview.html = `<html><body style="margin:0">
        <iframe id="nested" src="${url}" style="border:0;width:100%;height:200px"></iframe>
        <script>
          const api = acquireVsCodeApi()
          window.addEventListener("message", event => {
            if (event.data && event.data.nested) api.postMessage(event.data)
          })
        </script></body></html>`
    }),
    vscode.commands.registerCommand("helloWebview.external", async () => {
      const uri = await vscode.env.asExternalUri(vscode.Uri.parse("https://example.com/from-extension"))
      return vscode.env.openExternal(uri)
    }),
  )
}

module.exports = {activate}
