// Bee's extension host: runs the code of VS Code extensions (their `main`)
// for one workspace, with Bee's `vscode` module (vscode.js). Started by
// Bee.Extensions.Host, which it talks to over stdin/stdout: JSON messages,
// each after its length (4 bytes, big endian) –
//
//   {id, method, params}          a request; answered with
//   {id, result} | {id, error}
//   {method, params}              a notification
//
// From Bee: initialize, activate, deactivate, executeCommand; settings,
// document*, activeEditor. To Bee: registerCommand, showMessage,
// showQuickPick, showInputBox, applyEdit, updateConfiguration,
// executeCommand (commands that aren't here), statusItem, log, unsupported.
//
// stdout is the protocol's: what extensions print goes to Bee as log lines.
"use strict"

const Module = require("node:module")
const path = require("node:path")
const {randomUUID} = require("node:crypto")
const fs = require("node:fs")
const {Documents} = require("./documents")
const {Languages} = require("./languages")
const {Disposable, EventEmitter, Uri, TabInputText} = require("./types")
const {createApi, createContext, TextEditor} = require("./vscode")

// ---- Transport

const write = process.stdout.write.bind(process.stdout)

const send = message => {
  const body = Buffer.from(JSON.stringify(message), "utf8")
  const head = Buffer.alloc(4)
  head.writeUInt32BE(body.length)
  write(Buffer.concat([head, body]))
}

const log = (level, text, extension) => send({method: "log", params: {level, text: String(text), extension}})

const format = args =>
  args.map(arg => (typeof arg === "string" ? arg : arg instanceof Error ? arg.stack || arg.message : inspect(arg))).join(" ")

const inspect = value => {
  try {
    return require("node:util").inspect(value, {depth: 3, breakLength: 120})
  } catch (_e) {
    return String(value)
  }
}

for (const [method, level] of [["log", "info"], ["info", "info"], ["debug", "debug"], ["warn", "warning"], ["error", "error"], ["trace", "debug"]]) {
  console[method] = (...args) => log(level, format(args))
}
process.stdout.write = (chunk, _encoding, callback) => {
  log("info", String(chunk).replace(/\n$/, ""))
  if (typeof callback === "function") callback()
  return true
}
process.stderr.write = (chunk, _encoding, callback) => {
  log("error", String(chunk).replace(/\n$/, ""))
  if (typeof callback === "function") callback()
  return true
}

// ---- The host's state, shared by every extension's API

let nextRequest = 0
const waiting = new Map()

// (The folder may be gone already; Bee names it in `initialize`.)
const cwd = () => {
  try {
    return process.cwd()
  } catch (_e) {
    return "/"
  }
}

const host = {
  root: cwd(),
  session: randomUUID(),
  settings: {},
  defaults: {},
  documents: new Documents(),
  extensions: new Map(), // plugin name → extension
  commands: new Map(), // id → {handler, thisArg, extension}
  activeEditor: undefined,
  nextId: 0,
  onConfiguration: new EventEmitter(),
  onActiveEditor: new EventEmitter(),
  onSelection: new EventEmitter(),
  // Files of the workspace changing on disk: {path, kind} (for file watchers).
  onFile: new EventEmitter(),
  // Tabs opened, closed or changed: {opened, closed, changed}.
  onTabs: new EventEmitter(),
  watchers: 0,

  notify(method, params) {
    send({method, params})
  },

  request(method, params) {
    const id = ++nextRequest
    return new Promise((resolve, reject) => {
      waiting.set(id, {resolve, reject})
      send({id, method, params})
    })
  },

  registerCommand(extension, id, handler, thisArg) {
    if (typeof id !== "string" || typeof handler !== "function") throw new Error("registerCommand(id, handler)")
    if (host.commands.has(id)) throw new Error(`command '${id}' already exists`)
    const entry = {handler, thisArg, extension}
    host.commands.set(id, entry)
    host.notify("registerCommand", {extension: extension.name, command: id})
    return new Disposable(() => {
      if (host.commands.get(id) !== entry) return
      host.commands.delete(id)
      host.notify("unregisterCommand", {extension: extension.name, command: id})
    })
  },

  // A command registered here, or one of Bee's (or of an extension Bee
  // then activates).
  executeCommand(extension, id, args) {
    const local = host.commands.get(id)
    if (local) return Promise.resolve().then(() => local.handler.apply(local.thisArg, args))
    return host.request("executeCommand", {extension: extension.name, command: id, args}).then(revive)
  },

  // Edits of an open document ([{from, to, text}], its offsets): true once
  // Bee applied them (the changed text came back first).
  applyEdits(document, edits) {
    if (edits.length === 0) return Promise.resolve(true)
    return host.request("applyEdit", {path: document.fileName, edits}).then(Boolean)
  },

  // A file system watcher came or went: Bee sends file changes while there are any.
  watching(change) {
    const before = host.watchers
    host.watchers += change
    if ((before === 0) !== (host.watchers === 0)) host.notify("watchFiles", {on: host.watchers > 0})
  },

  // An API Bee doesn't have was used: told once per extension and name.
  unsupported(extension, name) {
    if (extension.unsupported.has(name)) return
    extension.unsupported.add(name)
    host.notify("unsupported", {extension: extension.name, api: name})
  },

  // vscode.extensions.getExtension("publisher.name")
  extensionInfo(id) {
    const extension = [...host.extensions.values()].find(e => e.id.toLowerCase() === String(id).toLowerCase())
    if (!extension) return undefined
    return {
      id: extension.id,
      extensionPath: extension.dir,
      extensionUri: Uri.file(extension.dir),
      packageJSON: extension.packageJSON,
      extensionKind: 1,
      get isActive() {
        return extension.active
      },
      get exports() {
        return extension.exports
      },
      activate: () => Promise.resolve(extension.exports),
    }
  },
}

