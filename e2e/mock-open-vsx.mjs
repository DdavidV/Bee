// A stand-in for Open VSX (https://open-vsx.org/swagger-ui), so the tests
// never reach the real one (it rate limits): the Bee under test gets its
// address as BEE_OPEN_VSX_URL. It knows acme.rocket, a color theme
// ("Rocket Theme") with a package per native platform (Bee installs its
// own platform's), acme.alien, with only a web package (installable
// nowhere), and fillers for paging. GET /__requests counts
// the API requests (searches, metadata; not files such as icons, which the
// browser loads) Bee made; /__reset zeroes it.
import {createServer} from "node:http"
import {crc32} from "node:zlib"

// One per worker (see fixtures.mjs), next to its Bee.
export const mockPort =
  Number(process.env.BEE_TEST_OPEN_VSX_PORT || 4214) + Number(process.env.TEST_PARALLEL_INDEX || 0)
export const mockUrl = `http://127.0.0.1:${mockPort}`

const version = "1.0.0"
const file = name => `${mockUrl}/api/acme/rocket/${version}/file/${name}`
const platforms = ["win32-x64", "win32-ia32", "win32-arm64", "linux-x64", "linux-arm64", "linux-armhf",
  "alpine-x64", "alpine-arm64", "darwin-x64", "darwin-arm64"]
const packageUrl = (name, platform) => `${mockUrl}/api/acme/${name}/${platform}/${version}/file/${name}.vsix`

// The platform this machine is, as Open VSX names it (what Bee picks).
export const hostPlatform = (() => {
  const os = {linux: "linux", darwin: "darwin", win32: "win32"}[process.platform]
  const cpu = {x64: "x64", arm64: "arm64", arm: "armhf", ia32: "ia32"}[process.arch]
  const musl = process.platform === "linux" && !process.report?.getReport().header.glibcVersionRuntime
  const platform = `${musl ? "alpine" : os}-${cpu}`
  return platforms.includes(platform) ? platform : "universal"
})()

const rocket = {
  namespace: "acme",
  name: "rocket",
  displayName: "Rocket",
  description: "A theme that goes up",
  version,
  downloadCount: 12345,
  averageRating: 4.5,
  verified: true,
  namespaceDisplayName: "ACME Corp",
  license: "MIT",
  repository: "https://example.com/acme/rocket",
  categories: ["Themes"],
  timestamp: "2026-09-01T10:00:00Z",
  files: {download: packageUrl("rocket", "win32-x64"), readme: file("README.md"), icon: file("icon.svg")},
  targetPlatform: "win32-x64",
  downloads: Object.fromEntries(platforms.map(p => [p, packageUrl("rocket", p)])),
}

const alien = {
  namespace: "acme",
  name: "alien",
  displayName: "Alien",
  description: "Only runs in a browser's extension host",
  version,
  files: {download: packageUrl("alien", "web")},
  targetPlatform: "web",
  downloads: {web: packageUrl("alien", "web")},
}

const fillers = Array.from({length: 40}, (_, i) => ({
  namespace: "filler",
  name: `ext${i + 1}`,
  displayName: `Filler ${i + 1}`,
  description: "Something else",
  version: "0.0.1",
}))

const readme = "# Rocket\n\nA **theme** that goes up.\n\n<script>window.readmeRan = true</script>\n"
const icon = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><circle cx="5" cy="5" r="5" fill="orange"/></svg>'

