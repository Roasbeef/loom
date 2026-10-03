//go:build linux

package jail_test

import (
	"runtime"
	"strings"
	"testing"
	"time"
)

// Cancel and the wall deadline must not wait on a stdin write, and the
// execution's stdin writer must be gone by the time Wait returns: the
// helper's join (server.reapRunning, waitDone) is only as strong as that.
//
// The payload never reads. 1 MiB is sixteen pipe buffers, so the writer is
// provably blocked in the kernel when Cancel is called. Settle's abandon is
// what closes the pipe under it; the check is on the goroutine itself
// rather than on a counter, because a counter is what a leak would also
// satisfy.
func TestStdinWriterIsJoinedAndCancelDoesNotWaitOnIt(t *testing.T) {
	c := newCollector()
	ex := start(t, testPolicy(t), []string{"/bin/sh", "-c", "echo up; exec sleep 30"}, c.sink)
	waitFor(t, 20*time.Second, func() bool { return strings.Contains(c.out(), "up") })

	if err := ex.WriteStdin(make([]byte, 1<<20), false); err != nil {
		t.Fatalf("WriteStdin: %v", err)
	}
	// Let the writer fill the pipe and block on it.
	time.Sleep(100 * time.Millisecond)

	begin := time.Now()
	ex.Cancel()
	res := ex.Wait()
	if took := time.Since(begin); took > 3*time.Second {
		t.Fatalf("cancel took %v behind an unread stdin", took)
	}
	if !res.Cancelled {
		t.Fatalf("result = %+v, want cancelled", res)
	}

	buf := make([]byte, 1<<20)
	buf = buf[:runtime.Stack(buf, true)]
	if strings.Contains(string(buf), "(*stdinQueue).run") {
		t.Fatalf("a stdin writer goroutine outlived Wait:\n%s", buf)
	}
	if err := ex.WriteStdin([]byte("late"), false); err == nil {
		t.Fatal("stdin accepted a chunk after the execution ended")
	}
}
