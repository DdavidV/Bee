defmodule Bee.JSONValidation do
  @moduledoc """
  JSON Schemas for JSON files, like VS Code's `jsonValidation`: a
  `Bee.Contributions.Point` for plugins' (and VSIX extensions')

      "jsonValidation": [{"fileMatch": ["*.swagger.json", "/.config/x.json"], "url": "./schema.json"}]

  `fileMatch` patterns are globs matched against a file's name, or – with a
  `/` – against the end of its path; one starting with `!` excludes. `url`
  is a schema file in the plugin or an `http(s)` address (fetched, cached:
  `Bee.JSONValidation.Schemas`). Schemas may be draft 4, 6 or 7.

  `validate/3` checks a JSON (or JSONC) file's text against the schemas
  matching it and returns diagnostics for the editor: a syntax error, or
  the schemas' errors, each placed on the value or key it is about.
  """
  @behaviour Bee.Contributions.Point

  alias Bee.Contributions
  alias Bee.JSON.Located
  alias Bee.JSONValidation.Schemas
  alias ExJsonSchema.Validator.Error

  @languages ~w(json jsonc)

  @type diagnostic :: %{
          from: non_neg_integer(),
          to: non_neg_integer(),
          line: pos_integer(),
          severity: :error | :warning,
          message: String.t()
        }

  @doc "Whether files of language `id` are validated."
  def language?(id), do: id in @languages

  @doc "The schemas (`url`s) for the file at `path`, in contribution order."
  def schemas_for(path) do
    for {_source, entries} <- Contributions.entries(:json_validation),
        entry <- entries,
        matches?(entry.file_match, path),
        uniq: true,
        do: entry.url
  end

  # A pattern matches, and the last matching one isn't an exclusion.
  defp matches?(patterns, path) do
    patterns
    |> Enum.filter(fn pattern -> glob?(String.trim_leading(pattern, "!"), path) end)
    |> List.last()
    |> case do
      nil -> false
      "!" <> _ -> false
      _ -> true
    end
  end

  defp glob?(pattern, path) do
    if String.contains?(pattern, "/"),
      do: Bee.Workspace.Glob.match?("**/" <> String.trim_leading(pattern, "/"), path),
      else: Bee.Workspace.Glob.match?(pattern, Path.basename(path))
  end

  @doc """
  The diagnostics of `text`, the file at `path`: a syntax error, else what
  its schemas (`schemas_for/1`) find – or why a schema can't be used.
  """
  @spec validate(String.t(), String.t(), [String.t()]) :: [diagnostic]
  def validate(path, text, urls \\ nil) do
    urls = urls || schemas_for(path)
    # Loaded even when the text doesn't parse (yet): completion uses them.
    Enum.each(urls, &Schemas.get/1)

    case Located.parse(text) do
      {:error, message, offset} ->
        [diagnostic(text, offset, min(offset + 1, byte_size(text)), :error, message)]

      {:ok, _value, _locs} when urls == [] ->
        []

      {:ok, value, locs} ->
        for(url <- urls, d <- check(url, value, locs, text), do: d)
        |> Enum.sort_by(&{&1.from, &1.to})
    end
  end

  defp check(url, value, locs, text) do
    case Schemas.get(url) do
      {:ok, root} ->
        case ExJsonSchema.Validator.validate(root, value, error_formatter: false) do
          :ok ->
            []

          {:error, errors} ->
            errors |> Enum.flat_map(&flatten/1) |> Enum.map(&place(&1, locs, text))
        end

      {:error, message} ->
        [
          diagnostic(
            text,
            0,
            min(1, byte_size(text)),
            :warning,
            "Can't use the schema #{url}: #{message}"
          )
        ]
    end
  end

  # if/then/else reports its branch's errors.
  defp flatten(%Error{error: %Error.IfThenElse{errors: inner}}) when inner != [],
    do: Enum.flat_map(inner, &flatten/1)

  defp flatten(error), do: [error]

  # On the property's key for objects and arrays (not all of it), on the
  # value for the rest; missing properties on their object's key.
  defp place(%Error{error: error, path: pointer}, locs, text) do
    path = path(pointer)
    loc = nearest(locs, path)

    {from, to} =
      case {error, loc} do
        {%Error.AdditionalProperties{}, %{key_from: from, key_to: to}} ->
          {from, to}

        {_, %{key_from: from, key_to: to, from: vfrom}} ->
          if :binary.at(text, vfrom) in [?{, ?[], do: {from, to}, else: {vfrom, loc.to}

        {_, %{from: from, to: to}} ->
          if :binary.at(text, from) in [?{, ?[], do: {from, from + 1}, else: {from, to}
      end

    diagnostic(text, from, to, :warning, message(error, path))
  end

  # The location of `path`, or of the closest value containing it.
  defp nearest(locs, path) do
    case locs do
      %{^path => loc} -> loc
      _ when path == [] -> %{from: 0, to: 0}
      _ -> nearest(locs, Enum.drop(path, -1))
    end
  end

  # "#/a/0/b~1c" → ["a", "0", "b/c"]
  defp path("#"), do: []

  defp path("#/" <> pointer),
    do:
      pointer
      |> String.split("/")
      |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))

  # Messages like VS Code's.
  defp message(%Error.AdditionalProperties{}, path),
    do: ~s(Property "#{List.last(path)}" is not allowed.)

  defp message(error, _path), do: message(error)

  defp message(%Error.Required{missing: missing}),
    do: "Missing property #{Enum.map_join(missing, ", ", &~s("#{&1}"))}."

  defp message(%Error.Type{expected: expected}),
    do: "Incorrect type. Expected #{Enum.map_join(List.wrap(expected), " or ", &~s("#{&1}"))}."

  defp message(%Error.Enum{}), do: "Value is not accepted."

  defp message(error) do
    text = to_string(error)
    if String.ends_with?(text, "."), do: text, else: text <> "."
  end

  defp diagnostic(text, from, to, severity, message) do
    line = text |> binary_part(0, from) |> :binary.matches("\n") |> length()
    %{from: from, to: max(to, from), line: line + 1, severity: severity, message: message}
  end

  ## Contribution point

  @impl Contributions.Point
  def key, do: :json_validation

  @impl Contributions.Point
  def normalize!(manifest, source, opts) do
    case get_in(manifest, ["contributes", "jsonValidation"]) do
      list when list in [nil, []] ->
        nil

      list ->
        dir =
          case {source, opts[:dir]} do
            {{:plugin, _}, dir} when is_binary(dir) -> Path.expand(dir)
            _ -> raise ArgumentError, "jsonValidation can only come from a plugin"
          end

        for %{"fileMatch" => match, "url" => url} <- list do
          %{file_match: List.wrap(match), url: url!(url, dir)}
        end
    end
  end

  # A web address as it is; a file: its path, inside the plugin.
  defp url!("http://" <> _ = url, _dir), do: url
  defp url!("https://" <> _ = url, _dir), do: url

  defp url!(rel, dir) do
    path = Path.expand(rel, dir)

    cond do
      not String.starts_with?(path, dir <> "/") ->
        raise ArgumentError, "jsonValidation #{rel}: the schema must be inside the plugin"

      not File.regular?(path) ->
        raise ArgumentError, "jsonValidation #{rel}: no such file"

      true ->
        path
    end
  end
end
