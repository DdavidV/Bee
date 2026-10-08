defmodule Bee.ColorThemes.Theme do
  @moduledoc """
  A color theme in VS Code's format (the JSON a `themes` contribution
  points to), resolved for use.

      {
        "include": "./base.json",               // optional, read first
        "colors": {"editor.background": "#1e1e1e", "sideBar.background": "#252526", …},
        "tokenColors": [{"scope": ["comment"], "settings": {"foreground": "#6a9955"}}, …]
      }

  `colors` are VS Code's color keys. The ones a theme leaves out get VS
  Code's defaults for its base, dark or light (`priv/color_themes/defaults.json`,
  which only has the keys Bee uses). Colors are `#rgb`, `#rgba`, `#rrggbb`
  or `#rrggbbaa`; anything else is dropped.

  The page gets them as CSS variables named like VS Code's (`css/2`):
  `editor.background` is `--vscode-editor-background`. Bee's components
  use those through the `--color-*` tokens in `app.css`, and daisyUI's
  colors (`base-100`…, `primary`) are set from them too, so the rest of the
  page follows.

  Bee's own themes (no file) have no colors: their daisyUI theme is used
  as it is.
  """

  defstruct id: nil, label: nil, base: :dark, custom?: false, colors: %{}, token_colors: []

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t(),
          base: :dark | :light,
          custom?: boolean(),
          colors: %{String.t() => String.t()},
          token_colors: [map()]
        }

  @external_resource Bee.Priv.path("color_themes/defaults.json")
  @defaults Bee.Priv.read_json!("color_themes/defaults.json")

  @color ~r/^#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/
  @key ~r/^[A-Za-z0-9_.-]+$/

  # daisyUI's colors, from the theme's.
  @daisy [
    {"--color-base-100", "editor.background"},
    {"--color-base-200", "sideBar.background"},
    {"--color-base-300", "editorGroupHeader.tabsBackground"},
    {"--color-base-content", "foreground"},
    {"--color-primary", "button.background"},
    {"--color-primary-content", "button.foreground"},
    {"--color-error", "errorForeground"},
    {"--color-warning", "editorWarning.foreground"},
    {"--color-info", "editorInfo.foreground"},
    {"--color-success", "gitDecoration.addedResourceForeground"}
  ]

  # xterm.js's theme, from the terminal's colors.
  @terminal [
    background: "terminal.background",
    foreground: "terminal.foreground",
    cursor: "terminalCursor.foreground",
    selectionBackground: "terminal.selectionBackground",
    black: "terminal.ansiBlack",
    red: "terminal.ansiRed",
    green: "terminal.ansiGreen",
    yellow: "terminal.ansiYellow",
    blue: "terminal.ansiBlue",
    magenta: "terminal.ansiMagenta",
    cyan: "terminal.ansiCyan",
    white: "terminal.ansiWhite",
    brightBlack: "terminal.ansiBrightBlack",
    brightRed: "terminal.ansiBrightRed",
    brightGreen: "terminal.ansiBrightGreen",
    brightYellow: "terminal.ansiBrightYellow",
    brightBlue: "terminal.ansiBrightBlue",
    brightMagenta: "terminal.ansiBrightMagenta",
    brightCyan: "terminal.ansiBrightCyan",
    brightWhite: "terminal.ansiBrightWhite"
  ]

  @doc "The base of a VS Code `uiTheme`: `vs`/`hc-light` are light, the rest dark."
  def base("vs"), do: :light
  def base("hc-light"), do: :light
  def base(_ui_theme), do: :dark

  @doc """
  A theme from its file's `colors` and `tokenColors` (includes already
  merged in), filled in with the defaults of `base`.
  """
  @spec new(map(), map()) :: t()
  def new(%{id: id, label: label, base: base}, %{colors: colors, token_colors: token_colors}) do
    %__MODULE__{
      id: id,
      label: label,
      base: base,
      custom?: true,
      colors: resolve(colors, base),
      token_colors: token_colors
    }
  end

  @doc "A theme without colors of its own: Bee's daisyUI theme for `base`."
  def plain(%{id: id, label: label, base: base}),
    do: %__MODULE__{id: id, label: label, base: base}

  @doc "The valid colors of a theme file's `colors`."
  def colors(%{} = colors) do
    for {key, value} when is_binary(value) <- colors,
        Regex.match?(@key, key) and Regex.match?(@color, value),
        into: %{},
        do: {key, String.downcase(value)}
  end

  def colors(_colors), do: %{}

  # The theme's colors over the defaults; defaults naming another key take
  # that key's (final) color.
  defp resolve(colors, base) do
    all = Map.merge(@defaults[to_string(base)], colors)

    for {key, _} <- all, color = lookup(all, key, 10), into: %{}, do: {key, color}
  end

  defp lookup(_all, _key, 0), do: nil

  defp lookup(all, key, depth) do
    case all[key] do
      "#" <> _ = color -> color
      nil -> nil
      other -> lookup(all, other, depth - 1)
    end
  end

  @doc """
  The CSS setting the theme's colors on `selector`: the `--vscode-*`
  variables and daisyUI's. Empty for a theme without colors.
  """
  @spec css(t(), String.t()) :: String.t()
  def css(%__MODULE__{custom?: false}, _selector), do: ""

  def css(%__MODULE__{colors: colors}, selector) do
    vscode = for {key, color} <- Enum.sort(colors), do: "#{var(key)}:#{color};"
    daisy = for {var, key} <- @daisy, color = colors[key], do: "#{var}:#{color};"
    "#{selector}{#{Enum.join(vscode)}#{Enum.join(daisy)}}"
  end

  @doc "The CSS variable of a VS Code color key, as VS Code names it for webviews."
  def var(key), do: "--vscode-" <> String.replace(key, ".", "-")

  @doc "xterm.js's theme (`ITheme`) from the theme's terminal colors; `nil` without colors."
  @spec terminal(t()) :: map() | nil
  def terminal(%__MODULE__{custom?: false}), do: nil

  def terminal(%__MODULE__{colors: colors}),
    do: for({name, key} <- @terminal, color = colors[key], into: %{}, do: {name, color})
end
