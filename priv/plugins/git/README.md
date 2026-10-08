# Git

Source control for Bee, like VS Code's: see what changed, stage, commit, switch branches, push and pull. Plus GitLens-style blame: who changed a line, and when, right in the editor.

It works on the git repository of the folder Bee has open, and needs `git` installed (or set `git.path`).

## Source Control

Open it from the activity bar (the branch icon). The icon's badge counts the changed files.

- **Changes:** the files that changed, in three groups: **Merge Changes** (conflicts), **Staged Changes** and **Changes**. Hover a file for its buttons:
  - open it
  - stage or unstage it
  - discard its changes, after asking first

  Each group's header stages, unstages or discards all of its files at once.
- **Commit:** type a message in the box at the top, then press `Ctrl+Enter` or **✓ Commit**. **Git: Commit** from the command palette asks for the message instead.
- **Commits:** the last 50 commits. Expand one to see the files it changed, and open them.
- **Not a repository yet?** **Git: Initialize Repository** makes one.

Files are coloured with their status in the Explorer and on their tabs, like in VS Code:

| Letter | Meaning |
|---|---|
| U | untracked (new) |
| A | added |
| M | modified |
| D | deleted |
| R | renamed |
| ! | conflict |

## Branches and remotes

The status bar shows the current branch. Click it to check out another one, or use **Git: Checkout to…**. **Git: Create Branch…** makes a new one.

When your branch has a remote, the status bar also shows how many commits it is ahead and behind (↑ ↓). Click it to **sync**: pull (fast-forward only), then push.

**Pull**, **Push**, **Fetch** and **Sync** are in the command palette, and Pull and Push are also in the Source Control header. They run in the background, so a slow remote doesn't hold Bee up.

## In the editor

- **Line blame:** after the line you're on: who last changed it, when, and the commit's message, e.g. *You, 5 minutes ago • Fix the parser*. Hover it for the commit's hash, author, date and full message. Turn it on or off with **Git: Toggle Line Blame**, or the `git.blame.inline` setting.
- **File blame:** a gutter showing who changed each block of lines and when. Turn it on with **Git: Toggle File Blame** (`Ctrl+Alt+B`), or the button above the editor.
- **Change markers:** bars in the gutter for lines that are added (green), modified (blue) or deleted (red). Click one to peek at the change: the old lines and the new ones, with:
  - Stage Change
  - Revert Change
  - Next and Previous Change
  - Close (`Escape`)

Blame and markers follow your unsaved edits too.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `git.path` | `"git"` | The git executable. |
| `git.blame.inline` | `true` | Show the current line's blame at its end. |
| `git.decorations.gutter` | `true` | Show the change markers in the gutter. |

## Commands

All are in the command palette (`Ctrl+Shift+P`) under **Git:**

- **Initialize Repository**, **Refresh**
- **Commit**
- **Stage All Changes**, **Unstage All Changes**, **Discard All Changes**
- **Checkout to…**, **Create Branch…**
- **Pull**, **Push**, **Fetch**, **Sync**
- **Toggle File Blame** (`Ctrl+Alt+B`), **Toggle Line Blame**

## How it's built

It's a Bee plugin in two parts, both included with Bee:

- **Server part** (`lib/`, Elixir): runs git, watches the repository and fills the Source Control views and the status bar.
- **Browser part** (`browser.js`): draws the blame and the change markers in the editor (CodeMirror).

It's also an example of what a plugin can do with Bee's plugin API.
