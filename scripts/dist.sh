#!/usr/bin/env bash
# Package the built release for download: one self-contained tarball for the
# server and its helper, one Erlang shipment tarball for the terminal client,
# and a SHA256SUMS over both.
#
#   scripts/dist.sh    # needs `make release` to have run
#
# Two downloads rather than one, and the split is on purpose. The server
# artifact is the BEAM runtime plus the kernel-enforcement helper, and it
# belongs where the repository and the jail are. `loom` is a client
# over the frozen gateway protocol; it belongs where the human is, which
# is routinely a different machine. Fusing them would also imply the two
# must match versions. The protocol being frozen is exactly the claim that
# they need not. The native client shipment carries its BEAM dependency
# closure, but not a second ERTS, so its host must provide compatible OTP.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

REL="$ROOT/build/release/loom"
[ -x "$REL/bin/loomd" ] || {
  echo "dist.sh: no release at $REL — run \`make release\` first" >&2; exit 1; }

VERSION="$(sed -n 's/^version *= *"\(.*\)"/\1/p' packages/client/gleam.toml | head -1)"

# The platform is a fact about the release tree, not a choice: the ERTS in
# it and the esqlite NIF beside it were both built here.
case "$(uname -s)" in
  Linux)  os=linux ;;
  Darwin) os=macos ;;
  *)      echo "dist.sh: no packaging for $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=x86_64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "dist.sh: no packaging for $(uname -m)" >&2; exit 1 ;;
esac
PLAT="$os-$arch"
SERVER_STEM="loomd-$VERSION-$PLAT"

DIST="$ROOT/dist"
rm -rf "$DIST"; mkdir -p "$DIST"

# tar's rename flags differ between GNU tar and bsdtar and this runs on
# both, so the directory is named by copying rather than by a flag.
STAGE="$ROOT/build/release/$SERVER_STEM"
rm -rf "$STAGE"
cp -a "$REL" "$STAGE"
tar -C "$ROOT/build/release" -czf "$DIST/$SERVER_STEM.tar.gz" "$SERVER_STEM"
rm -rf "$STAGE"

# The daemon archive must not carry a second `loom` command. Relx generates
# one internally, so release assembly removes it before this archive is made.
tar -tzf "$DIST/$SERVER_STEM.tar.gz" \
  | grep -Fx "$SERVER_STEM/bin/loomd" >/dev/null
if tar -tzf "$DIST/$SERVER_STEM.tar.gz" \
  | grep -Fx "$SERVER_STEM/bin/loom" >/dev/null; then
  echo "dist.sh: daemon archive shadows the client with bin/loom" >&2
  exit 1
fi

# Two client archives. The self-contained one is the download for a machine
# with no Erlang: the client release with its own ERTS, per-platform like the
# server. The slim one is the shipment a package manager that provides Erlang
# as a dependency wants; it carries no ERTS and so names no platform.
echo "==> packaging the native terminal client"
CLIENT_REL="$ROOT/build/release/loom-client"
[ -x "$CLIENT_REL/bin/loom" ] || {
  echo "dist.sh: no client release at $CLIENT_REL — run \`make release-client\` first" >&2
  exit 1; }
TUI_STEM="loom-$VERSION-$PLAT"
TUI_STAGE="$ROOT/build/release/$TUI_STEM"
rm -rf "$TUI_STAGE"
cp -a "$CLIENT_REL" "$TUI_STAGE"
tar -C "$ROOT/build/release" -czf "$DIST/$TUI_STEM.tar.gz" "$TUI_STEM"
rm -rf "$TUI_STAGE"

# The client is a tree, not a renamed standalone executable. Pin both halves
# of that contract in the archive so a packaging regression cannot publish a
# launcher whose runtime was omitted.
tar -tzf "$DIST/$TUI_STEM.tar.gz" \
  | grep -Fx "$TUI_STEM/bin/loom" >/dev/null
tar -tzf "$DIST/$TUI_STEM.tar.gz" \
  | grep -E "^$TUI_STEM/erts-[^/]+/bin/erl$" >/dev/null

echo "==> packaging the slim terminal client"
SLIM_STEM="loom-slim-$VERSION"
SLIM_STAGE="$ROOT/build/release/$SLIM_STEM"
rm -rf "$SLIM_STAGE"
mkdir -p "$SLIM_STAGE/bin" "$SLIM_STAGE/build"
cp "$ROOT/bin/loom" "$SLIM_STAGE/bin/loom"
cp -a "$ROOT/build/tui-erlang-shipment" "$SLIM_STAGE/build/tui-erlang-shipment"
tar -C "$ROOT/build/release" -czf "$DIST/$SLIM_STEM.tar.gz" "$SLIM_STEM"
rm -rf "$SLIM_STAGE"
tar -tzf "$DIST/$SLIM_STEM.tar.gz" \
  | grep -Fx "$SLIM_STEM/bin/loom" >/dev/null
tar -tzf "$DIST/$SLIM_STEM.tar.gz" \
  | grep -Fx "$SLIM_STEM/build/tui-erlang-shipment/entrypoint.sh" >/dev/null

# macOS ships `shasum` rather than `sha256sum`. The temp name keeps the
# manifest from listing itself.
SHA256=sha256sum
command -v sha256sum >/dev/null 2>&1 || SHA256="shasum -a 256"
( cd "$DIST" && $SHA256 ./* > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS )

echo
echo "dist/:"
( cd "$DIST" && du -h ./* | sed 's/^/  /' )
