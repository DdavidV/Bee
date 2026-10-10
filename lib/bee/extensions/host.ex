defmodule Bee.Extensions.Host do
  @moduledoc """
  Runs the code of VS Code extensions for one workspace, like VS Code's
  extension host per window: a Node.js process (`priv/extension_host`)
  that loads each extension's `main` with Bee's `vscode` module, and this
  process, which owns it and is its link to Bee. One per open workspace
  with an active extension, under `Bee.Extensions.HostSup`, registered as
  `{:extension_host, root}` in `Bee.Registry`. Started by
  `Bee.Plugins.Manager` when the first extension activates there.

  The two talk over the port's stdin/stdout: JSON messages, each after its
  length, requests (`id`, `method`, `params`) answered by `result` or
  `error`, and notifications (no `id`). See `priv/extension_host/main.js`.

  To the extensions this process is the workspace:

    * settings – `Bee.Settings.all/1`, sent at the start and when they change
    * documents – the text of the open buffers under the root, sent as it
      changes (the `vscode` API reads text without waiting)
    * the active editor and its selections – of the window that last ran a
      command or reported its editor (`active_editor/4`)

    * files changing on disk – while an extension watches files
      (`createFileSystemWatcher`), the workspace's `{:fs_changed, path}`

  and it carries out what they ask: messages, quick picks and input boxes
  in a window (answered with `{:bee_answer, ref, value}`, see `ask/5`),
  edits of open files, settings, context keys, status bar items, Bee's own
  commands. Their language features answer the editor through
  `Bee.Languages.Features`, which also knows what they registered; the
  diagnostics they find go to `Bee.Diagnostics`, edits of several files (`workspace.applyEdit`) to the
  open buffers and to disk. Their webview panels are the workspace's
  `Bee.Webviews`, shown by its windows. What they write to output channels, and what
  they print, is the workspace's `Bee.Output`. Offsets are UTF-16 code units on Node's side, UTF-8 bytes on
  Bee's (`to_utf16/2`, `to_bytes/2`).

  The manager is told `{:extension_activated, name, root}`,
  `{:extension_failed, name, root, message}` and `{:extension_warning,
  name, root, message}` (an API Bee doesn't have was used). When Node
  exits, this process stops with `{:shutdown, {:node_exited, status}}`.
  """
  use GenServer, restart: :temporary
  require Logger

  alias Bee.Editor.Buffer
  alias Bee.Plugins.Context

  @commands Bee.Extensions.Commands
  @activation_timeout 30_000
  @log_lines 500

  def start_link(root), do: GenServer.start_link(__MODULE__, root, name: via(root))

  defp via(root), do: {:via, Registry, {Bee.Registry, {:extension_host, root}}}

  def whereis(root) do
    case Registry.lookup(Bee.Registry, {:extension_host, root}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "The Node.js executable of workspace `root`'s hosts (`extensions.nodePath`), or nil."
  def node_path(root \\ nil) do
    setting = Bee.Settings.get("extensions.nodePath", root)
    System.find_executable(if(is_binary(setting) and setting != "", do: setting, else: "node"))
  end

  @doc "The table of the commands extensions registered: `{{root, id}, plugin_name}`."
  def create_commands_table do
    if :ets.whereis(@commands) == :undefined,
      do: :ets.new(@commands, [:named_table, :public, read_concurrency: true])

    :ok
  end

  @doc """
  The extension that registered command `id` in workspace `root`, or nil:
  the commands of its manifest once it is active, and those it registers
  without declaring them.
  """
  def command(root, id) do
    case :ets.lookup(@commands, {root, id}) do
      [{_, name}] -> name
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Activates the extension of `plugin` (a `Bee.Plugins` record) – asynchronously."
  def activate(pid, plugin), do: GenServer.cast(pid, {:activate, plugin})

  def deactivate(pid, name), do: GenServer.cast(pid, {:deactivate, name})

  @doc """
  Runs command `id` of extension `name` with `ctx` (its `args`, window,
  active editor and selections) – asynchronously, once the extension is
  active; a failure is shown in the window.
  """
  def execute(pid, name, id, %Context{} = ctx), do: GenServer.cast(pid, {:execute, name, id, ctx})

  @doc """
  `window`'s active editor is the file `path` (nil: none) with `selections`
  (`[{from, to}]`, byte offsets): what the extensions of workspace `root`
  see as the active editor, if they run.
  """
  def active_editor(root, window, path, selections) do
    case whereis(root) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:active_editor, window, path, selections})
    end
  end

  @doc """
  What a window has to say about webview panel `id` of workspace `root`
  (`Bee.Webviews`): `{:message, data}` its page posted, `{:state, active?,
  visible?}` of its tab, or `:closed`.
  """
  def webview(root, id, event) do
    case whereis(root) do
      # No host: nobody to tell, and the panel is nobody's.
      nil -> if event == :closed, do: Bee.Webviews.dispose(root, id), else: :ok
      pid -> GenServer.cast(pid, {:webview, id, event})
    end
  end

  @doc "The last lines extensions logged in workspace `root`, oldest first."
  def log(root) do
    case whereis(root) do
      nil -> []
      pid -> GenServer.call(pid, :log)
    end
  end

  ## Offsets

  @doc "UTF-8 byte offset `offset` into `text` as a UTF-16 one."
  def to_utf16(text, offset) do
    prefix = binary_part(text, 0, min(max(offset, 0), byte_size(text)))
    div(byte_size(:unicode.characters_to_binary(prefix, :utf8, {:utf16, :little})), 2)
  end

  @doc """
  A `%{"line" => l, "character" => c}` position (zero-based, UTF-16 units)
  in `text` as a UTF-8 byte offset; past a line's end: its end.
  """
  def position_to_bytes(text, %{"line" => line, "character" => character})
      when is_integer(line) and is_integer(character) do
    {start, line_text} = line_at(text, max(line, 0), 0)
    start + to_bytes(line_text, character)
  end

  @doc "UTF-8 byte offset `offset` into `text` as a `%{line, character}` position (UTF-16 units)."
  def bytes_to_position(text, offset) do
    before = binary_part(text, 0, min(max(offset, 0), byte_size(text)))
    lines = :binary.split(before, "\n", [:global])
    %{line: length(lines) - 1, character: to_utf16(List.last(lines), byte_size(List.last(lines)))}
  end

  # `{byte offset of its start, its text without the line break}`.
  defp line_at(text, 0, start) do
    line =
      case :binary.match(text, "\n") do
        {index, 1} -> binary_part(text, 0, index)
        :nomatch -> text
      end

    {start, String.trim_trailing(line, "\r")}
  end

  defp line_at(text, n, start) do
    case :binary.match(text, "\n") do
      {index, 1} ->
        rest = binary_part(text, index + 1, byte_size(text) - index - 1)
        line_at(rest, n - 1, start + index + 1)

      # Past the last line: its end.
      :nomatch ->
        {start + byte_size(text), ""}
    end
  end

  @doc "UTF-16 offset `offset` into `text` as a UTF-8 byte one."
  def to_bytes(text, offset) do
    utf16 = :unicode.characters_to_binary(text, :utf8, {:utf16, :little})
    prefix = binary_part(utf16, 0, min(max(offset, 0) * 2, byte_size(utf16)))

    case :unicode.characters_to_binary(prefix, {:utf16, :little}, :utf8) do
      bytes when is_binary(bytes) -> byte_size(bytes)
      # Inside a surrogate pair: before it.
      {:incomplete, bytes, _rest} -> byte_size(bytes)
      {:error, bytes, _rest} -> byte_size(bytes)
    end
  end

  ## Server

  @impl true
  def init(root) do
    Process.flag(:trap_exit, true)
    Logger.metadata(workspace: root)

    case File.dir?(root) && node_path(root) do
      false ->
        {:stop, {:shutdown, :no_folder}}

      nil ->
        {:stop, {:shutdown, :no_node}}

      node ->
        port =
          Port.open({:spawn_executable, node}, [
            :binary,
            :exit_status,
            {:packet, 4},
            {:args, [Path.join([:code.priv_dir(:bee), "extension_host", "main.js"])]},
            {:cd, root}
          ])

        Buffer.subscribe()
        Bee.Settings.subscribe()

        s = %{
          root: root,
          port: port,
          os_pid: port |> Port.info(:os_pid) |> elem(1),
          next_id: 1,
          # Our requests Node hasn't answered: id => what it was.
          pending: %{},
          # name => %{status: :activating | :active, plugin, deferred: [fun]}
          extensions: %{},
          # The window of the last command, for what extensions show.
          window: nil,
          # Questions windows haven't answered: ref => Node's request id.
          asks: %{},
          # What Node has of each open document (a hash of its text).
          documents: %{},
          # Whether an extension watches files (we send their changes then).
          watching?: false,
          # Language features being asked for: ref => our request's id.
          provides: %{},
          log: :queue.new()
        }

        {:ok, request(s, "initialize", initial(root), :initialize)}
    end
  end

  defp initial(root) do
    %{
      root: root,
      settings: Bee.Settings.all(root),
      defaults: Bee.Settings.defaults(),
      documents: for({path, text} <- open_buffers(root), do: document(path, text)),
      editor: nil
    }
  end

  # The open files under `root` with their text.
  defp open_buffers(root) do
    for path <-
          Registry.select(Bee.Registry, [{{{:buffer, :"$1"}, :_, :_}, [], [:"$1"]}]),
        inside?(path, root),
        text = Bee.API.text(path),
        is_binary(text),
        do: {path, text}
  end

  defp document(path, text, version \\ nil) do
    %{path: path, text: text, languageId: Bee.Languages.detect(path), version: version}
  end

  @impl true
  def handle_call(:log, _from, s), do: {:reply, :queue.to_list(s.log), s}

  @impl true
  def handle_cast({:activate, plugin}, s) do
    if Map.has_key?(s.extensions, plugin.name) do
      {:noreply, s}
    else
      {:noreply, start_extension(s, plugin)}
    end
  end

  def handle_cast({:deactivate, name}, s) do
    case Map.pop(s.extensions, name) do
      {nil, _} ->
        {:noreply, s}

      {extension, extensions} ->
        Enum.each(extension.deferred, & &1.({:error, "the extension was deactivated"}))
        forget_commands(s.root, name)
        Bee.Diagnostics.clear(s.root, name <> "/")
        {:noreply, request(%{s | extensions: extensions}, "deactivate", %{name: name}, :ignore)}
    end
  end

  def handle_cast({:execute, name, id, ctx}, s) do
    s = watch_window(s, ctx.window)

    run = fn
      {:ok, s} ->
        {document, editor, s} = editor_state(s, ctx.active_editor, ctx.selections)

        request(
          s,
          "executeCommand",
          %{command: id, args: ctx.args, document: document, editor: editor},
          {:execute, id, ctx.window}
        )

      {:error, message} ->
        Bee.API.show_message(context(s, ctx.window), :error, message)
        s
    end

    case s.extensions[name] do
      %{status: :active} ->
        {:noreply, run.({:ok, s})}

      # Its code is still starting: the command runs when it has.
      %{status: :activating} = extension ->
        {:noreply,
         put_in(s.extensions[name], %{extension | deferred: [run | extension.deferred]})}

      nil ->
        {:noreply, run.({:error, "#{command_label(id)}: the #{name} extension isn't active"})}
    end
  end

  # A language feature for an editor (Bee.Languages.Features): about the
  # text the buffer has now, which Node gets first if it hasn't.
  def handle_cast({:provide, feature, path, params, {pid, ref}}, s) do
    open? = is_binary(path) and Registry.lookup(Bee.Registry, {:buffer, path}) != []
    text = open? && inside?(path, s.root) && Bee.API.text(path)

    cond do
      # Details of a completion already given, the workspace's symbols:
      # not about the text.
      is_binary(text) or
          feature in ~w(completionResolve completionAccept workspaceSymbol codeActionApply) ->
        s = sync_document(s, path, text)
        id = s.next_id
        params = Map.merge(params, %{feature: feature, path: path, key: id})

        {:noreply,
         request(%{s | provides: Map.put(s.provides, ref, id)}, "provide", params, {
           :provide,
           pid,
           ref
         })}

      true ->
        send(pid, {:language_reply, ref, {:ok, nil}})
        {:noreply, s}
    end
  end

  def handle_cast({:webview, id, {:message, message}}, s),
    do: {:noreply, notify(s, "webviewMessage", %{id: id, message: message})}

  def handle_cast({:webview, id, {:state, active?, visible?}}, s),
    do: {:noreply, notify(s, "webviewState", %{id: id, active: active?, visible: visible?})}

  # Its panel disposes of itself (`webviewDispose` follows).
  def handle_cast({:webview, id, :closed}, s),
    do: {:noreply, notify(s, "webviewClosed", %{id: id})}

  def handle_cast({:cancel_provide, ref}, s) do
    case s.provides[ref] do
      nil -> {:noreply, s}
      id -> {:noreply, notify(s, "cancel", %{key: id})}
    end
  end

  def handle_cast({:active_editor, window, path, selections}, s) do
    s = watch_window(s, window)
    {document, editor, s} = editor_state(s, path, selections)
    {:noreply, notify(s, "activeEditor", %{document: document, editor: editor})}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = s) do
    case Jason.decode(data) do
      {:ok, message} ->
        {:noreply, from_node(message, s)}

      {:error, _} ->
        Logger.warning("Bee: the extension host sent what isn't JSON")
        {:noreply, s}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = s),
    do: {:stop, {:shutdown, {:node_exited, status}}, %{s | port: nil}}

  def handle_info({:EXIT, port, reason}, %{port: port} = s),
    do: {:stop, {:shutdown, {:node_exited, reason}}, %{s | port: nil}}

  def handle_info({:EXIT, _pid, _reason}, s), do: {:noreply, s}

  # A window answered a question (see ask/5).
  def handle_info({:bee_answer, ref, value}, s) do
    case Map.pop(s.asks, ref) do
      {nil, _} ->
        {:noreply, s}

      {{id, broadcast?}, asks} ->
        # Asked in every window: the others close theirs.
        if broadcast?, do: to_window(%{s | window: nil}, {:ask_done, ref})
        {:noreply, reply(%{s | asks: asks}, id, value)}
    end
  end

  def handle_info({:activation_timeout, name, id}, s) do
    case s.pending[id] do
      {:activate, ^name} ->
        s = %{s | pending: Map.delete(s.pending, id)}

        {:noreply,
         activation_failed(
           s,
           name,
           "didn't finish activating in #{div(@activation_timeout, 1000)}s"
         )}

      _ ->
        {:noreply, s}
    end
  end

  # The window we show things in is gone: its questions have no answer.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{window: {pid, _}} = s) do
    s = Enum.reduce(s.asks, s, fn {_ref, {id, _}}, s -> reply(s, id, nil) end)
    {:noreply, %{s | window: nil, asks: %{}}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, s), do: {:noreply, s}

  def handle_info({:settings_changed, scope}, %{root: root} = s)
      when scope == :user or scope == {:workspace, root},
      do: {:noreply, notify(s, "settings", %{settings: Bee.Settings.all(root)})}

  def handle_info({:buffer_opened, path, text}, s), do: {:noreply, sync_document(s, path, text)}

  def handle_info({:buffer_changed, path, _version, text}, s),
    do: {:noreply, sync_document(s, path, text)}

  def handle_info({:buffer_reloaded, path, text}, s), do: {:noreply, sync_document(s, path, text)}

  def handle_info({:buffer_saved, path, text}, s) do
    if inside?(path, s.root),
      do: {:noreply, s |> sync_document(path, text) |> notify("documentSaved", %{path: path})},
      else: {:noreply, s}
  end

  def handle_info({:buffer_closed, path}, s) do
    if Map.has_key?(s.documents, path),
      do:
        {:noreply,
         notify(%{s | documents: Map.delete(s.documents, path)}, "documentClosed", %{path: path})},
      else: {:noreply, s}
  end

  # A file changed on disk, for the extensions' file system watchers. Not
  # what the workspace hides (build output…), which changes a lot.
  def handle_info({:fs_changed, path}, %{watching?: true} = s) do
    if inside?(path, s.root) and not excluded?(path, s.root),
      do: {:noreply, notify(s, "fileChanged", %{path: path})},
      else: {:noreply, s}
  end

  def handle_info(_message, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s) do
    for {name, _} <- s.extensions, do: forget_commands(s.root, name)
    Bee.Diagnostics.clear(s.root)
    Bee.Languages.Features.put(s.root, [])
    Bee.Webviews.clear(s.root)

    for {_id, {:provide, pid, ref}} <- s.pending,
        do: send(pid, {:language_reply, ref, {:ok, nil}})

    if s.port do
      # Closing its stdin ends Node; one that hangs is killed.
      os_pid = s.os_pid
      catch_port_close(s.port)

      Task.Supervisor.start_child(Bee.Plugins.TaskSup, fn ->
        Process.sleep(2_000)
        System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true, cd: "/")
      end)
    end

    :ok
  catch
    _, _ -> :ok
  end

  defp catch_port_close(port) do
    Port.close(port)
  catch
    _, _ -> :ok
  end

  ## Extensions

  defp start_extension(s, plugin) do
    with {:ok, text} <- File.read(Path.join(plugin.dir, "package.json")),
         {:ok, %{} = package} <- Bee.JSON.JSONC.decode(text),
         %{"main" => main} <- plugin.manifest["extension"] do
      state = Path.join([Bee.Settings.user_dir(), "extension-state", plugin.name])
      workspace = Base.url_encode64(:crypto.hash(:sha, s.root), padding: false)

      params = %{
        name: plugin.name,
        dir: plugin.dir,
        main: main,
        packageJSON: package,
        globalStorage: state,
        storage: Path.join([state, "workspaces", workspace])
      }

      id = s.next_id
      Process.send_after(self(), {:activation_timeout, plugin.name, id}, @activation_timeout)

      s
      |> put_in([:extensions, plugin.name], %{status: :activating, deferred: []})
      |> request("activate", params, {:activate, plugin.name})
    else
      _ ->
        manager({:extension_failed, plugin.name, s.root, "its package.json can't be read"})
        s
    end
  end

  defp activation_failed(s, name, message) do
    case Map.pop(s.extensions, name) do
      {nil, _} ->
        s

      {extension, extensions} ->
        Enum.each(extension.deferred, & &1.({:error, "#{name} failed to activate: #{message}"}))
        forget_commands(s.root, name)

        Bee.Output.append_line(
          s.root,
          Bee.Output.host_channel(),
          "#{name} failed to activate: #{message}"
        )

        manager({:extension_failed, name, s.root, message})
        %{s | extensions: extensions}
    end
  end

  defp forget_commands(root, name), do: :ets.match_delete(@commands, {{root, :_}, name})

  ## Messages from Node

  # An answer to one of our requests.
  defp from_node(%{"id" => id} = message, s) when not is_map_key(message, "method") do
    case Map.pop(s.pending, id) do
      {nil, _} -> s
      {what, pending} -> answered(what, message, %{s | pending: pending})
    end
  end

  defp from_node(%{"id" => id, "method" => method} = message, s) do
    handle_request(method, message["params"] || %{}, id, s)
  rescue
    e -> reply_error(s, id, Exception.message(e))
  end

  defp from_node(%{"method" => method} = message, s) do
    handle_notification(method, message["params"] || %{}, s)
  rescue
    e ->
      Logger.warning("Bee: extension host #{method}: #{Exception.message(e)}")
      s
  end

  defp from_node(_other, s), do: s

  defp answered(:initialize, %{"result" => %{"node" => version}}, s) do
    Logger.info("Bee: extension host for #{s.root} runs on Node.js #{version}")
    s
  end

  defp answered({:activate, name}, %{"error" => error}, s),
    do: activation_failed(s, name, error_message(error))

  defp answered({:activate, name}, _result, s) do
    case s.extensions[name] do
      nil ->
        s

      extension ->
        manager({:extension_activated, name, s.root})
        s = put_in(s.extensions[name], %{extension | status: :active, deferred: []})
        Enum.reduce(Enum.reverse(extension.deferred), s, fn fun, s -> fun.({:ok, s}) end)
    end
  end

  defp answered({:execute, id, window}, %{"error" => error}, s) do
    message = "#{command_label(id)}: #{error_message(error)}"
    Logger.warning("Bee: extension command #{message}")

    Bee.Output.append_line(
      s.root,
      Bee.Output.host_channel(),
      "command #{id} failed: #{error["stack"] || error_message(error)}"
    )

    Bee.API.show_message(context(s, window), :error, message)
    s
  end

  defp answered({:provide, pid, ref}, message, s) do
    result =
      case message do
        %{"error" => error} -> {:error, error_message(error)}
        _ -> {:ok, message["result"]}
      end

    send(pid, {:language_reply, ref, result})
    %{s | provides: Map.delete(s.provides, ref)}
  end

  # A command run for another extension (or Bee): its answer goes back.
  defp answered({:forward, id}, %{"error" => error}, s),
    do: reply_error(s, id, error_message(error))

  defp answered({:forward, id}, %{"result" => result}, s), do: reply(s, id, result)
  defp answered(_what, _message, s), do: s

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(other), do: inspect(other)

  defp command_label(id) do
    case Bee.Commands.Registry.command(id) do
      nil -> id
      command -> Bee.Commands.Registry.label(command)
    end
  end

  ## Requests of extensions

  defp handle_request("showMessage", %{"text" => text} = params, id, s) do
    case params["items"] do
      [_ | _] = items ->
        ask(s, id, :pick, %{
          placeholder: text,
          items: for({label, index} <- Enum.with_index(items), do: %{label: label, value: index})
        })

      _ ->
        level = if params["level"] == "info", do: :info, else: :error
        Bee.API.show_message(context(s), level, text)
        reply(s, id, nil)
    end
  end

  defp handle_request("showQuickPick", params, id, s) do
    items =
      for {item, index} <- Enum.with_index(params["items"] || []) do
        %{label: item["label"] || "", description: item["description"] || "", value: index}
      end

    ask(s, id, :pick, %{placeholder: params["placeholder"] || "", items: items})
  end

  defp handle_request("showInputBox", params, id, s) do
    ask(s, id, :input, %{
      prompt: params["prompt"] || "",
      placeholder: params["placeholder"] || "",
      value: params["value"] || ""
    })
  end

  # Edits of an open file, in Node's offsets into the text it has.
  defp handle_request("applyEdit", %{"path" => path, "edits" => edits}, id, s) do
    with true <- inside?(path, s.root),
         text when is_binary(text) <- Bee.API.text(path),
         edits =
           for(
             %{"from" => from, "to" => to, "text" => insert} <- edits,
             do: {to_bytes(text, from), to_bytes(text, to), insert}
           ),
         :ok <- Bee.API.edit(path, edits) do
      # The changed text first: it is there when the edit's promise resolves.
      s |> sync_document(path, Bee.API.text(path)) |> reply(id, true)
    else
      _ -> reply(s, id, false)
    end
  end

  defp handle_request("updateConfiguration", %{"key" => key} = params, id, s) do
    scope = if params["target"] == "user", do: :user, else: {:workspace, s.root}

    case Bee.Settings.update(scope, key, fn _ -> params["value"] end) do
      :ok -> s |> notify("settings", %{settings: Bee.Settings.all(s.root)}) |> reply(id, nil)
      {:error, message} -> reply_error(s, id, message)
    end
  end

  defp handle_request("openFile", %{"path" => path} = params, id, s) do
    opts = if is_integer(params["line"]), do: [line: params["line"]], else: []
    Bee.API.open_file(context(s), path, opts)
    reply(s, id, nil)
  end

  # Edits of several files (a rename, a quick fix), and files to create,
  # delete or rename: all of them, or `false`.
  defp handle_request("applyWorkspaceEdit", params, id, s) do
    files = List.wrap(params["files"])
    operations = List.wrap(params["operations"])

    with :ok <- Enum.reduce_while(operations, :ok, &continue(file_operation(&1), &2)),
         {:ok, s} <-
           Enum.reduce_while(files, {:ok, s}, fn file, {:ok, s} ->
             case edit_file(s, file) do
               {:ok, s} -> {:cont, {:ok, s}}
               error -> {:halt, error}
             end
           end) do
      reply(s, id, true)
    else
      _ -> reply(s, id, false)
    end
  end

  # An address for the user's browser (env.openExternal).
  defp handle_request("openExternal", %{"url" => url}, id, s) when is_binary(url) do
    if external?(url) do
      to_window(s, {:open_external, url})
      reply(s, id, true)
    else
      reply(s, id, false)
    end
  end

  defp handle_request("findFiles", _params, id, s),
    do: reply(s, id, Bee.Workspace.files(s.root))

  defp handle_request("getLanguages", _params, id, s),
    do: reply(s, id, Enum.map(Bee.Languages.all(), & &1.id))

  defp handle_request("getCommands", _params, id, s),
    do: reply(s, id, Enum.map(Bee.Commands.Registry.commands(), & &1.id))

  # A command that isn't in Node (yet): VS Code's setContext, an extension
  # that isn't active, or one of Bee's.
  defp handle_request("executeCommand", %{"command" => command} = params, id, s) do
    args = List.wrap(params["args"])

    case {command, args, Bee.Commands.Registry.command(command)} do
      {"setContext", [key, value | _], _} when is_binary(key) ->
        Bee.UI.put_context(s.root, params["extension"] || "extension", key, value)
        reply(s, id, nil)

      {"vscode.open", [target | _], _} ->
        target = plain(target)

        if is_binary(target) and external?(target),
          do: to_window(s, {:open_external, target}),
          else: Bee.API.open_file(context(s), target)

        reply(s, id, nil)

      {_, _, %{handler: {:extension, name}}} ->
        forward = fn
          {:ok, s} ->
            request(s, "executeCommand", %{command: command, args: args}, {:forward, id})

          {:error, message} ->
            reply_error(s, id, message)
        end

        case s.extensions[name] do
          %{status: :active} ->
            # Unregistered since, or never registered.
            reply_error(s, id, "command '#{command}' not found")

          %{status: :activating} = extension ->
            put_in(s.extensions[name], %{extension | deferred: [forward | extension.deferred]})

          nil ->
            activate_for(s, name, forward)
        end

      {_, _, nil} ->
        reply_error(s, id, "command '#{command}' not found")

      {_, _, _bees} ->
        to_window(s, {:execute_command, command, Enum.map(args, &plain/1)})
        reply(s, id, nil)
    end
  end

  defp handle_request(method, _params, id, s),
    do: reply_error(s, id, "Bee has no #{method}")

  # The extension of a command another one runs: activated first.
  defp activate_for(s, name, forward) do
    case Bee.Plugins.get(name, s.root) do
      %{status: status} = plugin when status not in [:invalid, :disabled, :failed] ->
        s = start_extension(s, plugin)

        case s.extensions[name] do
          nil -> forward.({:error, "#{name} can't be activated"}) && s
          extension -> put_in(s.extensions[name], %{extension | deferred: [forward]})
        end

      _ ->
        forward.({:error, "#{name} can't be activated"})
    end
  end

  defp external?(url), do: String.match?(url, ~r/^(https?|mailto):/i)

  # {"$uri": path} (a vscode.Uri) → the path, for Bee's own commands.
  defp plain(%{"$uri" => path}) when is_binary(path), do: path
  defp plain(other), do: other

  ## Notifications of extensions

  defp handle_notification("registerCommand", %{"extension" => name, "command" => id}, s) do
    :ets.insert(@commands, {{s.root, id}, name})
    s
  end

  defp handle_notification("unregisterCommand", %{"command" => id}, s) do
    :ets.delete(@commands, {s.root, id})
    s
  end

  defp handle_notification("statusItem", %{"extension" => name, "id" => id} = params, s) do
    case params["item"] do
      %{} = item -> Bee.UI.put_status_item(s.root, name, id, item)
      _ -> Bee.UI.delete_status_item(s.root, name, id)
    end

    s
  end

  # A diagnostic collection's diagnostics of a file (none: cleared).
  defp handle_notification("diagnostics", %{"owner" => owner, "path" => path} = params, s) do
    Bee.Diagnostics.put(s.root, owner, path, List.wrap(params["diagnostics"]))
    s
  end

  # An extension watches files, or none does any more.
  defp handle_notification("watchFiles", %{"on" => on?}, s) do
    cond do
      on? and not s.watching? -> Bee.Workspace.subscribe()
      not on? and s.watching? -> Phoenix.PubSub.unsubscribe(Bee.PubSub, "fs")
      true -> :ok
    end

    %{s | watching?: on? == true}
  end

  # Which language features the extensions provide, for which files.
  defp handle_notification("providers", params, s) do
    Bee.Languages.Features.put(s.root, Enum.filter(List.wrap(params["providers"]), &is_map/1))
    s
  end

  defp handle_notification("setStatus", %{"text" => text}, s) do
    Bee.API.set_status(context(s), text)
    s
  end

  defp handle_notification("unsupported", %{"extension" => name, "api" => api}, s) do
    if name != "",
      do:
        manager({:extension_warning, name, s.root, "uses vscode.#{api}, which Bee doesn't have"})

    s
  end

  # Webview panels of extensions (window.createWebviewPanel): Bee.Webviews
  # has them for the windows to show.
  defp handle_notification("webviewOpen", %{"id" => id} = params, s) when is_binary(id) do
    Bee.Webviews.open(s.root, id, %{
      extension: params["extension"],
      view_type: params["viewType"],
      title: to_string(params["title"]),
      scripts?: params["scripts"] == true,
      roots: Enum.filter(List.wrap(params["roots"]), &is_binary/1)
    })

    s
  end

  defp handle_notification("webviewUpdate", %{"id" => id} = params, s) do
    changes =
      for {key, name, valid?} <- [
            {:title, "title", &is_binary/1},
            {:html, "html", &is_binary/1},
            {:scripts?, "scripts", &is_boolean/1},
            {:roots, "roots", &is_list/1}
          ],
          Map.has_key?(params, name) and valid?.(params[name]),
          into: %{},
          do: {key, params[name]}

    Bee.Webviews.update(s.root, id, changes)
    s
  end

  defp handle_notification("webviewPost", %{"id" => id} = params, s) do
    Bee.Webviews.post(s.root, id, params["message"])
    s
  end

  defp handle_notification("webviewReveal", %{"id" => id}, s) do
    Bee.Webviews.reveal(s.root, id)
    s
  end

  defp handle_notification("webviewDispose", %{"id" => id}, s) do
    Bee.Webviews.dispose(s.root, id)
    s
  end

  # An output channel of an extension's (window.createOutputChannel).
  defp handle_notification("output", %{"channel" => channel, "text" => text}, s)
       when is_binary(channel) and is_binary(text) do
    Bee.Output.append(s.root, channel, text)
    s
  end

  defp handle_notification("outputClear", %{"channel" => channel}, s) when is_binary(channel) do
    Bee.Output.clear(s.root, channel)
    s
  end

  # channel.show(): the panel's Output section, on that channel.
  defp handle_notification("outputShow", %{"channel" => channel}, s) when is_binary(channel) do
    to_window(s, {:show_output, channel})
    s
  end

  defp handle_notification("log", %{"text" => text} = params, s) do
    line = if params["extension"], do: "#{params["extension"]}: #{text}", else: text
    Bee.Output.append_line(s.root, Bee.Output.host_channel(), line)

    case params["level"] do
      "error" -> Logger.warning("Bee extension: #{line}")
      _ -> Logger.debug("Bee extension: #{line}")
    end

    log = :queue.in(line, s.log)
    log = if :queue.len(log) > @log_lines, do: :queue.drop(log), else: log
    %{s | log: log}
  end

  defp handle_notification(_method, _params, s), do: s

  ## Windows

  # What the extensions show goes to the window of the last command, or
  # (none yet, or it closed) to every window of the workspace.
  defp watch_window(s, nil), do: s
  defp watch_window(%{window: {pid, _}} = s, pid), do: s

  defp watch_window(s, pid) do
    with {_old, ref} <- s.window, do: Process.demonitor(ref, [:flush])
    %{s | window: {pid, Process.monitor(pid)}}
  end

  defp context(s), do: context(s, with({pid, _} <- s.window, do: pid))

  defp context(s, window) when is_pid(window) or is_nil(window),
    do: %Context{plugin: "extension", root: s.root, window: window, host: self()}

  defp to_window(s, request) do
    case s.window do
      {pid, _} -> send(pid, {:bee_api, request})
      nil -> Phoenix.PubSub.broadcast(Bee.PubSub, "windows:" <> s.root, {:bee_api, request})
    end
  end

  # Asks in a window: `kind` is `:pick` (`spec`: `%{placeholder, items:
  # [%{label, description, value}]}`, answered with the picked item's value)
  # or `:input` (`%{prompt, placeholder, value}`, answered with the text).
  # The window answers `{:bee_answer, ref, value}`, `nil` when dismissed.
  defp ask(s, id, kind, spec) do
    ref = make_ref()
    to_window(s, {:ask, ref, self(), kind, spec})
    %{s | asks: Map.put(s.asks, ref, {id, s.window == nil})}
  end

  ## Documents, the active editor

  # Tells Node the text of an open file, when it doesn't have that text.
  defp sync_document(s, path, text) when is_binary(text) do
    hash = :erlang.phash2(text)

    cond do
      not inside?(path, s.root) ->
        s

      s.documents[path] == hash ->
        s

      Map.has_key?(s.documents, path) ->
        notify(
          %{s | documents: Map.put(s.documents, path, hash)},
          "documentChanged",
          document(path, text)
        )

      true ->
        notify(
          %{s | documents: Map.put(s.documents, path, hash)},
          "documentOpened",
          document(path, text)
        )
    end
  end

  defp sync_document(s, _path, _text), do: s

  # `{document, editor, s}` for a window's active file: its text if Node
  # doesn't have it, and its selections in Node's offsets.
  defp editor_state(s, nil, _selections), do: {nil, nil, s}

  defp editor_state(s, path, selections) do
    case inside?(path, s.root) && Bee.API.text(path) do
      text when is_binary(text) ->
        hash = :erlang.phash2(text)
        document = if s.documents[path] == hash, do: nil, else: document(path, text)

        ranges =
          for {from, to} <- selections || [], do: [to_utf16(text, from), to_utf16(text, to)]

        {document, %{path: path, selections: ranges},
         %{s | documents: Map.put(s.documents, path, hash)}}

      _ ->
        {nil, nil, s}
    end
  end

  defp inside?(path, dir), do: String.starts_with?(path, dir <> "/")

  defp excluded?(path, root) do
    relative = Path.relative_to(path, root)

    Enum.any?(Bee.Settings.excluded_globs(root), &Bee.Workspace.Glob.match?(&1, relative)) or
      Enum.any?(Path.split(relative), &(&1 in ~w(.git _build deps node_modules .elixir_ls)))
  end

  ## Workspace edits

  defp continue(:ok, _acc), do: {:cont, :ok}
  defp continue(error, _acc), do: {:halt, error}

  # The edits of one file ([{from, to, text}], positions): in its open
  # buffer (every editor showing it gets them, undoable), or on disk.
  defp edit_file(s, %{"path" => path, "edits" => edits}) do
    with text when is_binary(text) <- Bee.API.text(path) || "",
         edits =
           for(
             %{"from" => from, "to" => to, "text" => insert} <- edits,
             do: {position_to_bytes(text, from), position_to_bytes(text, to), insert}
           ) do
      case Bee.API.edit(path, edits) do
        :ok ->
          {:ok, sync_document(s, path, Bee.API.text(path))}

        {:error, :not_open} ->
          with {:ok, changed} <- Buffer.apply_edits(text, edits),
               :ok <- File.mkdir_p(Path.dirname(path)),
               :ok <- File.write(path, changed),
               do: {:ok, s}

        error ->
          error
      end
    end
  end

  defp edit_file(_s, _file), do: {:error, :invalid}

  defp file_operation(%{"kind" => "create", "path" => path} = op) do
    cond do
      not File.exists?(path) or op["overwrite"] ->
        with :ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, "")

      op["ignoreIfExists"] ->
        :ok

      true ->
        {:error, :eexist}
    end
  end

  defp file_operation(%{"kind" => "delete", "path" => path} = op) do
    cond do
      not File.exists?(path) -> if(op["ignoreIfNotExists"], do: :ok, else: {:error, :enoent})
      File.dir?(path) and op["recursive"] -> with({:ok, _} <- File.rm_rf(path), do: :ok)
      File.dir?(path) -> File.rmdir(path)
      true -> File.rm(path)
    end
  end

  defp file_operation(%{"kind" => "rename", "path" => path, "newPath" => new} = op)
       when is_binary(new) do
    cond do
      File.exists?(new) and op["ignoreIfExists"] -> :ok
      File.exists?(new) and not op["overwrite"] -> {:error, :eexist}
      true -> with(:ok <- File.mkdir_p(Path.dirname(new)), do: File.rename(path, new))
    end
  end

  defp file_operation(_other), do: {:error, :invalid}

  ## The port

  defp request(s, method, params, what) do
    id = s.next_id
    send_node(s, %{id: id, method: method, params: params})
    %{s | next_id: id + 1, pending: Map.put(s.pending, id, what)}
  end

  defp notify(s, method, params) do
    send_node(s, %{method: method, params: params})
    s
  end

  defp reply(s, id, result) do
    send_node(s, %{id: id, result: result})
    s
  end

  defp reply_error(s, id, message) do
    send_node(s, %{id: id, error: %{message: to_string(message)}})
    s
  end

  defp send_node(%{port: nil}, _message), do: :ok

  defp send_node(%{port: port}, message) do
    Port.command(port, Jason.encode!(message))
  rescue
    # The port closed under us: its exit message follows.
    ArgumentError -> :ok
  end

  defp manager(message), do: GenServer.cast(Bee.Plugins.Manager, message)
end
