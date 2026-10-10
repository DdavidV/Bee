# LiveView without a web server

Phoenix LiveView normally needs two network connections: an HTTP request
that fetches the page, and a WebSocket that keeps it live. The desktop app
has neither. Nothing listens on a port, on either side. The window and Bee
exchange messages over Bee's standard input and output, and LiveView does
not notice the difference.

This page explains how that works.

## Why

A local web server is reachable by every program on the machine, and by any
web page that guesses its address. The browser mode guards against that with
a token (see [Security and access](security.md)). The desktop app avoids the
question: with no port, there is nothing to reach. Only the process that
started Bee holds the two pipes that lead to it.

## The three parties

```
┌──────────────────────── desktop app (one process) ────────────────────────┐
│                                                                           │
│   ┌─────────── window (system webview) ──────────┐    ┌──── shell ─────┐  │
│   │  Bee's page                                  │    │  (Rust, Tauri) │  │
│   │    LiveView client                           │    │                │  │
│   │      └─ bridge transport ── window.__bridge ─┼───▶│  relays frames │  │
│   │  page, scripts, styles ── bee://localhost ───┼───▶│                │  │
│   └──────────────────────────────────────────────┘    └───────┬────────┘  │
└───────────────────────────────────────────────────────────────┼───────────┘
                                                         stdin  │ ▲  stdout
                                                                ▼ │
                                                        ┌─────────────────┐
                                                        │ Bee (child      │
                                                        │ process, BEAM)  │
                                                        │ no listener     │
                                                        └─────────────────┘
```

- **The window** is the system's webview showing Bee's page, the same page a
  browser would get.
- **The shell** is the native part of the desktop app. It owns the windows,
  starts Bee, and passes messages between the two. It does not understand
  LiveView. It only relays.
- **Bee** is the Phoenix application, started as a child process in desktop
  mode. In this mode it starts no web server at all.

## Starting up

1. The user starts the app with a folder (or files) to open.
2. The shell starts Bee as a child process, tells it to run in desktop mode
   and which folder it was started for, and keeps hold of its standard input
   and output. Bee's standard error goes wherever the app's does.
3. Bee boots as usual, except that it starts no listener. Instead it takes
   over its own standard input and output as a message channel.
4. The shell opens a window pointed at `bee://localhost/?folder=…`. Before
   any of the page's own scripts run, it injects a small script that gives
   the page an object to talk to the shell with.
5. The page loads, LiveView connects, and the editor is live.

A development build compiles the checkout first and runs it directly. A
release build starts Bee's release. Either way the handshake is the same.

## Frames

Every message between the shell and Bee is a **frame**: four bytes giving
the length, then that many bytes of JSON. Binary payloads inside the JSON
are base64.

Two kinds of traffic share the channel.

| From the shell | From Bee | Purpose |
|---|---|---|
| `req` | `res` | One HTTP request and its response |
| `open` | `opened` or `closed` | A LiveView socket connecting |
| `msg` | `msg` | A socket message, in either direction |
| `close` | `closed` | A socket ending |

Requests carry a number so answers can come back in any order. Sockets carry
an id so several can be open at once. Both carry the name of the window they
belong to.

## Loading the page

The window does not use `http://`. Its address is on a scheme of the app's
own, `bee://localhost`. The webview hands every request for that scheme to
the shell instead of the network.

```
window                      shell                         Bee
  │  GET bee://localhost/     │                            │
  ├──────────────────────────▶│  req #7 (method, url,      │
  │                           │  headers, body)            │
  │                           ├───────────────────────────▶│  runs the request through
  │                           │                            │  the normal Phoenix pipeline,
  │                           │  res #7 (status, headers,  │  in memory
  │                           │  body)                     │
  │        response           │◀───────────────────────────┤
  │◀──────────────────────────┤                            │
```

Inside Bee the request is an ordinary one. It passes through the same
endpoint, the same plugs, the same router and the same controllers as a
request that arrived over HTTP. The only difference is where it came from
and where the response goes. That is why nothing else in Bee needs to know
about desktop mode: the page, its scripts and stylesheets, plugin assets,
icons and grammar files are all served this way without special cases.

Requests are answered concurrently. Each waits for its own response, so a
slow one does not hold up the others. If Bee does not answer within two
minutes the window gets a gateway timeout.

### Cookies

LiveView's socket proves who it is with the session cookie the page was
served with. Custom schemes and cookies do not mix reliably across webviews,
so the shell does not handle cookies at all. Bee keeps a cookie jar for each
window itself:

- when a response sets a cookie, Bee stores it for that window and removes
  the header before the response leaves;
- when a request arrives from that window, Bee adds the stored cookies back
  before running it;
- when a socket connects from that window, it connects with the same
  cookies.

The session and the CSRF check therefore work exactly as they do over HTTP.

## The LiveView socket

LiveView's browser client accepts a custom transport: any object that
behaves like a WebSocket. Bee's page checks whether the shell's object is
present. If it is, LiveView is given a transport that never opens a socket.
If it is not, the page is in a browser and LiveView uses a real WebSocket,
falling back to long polling when that fails.

The bridge transport looks like a WebSocket from the inside: it has a ready
state, it can send, it can close, and it calls back when it opens, receives a
message or closes. What it actually does is hand each of those to the shell.

