defmodule Bee.Plugins.Loader do
  @moduledoc """
  Compiles and loads the server part of a plugin, and unloads it again.

  Erlang files (`.erl`) are compiled first with `:compile.file/2` and loaded
  with `:code.load_binary/3`, then Elixir files (`.ex`) with
  `Kernel.ParallelCompiler`, so Elixir code can call Erlang modules.

  A plugin may not define a module that already exists – Bee's own, Elixir's,
  OTP's or another plugin's. Erlang modules are checked after compiling,
  before loading; Elixir modules from the `defmodule` names in the source,
  before compiling. This guards against accidents, not malice: plugins are
  trusted code that runs with Bee's permissions.
  """

  @type problem :: %{path: String.t(), message: String.t()}

  @default_sources ["lib", "src"]

  @doc """
  Loads `server` (the manifest's `"server"` object) of the plugin in `dir`.
  Returns `{:ok, entry_module, modules}` or `{:error, [problem]}`.
  """
  @spec load(String.t(), map()) :: {:ok, module(), [module()]} | {:error, [problem]}
  def load(dir, %{"module" => entry} = server) do
    with {:ok, files} <- source_files(dir, Map.get(server, "sources", @default_sources)) do
      {erl, ex} = Enum.split_with(files, &(Path.extname(&1) == ".erl"))

      with {:ok, erl_modules} <- load_erlang(erl, dir),
           {:ok, ex_modules} <- load_elixir(ex, erl_modules) do
        modules = erl_modules ++ ex_modules

        case Enum.find(modules, &(Atom.to_string(&1) in [entry, "Elixir." <> entry])) do
          nil ->
            unload(modules)

            {:error,
             [%{path: dir, message: "server module #{entry} is not defined in its sources"}]}

          module ->
            record(modules, true)
            {:ok, module, modules}
        end
      end
    end
  end

  @doc "Purges and deletes `modules` (old processes running them are killed)."
  def unload(modules) do
    for module <- modules do
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end

    record(modules, false)
  end

  @doc "Every module loaded for a plugin and not unloaded since."
  def loaded, do: :persistent_term.get(__MODULE__, MapSet.new()) |> MapSet.to_list()

  # Rarely written (plugin (un)loads), so :persistent_term is fine.
  defp record([], _loaded?), do: :ok

  defp record(modules, loaded?) do
    current = :persistent_term.get(__MODULE__, MapSet.new())

    updated =
      if loaded?,
        do: MapSet.union(current, MapSet.new(modules)),
        else: MapSet.difference(current, MapSet.new(modules))

    :persistent_term.put(__MODULE__, updated)
  end

  ## Sources

  defp source_files(dir, sources) do
    Enum.reduce_while(sources, {:ok, []}, fn source, {:ok, acc} ->
      case Bee.Workspace.FS.resolve(dir, source) do
        {:ok, path} ->
          files =
            cond do
              File.dir?(path) -> Path.wildcard(Path.join(path, "**/*.{ex,erl}"))
              File.regular?(path) -> [path]
              true -> []
            end

          {:cont, {:ok, acc ++ files}}

        {:error, _} ->
          {:halt,
           {:error, [%{path: dir, message: "source #{inspect(source)} is outside the plugin"}]}}
      end
    end)
  end

  ## Erlang

  defp load_erlang(files, dir) do
    include = String.to_charlist(Path.join(dir, "include"))

    files
    |> Enum.map(fn file ->
      case :compile.file(String.to_charlist(file), [
             :binary,
             :return_errors,
             :return_warnings,
             {:i, include}
           ]) do
        {:ok, module, binary, _warnings} ->
          if exists?(module),
            do: {:error, [conflict(file, module)]},
            else: {:ok, {module, file, binary}}

        {:error, errors, _warnings} ->
          {:error, erlang_problems(errors)}
      end
    end)
    |> collect()
    |> case do
      {:ok, compiled} ->
        for {module, file, binary} <- compiled,
            do: {:module, ^module} = :code.load_binary(module, String.to_charlist(file), binary)

        {:ok, Enum.map(compiled, &elem(&1, 0))}

      error ->
        error
    end
  end

  defp erlang_problems(errors) do
    for {file, entries} <- errors, {location, module, description} <- entries do
      %{path: to_string(file), message: "#{line(location)}#{module.format_error(description)}"}
    end
  end

  defp line({line, _col}), do: "line #{line}: "
  defp line(line) when is_integer(line), do: "line #{line}: "
  defp line(_), do: ""

  ## Elixir

  defp load_elixir([], _loaded), do: {:ok, []}

  defp load_elixir(files, loaded) do
    with :ok <- check_elixir_names(files) do
      case Kernel.ParallelCompiler.compile(files, return_diagnostics: true) do
        {:ok, modules, _warnings} ->
          {:ok, modules}

        {:error, errors, _warnings} ->
          # The modules that did compile stay loaded otherwise.
          unload(loaded)

          problems =
            for %{file: file, message: message} = diagnostic <- errors,
                # "cannot compile module (errors have been logged)" repeats the others
                diagnostic.position != 0 or length(errors) == 1,
                do: %{path: file, message: "#{position(diagnostic.position)}#{message}"}

          {:error, problems}
      end
    end
  end

  defp position({line, _col}), do: "line #{line}: "
  defp position(line) when is_integer(line) and line > 0, do: "line #{line}: "
  defp position(_), do: ""

  defp check_elixir_names(files) do
    problems =
      for file <- files,
          module <- defined_modules(file),
          exists?(module),
          do: conflict(file, module)

    if problems == [], do: :ok, else: {:error, problems}
  end

  # Module names from `defmodule` (nested ones included), without compiling.
  defp defined_modules(file) do
    case file |> File.read!() |> Code.string_to_quoted() do
      {:ok, ast} -> collect_modules(ast, nil)
      # Syntax errors are reported by the compiler.
      {:error, _} -> []
    end
  end

  defp collect_modules({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]}, parent)
       when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      module = if parent, do: Module.concat([parent | parts]), else: Module.concat(parts)
      [module | collect_modules(body, module)]
    else
      []
    end
  end

  defp collect_modules({_, _, args}, parent) when is_list(args),
    do: Enum.flat_map(args, &collect_modules(&1, parent))

  defp collect_modules(list, parent) when is_list(list),
    do: Enum.flat_map(list, &collect_modules(&1, parent))

  defp collect_modules({left, right}, parent),
    do: collect_modules(left, parent) ++ collect_modules(right, parent)

  defp collect_modules(_other, _parent), do: []

  ## Helpers

  defp exists?(module),
    do: :code.is_loaded(module) != false or :code.which(module) != :non_existing

  defp conflict(file, module) do
    %{path: file, message: "module #{inspect(module)} already exists; choose another name"}
  end

  defp collect(results) do
    case Enum.split_with(results, &match?({:ok, _}, &1)) do
      {oks, []} -> {:ok, Enum.map(oks, &elem(&1, 1))}
      {_, errors} -> {:error, Enum.flat_map(errors, &elem(&1, 1))}
    end
  end
end
