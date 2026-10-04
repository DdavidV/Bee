// The CodeMirror modes bundled with Bee. Languages pick them by name in
// priv/contributions/languages.json ("grammars").

import {StreamLanguage} from "@codemirror/language"
import {javascript} from "@codemirror/lang-javascript"
import {json} from "@codemirror/lang-json"
import {css} from "@codemirror/lang-css"
import {html} from "@codemirror/lang-html"
import {markdown} from "@codemirror/lang-markdown"
import {elixir} from "codemirror-lang-elixir"
import {erlang} from "@codemirror/legacy-modes/mode/erlang"
import {shell} from "@codemirror/legacy-modes/mode/shell"
import {yaml} from "@codemirror/legacy-modes/mode/yaml"
import {toml} from "@codemirror/legacy-modes/mode/toml"
import {dockerFile} from "@codemirror/legacy-modes/mode/dockerfile"
import {registerMode} from "./modes"

const stream = parser => () => StreamLanguage.define(parser)

registerMode("elixir", () => elixir())
registerMode("erlang", stream(erlang))
registerMode("javascript", () => javascript({jsx: true}))
registerMode("typescript", () => javascript({jsx: true, typescript: true}))
registerMode("json", () => json())
registerMode("css", () => css())
registerMode("html", () => html())
registerMode("markdown", () => markdown())
registerMode("shell", stream(shell))
registerMode("yaml", stream(yaml))
registerMode("toml", stream(toml))
registerMode("dockerfile", stream(dockerFile))
