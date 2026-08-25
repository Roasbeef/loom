#!/usr/bin/env bash
# kernel_census.sh — say exactly what this machine's kernel offers.
#
# The jail suites depend on features a hosted runner may or may not have:
# bubblewrap, Landlock, cgroup v2 delegation, seccomp, and unprivileged
# user namespaces (which Ubuntu 24.04 restricts through AppArmor). Loom's
# standing rule is that degraded enforcement is reported as ground truth,
# so before any suite runs, the run states what it is standing on. Purely
# informational: it never fails a job, because the judgement of what is
# and is not acceptable belongs to `.github/enforcement-expectations` and
# the self-test that feeds it.
set -uo pipefail

emit() {
	printf '%s\n' "$*"
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
	fi
}

kv() { printf '%-34s %s\n' "$1" "$2"; }

emit ""
emit "### Kernel census"
emit ""
emit '```'

{
	kv "uname" "$(uname -srmo 2>/dev/null || uname -a)"
	if [ -r /etc/os-release ]; then
		# shellcheck disable=SC1091
		kv "os" "$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"
	fi
	kv "uid/gid" "$(id -u)/$(id -g) ($(id -un))"

	if command -v bwrap >/dev/null 2>&1; then
		kv "bubblewrap" "$(bwrap --version 2>&1 | head -1) at $(command -v bwrap)"
	else
		kv "bubblewrap" "ABSENT (no namespace or mount layer)"
	fi

	# Landlock: the ABI version the kernel admits to, straight from the
	# syscall. -1 means the LSM is not in the boot-time LSM list even when
	# the kernel was built with it.
	if [ -r /sys/kernel/security/lsm ]; then
		kv "lsm list" "$(cat /sys/kernel/security/lsm)"
	else
		kv "lsm list" "unreadable (/sys/kernel/security not mounted)"
	fi

	sysctl_of() { cat "/proc/sys/${1//.//}" 2>/dev/null || echo "n/a"; }
	kv "unprivileged_userns_clone" "$(sysctl_of kernel.unprivileged_userns_clone)"
	kv "apparmor_restrict_unpriv_userns" \
		"$(sysctl_of kernel.apparmor_restrict_unprivileged_userns)"
	kv "seccomp" "$(sysctl_of kernel.seccomp.actions_avail)"

	if unshare -rn true 2>/dev/null; then
		kv "unshare -rn" "works (unprivileged user+net namespace)"
	else
		kv "unshare -rn" "REFUSED — bwrap and the offline seed probe cannot run"
	fi

	if [ -r /sys/fs/cgroup/cgroup.controllers ]; then
		kv "cgroup v2 root controllers" "$(cat /sys/fs/cgroup/cgroup.controllers)"
		kv "cgroup v2 root subtree_control" \
			"$(cat /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || echo unreadable)"
		own=$(awk -F: '/^0::/ { print $3 }' /proc/self/cgroup 2>/dev/null)
		kv "own cgroup" "${own:-unknown}"
		if [ -n "${own:-}" ] && mkdir "/sys/fs/cgroup${own%/}/loom-ci-probe" 2>/dev/null; then
			rmdir "/sys/fs/cgroup${own%/}/loom-ci-probe" 2>/dev/null || true
			kv "own cgroup delegated" "yes (mkdir succeeded)"
			kv "own cgroup subtree_control" \
				"$(cat "/sys/fs/cgroup${own%/}/cgroup.subtree_control" 2>/dev/null || echo unreadable)"
		else
			kv "own cgroup delegated" "no (mkdir refused) — pids/memory limits unavailable"
		fi
	else
		kv "cgroup v2" "ABSENT at /sys/fs/cgroup (no unified hierarchy)"
	fi
} 2>&1 | while IFS= read -r line; do emit "$line"; done

emit '```'
exit 0
