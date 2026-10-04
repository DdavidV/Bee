defmodule Bee.Commands.Command do
  @moduledoc """
  Implements commands as plain functions, tagged with their id:

      defmodule Bee.Workbench.Actions do
        use Bee.Commands.Command

        @command "workbench.action.togglePanel"
        def toggle_panel(workbench), do: ...
      end

  Handlers take a `%Bee.Workbench{}` and return either the new workbench or
  `{workbench, effects}` (see `Bee.Workbench` for effects). Their metadata
  (title, keys, menus) lives in a contributions manifest; `Bee.Commands.Registry`
  joins the two.

  Plugins (`use Bee.Plugin`) use the same annotation with `arity: 2`: their
  handlers take a context and the plugin's state (see `Bee.Plugin`).

  The id → function table is built at compile time and exposed as
  `__commands__/0`. Duplicate ids, wrong arity and a dangling `@command`
  are compile errors.
  """

  defmacro __using__(opts) do
    quote do
      @bee_command_arity unquote(Keyword.get(opts, :arity, 1))
      Module.register_attribute(__MODULE__, :command, accumulate: false)
      Module.register_attribute(__MODULE__, :bee_commands, accumulate: true)
      @on_definition Bee.Commands.Command
      @before_compile Bee.Commands.Command
    end
  end

  @doc false
  def __on_definition__(env, kind, name, args, _guards, _body) do
    case Module.get_attribute(env.module, :command) do
      nil ->
        :ok

      id ->
        Module.delete_attribute(env.module, :command)

        cond do
          kind != :def ->
            compile_error!(env, "@command #{inspect(id)} must be on a public function (def)")

          length(args) != (arity = Module.get_attribute(env.module, :bee_command_arity)) ->
            compile_error!(
              env,
              "@command #{inspect(id)}: #{name} must take #{arity} argument(s)"
            )

          Enum.any?(Module.get_attribute(env.module, :bee_commands), &(elem(&1, 0) == id)) ->
            compile_error!(env, "@command #{inspect(id)} is defined twice")

          true ->
            Module.put_attribute(env.module, :bee_commands, {id, name})
        end
    end
  end

  defmacro __before_compile__(env) do
    if id = Module.get_attribute(env.module, :command) do
      compile_error!(env, "@command #{inspect(id)} is not followed by a function")
    end

    commands = env.module |> Module.get_attribute(:bee_commands) |> Map.new()

    quote do
      @doc false
      def __commands__, do: unquote(Macro.escape(commands))
    end
  end

  defp compile_error!(env, message) do
    raise CompileError, file: env.file, line: env.line, description: message
  end
end
