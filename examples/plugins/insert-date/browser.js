// Runs in the browser. `bee` is described in Bee's assets/js/plugins/api.js.
export function activate(bee) {
  bee.registerCommand("insertDate.insert", () => {
    const today = new Date().toISOString().slice(0, 10)
    if (!bee.editor.insert(today)) bee.showMessage("Open a file first", "error")
  })
}
