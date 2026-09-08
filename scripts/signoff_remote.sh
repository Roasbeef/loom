#!/usr/bin/env bash
# signoff_remote.sh — run scripts/signoff.sh for HEAD on another machine.
#
# Usage: LOOM_SIGNOFF_HOST=<ssh destination> scripts/signoff_remote.sh [signoff.sh args]
#
# The host comes only from the environment. Which box runs a developer's
# Linux lane is that developer's business, not the repository's, so
# nothing here names one: LOOM_SIGNOFF_HOST is an ssh alias or user@host
# from the caller's own ssh config, and LOOM_SIGNOFF_DIR (default
# `loom-signoff`, relative to the remote home) is a checkout this script
# owns. Owning it matters: the run detaches that checkout at the commit
# under test, which would move HEAD out from under anyone working in it,
# so it is never the developer's own clone. The directory is cloned on
# first use, from the same remote this checkout's `origin` points at, and
# never under /tmp — code mode refuses a cap socket there, because the
# jail replaces /tmp with the scratch tmpfs.
#
# HEAD must already be on that remote, in whatever ref: the box fetches
# by SHA, and `gh signoff` will refuse to sign a commit no remote holds.
#
# SIGNOFF_PARALLEL travels with the run. It is the one knob signoff.sh
# reads from the environment, and a sequential run is how a failure is
# told apart from a concurrency effect, so leaving it behind on this side
# of the ssh session would make that distinction unavailable remotely.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

host=${LOOM_SIGNOFF_HOST:?set LOOM_SIGNOFF_HOST to an ssh destination (an alias from your ssh config, or user@host)}
dir=${LOOM_SIGNOFF_DIR:-loom-signoff}
sha=$(git -C "$root" rev-parse HEAD)
origin=$(git -C "$root" remote get-url origin)

if [ -z "$(git -C "$root" branch -r --contains "$sha")" ]; then
	echo "signoff_remote: $sha is on no remote branch; push first" >&2
	exit 2
fi

# A login shell, because a non-interactive ssh session has the bare
# system PATH and the toolchain usually lives under the user's own
# directories. The remote body is one string so a failure anywhere in it
# is the exit status ssh returns.
remote=$(
	cat <<EOF
set -euo pipefail
if [ ! -d "$dir/.git" ]; then git clone --quiet "$origin" "$dir"; fi
cd "$dir"
git fetch --quiet origin "$sha"
git checkout --quiet --detach "$sha"
exec env ${SIGNOFF_PARALLEL:+SIGNOFF_PARALLEL="$SIGNOFF_PARALLEL"} scripts/signoff.sh --commit "$sha" $*
EOF
)
exec ssh "$host" "bash -lc $(printf '%q' "$remote")"
