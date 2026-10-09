// Snippets like VS Code's (Bee.Snippets sends a file's language's ones):
// offered while typing their prefix, in the completion list, and inserted
// by "Insert Snippet" (cm:snippet). Their bodies use TextMate's snippet
// syntax, which is parsed here and turned into a CodeMirror snippet:
//
//   $1, ${1}, $0          tab stops (Tab / Shift+Tab move between them; the
//                         same number twice is edited together)
//   ${1:default}          a placeholder; nested ones flatten into its text
//   ${1|one,two|}         a choice: the first one (no list to pick from)
//   $NAME, ${NAME:default}, ${NAME/regex/format/flags}
//                         variables (TM_FILENAME, CURRENT_YEAR, UUID…),
//                         resolved when inserted; an unknown one becomes a
//                         placeholder with its name, like in VS Code
//
// Transforms of tab stops (${1/…/…/}) aren't applied: they mirror the stop.
// CodeMirror's fields can't hold braces: a placeholder whose text has some
// is inserted as plain text.

import {EditorState} from "@codemirror/state"
import {snippet} from "@codemirror/autocomplete"
import {filePath} from "./extensions"

let root = null
// The workspace folder, for WORKSPACE_NAME and RELATIVE_FILEPATH.
export const setSnippetRoot = folder => (root = folder || null)

// Parsing

// [{text} | {tabstop, transform?} | {placeholder, children} |
//  {choice, options} | {variable, children?, transform?}]
export const parse = src => {
  let i = 0

  const any = inside => {
    const nodes = []
    let text = ""
    const flush = () => {
      if (text) nodes.push({text})
      text = ""
    }
    while (i < src.length) {
      const ch = src[i]
      if (ch === "\\" && i + 1 < src.length && "$}\\".includes(src[i + 1])) {
        text += src[i + 1]
        i += 2
      } else if (inside && ch === "}") {
        break
      } else if (ch === "$") {
        const start = i
        const node = dollar()
        if (node) {
          flush()
          nodes.push(node)
        } else {
          i = start + 1
          text += "$"
        }
      } else {
        text += ch
        i++
      }
    }
    flush()
    return nodes
  }

  const read = re => {
    re.lastIndex = i
    const m = re.exec(src)
    if (!m || m.index !== i) return null
    i += m[0].length
    return m[0]
  }
  const INT = /\d+/y
  const NAME = /[_a-zA-Z][_a-zA-Z0-9]*/y

  // Up to an unescaped `end`, unescaping \end and \\.
  const until = end => {
    let out = ""
    while (i < src.length && src[i] !== end) {
      if (src[i] === "\\" && i + 1 < src.length && (src[i + 1] === end || src[i + 1] === "\\")) {
        out += src[i + 1]
        i += 2
      } else {
        out += src[i++]
      }
    }
    if (src[i] !== end) return null
    i++
    return out
  }

  // A transform's format, up to its unescaped "/" (not one inside ${…}).
  const formatPart = () => {
    let out = ""
    let depth = 0
    while (i < src.length) {
      const ch = src[i]
      if (ch === "\\" && i + 1 < src.length && "/\\".includes(src[i + 1])) {
        out += src[i + 1]
        i += 2
        continue
      }
      if (ch === "/" && depth === 0) {
        i++
        return out
      }
      if (ch === "$" && src[i + 1] === "{") depth++
      else if (ch === "}" && depth > 0) depth--
      out += ch
      i++
    }
    return null
  }

  const transform = () => {
    // After the "/": regex/format/flags}
    const regex = until("/")
    if (regex === null) return null
    const format = formatPart()
    if (format === null) return null
    const flags = until("}")
    if (flags === null) return null
    return {regex, format, flags}
  }

  const dollar = () => {
    i++ // $
    let n = read(INT)
    if (n !== null) return {tabstop: +n}
    let name = read(NAME)
    if (name !== null) return {variable: name}
    if (src[i] !== "{") return null
    i++
    n = read(INT)
    if (n !== null) {
      const num = +n
      if (src[i] === "}") {
        i++
        return {tabstop: num}
      }
      if (src[i] === ":") {
        i++
        const children = any(true)
        if (src[i] !== "}") return null
        i++
        return {placeholder: num, children}
      }
      if (src[i] === "|") {
        i++
        const options = []
        let option = ""
        while (i < src.length) {
          const ch = src[i]
          if (ch === "\\" && i + 1 < src.length && ",|$}\\".includes(src[i + 1])) {
            option += src[i + 1]
            i += 2
          } else if (ch === ",") {
            options.push(option)
            option = ""
            i++
          } else if (ch === "|" && src[i + 1] === "}") {
            options.push(option)
            i += 2
            return {choice: num, options}
          } else {
            option += ch
            i++
          }
        }
        return null
      }
      if (src[i] === "/") {
        i++
        const t = transform()
        return t ? {tabstop: num, transform: t} : null
      }
      return null
    }
    name = read(NAME)
    if (name !== null) {
      if (src[i] === "}") {
        i++
        return {variable: name}
      }
      if (src[i] === ":") {
        i++
        const children = any(true)
        if (src[i] !== "}") return null
        i++
        return {variable: name, children}
      }
      if (src[i] === "/") {
        i++
        const t = transform()
        return t ? {variable: name, transform: t} : null
      }
    }
    return null
  }

  return any(false)
}

