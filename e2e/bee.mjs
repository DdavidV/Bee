// The Bee under test: a release of this checkout (what users run), built
// when its sources changed, and started for one test file at a time – on
// the worker's port, with its config folder and test folders, the worker's
// stand-in for Open VSX, and nothing of the machine's own setup (git
// identity, shell startup files).
import {execFileSync, spawn} from "node:child_process"
import {existsSync, mkdirSync, openSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync} from "node:fs"
import {dirname, join} from "node:path"
import {cache, config, dws, here, index, port, repo, token, url, work, workRoot} from "./fixtures.mjs"
import {mockUrl} from "./mock-open-vsx.mjs"

export const release = process.env.BEE_RELEASE || join(repo, "_build/prod/rel/bee/bin/bee")
const stamp = join(cache, "release-built")
const pidFile = n => join(workRoot, `w${n}.pid`)
export const logFile = join(workRoot, `w${index}.log`)

// The newest change among what a release is built from.
const newest = path => {
  const stat = statSync(path, {throwIfNoEntry: false})
  if (!stat) return 0
  if (!stat.isDirectory()) return stat.mtimeMs
  let latest = 0
  for (const entry of readdirSync(path)) {
    if (["node_modules", "cache_manifest.json"].includes(entry)) continue
    if (path.endsWith("priv/static") && entry === "assets") continue
    latest = Math.max(latest, newest(join(path, entry)))
  }
  return latest
}

// Builds the release unless it is up to date (BEE_RELEASE: yours, as it is).
export const buildRelease = () => {
  if (process.env.BEE_RELEASE) return
  const changed = () => Math.max(...["lib", "config", "priv", "assets", "rel", "mix.exs", "mix.lock"].map(p => newest(join(repo, p))))
  const built = existsSync(stamp) ? Number(readFileSync(stamp, "utf8")) : 0
  if (existsSync(release) && built >= changed()) return

  console.log("Building Bee's release (mix bee.release)…")
  execFileSync("mix", ["bee.release"], {cwd: repo, env: {...process.env, MIX_ENV: "prod"}, stdio: ["ignore", "ignore", "inherit"]})
  mkdirSync(cache, {recursive: true})
  // (Read again: building touches the static files it digests.)
  writeFileSync(stamp, String(changed()))
}

const alive = pid => {
  try {
    process.kill(pid, 0)
    return true
  } catch (_e) {
    return false
  }
}

// Stops worker `n`'s Bee, and what it started (its process group).
export const stopBee = async (n = index) => {
  if (!existsSync(pidFile(n))) return
  const pid = Number(readFileSync(pidFile(n), "utf8"))
  rmSync(pidFile(n), {force: true})
  for (const signal of ["SIGTERM", "SIGKILL"]) {
    try {
      process.kill(-pid, signal)
    } catch (_e) {
      return
    }
    for (let i = 0; i < 100 && alive(pid); i++) await new Promise(r => setTimeout(r, 30))
    if (!alive(pid)) return
  }
}

const ready = async () => {
  for (let i = 0; i < 600; i++) {
    try {
      const response = await fetch(`${url}/?token=${token}`, {redirect: "manual"})
      if (response.status < 500) return
    } catch (_e) {
      // not listening yet
    }
    await new Promise(r => setTimeout(r, 50))
  }
  throw new Error(`Bee didn't start on ${url}: see ${logFile}`)
}

// Starts this worker's Bee on its folders (made by the caller). `env` adds
// to its environment.
export const startBee = async (env = {}) => {
  await stopBee()
  mkdirSync(workRoot, {recursive: true})
  const log = openSync(logFile, "w")

  const child = spawn(release, ["start"], {
    cwd: dws,
    detached: true,
    stdio: ["ignore", log, log],
    env: {
      ...process.env,
      // The extension host's Node.js: the one running the tests.
      PATH: `${dirname(process.execPath)}:${process.env.PATH}`,
      PORT: String(port),
      BEE_MODE: "server",
      BEE_ROOT: dws,
      BEE_CONFIG_DIR: config,
      BEE_TOKEN: token,
      BEE_OPEN_VSX_URL: mockUrl,
      // The test folders are inside Bee's own checkout: git, run by Bee in
      // one that isn't a repository, mustn't find (or change) that one.
      GIT_CEILING_DIRECTORIES: work,
      // Not the machine's git setup, nor its shell's startup files.
      GIT_CONFIG_GLOBAL: "/dev/null",
      GIT_CONFIG_NOSYSTEM: "1",
      GIT_AUTHOR_NAME: "Bee",
      GIT_AUTHOR_EMAIL: "bee@example.com",
      GIT_COMMITTER_NAME: "Bee",
      GIT_COMMITTER_EMAIL: "bee@example.com",
      SHELL: "/bin/sh",
      ENV: "",
      PS1: "$ ",
      // What a language server builds for itself, kept between runs.
      MIX_INSTALL_DIR: join(cache, "mix-install"),
      ...env,
    },
  })
  child.unref()
  writeFileSync(pidFile(index), String(child.pid))
  await ready()
}

// Every worker's Bee, after a run (also those a crashed worker left).
export const stopAll = async () => {
  if (!existsSync(workRoot)) return
  for (const entry of readdirSync(workRoot)) {
    const match = entry.match(/^w(\d+)\.pid$/)
    if (match) await stopBee(Number(match[1]))
  }
}

export {here}
