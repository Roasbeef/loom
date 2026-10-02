//go:build darwin

package jail

import (
	"fmt"
	"os"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// processTracker remembers every descendant observed beneath sandbox-exec.
// macOS has no PID namespace or subreaper, so a child that calls setsid leaves
// the process group. Tracking parent links while the root is alive preserves a
// handle after such a child is reparented to launchd.
type processTracker struct {
	root int

	mu   sync.Mutex
	seen map[int]uint64

	// Scratch belongs to the same lock as the ledger. Its capacity follows the
	// largest snapshot, but its links are rebuilt from each fresh kernel table.
	children map[int]int
	next     []int
	frontier []int
	stop     chan struct{}
	done     chan struct{}
}

const processTrackInterval = 20 * time.Millisecond

func startProcessTracker(root int) (*processTracker, error) {
	if _, err := darwinProcessTable(); err != nil {
		return nil, fmt.Errorf("jail: read Darwin process table: %w", err)
	}
	t := &processTracker{
		root: root,
		seen: make(map[int]uint64),
		stop: make(chan struct{}),
		done: make(chan struct{}),
	}
	t.capture()
	go t.run()
	return t, nil
}

func (t *processTracker) run() {
	defer close(t.done)
	ticker := time.NewTicker(processTrackInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			t.capture()
		case <-t.stop:
			return
		}
	}
}

func (t *processTracker) capture() {
	table, err := darwinProcessTable()
	if err != nil {
		return
	}
	t.captureTable(table)
}

// captureTable walks parent links in this fresh kernel snapshot. Child lists
// retain row indices rather than copies of process records: only the observed
// subtree's pid and birth time enter the persistent descendant ledger.
func (t *processTracker) captureTable(table []unix.KinfoProc) {
	t.mu.Lock()
	defer t.mu.Unlock()

	// Clearing the heads prevents a disappeared parent from retaining links
	// into a later snapshot. Every active row's next link is overwritten below.
	if cap(t.next) < len(table) || t.children == nil {
		t.children = make(map[int]int, len(table))
		t.next = make([]int, len(table))
	} else {
		clear(t.children)
		t.next = t.next[:len(table)]
	}

	// Prepending rows backwards preserves the kernel snapshot's sibling
	// order while giving every parent one head instead of a separate slice.
	for row := len(table) - 1; row >= 0; row-- {
		ppid := int(table[row].Eproc.Ppid)
		t.next[row] = t.children[ppid]
		t.children[ppid] = row + 1
	}

	// A one-based link reserves zero for the end of a sibling list. All
	// links belong to this snapshot, so no process identity is cached here.
	t.frontier = append(t.frontier[:0], t.root)
	for cursor := 0; cursor < len(t.frontier); cursor++ {
		parent := t.frontier[cursor]
		for link := t.children[parent]; link != 0; link = t.next[link-1] {
			process := table[link-1]
			pid := int(process.Proc.P_pid)
			t.seen[pid] = processBirth(process)
			t.frontier = append(t.frontier, pid)
		}
	}
}

// signal narrows each delivery to a process whose birth time still matches the
// descendant originally observed. Darwin has no stable pidfd-like handle, so a
// final exit-and-reuse race remains between this check and kill(2); every
// execution's lifecycle skip records that the tracker is not kernel ownership.
func (t *processTracker) signal(sig syscall.Signal) bool {
	t.capture()
	t.mu.Lock()
	defer t.mu.Unlock()
	delivered := false
	for pid, birth := range t.seen {
		liveBirth, err := darwinProcessBirth(pid)
		if err != nil || liveBirth != birth {
			continue
		}
		if err := syscall.Kill(pid, sig); err == nil {
			delivered = true
		}
	}
	return delivered
}

func darwinProcessBirth(pid int) (uint64, error) {
	entry, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		return 0, err
	}
	return processBirth(*entry), nil
}

func (t *processTracker) close() {
	close(t.stop)
	<-t.done
}

func darwinProcessTable() ([]unix.KinfoProc, error) {
	return unix.SysctlKinfoProcSlice("kern.proc.all")
}

func processBirth(entry unix.KinfoProc) uint64 {
	start := entry.Proc.P_starttime
	return uint64(start.Sec)*1_000_000 + uint64(start.Usec)
}

// CurrentUserProcessCount returns the number RLIMIT_NPROC currently counts
// against this uid. Darwin's process limit is per-user rather than per-jail;
// callers must leave concurrency reserve above this floor, because a ceiling
// at the sample turns every later fork into EAGAIN regardless of the jailed
// subtree's own size. The sample cannot be atomic with unrelated same-user
// forks.
func CurrentUserProcessCount() (uint64, error) {
	entries, err := unix.SysctlKinfoProcSlice("kern.proc.all")
	if err != nil {
		return 0, err
	}
	uid := uint32(os.Getuid())
	var count uint64
	for _, entry := range entries {
		if entry.Eproc.Ucred.Uid == uid {
			count++
		}
	}
	return count, nil
}
