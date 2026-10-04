// Loads the browser parts of plugins. data-plugins: [{name, url}] from
// Bee.Plugins.browser_modules/0; the URL changes when the file does, so an
// edited plugin is unloaded and imported again.
//
// A plugin module exports activate(bee) (see plugins/api.js) and optionally
// deactivate().

import {createApi} from "../plugins/api"

export const Plugins = {
  mounted() {
    this.loaded = new Map() // name -> {url, dispose}
    this.sync()
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