// Transforms: ${VAR/regex/format/flags}

// A transform's format: $n, ${n}, ${n:/upcase|downcase|capitalize|
// camelcase|pascalcase}, ${n:+if}, ${n:?if:else}, ${n:-else}, ${n:else}.
const format = (fmt, groups) =>
  fmt.replace(/\$(\d+)|\$\{(\d+)(?::(\/\w+|\+[^}]*|\?[^:}]*:[^}]*|-[^}]*|[^}]*))?\}/g, (_, a, b, op) => {
    const value = groups[+(a ?? b)] ?? ""
    if (!op) return value
    if (op.startsWith("/")) {
      const words = value.split(/[\s_-]+/).filter(Boolean)
      const cap = w => w.charAt(0).toUpperCase() + w.slice(1)
      switch (op) {
        case "/upcase":
          return value.toUpperCase()
        case "/downcase":
          return value.toLowerCase()
        case "/capitalize":
          return cap(value)
        case "/camelcase":
          return words.map((w, i) => (i ? cap(w) : w.charAt(0).toLowerCase() + w.slice(1))).join("")
        case "/pascalcase":
          return words.map(cap).join("")
        default:
          return value
      }
    }
    if (op.startsWith("+")) return value ? op.slice(1) : ""
    if (op.startsWith("?")) {
      const [then, otherwise] = op.slice(1).split(":")
      return value ? then : otherwise
    }
    return value || (op.startsWith("-") ? op.slice(1) : op)
  })

const transformed = (value, {regex, format: fmt, flags}) => {
  try {
    const re = new RegExp(regex, flags.replace(/[^gimsuy]/g, ""))
    return value.replace(re, (...m) => format(fmt, m.slice(0, -2).filter(x => typeof x !== "object")))
  } catch (_e) {
    return value
  }
}

// Variables

const pad = n => String(n).padStart(2, "0")
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
const randomDigits = (n, base) => Array.from({length: n}, () => Math.floor(Math.random() * base).toString(base)).join("")

// The variables' values where a snippet goes in `state` (`from`-`to`
// selected); undefined for an unknown one.
const variables = (state, from, to) => {
  const path = state.facet(filePath) || ""
  const name = path.split("/").pop()
  const line = state.doc.lineAt(from)
  const word = state.wordAt(from)
  const now = new Date()
  const comments = state.languageDataAt("commentTokens", from)[0] || {}
  const relative = root && path.startsWith(root + "/") ? path.slice(root.length + 1) : path

  const values = {
    TM_SELECTED_TEXT: () => state.sliceDoc(from, to),
    TM_CURRENT_LINE: () => line.text,
    TM_CURRENT_WORD: () => (word ? state.sliceDoc(word.from, word.to) : ""),
    TM_LINE_INDEX: () => String(line.number - 1),
    TM_LINE_NUMBER: () => String(line.number),
    TM_FILENAME: () => name,
    TM_FILENAME_BASE: () => name.replace(/\.[^.]*$/, ""),
    TM_DIRECTORY: () => path.split("/").slice(0, -1).join("/"),
    TM_FILEPATH: () => path,
    RELATIVE_FILEPATH: () => relative,
    WORKSPACE_NAME: () => (root ? root.split("/").pop() : ""),
    WORKSPACE_FOLDER: () => root || "",
    CLIPBOARD: () => "",
    CURSOR_INDEX: () => "0",
    CURSOR_NUMBER: () => "1",
    CURRENT_YEAR: () => String(now.getFullYear()),
    CURRENT_YEAR_SHORT: () => String(now.getFullYear()).slice(-2),
    CURRENT_MONTH: () => pad(now.getMonth() + 1),
    CURRENT_MONTH_NAME: () => MONTHS[now.getMonth()],
    CURRENT_MONTH_NAME_SHORT: () => MONTHS[now.getMonth()].slice(0, 3),
    CURRENT_DATE: () => pad(now.getDate()),
    CURRENT_DAY_NAME: () => DAYS[now.getDay()],
    CURRENT_DAY_NAME_SHORT: () => DAYS[now.getDay()].slice(0, 3),
    CURRENT_HOUR: () => pad(now.getHours()),
    CURRENT_MINUTE: () => pad(now.getMinutes()),
    CURRENT_SECOND: () => pad(now.getSeconds()),
    CURRENT_SECONDS_UNIX: () => String(Math.floor(now.getTime() / 1000)),
    CURRENT_TIMEZONE_OFFSET: () => {
      const offset = -now.getTimezoneOffset()
      return `${offset < 0 ? "-" : "+"}${pad(Math.floor(Math.abs(offset) / 60))}:${pad(Math.abs(offset) % 60)}`
    },
    RANDOM: () => randomDigits(6, 10),
    RANDOM_HEX: () => randomDigits(6, 16),
    UUID: () => crypto.randomUUID(),
    LINE_COMMENT: () => comments.line || "",
    BLOCK_COMMENT_START: () => comments.block?.open || "",
    BLOCK_COMMENT_END: () => comments.block?.close || "",
  }
  return variable => values[variable]?.()
}

