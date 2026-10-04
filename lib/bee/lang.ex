defmodule Bee.Lang do

  @by_ext %{
    ".ex" => "elixir",
    ".exs" => "elixir",
    ".heex" => "elixir",
    ".erl" => "erlang",
    ".hrl" => "erlang",
    ".js" => "javascript",
    ".mjs" => "javascript",
    ".jsx" => "javascript",
    ".ts" => "typescript",
    ".tsx" => "typescript",
    ".json" => "json",
    ".css" => "css",
    ".html" => "html",
    ".md" => "markdown",
    ".sh" => "shell",
    ".yml" => "yaml",
    ".yaml" => "yaml",
    ".toml" => "toml"
  }

  def detect(path) do
    case Path.basename(path) do
      "Dockerfile" -> "dockerfile"
      "Makefile" -> "makefile"
      _ -> Map.get(@by_ext, String.downcase(Path.extname(path)), "plaintext")
    end
  end
end