host.languages = new Languages(host)

// The documents are the tabs (vscode.window.tabGroups).
const tabOf = document => ({label: path.basename(document.fileName), input: new TabInputText(document.uri)})
host.documents.onOpen.event(document => host.onTabs.fire({opened: [tabOf(document)], closed: [], changed: []}))
host.documents.onClose.event(document => host.onTabs.fire({opened: [], closed: [tabOf(document)], changed: []}))

// `require("vscode")`: the API of the extension the requiring file belongs to.
const fallback = {name: "", id: "bee.unknown", dir: "", unsupported: new Set(), subscriptions: []}
const load = Module._load
Module._load = function (request, parent, ...rest) {
  if (request !== "vscode") return load.call(this, request, parent, ...rest)
  const file = (parent && parent.filename) || ""
  let owner = null
  for (const extension of host.extensions.values()) {
    if (file.startsWith(extension.dir + path.sep) && (!owner || extension.dir.length > owner.dir.length)) owner = extension
  }
  owner ??= fallback
  owner.api ??= createApi(host, owner)
  return owner.api
}

// {"$uri": "/path"} ↔ Uri, in arguments and results.
const revive = value => {
  if (Array.isArray(value)) return value.map(revive)
  if (value && typeof value === "object") {
    if (typeof value.$uri === "string" && Object.keys(value).length === 1) return Uri.parse(value.$uri)
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, revive(item)]))
  }
  return value
}

// What can go back to Bee as JSON (undefined and functions can't).
const jsonable = value => {
  try {
    const text = JSON.stringify(value)
    return text === undefined ? null : JSON.parse(text)
  } catch (_e) {
    return null
  }
}

// ---- The active editor

const setActiveEditor = editor => {
  const before = host.activeEditor
  const document = editor && editor.path ? host.documents.get(editor.path) : undefined
  if (!document) {
    host.activeEditor = undefined
    if (before) host.onActiveEditor.fire(undefined)
    return
  }
  if (before && before.document === document) {
    before._setSelections(editor.selections)
    host.onSelection.fire({textEditor: before, selections: before.selections, kind: undefined})
  } else {
    host.activeEditor = new TextEditor(host, document, editor.selections)
    host.onActiveEditor.fire(host.activeEditor)
  }
}

// ---- Requests from Bee

const methods = {
  initialize({root, settings, defaults, documents, editor}) {
    host.root = root
    host.settings = settings || {}
    host.defaults = defaults || {}
    for (const document of documents || []) host.documents.put(document)
    setActiveEditor(editor)
    return {node: process.version, pid: process.pid}
  },

  async activate({name, dir, main, packageJSON, storage, globalStorage}) {
    if (host.extensions.has(name)) return {active: true}
    const extension = {
      name,
      id: `${packageJSON.publisher || "undefined_publisher"}.${packageJSON.name || name}`,
      dir,
      packageJSON,
      subscriptions: [],
      unsupported: new Set(),
      active: false,
      exports: undefined,
      module: null,
    }
    host.extensions.set(name, extension)
    try {
      extension.api = createApi(host, extension)
      extension.module = require(path.resolve(dir, main))
      if (typeof extension.module.activate === "function") {
        extension.exports = await extension.module.activate(createContext(host, extension, {storage, globalStorage}))
      }
      extension.active = true
      return {active: true}
    } catch (e) {
      await dispose(extension)
      throw e
    }
  },

  async deactivate({name}) {
    const extension = host.extensions.get(name)
    if (extension) await dispose(extension)
    return {}
  },

  // `editor`, `document`: the window's active editor as the command runs.
  async executeCommand({command, args, document, editor}) {
    if (document) host.documents.put(document)
    if (editor !== undefined) setActiveEditor(editor)
    const entry = host.commands.get(command)
    if (!entry) {
      throw new Error(
        `the extension didn't register the command '${command}': its code may have failed as it started (see Bee.Extensions.Host.log/1)`,
      )
    }
    return jsonable(await entry.handler.apply(entry.thisArg, revive(args || [])))
  },
}

