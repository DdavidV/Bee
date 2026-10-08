defmodule Bee.Console do
  @moduledoc """
  The Bee Console: an Elixir shell running inside Bee, in a panel tab next
  to the terminals (Developer: Open Bee Console). For looking into Bee and
  driving it – its commands, windows, plugins, memory – in the desktop app
  and the browser alike, over the window's own connection (no port, unlike
  `bin/bee remote`). See `Bee.Console.Helpers` for its helpers.

  To the window it is a terminal: it speaks `Bee.Terminal`'s protocol
  (registered as `{:terminal, id}`, `{:input, data}` / `{:resize, cols,
  rows}` casts, `:scrollback`, output as `{:term_data, …}` on the terminal's
  topic), so the panel and its xterm view work unchanged.

  It edits the line itself (xterm sends keys): cursor keys, Home/End,
  history (↑/↓), Tab completion (`IEx.Autocomplete`), Ctrl+A/E/U/L. An
  incomplete expression continues on the next line. Keys typed while an
  expression runs wait for it. Each one is evaluated
  in a process of its own, with this one as its group leader (its output
  comes here): Ctrl+C kills it. Variables, aliases and imports carry over
  from one to the next.

  It stops with its owner, the window that opened it.
  """
  use GenServer, restart: :temporary

  @scrollback_bytes 256 * 1024
  @history 500
  # IEx.dont_display_result/0: helpers that print return it.
  @silent :"do not show this result in output"

  def start(opts), do: DynamicSupervisor.start_child(Bee.TerminalSup, {__MODULE__, opts})

  def start_link(opts),
    do:
      GenServer.start_link(__MODULE__, opts,
        name: {:via, Registry, {Bee.Registry, {:terminal, Keyword.fetch!(opts, :id)}}}
      )

  ## Server

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    Process.monitor(owner)

    s = %{
      id: Keyword.fetch!(opts, :id),
      owner: owner,
      root: Keyword.fetch!(opts, :root),
      seq: 0,
      scrollback: <<>>,
      cols: 80,
      rows: 24,
      # The line being edited: before and after the cursor.
      left: "",
      right: "",
      # Lines of an expression not complete yet.
      pending: [],
      history: [],
      # Position while browsing history, and the line before browsing.
      browsing: nil,
      counter: 1,
      binding: [],
      env: initial_env(),
      # The running evaluation: {pid, monitor ref}.
      eval: nil,
      # Keys typed while something runs, for after it.
      typeahead: ""
    }

    banner =
      "\e[1;33mBee Console\e[0m – Elixir inside Bee (#{System.version()}). " <>
        "\e[2mhelp() lists Bee's helpers; Ctrl+C interrupts.\e[0m\r\n"

    {:ok, s |> write(banner) |> prompt()}
  end

  # The helpers and IEx's (h/1, i/1…), imported into every expression.
  defp initial_env do
    {_value, _binding, env} =
      "import IEx.Helpers, warn: false; import Bee.Console.Helpers, warn: false"
      |> Code.string_to_quoted!()
      |> Code.eval_quoted_with_env([], Code.env_for_eval(file: "bee_console"))

    env
  end

  @impl true
  def handle_call(:scrollback, _from, s), do: {:reply, {s.scrollback, s.seq}, s}

  @impl true
  def handle_cast({:input, data}, s), do: {:noreply, keys(s, data)}
  def handle_cast({:resize, cols, rows}, s), do: {:noreply, %{s | cols: cols, rows: rows}}

  @impl true
  def handle_info({:io_request, from, reply_as, request}, s) do
    {reply, s} = io_request(request, s)
    send(from, {:io_reply, reply_as, reply})
    {:noreply, s}
  end

  def handle_info({:evaluated, pid, result}, %{eval: {pid, ref}} = s) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{s | eval: nil} |> show(result) |> prompt() |> typed_ahead()}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{eval: {_eval, ref}} = s) do
    message =
      if reason == :killed, do: "interrupted", else: "exited: #{Exception.format_exit(reason)}"

    {:noreply,
     %{s | eval: nil}
     |> write("\e[31m** (#{message})\e[0m\r\n")
     |> prompt()
     |> typed_ahead()}
  end

  def handle_info({:DOWN, _, :process, owner, _}, %{owner: owner} = s), do: {:stop, :normal, s}
  def handle_info(_msg, s), do: {:noreply, s}

  ## Keys

  defp keys(s, ""), do: s

  # Ctrl+C: interrupts what runs (and drops what was typed ahead), else
  # drops the line.
  defp keys(%{eval: {pid, _}} = s, <<3, rest::binary>>) do
    Process.exit(pid, :kill)
    keys(%{s | typeahead: ""}, rest)
  end

  defp keys(s, <<3, rest::binary>>),
    do:
      %{s | left: "", right: "", pending: [], browsing: nil}
      |> write("^C\r\n")
      |> prompt()
      |> keys(rest)

  # While something runs, keys wait for it (up to a Ctrl+C), like a
  # terminal's type-ahead.
  defp keys(%{eval: {_, _}} = s, data) do
    case :binary.split(data, <<3>>) do
      [ahead] -> %{s | typeahead: s.typeahead <> ahead}
      [ahead, rest] -> keys(%{s | typeahead: s.typeahead <> ahead}, <<3, rest::binary>>)
    end
  end

  defp keys(s, <<"\r\n", rest::binary>>), do: s |> enter() |> keys(rest)
  defp keys(s, <<c, rest::binary>>) when c in [?\r, ?\n], do: s |> enter() |> keys(rest)

  defp keys(s, <<c, rest::binary>>) when c in [127, 8], do: s |> backspace() |> keys(rest)
  defp keys(s, <<"\e[3~", rest::binary>>), do: s |> delete() |> keys(rest)
  defp keys(s, <<"\e[A", rest::binary>>), do: s |> history(+1) |> keys(rest)
  defp keys(s, <<"\e[B", rest::binary>>), do: s |> history(-1) |> keys(rest)
  defp keys(s, <<"\e[C", rest::binary>>), do: s |> right() |> keys(rest)
  defp keys(s, <<"\e[D", rest::binary>>), do: s |> left() |> keys(rest)

  defp keys(s, <<home::binary-size(3), rest::binary>>) when home in ["\e[H", "\eOH"],
    do: s |> home() |> keys(rest)

  defp keys(s, <<"\e[1~", rest::binary>>), do: s |> home() |> keys(rest)

  defp keys(s, <<end_::binary-size(3), rest::binary>>) when end_ in ["\e[F", "\eOF"],
    do: s |> end_of_line() |> keys(rest)

  defp keys(s, <<"\e[4~", rest::binary>>), do: s |> end_of_line() |> keys(rest)
  defp keys(s, <<1, rest::binary>>), do: s |> home() |> keys(rest)
  defp keys(s, <<5, rest::binary>>), do: s |> end_of_line() |> keys(rest)
  defp keys(s, <<21, rest::binary>>), do: %{s | left: "", right: ""} |> redraw() |> keys(rest)

  # Ctrl+L (and Clear Bee Console): the screen and the scrollback go.
  defp keys(s, <<12, rest::binary>>),
    do: %{s | scrollback: ""} |> write("\e[2J\e[3J\e[H") |> redraw() |> keys(rest)

  defp keys(s, <<?\t, rest::binary>>), do: s |> complete() |> keys(rest)

  # Other escape sequences (F-keys…) do nothing.
  defp keys(s, <<"\e[", rest::binary>>), do: keys(s, skip_sequence(rest))
  defp keys(s, <<"\e", rest::binary>>), do: keys(s, rest)
  defp keys(s, <<c, rest::binary>>) when c < 32, do: keys(s, rest)

  # Text, as much as there is up to the next control key (pasting).
  defp keys(s, data) do
    {text, rest} = take_text(data, "")
    s = %{s | left: s.left <> text, browsing: nil}
    s = if s.right == "", do: write(s, text), else: redraw(s)
    keys(s, rest)
  end

  defp typed_ahead(%{typeahead: ""} = s), do: s
  defp typed_ahead(s), do: keys(%{s | typeahead: ""}, s.typeahead)

  defp take_text(<<c, _::binary>> = rest, acc) when c < 32 or c == 127, do: {acc, rest}
  defp take_text(<<c::utf8, rest::binary>>, acc), do: take_text(rest, <<acc::binary, c::utf8>>)
  # Not UTF-8: dropped.
  defp take_text(<<_, rest::binary>>, acc), do: take_text(rest, acc)
  defp take_text("", acc), do: {acc, ""}

  defp skip_sequence(<<c, rest::binary>>) when c in ?@..?~, do: rest
  defp skip_sequence(<<_, rest::binary>>), do: skip_sequence(rest)
  defp skip_sequence(""), do: ""

  defp backspace(%{left: ""} = s), do: s

  defp backspace(s),
    do: redraw(%{s | left: String.slice(s.left, 0..-2//1), browsing: nil})

  defp delete(%{right: ""} = s), do: s
  defp delete(s), do: redraw(%{s | right: String.slice(s.right, 1..-1//1)})

  defp left(%{left: ""} = s), do: s

  defp left(s) do
    {before, last} = String.split_at(s.left, -1)
    write(%{s | left: before, right: last <> s.right}, "\e[D")
  end

  defp right(%{right: ""} = s), do: s

  defp right(s) do
    {first, rest} = String.split_at(s.right, 1)
    write(%{s | left: s.left <> first, right: rest}, "\e[C")
  end

  defp home(s), do: redraw(%{s | left: "", right: s.left <> s.right})
  defp end_of_line(s), do: redraw(%{s | left: s.left <> s.right, right: ""})

  # ↑ (+1) older, ↓ (-1) newer; past the newest, the line from before.
  defp history(s, step) do
    {pos, current} = s.browsing || {-1, s.left <> s.right}
    pos = pos + step

    cond do
      pos >= length(s.history) ->
        s

      pos < 0 ->
        redraw(%{s | left: current, right: "", browsing: nil})

      true ->
        redraw(%{s | left: Enum.at(s.history, pos), right: "", browsing: {pos, current}})
    end
  end

  defp complete(s) do
    case IEx.Autocomplete.expand(s.left |> String.to_charlist() |> Enum.reverse(), nil) do
      {:yes, hint, []} ->
        redraw(%{s | left: s.left <> List.to_string(hint)})

      {:yes, hint, entries} ->
        s = %{s | left: s.left <> List.to_string(hint)}
        list = Enum.map_join(entries, "  ", &List.to_string/1)
        s |> write("\r\n" <> list <> "\r\n") |> redraw()

      {:no, _, _} ->
        s
    end
  rescue
    _ -> s
  end

  # The prompt and the line, the cursor where it is.
  defp redraw(s) do
    back = String.length(s.right)
    move = if back > 0, do: "\e[#{back}D", else: ""
    write(s, "\r\e[K" <> prompt_text(s) <> s.left <> s.right <> move)
  end

  defp prompt(s), do: write(%{s | left: "", right: "", browsing: nil}, prompt_text(s))

  defp prompt_text(%{pending: []} = s), do: "\e[33mbee(#{s.counter})>\e[0m "
  defp prompt_text(s), do: "\e[33m...(#{s.counter})>\e[0m "

  ## Evaluating

  defp enter(s) do
    line = s.left <> s.right
    s = write(%{s | browsing: nil}, "\r\n")

    s =
      if String.trim(line) != "" and List.first(s.history) != line,
        do: %{s | history: Enum.take([line | s.history], @history)},
        else: s

    code = Enum.join(Enum.reverse([line | s.pending]), "\n")

    cond do
      String.trim(code) == "" ->
        prompt(%{s | pending: []})

      incomplete?(code) ->
        prompt(%{s | pending: [line | s.pending]})

      true ->
        evaluate(%{s | pending: []}, code)
    end
  end

  defp incomplete?(code) do
    Code.string_to_quoted!(code)
    false
  rescue
    TokenMissingError -> true
    _ -> false
  end

  defp evaluate(s, code) do
    me = self()
    %{binding: binding, env: env, owner: window, root: root} = s
    env = %{env | line: s.counter}

    {pid, ref} =
      spawn_monitor(fn ->
        Process.group_leader(self(), me)
        # For Bee.Console.Helpers.
        Process.put(:bee_console, %{window: window, root: root})

        result =
          try do
            {value, binding, env} =
              code
              |> Code.string_to_quoted!(file: "bee_console", line: env.line)
              |> Code.eval_quoted_with_env(binding, env)

            {:ok, value, binding, env}
          catch
            kind, reason -> {:error, kind, reason, __STACKTRACE__}
          end

        send(me, {:evaluated, self(), result})
      end)

    %{s | eval: {pid, ref}}
  end

  defp show(s, {:ok, value, binding, env}) do
    s = %{s | binding: binding, env: env, counter: s.counter + 1}
    if value == @silent, do: s, else: write(s, text(inspect_value(value, s.cols)) <> "\r\n")
  end

  defp show(s, {:error, kind, reason, stacktrace}) do
    message = Exception.format(kind, reason, prune(stacktrace))

    write(
      %{s | counter: s.counter + 1},
      "\e[31m" <> text(String.trim_trailing(message)) <> "\e[0m\r\n"
    )
  end

  # The console's own frames say nothing about the error.
  defp prune(stacktrace) do
    Enum.take_while(stacktrace, fn {module, _, _, _} ->
      module not in [__MODULE__, :elixir_eval, :elixir, Code, :erl_eval]
    end)
  end

  defp inspect_value(value, cols) do
    inspect(value,
      pretty: true,
      width: max(cols - 2, 20),
      limit: 200,
      syntax_colors: [
        atom: :cyan,
        string: :green,
        number: :yellow,
        boolean: :magenta,
        nil: :magenta,
        regex: :light_red
      ]
    )
  end

  ## Output (we are the group leader of what we evaluate)

  defp io_request({:put_chars, _encoding, chars}, s), do: {:ok, write(s, text(chars))}
  defp io_request({:put_chars, chars}, s), do: {:ok, write(s, text(chars))}

  defp io_request({:put_chars, _encoding, m, f, a}, s),
    do: {:ok, write(s, text(apply(m, f, a)))}

  defp io_request({:put_chars, m, f, a}, s), do: {:ok, write(s, text(apply(m, f, a)))}
  defp io_request({:get_geometry, :columns}, s), do: {s.cols, s}
  defp io_request({:get_geometry, :rows}, s), do: {s.rows, s}
  defp io_request(:getopts, s), do: {[binary: true, encoding: :unicode], s}
  defp io_request({:setopts, _opts}, s), do: {:ok, s}

  defp io_request({:requests, requests}, s) do
    Enum.reduce(requests, {:ok, s}, fn request, {_reply, s} -> io_request(request, s) end)
  end

  # Reading input (IO.gets) isn't supported.
  defp io_request(_other, s), do: {{:error, :enotsup}, s}

  # Terminal text: lines end in \r\n.
  defp text(chars) do
    chars |> IO.chardata_to_string() |> String.replace(~r/\r?\n/, "\r\n")
  end

  defp write(s, data) do
    seq = s.seq + 1
    Phoenix.PubSub.broadcast(Bee.PubSub, Bee.Terminal.topic(s.id), {:term_data, s.id, seq, data})
    %{s | seq: seq, scrollback: trim(s.scrollback <> data)}
  end

  defp trim(buf) when byte_size(buf) > @scrollback_bytes,
    do: binary_part(buf, byte_size(buf) - @scrollback_bytes, @scrollback_bytes)

  defp trim(buf), do: buf
end
