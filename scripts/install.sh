#!/usr/bin/env bash
# Install Loom for the person at this keyboard: the self-contained server
# release, the native terminal client, and two launchers on PATH, so that
# typing `loom` in any directory opens the shared daemon's session picker.
#
#   scripts/install.sh                   # into $HOME/.local (bin/, lib/loom/)
#   PREFIX=/usr/local scripts/install.sh
#   LOOM_CLIENT=slim scripts/install.sh  # the client on the host's Erlang
#
# `make install` runs the builds first — the code-mode seed, the server
# release, a client — and then this. Nothing here reaches the network.
#
# What lands where, and why each is where it is:
#
#   $PREFIX/lib/loom/server-<version>   a copy of build/release/loom: bin/loomd,
#                                       bin/loom-exec, bin/gleam,
#                                       share/codemode-seed, the bundled ERTS.
#                                       The server finds its helper, its
#                                       compiler and its seed through
#                                       `code:root_dir()` — the release root —
#                                       so the tree must stay whole and is
#                                       copied whole.
#   $PREFIX/lib/loom/server             a symlink to server-<version>. A running
#                                       daemon is pinned to the physical tree it
#                                       started from, because the release's own
#                                       launcher resolves its root with `pwd -P`
#                                       (scripts/release.sh) and so never
#                                       follows this link after boot. Installing
#                                       a new version therefore never mutates a
#                                       tree a live daemon is still reading from.
#   $PREFIX/lib/loom/client-<version>   LOOM_CLIENT=bundled (the default): a copy
#   $PREFIX/lib/loom/client             of build/release/loom-client, the client
#                                       with its own ERTS, so `loom` needs no
#                                       Erlang on the host; the symlink names
#                                       the installed version.
#   $PREFIX/lib/loom/tui-<version>      LOOM_CLIENT=slim: a copy of
#   $PREFIX/lib/loom/tui                build/tui-erlang-shipment. Compiled BEAM
#                                       files, no runtime: the client runs on
#                                       the `erl` on PATH. This is the shape a
#                                       package manager that provides Erlang as
#                                       a dependency wants; the two shapes never
#                                       coexist.
#   $PREFIX/bin/loom                    the client launcher, generated here
#                                       rather than copied, because a
#                                       checkout's bin/loom names its shipment
#                                       relative to itself and a release's names
#                                       its own tree.
#   $PREFIX/bin/loomd                   a wrapper that execs the release's own
#                                       bin/loomd, through the server symlink.
#                                       Not a symlink itself: that script
#                                       resolves the release root from its own
#                                       location with `pwd -P`, which lands it on
#                                       the physical server-<version> directory
#                                       rather than on $PREFIX. The client looks
#                                       for the server beside itself before
#                                       PATH, which is why the two share a
#                                       directory.
#
# Both wrappers export the build identity (`LOOM_BUILD_VERSION`,
# `LOOM_BUILD_COMMIT`) so the running binary can report which build it is; the
# values are baked in here rather than read at run time, so a launcher keeps
# working in a tree with no git checkout and no `git` on PATH.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
CLIENT="${LOOM_CLIENT:-bundled}"
case "$CLIENT" in
  bundled|slim) ;;
  *) echo "install.sh: LOOM_CLIENT must be bundled or slim, got $CLIENT" >&2; exit 1 ;;
esac

# The version is read here, from the same files scripts/release.sh and
# scripts/release-client.sh read, rather than passed in by the Makefile. The
# installer then names the on-disk directory itself, so a release rebuilt at a
# new version always lands in a directory that did not exist before, which is
# what lets the switch below be a rename rather than an in-place mutation.
version_of() {
  sed -n 's/^version *= *"\(.*\)"/\1/p' "$1" | head -1
}
SERVER_VERSION="$(version_of packages/client/gleam.toml)"
CLIENT_VERSION="$(version_of packages/tui/gleam.toml)"
[ -n "$SERVER_VERSION" ] || {
  echo "install.sh: no version in packages/client/gleam.toml" >&2; exit 1; }
[ -n "$CLIENT_VERSION" ] || {
  echo "install.sh: no version in packages/tui/gleam.toml" >&2; exit 1; }

# `unknown` rather than an empty string, so a launcher built from a tarball
# still says honestly which half of its identity it lacks. The `||` is what
# keeps a tree with no git metadata from failing the install under `set -e`.
BUILD_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

