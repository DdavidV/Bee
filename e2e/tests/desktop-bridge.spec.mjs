// Desktop mode, without the desktop app: Bee started the way the app
// starts it, spoken to the way the app speaks to it – frames on its
// stdin and stdout (a length, then JSON), and no port at all. The page,
// its files and LiveView's socket all travel that way. (No browser here.)
import {spawn} from "node:child_process"
import {createConnection} from "node:net"
import {release} from "../bee.mjs"
import {makeFixtures, port} from "../fixtures.mjs"
import {config, dws, expect, test, work} from "./helpers.mjs"

let bee
let frames = []
let waiting = []
let buffer = Buffer.alloc(0)
let stray = ""

const send = frame => {
  const body = Buffer.from(JSON.stringify(frame))
  const head = Buffer.alloc(4)
  head.writeUInt32BE(body.length)
  bee.stdin.write(Buffer.concat([head, body]))
}

// The next frame from Bee that `match` accepts.
const next = (match, what = "a frame") =>
  new Promise((resolve, reject) => {
    const found = frames.findIndex(match)
    if (found >= 0) return resolve(frames.splice(found, 1)[0])
    const timer = setTimeout(() => reject(new Error(`Bee didn't send ${what}`)), 10_000)
    waiting.push({match, resolve, timer})
  })

const receive = chunk => {
  buffer = Buffer.concat([buffer, chunk])
  while (buffer.length >= 4) {
    const length = buffer.readUInt32BE(0)
    if (buffer.length < 4 + length) break
    const text = buffer.subarray(4, 4 + length).toString()
    buffer = buffer.subarray(4 + length)
    let frame
    try {
      frame = JSON.parse(text)
    } catch (_e) {
      stray += text
      continue
    }
    const waiter = waiting.findIndex(w => w.match(frame))
    if (waiter >= 0) {
      const [{resolve, timer}] = waiting.splice(waiter, 1)
      clearTimeout(timer)
      resolve(frame)
    } else frames.push(frame)
  }
}

let ids = 0
// One request of window `win`, answered: {status, headers, body}.
const request = async (url, {win = "w1", method = "GET", headers = [], body = ""} = {}) => {
  const id = ++ids
  send({t: "req", id, win, method, url, headers, body: Buffer.from(body).toString("base64")})
  const res = await next(f => f.t === "res" && f.id === id, `an answer to ${url}`)
  return {status: res.status, headers: Object.fromEntries(res.headers), body: Buffer.from(res.body, "base64").toString()}
}

const listening = () =>
  new Promise(resolve => {
    const socket = createConnection({host: "127.0.0.1", port})
    socket.on("connect", () => (socket.destroy(), resolve(true)))
    socket.on("error", () => resolve(false))
  })

test.beforeAll(async () => {
  makeFixtures()
  bee = spawn(release, ["start"], {
    cwd: dws,
    stdio: ["pipe", "pipe", "ignore"],
    env: {...process.env, BEE_MODE: "desktop", BEE_ROOT: dws, BEE_CONFIG_DIR: config, PORT: String(port), GIT_CEILING_DIRECTORIES: work},
  })
  bee.stdout.on("data", receive)
  // Ready when it answers.
  expect((await request("bee://localhost/")).status).toBe(200)
})

test.afterAll(() => bee?.kill("SIGKILL"))

test("the page is served over the pipe, with no token and no port", async () => {
  const page = await request("bee://localhost/")
  expect(page.status).toBe(200)
  expect(page.headers["content-type"]).toContain("text/html")
  expect(page.body).toContain("data-phx-main")
  expect(page.body).toContain("dws")
  // Nothing listens, on the port it would use or otherwise announced.
  expect(await listening()).toBe(false)
})

test("the page's files come the same way", async () => {
  const page = await request("bee://localhost/")
  const script = page.body.match(/src="(\/assets\/[^"]+\.js[^"]*)"/)[1]
  const style = page.body.match(/href="(\/assets\/[^"]+\.css[^"]*)"/)[1]

  const js = await request(`bee://localhost${script}`)
  expect(js.status).toBe(200)
  expect(js.headers["content-type"]).toContain("javascript")
  expect(js.body.length).toBeGreaterThan(10_000)

  expect((await request(`bee://localhost${style}`)).headers["content-type"]).toContain("css")
  expect((await request("bee://localhost/images/bee.svg")).body).toContain("<svg")
  expect((await request("bee://localhost/plugins/git/browser.js")).status).toBe(200)
  expect((await request("bee://localhost/no/such/page")).status).toBe(404)
})

test("another folder is named in the address, as each window does", async () => {
  const page = await request(`bee://localhost/?folder=${encodeURIComponent(work + "/ws2")}`, {win: "w2"})
  expect(page.status).toBe(200)
  expect(page.body).toContain("ws2")
})

test("cookies stay inside Bee: the app never sees them, each window has its own", async () => {
  const first = await request("bee://localhost/", {win: "cookie-window"})
  expect(first.headers["set-cookie"]).toBeUndefined()
  const token = body => body.match(/name="csrf-token" content="([^"]+)"/)[1]

  // The same window again: the same session (its CSRF token is still good
  // for LiveView, checked below); requests are answered in any order.
  const [a, b, c] = await Promise.all([
    request("bee://localhost/", {win: "cookie-window"}),
    request("bee://localhost/images/bee.svg", {win: "cookie-window"}),
    request("bee://localhost/", {win: "another-window"}),
  ])
  expect(a.status).toBe(200)
  expect(b.body).toContain("<svg")
  expect(token(c.body)).not.toBe(token(a.body))
})

