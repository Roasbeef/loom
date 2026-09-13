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
#
# --- LOOM_SIGNOFF_CONTAINER=1: run the gate inside a fresh container ---
#
# Why. $LOOM_SIGNOFF_DIR persists between runs by design (it is cloned
# once and re-fetched), so anything a run leaves behind under it — a
# shipment directory, a stale build/ tree — is state the next run
# inherits. On PR #378 (2026-09-13) that state was
# packages/tui/build/erlang-shipment from an earlier run, and the next
# run's shipment step refused to overwrite it, going red in prep before a
# single lane even started. Opting into a container removes the
# possibility by construction rather than by cleaning up harder: the
# working tree the gate actually runs in is a brand-new directory, on a
# brand-new local clone, every single time — the checkout above is used
# only as the fetch-and-build source, never as the tree the gate runs in.
#
# What persists across a containerised run, and only this: two named
# Docker volumes, for the Hex/gleam package cache and the Go module
# cache (see scripts/signoff/Dockerfile's own comment on GOMODCACHE and
# the gleam cache directory). Both are content-addressed and checksummed
# against committed manifests (packages/*/manifest.toml for Hex, go.sum
# for Go), so a warm volume cannot serve a run different bytes than a
# cold fetch would — it can only save the fetch. Skipping them would mean
# resolving every dependency from cold on every run, which is exactly
# the burst that trips Hex's per-address rate limit (issue #248) within
# minutes; see .github/scripts/hex_retry.sh's own comment for the
# incident that proved it under seven lanes sharing one address.
#
# Everything else — the checkout, build/, bin/, the code-mode seed,
# packages/tui/build/erlang-shipment, the shipped server — lives in a
# working tree cloned fresh into a directory this run alone creates.
# Nothing about a previous run's tree is visible to it: not by
# convention, but because the directory did not exist until this run
# made it.
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
# this script posts the verdict itself afterward, from the remote host's
# own already-authenticated `gh`, using the container's exit code. That
# reproduces signoff.sh's own two-line posting stanza rather than
# extending signoff.sh to skip it conditionally, which would mean
# touching the lanes file this change was scoped to leave alone.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

host=${LOOM_SIGNOFF_HOST:?set LOOM_SIGNOFF_HOST to an ssh destination (an alias from your ssh config, or user@host)}
dir=${LOOM_SIGNOFF_DIR:-loom-signoff}
sha=$(git -C "$root" rev-parse HEAD)
origin=$(git -C "$root" remote get-url origin)
container=${LOOM_SIGNOFF_CONTAINER:-0}

if [ -z "$(git -C "$root" branch -r --contains "$sha")" ]; then
	echo "signoff_remote: $sha is on no remote branch; push first" >&2
	exit 2
fi

if [ "$container" = 1 ]; then
	# Container mode moves the posting step out of signoff.sh (see the
	# block comment above), so it needs to know, from the caller's own
	# args, whether this run intends to post at all and where.
	# signoff.sh's own case statement is still the one authority on which
	# flags are valid; this only ever reads the two that change what
	# happens after the container exits.
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

	# The driver script below is entirely single-quoted (heredoc
	# delimiter 'DRIVER'): nothing in it is touched by this local shell,
	# so every $VAR in it is resolved once, remotely, at run time. The
	# handful of values this side actually knows — the checkout
	# directory, the origin URL, the commit, whether to post and where —
	# travel as environment variables instead of being spliced into the
	# text, which is what keeps a path or URL with a shell-special
	# character in it from corrupting the script it lands in.
	exec ssh "$host" "env $(printf 'LOOM_DIR=%q ' "$dir")$(printf 'LOOM_ORIGIN=%q ' "$origin")$(printf 'LOOM_SHA=%q ' "$sha")$(printf 'LOOM_POST=%q ' "$post")$(printf 'LOOM_URL=%q ' "$url")${SIGNOFF_PARALLEL:+$(printf 'LOOM_PARALLEL=%q ' "$SIGNOFF_PARALLEL")}bash -lc 'exec bash -s'" <<'DRIVER'
set -euo pipefail
if [ ! -d "$LOOM_DIR/.git" ]; then git clone --quiet "$LOOM_ORIGIN" "$LOOM_DIR"; fi
cd "$LOOM_DIR"
git fetch --quiet origin "$LOOM_SHA"
git checkout --quiet --detach "$LOOM_SHA"

short=$(git rev-parse --short=12 "$LOOM_SHA")
base="$HOME/loom-signoff-container"
runs="$base/runs"
logs="$base/logs/$short"
mkdir -p "$runs" "$logs"

# Every run below gets its own working tree; a directory from more than
# a day ago cannot be this run's, so it is safe to reclaim rather than
# let per-run trees accumulate on the box forever.
find "$runs" -mindepth 1 -maxdepth 1 -mtime +1 -exec rm -rf {} + 2>/dev/null || true

