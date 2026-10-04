defmodule Bee.Contributions.Point do
  @moduledoc """
  A contribution point: one part of a manifest's `contributes` section and
  the registry that answers questions about it (VS Code calls these
  extension points).

  `Bee.Contributions` validates a manifest against the manifest schema, then
  asks every point to `normalize!/3` its part. A point returns `nil` when the
  manifest contributes nothing to it, and raises `ArgumentError` for
  problems the schema can't express (bad `when` clauses, missing handlers…).
  `conflicts/2` checks the result against what other sources contributed.
  """

  @type source :: {:builtin, String.t()} | {:plugin, String.t()} | term()

  @doc "Key the normalized data is stored under (`Bee.Contributions.entries/1`)."
  @callback key() :: atom()

  @doc "Normalizes this point's part of `manifest`; `nil` when there is none."
  @callback normalize!(manifest :: map(), source(), opts :: keyword()) :: term() | nil

  @doc "Messages for clashes between `data` and other sources' data."
  @callback conflicts(data :: term(), others :: [term()]) :: [String.t()]

  @optional_callbacks conflicts: 2
end
