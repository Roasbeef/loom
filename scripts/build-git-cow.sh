#!/usr/bin/env bash
# Build the pinned git-cow that a release ships beside loom-exec.
#
#   scripts/build-git-cow.sh <output>
#
# git-cow makes the copy-on-write copies of a project's template
# (docs/architecture/project-mode.md). Without it every worker clone and
# check tree is a plain recursive copy, which is correct and slower, so a
# release that did not ship it would be a release that quietly pays the
# slow price on every ticket. The server looks for it at `<root>/bin/git-cow`
# before it looks on PATH (client/install.gleam), so a release needs nothing
# installed on the machine that runs it.
#
# The source is fetched, not vendored. Building a release already needs the
# network for the Go module cache (the sandbox helper and the microVM
# launcher come from go.sum the same way), so a fetch adds no new
# requirement, and a vendored copy would be a second place a security fix
# has to land. What makes the fetch safe is the pin: an exact commit, and the
# module hash (`h1:`) of the source tree at that commit, which this script
# compares with the hash Go computed for what it downloaded. Go also checks
# the download against the public checksum database, so a changed upstream
# tag or a changed proxy answer is refused twice.
#
# To move the pin: set GIT_COW_COMMIT to the new commit, run this script, and
# put the `Sum` it prints into GIT_COW_SUM. The review is of the diff between
# the two commits in the git-cow repository.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: build-git-cow.sh <output>" >&2; exit 1; }
command -v go >/dev/null || { echo "build-git-cow.sh: go is not on PATH (need >= 1.26)" >&2; exit 1; }

# The module path is the lower-case one its go.mod declares. The repository's
# address on GitHub is Roasbeef/git-cow, and GitHub ignores case, but the Go
# module proxy does not, and a request for the capitalised path is refused
# because the module says it is the lower-case one.
GIT_COW_MODULE="github.com/roasbeef/git-cow"
GIT_COW_COMMIT="186b2e6f5c8970e30508196b97e7746581ff0700"
GIT_COW_SUM="h1:Lo7cR7htAysf+gWbiT36pzuPxnJ0lgSxqfxdGF9yLAg="

output="$1"
case "$output" in /*) ;; *) output="$PWD/$output" ;; esac
mkdir -p "$(dirname "$output")"

# Nothing here may read or write a go.mod of this repository, so the download
# and the build both run from a scratch directory.
work="$(mktemp -d "${TMPDIR:-/var/tmp}/git-cow-build.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cd "$work"

sum="$(go mod download -json "$GIT_COW_MODULE@$GIT_COW_COMMIT" | sed -n 's/^[[:space:]]*"Sum": "\(.*\)",\{0,1\}$/\1/p')"
if [ "$sum" != "$GIT_COW_SUM" ]; then
  echo "build-git-cow.sh: the source at $GIT_COW_COMMIT hashes to" >&2
  echo "  ${sum:-<nothing>}" >&2
  echo "  but the pin is $GIT_COW_SUM. Refusing to build." >&2
  exit 1
fi

# Same flags as scripts/go-build.sh, for the same reasons: -trimpath removes
# the build directory from the binary and -s -w drops symbols nothing reads.
GOBIN="$work/bin" go install -trimpath -ldflags="-s -w" "$GIT_COW_MODULE/cmd/git-cow@$GIT_COW_COMMIT"
install -m 0755 "$work/bin/git-cow" "$output"
echo "built $output from $GIT_COW_MODULE@${GIT_COW_COMMIT:0:12}"