```
LiveView client        bridge transport        shell                Bee
      │  new transport        │                  │                   │
      ├──────────────────────▶│  open(sid, url)  │                   │
      │                       ├─────────────────▶│  open             │
      │                       │                  ├──────────────────▶│  finds the socket mounted at
      │                       │                  │                   │  that path, connects it with
      │                       │                  │                   │  the window's session, starts
      │                       │                  │   opened          │  a process for it
      │       onopen          │    opened        │◀──────────────────┤
      │◀──────────────────────┤◀─────────────────┤                   │
      │  send(join…)          │                  │                   │
      ├──────────────────────▶│  send(sid, data) ├─ msg ────────────▶│
      │                       │                  │                   │
      │      onmessage        │                  │◀─ msg ────────────┤  (reply, diffs, pushes)
      │◀──────────────────────┤◀─────────────────┤                   │
```

On Bee's side, each socket is a process that does for LiveView what a
WebSocket server would: it performs the connect step with the request's
parameters and the session cookie, including the CSRF check, then feeds
incoming messages to LiveView and sends whatever LiveView pushes back to the
shell. LiveView itself is unchanged. It sees a socket of the WebSocket kind.

If the connect is refused, or does not finish within ten seconds, the page
is told the socket closed, with the reason, and LiveView retries as it
would after any dropped connection.

### Keeping messages in order

LiveView depends on order: a channel must be joined before events are sent
on it, and diffs must be applied in sequence.

- **Page to shell.** Calls from the page to the shell may run concurrently
  and finish out of order. The injected script therefore queues them and
  sends each one only after the previous has been accepted.
- **Shell to page.** Messages go back over a channel that delivers them in
  the order they were sent.
- **Shell to Bee and back.** A single pipe in each direction is ordered by
  nature. The shell writes whole frames one at a time.

### Socket ids

The page numbers its own sockets, and two windows would each call their
first one the same thing. Two things keep them apart:

- each page load picks a random prefix, so the sockets of a reloaded page
  never take the ids of the ones still being torn down;
- the shell adds the window's name in front before passing the id to Bee.

## What else crosses the bridge

A web page cannot do everything a desktop app needs. The shell's object
offers a few services beyond the socket, which the page uses only when it is
there:

| Service | Used for |
|---|---|
| Open a window | *Open Folder in New Window*: Bee names the page, the shell opens a window for it or focuses the one already showing that folder |
| Pick a folder | *Open Folder…*: the system's native folder dialog. The pick comes back to the page, which runs the open-folder command with it |
| Copy text | *Copy Path*: webviews only let a page write the clipboard in some situations |
| Open a link | Links to the web open in the user's own browser, never inside Bee's window. Only `http` and `https` addresses are accepted |
| Window title | The native title follows the page's title, which changes with the folder |

In the browser the same actions fall back to what a page can do: a new tab,
the page's own clipboard access, an ordinary link.

## Windows and folders

One Bee serves every window. Each window shows one folder, named in its
address.

- **Launching the app again** does not start a second Bee. The new launch
  hands its arguments to the running app and exits. A folder is focused if a
  window already shows it, otherwise it gets a new window. A file opens in
  the window whose folder contains it. When several windows qualify, the
  innermost folder wins. With no such window, a new one opens for the file's
  folder, and the file is named in that window's address so it opens once the
  page is ready.
- **Closing a window** makes the shell close that window's sockets. Bee's
  LiveView for it ends, and with it the window's terminals. When no window
  shows a folder any more, Bee lets go of the folder a few seconds later.
- **Closing the last window** quits the app.

## Shutting down

The pipes are also the lifeline.

- When the shell exits, it closes Bee's standard input. Bee treats that as
  the signal to stop, and stops cleanly. If Bee has not stopped after a few
  seconds, the shell kills it.
- When Bee stops for any reason, its output ends. The shell notices and
  quits the app.

Neither side can outlive the other.

## Protecting the channel

Bee's standard output now carries frames, so a single stray line printed to
it would corrupt the stream. Bee is full of things that print: logging,
debugging output, and plugins that are free to print whatever they like.

In desktop mode Bee therefore replaces the process that normally receives
all printed output with one that forwards everything to standard error.
Every process started afterwards inherits it. Logs are sent to standard
error too. Attempts to read from standard input get an error, because the
input belongs to the bridge. The runtime is also started without its own
terminal reader, which would otherwise compete for the same input.

The result is that standard output carries frames and nothing else, whatever
code runs inside Bee.

## Webview panels: a second address

VS Code extensions can show pages of their own HTML in editor tabs. Such a
page must not share an origin with Bee's page, or it could act as the
editor. In the browser, Bee serves those pages from a second local port,
which the browser treats as a different origin.

The desktop app opens no port, so it uses a second scheme instead:
`beeview://localhost`. The shell answers it the same way as `bee://`, by
relaying frames. Bee tells the two apart by the address. Requests to the
second one reach only the webview pages and the files they are allowed to
load, and never carry the window's cookies. A different scheme is a
different origin, so the isolation is the same as in the browser.

See [Security and access](security.md) for more on webview isolation.

## Differences from browser mode

| | Browser | Desktop |
|---|---|---|
| Page and assets | HTTP on `127.0.0.1` | `bee://localhost`, relayed as frames |
| LiveView transport | WebSocket, long polling as fallback | Bridge transport |
| Access control | Token, then a session cookie | None needed: only the shell can reach Bee |
| Host check | Local names only | Not applied |
| Webview pages | A second local port | `beeview://localhost` |
| Log output | Standard output | Standard error |
| Lifetime | Until stopped | Until the last window closes |

Everything else is identical. It is the same page, the same LiveView, the
same plugins.

## Testing it

The desktop app can be built with a self-test. The first window then drives
Bee's real interface by itself: it opens, edits and saves a file, checks the
git plugin, checks that a webview page has an origin of its own, runs a
terminal command, opens and closes a second window, and reports each check. The app exits with success only if all of them passed.
See [Developing Bee](development.md).
