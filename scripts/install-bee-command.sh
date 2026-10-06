#!/bin/sh
# Sets up the `bee` command for the desktop app of this checkout:
#
#   bee            opens the current folder
#   bee .          the same
#   bee DIR        opens DIR
#
# The app starts in the background; when it is already running, the folder
# opens in a window of the running app. Its output goes to
# ~/.local/state/bee/desktop.log.
#
# `bee` is a shell function, added to ~/.bashrc and ~/.zshrc (those that
# exist, and the one of your login shell) between "# >>> bee >>>" and
# "# <<< bee <<<"; running this again replaces it. Builds the desktop
# release first if there is none (mix bee.release.desktop).
#
# Also installs the app's desktop entry and icon (in ~/.local/share), so
# taskbars show Bee's logo for its windows (they find it by the window's
# app id, bee-desktop) and app menus list it. (Not on WSL: WSLg only reads
# system folders, so its taskbar shows its default icon.)
#
#   scripts/install-bee-command.sh              install
#   scripts/install-bee-command.sh --uninstall  remove it again
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
app="$repo/desktop/target/release/bee-desktop"
begin="# >>> bee >>>"
end="# <<< bee <<<"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
entry="$data/applications/bee-desktop.desktop"
icon="$data/icons/hicolor/512x512/apps/bee-desktop.png"

rc_files() {
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] && echo "$rc"
  done
  case "${SHELL:-}" in
    */zsh) [ -f "$HOME/.zshrc" ] || echo "$HOME/.zshrc" ;;
    *) [ -f "$HOME/.bashrc" ] || echo "$HOME/.bashrc" ;;
  esac
}

# Removes our block from file $1.
remove_block() {
  [ -f "$1" ] || return 0
  tmp=$(mktemp)
  awk -v b="$begin" -v e="$end" '$0 == b {skip = 1} !skip {print} $0 == e {skip = 0}' "$1" >"$tmp"
  cat "$tmp" >"$1"
  rm -f "$tmp"
}

if [ "${1:-}" = "--uninstall" ]; then
  for rc in $(rc_files); do
    remove_block "$rc"
    echo "Removed bee from $rc"
  done
  rm -f "$entry" "$icon"
  echo "Removed $entry and $icon"
  echo "Open a new terminal (or run: unset -f bee)."
  exit 0
fi

if [ ! -x "$app" ]; then
  echo "No desktop release yet: building it (mix bee.release.desktop)…"
  (cd "$repo" && mix bee.release.desktop)
fi

for rc in $(rc_files); do
  remove_block "$rc"
  cat >>"$rc" <<EOF
$begin
# Bee's desktop app (from $repo/scripts/install-bee-command.sh)
bee() {
  mkdir -p "\$HOME/.local/state/bee"
  (nohup "$app" "\$@" >>"\$HOME/.local/state/bee/desktop.log" 2>&1 &)
}
$end
EOF
  echo "Added bee to $rc"
done

# The taskbar's and app menu's icon: the window's app id is bee-desktop.
mkdir -p "$(dirname "$entry")" "$(dirname "$icon")"
cp "$repo/desktop/icons/icon.png" "$icon"
cat >"$entry" <<EOF
[Desktop Entry]
Type=Application
Name=Bee
Comment=A code editor built on Phoenix LiveView
Exec="$app" %f
Icon=$icon
StartupWMClass=bee-desktop
Categories=Development;TextEditor;
Terminal=false
EOF
echo "Installed $entry"

echo "Open a new terminal (or source your rc file), then: bee ."
