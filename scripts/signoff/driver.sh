#!/usr/bin/env bash
# driver.sh — the remote half of a containerised signoff, run on the box
# that hosts it.
#
# scripts/signoff_remote.sh streams this file to `bash -s` over ssh. It
# was a heredoc inside that script; it is a file of its own so that it can
# be read, tested and installed as one, and signoff_remote.sh's header
# still says why the container flags, the entrypoint and the posting
# stanza are what they are.
#
# Everything it needs arrives in the environment, never spliced into its
# text, so a path or URL with a shell-special character in it cannot
# corrupt the script it would have landed in:
#
#   LOOM_DIR      the checkout this run owns (cloned on first use)
#   LOOM_ORIGIN   where to clone it from
#   LOOM_SHA      the commit under test, already on one of origin's branches
#   LOOM_POST     `yes` to post the verdict with the host's `gh`, else `no`
#   LOOM_URL      the status's details link, or empty
#   LOOM_PARALLEL optional; becomes SIGNOFF_PARALLEL in the container
#   LOOM_CPUS     optional; a docker --cpus ceiling for the run
#   LOOM_MEMORY   optional; a docker --memory ceiling, e.g. 16g
set -euo pipefail
if [ ! -d "$LOOM_DIR/.git" ]; then git clone --quiet "$LOOM_ORIGIN" "$LOOM_DIR"; fi
cd "$LOOM_DIR"
git fetch --quiet origin "$LOOM_SHA"
git checkout --quiet --detach "$LOOM_SHA"

short=$(git rev-parse --short=12 "$LOOM_SHA")
logs="$HOME/loom-signoff-container/logs/$short"
mkdir -p "$logs"

# The container-side entrypoint, written into this commit's logs directory
# so it reaches the container on the /logs mount rather than through a
# second layer of quoting in `docker run ... bash -c "..."`. In order, it:
#
#   1. clones the read-only checkout at /src into /work, on the
#      container's own filesystem, so `--rm` removes the whole tree;
#   2. makes /sys/fs/cgroup writable (Docker mounts it read-only even with
#      --cgroupns=host) and carves out a fresh, process-empty cgroup v2 base
#      for loom-exec's pids/memory ceilings, the way scripts/signoff.sh's
#      delegation does on bare metal, as root here, so no systemd handoff;
#      When LOOM_MEMORY or LOOM_CPUS is set, the base gets the same
#      ceiling as the container, because it sits beside the container's
#      cgroup rather than under it and would otherwise escape that ceiling;
#   3. runs signoff.sh with --dry-run, because posting happens after the
#      container exits (see this script's header comment for why);
#   4. copies the lanes' logs to /logs and gives them to the login account.
#
# git's dubious-ownership guard refuses a repository owned by another user,
# and /src belongs to the login account while the container is root. The
# guard exists to stop a process from running hooks in a tree someone else
# controls; this checkout is the one this script fetched one command ago,
# so it is trusted, and /work is root's own clone. A clone from a work
# tree reads its `.git` directory, which the guard checks as a path of its
# own, so both are named.
cat >"$logs/entrypoint.sh" <<'ENTRYPOINT'
#!/usr/bin/env bash
set -euo pipefail
short=$1 sha=$2 owner=$3 memory=${4:-} cpu_quota=${5:-}
git config --global --add safe.directory /src
git config --global --add safe.directory /src/.git
git clone --quiet /src /work
git -C /work checkout --quiet --detach "$sha"
mount -o remount,rw /sys/fs/cgroup
base="/sys/fs/cgroup/loom-signoff-$short"
mkdir -p "$base"
echo "+pids +memory" >/sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
if [ -n "$memory" ]; then echo "$memory" >"$base/memory.max"; fi
if [ -n "$cpu_quota" ]; then
	echo "+cpu" >/sys/fs/cgroup/cgroup.subtree_control
	echo "$cpu_quota 100000" >"$base/cpu.max"
fi
echo "+pids +memory" >"$base/cgroup.subtree_control"
export LOOM_CGROUP_BASE="$base"
cd /work
st=0
scripts/signoff.sh --commit "$sha" --dry-run || st=$?
rmdir "$base" 2>/dev/null || true
if [ -d build/signoff ]; then
	rm -rf /logs/lanes
	cp -r build/signoff /logs/lanes
	chown -R "$owner" /logs/lanes
fi
exit "$st"
ENTRYPOINT

echo "== building loom-signoff:$short (scripts/signoff/Dockerfile at $LOOM_SHA)"
docker build --quiet -f scripts/signoff/Dockerfile -t "loom-signoff:$short" . >"$logs/image-build.log"

# LOOM_CPUS and LOOM_MEMORY, when set, bound the run for a box that has
# other work on it; unset, a run may use the whole machine, as it always
# has. memory.max takes bytes and cpu.max a quota per 100ms period, where
# docker takes a suffixed size and a fraction of CPUs, so the conversions
# are made once, here.
memory_bytes=""
if [ -n "${LOOM_MEMORY:-}" ]; then
	memory_bytes=$(numfmt --from=iec "${LOOM_MEMORY^^}")
fi
cpu_quota=""
if [ -n "${LOOM_CPUS:-}" ]; then
	cpu_quota=$(awk -v cpus="$LOOM_CPUS" 'BEGIN { printf "%d", cpus * 100000 }')
fi

started=$(date +%s)
set +e
docker run --rm \
	${LOOM_CPUS:+--cpus "$LOOM_CPUS"} \
	${LOOM_MEMORY:+--memory "$LOOM_MEMORY"} \
	--cgroupns=host \
	--cap-add SYS_ADMIN \
	--security-opt seccomp=unconfined \
	--security-opt apparmor=unconfined \
	--security-opt systempaths=unconfined \
	-v "$PWD:/src:ro" \
	-v "$logs:/logs" \
	-v loom-signoff-hex-cache:/root/.cache/gleam \
	-v loom-signoff-go-mod-cache:/var/cache/loom-signoff/go/pkg/mod \
	${LOOM_PARALLEL:+-e "SIGNOFF_PARALLEL=$LOOM_PARALLEL"} \
	"loom-signoff:$short" \
	bash /logs/entrypoint.sh "$short" "$LOOM_SHA" "$(id -u):$(id -g)" "$memory_bytes" "$cpu_quota" >"$logs/signoff.log" 2>&1
verdict=$?
set -e
elapsed=$(($(date +%s) - started))
cat "$logs/signoff.log"
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
