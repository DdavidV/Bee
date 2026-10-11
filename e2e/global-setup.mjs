// Before a run: Bee's release, up to date; the real language extension the
// tests use, downloaded once (kept in ./.cache). After it: every Bee
// stopped, the test folders gone.
import {existsSync, mkdirSync, renameSync, rmSync, writeFileSync} from "node:fs"
import {buildRelease, stopAll} from "./bee.mjs"
import {cache, elixirLs, workRoot} from "./fixtures.mjs"

const download = async () => {
  if (existsSync(elixirLs.vsix) || process.env.BEE_TEST_OFFLINE) return
  mkdirSync(cache, {recursive: true})
  try {
    console.log(`Downloading ElixirLS ${elixirLs.version} from Open VSX (once)…`)
    const response = await fetch(elixirLs.url, {signal: AbortSignal.timeout(120_000)})
    if (!response.ok) throw new Error(`${response.status} ${response.statusText}`)
    writeFileSync(elixirLs.vsix + ".part", Buffer.from(await response.arrayBuffer()))
    renameSync(elixirLs.vsix + ".part", elixirLs.vsix)
  } catch (e) {
    rmSync(elixirLs.vsix + ".part", {force: true})
    console.warn(`Couldn't download ElixirLS (${e.message}): its tests are skipped.`)
  }
}

export default async () => {
  await stopAll()
  rmSync(workRoot, {recursive: true, force: true})
  buildRelease()
  await download()

  return async () => {
    await stopAll()
    if (!process.env.BEE_TEST_KEEP) rmSync(workRoot, {recursive: true, force: true})
  }
}
