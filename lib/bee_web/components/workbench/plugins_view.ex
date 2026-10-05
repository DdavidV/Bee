defmodule BeeWeb.Workbench.PluginsView do
  @moduledoc """
  The Plugins sidebar view (`workbench.extensions.installed`): installed
  plugins from `Bee.Plugins.list/0` with their status and problems. Its
  reload button is a `view/title` menu item in `bee.json`.
  """
  use BeeWeb, :html

  alias BeeWeb.Workbench.Toolbar

  attr :plugins, :list, required: true
  attr :user_dir, :string, required: true
  attr :item_actions, :map, required: true, doc: "row context → inline actions"

  def plugins_view(assigns) do
    ~H"""
    <div id="plugins-view" class="text-sm">
      <div :if={@plugins == []} class="px-3 py-2 text-xs opacity-60 space-y-2">
        <p>No plugins installed.</p>
        <p>
          Put a plugin folder (with a <code>plugin.json</code>) in <code class="break-all">{@user_dir}</code>.
        </p>
      </div>

      <div
        :for={plugin <- @plugins}
        id={"plugin-#{plugin.name}"}
        class="px-3 py-2 border-b border-base-300 hover:bg-base-content/5"
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

  defp context(%{status: :disabled}), do: "plugin.disabled"
  defp context(_plugin), do: "plugin.enabled"

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