const dispose = async extension => {
  try {
    if (extension.module && typeof extension.module.deactivate === "function") await extension.module.deactivate()
  } catch (e) {
    log("error", `deactivate failed: ${e && e.message}`, extension.name)
  }
  for (const subscription of extension.subscriptions.splice(0).reverse()) {
    try {
      if (subscription && typeof subscription.dispose === "function") subscription.dispose()
    } catch (e) {
      log("error", `dispose failed: ${e && e.message}`, extension.name)
    }
  }
  host.languages.forget(extension)
  // Commands it didn't put in its subscriptions.
  for (const [id, entry] of [...host.commands]) {
    if (entry.extension !== extension) continue
    host.commands.delete(id)
    host.notify("unregisterCommand", {extension: extension.name, command: id})
  }
  extension.active = false
  host.extensions.delete(extension.name)
  // Loaded afresh the next time (a new version may be installed).
  for (const file of Object.keys(require.cache)) {
    if (file.startsWith(extension.dir + path.sep)) delete require.cache[file]
  }
}

// ---- Notifications from Bee

const notifications = {
  settings({settings}) {
    const before = host.settings
    host.settings = settings || {}
    const changed = new Set()
    for (const key of new Set([...Object.keys(before), ...Object.keys(host.settings)])) {
      if (JSON.stringify(before[key]) !== JSON.stringify(host.settings[key])) changed.add(key)
    }
    if (changed.size === 0) return
    host.onConfiguration.fire({
      affectsConfiguration: section =>
        [...changed].some(key => key === section || key.startsWith(section + ".") || section.startsWith(key + ".")),
    })
  },
  documentOpened: document => host.documents.put(document),
  documentChanged: document => host.documents.put(document),
  documentSaved: ({path: file}) => host.documents.saved(file),
  documentClosed: ({path: file}) => {
    if (host.activeEditor && host.activeEditor.document.fileName === file) setActiveEditor(undefined)
    host.documents.close(file)
  },
  // A file of the workspace changed on disk: created (just now), deleted or changed.
  fileChanged: ({path: file}) => {
    let kind = "changed"
    try {
      const stat = fs.statSync(file)
      if (Date.now() - stat.birthtimeMs < 2000) kind = "created"
    } catch (_e) {
      kind = "deleted"
    }
    host.onFile.fire({path: file, kind})
  },
  activeEditor: ({editor, document}) => {
    if (document) host.documents.put(document)
    setActiveEditor(editor)
  },
}

const failure = e => ({message: (e && e.message) || String(e), stack: e && e.stack})

const handle = async message => {
  if (message.method === undefined) {
    const entry = waiting.get(message.id)
    if (!entry) return
    waiting.delete(message.id)
    if (message.error) entry.reject(new Error(message.error.message || String(message.error)))
    else entry.resolve(message.result)
  } else if (message.id === undefined) {
    try {
      notifications[message.method]?.(message.params || {})
    } catch (e) {
      log("error", `${message.method}: ${e && e.stack}`)
    }
  } else {
    try {
      const method = methods[message.method]
      if (!method) throw new Error(`unknown method ${message.method}`)
      send({id: message.id, result: (await method(message.params || {})) ?? null})
    } catch (e) {
      send({id: message.id, error: failure(e)})
    }
  }
}

let pending = Buffer.alloc(0)
process.stdin.on("data", chunk => {
  pending = pending.length ? Buffer.concat([pending, chunk]) : chunk
  while (pending.length >= 4) {
    const length = pending.readUInt32BE(0)
    if (pending.length < 4 + length) break
    const body = pending.subarray(4, 4 + length)
    pending = pending.subarray(4 + length)
    handle(JSON.parse(body.toString("utf8")))
  }
})
// Bee is gone (or closed the host): so are we.
process.stdin.on("end", () => process.exit(0))
process.stdin.on("close", () => process.exit(0))

// An extension's mistake must not take the others down.
process.on("uncaughtException", e => log("error", `uncaught exception: ${(e && e.stack) || e}`))
process.on("unhandledRejection", e => log("error", `unhandled rejection: ${(e && e.stack) || e}`))
