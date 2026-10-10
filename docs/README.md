# Bee documentation

Bee is a code editor built on Phoenix LiveView. The same editor runs in a
browser tab or in a desktop window, and it is extended by plugins and by
VS Code extensions.

These pages describe how Bee works and how to use and extend it. For
installing and starting Bee, see the [README](../README.md).

| Page | What it covers |
|---|---|
| [Architecture](architecture.md) | The parts of Bee, what runs where, and how a keystroke, a command or a file change travels through them |
| [LiveView without a web server](desktop-bridge.md) | How the desktop app shows a LiveView application without opening a port |
| [Plugins](plugins.md) | What a plugin is, how Bee loads and runs it, and a guide to writing one |
| [VS Code extensions](vscode-extensions.md) | Installing extensions from Open VSX or a VSIX, what Bee uses of them, and how their code runs |
| [Configuration](configuration.md) | Every setting, keybinding, file and environment variable |
| [Security and access](security.md) | Who can reach Bee, and how plugin and extension content is kept apart |
| [Developing Bee](development.md) | Running from source, tests, releases, and the Bee Console |

## Bee in one paragraph

Bee is one long-running program. It holds the open folders, the text of the
open files, the terminals and the plugins. A window, whether a browser tab
or a desktop window, is a thin view of that program: it draws what Bee sends
and reports what the user does. Almost everything Bee offers, including its
own menus and commands, is declared in manifests that plugins use in the same
format, so a plugin can add to Bee anything Bee adds to itself.
