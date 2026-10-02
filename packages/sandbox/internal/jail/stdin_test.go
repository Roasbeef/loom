package jail

import (
	"bytes"
	"io"
	"os"
	"sync"
	"testing"
	"time"
)

// pipePair is a real kernel pipe: the queue's whole reason to exist is how
// a pipe write blocks, which an in-memory writer cannot reproduce.
func pipePair(t *testing.T) (r, w *os.File) {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { r.Close(); w.Close() })
	return r, w
}

// within fails the test if f does not return in time, so a regression is a
// named failure instead of a hung test binary.
func within(t *testing.T, d time.Duration, what string, f func()) {
	t.Helper()
	done := make(chan struct{})
	go func() { f(); close(done) }()
	select {
	case <-done:
	case <-time.After(d):
		t.Fatalf("%s did not return within %v", what, d)
	}
}

// Bytes reach the pipe in the order they were put, across chunks, and the
// pipe closes only after the last of them: EOF is ordered behind the data.
func TestStdinQueuePreservesOrderAndEOFFollowsData(t *testing.T) {
	r, w := pipePair(t)
	q := newStdinQueue(w)

	var want bytes.Buffer
	chunks := make([][]byte, 200)
	for i := range chunks {
		chunks[i] = bytes.Repeat([]byte{byte(i)}, 4096+i)
		want.Write(chunks[i])
	}
	go func() {
		for i, chunk := range chunks {
			if err := q.put(chunk, i == len(chunks)-1); err != nil {
				t.Errorf("put %d: %v", i, err)
				return
			}
		}
	}()

	var got []byte
	within(t, 10*time.Second, "reading to EOF", func() { got, _ = io.ReadAll(r) })
	if err := q.abandon(); err != nil {
		t.Fatalf("abandon: %v", err)
	}
	if !bytes.Equal(got, want.Bytes()) {
		t.Fatalf("stdin bytes differ: got %d, want %d", len(got), want.Len())
	}
}

// With a reader that never reads, the bound is the whole of what the frame
// loop may hand over without waiting, and one more byte waits. Abandon is
// what releases that wait, and it joins a writer that is blocked inside the
// kernel by closing the pipe under it.
func TestStdinQueueBoundsPendingBytesAndAbandonReleasesIt(t *testing.T) {
	_, w := pipePair(t)
	q := newStdinQueue(w)

	// Fill to exactly the bound. The first 64 KiB or so drains into the
	// kernel buffer, so the accounting is by what the writer completed:
	// keep putting until a put blocks, and require that to happen only
	// after at least the bound was accepted.
	chunk := make([]byte, 1<<20)
	accepted := 0
	blocked := make(chan struct{})
	released := make(chan error, 1)
	go func() {
		for {
			probe := make(chan error, 1)
			go func() { probe <- q.put(chunk, false) }()
			select {
			case err := <-probe:
				if err != nil {
					released <- err
					return
				}
				accepted += len(chunk)
			case <-time.After(300 * time.Millisecond):
				close(blocked)
				released <- <-probe
				return
			}
		}
	}()

	select {
	case <-blocked:
	case <-time.After(20 * time.Second):
		t.Fatal("put never waited: the pending bound is not enforced")
	}
	if accepted < StdinPendingMax {
		t.Fatalf("put waited after only %d accepted bytes, below the %d bound", accepted, StdinPendingMax)
	}
	if accepted > StdinPendingMax+(64<<10)+len(chunk) {
		t.Fatalf("accepted %d bytes for a reader that never read, bound is %d", accepted, StdinPendingMax)
	}

	within(t, 5*time.Second, "abandon of a blocked writer", func() { _ = q.abandon() })

	select {
	case err := <-released:
		if err == nil {
			t.Fatal("a put waiting for room was accepted after the execution ended")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("abandon did not release the put waiting for room")
	}
}

// The writer is joined: after abandon returns it is gone, and the pipe is
// closed, so a late put is refused rather than queued for nobody.
func TestStdinQueueAbandonJoinsAndRefusesLatePuts(t *testing.T) {
	r, w := pipePair(t)
	q := newStdinQueue(w)

	if err := q.put(make([]byte, 1<<20), false); err != nil {
		t.Fatal(err)
	}
	within(t, 5*time.Second, "abandon", func() { _ = q.abandon() })

	select {
	case <-q.done:
	default:
		t.Fatal("abandon returned with the writer goroutine still running")
	}
	if err := q.put([]byte("late"), false); err == nil {
		t.Fatal("put after abandon was accepted")
	}
	// The write end is closed, so draining the read end terminates.
	within(t, 5*time.Second, "draining a closed pipe", func() { _, _ = io.Copy(io.Discard, r) })
}

// abandon with nothing ever put must neither hang on a writer that was
// never started nor leave the pipe open, and is safe to repeat.
func TestStdinQueueAbandonWithoutWriter(t *testing.T) {
	r, w := pipePair(t)
	q := newStdinQueue(w)

	within(t, 5*time.Second, "abandon", func() {
		_ = q.abandon()
		_ = q.abandon()
	})
	within(t, 5*time.Second, "reading a closed pipe", func() { _, _ = io.Copy(io.Discard, r) })
}

// Nothing may follow EOF, whether or not the writer has closed the pipe
// yet, and a write the child's side refused is reported by the next put.
func TestStdinQueueRefusesAfterEOFAndReportsPipeFailure(t *testing.T) {
	_, w := pipePair(t)
	q := newStdinQueue(w)
	if err := q.put([]byte("x"), true); err != nil {
		t.Fatal(err)
	}
	if err := q.put([]byte("y"), false); err == nil {
		t.Fatal("put after eof was accepted")
	}
	_ = q.abandon()

	r2, w2 := pipePair(t)
	q2 := newStdinQueue(w2)
	r2.Close() // the child's end is gone: the next write is EPIPE
	if err := q2.put([]byte("first"), false); err != nil {
		t.Fatalf("first put is accepted before the write is attempted: %v", err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		if err := q2.put([]byte("again"), false); err != nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("a failed pipe write was never reported to a later put")
		}
		time.Sleep(5 * time.Millisecond)
	}
	_ = q2.abandon()
}

// Concurrent puts and an abandon must not race or deadlock.
func TestStdinQueueConcurrentPutAndAbandon(t *testing.T) {
	_, w := pipePair(t)
	q := newStdinQueue(w)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 50; j++ {
				if q.put(make([]byte, 100<<10), false) != nil {
					return
				}
			}
		}()
	}
	time.Sleep(50 * time.Millisecond)
	within(t, 5*time.Second, "abandon under load", func() { _ = q.abandon() })
	within(t, 5*time.Second, "releasing every put", wg.Wait)
}
