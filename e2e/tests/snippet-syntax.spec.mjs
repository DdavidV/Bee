// VS Code's snippet syntax → CodeMirror snippet templates
// (bee/assets/js/editor/snippets.js), in Node: the module is bundled with
// Bee's esbuild, then each body is converted with fixed variables.
import {expect, test} from "@playwright/test"
import {execFileSync} from "node:child_process"
import {mkdtempSync, readdirSync} from "node:fs"
import {tmpdir} from "node:os"
import {dirname, join, resolve} from "node:path"

const repo = resolve(process.env.BEE_REPO || join(dirname(new URL(import.meta.url).pathname), "../.."))

let template
test.beforeAll(async () => {
  const esbuild = readdirSync(join(repo, "_build")).find(f => f.startsWith("esbuild-"))
  const out = join(mkdtempSync(join(tmpdir(), "bee-snippets-")), "snippets.mjs")
  execFileSync(join(repo, "_build", esbuild), [
    join(repo, "assets/js/editor/snippets.js"),
    "--bundle", "--platform=node", "--format=esm", `--outfile=${out}`, "--log-level=warning",
  ])
  ;({template} = await import(out))
})

const vars = name => ({TM_FILENAME: "app.ex", TM_FILENAME_BASE: "app", TM_SELECTED_TEXT: ""})[name]

const cases = [
  ["tab stops and the final position", "def ${1:name} do\n\t$0\nend", "def ${1:name} do\n\t${0}\nend"],
  ["the same stop twice: linked", "$1 and $1", "${1} and ${1}"],
  ["a mirror before its placeholder gets its text", "${2:second} ${1:first} $1", "${2:second} ${1:first} ${1:first}"],
  ["nested placeholders flatten", "${1:a ${2:b}} $2", "${1:a b} ${2:b}"],
  ["a choice: its first option", "${1|one,two\\,x|}", "${1:one}"],
  ["a variable with a transform", "${TM_FILENAME/(\\w+)\\.ex/${1:/upcase}/}", "APP"],
  ["a transform in a placeholder", "defmodule ${1:${TM_FILENAME_BASE/(.*)/${1:/capitalize}/}} do", "defmodule ${1:App} do"],
  ["an empty variable: its default", "${TM_SELECTED_TEXT:fallback}", "fallback"],
  ["an unknown variable: a placeholder, or its default", "$NOPE and ${NOPE2:dflt}", "${1:NOPE} and dflt"],
  ["braces in text are escaped", "obj = {a: ${1:x}}", "obj = \\{a: ${1:x}\\}"],
  ["escapes", "cost \\$5 and \\}", "cost $5 and \\}"],
  ["a placeholder with braces: plain text", "${1:{}}", "\\{\\}"],
  ["a lone $ and an unfinished ${", "$ alone and ${ broken", "$ alone and $\\{ broken"],
]

for (const [what, body, expected] of cases) {
  test(what, () => expect(template(body, vars)).toBe(expected))
}
