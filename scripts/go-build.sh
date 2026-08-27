#!/usr/bin/env bash
# Build one of Loom's Go binaries with the flags every caller must use.
#
#   scripts/go-build.sh <module-dir> <package> <output>
#
# One script rather than a flag list repeated in the Makefile and the
# release script, because the flags are load-bearing: `make selftest` and
# `make e2e` probe the helper they build, `make dist` ships the helper it
# builds, and those two are only the same evidence if they are the same
# bytes. `-trimpath` removes the build directory from the binary, which is
# what makes that reproducible off one machine; `-s -w` drops the symbol
# table and DWARF, about a third of each binary, and neither is read at
# runtime — Go's panics come from its own tables, not from ELF.
set -euo pipefail

[ $# -eq 3 ] || { echo "usage: go-build.sh <module-dir> <package> <output>" >&2; exit 1; }
command -v go >/dev/null || { echo "go-build.sh: go is not on PATH (need >= 1.24)" >&2; exit 1; }

module="$1"; package="$2"; output="$3"
case "$output" in /*) ;; *) output="$PWD/$output" ;; esac
mkdir -p "$(dirname "$output")"
cd "$module"
exec go build -trimpath -ldflags="-s -w" -o "$output" "$package"
