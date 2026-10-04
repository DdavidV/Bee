// Implementations of "runtime": "client" commands (see Bee.Commands.Registry):
// registered by hooks (CodeEditor) and browser plugins. The server asks for
// them with a `bee:exec` event.

const handlers = new Map()

export const registerCommand = (id, handler) => {
  handlers.set(id, handler)
  return () => handlers.get(id) === handler && handlers.delete(id)
}

export const hasCommand = id => handlers.has(id)

export const exec = (id, args = []) => {
  const handler = handlers.get(id)
  if (handler) handler(...args)
  else console.warn(`Bee: no client handler for command ${id}`)
}
