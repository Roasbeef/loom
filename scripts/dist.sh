#!/usr/bin/env bash
# Package the built release for download: one self-contained tarball for the
# server and its helper, one Erlang shipment tarball for the terminal client,
# and a SHA256SUMS over both.
#
#   scripts/dist.sh    # needs `make release` to have run
#
# Two downloads rather than one, and the split is on purpose. The server
# artifact is the BEAM runtime plus the kernel-enforcement helper, and it
# belongs where the repository and the jail are. `loom-tui` is a client
# over the frozen gateway protocol; it belongs where the human is, which
# is routinely a different machine. Fusing them would also imply the two
# must match versions. The protocol being frozen is exactly the claim that
# they need not. The native client shipment carries its BEAM dependency
# closure, but not a second ERTS, so its host must provide compatible OTP.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

REL="$ROOT/build/release/loom"
[ -x "$REL/bin/loom" ] || {
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
STEM="loom-$VERSION-$PLAT"

DIST="$ROOT/dist"
rm -rf "$DIST"; mkdir -p "$DIST"

# tar's rename flags differ between GNU tar and bsdtar and this runs on
# both, so the directory is named by copying rather than by a flag.
STAGE="$ROOT/build/release/$STEM"
rm -rf "$STAGE"
cp -a "$REL" "$STAGE"
tar -C "$ROOT/build/release" -czf "$DIST/$STEM.tar.gz" "$STEM"
rm -rf "$STAGE"

echo "==> packaging the native terminal client"
TUI_STEM="loom-tui-$VERSION-$PLAT"
TUI_STAGE="$ROOT/build/release/$TUI_STEM"
rm -rf "$TUI_STAGE"
mkdir -p "$TUI_STAGE/bin" "$TUI_STAGE/build"
cp "$ROOT/bin/loom-tui" "$TUI_STAGE/bin/loom-tui"
cp -a "$ROOT/build/tui-erlang-shipment" "$TUI_STAGE/build/tui-erlang-shipment"
tar -C "$ROOT/build/release" -czf "$DIST/$TUI_STEM.tar.gz" "$TUI_STEM"
rm -rf "$TUI_STAGE"

# The client is a tree, not a renamed standalone executable. Pin both halves
# of that contract in the archive so a packaging regression cannot publish a
# launcher whose shipment was omitted.
tar -tzf "$DIST/$TUI_STEM.tar.gz" \
  | grep -Fx "$TUI_STEM/bin/loom-tui" >/dev/null
tar -tzf "$DIST/$TUI_STEM.tar.gz" \
  | grep -Fx "$TUI_STEM/build/tui-erlang-shipment/entrypoint.sh" >/dev/null

# macOS ships `shasum` rather than `sha256sum`. The temp name keeps the
# manifest from listing itself.
SHA256=sha256sum
command -v sha256sum >/dev/null 2>&1 || SHA256="shasum -a 256"
( cd "$DIST" && $SHA256 ./* > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS )

echo
echo "dist/:"
( cd "$DIST" && du -h ./* | sed 's/^/  /' )
