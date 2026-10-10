// Builds the canonical stroke strings of Bee.Commands.Keys ("ctrl+shift+alt+meta+key")
// from KeyboardEvent.code, i.e. physical keys, so bindings work on any layout.

const CODES = {
  Escape: "escape", Enter: "enter", NumpadEnter: "enter", Tab: "tab", Space: "space",
  Backspace: "backspace", Delete: "delete", Insert: "insert",
  ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right",
  Home: "home", End: "end", PageUp: "pageup", PageDown: "pagedown",
  Backquote: "`", Minus: "-", Equal: "=", BracketLeft: "[", BracketRight: "]",
  Backslash: "\\", Semicolon: ";", Quote: "'", Comma: ",", Period: ".", Slash: "/",
  IntlBackslash: "intlbackslash", Pause: "pausebreak", CapsLock: "capslock",
  ContextMenu: "contextmenu", NumLock: "numlock", ScrollLock: "scrolllock",
  NumpadMultiply: "numpad_multiply", NumpadAdd: "numpad_add", NumpadSubtract: "numpad_subtract",
  NumpadDecimal: "numpad_decimal", NumpadDivide: "numpad_divide", NumpadComma: "numpad_separator",
}

const keyOf = code => {
  if (CODES[code]) return CODES[code]
  let m
  if ((m = code.match(/^Key([A-Z])$/))) return m[1].toLowerCase()
  if ((m = code.match(/^(?:Digit|Numpad)(\d)$/))) return m[1]
  if ((m = code.match(/^F(\d{1,2})$/))) return "f" + m[1]
  return null
}

// null for lone modifiers and keys Bee can't bind.
export const strokeFromEvent = e => {
  const key = keyOf(e.code)
  if (!key) return null
  const mods = []
  if (e.ctrlKey) mods.push("ctrl")
  if (e.shiftKey) mods.push("shift")
  if (e.altKey) mods.push("alt")
  if (e.metaKey) mods.push("meta")
  return [...mods, key].join("+")
}

const LABELS = {ctrl: "Ctrl", shift: "Shift", alt: "Alt", meta: "Meta", pageup: "PageUp", pagedown: "PageDown"}

export const label = stroke =>
  stroke.split("+").map(p => LABELS[p] || p.charAt(0).toUpperCase() + p.slice(1)).join("+")

export const isMac = /Mac|iPhone|iPad/.test(navigator.platform)
