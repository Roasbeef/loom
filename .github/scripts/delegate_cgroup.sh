#!/usr/bin/env bash
# Delegate and prove the existing memory/pid enforcement prerequisite.
# All real helper-running steps must also source join_delegated_cgroup.sh.
set -euo pipefail
base=/sys/fs/cgroup/loom.slice
sudo mkdir -p "$base"
# The root cgroup is exempt from the no-internal-process rule,
# so it can distribute controllers even while populated. systemd
# has usually done this already; enabling twice is a no-op, and
# the proof that it took is the probe further down, not this
# write's exit code.
sudo sh -c 'echo "+memory +pids" > /sys/fs/cgroup/cgroup.subtree_control' ||
  echo "root subtree_control unchanged (already set, or refused)"
sudo sh -c "echo '+memory +pids' > $base/cgroup.subtree_control"
# Delegation proper: the workflow user owns the directory and
# the three interface files a delegated cgroup needs.
sudo chown -R "$(id -u):$(id -g)" "$base"
echo "controllers:    $(cat "$base"/cgroup.controllers)"
echo "subtree:        $(cat "$base"/cgroup.subtree_control)"
echo "member procs:   $(wc -l < "$base"/cgroup.procs)"
# Prove the grant before anything depends on it, in both the
# ways it can be hollow.
#
# First: a child of the base must really have the two limit
# files to write.
mkdir -p "$base/ci-probe" "$base/supervisor"
test -w "$base/ci-probe/memory.max"
test -w "$base/ci-probe/pids.max"
#
# Second, and much easier to get wrong: cgroup v2's delegation
# containment rule permits an unprivileged migration only when
# the writer can write both the destination's `cgroup.procs`
# and the `cgroup.procs` of the common ancestor of source and
# destination. A helper left in the runner's own service cgroup
# shares only the *root* cgroup with this base, and nobody
# unprivileged writes root — so every per-exec cgroup would be
# created, configured, and left empty. The shape that works is
# systemd's `DelegateSubgroup=`: the supervisor sits in a
# subgroup of the base, which makes the base the common
# ancestor. Prove that with a real unprivileged move.
sh -c 'exec sleep 60' &
probe_pid=$!
# Only this first move needs root, because it crosses out of
# the runner's service cgroup — exactly what systemd does for a
# delegated service at start.
sudo sh -c "echo $probe_pid > '$base/supervisor/cgroup.procs'"
# And this one is the real test: unprivileged, within the
# delegated subtree.
if ! echo "$probe_pid" > "$base/ci-probe/cgroup.procs"; then
  echo "delegation is hollow: an unprivileged migration into a"
  echo "child of $base was refused. The helper would create"
  echo "per-exec cgroups it cannot put anything into, and the"
  echo "memory and pid ceilings would bind nothing."
  kill "$probe_pid" 2>/dev/null || true
  exit 1
fi
grep -qx "$probe_pid" "$base/ci-probe/cgroup.procs"
kill "$probe_pid" 2>/dev/null || true
wait "$probe_pid" 2>/dev/null || true
rmdir "$base/ci-probe"
echo "LOOM_CGROUP_BASE=$base" >> "$GITHUB_ENV"
