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
