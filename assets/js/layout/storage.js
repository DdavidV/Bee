// Sidebar width and panel height, remembered per workspace in localStorage
// (VS Code keeps layout per workspace too). The workspace comes from the
// bee-workspace meta tag; root.html.heex reads the same key to apply the
// sizes before the first paint, and app.js sends them with the LiveView
// connection so the server renders them from the start.

const key = () => `bee:layout:${document.querySelector("meta[name=bee-workspace]")?.content}`

export const loadLayout = () => {
  try {
    return JSON.parse(localStorage.getItem(key()) || "{}")
  } catch (_e) {
    return {}
  }
}

export const saveLayout = (part, size) => {
  try {
    const layout = loadLayout()
    if (size == null) delete layout[part]
    else layout[part] = size
    localStorage.setItem(key(), JSON.stringify(layout))
  } catch (_e) {
    // storage unavailable: sizes just aren't remembered
  }
}
