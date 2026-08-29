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

// signal sends sig only to a currently live process with the same birth time
// as the descendant originally observed. The identity check prevents PID reuse
// from turning cleanup into a signal aimed at an unrelated process.
func (t *processTracker) signal(sig syscall.Signal) bool {
	t.capture()
	table, err := darwinProcessTable()
	if err != nil {
		return false
	}
	live := make(map[int]uint64, len(table))
	for _, process := range table {
		live[process.pid] = process.birth
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	delivered := false
	for pid, birth := range t.seen {
		if live[pid] != birth {
			continue
		}
		if err := syscall.Kill(pid, sig); err == nil {
			delivered = true
		}
	}
	return delivered
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
		start := entry.Proc.P_starttime
		birth := uint64(start.Sec)*1_000_000 + uint64(start.Usec)
		out = append(out, darwinProcess{
			pid:   int(entry.Proc.P_pid),
			ppid:  int(entry.Eproc.Ppid),
			birth: birth,
		})
	}
	return out, nil
}

// CurrentUserProcessCount returns the number RLIMIT_NPROC currently counts
// against this uid. Darwin's process limit is per-user rather than per-jail;
// callers must not install a ceiling already below this floor, because that
// would turn every later fork into EAGAIN regardless of the jailed subtree's
// own size.
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