test("LiveView's socket: opened, joined and live over frames", async () => {
  const win = "live-window"
  const page = await request("bee://localhost/", {win})
  const csrf = page.body.match(/name="csrf-token" content="([^"]+)"/)[1]
  const main = page.body.match(/<div[^>]*data-phx-main[^>]*>/)[0]
  const attribute = name => main.match(new RegExp(`${name}="([^"]*)"`))[1]
  const sid = "live-window:s1"

  send({t: "open", sid, win, url: `ws://localhost/live/websocket?vsn=2.0.0&_csrf_token=${encodeURIComponent(csrf)}`})
  await next(f => f.t === "opened" && f.sid === sid, "opened")

  const topic = `lv:${attribute("id")}`
  const join = ["1", "1", topic, "phx_join", {
    url: "bee://localhost/",
    params: {_csrf_token: csrf, _mounts: 0},
    session: attribute("data-phx-session"),
    static: attribute("data-phx-static"),
  }]
  send({t: "msg", sid, data: JSON.stringify(join), bin: false})
  const reply = await next(f => f.t === "msg" && f.sid === sid && f.data.includes("phx_reply"), "the join's reply")
  const [, ref, replyTopic, event, payload] = JSON.parse(reply.data)
  expect([ref, replyTopic, event]).toEqual(["1", topic, "phx_reply"])
  expect(payload.status).toBe("ok")
  // The window, rendered: its files are in it.
  expect(JSON.stringify(payload.response.rendered)).toContain("one.txt")

  // An event of the page: a command, as a menu sends it; the window answers with what changed.
  send({t: "msg", sid, bin: false, data: JSON.stringify(["1", "2", topic, "event", {type: "click", event: "run_command", value: {command: "workbench.action.togglePanel"}}])})
  const diff = await next(f => f.t === "msg" && f.sid === sid && JSON.parse(f.data)[1] === "2", "the event's reply")
  expect(JSON.parse(diff.data)[4].status).toBe("ok")
  expect(diff.data).toContain("Terminal")

  // Heartbeats are answered, like any socket's.
  send({t: "msg", sid, bin: false, data: JSON.stringify([null, "3", "phoenix", "heartbeat", {}])})
  const beat = await next(f => f.t === "msg" && f.sid === sid && JSON.parse(f.data)[1] === "3", "the heartbeat's reply")
  expect(JSON.parse(beat.data)[4].status).toBe("ok")

  send({t: "close", sid})
})

test("a socket without the window's session is refused", async () => {
  const page = await request("bee://localhost/", {win: "honest-window"})
  const csrf = page.body.match(/name="csrf-token" content="([^"]+)"/)[1]
  const main = page.body.match(/<div[^>]*data-phx-main[^>]*>/)[0]
  const attribute = name => main.match(new RegExp(`${name}="([^"]*)"`))[1]

  // Another window (no cookie of the first) with the first one's page.
  const sid = "thief:s1"
  send({t: "open", sid, win: "thief-window", url: `ws://localhost/live/websocket?vsn=2.0.0&_csrf_token=${encodeURIComponent(csrf)}`})
  const opened = await next(f => f.sid === sid && ["opened", "closed"].includes(f.t), "an answer to the open")
  if (opened.t === "opened") {
    const topic = `lv:${attribute("id")}`
    send({t: "msg", sid, bin: false, data: JSON.stringify(["1", "1", topic, "phx_join", {url: "bee://localhost/", params: {_csrf_token: csrf, _mounts: 0}, session: attribute("data-phx-session"), static: attribute("data-phx-static")}])})
    const reply = await next(f => f.t === "msg" && f.sid === sid && f.data.includes("phx_reply"), "the join's reply")
    expect(JSON.parse(reply.data)[4].status).toBe("error")
  }
})

test("a socket Bee doesn't have is closed, with the reason", async () => {
  send({t: "open", sid: "x:s9", win: "w1", url: "ws://localhost/no-such-socket/websocket?vsn=2.0.0"})
  const closed = await next(f => f.t === "closed" && f.sid === "x:s9", "closed")
  expect(closed.reason).toBeTruthy()
})

test("the second address serves webview pages only, never Bee's own", async () => {
  expect((await request("beeview://localhost/")).status).toBe(404)
  expect((await request("beeview://localhost/webview/not-a-panel/")).status).toBe(404)
  expect((await request("beeview://localhost/assets/js/app.js")).status).toBe(404)
  // (Windows' name for it.)
  expect((await request("http://beeview.localhost/")).status).toBe(404)
})

test("frames Bee doesn't know are passed over; only frames ever come out", async () => {
  send({t: "what-is-this", id: 1})
  send({nonsense: true})
  expect((await request("bee://localhost/images/bee.svg")).status).toBe(200)
  expect(stray).toBe("")
  expect(buffer.length).toBe(0)
})

test("Bee stops when its input closes: the app is gone", async () => {
  const exited = new Promise(resolve => bee.on("exit", resolve))
  bee.stdin.end()
  expect(await exited).toBe(0)
})
