// Loads the browser parts of plugins. data-plugins: [{name, url}] from
// Bee.Plugins.browser_modules/0; the URL changes when the file does, so an
// edited plugin is unloaded and imported again.
//
// A plugin module exports activate(bee) (see plugins/api.js) and optionally
// deactivate(). This hook also carries bee.request() to the server
// (plugin_request → plugin:reply) and Bee.API.post_message/2 to the plugin
// (plugin:message).

import {createApi} from "../plugins/api"

export const Plugins = {
  mounted() {
    this.loaded = new Map() // name -> {url, dispose}
    this.pending = new Map() // request ref -> {resolve, reject}
    this.listeners = new Map() // plugin name -> Set of message handlers
    this.nextRef = 0

    this.handleEvent("plugin:reply", ({ref, result, error}) => {
      const pending = this.pending.get(ref)
      if (!pending) return
      this.pending.delete(ref)
      if (error != null) pending.reject(new Error(error))
      else pending.resolve(result)
    })
    this.handleEvent("plugin:message", ({plugin, data}) => {
      for (const fn of this.listeners.get(plugin) || []) {
        try {
          fn(data)
        } catch (e) {
          console.error(`Bee: plugin ${plugin} message handler failed`, e)
        }
      }
    })
    this.sync()
  },

  request(plugin, method, params) {
    const ref = `r${++this.nextRef}`
    return new Promise((resolve, reject) => {
      this.pending.set(ref, {resolve, reject})
      this.pushEvent("plugin_request", {plugin, method, params, ref})
    })
  },

  onMessage(plugin, fn) {
    if (!this.listeners.has(plugin)) this.listeners.set(plugin, new Set())
    this.listeners.get(plugin).add(fn)
    return () => this.listeners.get(plugin)?.delete(fn)
  },

  updated() {
    this.sync()
  },

  destroyed() {
    for (const name of [...this.loaded.keys()]) this.unload(name)
  },

  sync() {
    const wanted = JSON.parse(this.el.dataset.plugins || "[]")
    const urls = new Map(wanted.map(p => [p.name, p.url]))

    for (const [name, entry] of this.loaded) {
      if (urls.get(name) !== entry.url) this.unload(name)
    }
    for (const {name, url} of wanted) {
      if (!this.loaded.has(name)) this.load(name, url)
    }
  },

  async load(name, url) {
    const {bee, dispose} = createApi(name, this)
    const entry = {url, dispose, module: null}
    this.loaded.set(name, entry)

    try {
      const module = await import(url)
      // Unloaded (or replaced) while importing.
      if (this.loaded.get(name) !== entry) return
      entry.module = module
      await module.activate?.(bee)
    } catch (e) {
      console.error(`Bee: plugin ${name} failed`, e)
      this.pushEvent("plugin_message", {plugin: name, level: "error", text: `failed to load: ${e.message}`})
    }
  },

  unload(name) {
    const entry = this.loaded.get(name)
    if (!entry) return
    this.loaded.delete(name)
    try {
      entry.module?.deactivate?.()
    } catch (e) {
      console.error(`Bee: plugin ${name} deactivate failed`, e)
    }
    entry.dispose()
  },
}
