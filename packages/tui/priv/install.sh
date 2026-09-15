#!/usr/bin/env bash
# Install complete releases beside existing trees, then publish their links.
# A live process can load files long after boot, so published trees are never
# replaced, renamed, or pruned. Reinstalling the same version gets a new tree.
# Usage: [PREFIX=$HOME/.local] [LOOM_CLIENT=bundled|slim] scripts/install.sh
set -euo pipefail
ROOT="${LOOM_INSTALL_SOURCE:?install.sh needs LOOM_INSTALL_SOURCE}"
ROOT="$(CDPATH= cd -- "$ROOT" && pwd -P)"
PREFIX="${PREFIX:-$HOME/.local}"
CLIENT="${LOOM_CLIENT:-bundled}"
case "$CLIENT" in
  bundled) CLIENT_STEM=client; CLIENT_SRC="$ROOT/build/release/loom-client" ;;
  slim) CLIENT_STEM=tui; CLIENT_SRC="$ROOT/build/tui-erlang-shipment" ;;
  *) echo 'install.sh: LOOM_CLIENT must be bundled or slim' >&2; exit 1 ;;
esac
SERVER_SRC="$ROOT/build/release/loom"
for launcher in "$SERVER_SRC/bin/loomd" "$SERVER_SRC/bin/loom-exec" \
  "$CLIENT_SRC/bin/loom" "$CLIENT_SRC/bin/loom-profile"; do
  [ -x "$launcher" ] || {
    echo "install.sh: missing $launcher; run the release/client build first" >&2
    exit 1
  }
done
[ -d "$SERVER_SRC/share/codemode-seed" ] || {
  echo 'install.sh: server lacks code-mode seed; run make codemode-seed release' >&2
  exit 1
}

LIB="$PREFIX/lib/loom"
BIN="$PREFIX/bin"
# Preflight before copying or publishing anything. Even renaming a legacy
# directory breaks later absolute-path loads by processes started from it.
# No endpoint/PID check can prove that every client and daemon has retired.
for stem in server client tui; do
  if [ -e "$LIB/$stem" ] && [ ! -L "$LIB/$stem" ]; then
    echo "install.sh: legacy path $LIB/$stem must be migrated offline." >&2
    echo 'Stop all clients and daemons using this prefix, move its trees aside,' >&2
    echo 'then reinstall, or choose a fresh PREFIX. See docs/updating.md.' >&2
    exit 1
  fi
done
for launcher in loom loomd loom-profile; do
  if [ -d "$BIN/$launcher" ]; then
    echo "install.sh: launcher path is a directory: $BIN/$launcher" >&2
    exit 1
  fi
done
mkdir -p "$LIB" "$BIN"
LIB="$(CDPATH= cd -- "$LIB" && pwd -P)"
BIN="$(CDPATH= cd -- "$BIN" && pwd -P)"
PREFIX="$(CDPATH= cd -- "$PREFIX" && pwd -P)"

# Only private, unpublished wrapper files are removed on failure. A copied
# release may already have been published when a later step fails, so retaining
# it is safer than trying to roll back a multi-file installation in a trap.
WRAPPERS="$(mktemp -d "$BIN/.loom-install.XXXXXXXX")"
LINKS="$(mktemp -d "$LIB/.loom-install.XXXXXXXX")"
trap 'rm -rf "$WRAPPERS" "$LINKS"' EXIT

# A random suffix identifies the installation, independently of package version
# or git revision. The directory stays unreachable from launchers until its
# whole copy succeeds. Interrupted copies remain for offline manual cleanup.
copy_release() {
  local src="$1" stem="$2" dest
  dest="$(mktemp -d "$LIB/$stem.XXXXXXXX")" || return
  cp -R "$src/." "$dest/" || return
  printf '%s\n' "$dest"
}
SERVER_TREE="$(copy_release "$SERVER_SRC" server)"
CLIENT_TREE="$(copy_release "$CLIENT_SRC" "$CLIENT_STEM")"

# Quote literal filesystem paths for the generated shell, including prefixes
# containing spaces, dollar signs, or apostrophes.
shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
write_wrapper() {
  local name="$1" stem="$2" entry="$3"
  {
    printf '%s\n' '#!/bin/sh' 'set -eu'
    printf 'tree=$(CDPATH= cd -- %s && pwd -P)\n' "$(shell_quote "$LIB/$stem")"
    if [ "$name" = loom ]; then
      printf 'LOOM_EXECUTABLE=%s\nexport LOOM_EXECUTABLE\n' "$(shell_quote "$BIN/loom")"
      printf 'LOOM_INSTALL_PREFIX=%s\nexport LOOM_INSTALL_PREFIX\n' "$(shell_quote "$PREFIX")"
      printf 'LOOM_INSTALL_CLIENT=%s\nexport LOOM_INSTALL_CLIENT\n' "$(shell_quote "$CLIENT")"
    fi
    printf 'exec "$tree/bin/%s" "$@"\n' "$entry"
  } > "$WRAPPERS/$name"
  chmod +x "$WRAPPERS/$name"
}
write_wrapper loomd server loomd
write_wrapper loom "$CLIENT_STEM" loom
write_wrapper loom-profile "$CLIENT_STEM" loom-profile

# GNU mv needs -T and BSD mv needs -h to replace a directory symlink rather
# than moving the new link into its target. Both source and destination live
# on the same filesystem. Each switch exposes a complete old or new tree.
switch_link() {
  local tree="$1" stem="$2" staged="$LINKS/$2.link"
  ln -s "$tree" "$staged"
  if ! mv -T -f "$staged" "$LIB/$stem" 2>/dev/null; then
    mv -h -f "$staged" "$LIB/$stem"
  fi
}
switch_link "$SERVER_TREE" server
switch_link "$CLIENT_TREE" "$CLIENT_STEM"
# Rename complete scripts rather than truncating a launcher another process
# may still be reading. The other client shape's link and trees remain intact.
for launcher in loomd loom loom-profile; do
  mv -f "$WRAPPERS/$launcher" "$BIN/$launcher"
done
printf 'installed:\n  %s\n  %s\n  %s\n' "$BIN/loom" "$BIN/loomd" "$BIN/loom-profile"
printf 'release trees:\n  %s\n  %s\n' "$SERVER_TREE" "$CLIENT_TREE"
printf '%s\n' 'Old trees are retained. See docs/updating.md for restart and manual cleanup.'
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) printf 'Add %s to PATH, or invoke the launchers there directly.\n' "$BIN" ;;
esac
CATALOGUE="${LOOM_STATE_DIR:-$HOME/.loom}/loom.toml"
if [ ! -f "$CATALOGUE" ]; then
  printf 'No catalogue at %s; docs/examples/loom.toml is a worked example.\n' "$CATALOGUE"
fi
