defmodule BeeWeb.Workbench.PluginLive do
  @moduledoc """
  A plugin's own LiveView (`Bee.Plugin.LiveView`) in the window: in one of
  its views (sidebar, panel) or in an editor tab. Rendered nested
  (`live_render/3`), so it is a process of its own – its crash is its own,
  and it starts again by itself.

  `state` is what `BeeWeb.EditorLive` knows of it (`live_state/3`):
  `%{plugin, module, status, load_id}`, `module` being the LiveView once
  the plugin's code is loaded (nil until then, or when the manifest names
  a module the plugin doesn't have). The element's id carries the plugin's
  `load_id`: a reloaded plugin's LiveView is mounted afresh.
  """
  use BeeWeb, :html

  attr :socket, :any, required: true, doc: "the window's socket"
  attr :state, :map, default: nil
  attr :kind, :string, required: true, doc: ~s("view" or "editor")
  attr :id, :string, required: true, doc: "the view's or editor's id"
  attr :key, :string, default: nil, doc: "an editor tab's own key, when one editor has several"
  attr :root, :string, required: true
  attr :params, :map, default: %{}

  def plugin_live(%{state: %{module: module}} = assigns) when module != nil do
    ~H"""
    {live_render(@socket, @state.module,
      id: dom_id(@kind, @id, @key, @state.load_id),
      session: %{
        "plugin" => @state.plugin,
        "root" => @root,
        "id" => @id,
        "kind" => @kind,
        "params" => @params
      },
      container: {:div, class: "h-full", "data-plugin-live": @id, "data-plugin": @state.plugin}
    )}
    """
  end

  def plugin_live(%{state: %{status: status}} = assigns) when status in [:active, :failed] do
    ~H"""
    <div class="px-4 py-2 text-xs text-error" data-plugin-live-error={@id}>
      {if @state.status == :failed,
        do: "#{@state.plugin} failed to start (see its problems).",
        else: "#{@state.plugin} has no LiveView #{@state.name}."}
    </div>
    """
  end

  def plugin_live(%{state: nil} = assigns) do
    ~H"""
    <div class="px-4 py-2 text-xs opacity-60">Its plugin isn't loaded any more.</div>
    """
  end

  def plugin_live(assigns) do
    ~H"""
    <div class="px-4 py-2 text-xs opacity-50">Loading…</div>
    """
  end

  defp dom_id(kind, id, key, load_id),
    do: "plugin-live-#{kind}-#{:erlang.phash2({id, key})}-#{load_id}"
end
