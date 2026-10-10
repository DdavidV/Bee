defmodule BeeWeb.WebviewController do
  @moduledoc """
  Serves a webview panel of an extension (`Bee.Webviews`) to the frame
  that shows it (`BeeWeb.Workbench.Webview`):

    * `GET /webview/:token/` – the panel's HTML, with Bee's part put in
      front (see below)
    * `GET /webview/:token/file/<absolute path>` – a file the page loads
      (`webview.asWebviewUri`), if it is under the panel's
      `localResourceRoots`

  `token` is the panel's, unguessable: the frame is sandboxed without
  `allow-same-origin`, so that the extension's page is apart from Bee's –
  it has no cookie to show, and can't reach Bee's page. Every answer says
  so again (`Content-Security-Policy: sandbox`), for a page opened on its
  own.

  Bee's part of the page, before anything of the extension's (also before
  a Content-Security-Policy of its own, which would stop it):

    * the color theme as VS Code's CSS variables (`--vscode-*`), and VS
      Code's default styles for webviews; `vscode-dark` or `vscode-light`
      on the body
    * `acquireVsCodeApi()`: `postMessage` to the extension (messages from
      it are `message` events of the window), `getState`/`setState`
    * links to the web open in the user's browser; keys with a modifier go
      to Bee too (its keybindings work with the focus in the page)

  The stand-in addresses of `asWebviewUri` in the HTML become the panel's.
  """
  use BeeWeb, :controller

  alias Bee.ColorThemes.Theme

  @placeholder "https://file.bee-webview.invalid"

  def show(conn, %{"token" => token, "path" => path}) do
    case {Bee.Webviews.by_token(token), path} do
      {nil, _} ->
        send_resp(conn, 404, "not found")

      {{root, panel}, page} when page in [[], ["index.html"]] ->
        conn
        |> headers(panel)
        |> put_resp_content_type("text/html")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, page(root, panel))

      {{_root, panel}, ["file" | parts]} ->
        case Bee.Webviews.resource(panel, "/" <> Path.join(parts)) do
          nil ->
            send_resp(conn, 404, "not found")

          file ->
            conn
            |> headers(panel)
            |> put_resp_content_type(MIME.from_path(file), nil)
            |> put_resp_header("cache-control", "no-cache")
            # The page's origin is none: fonts and fetch() ask for this.
            |> put_resp_header("access-control-allow-origin", "*")
            |> send_file(200, file)
        end

      _ ->
        send_resp(conn, 404, "not found")
    end
  end

  defp headers(conn, panel) do
    conn
    |> put_resp_header("content-security-policy", "sandbox " <> sandbox(panel))
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  @doc "What a panel's frame may do (the `sandbox` attribute): never `allow-same-origin`."
  def sandbox(%{scripts?: true}),
    do: "allow-scripts allow-forms allow-modals allow-popups allow-downloads"

  def sandbox(_panel), do: "allow-forms"

  @doc false
  def page(root, panel) do
    html = String.replace(panel.html, @placeholder, "/webview/#{panel.token}/file")
    theme = Bee.ColorThemes.get(Bee.Settings.get("workbench.colorTheme", root))
    insert(html, head(root, panel, theme))
  end

  # After <head>, <html> or the doctype, whichever the page has first.
  defp insert(html, head) do
    [~r/<head(\s[^>]*)?>/i, ~r/<html(\s[^>]*)?>/i, ~r/<!doctype[^>]*>/i]
    |> Enum.find_value(fn regex ->
      case Regex.run(regex, html, return: :index) do
        [{start, length} | _] -> start + length
        nil -> nil
      end
    end)
    |> case do
      nil -> head <> html
      at -> binary_part(html, 0, at) <> head <> binary_part(html, at, byte_size(html) - at)
    end
  end

  defp head(root, panel, theme) do
    kind = if theme.base == :light, do: "vscode-light", else: "vscode-dark"
    size = Bee.Settings.get("editor.fontSize", root) || 14
    config = Jason.encode!(%{kind: kind, state: panel.state}, escape: :html_safe)

    """
    <style id="_defaultStyles">
    :root{#{Theme.variables(theme)}
    --vscode-font-family:system-ui,-apple-system,"Segoe UI",sans-serif;--vscode-font-size:13px;--vscode-font-weight:normal;
    --vscode-editor-font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;--vscode-editor-font-size:#{size}px;--vscode-editor-font-weight:normal;
    color-scheme:#{if theme.base == :light, do: "light", else: "dark"}}
    html{background-color:var(--vscode-editor-background)}
    body{background-color:transparent;color:var(--vscode-editor-foreground);font-family:var(--vscode-font-family);font-weight:var(--vscode-font-weight);font-size:var(--vscode-font-size);margin:0;padding:0 20px}
    img,video{max-width:100%;max-height:100%}
    a,a code{color:var(--vscode-textLink-foreground,#3794ff)}
    a:hover{color:var(--vscode-textLink-activeForeground,#3794ff)}
    a:focus,input:focus,select:focus,textarea:focus{outline:1px solid -webkit-focus-ring-color;outline-offset:-1px}
    code{font-family:var(--vscode-editor-font-family);color:var(--vscode-textPreformat-foreground,inherit)}
    blockquote{background:var(--vscode-textBlockQuote-background,transparent);border-color:var(--vscode-textBlockQuote-border,currentColor)}
    </style>
    <script>
    (function () {
      var config = #{config};
      var state = config.state;
      var acquired = false;
      var post = function (type, data) { window.parent.postMessage({__bee: type, data: data}, "*"); };
      window.acquireVsCodeApi = function () {
        if (acquired) throw new Error("An instance of the VS Code API has already been acquired");
        acquired = true;
        return Object.freeze({
          postMessage: function (message) { post("message", message); },
          setState: function (value) { state = value; post("state", value); return value; },
          getState: function () { return state; }
        });
      };
      // From the extension: a message event of the window, as in VS Code.
      window.addEventListener("message", function (event) {
        if (event.source !== window.parent || !event.data || event.data.__bee !== "message") return;
        event.stopImmediatePropagation();
        window.dispatchEvent(new MessageEvent("message", {data: event.data.data}));
      }, true);
      var themed = function () {
        document.body.classList.add(config.kind);
        document.body.setAttribute("data-vscode-theme-kind", config.kind);
      };
      // As soon as there is a body: before the page's first script in it.
      if (document.body) themed();
      else new MutationObserver(function (_changes, observer) {
        if (!document.body) return;
        observer.disconnect();
        themed();
      }).observe(document.documentElement, {childList: true});
      document.addEventListener("click", function (event) {
        var link = event.target && event.target.closest && event.target.closest("a[href]");
        if (!link || event.defaultPrevented || link.getAttribute("href").charAt(0) === "#") return;
        event.preventDefault();
        if (/^(https?|mailto):/i.test(link.href)) post("open", link.href);
      });
      window.addEventListener("keydown", function (event) {
        if (!(event.ctrlKey || event.metaKey || event.altKey || /^F\\d+$/.test(event.key))) return;
        post("key", {key: event.key, code: event.code, ctrlKey: event.ctrlKey, metaKey: event.metaKey, altKey: event.altKey, shiftKey: event.shiftKey});
      });
    })();
    </script>
    """
  end
end