REL="$ROOT/build/release/loom"
CLIENT_REL="$ROOT/build/release/loom-client"
TUI="$ROOT/build/tui-erlang-shipment"
[ -x "$REL/bin/loomd" ] || {
  echo "install.sh: no release at $REL — run \`make release\` first" >&2; exit 1; }
[ -x "$REL/bin/loom-exec" ] || {
  echo "install.sh: the release at $REL has no bin/loom-exec" >&2; exit 1; }
[ -d "$REL/share/codemode-seed" ] || {
  echo "install.sh: the release at $REL carries no code-mode seed;" >&2
  echo "install.sh: build it with \`make codemode-seed release\`" >&2; exit 1; }
case "$CLIENT" in
  bundled) [ -x "$CLIENT_REL/bin/loom" ] || {
    echo "install.sh: no client release at $CLIENT_REL — run \`make release-client\` first" >&2
    exit 1; } ;;
  slim) [ -f "$TUI/entrypoint.sh" ] || {
    echo "install.sh: no client shipment at $TUI — run \`make tui-shipment\` first" >&2
    exit 1; } ;;
esac

LIB="$PREFIX/lib/loom"
BIN="$PREFIX/bin"
mkdir -p "$LIB" "$BIN"

# ------------------------------------------------------------------ liveness
#
# Everything below that removes or replaces a directory consults this. The
# discovery record at ${LOOM_STATE_DIR:-$HOME/.loom}/daemon.endpoint names the
# running daemon's PID, and a PID the kernel says is alive is enough to stop
# deleting trees. It is deliberately a *stop*, never a proof: a shell cannot
# ask which directory that PID was rooted in. `lsof` is not portable to every
# host this installs on, and even where it exists its answer is a snapshot
# rather than a guarantee. So the record is read for the one fact it carries,
# and anything it cannot rule out keeps its tree.
ENDPOINT="${LOOM_STATE_DIR:-$HOME/.loom}/daemon.endpoint"
LIVE=0
LIVE_PID=""
if [ -f "$ENDPOINT" ] && [ -r "$ENDPOINT" ]; then
  LIVE_PID="$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$ENDPOINT" | head -1)"
fi

# A PID from the record is only evidence of life if it is not this process;
# otherwise the record is stale text and there is nothing to protect.
if [ -n "$LIVE_PID" ] && [ "$LIVE_PID" != "$$" ] && kill -0 "$LIVE_PID" 2>/dev/null; then
  LIVE=1
fi

# The link switch: build the new link under a temporary name in the same
# directory and rename it over the old one. `rename(2)` is atomic, so a reader
# resolves either the old target or the new one and never an absent link;
# deleting the link first and re-creating it would leave exactly that window,
# and a daemon or client starting inside it would fail to find the tree it was
# pointed at.
#
# `mv` has to be told not to dereference the destination: `-T` on GNU, `-h` on
# BSD/macOS. Without that, a *symlink* destination pointing at a directory is
# treated as that directory, and the temporary link is moved inside the old
# tree instead of replacing it. There is no `-T` on macOS, so the second form
# is what runs there; the first is tried and falls through quietly so one
# script serves both. A destination that is a real directory — the pre-versioned
# layout this script replaces — cannot be swapped by either flag, so it is
# renamed aside first by `preserve_legacy` below.
switch_link() {
  target="$1"
  link="$2"
  tmp="$link.new.$$"
  rm -f "$tmp"
  ln -s "$target" "$tmp"
  if ! mv -T -f "$tmp" "$link" 2>/dev/null; then
    if ! mv -h -f "$tmp" "$link" 2>/dev/null; then
      rm -f "$tmp"
      echo "install.sh: could not switch $link to $target" >&2
      exit 1
    fi
  fi
}

# A `$LIB/server` (or client, or tui) that is a real directory predates this
# script's versioned layout: it is the tree an earlier install copied in place.
# A live daemon may be rooted in it, so where one might be the directory is
# *renamed*, which keeps the tree readable by that daemon through the path it
# already resolved; where none can be, it is simply removed. Renaming is the
# whole trick: `mv` on a directory does not disturb a process whose root path
# was resolved before the rename.
preserve_legacy() {
  path="$1"
  if [ -e "$path" ] && [ ! -L "$path" ]; then
    if [ "$LIVE" = 1 ]; then
      rm -rf "$path-legacy"
      mv "$path" "$path-legacy"
      echo "install.sh: renamed $path to $path-legacy (a daemon may be using it)"
    else
      rm -rf "$path"
    fi
  fi
}

