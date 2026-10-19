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

	queue   int
	watched map[int]uint64
}

const processTrackInterval = 20 * time.Millisecond

// A fresh Darwin process table is large. Limit its acquisition and indexing
// to one capture in this helper so overlapping trackers do not multiply the
// transient heap footprint. No snapshot is shared or retained by this lock.
// Lock order is processCaptureMu then one tracker's mu; signal and close
// never acquire this lock while holding a tracker lock.
var processCaptureMu sync.Mutex

func startProcessTracker(root int) (*processTracker, error) {
	t := &processTracker{
		root:    root,
		seen:    make(map[int]uint64),
		stop:    make(chan struct{}),
		done:    make(chan struct{}),
		watched: make(map[int]uint64),
	}

	queue, err := unix.Kqueue()
	if err != nil {
		return nil, fmt.Errorf("jail: create Darwin process queue: %w", err)
	}
	t.queue = queue
	wake := unix.Kevent_t{Filter: unix.EVFILT_USER, Flags: unix.EV_ADD | unix.EV_CLEAR}
	if _, err := unix.Kevent(queue, []unix.Kevent_t{wake}, nil, nil); err != nil {
		_ = unix.Close(queue)
		return nil, fmt.Errorf("jail: register Darwin tracker wake: %w", err)
	}

	// Register the gated root before taking the initial snapshot. Fork events
	// arriving during discovery remain queued for the next fresh capture.
	if err := t.watch(root); err != nil {
		_ = unix.Close(queue)
		return nil, fmt.Errorf("jail: watch Darwin process root: %w", err)
	}

	// The jail's start gate is still closed. This successful fresh capture
	// is the initial descendant ledger as well as the fail-closed preflight.
	if err := t.captureAndWatch(); err != nil {
		_ = unix.Close(queue)
		return nil, fmt.Errorf("jail: read/watch Darwin process table: %w", err)
	}
	go t.run()
	return t, nil
}

// run uses process events as discovery hints, never as identity authority.
// Darwin does not implement recursive NOTE_TRACK: each fork/exit wakes a fresh
// table walk, then newly observed descendants receive their own watches. A
// rapid double-fork can still outrun discovery, as with the sampled tracker.
func (t *processTracker) run() {
	defer close(t.done)
	var events [32]unix.Kevent_t
	timeout := unix.NsecToTimespec((250 * time.Millisecond).Nanoseconds())
	for {
		select {
		case <-t.stop:
			return
		default:
		}

		// The user event wakes close promptly; the timeout also bounds join
		// if that notification fails. Idle waits do not read a process table.
		n, err := unix.Kevent(t.queue, nil, events[:], &timeout)
		if err == unix.EINTR {
			continue
		}
		if err != nil {
			t.runPolling()
			return
		}
		select {
		case <-t.stop:
			return
		default:
		}
		if n == 0 {
			continue
		}
		for _, event := range events[:n] {
			if event.Flags&unix.EV_ERROR != 0 {
				t.runPolling()
				return
			}
			if event.Fflags&unix.NOTE_EXIT != 0 {
				delete(t.watched, int(event.Ident))
			}
		}
		if err := t.captureAndWatch(); err != nil {
			t.runPolling()
			return
		}
	}
}

// runPolling preserves the previous best-effort discovery if a live queue or
// a descendant registration fails. Losing notifications must not silently
// stop discovery; startup failures instead refuse before opening the gate.
func (t *processTracker) runPolling() {
	ticker := time.NewTicker(processTrackInterval)
	defer ticker.Stop()
	for {
		_ = t.capture()
		select {
		case <-ticker.C:
		case <-t.stop:
			return
		}
	}
}

func (t *processTracker) watch(pid int) error {
	change := unix.Kevent_t{
		Ident: uint64(pid), Filter: unix.EVFILT_PROC,
		Flags:  unix.EV_ADD | unix.EV_CLEAR,
		Fflags: unix.NOTE_FORK | unix.NOTE_EXIT,
	}
	_, err := unix.Kevent(t.queue, []unix.Kevent_t{change}, nil, nil)
	return err
}

func (t *processTracker) captureAndWatch() error {
	processCaptureMu.Lock()
	defer processCaptureMu.Unlock()
	table, err := darwinProcessTable()
	if err != nil {
		return err
	}
	t.captureTable(table)
	return t.watchTable(table)
}

func (t *processTracker) watchTable(table []unix.KinfoProc) error {
	// Only identities observed under this root enter the ledger. A watch
	// raced by exit is harmless; signal always rechecks the remembered birth.
	t.mu.Lock()
	defer t.mu.Unlock()
	added := false
	for _, entry := range table {
		pid, birth := int(entry.Proc.P_pid), processBirth(entry)
		observed, ok := t.seen[pid]
		if !ok || observed != birth || t.watched[pid] == birth {
			continue
		}
		if err := t.watch(pid); err != nil {
			if err == unix.ESRCH {
				continue
			}
			return err
		}
		t.watched[pid] = birth
		added = true
	}

	// A child can fork between this snapshot and its watch registration.
	// Queue a post-registration snapshot to discover such live grandchildren;
	// later forks already have watches. Each scan releases the capture lock
	// and returns through run's stop check, even under a continuous fork load.
	if added {
		return t.wake()
	}
	return nil
}

// capture consumes one fresh kernel snapshot while its process-local permit
// is held. Startup propagates failure; periodic and signal paths retain their
// existing best-effort treatment of an unavailable kernel table.
func (t *processTracker) capture() error {
	processCaptureMu.Lock()
	defer processCaptureMu.Unlock()
	table, err := darwinProcessTable()
	if err != nil {
		return err
	}
	t.captureTable(table)
	return nil
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
	_ = t.capture()
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

	// close owns the descriptor until the reader has joined, so a racing
	// reader exit cannot recycle it underneath this wakeup.
	_ = t.wake()
	<-t.done
	_ = unix.Close(t.queue)
}

func (t *processTracker) wake() error {
	wake := unix.Kevent_t{Filter: unix.EVFILT_USER, Fflags: unix.NOTE_TRIGGER}
	_, err := unix.Kevent(t.queue, []unix.Kevent_t{wake}, nil, nil)
	return err
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
