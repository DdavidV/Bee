// CodeMirror modes by name. Which language uses which mode is data
// (`grammars` contributions, see Bee.Languages); this is only what the
// browser can highlight: the modes bundled with Bee (builtin_modes.js) and
// those registered by browser plugins.

const modes = new Map() // name -> () => Extension
const listeners = new Set()

export const registerMode = (name, factory) => {
  modes.set(name, factory)
  listeners.forEach(listener => listener(name))
  return () => {
    if (modes.get(name) !== factory) return
    modes.delete(name)
    listeners.forEach(listener => listener(name))
  }
}

// The extension for mode `name`, or [] (no highlighting) when unknown.
export const modeExtension = name => {
  const factory = name && modes.get(name)
  if (!factory) return []
  try {
    return factory()
  } catch (e) {
    console.error(`Bee: mode ${name} failed`, e)
    return []
  }
}

// Calls `listener(name)` when a mode is (un)registered.
export const onModeChange = listener => {
  listeners.add(listener)
  return () => listeners.delete(listener)
}
