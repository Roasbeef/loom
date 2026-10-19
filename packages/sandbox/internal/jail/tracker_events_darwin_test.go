//go:build darwin

package jail

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// Discovery must populate custody before signal's independent fresh capture.
// A second generation proves that watches extend beyond the gated root, and
// killing its parent proves that observed custody survives reparenting.
func TestProcessTrackerDiscoversForksAndRetainsOrphans(t *testing.T) {
	for _, fallback := range []bool{false, true} {
		t.Run(fmt.Sprintf("failed_queue=%v", fallback), func(t *testing.T) {
			readGate, writeGate, err := os.Pipe()
			if err != nil {
				t.Fatal(err)
			}
			defer readGate.Close()
			defer writeGate.Close()
			root := exec.Command("/bin/sh", "-c", "read ready <&3; /bin/sh -c 'read ready <&3; /bin/sleep 30 & echo $!; wait' & echo $!; wait")
			root.ExtraFiles = []*os.File{readGate}
			root.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
			out, err := root.StdoutPipe()
			if err != nil {
				t.Fatal(err)
			}
			if err := root.Start(); err != nil {
				t.Fatal(err)
			}
			done := make(chan struct{})
			go func() { _ = root.Wait(); close(done) }()
			defer func() { _ = syscall.Kill(-root.Process.Pid, syscall.SIGKILL); <-done }()

			var tracker *processTracker
			if fallback {
				// An unusable queue exercises the runtime fallback, not startup:
				// production refuses queue creation/registration failures there.
				tracker = &processTracker{root: root.Process.Pid, queue: -1,
					seen: make(map[int]uint64), stop: make(chan struct{}), done: make(chan struct{})}
				if err := tracker.capture(); err != nil {
					t.Fatal(err)
				}
				go tracker.run()
			} else {
				tracker, err = startProcessTracker(root.Process.Pid)
				if err != nil {
					t.Fatal(err)
				}
			}
			defer tracker.close()
			reader := bufio.NewReader(out)
			nextChild := func() int {
				t.Helper()
				if _, err := fmt.Fprintln(writeGate, "continue"); err != nil {
					t.Fatal(err)
				}
				if err := out.(*os.File).SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
					t.Fatal(err)
				}
				line, err := reader.ReadString('\n')
				if err != nil {
					t.Fatal(err)
				}
				pid, err := strconv.Atoi(strings.TrimSpace(line))
				if err != nil {
					t.Fatal(err)
				}
				deadline := time.Now().Add(5 * time.Second)
				for {
					tracker.mu.Lock()
					_, observed := tracker.seen[pid]
					tracker.mu.Unlock()
					if observed {
						return pid
					}
					if time.Now().After(deadline) {
						t.Fatalf("background discovery missed child %d", pid)
					}
					time.Sleep(time.Millisecond)
				}
			}
			parent, orphan := nextChild(), nextChild()
			if err := syscall.Kill(parent, syscall.SIGKILL); err != nil {
				t.Fatal(err)
			}
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				t.Fatal("root did not finish after its direct child exited")
			}
			if !tracker.signal(syscall.SIGTERM) {
				t.Fatal("no signal delivered to the remembered orphan")
			}
			deadline := time.Now().Add(5 * time.Second)
			for {
				err := syscall.Kill(orphan, 0)
				if err == unix.ESRCH {
					break
				}
				if time.Now().After(deadline) {
					t.Fatalf("remembered orphan %d survived cancellation: %v", orphan, err)
				}
				time.Sleep(time.Millisecond)
			}
		})
	}
}

func TestProcessTrackerRefusesMissingRoot(t *testing.T) {
	tracker, err := startProcessTracker(1<<31 - 1)
	if tracker != nil {
		tracker.close()
	}
	if err == nil {
		t.Fatal("missing root did not fail the gated preflight")
	}
}
