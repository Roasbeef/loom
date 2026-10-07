#!/usr/bin/env bash
# signoff_remote.sh — run scripts/signoff.sh for HEAD on another machine.
#
# Usage: LOOM_SIGNOFF_HOST=<ssh destination> scripts/signoff_remote.sh [--dry-run]
#        LOOM_SIGNOFF_UNGATED=1 LOOM_SIGNOFF_HOST=<ssh destination> scripts/signoff_remote.sh [signoff.sh args]
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
#
# --- The gate runs in a fresh container, and only there ---
#
# Every run happens inside a new container, and the working tree it runs
# in is cloned inside that container. There is no bare-checkout mode: a
# verdict from a tree that persists between runs is one this script will
# not produce.
#
# Why a fresh tree. $LOOM_SIGNOFF_DIR persists between runs by design (it
# is cloned once and re-fetched), so anything a run leaves behind under it
# — a shipment directory, a stale build/ tree — is state the next run
# inherits. On PR #378 (2026-09-13) that state was
# packages/tui/build/erlang-shipment from an earlier run, and the next
# run's shipment step refused to overwrite it, going red in prep before a
# single lane even started. The container removes the possibility by
# construction rather than by cleaning up harder: the checkout is only the
# fetch-and-build source, mounted read-only, and the gate runs in a clone
# the container makes on its own filesystem at /work.
#
# Why the tree lives inside the container. The container runs as root (see
# the flags below), so everything a run builds — build/, bin/, the
# code-mode seed, the TUI shipment — is owned by root. These trees used to
# be cloned on the host under $HOME/loom-signoff-container/runs and bind
# mounted in, and the login account that ran this script could not delete
# what root had written there. Its prune failed quietly, and on 2026-10-04
# 289 run directories (214 GB) had filled the host's disk until a signoff
# failed at `git checkout` with "No space left on device". A tree on the
# container's own filesystem is removed by `docker run --rm` with the
# container, so nothing accumulates and nothing needs pruning.
#
# What persists across runs, and only this: two named Docker volumes, for
# the Hex/gleam package cache and the Go module cache (see
# scripts/signoff/Dockerfile's own comment on GOMODCACHE and the gleam
# cache directory). Both are content-addressed and checksummed against
# committed manifests (packages/*/manifest.toml for Hex, go.sum for Go), so
# a warm volume cannot serve a run different bytes than a cold fetch would;
# it can only save the fetch. Skipping them would mean resolving every
# dependency from cold on every run, which is exactly the burst that trips
# Hex's per-address rate limit (issue #248) within minutes; see
# .github/scripts/hex_retry.sh's own comment for the incident that proved
# it under seven lanes sharing one address.
#
# The host keeps one more thing per commit: $HOME/loom-signoff-container/
# logs/<sha>, mounted at /logs. It holds the image build log, the signoff
# log, and a copy of the lanes' own logs, which the container hands back to
# the login account before it exits so the host can always delete them.
#
# The image (scripts/signoff/Dockerfile) is built from this checkout's
# own copy of that file at the commit under test, so a Dockerfile change
# on the branch under test takes effect on the very next run; Docker's
# layer cache still makes an unchanged image instant.
#
# Container flags, and why each is there (measured on the box this
# shipped against: Ubuntu 22.04, kernel 5.15, Docker 23.0.1 with the
# systemd cgroup driver — a different box may need fewer, or more):
#
#   --cgroupns=host                 the container shares the host's
#                                    cgroup v2 tree instead of a private
#                                    view, which is the only way the
#                                    fork-bomb probe's delegated base
#                                    (created inside the container,
#                                    below) is the same cgroup tree
#                                    loom-exec's pids/memory ceilings
#                                    actually apply to.
#   --cap-add SYS_ADMIN              bwrap creates user, mount and PID
#                                    namespaces and mounts a fresh procfs
#                                    inside them (packages/sandbox/CLAUDE.md:
#                                    "bwrap owns all namespace and mount
#                                    work"); Docker's default capability
#                                    set refuses the nested mount(2)
#                                    calls that takes.
#   --security-opt seccomp=unconfined
#                                    loom-exec installs its own seccomp
#                                    filter inside the jail (the
#                                    network-off enforcement); Docker's
#                                    default filter blocks some of the
#                                    namespace and mount syscalls bwrap
#                                    issues before that filter is even
#                                    installed.
#   --security-opt apparmor=unconfined
#                                    Docker's default AppArmor profile
#                                    denies mount operations regardless
#                                    of capabilities held — the same
#                                    class of restriction ci.yml's
#                                    jail-linux job lifts on the bare
#                                    runner via
#                                    apparmor_restrict_unprivileged_userns.
#   --security-opt systempaths=unconfined
#                                    without it /sys/fs/cgroup stays
#                                    mounted read-only inside the
#                                    container regardless of the flags
#                                    above, and the delegated base below
#                                    can never be created.
#
# What was tried and turned out not to be necessary: --privileged (works,
# but is strictly broader than the five flags above, which were arrived
# at by removing flags from a working --privileged run one at a time and
# re-measuring the self-test each time); --cgroup-parent, to place the
# container under a pre-delegated cgroup the way ci.yml's jail-linux job
# delegates one on the bare runner. This box's Docker uses the systemd
# cgroup driver, which refuses a --cgroup-parent that is not itself a
# bare *.slice name, and there is no unprivileged way to create one of
# those here (no passwordless sudo). Running the container as root sides
# steps the problem instead: root can remount and populate a cgroup base
# directly, which is not a shortcut around cgroup v2's no-internal-
# -process rule, only around the *unprivileged* case of it that
# signoff.sh's own systemd-run delegation dance exists to solve on the
# bare-metal path.
#
# What the container cannot be told to do is post the signoff verdict.
# `gh signoff` needs a GitHub token, and the arrangement that keeps
# credentials out of the image is to keep `gh` out of the image
# entirely: the container always runs signoff.sh with --dry-run, and
# the driver (scripts/signoff/driver.sh) posts the verdict itself
# afterward, from the remote host's own already-authenticated `gh`, using
# the container's exit code. That reproduces signoff.sh's own two-line
# posting stanza rather than extending signoff.sh to skip it
# conditionally, which would mean touching the lanes file this change was
# scoped to leave alone.
#
# --- A gated host, which is the default ---
#
# Sending the driver means the ssh key that runs a signoff can run
# anything at all on the box, which is right for a developer's own login
# and wrong for a key handed to agents. So by default this script sends
# only `signoff <sha> [--dry-run] [--parallel N]`, to a host whose key is
# pinned to scripts/signoff/gate.sh, which reads that request as data and
# runs an installed copy of the same driver; gate.sh says what such a key
# does and does not bound, and how a host is set up for it.
#
# LOOM_SIGNOFF_UNGATED=1 sends the driver from this checkout instead, to
# an ordinary login. That is for a change to driver.sh itself, which a
# gated host runs only once it is installed there; a pinned key refuses
# the driver protocol, so the opt-in grants an agent holding one nothing.
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

