// vscode values as plain data, for Bee: positions are {line, character}
// (UTF-16 units, as CodeMirror counts them too).
"use strict"

const position = p => ({line: p.line, character: p.character})
const range = r => ({from: position(r.start), to: position(r.end)})

// A WorkspaceEdit: `{files: [{path, edits: [{from, to, text}]}], operations}`.
const workspaceEdit = edit => ({
  files: edit
    .entries()
    .filter(([uri]) => uri.scheme === "file")
    .map(([uri, edits]) => ({
      path: uri.fsPath,
      edits: edits.map(one => ({...range(one.range), text: String(one.newText ?? "")})),
    })),
  operations: (edit._files || []).map(file => ({
    kind: file.kind,
    path: file.uri.fsPath,
    newPath: file.newUri ? file.newUri.fsPath : null,
    overwrite: !!file.options.overwrite,
    ignoreIfExists: !!file.options.ignoreIfExists,
    ignoreIfNotExists: !!file.options.ignoreIfNotExists,
    recursive: !!file.options.recursive,
  })),
})

module.exports = {position, range, workspaceEdit}
