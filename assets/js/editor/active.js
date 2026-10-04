// The editor, for browser plugins: the CodeEditor hook registers itself
// here, plugins get `bee.editor` (see plugins/api.js).

let editor = null

export const setEditor = hook => {
  editor = hook
  return () => {
    if (editor === hook) editor = null
  }
}

export const getEditor = () => editor

// Context keys the editor knows first (see CodeEditor.contextKeys), fresher
// than the server's copy.
export const editorContext = () => editor?.contextKeys() ?? {}
