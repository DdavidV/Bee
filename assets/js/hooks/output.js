// The Output section's text (Bee.Output): one channel's, sent whole when
// it is shown (output:set) and then as it comes (output:append). Stays at
// the end while it is there; scrolled up, it stays where it is.

const MAX_CHARS = 600_000

export const Output = {
  mounted() {
    this.channel = null
    this.length = 0
    this.handleEvent("output:set", ({channel, text}) => {
      this.channel = channel
      this.length = text.length
      this.el.textContent = text
      this.el.scrollTop = this.el.scrollHeight
    })
    this.handleEvent("output:append", ({channel, text}) => {
      if (channel !== this.channel) return
      const atEnd = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 24
      this.el.append(text)
      // Long output: its start goes (whole pieces, as they came).
      // (Counted as it comes: reading the whole text back for every line
      // added would cost more the more there is.)
      this.length += text.length
      while (this.length > MAX_CHARS && this.el.firstChild && this.el.firstChild !== this.el.lastChild) {
        this.length -= this.el.firstChild.textContent.length
        this.el.firstChild.remove()
      }
      if (atEnd) this.el.scrollTop = this.el.scrollHeight
    })
    this.pushEvent("output_ready", {})
  },
}