# A local clone, from the checkout above (already fetched to the commit
# under test), into a directory this run alone owns — the fresh working
# tree. No network round trip, and nothing survives from a previous run
# because no previous run ever wrote into this path.
work=$(mktemp -d "$runs/$short.XXXXXX")

# mktemp defaults a fresh directory to mode 700, world-shut, and it is
# owned by the ssh session's own user (a login account, not root). The
# container runs as root to do the cgroup work above, but the payload
# a lane's own test spawns runs the way the whole design demands: under
# a dropped, unprivileged identity that is neither root nor this login
# account. That identity has no path into a 700 directory it owns
# neither by uid nor by root, and every jailed exec inside the
# container failed on it — bwrap and the sandbox's own probes alike, all
# with the same `readlink("/work/packages", ...)  = -1 EACCES`, because
# path resolution for a bind source has to pass through this directory
# before it ever reaches the file being bound. Opening the top directory
# to `o+rx` costs nothing this run does not already give up by handing
# root the whole tree, and every file underneath already inherited a
# permissive mode from `git clone`'s own umask; this was the one
# directory mktemp made restrictive.
chmod o+rx "$work"

git clone --quiet "$PWD" "$work"
git -C "$work" checkout --quiet --detach "$LOOM_SHA"

# The container-side entrypoint, written into the working tree so it
# rides along on the bind mount below rather than needing a second layer
# of quoting through `docker run ... bash -c "..."`. It does exactly
# three things: makes /sys/fs/cgroup writable (Docker mounts it
# read-only even with --cgroupns=host), carves out a fresh, process-empty
# cgroup v2 base for loom-exec's pids/memory ceilings the way
# scripts/signoff.sh's own delegation dance does on bare metal — as root
# here, which needs no systemd handoff — and then runs signoff.sh itself
# with --dry-run, because posting happens after the container exits (see
# this script's own header comment for why).
cat >"$work/.ci-container-entrypoint.sh" <<'ENTRYPOINT'
#!/usr/bin/env bash
set -euo pipefail
# The bind-mounted working tree keeps the host's UID as owner, which
# does not match the container's root; git's dubious-ownership guard
# then refuses every command in it, including the `git rev-parse` at
# the top of signoff.sh. The guard exists to stop a container from
# quietly running as whoever owns a mounted tree it did not create;
# here the container built the tree's clone source itself one command
# ago, so there is nothing to guard against.
git config --global --add safe.directory /work
mount -o remount,rw /sys/fs/cgroup
base="/sys/fs/cgroup/loom-signoff-$1"
mkdir -p "$base"
echo "+pids +memory" >/sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
echo "+pids +memory" >"$base/cgroup.subtree_control"
export LOOM_CGROUP_BASE="$base"
cd /work
st=0
scripts/signoff.sh --commit "$2" --dry-run || st=$?
rmdir "$base" 2>/dev/null || true
exit "$st"
ENTRYPOINT
chmod +x "$work/.ci-container-entrypoint.sh"

echo "== building loom-signoff:$short (scripts/signoff/Dockerfile at $LOOM_SHA)"
docker build --quiet -f scripts/signoff/Dockerfile -t "loom-signoff:$short" scripts/signoff >"$logs/image-build.log"

started=$(date +%s)
set +e
docker run --rm \
	--cgroupns=host \
	--cap-add SYS_ADMIN \
	--security-opt seccomp=unconfined \
	--security-opt apparmor=unconfined \
	--security-opt systempaths=unconfined \
	-v "$work:/work" \
	-v loom-signoff-hex-cache:/root/.cache/gleam \
	-v loom-signoff-go-mod-cache:/var/cache/loom-signoff/go/pkg/mod \
	${LOOM_PARALLEL:+-e "SIGNOFF_PARALLEL=$LOOM_PARALLEL"} \
	"loom-signoff:$short" \
	/work/.ci-container-entrypoint.sh "$short" "$LOOM_SHA" >"$logs/signoff.log" 2>&1
verdict=$?
set -e
elapsed=$(($(date +%s) - started))
cat "$logs/signoff.log"
cp -r "$work/build/signoff" "$logs/lanes" 2>/dev/null || true
echo "== containerised signoff/linux: $([ "$verdict" -eq 0 ] && echo GREEN || echo RED) in ${elapsed}s"
echo "== logs: $logs on $(hostname)"

if [ "$LOOM_POST" = yes ]; then
	if [ "$verdict" -eq 0 ]; then
		gh signoff --commit "$LOOM_SHA" ${LOOM_URL:+--url "$LOOM_URL"} linux
	else
		gh signoff fail --commit "$LOOM_SHA" ${LOOM_URL:+--url "$LOOM_URL"} \
			--description "$(git config user.name): signoff/linux red, ${elapsed}s (container), see $logs on the runner" linux
	fi
fi
exit "$verdict"
DRIVER
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
