// "Plugins: Install from VSIX…" (workbench.extensions.action.installVSIX):
// opens the browser's file picker on the hidden upload form; a picked file
// goes up right away and the server installs it (Bee.Plugins.Vsix).

import {registerCommand} from "../commands/registry"

export const VsixInstall = {
  mounted() {
    this.unregister = registerCommand("workbench.extensions.action.installVSIX", () =>
      this.el.querySelector("input[type=file]").click(),
    )
  },

  destroyed() {
    this.unregister()
  },
}
