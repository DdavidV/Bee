// Evaluates `when` clause ASTs produced by Bee.Commands.When (lib/bee/commands/when.ex).
// Keep the semantics in sync with Bee.Commands.When.eval/2, which is unit tested.

const truthy = v => !(v === undefined || v === null || v === false || v === 0 || v === "")

const looseEq = (a, b) => {
  if (typeof a === "boolean" || typeof b === "boolean") return a === b
  if (a === undefined || a === null) return false
  return String(a) === String(b)
}

const number = v => {
  if (typeof v === "number") return v
  if (typeof v === "string" && v.trim() !== "" && !isNaN(Number(v))) return Number(v)
  return null
}

const regexCache = new Map()
const regex = (source, flags) => {
  const k = source + "/" + flags
  if (!regexCache.has(k)) {
    let re = null
    try { re = new RegExp(source, flags.replace(/[^imsu]/g, "")) } catch (_) {}
    regexCache.set(k, re)
  }
  return regexCache.get(k)
}

const member = (container, value) => {
  if (Array.isArray(container)) return container.includes(value)
  if (container && typeof container === "object") return Object.hasOwn(container, String(value))
  return false
}

export const evaluate = (ast, ctx) => {
  const [op, a, b, c] = ast
  switch (op) {
    case "true": return true
    case "false": return false
    case "key": return truthy(ctx[a])
    case "not": return !evaluate(a, ctx)
    case "and": return ast.slice(1).every(e => evaluate(e, ctx))
    case "or": return ast.slice(1).some(e => evaluate(e, ctx))
    case "eq": return looseEq(ctx[a], b)
    case "ne": return !looseEq(ctx[a], b)
    case "lt": case "le": case "gt": case "ge": {
      const x = number(ctx[a]), y = number(b)
      if (x === null || y === null) return false
      return op === "lt" ? x < y : op === "le" ? x <= y : op === "gt" ? x > y : x >= y
    }
    case "regex": {
      const v = ctx[a], re = regex(b, c)
      return v !== undefined && v !== null && re !== null && re.test(String(v))
    }
    case "in": return member(ctx[b], ctx[a])
    case "notin": return !member(ctx[b], ctx[a])
    default: return false
  }
}
