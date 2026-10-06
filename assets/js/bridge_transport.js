// Desktop mode: a WebSocket-shaped transport for LiveView that opens no
// socket. Frames go to the desktop shell (window.__bridge, which the shell
// provides), and the shell relays them to Bee over its stdin/stdout
// (Desktop.Bridge). phoenix.js only uses this much of WebSocket.
//
// window.__bridge: open(sid, url, transport), send(sid, data), close(sid);
// it calls transport._opened(), _message(data) and _closed(reason).

let nextId = 1
const pageId = Math.random().toString(36).slice(2, 10)

export class BridgeTransport {
  static CONNECTING = 0
  static OPEN = 1
  static CLOSING = 2
  static CLOSED = 3

  constructor(url) {
    this.url = url
    this.readyState = BridgeTransport.CONNECTING
    this.binaryType = "arraybuffer"
    this.bufferedAmount = 0
    // Unique for this page load (the shell adds the window): a reloaded
    // page's sockets mustn't take the ids of the ones going away.
    this.sid = `${pageId}-s${nextId++}`
    window.__bridge.open(this.sid, url, this)
  }

  // From the shell.
  _opened() {
    this.readyState = BridgeTransport.OPEN
    this.onopen && this.onopen({})
  }

  _message(data) {
    this.onmessage && this.onmessage({data})
  }

  _closed(reason) {
    if (this.readyState === BridgeTransport.CLOSED) return
    this.readyState = BridgeTransport.CLOSED
    this.onclose && this.onclose({code: 1000, reason, wasClean: true})
  }

  // From phoenix.js.
  send(data) {
    window.__bridge.send(this.sid, data)
  }

  close(code, reason) {
    this.readyState = BridgeTransport.CLOSING
    window.__bridge.close(this.sid)
    this._closed(reason)
  }
}
