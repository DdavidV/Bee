// Who gets in (browser mode): Bee's address with its token, once, then the
// cookie it was traded for; nobody else, and only by a local name.
import {request as httpRequest} from "node:http"
import {expect, freshBee, openBee, test, token, url} from "./helpers.mjs"

freshBee()

// A GET that doesn't follow redirects: {status, headers, body}.
const get = (path, headers = {}) =>
  new Promise((resolve, reject) => {
    const req = httpRequest(url + path, {headers}, res => {
      let body = ""
      res.on("data", chunk => (body += chunk))
      res.on("end", () => resolve({status: res.statusCode, headers: res.headers, body}))
    })
    req.on("error", reject)
    req.end()
  })

test("without the token, or with a wrong one, Bee refuses and says what to do", async () => {
  const none = await get("/")
  expect(none.status).toBe(401)
  expect(none.body).toContain("Bee needs its token")
  expect(none.body).toContain("?token=")
  // Nothing of the editor is in the answer.
  expect(none.body).not.toContain("data-phx-main")

  const wrong = await get("/?token=not-the-token")
  expect(wrong.status).toBe(401)
  expect(wrong.headers["set-cookie"]).toBeUndefined()
})

test("the token is traded for a cookie and dropped from the address", async () => {
  const first = await get(`/?folder=%2Ftmp&token=${token}`)
  expect(first.status).toBe(302)
  // The rest of the address is kept.
  expect(first.headers.location).toBe("/?folder=%2Ftmp")
  const cookie = first.headers["set-cookie"].map(c => c.split(";")[0]).join("; ")

  const second = await get("/", {cookie})
  expect(second.status).toBe(200)
  expect(second.body).toContain("data-phx-main")

  // A made-up cookie is no good.
  expect((await get("/", {cookie: "_bee_key=abc"})).status).toBe(401)
})

test("in the browser: the address loses its token, a reload stays in, another browser doesn't get in", async ({page, browser}) => {
  await openBee(page)
  expect(new URL(page.url()).searchParams.has("token")).toBe(false)

  await page.reload()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()

  const stranger = await browser.newContext()
  const other = await stranger.newPage()
  const response = await other.goto(url + "/")
  expect(response.status()).toBe(401)
  await expect(other.getByText("Bee needs its token")).toBeVisible()
  await stranger.close()
})

test("only local names are answered", async () => {
  const evil = await get(`/?token=${token}`, {host: "bee.example.com"})
  expect(evil.status).toBe(403)
  expect(evil.body).toContain("localhost")

  expect((await get(`/?token=${token}`, {host: `localhost:${new URL(url).port}`})).status).toBe(302)
})

test("a plugin's files and webview pages can't be fished for", async () => {
  // No cookie: nothing of a plugin.
  expect((await get("/plugins/git/browser.js")).status).toBe(401)
  // A webview page needs its panel's own token.
  expect((await get("/webview/not-a-panel/")).status).toBe(404)

  const signedIn = await get(`/?token=${token}`)
  const cookie = signedIn.headers["set-cookie"].map(c => c.split(";")[0]).join("; ")
  expect((await get("/plugins/git/browser.js", {cookie})).status).toBe(200)
  // Only what the page needs: not the plugin's other files, nor files outside it.
  expect((await get("/plugins/git/plugin.json", {cookie})).status).toBe(404)
  expect((await get("/plugins/git/lib/bee_git.ex", {cookie})).status).toBe(404)
  expect((await get("/plugins/git/..%2F..%2F..%2Fmix.exs", {cookie})).status).toBe(404)
  expect((await get("/plugins/no-such-plugin/browser.js", {cookie})).status).toBe(404)
})
