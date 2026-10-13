// vscode.window.createTerminal: terminals of an extension's own, in Bee's
// panel beside the user's. And the environment extensions want every new
// terminal to have (ExtensionContext.environmentVariableCollection).
//
//   to Bee     terminalCreate {id, extension, name, shell, args, cwd, env}
//              terminalInput {id, text}, terminalShow {id}, terminalDispose {id}
//              terminalEnv {extension, variables: {NAME: {value, type}}}
//   from Bee   terminalOpened {id, pid}    its shell runs
//              terminalClosed {id, code}   its shell exited, or it was killed
//
// What is sent to a terminal before its shell runs waits in Bee.
"use strict"

const {Disposable, EventEmitter, Uri} = require("./types")

const strings = object =>
  Object.fromEntries(
    Object.entries(object || {})
      .filter(([, value]) => value !== undefined)
      .map(([name, value]) => [name, value === null ? null : String(value)]),
  )

const fsPath = value => (value instanceof Uri ? value.fsPath : typeof value === "string" ? value : undefined)

class Terminal {
  constructor(terminals, extension, id, options) {
    this._terminals = terminals
    this._extension = extension
    this._id = id
    this._disposed = false
    this.name = String(options.name || "Terminal")
    this.creationOptions = options
    this.exitStatus = undefined
    this.state = {isInteractedWith: false, shell: undefined}
    // Bee's terminals don't tell where a command starts and ends.
    this.shellIntegration = undefined
    this.processId = new Promise(resolve => (this._pid = resolve))
  }

  sendText(text, addNewLine = true) {
    if (this._disposed) return
    this._terminals.host.notify("terminalInput", {id: this._id, text: String(text) + (addNewLine ? "\n" : "")})
  }

  show() {
    if (!this._disposed) this._terminals.host.notify("terminalShow", {id: this._id})
  }

  hide() {}

  dispose() {
    if (this._disposed) return
    this._terminals.host.notify("terminalDispose", {id: this._id})
    this._terminals.closed({id: this._id})
  }
}

// EnvironmentVariableMutatorType
const REPLACE = 1
const APPEND = 2
const PREPEND = 3

// An extension's changes to the environment of new terminals.
class EnvironmentVariableCollection {
  constructor(terminals, extension) {
    this._terminals = terminals
    this._extension = extension
    this._variables = new Map()
    this.persistent = false
    this.description = undefined
  }
  _put(variable, value, type, options) {
    this._variables.set(String(variable), {value: String(value), type, options: options || {applyAtProcessCreation: true}})
    this._tell()
  }
  _tell() {
    const variables = Object.fromEntries([...this._variables].map(([name, {value, type}]) => [name, {value, type}]))
    this._terminals.host.notify("terminalEnv", {extension: this._extension.name, variables})
  }
  replace(variable, value, options) {
    this._put(variable, value, REPLACE, options)
  }
  append(variable, value, options) {
    this._put(variable, value, APPEND, options)
  }
  prepend(variable, value, options) {
    this._put(variable, value, PREPEND, options)
  }
  get(variable) {
    return this._variables.get(String(variable))
  }
  forEach(callback, thisArg) {
    this._variables.forEach((mutator, variable) => callback.call(thisArg, variable, mutator, this))
  }
  delete(variable) {
    if (this._variables.delete(String(variable))) this._tell()
  }
  clear() {
    if (this._variables.size === 0) return
    this._variables.clear()
    this._tell()
  }
  getScoped() {
    return this
  }
  [Symbol.iterator]() {
    return [...this._variables].map(([variable, mutator]) => [variable, mutator])[Symbol.iterator]()
  }
}

// The host's part: every extension's terminals.
class Terminals {
  constructor(host) {
    this.host = host
    this.all = new Map() // id → terminal
    this.next = 0
    this.active = undefined
    this.onOpen = new EventEmitter()
    this.onClose = new EventEmitter()
    this.onActive = new EventEmitter()
  }

  // createTerminal(name?, shellPath?, shellArgs?) or createTerminal(options)
  create(extension, first, shellPath, shellArgs) {
    const options = first && typeof first === "object" ? first : {name: first, shellPath, shellArgs}
    const id = String(++this.next)
    const terminal = new Terminal(this, extension, id, options)
    this.all.set(id, terminal)
    this.host.notify("terminalCreate", {
      id,
      extension: extension.name,
      name: terminal.name,
      shell: typeof options.shellPath === "string" ? options.shellPath : null,
      args: Array.isArray(options.shellArgs) ? options.shellArgs.map(String) : [],
      cwd: fsPath(options.cwd) || null,
      env: strings(options.env),
    })
    this.active = terminal
    // (After the caller has its terminal, as in VS Code.)
    queueMicrotask(() => {
      if (terminal._disposed) return
      this.onOpen.fire(terminal)
      this.onActive.fire(terminal)
    })
    return terminal
  }

  // From Bee.
  opened({id, pid}) {
    this.all.get(id)?._pid(typeof pid === "number" ? pid : undefined)
  }

  closed({id, code}) {
    const terminal = this.all.get(id)
    if (!terminal || terminal._disposed) return
    terminal._disposed = true
    terminal._pid(undefined)
    terminal.exitStatus = {code: typeof code === "number" ? code : undefined, reason: 0}
    this.all.delete(id)
    if (this.active === terminal) {
      this.active = [...this.all.values()].at(-1)
      this.onActive.fire(this.active)
    }
    this.onClose.fire(terminal)
  }

  // The terminals of an extension that is going away, and what it wanted
  // in the environment.
  forget(extension) {
    for (const terminal of [...this.all.values()]) if (terminal._extension === extension) terminal.dispose()
    if (extension.environment) extension.environment.clear()
  }

  environment(extension) {
    extension.environment ??= new EnvironmentVariableCollection(this, extension)
    return extension.environment
  }

  api(extension) {
    const terminals = this
    return {
      createTerminal: (first, shellPath, shellArgs) => this.create(extension, first, shellPath, shellArgs),
      get terminals() {
        return [...terminals.all.values()]
      },
      get activeTerminal() {
        return terminals.active
      },
      onDidOpenTerminal: this.onOpen.event,
      onDidCloseTerminal: this.onClose.event,
      onDidChangeActiveTerminal: this.onActive.event,
      onDidChangeTerminalState: new EventEmitter().event,
      // No shell integration: these never fire.
      onDidChangeTerminalShellIntegration: new EventEmitter().event,
      onDidStartTerminalShellExecution: new EventEmitter().event,
      onDidEndTerminalShellExecution: new EventEmitter().event,
      registerTerminalLinkProvider: () => new Disposable(() => {}),
      registerTerminalProfileProvider: () => new Disposable(() => {}),
    }
  }
}

module.exports = {Terminals}
