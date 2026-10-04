// Registers the "dotenv" mode its manifest's grammar names: a CodeMirror
// stream parser built with Bee's own CodeMirror (bee.codemirror).
export function activate(bee) {
  const {StreamLanguage} = bee.codemirror.language

  bee.registerMode("dotenv", () =>
    StreamLanguage.define({
      name: "dotenv",
      startState: () => ({value: false}),
      token(stream, state) {
        if (stream.sol()) state.value = false
        if (stream.eatSpace()) return null
        if (stream.peek() === "#") {
          stream.skipToEnd()
          return "comment"
        }
        if (!state.value) {
          if (stream.match(/^export\b/)) return "keyword"
          if (stream.match(/^[A-Za-z_][A-Za-z0-9_.]*/)) return "def"
          if (stream.eat("=")) {
            state.value = true
            return "operator"
          }
        } else {
          if (stream.match(/^"(?:[^"\\]|\\.)*"?/) || stream.match(/^'[^']*'?/)) return "string"
          if (stream.match(/^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)) return "variableName"
          if (stream.match(/^[^\s#$"']+/)) return "string"
        }
        stream.next()
        return null
      },
    })
  )
}
