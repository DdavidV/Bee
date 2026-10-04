defmodule Bee.Priv do
  @moduledoc """
  Bee's own data files in `priv/` (JSON schemas, the contributions
  manifest), for embedding at compile time:

      @external_resource Bee.Priv.path("schemas/settings.schema.json")
      @schema Bee.Priv.read_json!("schemas/settings.schema.json")

  `@external_resource` makes the module recompile when the file changes, and
  a broken file fails the build instead of the boot. Nothing reads `priv/`
  at runtime, so releases need no path lookups.
  """

  @root Path.expand("../../priv", __DIR__)

  @doc "Absolute path of `rel` inside the project's `priv/` directory."
  def path(rel), do: Path.join(@root, rel)

  @doc "Reads and decodes a JSON file from `priv/`."
  def read_json!(rel), do: rel |> path() |> File.read!() |> Jason.decode!()
end
