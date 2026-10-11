// Every test file gets a Bee of its own (tests/helpers.mjs: freshBee), so
// files run side by side: one worker each, as many as BEE_TEST_WORKERS
// (default: half the processors, at most 8 – a Bee and a browser each).
// The tests of a file share its Bee and run in order.
import {defineConfig} from "@playwright/test"
import {existsSync} from "node:fs"
import {cpus} from "node:os"
import {join} from "node:path"
import {here} from "./fixtures.mjs"

// Chromium's libraries unpacked by setup.sh, when the system lacks them.
const libs = join(here, "libs/root/usr/lib/x86_64-linux-gnu")
if (existsSync(libs)) process.env.LD_LIBRARY_PATH = [libs, process.env.LD_LIBRARY_PATH].filter(Boolean).join(":")

const workers = Number(process.env.BEE_TEST_WORKERS) || Math.max(1, Math.min(8, Math.floor(cpus().length / 2)))

export default defineConfig({
  testDir: "tests",
  globalSetup: "./global-setup.mjs",
  workers,
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  timeout: 30_000,
  expect: {timeout: 10_000},
  reporter: [["list"], ["html", {open: "never"}]],
  use: {
    viewport: {width: 1200, height: 700},
    // BEE_TEST_TRACE=1: a trace of every failed test (slower).
    trace: process.env.BEE_TEST_TRACE ? "retain-on-failure" : "off",
    screenshot: "only-on-failure",
  },
})
