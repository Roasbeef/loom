//go:build linux

package cgroup

import (
	"fmt"

	"golang.org/x/sys/unix"
)

// notCgroup2 reports why path is not a cgroup v2 filesystem, or "" when
// it is.
//
// This is the check that was missing entirely (#52). Every question
// DetectBase asked — reading `cgroup.controllers`, reading
// `cgroup.procs`, writing `cgroup.subtree_control`, creating a child
// directory — an ordinary directory answers just as well, so three text
// files under a typo'd `--cgroup-base` became a cgroup v2 base, the
// ceilings became ordinary text files, `Enter` wrote a pid into one and
// returned nil, and the exec_exit frame told the broker `cgroup-v2` was
// applied. Only the kernel can settle what a directory actually is, and
// `statfs(2)` is how it is asked.
func notCgroup2(path string) string {
	var st unix.Statfs_t
	if err := unix.Statfs(path, &st); err != nil {
		return fmt.Sprintf("%s is not a cgroup v2 directory: statfs: %v", path, err)
	}
	if uint32(st.Type) != uint32(unix.CGROUP2_SUPER_MAGIC) {
		return fmt.Sprintf("%s is not on a cgroup v2 filesystem "+
			"(statfs f_type 0x%x, want 0x%x for cgroup2); a plain directory "+
			"holding files named cgroup.controllers and cgroup.procs is not "+
			"a cgroup, and ceilings written into it bind nothing",
			path, uint32(st.Type), uint32(unix.CGROUP2_SUPER_MAGIC))
	}
	return ""
}

// writableProcs reports whether the caller may write pids into the
// cgroup.procs of dir — the permission cgroup v2's delegation
// containment rule requires of the *common ancestor* of the source and
// destination cgroups, not just of the destination.
func writableProcs(procs string) bool {
	return unix.Access(procs, unix.W_OK) == nil
}
