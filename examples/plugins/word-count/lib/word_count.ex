defmodule WordCount do
  @moduledoc """
  Counts the words of the active file, or of the selection if there is one.
  Runs in its own process; the state counts how often it ran.
  """
  use Bee.Plugin

  @impl true
  def activate(_ctx), do: {:ok, %{runs: 0}}

  @command "wordCount.count"
  def count(%{active_editor: nil} = ctx, _state),
    do: Bee.API.show_message(ctx, :error, "Open a file first")

  def count(ctx, state) do
    {text, where} =
      case for({_from, _to, text} <- Bee.API.selected(ctx), text != "", do: text) do
        [] -> {Bee.API.text(ctx.active_editor) || "", Path.basename(ctx.active_editor)}
        selected -> {Enum.join(selected, "\n"), "selection"}
      end

    words =
      text
      |> String.split(~r/[^\p{L}\p{N}_'-]+/u, trim: true)
      |> Enum.reject(&(not Bee.API.setting("wordCount.countNumbers") and &1 =~ ~r/^\d+$/))
      |> length()

    runs = state.runs + 1
    noun = if words == 1, do: "word", else: "words"
    Bee.API.show_message(ctx, :info, "#{words} #{noun} in #{where} (counted #{runs}×)")
    {:ok, %{state | runs: runs}}
  end
end
