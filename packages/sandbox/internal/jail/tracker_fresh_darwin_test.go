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
)

// Concurrent trackers must observe descendants born after both initial
// captures. Sharing a stale table would miss them; crossing roots would kill
// the unrelated execution. The process-local capture bound must do neither.
func TestConcurrentTrackersCaptureFreshDescendantsIndependently(t *testing.T) {
	type root struct {
		cmd    *exec.Cmd
		input  *os.File
		output *os.File
		done   chan struct{}
	}
	roots := make([]root, 2)
	trackers := make([]*processTracker, 2)
	t.Cleanup(func() {
		for _, tracker := range trackers {
			if tracker != nil {
				tracker.close()
			}
		}
		for _, r := range roots {
			if r.cmd != nil && r.cmd.Process != nil {
				_ = syscall.Kill(-r.cmd.Process.Pid, syscall.SIGKILL)
				r.input.Close()
				r.output.Close()
				<-r.done
			}
		}
	})
	for i := range roots {
		cmd := exec.Command("/bin/sh", "-c", "read ready; /bin/sleep 30 & printf '%s\\n' \"$!\"; wait")
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		input, err := cmd.StdinPipe()
		if err != nil {
			t.Fatal(err)
		}
		output, err := cmd.StdoutPipe()
		if err != nil {
			t.Fatal(err)
		}
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		done := make(chan struct{})
		go func() { _ = cmd.Wait(); close(done) }()
		roots[i] = root{cmd: cmd, input: input.(*os.File), output: output.(*os.File), done: done}
	}
	type result struct {
		index   int
		tracker *processTracker
		err     error
	}
	results := make(chan result, 2)
	for i := range roots {
		go func(index int) {
			tracker, err := startProcessTracker(roots[index].cmd.Process.Pid)
			results <- result{index, tracker, err}
		}(i)
	}
	var startErr error
	for range roots {
		r := <-results
		trackers[r.index] = r.tracker
		if r.err != nil {
			startErr = r.err
		}
	}
	if startErr != nil {
		t.Fatal(startErr)
	}
	children := make([]int, 2)
	for i, r := range roots {
		if _, err := fmt.Fprintln(r.input, "start"); err != nil {
			t.Fatal(err)
		}
		r.output.SetReadDeadline(time.Now().Add(5 * time.Second))
		line, err := bufio.NewReader(r.output).ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		children[i], err = strconv.Atoi(strings.TrimSpace(line))
		if err != nil {
			t.Fatal(err)
		}
	}
	if !trackers[0].signal(syscall.SIGTERM) {
		t.Fatal("fresh descendant was not observed")
	}
	trackers[0].mu.Lock()
	_, own := trackers[0].seen[children[0]]
	_, other := trackers[0].seen[children[1]]
	trackers[0].mu.Unlock()
	if !own || other {
		t.Fatalf("own descendant=%v unrelated descendant=%v", own, other)
	}
	select {
	case <-roots[0].done:
	case <-time.After(5 * time.Second):
		t.Fatal("target execution did not stop")
	}
	if err := syscall.Kill(children[1], 0); err != nil {
		t.Fatalf("unrelated descendant did not survive: %v", err)
	}
}
