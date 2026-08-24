package jail

// StreamLimiter enforces the per-stream output_bytes cap. It is pure
// bookkeeping: the caller feeds it chunk sizes and it answers how many
// bytes may pass and whether this chunk crossed the cap (which happens
// exactly once). After truncation the caller keeps *reading* the child's
// stream and discards — stopping would wedge the child on a full pipe,
// turning an output limit into an accidental deadlock.
type StreamLimiter struct {
	limit     uint64 // 0 = unlimited
	admitted  uint64
	truncated bool
}

// NewStreamLimiter returns a limiter with the given cap; 0 means no cap.
func NewStreamLimiter(limit uint64) *StreamLimiter {
	return &StreamLimiter{limit: limit}
}

// Admit accounts for a chunk of n bytes, returning how many of them may
// be forwarded and whether the cap was crossed by this chunk.
func (l *StreamLimiter) Admit(n int) (allow int, justTruncated bool) {
	if n <= 0 {
		return 0, false
	}
	if l.limit == 0 {
		l.admitted += uint64(n)
		return n, false
	}
	if l.truncated {
		return 0, false
	}
	remaining := l.limit - l.admitted
	if uint64(n) <= remaining {
		l.admitted += uint64(n)
		return n, false
	}
	l.admitted = l.limit
	l.truncated = true
	return int(remaining), true
}

// Admitted is the cumulative bytes forwarded (the exec_out counter).
func (l *StreamLimiter) Admitted() uint64 { return l.admitted }

// Truncated reports whether the cap was hit.
func (l *StreamLimiter) Truncated() bool { return l.truncated }
