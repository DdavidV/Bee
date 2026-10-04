defmodule Bee.Workspace.Glob do
  @moduledoc """
  Glob patterns as used by VS Code's `files.exclude`, matched against paths
  relative to the workspace root:

    * `*` – any characters except `/`
    * `?` – one character except `/`
    * `**` – any characters including `/`; `**/` also matches nothing
    * `{a,b}` – alternatives
  """

  @spec compile(String.t()) :: Regex.t()
  def compile(pattern), do: Regex.compile!("^" <> translate(pattern, "") <> "$")

  @spec match?(Regex.t() | String.t(), String.t()) :: boolean()
  def match?(%Regex{} = regex, path), do: Regex.match?(regex, path)
  def match?(pattern, path), do: Regex.match?(compile(pattern), path)

  defp translate("", acc), do: acc
  defp translate("**/" <> rest, acc), do: translate(rest, acc <> "(?:.*/)?")
  defp translate("**" <> rest, acc), do: translate(rest, acc <> ".*")
  defp translate("*" <> rest, acc), do: translate(rest, acc <> "[^/]*")
  defp translate("?" <> rest, acc), do: translate(rest, acc <> "[^/]")

  defp translate("{" <> rest, acc) do
    case String.split(rest, "}", parts: 2) do
      [alternatives, rest] ->
        group = alternatives |> String.split(",") |> Enum.map_join("|", &translate(&1, ""))
        translate(rest, acc <> "(?:" <> group <> ")")

      [_unclosed] ->
        translate(rest, acc <> "\\{")
    end
  end

  defp translate(<<c::utf8, rest::binary>>, acc),
    do: translate(rest, acc <> Regex.escape(<<c::utf8>>))
end
