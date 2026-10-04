//go:build linux

package cgroup

import (
	"fmt"
	"path/filepath"
	"time"

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

// awaitEmpty blocks until cgroup.events in dir reports `populated 0`, or
// until bound passes. The kernel modifies that file when the subtree's
// population changes, so an inotify watch wakes the wait on the exact
// event rather than on a polling interval. The watch is added before the
// first read: a change landing between the two is then still delivered.
// A directory with no cgroup.events (a fake base in tests, or one already
// removed) has nothing to wait for.
func awaitEmpty(dir string, bound time.Duration) {
	events := filepath.Join(dir, "cgroup.events")
	fd, err := unix.InotifyInit1(unix.IN_CLOEXEC)
	if err != nil {
		return
	}
	defer unix.Close(fd)
	if _, err := unix.InotifyAddWatch(fd, events, unix.IN_MODIFY); err != nil {
		return
	}

	deadline := time.Now().Add(bound)
	buf := make([]byte, 4096)
	for !unpopulated(events) {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return
		}
		fds := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}
		n, err := unix.Poll(fds, int(remaining/time.Millisecond)+1)
		if err == unix.EINTR {
			continue
		}
		if err != nil || n == 0 {
			return
		}
		_, _ = unix.Read(fd, buf)
	}
}

// processAlive reports whether a process with this pid exists. `kill(pid, 0)`
// delivers nothing and only asks; EPERM means the process exists and belongs to
// someone else, which is alive.
func processAlive(pid int) bool {
	err := unix.Kill(pid, 0)
	return err == nil || err == unix.EPERM
}

// writableProcs reports whether the caller may write pids into the
// cgroup.procs of dir — the permission cgroup v2's delegation
// containment rule requires of the *common ancestor* of the source and
// destination cgroups, not just of the destination.
func writableProcs(procs string) bool {
	return unix.Access(procs, unix.W_OK) == nil
}