# One installed version directory, named so a reader of `ls` sees the layout
# without resolving anything. The copy is staged under a temporary name and
# renamed into place, so a copy interrupted half-way never becomes the tree a
# symlink points at. A directory that is already there is only replaced when no
# daemon can be live from it: a release is normally installed once per version,
# and the same-version case is the `make install` re-run after a rebuild.
install_version() {
  src="$1"
  dir="$2"
  version="$3"
  dest="$dir-$version"
  if [ -e "$dest" ] && [ "$LIVE" = 1 ]; then
    echo "install.sh: $dest exists and a daemon may be using it; leaving it in place"
    return 0
  fi
  staging="$dir-staging.$$"
  rm -rf "$staging"
  cp -R "$src" "$staging"
  if [ -e "$dest" ]; then
    # No daemon we can rule in is reading it, so the tree can be swapped. The
    # two renames leave a brief window with no `$dest`; that is the case the
    # version in the directory name exists to avoid, and a same-version
    # reinstall is the one time it cannot be avoided for a directory, which
    # cannot be replaced in a single syscall.
    replaced="$dir-replaced.$$"
    rm -rf "$replaced"
    mv "$dest" "$replaced"
    mv "$staging" "$dest"
    rm -rf "$replaced"
  else
    mv "$staging" "$dest"
  fi
}

# The link's current target, read *before* any switch. That target is the
# version a daemon started by the previous install may still be running from,
# and so it is the one the prune below must keep; once the link names the new
# version, the old one is no longer discoverable through it.
previous_target() {
  readlink "$1" 2>/dev/null || true
}

case "$CLIENT" in
  bundled) CLIENT_STEM="client" ;;
  slim)    CLIENT_STEM="tui" ;;
esac
PREV_SERVER="$(previous_target "$LIB/server")"
PREV_CLIENT="$(previous_target "$LIB/$CLIENT_STEM")"

# The launchers on PATH are regular files written in place. That is safe where
# a tree is not: each is exec'd once and is gone from the filesystem's
# perspective by the time its daemon or client is running, so rewriting it
# never changes what a live process is executing.
case "$CLIENT" in
  bundled) preserve_legacy "$LIB/client" ;;
  slim)    preserve_legacy "$LIB/tui" ;;
esac
preserve_legacy "$LIB/server"

install_version "$REL" "$LIB/server" "$SERVER_VERSION"

cat > "$BIN/loomd" <<EOF
#!/bin/sh
# Generated by scripts/install.sh. Execs the installed Loom multi-session daemon.
# The release's own launcher resolves its root with \`pwd -P\`, so this reaches
# the physical server-$SERVER_VERSION directory and stays there for the life of
# the process, even if the server symlink is later switched to another version.
LOOM_BUILD_VERSION="$SERVER_VERSION"
LOOM_BUILD_COMMIT="$BUILD_COMMIT"
export LOOM_BUILD_VERSION LOOM_BUILD_COMMIT
exec "$LIB/server/bin/loomd" "\$@"
EOF
chmod +x "$BIN/loomd"

# LOOM_EXECUTABLE is how the client knows where it is, and so where to look for
# loomd beside itself; both launchers set it to the wrapper on PATH before
# handing off, so the sibling lookup lands in $PREFIX/bin.
case "$CLIENT" in
  bundled)
    install_version "$CLIENT_REL" "$LIB/client" "$CLIENT_VERSION"
    cat > "$BIN/loom" <<EOF
#!/bin/sh
# Generated by scripts/install.sh. The Loom terminal client, self-contained.
set -eu
LOOM_BUILD_VERSION="$CLIENT_VERSION"
LOOM_BUILD_COMMIT="$BUILD_COMMIT"
export LOOM_BUILD_VERSION LOOM_BUILD_COMMIT
LOOM_EXECUTABLE="$BIN/loom"
export LOOM_EXECUTABLE
exec "$LIB/client/bin/loom" "\$@"
EOF
    ;;
  slim)
    # The same launcher `make tui-shipment` writes into bin/loom, anchored to
    # the installed shipment. No ERTS travels with it, so a compatible
    # Erlang/OTP must be on PATH. The glob expands through the tui symlink to
    # the physical tui-$CLIENT_VERSION directory, which is where the ebin files
    # actually are.
    install_version "$TUI" "$LIB/tui" "$CLIENT_VERSION"
    cat > "$BIN/loom" <<EOF