// To a CodeMirror template

const escape = text => text.replace(/[{}]/g, "\\$&")

// `body` as a CodeMirror snippet template, its variables from `vars`.
export const template = (body, vars) => {
  const nodes = parse(body)

  // Each tab stop's text: its first placeholder's (or choice's).
  const defaults = new Map()
  let max = 0
  const collect = list => {
    for (const node of list) {
      for (const key of ["tabstop", "placeholder", "choice"]) if (key in node) max = Math.max(max, node[key])
      if ("choice" in node && !defaults.has(node.choice)) defaults.set(node.choice, node.options[0] || "")
      if (node.children) collect(node.children)
      if ("placeholder" in node && !defaults.has(node.placeholder)) defaults.set(node.placeholder, plain(node.children))
    }
  }

  // A node's text, without fields.
  const plain = list => list.map(node => plainNode(node)).join("")
  const plainNode = node => {
    if ("text" in node) return node.text
    if ("placeholder" in node) return defaults.get(node.placeholder) ?? plain(node.children)
    if ("choice" in node) return node.options[0] || ""
    if ("tabstop" in node) return defaults.get(node.tabstop) ?? ""
    let value = vars(node.variable)
    if (value === undefined) return node.children ? plain(node.children) : node.variable
    if (node.transform) value = transformed(value, node.transform)
    return value === "" && node.children ? plain(node.children) : value
  }

  const field = (n, text) => (/[{}]/.test(text) ? escape(text) : text ? `\${${n}:${text}}` : `\${${n}}`)

  let unknown = 0
  const render = list =>
    list
      .map(node => {
        if ("text" in node) return escape(node.text)
        if ("tabstop" in node) return field(node.tabstop, defaults.get(node.tabstop) ?? "")
        if ("placeholder" in node) return field(node.placeholder, defaults.get(node.placeholder))
        if ("choice" in node) return field(node.choice, defaults.get(node.choice))
        let value = vars(node.variable)
        // Unknown: its default, else a placeholder named like it.
        if (value === undefined) return node.children ? render(node.children) : field(max + ++unknown, node.variable)
        if (node.transform) value = transformed(value, node.transform)
        return value === "" && node.children ? render(node.children) : escape(value)
      })
      .join("")

  collect(nodes)
  return render(nodes)
}

// Inserting

// Inserts `body` over `from`-`to` of the view, its first field selected.
export const insertSnippet = (view, body, from, to, completion = null) => {
  const vars = variables(view.state, from, to)
  snippet(template(body, vars))(view, completion, from, to)
}

const WORD_BEFORE = /[^\s()[\]{}"'`,;]+$/
const WORD = /^[^\s()[\]{}"'`,;]*$/

// A completion source offering `snippets` by their prefixes.
const source = snippets => {
  const options = snippets.flatMap(s =>
    s.prefix.map(prefix => ({
      label: prefix,
      detail: s.name,
      info: s.description ? `${s.description}\n\n${s.body}` : s.body,
      type: "text",
      boost: -1,
      apply: (view, completion, from, to) => insertSnippet(view, s.body, from, to, completion),
    })),
  )
  return context => {
    const before = context.matchBefore(WORD_BEFORE)
    if (!before && !context.explicit) return null
    return {from: before ? before.from : context.pos, options, validFor: WORD}
  }
}

// The extension offering a file's snippets while typing. One source for
// good: CodeMirror tells sources apart by identity, a new one each time
// would never finish completing.
export const snippetCompletions = snippets => {
  if (!snippets?.length) return []
  const data = [{autocomplete: source(snippets)}]
  return EditorState.languageData.of(() => data)
}
