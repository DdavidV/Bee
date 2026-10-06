// The GUI self-test (`cargo run --features selftest -- <repo>`, see
// src/selftest.rs): drives Bee's real UI in the desktop window and reports
// each check to the shell's stderr (selftest_report), then quits
// (selftest_done). For checking the app where nobody watches the window
// (CI, a remote machine). The folder must be a git repository with lib/a.ex.
(() => {
  if (window.top !== window) return
  const invoke = (cmd, args) => window.__TAURI__.core.invoke(cmd, args)
  const report = (ok, msg) => invoke("selftest_report", {line: `${ok ? "PASS" : "FAIL"} ${msg}`})
  const sleep = ms => new Promise(r => setTimeout(r, ms))
  const waitFor = async (check, ms = 20000) => {
    for (const end = Date.now() + ms; Date.now() < end; await sleep(100)) {
      const value = await check()
      if (value) return value
    }
    return null
  }
  const key = (el, key, opts = {}) =>
    el.dispatchEvent(new KeyboardEvent("keydown", {key, bubbles: true, cancelable: true, ...opts}))

  const run = async () => {
    let ok = true
    const check = async (cond, msg) => {
      ok = ok && !!cond
      await report(!!cond, msg)
    }

    const t0 = performance.now()
    await check(await waitFor(() => document.querySelector("[data-phx-main].phx-connected")),
      `LiveView connected over the bridge (${Math.round(performance.now() - t0)} ms after the page loaded)`)

    // Open lib/a.ex, type at its end, save.
    document.querySelector("#explorer button[phx-value-path='lib']")?.click()
    const file = await waitFor(() => document.querySelector("#explorer button[phx-value-path='lib/a.ex']"))
    file?.click()
    const content = await waitFor(() => document.querySelector(".cm-content"))
    await check(content, "opened a file in the editor")
    if (content) {
      // Synthetic typing doesn't reach CodeMirror in every webview: edit
      // through its view instead (the change still goes to Bee the same way).
      // What EditorView.findFromDOM does.
      const view = content.cmTile?.root?.view
      // The editor exists before the file's text arrives (cm:open): wait for it.
      await check(view && (await waitFor(() => view.state.doc.toString().includes("defmodule"))),
        "the file's text arrived in the editor")
      if (view) {
        view.focus()
        const before = view.state.doc.length
        view.dispatch({
          changes: {from: before, insert: "# typed in the desktop window\n"},
          userEvent: "input.type",
        })
        const dirty = await waitFor(() => document.querySelector("#tabs .rounded-full"), 5000)
        await check(dirty, `edit reached Bee: the tab shows unsaved changes (doc ${before} → ${view.state.doc.length} chars)`)
        // Bee's keybindings match on KeyboardEvent.code.
        key(content, "s", {ctrlKey: true, code: "KeyS"})
        const saved = await waitFor(() => document.querySelector("#status")?.textContent.includes("Saved"), 10000)
        await check(saved, `edited and saved with Ctrl+S (status: "${document.querySelector("#status")?.textContent ?? ""}")`)
      }
    }

    // Git plugin: its browser module came over bee:// (change gutter).
    await check(await waitFor(() => document.querySelector(".bee-git-changes .bee-git-change")),
      "git plugin's browser module loaded (change gutter)")

    // Terminal: open the panel, run a command, read its output.
    document.querySelector("#layout-panel")?.click()
    const input = await waitFor(() => document.querySelector(".xterm-helper-textarea"))
    if (input) {
      await sleep(1500)
      input.focus()
      input.dispatchEvent(new InputEvent("input", {inputType: "insertText", data: "echo tauri-$((40+2))\r", bubbles: true}))
      const out = await waitFor(() => document.querySelector(".xterm-rows")?.textContent.includes("tauri-42"), 15000)
      await check(out, "terminal: a command's output came back")
    } else {
      await check(false, "terminal: the panel didn't open")
    }

    // Windows: Open Folder in New Window (Bee's command) opens a window for
    // lib/; asking again focuses that one instead of opening another.
    const root = document.querySelector("meta[name=bee-workspace]")?.content
    const openFolder = path => window.liveSocket.execJS(document.querySelector("[data-phx-main]"),
      JSON.stringify([["push", {event: "run_command", value: {command: "bee.openFolder", args: JSON.stringify(["new", path])}}]]))
    const lib = `${root}/lib`
    openFolder(lib)
    const windows = await waitFor(async () => {
      const folders = await invoke("selftest_windows")
      return folders.includes(lib) && folders
    }, 15000)
    await check(windows && windows.length === 2, `Open Folder in New Window: a window for lib/ (${JSON.stringify(windows)})`)
    openFolder(lib)
    await sleep(1500)
    const again = await invoke("selftest_windows")
    await check(again.length === 2, `opening lib/ again focuses its window (${again.length} windows)`)
    await invoke("selftest_close_window", {folder: lib})
    const left = await waitFor(async () => (await invoke("selftest_windows")).length === 1, 5000)
    await check(left, "closed lib/'s window")

    // This window still talks to Bee: closing another one mustn't close its
    // sockets (pages number them alike).
    const term = document.querySelector(".xterm-helper-textarea")
    term?.focus()
    term?.dispatchEvent(new InputEvent("input", {inputType: "insertText", data: "echo still-$((20+1))\r", bubbles: true}))
    await check(await waitFor(() => document.querySelector(".xterm-rows")?.textContent.includes("still-21"), 10000),
      "this window still works after another closed")

    await invoke("selftest_done", {ok})
  }

  window.addEventListener("load", () => run().catch(e => report(false, `self-test crashed: ${e}`).then(() => invoke("selftest_done", {ok: false}))))
})()