# Posting happens outside signoff.sh (see the block comment above), so
# this side needs to know, from the caller's own args, whether this run
# intends to post at all and where. signoff.sh's own case statement is
# still the one authority on which flags are valid; this only ever reads
# the two that change what happens after the container exits.
post=yes
url=""
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
	case ${args[$i]} in
	--dry-run) post=no ;;
	--url)
		i=$((i + 1))
		url=${args[$i]:-}
		;;
	esac
	i=$((i + 1))
done

# A gated host (scripts/signoff/gate.sh) takes no script, only a request
# it can read as data, so this side sends the commit and the two knobs the
# gate accepts and nothing else. The gate takes no details link, so asking
# for one is refused here rather than dropped on the way.
if [ -z "${LOOM_SIGNOFF_UNGATED:-}" ]; then
	if [ -n "$url" ]; then
		echo "signoff_remote: a gated host takes no --url" >&2
		exit 2
	fi
	request="signoff $sha"
	if [ "$post" = no ]; then request="$request --dry-run"; fi
	if [ -n "${SIGNOFF_PARALLEL:-}" ]; then request="$request --parallel $SIGNOFF_PARALLEL"; fi
	exec ssh "$host" "$request" </dev/null
fi

# The driver (scripts/signoff/driver.sh) is sent as it is in this
# checkout and read by `bash -s`, so nothing in it is touched by this
# local shell and every $VAR in it is resolved once, remotely, at run
# time. The handful of values this side actually knows — the checkout
# directory, the origin URL, the commit, whether to post and where —
# travel as environment variables instead of being spliced into the text,
# which is what keeps a path or URL with a shell-special character in it
# from corrupting the script it lands in.
exec ssh "$host" "env $(printf 'LOOM_DIR=%q ' "$dir")$(printf 'LOOM_ORIGIN=%q ' "$origin")$(printf 'LOOM_SHA=%q ' "$sha")$(printf 'LOOM_POST=%q ' "$post")$(printf 'LOOM_URL=%q ' "$url")${SIGNOFF_PARALLEL:+$(printf 'LOOM_PARALLEL=%q ' "$SIGNOFF_PARALLEL")}bash -lc 'exec bash -s'" <"$root/scripts/signoff/driver.sh"
