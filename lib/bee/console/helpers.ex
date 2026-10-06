defmodule Bee.Console.Helpers do
  @moduledoc """
  What the Bee Console (`Bee.Console`) imports, besides `IEx.Helpers`: Bee
  from the inside, acting on the console's window. `help()` lists them.
  """

  alias Bee.Commands.Keybindings
  alias Bee.Commands.Registry, as: CommandRegistry

  @silent :"do not show this result in output"

  @doc "Lists the helpers."
  def help do
    IO.puts("""
    \e[1mBee Console helpers\e[0m (plus IEx's: h/1, i/1, exports/1…)

      commands()          every command, with its title and key
      commands("term")    those matching
      run(id)             runs a command in this window, as if you had
      run(id, args)       with arguments, e.g. run("bee.openFile", ["/path"])
      window()            this window's state: folder, editors, panel…
      root()              this window's folder
      workspaces()        the open folders
      plugins()           the plugins of this window's folder and their status
      memory()            Bee's memory (MB), CPU time and process count

    Anything else is plain Elixir inside Bee: Bee.Settings.all(root()),
    Bee.Plugins.reload(), :sys.get_state(Bee.Plugins.Manager)…
    """)

    @silent
  end

  @doc "Prints the commands whose id or title contains `filter`."
  def commands(filter \\ "") do
    filter = String.downcase(filter)
    keys = Keybindings.all()

    rows =
      for command <- CommandRegistry.commands(),
          title = CommandRegistry.label(command),
          String.contains?(String.downcase(command.id <> " " <> title), filter) do
        {command.id, title, Keybindings.label(command.id, keys)}
      end

    width = rows |> Enum.map(&String.length(elem(&1, 0))) |> Enum.max(fn -> 0 end)

    for {id, title, key} <- Enum.sort(rows) do
      IO.puts(
        "#{String.pad_trailing(id, width)}  #{title}#{if key, do: "  \e[2m#{key}\e[0m", else: ""}"
      )
    end

    IO.puts("\e[2m#{length(rows)} commands\e[0m")
    @silent
  end

  @doc """
  Runs command `id` (with `args`) in the console's window, as the palette
  would. Returns at once.
  """
  def run(id, args \\ []) when is_binary(id) and is_list(args) do
    send(console().window, {:bee_api, {:execute_command, id, args}})
    :ok
  end

  @doc "The console's window state: its folder, editors, panel, palette…"
  def window do
    ref = make_ref()
    send(console().window, {:bee_console, :window, self(), ref})

    receive do
      {^ref, state} -> state
    after
      5_000 -> raise "the window didn't answer"
    end
  end

  @doc "The console's window's folder."
  def root, do: console().root

  @doc "The open folders."
  def workspaces, do: Bee.Workspace.list()

  @doc "The plugins of the window's folder: `%{name => status}`."
  def plugins, do: Map.new(Bee.Plugins.list(root()), &{&1.name, &1.status})

  @doc "Bee's memory in MB, CPU time and process count."
  def memory do
    mb = &div(&1, 1_048_576)
    memory = :erlang.memory()
    {cpu_ms, _} = :erlang.statistics(:runtime)

    %{
      total_mb: mb.(memory[:total]),
      processes_mb: mb.(memory[:processes]),
      code_mb: mb.(memory[:code]),
      binary_mb: mb.(memory[:binary]),
      ets_mb: mb.(memory[:ets]),
      cpu_ms: cpu_ms,
      processes: length(Process.list())
    }
  end

  defp console do
    Process.get(:bee_console) || raise "only in the Bee Console"
  end
end
