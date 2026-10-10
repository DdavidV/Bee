# Security and access

Bee can open terminals and read and write your files. Whoever can reach Bee
can do what you can do. This page describes who can reach it, and how
content that is not Bee's own is kept apart.

## The short version

- The **desktop app** opens no port. Only the app itself can talk to Bee.
- In the **browser**, Bee listens on your own machine only and requires a
  token.
- **Plugins and extensions are trusted code.** Install only what you would
  run as a program.
- **Pages from extensions** are isolated from Bee's own page by origin.

## Desktop mode

The desktop app starts Bee as a child process and talks to it over that
process's standard input and output. Nothing listens anywhere. No other
program, and no web page, has a way in.

No token is needed, and none is used. See
[LiveView without a web server](desktop-bridge.md).

## Browser mode

### Local only

Bee listens on `127.0.0.1`. It is not reachable from other machines.

### The token

Being local is not enough. Other programs on the machine, and web pages open
in your browser, can also send requests to a local port. So Bee asks for
proof that the visitor was given its address.

```
 Bee starts and prints   http://127.0.0.1:4000/?token=…
          │
          ▼
 you open that address
          │
          ▼
 Bee checks the token, sets a session cookie,
 and redirects to the same address without the token
          │
          ▼
 from now on the cookie is enough:  http://127.0.0.1:4000
```

- A request with neither a valid token nor the cookie is refused, with a
  page saying where to find the address.
- The token is generated on first run and kept in the configuration folder,
  readable only by you. It survives restarts, so the cookie stays good.
- The cookie stores a fingerprint of the token, not the token. **Deleting
  the token file signs out every browser**: Bee makes a new one on its next
  start and old cookies no longer match.
- The live connection is checked again on its own when it is set up. The
  page having been served is not taken as proof.
- `BEE_TOKEN` sets a fixed token instead of the generated one.

### Only local names

A web page elsewhere can point a domain name of its own at `127.0.0.1` and
have your browser send requests to Bee under that name. Bee refuses any
request that does not address it by a local name: `localhost`, `127.0.0.1`
or `[::1]`.

The live connection is additionally checked for where it was opened from,
and only pages served from those local names are accepted.

If you reach Bee through a tunnel or a proxy under another name, add that
name with `BEE_ALLOWED_HOSTS`. Doing so widens who can reach Bee, so do it
knowingly.

### The cookie secret

Cookies are signed with a secret created on first run and kept in the
configuration folder, readable only by you. `SECRET_KEY_BASE` overrides it.

## Plugins and extensions

There is no sandbox.

- A plugin's **server part** runs inside Bee and can do anything Bee can.
- A plugin's **browser part** runs in Bee's page and can do anything the
  page can.
- A VS Code extension's **code** runs in Node.js with your permissions, as
  it does in VS Code.

What Bee does guard against is code running without you having asked for it.

**Opening a folder never runs its code.** A folder can carry plugins in
`.bee/plugins`, but they are loaded only when `plugins.workspace.enabled`
is on, and that setting is honoured only from your own user settings. A
repository cannot switch it on in its own settings file.

**Only declared files are served.** The page can fetch a plugin's browser
module, its stylesheet, its theme icons, its grammar files and the images of
its details page. Nothing else from a plugin's folder is reachable over the
page's connection. Images and grammars are served with restrictions that
stop a file opened directly from running scripts as Bee.

**Names in manifests cannot reach outside the plugin.** A LiveView named in
a manifest is only ever resolved to one of that plugin's own modules, and
source paths are confined to the plugin's folder.

**Extension packages are checked** before unpacking: size, file count, and
paths that would escape the folder.

## Webview pages

A VS Code extension can show a page of its own HTML in an editor tab. That
page is the extension's, possibly with scripts, possibly loading content
from elsewhere. It must not be able to act as Bee's page, which holds the
live connection to everything.

Browsers isolate pages by **origin**. Bee gives webview pages an origin of
their own.

| | Where webview pages come from |
|---|---|
| Browser mode | A second local port, picked at startup, that serves webview pages and nothing else |
| Desktop app | A second address scheme of the app's, since no port is opened |
| Neither is reachable | Bee's own address, with the frame denied any origin at all |

In every case the page cannot read Bee's page, its cookies or its
connection, and Bee's page cannot be scripted by it.

Further limits:

- Each panel has an unguessable token in its address. That token is the only
  credential a webview page has, and it grants that page only.
- A panel may load local files only from the folders its extension listed,
  with links in the path followed before the check.
- Scripts run in the page only if the extension enabled them.
- The page talks to its extension, and to nothing else in Bee, by passing
  messages.
- Links to the web open in your browser, not in the frame.

## Paths from the browser

Every file path that arrives from the page is resolved against the open
folder and refused if it would land outside it. Explorer operations (create,
rename, move, delete) are confined the same way.

## Opening links

Bee opens only web links outside itself: `http` and `https`, and in the
browser also `mailto`. In the desktop app they go to your default browser,
never into Bee's window.

## Programs Bee starts

Terminals, git, the extension host and the language servers extensions
start all run as you, in your environment.

When Bee runs from a release, its own runtime's variables and paths are
removed from the environment these programs inherit, so that tools you run
in a terminal are your own and not the ones bundled with Bee.

## Releases and the network

A release of Bee does not join an Erlang cluster and does not start the
daemon that clustering needs, which would listen on all interfaces and
outlive Bee. Set `RELEASE_DISTRIBUTION=sname` if you want to attach a remote
shell to a running release, knowing that this opens that door.

The only outgoing connections Bee makes itself are to Open VSX, when you
search for or install extensions, and to fetch JSON schemas that extensions
reference by web address.
