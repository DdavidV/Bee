// The browser part: a LiveView hook for the plugin's LiveViews
// (phx-hook="TodosLiveFilter" on the view's filter box). Escape empties
// the box, and tells the LiveView.
export function activate(bee) {
  bee.registerHook("TodosLiveFilter", {
    mounted() {
      this.el.addEventListener("keydown", event => {
        if (event.key !== "Escape" || this.el.value === "") return
        event.stopPropagation()
        this.el.value = ""
        this.pushEvent("filter", {filter: ""})
      })
    },
  })
}
