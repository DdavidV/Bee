defmodule Bee.LanguagesTest do
  # Registers contributions in the global registry.
  use ExUnit.Case, async: false

  alias Bee.{Contributions, Languages}

  @root "/ws"

  defp detect(path, opts \\ []),
    do: Languages.detect(path, Keyword.merge([root: @root, associations: %{}], opts))

  defp contribute(source, contributes) do
    :ok = Contributions.register(source, %{"name" => "test", "contributes" => contributes})
    on_exit(fn -> Contributions.unregister(source) end)
  end

  describe "Bee's own languages (priv/contributions/languages.json)" do
    test "by extension, the longest one winning" do
      assert detect("/ws/lib/a.ex") == "elixir"
      assert detect("/ws/test/a_test.exs") == "elixir"
      assert detect("/ws/a.HEEX") == "phoenix-heex"
      assert detect("/ws/src/bee.app.src") == "erlang"
      assert detect("/ws/a.unknown") == "plaintext"
      assert detect("/ws/noext") == "plaintext"
    end

    test "file names and patterns before extensions" do
      assert detect("/ws/Dockerfile") == "dockerfile"
      assert detect("/ws/Dockerfile.prod") == "dockerfile"
      assert detect("/ws/Makefile") == "makefile"
      assert detect("/ws/mix.lock") == "elixir"
      # settings.json is JSON with comments, other .json files aren't
      assert detect("/home/me/.config/bee/settings.json") == "jsonc"
      assert detect("/ws/package.json") == "json"
    end

    test "the first line, when nothing else matches" do
      assert detect("/ws/bin/run", first_line: "#!/usr/bin/env elixir") == "elixir"
      assert detect("/ws/bin/run", first_line: "#!/bin/bash") == "shellscript"
      assert detect("/ws/bin/run.txt", first_line: "#!/bin/bash") == "plaintext"
      assert detect("/ws/bin/run", first_line: "hello") == "plaintext"
    end

    test "names and modes" do
      assert Languages.name("elixir") == "Elixir"
      assert Languages.name("unknown-lang") == "unknown-lang"
      assert Languages.mode("jsonc") == "json"
      assert Languages.mode("makefile") == nil
    end
  end

  test "files.associations wins; patterns with a slash match the relative path" do
    associations = %{"*.conf" => "shellscript", "config/*.ex" => "plaintext"}

    assert detect("/ws/app.conf", associations: associations) == "shellscript"
    assert detect("/ws/config/dev.ex", associations: associations) == "plaintext"
    assert detect("/ws/lib/dev.ex", associations: associations) == "elixir"
  end

  test "contributions with the same id merge; later sources win" do
    contribute(:test_merge, %{
      "languages" => [
        %{"id" => "elixir", "extensions" => [".exx"], "filenames" => ["Elixirfile"]},
        %{"id" => "my-heex", "aliases" => ["My HEEx"], "extensions" => [".heex"]}
      ],
      "grammars" => [%{"language" => "elixir", "mode" => "my-elixir"}]
    })

    assert detect("/ws/a.exx") == "elixir"
    assert detect("/ws/Elixirfile") == "elixir"
    assert detect("/ws/a.heex") == "my-heex"
    assert Languages.name("my-heex") == "My HEEx"
    assert Languages.mode("elixir") == "my-elixir"

    elixir = Languages.get("elixir")
    assert elixir.aliases == ["Elixir"]
    assert ".ex" in elixir.extensions and ".exx" in elixir.extensions
  end

  test "an invalid firstLine regex is rejected" do
    assert {:error, message} =
             Contributions.register(:test_bad, %{
               "name" => "test",
               "contributes" => %{"languages" => [%{"id" => "x", "firstLine" => "(unclosed"}]}
             })

    assert message =~ "language x: firstLine"
  end
end
