// Markdown from a plugin (its README, on its details page), rendered in the
// browser: `marked` turns it into HTML, DOMPurify keeps only harmless HTML
// (no scripts, event handlers, styles, forms or frames) – a README is the
// plugin author's, not Bee's.
//
// data-markdown  the text
// data-base      where its relative links and images point (the plugin's
//                folder, /plugins/<name>/: Bee serves its images)
//
// Links open outside Bee: in the user's browser (the desktop app's
// bridge), or a new browser tab.

import {marked} from "marked"
import DOMPurify from "dompurify"

const render = (text, base) => {
  const html = marked.parse(text, {gfm: true, async: false})
  const fragment = DOMPurify.sanitize(html, {
    RETURN_DOM_FRAGMENT: true,
    FORBID_TAGS: ["style", "form", "input", "button", "textarea", "select", "iframe"],
    FORBID_ATTR: ["style"],
  })
  const resolve = url => {
    try {
      return new URL(url, new URL(base, window.location.href)).href
    } catch (_e) {
      return null
    }
  }
  for (const img of fragment.querySelectorAll("img[src]")) {
    const src = resolve(img.getAttribute("src"))
    if (src) img.setAttribute("src", src)
    else img.remove()
  }
  for (const a of fragment.querySelectorAll("a[href]")) {
    const href = a.getAttribute("href")
    if (href.startsWith("#")) continue
    const url = resolve(href)
    if (url) a.setAttribute("href", url)
    a.setAttribute("target", "_blank")
    a.setAttribute("rel", "noopener noreferrer")
  }
  return fragment
}

export const Markdown = {
  mounted() {
    this.show()
    this.el.addEventListener("click", e => {
      const a = e.target.closest("a[href]")
      if (!a || a.getAttribute("href").startsWith("#")) return
      e.preventDefault()
      const url = a.href
      if (!/^https?:/.test(url)) return
      if (window.__bridge?.openUrl) window.__bridge.openUrl(url).catch(err => console.warn("Bee: can't open", url, err))
      else window.open(url, "_blank", "noopener")
    })
  },

  // The plugin changed (an update): its new README.
  updated() {
    if (this.el.dataset.markdown !== this.text) this.show()
  },

  show() {
    this.text = this.el.dataset.markdown || ""
    this.el.replaceChildren(render(this.text, this.el.dataset.base || "/"))
  },
}
