// CodeMirror extensions added by browser plugins (bee.registerEditorExtension).
// The CodeEditor hook puts them in every file's state and reconfigures when
// the set changes. `filePath` tells an extension which file a state is.

import {Facet} from "@codemirror/state"

export const filePath = Facet.define({combine: values => values[0] ?? null})

const extensions = new Set()
const listeners = new Set()
const notify = () => listeners.forEach(listener => listener())

export const registerExtension = extension => {
  extensions.add(extension)
  notify()
  return () => {
    if (extensions.delete(extension)) notify()
  }
}

export const pluginExtensions = () => [...extensions]

export const onExtensionsChange = listener => {
  listeners.add(listener)
  return () => listeners.delete(listener)
}
