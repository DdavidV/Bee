defmodule BeeWeb.Workbench.PluginsView do
  @moduledoc """
  The Plugins sidebar views, sections like VS Code's: Installed
  (`workbench.extensions.installed`: the user's and the workspace's
  plugins) and Built-in (`workbench.extensions.builtin`), from
  `Bee.Plugins.list/0` with their status and problems. Their Install from
  VSIX and reload buttons are `view/title` menu items in `bee.json`; each
  row's Enable/Disable and Uninstall buttons `view/item/context` ones
  (`viewItem` is `plugin.<enabled|disabled>.<builtin|user|workspace>`).
  Clicking a row opens the plugin's details (`extension.open`).
  """
  use BeeWeb, :html

  alias BeeWeb.Workbench.Toolbar

  attr :id, :string, required: true, doc: "the view's id"
  attr :plugins, :list, required: true, doc: "this section's"
  attr :builtin, :boolean, default: false, doc: "the Built-in section"
  attr :user_dir, :string, required: true
  attr :item_actions, :map, required: true, doc: "row context → inline actions"

  def plugins_view(assigns) do
    ~H"""
    <div id={"plugins-#{@id}"} class="text-sm">
      <p :if={@plugins == [] and @builtin} class="px-3 py-2 text-xs opacity-60">
        No built-in plugins.
      </p>
      <div :if={@plugins == [] and not @builtin} class="px-3 py-2 text-xs opacity-60 space-y-2">
        <p>No plugins installed.</p>
        <p>
          Install one from a VSIX, or put a plugin folder (with a <code>plugin.json</code>)
          in <code class="break-all">{@user_dir}</code>.
        </p>
      </div>

      <div
        :for={plugin <- @plugins}
        id={"plugin-#{plugin.name}"}
        class="px-3 py-2 border-b border-sidebar-section-border hover:bg-list-hover cursor-pointer"
        phx-click="run_command"
        phx-value-command="extension.open"
        phx-value-args={Jason.encode!([plugin.name])}
      >
        <div class="flex items-center gap-2">
          <span class={["font-medium truncate", plugin.status == :disabled && "opacity-50"]}>
            {plugin.display_name}
          </span>
          <span :if={plugin.version} class="text-xs opacity-50">{plugin.version}</span>
          <span class="flex-1" />
          <Toolbar.toolbar
            actions={Map.get(@item_actions, context(plugin), [])}
            args={[plugin.name]}
          />
          <span class={["badge badge-xs", status_class(plugin.status)]}>{status(plugin.status)}</span>
        </div>
        <div :if={plugin.description} class="text-xs opacity-70 truncate" title={plugin.description}>
          {plugin.description}
        </div>
        <div class="text-xs opacity-50">
          {plugin.name} · {kinds(plugin)} · {plugin.scope}
        </div>
        <button
          :for={error <- plugin.errors}
          class="block text-left text-xs text-error mt-1 cursor-pointer hover:underline break-words"
          phx-click="open_problem"
          phx-value-path={error.path}
        >
          {error.message}
        </button>
      </div>
    </div>
    """
  end

  @doc "Every row context: `plugin.<enabled|disabled>.<scope>`."
  def contexts,
    do:
      for(
        state <- ~w(enabled disabled),
        scope <- ~w(builtin user workspace),
        do: "plugin.#{state}.#{scope}"
      )

  defp context(%{status: :disabled, scope: scope}), do: "plugin.disabled.#{scope}"
  defp context(%{scope: scope}), do: "plugin.enabled.#{scope}"

  defp status(:inactive), do: "installed"
  defp status(status), do: to_string(status)

  defp status_class(:active), do: "badge-success"
  defp status_class(:activating), do: "badge-info"
  defp status_class(status) when status in [:failed, :invalid], do: "badge-error"
  defp status_class(_), do: "badge-ghost"

  defp kinds(plugin) do
    [plugin.server? && "server", plugin.browser && "browser"]
    |> Enum.filter(& &1)
    |> case do
      [] -> "contributions only"
      kinds -> Enum.join(kinds, " + ")
    end
  end
end
