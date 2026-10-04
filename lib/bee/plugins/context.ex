defmodule Bee.Plugins.Context do
  @moduledoc """
  What a plugin's server code gets: the plugin, its process and – for
  commands – the window that ran it and that window's active editor.

    * `window` – the LiveView that ran the command; `nil` in `activate/1` and
      events, where `Bee.API` messages go to every window
    * `active_editor` – absolute path, or nil
    * `language` – language id of the active editor
    * `selections` – `[{from, to}]` in the active editor, UTF-8 byte offsets
      into `Bee.API.text/1`
    * `args` – the command's arguments (from a view item, an input box…)

  A plain struct, so Erlang code can match it as a map.
  """

  defstruct [
    :plugin,
    :dir,
    :host,
    :root,
    :window,
    :active_editor,
    :language,
    selections: [],
    args: []
  ]

  @type t :: %__MODULE__{}
end
