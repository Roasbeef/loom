package jail

import (
	"fmt"
	"io"
	"sync"
)

// StdinPendingMax bounds the stdin bytes one execution may have accepted
// from the frame loop and not yet written into the child's pipe. It equals
// framing.MaxFrameLen (16 MiB), the largest frame the wire admits, so a
// well-behaved broker's single largest chunk always fits and the bound only
// ever bites a sender that keeps feeding a payload which is not reading.
//
// This package does not import framing, so the equality is a convention
// pinned by a test in internal/server rather than by the type system.
const StdinPendingMax = 1 << 24

// stdinQueue decouples the frame loop from the child's stdin pipe.
//
// A pipe write blocks as soon as the kernel buffer (64 KiB on Linux) is
// full, and a payload that never reads stdin keeps it full forever. When
// the write ran inline on the helper's one frame-reading goroutine, and
// under the lock that Cancel and the wall-clock deadline also take, one
// such payload stopped the helper from reading cancel, heartbeat and
// shutdown frames and stopped its own deadline from firing. The broker's
// only remaining recourse was killing the whole helper, which loses the
// native-exit witness and strands a pool slot.
//
// So the frame loop only appends a chunk to a FIFO, and one writer
// goroutine per execution, started by the first chunk, drains it into the
// pipe. The queue's mutex is held for bookkeeping only and never across a
// pipe write, and it is not the Exec's mutex, so nothing Cancel or the
// deadline touches can be held by a blocked writer.
//
// # Backpressure
//
// Pending bytes are counted until their write has completed and are
// bounded by StdinPendingMax. Only a chunk that would push the count past
// the bound makes put wait for room. That wait is the pathological case:
// it requires 16 MiB queued for a payload that is not reading, and it ends
// the moment the payload reads, or the execution ends and abandon releases
// it. Cancel and the deadline are lock-free with respect to the writer, so
// they still bound it by terminating the payload.
//
// # Lifetime
//
// The writer goroutine exits when the queue drains after an EOF (having
// closed the pipe), when a write fails, or when abandon is called. abandon
// is the end-of-execution join: it drops whatever is still queued, closes
// the pipe, which interrupts a write blocked in the kernel, and waits for
// the writer to return. Exec.Settle calls it before the execution's exit
// frame can be written, so by the time the helper's waitDone closes no
// writer goroutine of that execution is left.
type stdinQueue struct {
	w io.WriteCloser

	mu      sync.Mutex
	changed *sync.Cond // signalled on every change to the fields below

	chunks  [][]byte
	pending int
	// sealed is set when the EOF chunk has been accepted: no further
	// chunk may follow it, and the writer closes the pipe once the queue
	// drains.
	sealed bool
	// abandoned is set by abandon: the execution is over, the queue's
	// contents are moot, and puts fail instead of waiting.
	abandoned bool
	// failed holds the first pipe write error. It is sticky and is
	// reported to the next put, because the chunk that failed was already
	// acknowledged to the frame loop.
	failed  error
	started bool
	done    chan struct{} // closed when the writer goroutine has returned

	closeOnce sync.Once
	closeErr  error
}

func newStdinQueue(w io.WriteCloser) *stdinQueue {
	q := &stdinQueue{w: w, done: make(chan struct{})}
	q.changed = sync.NewCond(&q.mu)
	return q
}

// put accepts one chunk, and eof marks the stream finished after it. It
// returns without waiting for the chunk to reach the child, except in the
// bounded-pending case described on stdinQueue. The data is copied: the
// pipe write happens after put returns, and callers are entitled to reuse
// their buffer, as they could when the write was synchronous.
//
// An error means the chunk was not accepted: stdin was already ended, the
// execution is over, or an earlier chunk's write failed (typically EPIPE
// from a child that closed its stdin).
func (q *stdinQueue) put(data []byte, eof bool) error {
	q.mu.Lock()
	defer q.mu.Unlock()

	for {
		switch {
		case q.sealed:
			return fmt.Errorf("jail: stdin already closed")
		case q.abandoned:
			return fmt.Errorf("jail: write stdin: execution has ended")
		case q.failed != nil:
			return fmt.Errorf("jail: write stdin: %w", q.failed)
		}

		// An empty queue always admits, so a chunk larger than the bound
		// (not reachable through the wire, reachable through the Go API)
		// cannot wait for room that will never exist.
		if q.pending == 0 || q.pending+len(data) <= StdinPendingMax {
			break
		}
		q.changed.Wait()
	}

	if len(data) > 0 {
		q.chunks = append(q.chunks, append([]byte(nil), data...))
		q.pending += len(data)
	}
	if eof {
		q.sealed = true
	}

	if !q.started {
		q.started = true
		go q.run()
	}
	q.changed.Broadcast()
	return nil
}

// run is the writer goroutine: pop the oldest chunk, write it with no lock
// held, then account for it. Strict FIFO order is what keeps the child's
// stdin byte-identical to what the broker sent.
func (q *stdinQueue) run() {
	defer close(q.done)

	for {
		q.mu.Lock()
		for len(q.chunks) == 0 && !q.sealed && !q.abandoned {
			q.changed.Wait()
		}
		if q.abandoned {
			q.mu.Unlock()
			return
		}
		if len(q.chunks) == 0 {
			// Sealed and drained: EOF is the pipe closing, after every
			// queued byte has been written.
			q.mu.Unlock()
			_ = q.closePipe()
			return
		}
		chunk := q.chunks[0]
		q.chunks[0] = nil
		q.chunks = q.chunks[1:]
		q.mu.Unlock()

		_, err := q.w.Write(chunk)

		q.mu.Lock()
		if !q.abandoned {
			q.pending -= len(chunk)
			if err != nil {
				q.failed = err
			}
		}
		// An error after abandon is the end-of-execution close landing
		// under a blocked write: the join working, not a failure to report.
		q.changed.Broadcast()
		failed := q.failed != nil
		q.mu.Unlock()

		if failed {
			return
		}
	}
}

// abandon ends the queue: pending chunks are dropped, a put that is waiting
// for room is released with an error, the pipe is closed, and the writer
// goroutine is joined. It is safe to call more than once and when no chunk
// was ever put.
func (q *stdinQueue) abandon() error {
	q.mu.Lock()
	q.abandoned = true
	q.chunks = nil
	q.pending = 0
	started := q.started
	q.changed.Broadcast()
	q.mu.Unlock()

	// Closing is what unblocks a write stuck on a full pipe, so it must
	// precede the join.
	err := q.closePipe()
	if started {
		<-q.done
	}
	return err
}

// closePipe closes the child's stdin exactly once, whichever of the writer
// (EOF drained) and abandon (execution over) gets there first.
func (q *stdinQueue) closePipe() error {
	q.closeOnce.Do(func() { q.closeErr = q.w.Close() })
	return q.closeErr
}
