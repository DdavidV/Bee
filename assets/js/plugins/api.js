// The `bee` object a browser plugin's activate(bee) receives.
//
//   bee.plugin                       the plugin's name
//   bee.registerCommand(id, fn)      implements a "runtime": "client" command
//   bee.registerMode(name, factory)  a CodeMirror mode for "grammars"
//   bee.showMessage(text, level)     level: "info" | "error"
//   bee.request(method, params)      -> Promise of the server part's answer
//                                    (handle_request/4); rejects with its error
//   bee.onMessage(fn)                fn(data) for Bee.API.post_message/2
//   bee.registerEditorExtension(ext) a CodeMirror extension for every file;
//                                    bee.editor.pathOf(state) tells which file
//   bee.editor                       the active editor (see below)
//   bee.codemirror                   Bee's CodeMirror modules: plugins must use
//                                    these, a second copy of @codemirror/state
//                                    doesn't work with Bee's editor
//
// Everything registered is undone when the plugin is unloaded.

import * as state from "@codemirror/state"
import * as view from "@codemirror/view"
import * as language from "@codemirror/language"
import * as commands from "@codemirror/commands"
import * as autocomplete from "@codemirror/autocomplete"
import {registerCommand} from "../commands/registry"
import {registerMode} from "../editor/modes"
import {getEditor} from "../editor/active"
import {filePath, registerExtension} from "../editor/extensions"

const codemirror = {state, view, language, commands, autocomplete}

// The active editor. Positions are CodeMirror's (UTF-16 offsets).
const editor = {
  // Absolute path of the active file, or null.
  get path() {
    return getEditor()?.active ?? null
  },
  // The file of an EditorState (inside editor extensions).
  pathOf(editorState) {
    return editorState.facet(filePath)
  },
  // The EditorView, or null when no file is open.
  get view() {
    const hook = getEditor()
    return hook?.active ? hook.view : null
  },
  getText() {
    return this.view?.state.doc.toString() ?? null
  },
  // [{from, to, text}]
  getSelections() {
    const v = this.view
    if (!v) return []
    return v.state.selection.ranges.map(r => ({from: r.from, to: r.to, text: v.state.sliceDoc(r.from, r.to)}))
  },
  // Replaces every selection with fn(selectedText) (one undo step).
  replaceSelections(fn) {
    const v = this.view
    if (!v) return false
    v.dispatch(v.state.changeByRange(range => {
      const insert = String(fn(v.state.sliceDoc(range.from, range.to)))
      return {
        changes: {from: range.from, to: range.to, insert},
        range: state.EditorSelection.range(range.from, range.from + insert.length),
      }
    }))
    v.focus()
    return true
  },
  // Inserts text in place of the main selection.
  insert(text) {
    const v = this.view
    if (!v) return false
    v.dispatch(v.state.replaceSelection(String(text)))
    v.focus()
    return true
  },
}

export const createApi = (name, hook) => {
  const disposers = []
  const track = dispose => {
    disposers.push(dispose)
    return dispose
  }

  const bee = {
    plugin: name,
    registerCommand: (id, fn) => track(registerCommand(id, fn)),
    registerMode: (mode, factory) => track(registerMode(mode, factory)),
    showMessage: (text, level = "info") =>
      hook.pushEvent("plugin_message", {plugin: name, level, text: String(text)}),
    request: (method, params = null) => hook.request(name, method, params),
    onMessage: fn => track(hook.onMessage(name, fn)),
    registerEditorExtension: extension => track(registerExtension(extension)),
    editor,
    codemirror,
  }

  return {bee, dispose: () => disposers.splice(0).forEach(dispose => dispose())}
}
