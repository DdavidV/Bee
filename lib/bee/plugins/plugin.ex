defmodule Bee.Plugin do
  @moduledoc """
  The server part of a plugin: a module in Elixir or Erlang, run by its own
  process (`Bee.Plugins.Host`). Its manifest (`plugin.json`) declares the
  commands, keys, menus and settings; the module implements them.

  ## Elixir

      defmodule WordCount do
        use Bee.Plugin

        @impl true
        def activate(_ctx), do: {:ok, %{runs: 0}}

        @command "wordCount.count"
        def count(ctx, state) do
          text = Bee.API.text(ctx.active_editor)
          Bee.API.show_message(ctx, :info, "\#{length(String.split(text))} words")
          {:ok, %{state | runs: state.runs + 1}}
        end
      end

  ## Erlang

      -module(bee_upcase).
      -behaviour('Elixir.Bee.Plugin').
      -export([upcase/2]).
      -command({<<"upcase.selection">>, upcase}).

      upcase(Ctx, State) -> ..., ok.

  ## Callbacks

  All are optional. Command handlers take the command context
  (`Bee.Plugins.Context`) and the state, and return `:ok` or
  `{:ok, new_state}`. They run one at a time, each with a timeout; an
  exception is reported to the user and leaves the state unchanged.

  `handle_event/2` receives (when exported):

    * `{:buffer_opened, path}`, `{:buffer_changed, path, version}`,
      `{:buffer_saved, path}`, `{:buffer_closed, path}`
    * `{:settings_changed, settings}`

  Messages sent to the plugin's process (`ctx.host`), e.g. by timers, go to
  `handle_info/2`.
  """

  @type state :: term()
  @type result :: :ok | {:ok, state}

  @callback activate(Bee.Plugins.Context.t()) :: {:ok, state} | {:error, term()}
  @callback deactivate(state) :: term()
  @callback handle_event(event :: tuple(), state) :: result
  @callback handle_info(msg :: term(), state) :: result

  @optional_callbacks activate: 1, deactivate: 1, handle_event: 2, handle_info: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour Bee.Plugin
      use Bee.Commands.Command, arity: 2
    end
  end

  @doc """
  The module's command table, id → function name: from `@command`
  (`__commands__/0`) in Elixir, from `-command({Id, Fun}).` attributes in
  Erlang.
  """
  def commands(module) do
    if function_exported?(module, :__commands__, 0) do
      module.__commands__()
    else
      for {:command, entries} <- module.module_info(:attributes),
          {id, fun} <- entries,
          into: %{},
          do: {to_string(id), fun}
    end
  end
end