// A .vsix: a zip of stored (uncompressed) entries.
export const zip = files => {
  const locals = []
  const centrals = []
  let offset = 0
  for (const [name, text] of Object.entries(files)) {
    const nameBuf = Buffer.from(name)
    const data = Buffer.from(text)
    const crc = crc32(data)
    const local = Buffer.alloc(30)
    local.writeUInt32LE(0x04034b50, 0)
    local.writeUInt16LE(20, 4)
    local.writeUInt32LE(crc, 14)
    local.writeUInt32LE(data.length, 18)
    local.writeUInt32LE(data.length, 22)
    local.writeUInt16LE(nameBuf.length, 26)
    const central = Buffer.alloc(46)
    central.writeUInt32LE(0x02014b50, 0)
    central.writeUInt16LE(20, 4)
    central.writeUInt16LE(20, 6)
    central.writeUInt32LE(crc, 16)
    central.writeUInt32LE(data.length, 20)
    central.writeUInt32LE(data.length, 24)
    central.writeUInt16LE(nameBuf.length, 28)
    central.writeUInt32LE(offset, 42)
    locals.push(local, nameBuf, data)
    centrals.push(central, nameBuf)
    offset += 30 + nameBuf.length + data.length
  }
  const dir = Buffer.concat(centrals)
  const end = Buffer.alloc(22)
  end.writeUInt32LE(0x06054b50, 0)
  end.writeUInt16LE(centrals.length / 2, 8)
  end.writeUInt16LE(centrals.length / 2, 10)
  end.writeUInt32LE(dir.length, 12)
  end.writeUInt32LE(offset, 16)
  return Buffer.concat([...locals, dir, end])
}

const vsix = zip({
  "extension/package.json": JSON.stringify({
    name: "rocket",
    displayName: "Rocket",
    publisher: "acme",
    version,
    contributes: {themes: [{label: "Rocket Theme", uiTheme: "vs-dark", path: "./themes/rocket.json"}]},
  }),
  "extension/themes/rocket.json": JSON.stringify({colors: {"editor.background": "#331100"}}),
  "extension/README.md": readme,
})

let requests = 0
// The platforms of the rocket packages downloaded (GET /__downloads).
const installedPlatforms = []

const json = (res, status, body) => {
  res.writeHead(status, {"content-type": "application/json"})
  res.end(JSON.stringify(body))
}

const handle = (req, res) => {
  const url = new URL(req.url, mockUrl)
  if (url.pathname === "/__requests") return json(res, 200, {requests})
  if (url.pathname === "/__downloads") return json(res, 200, {platforms: installedPlatforms})
  if (url.pathname === "/__reset") {
    requests = 0
    return json(res, 200, {requests})
  }
  if (!url.pathname.includes("/file/")) requests++

  if (url.pathname === "/api/-/search") {
    const query = (url.searchParams.get("query") || "").toLowerCase()
    const offset = Number(url.searchParams.get("offset") || 0)
    const size = Number(url.searchParams.get("size") || 18)
    if (query.includes("ratelimit")) {
      res.writeHead(429, {"content-type": "application/json", "retry-after": "1"})
      return res.end(JSON.stringify({error: "Too many requests"}))
    }
    const all = query.includes("rocket") ? [rocket, ...fillers] : query.includes("alien") ? [alien] : []
    return json(res, 200, {offset, totalSize: all.length, extensions: all.slice(offset, offset + size)})
  }
  if (url.pathname === "/api/acme/rocket") return json(res, 200, rocket)
  if (url.pathname === "/api/acme/alien") return json(res, 200, alien)
  if (url.pathname === `/api/acme/rocket/${version}/file/README.md`) {
    res.writeHead(200, {"content-type": "text/markdown"})
    return res.end(readme)
  }
  if (url.pathname === `/api/acme/rocket/${version}/file/icon.svg`) {
    res.writeHead(200, {"content-type": "image/svg+xml"})
    return res.end(icon)
  }
  const pkg = url.pathname.match(/^\/api\/acme\/rocket\/([a-z0-9-]+)\/1\.0\.0\/file\/rocket\.vsix$/)
  if (pkg && platforms.includes(pkg[1])) {
    installedPlatforms.push(pkg[1])
    res.writeHead(200, {"content-type": "application/octet-stream"})
    return res.end(vsix)
  }
  json(res, 404, {error: `Not found: ${url.pathname}`})
}

let server = null

// Starts it (once in a process), with nothing counted yet.
export const startMockOpenVsx = () => {
  requests = 0
  installedPlatforms.length = 0
  if (server) return server
  server = createServer(handle)
  server.listen(mockPort, "127.0.0.1")
  // Doesn't keep the test run alive.
  server.unref()
  return server
}
