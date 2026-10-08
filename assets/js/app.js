// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/bee"
import topbar from "../vendor/topbar"
import "@xterm/xterm/css/xterm.css"
import {CodeEditor} from "./hooks/code_editor"
import {Keybindings} from "./hooks/keybindings"
import {Terminal} from "./hooks/terminal"
import {Palette} from "./hooks/palette"
import {Tabs} from "./hooks/tabs"
import {exec} from "./commands/registry"
import {Plugins} from "./hooks/plugins"
import {ViewInput} from "./hooks/view_input"
import {SearchInput} from "./hooks/search_input"
import {ActivityBar, PanelSections, TerminalList} from "./hooks/sortable"
import {ContextMenu, ContextMenus} from "./hooks/context_menu"
import {ExplorerInput} from "./hooks/explorer_input"
import {PaneSash, Sash} from "./hooks/sash"
import {VsixInstall} from "./hooks/vsix_install"
import {loadLayout} from "./layout/storage"
import {BridgeTransport} from "./bridge_transport"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
// In the desktop app the shell provides window.__bridge: no WebSocket, LiveView's
// frames go over the shell to Bee's stdin/stdout.
const transport = window.__bridge ? {transport: BridgeTransport} : {longPollFallbackMs: 2500}

const liveSocket = new LiveSocket("/live", Socket, {
  ...transport,
  // A function: evaluated on every (re)connect, so the saved layout is current.
  params: () => ({_csrf_token: csrfToken, layout: loadLayout()}),
  hooks: {...colocatedHooks, ActivityBar, CodeEditor, ContextMenu, ContextMenus, ExplorerInput, Keybindings, Palette, PaneSash, PanelSections, Tabs, TerminalList, Plugins, Sash, SearchInput, Terminal, ViewInput, VsixInstall},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// "Open Folder in New Window": the server names the URL (?folder=…).
// Runs a Bee command in this window, as the palette does.
const runCommand = (command, args) =>
  liveSocket.execJS(document.querySelector("[data-phx-main]"),
    JSON.stringify([["push", {event: "run_command", value: {command, args: JSON.stringify(args)}}]]))

// Open Folder in the desktop app: its native dialog; the pick goes back to
// Bee as bee.openFolder [where, path].
window.addEventListener("phx:bee:pick_folder", async e => {
  const {where, title, start} = e.detail
  const path = await window.__bridge?.pickFolder(title, start)
  if (path) runCommand("bee.openFolder", [where, path])
})

// The desktop app's `bee FILE` for a file in this window's folder (the shell
// dispatches it).
window.addEventListener("bee:open_file", e => runCommand("bee.openFile", [e.detail.path]))

// Client commands from a right-click menu, run at once (still in the click:
// copying to the clipboard needs that). BeeWeb.Workbench.ContextMenu.
window.addEventListener("bee:run", e => exec(e.detail.command, e.detail.args || []))

// A folder in a new window: a browser tab, or a window of the desktop app.
window.addEventListener("phx:bee:open_window", e =>
  window.__bridge ? window.__bridge.openWindow(e.detail.url) : window.open(e.detail.url, "_blank"))

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

