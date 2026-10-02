//go:build darwin

package jail

import (
	"bufio"
	"os/exec"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func trackerProcess(pid, ppid int, birth int64) unix.KinfoProc {
	var process unix.KinfoProc
	process.Proc.P_pid = int32(pid)
	process.Eproc.Ppid = int32(ppid)
	process.Proc.P_starttime.Sec = birth / 1_000_000
	process.Proc.P_starttime.Usec = int32(birth % 1_000_000)
	return process
}

func TestProcessTrackerCaptureKeepsDescendantIdentity(t *testing.T) {
	// Parent links may appear in any kernel row order. The last row is a
	// direct child, while its child and an unrelated tree precede it.
	table := []unix.KinfoProc{
		trackerProcess(201, 200, 1_000_201),
		trackerProcess(104, 102, 1_000_104),
		trackerProcess(100, 1, 1_000_100),
		trackerProcess(103, 100, 1_000_103),
		trackerProcess(200, 1, 1_000_200),
		trackerProcess(102, 100, 1_000_102),
	}
	want := map[int]uint64{102: 1_000_102, 103: 1_000_103, 104: 1_000_104}
	tracker := &processTracker{root: 100, seen: make(map[int]uint64)}
	for offset := range table {
		tracker = &processTracker{root: 100, seen: make(map[int]uint64)}
		rotated := append(append([]unix.KinfoProc{}, table[offset:]...), table[:offset]...)
		tracker.captureTable(rotated)
		if !reflect.DeepEqual(tracker.seen, want) {
			t.Fatalf("rotation %d: identities = %v, want %v", offset, tracker.seen, want)
		}
	}

	// A previously observed descendant remains in custody after reparenting.
	// A reused pid is updated only when its new owner is itself a descendant;
	// signal's fresh birth check continues to reject an unrelated new owner.
	tracker.captureTable([]unix.KinfoProc{
		trackerProcess(102, 1, 2_000_102),
		trackerProcess(104, 1, 1_000_104),
		trackerProcess(103, 100, 2_000_103),
	})
	want[103] = 2_000_103
	if !reflect.DeepEqual(tracker.seen, want) {
		t.Fatalf("reparented identities = %v, want %v", tracker.seen, want)
	}
	tracker.captureTable(nil)
	if !reflect.DeepEqual(tracker.seen, want) {
		t.Fatalf("empty snapshot discarded custody: %v", tracker.seen)
	}
}

// TestProcessTrackerFreshEdges checks scratch reuse across reordered, empty,
// shrinking and growing snapshots. Historical custody must survive, while
// fresh unrelated processes must never inherit a stale parent link.
func TestProcessTrackerFreshEdges(t *testing.T) {
	tracker := &processTracker{root: 100, seen: make(map[int]uint64)}
	tracker.captureTable([]unix.KinfoProc{
		trackerProcess(101, 100, 101), trackerProcess(102, 101, 102),
		trackerProcess(201, 200, 201),
	})
	tracker.captureTable([]unix.KinfoProc{
		trackerProcess(301, 300, 301), trackerProcess(302, 301, 302),
		trackerProcess(303, 300, 303),
	})
	tracker.captureTable(nil)
	tracker.captureTable([]unix.KinfoProc{trackerProcess(401, 400, 401)})
	tracker.captureTable([]unix.KinfoProc{
		trackerProcess(501, 500, 501), trackerProcess(502, 501, 502),
		trackerProcess(503, 500, 503), trackerProcess(105, 100, 105),
	})
	want := map[int]uint64{101: 101, 102: 102, 105: 105}
	if !reflect.DeepEqual(tracker.seen, want) {
		t.Fatalf("fresh edges changed custody: %v, want %v", tracker.seen, want)
	}
}

func TestProcessTrackerSteadyCaptureAllocations(t *testing.T) {
	table := make([]unix.KinfoProc, 1200)
	for row := range table {
		table[row] = trackerProcess(row+2, row/6+1, int64(row+1))
	}
	tracker := &processTracker{root: 1, seen: make(map[int]uint64)}
	tracker.captureTable(table)
	if allocations := testing.AllocsPerRun(100, func() {
		tracker.captureTable(table)
	}); allocations != 0 {
		t.Fatalf("stable snapshot allocated %g times per capture", allocations)
	}
}

func TestProcessTrackerConcurrentCaptures(t *testing.T) {
	tracker := &processTracker{root: 100, seen: make(map[int]uint64)}
	var workers sync.WaitGroup
	for pid := 101; pid <= 102; pid++ {
		workers.Go(func() {
			table := []unix.KinfoProc{trackerProcess(pid, 100, int64(pid))}
			for range 100 {
				tracker.captureTable(table)
			}
		})
	}
	workers.Wait()
	want := map[int]uint64{101: 101, 102: 102}
	if !reflect.DeepEqual(tracker.seen, want) {
		t.Fatalf("concurrent custody = %v, want %v", tracker.seen, want)
	}
}

func BenchmarkProcessTrackerCaptureTable(b *testing.B) {
	table := make([]unix.KinfoProc, 1200)
	for row := range table {
		table[row] = trackerProcess(row+2, row/6+1, int64(row+1))
	}
	table[len(table)-1] = trackerProcess(2000, 1000, 1_002_000)
	tracker := &processTracker{root: 1000, seen: make(map[int]uint64)}
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		tracker.captureTable(table)
	}
}

// TestProcessTrackerSignalsOnlyObservedBirths exercises capture and delivery
// against real sleeping processes, with an unrelated process as the control.
func TestProcessTrackerSignalsOnlyObservedBirths(t *testing.T) {
	root := exec.Command("/bin/sh", "-c", "/bin/sleep 30 & printf '%s\n' \"$!\"; wait")
	root.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	out, err := root.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := root.Start(); err != nil {
		t.Fatal(err)
	}
	rootDone := make(chan struct{})
	go func() { _ = root.Wait(); close(rootDone) }()
	defer func() { _ = syscall.Kill(-root.Process.Pid, syscall.SIGKILL); <-rootDone }()
	line, err := bufio.NewReader(out).ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	child, err := strconv.Atoi(strings.TrimSpace(line))
	if err != nil {
		t.Fatal(err)
	}

	control := exec.Command("/bin/sleep", "30")
	control.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := control.Start(); err != nil {
		t.Fatal(err)
	}
	controlDone := make(chan struct{})
	go func() { _ = control.Wait(); close(controlDone) }()
	defer func() { _ = syscall.Kill(-control.Process.Pid, syscall.SIGKILL); <-controlDone }()
	tracker, err := startProcessTracker(root.Process.Pid)
	if err != nil {
		t.Fatal(err)
	}
	defer tracker.close()
	tracker.mu.Lock()
	_, childObserved := tracker.seen[child]
	_, controlObserved := tracker.seen[control.Process.Pid]

	// A remembered pid with the wrong birth must not authorize delivery.
	tracker.seen[control.Process.Pid] = 0
	tracker.mu.Unlock()
	if !childObserved || controlObserved {
		t.Fatalf("child observed=%v, unrelated observed=%v", childObserved, controlObserved)
	}
	if !tracker.signal(syscall.SIGTERM) {
		t.Fatal("TERM reached no observed descendant")
	}
	select {
	case <-rootDone:
	case <-time.After(5 * time.Second):
		t.Fatal("observed descendant did not receive TERM")
	}
	select {
	case <-controlDone:
		t.Fatal("unrelated sleeping control was signalled")
	case <-time.After(500 * time.Millisecond):
	}
}
