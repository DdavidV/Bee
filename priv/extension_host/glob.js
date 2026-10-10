// VS Code's glob patterns (document selectors, file system watchers,
// findFiles): `*`, `?`, `**`, `{a,b}`, `[abc]`. Matched against a path
// relative to the pattern's base (or, without one, also against its end).
"use strict"

const path = require("node:path")

const cache = new Map()

const toRegExp = glob => {
  if (cache.has(glob)) return cache.get(glob)
  let source = ""
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i]
    if (c === "*") {
      if (glob[i + 1] === "*") {
        // "**/" also matches nothing.
        if (glob[i + 2] === "/") {
          source += "(?:.*/)?"
          i += 2
        } else {
          source += ".*"
          i += 1
        }
      } else source += "[^/]*"
    } else if (c === "?") source += "[^/]"
    else if (c === "{") {
      const end = glob.indexOf("}", i)
      if (end < 0) source += "\\{"
      else {
        const parts = glob.slice(i + 1, end).split(",").map(part => toRegExp(part).source.slice(1, -1))
        source += `(?:${parts.join("|")})`
        i = end
      }
    } else if (c === "[") {
      const end = glob.indexOf("]", i)
      if (end < 0) source += "\\["
      else {
        source += "[" + glob.slice(i + 1, end).replace(/^!/, "^") + "]"
        i = end
      }
    } else source += c.replace(/[.+^$()|\\]/g, "\\$&")
  }
  const regexp = new RegExp(`^${source}$`)
  cache.set(glob, regexp)
  return regexp
}

// `pattern`: a glob string or a RelativePattern ({base, pattern}).
const matches = (pattern, file, root) => {
  if (pattern && typeof pattern === "object" && typeof pattern.pattern === "string") {
    const base = pattern.base || (pattern.baseUri && pattern.baseUri.fsPath) || root
    if (file !== base && !file.startsWith(base + path.sep)) return false
    return toRegExp(pattern.pattern).test(path.relative(base, file).split(path.sep).join("/"))
  }
  const glob = String(pattern)
  const regexp = toRegExp(glob)
  const relative = root && file.startsWith(root + path.sep) ? file.slice(root.length + 1) : null
  return regexp.test(file) || (relative !== null && regexp.test(relative)) || (!glob.includes("/") && regexp.test(path.basename(file)))
}

module.exports = {matches, toRegExp}
