defmodule BeeWeb.Icons do
  @moduledoc """
  Icons by name, for things contributions name – commands, view containers,
  view items – embedded at compile time:

    * every Heroicons outline icon: `"plus"`, `"arrow-path"`, … (see
      heroicons.com), what Bee's own manifests and plugins use
    * every VS Code codicon, written as VS Code extensions do:
      `"$(refresh)"`, `"$(sync~spin)"` (`assets/vendor/codicons`)

  and images of a plugin, `%{light: url, dark: url}`: the one for the
  color theme's kind shows.

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

  @codicon_dir Path.expand("../../../assets/vendor/codicons", __DIR__)
  @external_resource @codicon_dir
  @external_resource Path.join(@codicon_dir, "mapping.json")

  @codicon_files (for file <- File.ls!(@codicon_dir),
                      Path.extname(file) == ".svg",
                      into: %{} do
                    @external_resource Path.join(@codicon_dir, file)
                    svg = File.read!(Path.join(@codicon_dir, file))
                    # "blank" is an empty <svg/>.
                    body =
                      case Regex.run(~r{<svg[^>]*>(.*)</svg>}s, svg) do
                        [_, body] -> String.trim(body)
                        nil -> ""
                      end

                    {Path.basename(file, ".svg"), body}
                  end)

  # An icon has several names ("add", "plus"); one of them is its file's.
  @codicons for {_code, names} <-
                  @codicon_dir |> Path.join("mapping.json") |> File.read!() |> Jason.decode!(),
                body = Enum.find_value(names, &@codicon_files[&1]),
                name <- names,
                into: @codicon_files,
                do: {name, body}

  @doc """
  Whether `icon` is one that can be drawn: a Heroicons name, a known
  codicon (`"$(name)"`) or a plugin's images.
  """
  def exists?(%{light: _, dark: _}), do: true
  def exists?("$(" <> _ = icon), do: codicon(icon) != nil
  def exists?(name) when is_binary(name), do: Map.has_key?(@icons, name)
  def exists?(_icon), do: false

  # "$(sync~spin)" → {drawing, spin?}
  defp codicon(icon) do
    with [_, name | modifier] <- Regex.run(~r/^\$\(([a-z0-9-]+)(~spin)?\)$/, icon),
         body when body != nil <- @codicons[name] do
      {body, modifier == ["~spin"]}
    else
      _ -> nil
    end
  end

  attr :name, :any, required: true, doc: "see `exists?/1`"
  attr :class, :any, default: "size-4"
  attr :rest, :global

  @doc "Renders icon `name`; nothing for an unknown (or nil) one."
  def named_icon(%{name: %{light: light, dark: dark}} = assigns) do
    assigns = assign(assigns, light: light, dark: dark)

    ~H"""
    <img src={@light} alt="" class={["shrink-0 dark:hidden", @class]} {@rest} />
    <img src={@dark} alt="" class={["shrink-0 hidden dark:inline", @class]} {@rest} />
    """
  end

  def named_icon(%{name: "$(" <> _ = name} = assigns) do
    {body, spin?} = codicon(name) || {nil, false}
    assigns = assign(assigns, body: body, spin?: spin?)

    ~H"""
    <svg
      :if={@body}
      xmlns="http://www.w3.org/2000/svg"
      fill="currentColor"
      viewBox="0 0 16 16"
      aria-hidden="true"
      class={["shrink-0", @spin? && "animate-spin", @class]}
      {@rest}
    >{Phoenix.HTML.raw(@body)}</svg>
    """
  end

  def named_icon(assigns) do
    assigns =
      assign(assigns, :body, is_binary(assigns.name) && Map.get(@icons, assigns.name))

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
