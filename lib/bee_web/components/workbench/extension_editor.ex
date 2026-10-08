defmodule BeeWeb.Workbench.ExtensionEditor do
  @moduledoc """
  A plugin's details in an editor tab, like VS Code's extension editor
  (`extension.open`; the tab's path is "extension:<name>"): a header with
  its icon, name, version and buttons, then its README (Details) or what it
  contributes (Features), and a column about its installation.

  The data comes from the plugin itself, see `Bee.Plugins.Details`. The
  README is Markdown from the plugin, rendered and sanitized in the browser
  (the Markdown hook).
  """
  use BeeWeb, :html

  alias Phoenix.LiveView.JS

  attr :details, :map,
    default: nil,
    doc: "Bee.Plugins.Details.get/1; nil: not installed (any more)"

  attr :name, :string, required: true

  def extension_editor(%{details: nil} = assigns) do
    ~H"""
    <div id={"extension-#{@name}"} class="h-full grid place-items-center bg-editor text-editor-fg">
      <p class="opacity-60 text-sm">The plugin {@name} isn't installed.</p>
    </div>
    """
  end

  def extension_editor(assigns) do
    ~H"""
    <div id={"extension-#{@name}"} class="h-full overflow-auto bg-editor text-editor-fg">
      <div class="max-w-5xl mx-auto px-8 py-6">
        <header class="flex gap-6 items-start">
          <img
            :if={@details.icon}
            src={@details.icon}
            alt=""
            class="size-28 shrink-0 object-contain"
          />
          <div
            :if={!@details.icon}
            class="size-28 shrink-0 grid place-items-center rounded-lg bg-base-content/5"
          >
            <.icon name="hero-puzzle-piece" class="size-14 opacity-50" />
          </div>
          <div class="min-w-0 flex-1 space-y-2">
            <h1 class="text-2xl font-semibold truncate">{@details.display_name}</h1>
            <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm">
              <span :if={@details.publisher} class="font-medium">{@details.publisher}</span>
              <span :if={@details.publisher} class="opacity-30">|</span>
              <span :if={@details.version} class="opacity-70">v{@details.version}</span>
              <span class={["badge badge-sm", status_class(@details.status)]}>
                {status(@details.status)}
              </span>
            </div>
            <p :if={@details.description} class="opacity-80">{@details.description}</p>
            <div class="flex flex-wrap gap-2 pt-1">
              <.action
                :if={@details.color_themes != []}
                label="Set Color Theme"
                command="workbench.action.selectTheme"
                name={@details.name}
                primary
              />
              <.action
                :if={@details.icon_themes != []}
                label="Set File Icon Theme"
                command="workbench.action.selectIconTheme"
                name={@details.name}
                primary
              />
              <.action
                :if={@details.status == :disabled}
                label="Enable"
                command="bee.plugins.enable"
                name={@details.name}
              />
              <.action
                :if={@details.status not in [:disabled, :invalid]}
                label="Disable"
                command="bee.plugins.disable"
                name={@details.name}
              />
              <.action
                :if={@details.scope == :user}
                label="Uninstall"
                command="bee.plugins.uninstall"
                name={@details.name}
              />
            </div>
          </div>
        </header>

        <div :if={@details.errors != []} class="mt-4 space-y-1">
          <button
            :for={error <- @details.errors}
            class="block text-left text-sm text-error cursor-pointer hover:underline break-words"
            phx-click="open_problem"
            phx-value-path={error.path}
          >
            {error.message}
          </button>
        </div>

        <nav class="mt-6 flex gap-4 border-b border-base-content/10 text-xs uppercase tracking-wide">
          <.page_tab name={@details.name} page="details" other="features" active>Details</.page_tab>
          <.page_tab name={@details.name} page="features" other="details">Features</.page_tab>
        </nav>

        <div class="mt-4 flex gap-8 items-start">
          <div class="flex-1 min-w-0">
            <section id={"extension-#{@details.name}-details"}>
              <div
                :if={@details.readme}
                id={"extension-#{@details.name}-readme"}
                phx-hook="Markdown"
                phx-update="ignore"
                data-markdown={@details.readme}
                data-base={"/plugins/#{@details.name}/"}
                class="markdown"
              >
              </div>
              <p :if={!@details.readme} class="opacity-60 text-sm">
                No README: this plugin has no README.md.
              </p>
            </section>
            <section id={"extension-#{@details.name}-features"} class="hidden space-y-6">
              <p :if={@details.features == []} class="opacity-60 text-sm">
                It contributes nothing Bee shows here.
              </p>
              <div :for={feature <- @details.features}>
                <h2 class="font-semibold mb-2">
                  {feature.title} <span class="opacity-50 font-normal">({length(feature.rows)})</span>
                </h2>
                <table class="w-full text-sm">
                  <thead>
                    <tr class="text-left border-b border-base-content/15">
                      <th :for={h <- feature.headers} class="py-1 pr-4 font-medium opacity-70">
                        {h}
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={row <- feature.rows} class="border-b border-base-content/5 align-top">
                      <td :for={cell <- row} class="py-1 pr-4 break-words">{cell}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
              <div :if={@details.activation_events != []}>
                <h2 class="font-semibold mb-2">Activation Events</h2>
                <ul class="text-sm space-y-0.5">
                  <li :for={event <- @details.activation_events}><code>{event}</code></li>
                </ul>
              </div>
            </section>
          </div>

          <aside class="w-64 shrink-0 text-sm space-y-6">
            <div>
              <h2 class="font-semibold mb-2">Installation</h2>
              <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1">
                <dt class="opacity-60">Identifier</dt>
                <dd class="break-all">
                  {if @details.publisher,
                    do: "#{@details.publisher}.#{@details.name}",
                    else: @details.name}
                </dd>
                <dt :if={@details.version} class="opacity-60">Version</dt>
                <dd :if={@details.version}>{@details.version}</dd>
                <dt class="opacity-60">Installed</dt>
                <dd>{scope(@details)}</dd>
                <dt class="opacity-60">Runs</dt>
                <dd>{@details.runs}</dd>
                <dt class="opacity-60">Folder</dt>
                <dd class="break-all text-xs" title={@details.dir}>{@details.dir}</dd>
              </dl>
            </div>
            <div :if={@details.license || @details.repository || @details.homepage}>
              <h2 class="font-semibold mb-2">Resources</h2>
              <ul class="space-y-1">
                <li :if={@details.license}>License: {@details.license}</li>
                <li :if={@details.repository}>
                  <a href={@details.repository} target="_blank" rel="noopener" class="link">
                    Repository
                  </a>
                </li>
                <li :if={@details.homepage}>
                  <a href={@details.homepage} target="_blank" rel="noopener" class="link">Homepage</a>
                </li>
              </ul>
            </div>
            <div :if={@details.categories != []}>
              <h2 class="font-semibold mb-2">Categories</h2>
              <div class="flex flex-wrap gap-1">
                <span :for={c <- @details.categories} class="badge badge-sm badge-ghost">{c}</span>
              </div>
            </div>
          </aside>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :command, :string, required: true
  attr :name, :string, required: true
  attr :primary, :boolean, default: false

  defp action(assigns) do
    ~H"""
    <button
      type="button"
      class={["btn btn-sm", if(@primary, do: "btn-primary", else: "btn-outline")]}
      data-command={@command}
      phx-click="run_command"
      phx-value-command={@command}
      phx-value-args={Jason.encode!([@name])}
    >
      {@label}
    </button>
    """
  end

  attr :name, :string, required: true
  attr :page, :string, required: true
  attr :other, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  # Details / Features: switched in the browser.
  defp page_tab(assigns) do
    ~H"""
    <button
      type="button"
      id={"extension-#{@name}-tab-#{@page}"}
      class={[
        "pb-2 -mb-px border-b-2 cursor-pointer",
        if(@active, do: "border-primary", else: "border-transparent opacity-60")
      ]}
      phx-click={
        JS.show(to: "#extension-#{@name}-#{@page}")
        |> JS.hide(to: "#extension-#{@name}-#{@other}")
        |> JS.add_class("border-primary", to: "#extension-#{@name}-tab-#{@page}")
        |> JS.remove_class("border-transparent opacity-60", to: "#extension-#{@name}-tab-#{@page}")
        |> JS.add_class("border-transparent opacity-60", to: "#extension-#{@name}-tab-#{@other}")
        |> JS.remove_class("border-primary", to: "#extension-#{@name}-tab-#{@other}")
      }
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp scope(%{scope: :builtin}), do: "Built-in"
  defp scope(%{scope: :workspace}), do: "This workspace"
  defp scope(%{source: :vsix}), do: "From a VSIX"
  defp scope(_details), do: "User plugin"

  defp status(:inactive), do: "installed"
  defp status(status), do: to_string(status)

  defp status_class(:active), do: "badge-success"
  defp status_class(:activating), do: "badge-info"
  defp status_class(status) when status in [:failed, :invalid], do: "badge-error"
  defp status_class(_), do: "badge-ghost"
end
