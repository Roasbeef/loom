#!/usr/bin/env bash
# Install complete releases beside existing trees, then publish their links.
# A live process can load files long after boot, so a published tree is never
# replaced or renamed. Reinstalling the same version gets a new tree. Once the
# links are repointed, prune_old_trees removes superseded trees that no link
# selects and no live process uses.
# Usage: [PREFIX=$HOME/.local] [LOOM_CLIENT=bundled|slim] [LOOM_KEEP_OLD_TREES=1]
#   scripts/install.sh
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

# Collect what live processes use into $INUSE: every command line from ps, and
# every open file or working directory path from lsof when it is installed. The
# check is substring matching on the physical tree path, which the launchers
# always use. Returns non-zero when the evidence cannot be gathered, and the
# caller then deletes nothing: a missing answer must not read as "unused".
collect_in_use() {
  ps -axo command > "$INUSE" 2>/dev/null || return 1
  [ -s "$INUSE" ] || return 1
  command -v lsof >/dev/null 2>&1 || return 0
  # lsof exits 1 when it could not inspect some other user's process, which is
  # normal. Anything above 1 means it did not work.
  local status=0
  lsof -nP -w -F n >> "$INUSE" 2>/dev/null || status=$?
  [ "$status" -le 1 ] || return 1
  return 0
}

# Remove superseded release trees under $LIB for the stems this install
# repointed. Kept: the tree every link selects, the tree each repointed link
# selected before this install, and any tree a live process uses. Only real
# directories named exactly <stem>.<8 alphanumerics> qualify, so symlinks,
# legacy-backup.*, update.lock, and unrelated entries are never touched. This
# assumes no other install runs on the prefix at the same time: loom update
# serializes on update.lock, but a bare make install does not, and a tree being
# copied by a concurrent install looks unused until its link is switched.
prune_old_trees() {
  if [ "${LOOM_KEEP_OLD_TREES:-}" = 1 ]; then
    printf '%s\n' 'LOOM_KEEP_OLD_TREES=1: old release trees kept.'
    return 0
  fi
  INUSE="$LINKS/in-use.txt"
  if ! collect_in_use; then
    printf '%s\n' 'Could not inspect running processes; no old release trees pruned.'
    return 0
  fi
  local LC_COLLATE=C stem prev dir name keep link kib removed=0 freed=0
  for stem in server "$CLIENT_STEM"; do
    prev="$PREV_CLIENT"
    [ "$stem" != server ] || prev="$PREV_SERVER"
    for dir in "$LIB/$stem".*; do
      name="${dir##*/}"
      [ -d "$dir" ] && [ ! -L "$dir" ] || continue
      [[ "$name" =~ ^$stem\.[A-Za-z0-9]{8}$ ]] || continue
      keep=
      for link in server client tui; do
        if [ -L "$LIB/$link" ] && [ "$(readlink "$LIB/$link")" = "$dir" ]; then keep=1; fi
      done
      [ "$prev" != "$dir" ] || keep=1
      [ -z "$keep" ] || continue
      if grep -qF -- "$dir" "$INUSE"; then
        printf 'kept (in use): %s\n' "$dir"
        continue
      fi
      kib="$(du -sk "$dir" 2>/dev/null | cut -f1)"
      if rm -rf "$dir"; then
        printf 'removed: %s\n' "$dir"
        removed=$((removed + 1))
        freed=$((freed + ${kib:-0}))
      else
        printf 'could not remove: %s\n' "$dir"
      fi
    done
  done
  printf 'pruned %d old release trees, %d KiB freed\n' "$removed" "$freed"
}

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
# The trees the links select before this install are the one-step rollback and
# the likeliest to still be running, so pruning below keeps them.
PREV_SERVER="$(readlink "$LIB/server" 2>/dev/null || true)"
PREV_CLIENT="$(readlink "$LIB/$CLIENT_STEM" 2>/dev/null || true)"
switch_link "$SERVER_TREE" server
switch_link "$CLIENT_TREE" "$CLIENT_STEM"
# Rename complete scripts rather than truncating a launcher another process
# may still be reading. The other client shape's link and trees remain intact.
for launcher in loomd loom loom-profile; do
  mv -f "$WRAPPERS/$launcher" "$BIN/$launcher"
done
printf 'installed:\n  %s\n  %s\n  %s\n' "$BIN/loom" "$BIN/loomd" "$BIN/loom-profile"
printf 'release trees:\n  %s\n  %s\n' "$SERVER_TREE" "$CLIENT_TREE"
prune_old_trees
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) printf 'Add %s to PATH, or invoke the launchers there directly.\n' "$BIN" ;;
esac
CATALOGUE="${LOOM_STATE_DIR:-$HOME/.loom}/loom.toml"
if [ ! -f "$CATALOGUE" ]; then
  printf 'No catalogue at %s; docs/examples/loom.toml is a worked example.\n' "$CATALOGUE"
fi