#!/bin/sh
# Generated by scripts/install.sh. The Loom terminal client, on the host's Erlang.
set -eu
LOOM_BUILD_VERSION="$CLIENT_VERSION"
LOOM_BUILD_COMMIT="$BUILD_COMMIT"
export LOOM_BUILD_VERSION LOOM_BUILD_COMMIT
LOOM_EXECUTABLE="$BIN/loom"
export LOOM_EXECUTABLE
exec erl +Bd -pa "$LIB/tui"/*/ebin -eval 'tui@@main:run(tui)' -noshell -extra "\$@"
EOF
    ;;
esac
chmod +x "$BIN/loom"

# Point the symlinks at the new trees, and only now, with the copy complete and
# renamed into place. Switching before the copy finished would publish a tree
# that is still being written.
switch_link "server-$SERVER_VERSION" "$LIB/server"
switch_link "$CLIENT_STEM-$CLIENT_VERSION" "$LIB/$CLIENT_STEM"

# Prune old version directories, on the one rule a shell script can apply
# soundly: keep the version each symlink now points at and the version it
# pointed at immediately before, and delete only what is older. The previous
# version is kept because a daemon started before this install may still be
# running from it, and a stale directory costs disk while deleting a live tree
# is the failure this whole layout exists to prevent. A whole-install skip is
# taken when a daemon is recorded alive: see the limitation above, where the
# rule is to keep everything rather than guess which tree a PID is rooted in.
prune_versions() {
  stem="$1"
  want="$2"
  prev="$3"
  for d in "$LIB/$stem"-*; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    case "$name" in
      "$stem"-staging.*) continue ;;      # a copy this run, or a crash, left behind
      "$stem"-replaced.*) continue ;;     # the same, for a swapped-in tree
      "$stem"-legacy) continue ;;         # a pre-versioned tree, never ours to delete
      "$stem"-[0-9]*) ;;                  # a version directory: the only candidate
      *) continue ;;                      # anything else is not ours to remove
    esac
    if [ "$name" = "$stem-$want" ]; then continue; fi
    if [ -n "$prev" ] && [ "$name" = "$prev" ]; then continue; fi
    echo "install.sh: removing old version $name"
    rm -rf "$d"
  done
}

if [ "$LIVE" = 1 ]; then
  echo "install.sh: a daemon (pid $LIVE_PID) may still be running; keeping all installed versions"
else
  prune_versions server "$SERVER_VERSION" "$PREV_SERVER"
  prune_versions "$CLIENT_STEM" "$CLIENT_VERSION" "$PREV_CLIENT"
fi

# The two client shapes never coexist, so the other shape's symlink and version
# directories go. Only the symlink and its own trees are touched: the previous
# shape's version may be what a running client is reading from, so this is
# skipped entirely under the same liveness rule the prune above uses.
if [ "$LIVE" != 1 ]; then
  case "$CLIENT" in
    bundled) OTHER_STEM="tui" ;;
    slim)    OTHER_STEM="client" ;;
  esac
  rm -f "$LIB/$OTHER_STEM"
  prune_versions "$OTHER_STEM" "" ""
fi

echo "installed:"
case "$CLIENT" in
  bundled) echo "  $BIN/loom            the terminal client (self-contained)" ;;
  slim)    echo "  $BIN/loom            the terminal client (needs erl on PATH)" ;;
esac
echo "  $BIN/loomd           the multi-session daemon (self-contained)"
echo "  $LIB/server-$SERVER_VERSION"
echo "                       release: helper, gleam, code-mode seed, ERTS"
echo "  $LIB/server          a symlink to that version"
case "$CLIENT" in
  bundled)
    echo "  $LIB/client-$CLIENT_VERSION"
    echo "                       client release with its own ERTS"
    echo "  $LIB/client          a symlink to that version" ;;
  slim)
    echo "  $LIB/tui-$CLIENT_VERSION"
    echo "                       client shipment"
    echo "  $LIB/tui             a symlink to that version" ;;
esac
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo
     echo "note: $BIN is not on PATH; add it, or run $BIN/loom directly" ;;
esac
CATALOGUE="${LOOM_STATE_DIR:-$HOME/.loom}/loom.toml"
if [ ! -f "$CATALOGUE" ]; then
  echo
  echo "note: no catalogue at $CATALOGUE; the launcher uses it when present."
  echo "      docs/examples/loom.toml is the worked example to start from."
fi
