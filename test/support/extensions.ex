defmodule Bee.Test.Extensions do
  @moduledoc """
  Test VS Code extensions (`test/fixtures/extensions/<name>`), installed the
  way `Bee.Plugins.Vsix` leaves them: their folder in the user's plugins
  folder, with the `.vsix.json` marker.
  """

  @fixtures Path.expand("../fixtures/extensions", __DIR__)

  @doc "The folder of fixture extension `name`."
  def fixture(name), do: Path.join(@fixtures, name)

  @doc "Installs fixture extension `name` and loads it. Returns its plugin folder."
  def install(name) do
    dir = Path.join(Bee.Plugins.user_dir(), name)
    File.rm_rf!(dir)
    File.mkdir_p!(Bee.Plugins.user_dir())
    File.cp_r!(fixture(name), dir)
    File.write!(Path.join(dir, ".vsix.json"), Jason.encode!(%{name: name}))
    Bee.Plugins.reload(name)
    dir
  end

  @doc "A `.vsix` of fixture extension `name`, written to `path`."
  def vsix(name, path) do
    root = fixture(name)

    entries =
      for file <- Path.wildcard(Path.join(root, "**"), match_dot: true), File.regular?(file) do
        {String.to_charlist("extension/" <> Path.relative_to(file, root)), File.read!(file)}
      end

    {:ok, _} = :zip.create(String.to_charlist(path), entries)
    path
  end
end
