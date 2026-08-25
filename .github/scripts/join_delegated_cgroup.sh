#!/usr/bin/env bash
# join_delegated_cgroup.sh — put this shell inside the delegated cgroup,
# so the helper it spawns can create per-exec cgroups and move children
# into them. Meant to be *sourced*, because it moves `$$`:
#
#   . .github/scripts/join_delegated_cgroup.sh
#
# Why it is needed at all. cgroup v2's delegation containment rule lets an
# unprivileged process migrate another process only when it can write both
# the destination's `cgroup.procs` *and* the `cgroup.procs` of the common
# ancestor of source and destination. A helper left in the runner's own
# service cgroup shares only the root cgroup with $LOOM_CGROUP_BASE, and
# nobody unprivileged may write root's `cgroup.procs` — so the per-exec
# cgroup would be created and then stand empty, ceilings and all.
#
# The fix is the shape systemd already produces for `Delegate=yes` with
# `DelegateSubgroup=`: the supervisor's own processes live in a subgroup
# of the delegated base, leaving the base itself process-empty (which is
# what lets it enable controllers for its children) and making the base
# the common ancestor of supervisor and per-exec cgroups alike. That
# ancestor is delegated, so the migration is permitted.
#
# The move itself needs root exactly once, for the same containment
# reason: this shell is coming *from* the runner's service cgroup. systemd
# does this move as root at service start; here sudo does.
#
# A no-op when LOOM_CGROUP_BASE is unset, so a job without delegation runs
# unchanged.
if [ -n "${LOOM_CGROUP_BASE:-}" ]; then
	loom_sub="${LOOM_CGROUP_BASE}/supervisor"
	mkdir -p "$loom_sub"
	sudo sh -c "echo $$ > '${loom_sub}/cgroup.procs'"
	echo "joined delegated cgroup: $(cat /proc/self/cgroup)"
	unset loom_sub
fi
