defmodule BeeWeb.Icons do
  @moduledoc """
  Icons by name, for things contributions name – commands, view containers,
  view items – the way VS Code uses codicons: every Heroicons outline icon
  (`"plus"`, `"arrow-path"`, …, see heroicons.com), embedded at compile time.

  Bee's own templates use the `hero-*` CSS classes (`<.icon>`); those only
  exist for names Tailwind finds in the source, so names coming from
  manifests are rendered from here instead.
  """
  use Phoenix.Component

  @dir Path.expand("../../../deps/heroicons/optimized/24/outline", __DIR__)
  @external_resource @dir

  @icons (for file <- File.ls!(@dir), Path.extname(file) == ".svg", into: %{} do
            @external_resource Path.join(@dir, file)
            svg = File.read!(Path.join(@dir, file))
            # Keep the drawing; the <svg> element is written by named_icon/1.
            [_, body] = Regex.run(~r{<svg[^>]*>(.*)</svg>}s, svg)
            {Path.basename(file, ".svg"), String.trim(body)}
          end)

  @doc "Whether `name` is a known icon."
  def exists?(name), do: Map.has_key?(@icons, name)

  attr :name, :string, required: true
  attr :class, :any, default: "size-4"
  attr :rest, :global

  @doc "Renders icon `name`; nothing for an unknown (or nil) name."
  def named_icon(assigns) do
    assigns = assign(assigns, :body, assigns.name && Map.get(@icons, assigns.name))

    ~H"""
    <svg
      :if={@body}
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      aria-hidden="true"
      class={["shrink-0", @class]}
      {@rest}
    >{Phoenix.HTML.raw(@body)}</svg>
    """
  end
end
