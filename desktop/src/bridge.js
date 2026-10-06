// window.__bridge for Bee's BridgeTransport (assets/js/bridge_transport.js):
// LiveView's socket frames go to the shell with Tauri commands, and come
// back over a Tauri Channel (which keeps their order). Also opens windows
// and keeps the native title. Injected before the page's own scripts run.
(() => {
  const core = () => window.__TAURI__.core
  const toB64 = buffer => {
    const bytes = new Uint8Array(buffer)
    let s = ""
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
    return btoa(s)
  }
  const fromB64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0)).buffer

  // Tauri may run concurrent invokes out of order; LiveView needs its frames
  // in order (join before events), so they go one after the other.
  let queue = Promise.resolve()
  const invoke = (cmd, args) => (queue = queue.then(() => core().invoke(cmd, args)).catch(e => console.error("bee bridge:", e)))

  const transports = new Map()

  window.__bridge = {
    open(sid, url, transport) {
      transports.set(sid, transport)
      const channel = new (core().Channel)()
      channel.onmessage = f => {
        const t = transports.get(sid)
        if (!t) return
        if (f.t === "opened") t._opened()
        else if (f.t === "msg") t._message(f.bin ? fromB64(f.data) : f.data)
        else if (f.t === "closed") {
          transports.delete(sid)
          t._closed(f.reason)
        }
      }
      invoke("bridge_open", {sid, url, channel})
    },

    send(sid, data) {
      if (typeof data === "string") invoke("bridge_send", {sid, data, bin: false})
      else invoke("bridge_send", {sid, data: toB64(data), bin: true})
    },

    close(sid) {
      transports.delete(sid)
      invoke("bridge_close", {sid})
    },

    // Another window, for a page of Bee ("/?folder=…"): the shell opens it,
    // or focuses the window already showing that folder.
    openWindow(url) {
      core().invoke("bridge_open_window", {url}).catch(e => console.error("bee bridge:", e))
    },
  }

  // The native window's title follows the page's (it changes with the folder).
  addEventListener("DOMContentLoaded", () => {
    const title = document.querySelector("title")
    const report = () => core().invoke("bridge_title", {title: document.title}).catch(() => {})
    report()
    if (title) new MutationObserver(report).observe(title, {childList: true, characterData: true, subtree: true})
  })
})()
