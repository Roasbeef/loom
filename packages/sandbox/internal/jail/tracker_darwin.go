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
	stop chan struct{}
	done chan struct{}
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
	children := make(map[int][]darwinProcess, len(table))
	for _, process := range table {
		children[process.ppid] = append(children[process.ppid], process)
	}
	frontier := children[t.root]
	observed := make(map[int]uint64)
	for len(frontier) > 0 {
		var next []darwinProcess
		for _, process := range frontier {
			observed[process.pid] = process.birth
			next = append(next, children[process.pid]...)
		}
		frontier = next
	}
	t.mu.Lock()
	for pid, birth := range observed {
		t.seen[pid] = birth
	}
	t.mu.Unlock()
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

type darwinProcess struct {
	pid   int
	ppid  int
	birth uint64
}

func darwinProcessTable() ([]darwinProcess, error) {
	entries, err := unix.SysctlKinfoProcSlice("kern.proc.all")
	if err != nil {
		return nil, err
	}
	out := make([]darwinProcess, 0, len(entries))
	for _, entry := range entries {
		out = append(out, darwinProcess{
			pid:   int(entry.Proc.P_pid),
			ppid:  int(entry.Eproc.Ppid),
			birth: processBirth(entry),
		})
	}
	return out, nil
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
