// Opens an address outside Bee: in the user's browser (the desktop app's
// bridge), or a new browser tab.
export const openExternal = url => {
  if (!/^(https?|mailto):/i.test(url)) return
  if (window.__bridge?.openUrl) window.__bridge.openUrl(url).catch(e => console.warn("Bee: can't open", url, e))
  else window.open(url, "_blank", "noopener")
}
