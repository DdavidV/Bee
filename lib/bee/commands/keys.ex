defmodule Bee.Commands.Keys do
  @moduledoc """
  VS Code key strings: `"ctrl+shift+p"`, chords separated by a space
  (`"ctrl+k ctrl+s"`), case-insensitive, with modifier aliases
  (`cmd`/`win`/`super`/`meta`, `control`, `option`).

  `parse/1` normalizes to a list of strokes, each `"ctrl+shift+alt+meta+key"`
  with modifiers in that order. `assets/js/commands/keys.js` builds the same form from
  `KeyboardEvent.code` (physical keys, so bindings work on any layout).

  VS Code's other spellings are understood too: its Windows names
  (`oem_1`, `oem_plus`…), the numpad's (`numpad_add`; `numpad0`–`numpad9`
  are the digits) and scan codes (`[KeyA]`, `[BracketLeft]`), which name
  the physical keys Bee binds anyway.
  """

  @modifiers ~w(ctrl shift alt meta)
  @modifier_aliases %{
    "ctrl" => "ctrl",
    "control" => "ctrl",
    "shift" => "shift",
    "alt" => "alt",
    "option" => "alt",
    "meta" => "meta",
    "cmd" => "meta",
    "win" => "meta",
    "super" => "meta"
  }

  @key_aliases %{
    "esc" => "escape",
    "return" => "enter",
    "del" => "delete",
    "ins" => "insert",
    "arrowup" => "up",
    "arrowdown" => "down",
    "arrowleft" => "left",
    "arrowright" => "right",
    "backtick" => "`",
    "plus" => "=",
    "pause" => "pausebreak",
    "oem_1" => ";",
    "oem_plus" => "=",
    "oem_comma" => ",",
    "oem_minus" => "-",
    "oem_period" => ".",
    "oem_2" => "/",
    "oem_3" => "`",
    "oem_4" => "[",
    "oem_5" => "\\",
    "oem_6" => "]",
    "oem_7" => "'",
    "oem_102" => "intlbackslash",
    "numpad_comma" => "numpad_separator"
  }

  # Scan codes ("[KeyA]", lowercased): KeyboardEvent.code → the key, as in
  # assets/js/commands/keys.js.
  @codes %{
    "escape" => "escape",
    "enter" => "enter",
    "numpadenter" => "enter",
    "tab" => "tab",
    "space" => "space",
    "backspace" => "backspace",
    "delete" => "delete",
    "insert" => "insert",
    "arrowup" => "up",
    "arrowdown" => "down",
    "arrowleft" => "left",
    "arrowright" => "right",
    "home" => "home",
    "end" => "end",
    "pageup" => "pageup",
    "pagedown" => "pagedown",
    "backquote" => "`",
    "minus" => "-",
    "equal" => "=",
    "bracketleft" => "[",
    "bracketright" => "]",
    "backslash" => "\\",
    "semicolon" => ";",
    "quote" => "'",
    "comma" => ",",
    "period" => ".",
    "slash" => "/",
    "intlbackslash" => "intlbackslash",
    "pause" => "pausebreak",
    "capslock" => "capslock",
    "contextmenu" => "contextmenu",
    "numlock" => "numlock",
    "scrolllock" => "scrolllock",
    "numpadmultiply" => "numpad_multiply",
    "numpadadd" => "numpad_add",
    "numpadsubtract" => "numpad_subtract",
    "numpaddecimal" => "numpad_decimal",
    "numpaddivide" => "numpad_divide",
    "numpadcomma" => "numpad_separator"
  }

  @named ~w(escape enter tab space backspace delete insert up down left right home end pageup pagedown) ++
           ~w(pausebreak capslock contextmenu numlock scrolllock intlbackslash) ++
           ~w(numpad_multiply numpad_add numpad_separator numpad_subtract numpad_decimal numpad_divide) ++
           Enum.map(1..24, &"f#{&1}")
  @punctuation ~w(` - = [ ] \\ ; ' , . /)
  @chars Enum.map(?a..?z, &<<&1>>) ++ Enum.map(?0..?9, &<<&1>>)

  @keys MapSet.new(@named ++ @punctuation ++ @chars)

  @spec parse(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def parse(source) when is_binary(source) do
    source
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> case do
      [] ->
        {:error, "empty key"}

      strokes ->
        Enum.reduce_while(strokes, {:ok, []}, fn stroke, {:ok, acc} ->
          case parse_stroke(stroke) do
            {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
            {:error, reason} -> {:halt, {:error, "#{reason} in #{inspect(source)}"}}
          end
        end)
    end
  end

  def parse(other), do: {:error, "key must be a string, got #{inspect(other)}"}

  # "+" itself can't be a key here ("ctrl++" is ambiguous); VS Code spells it "=" with shift.
  defp parse_stroke(stroke) do
    parts = String.split(stroke, "+")
    {mods, [key]} = Enum.split(parts, -1)
    key = key_name(key)

    with {:ok, mods} <- parse_modifiers(mods),
         true <- MapSet.member?(@keys, key) || {:error, "unknown key #{inspect(key)}"} do
      ordered = Enum.filter(@modifiers, &(&1 in mods))
      {:ok, Enum.join(ordered ++ [key], "+")}
    end
  end

  defp key_name("[" <> _ = code) do
    code = code |> String.trim_leading("[") |> String.trim_trailing("]")

    case code do
      "key" <> <<letter>> when letter in ?a..?z -> <<letter>>
      "digit" <> <<digit>> when digit in ?0..?9 -> <<digit>>
      "numpad" <> <<digit>> when digit in ?0..?9 -> <<digit>>
      "f" <> _ = function -> function
      _ -> Map.get(@codes, code, "[" <> code <> "]")
    end
  end

  defp key_name("numpad" <> <<digit>>) when digit in ?0..?9, do: <<digit>>
  defp key_name(key), do: Map.get(@key_aliases, key, key)

  defp parse_modifiers(mods) do
    Enum.reduce_while(mods, {:ok, []}, fn mod, {:ok, acc} ->
      case @modifier_aliases[mod] do
        nil -> {:halt, {:error, "unknown modifier #{inspect(mod)}"}}
        m -> {:cont, {:ok, [m | acc]}}
      end
    end)
  end

  @doc ~S'Human label, e.g. `["ctrl+k", "ctrl+s"]` → `"Ctrl+K Ctrl+S"`.'
  def label(strokes) when is_list(strokes), do: Enum.map_join(strokes, " ", &label_stroke/1)

  defp label_stroke(stroke) do
    stroke
    |> String.split("+")
    |> Enum.map_join("+", fn
      "ctrl" -> "Ctrl"
      "shift" -> "Shift"
      "alt" -> "Alt"
      "meta" -> "Meta"
      "pageup" -> "PageUp"
      "pagedown" -> "PageDown"
      key -> String.capitalize(key)
    end)
  end
end
