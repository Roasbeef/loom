//go:build linux

package server_test

import (
	"bytes"
	"io"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/roasbeef/loom/sandbox/internal/framing"
	"github.com/roasbeef/loom/sandbox/internal/jail"
	"github.com/roasbeef/loom/sandbox/internal/policy"
	"github.com/roasbeef/loom/sandbox/internal/server"
	"github.com/roasbeef/loom/sandbox/internal/testbin"
)

// harness wires a Server to an in-memory duplex channel and runs it.
type harness struct {
	conn    *framing.Conn // the broker's side
	rawW    io.Writer     // broker→server pipe, for malformed-byte tests
	stopped chan struct{} // closed when Run returns
	runErr  error         // valid after stopped is closed
}

// waitStopped blocks until the server goroutine returns and yields its
// error. Safe to call any number of times.
func (h *harness) waitStopped(t *testing.T) error {
	t.Helper()
	select {
	case <-h.stopped:
		return h.runErr
	case <-time.After(10 * time.Second):
		t.Fatal("server did not stop")
		return nil
	}
}

func newHarness(t *testing.T, pol policy.Policy) *harness {
	t.Helper()
	return newHarnessWrapped(t, pol, nil)
}

// newHarnessWrapped is newHarness with the server's outbound stream
// wrapped. A test that needs to observe or delay a particular frame's
// write supplies wrap; everything else passes nil.
func newHarnessWrapped(t *testing.T, pol policy.Policy, wrap func(io.Writer) io.Writer) *harness {
	t.Helper()
	// Real kernel pipes, not io.Pipe: production speaks over stdio
	// pipes with kernel buffering, and io.Pipe's rendezvous semantics
	// would manufacture write-write deadlocks no real deployment has.
	toServerR, toServerW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	fromServerR, fromServerW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		toServerR.Close()
		fromServerR.Close()
		fromServerW.Close()
	})
	var out io.Writer = fromServerW
	if wrap != nil {
		out = wrap(out)
	}

	srv := server.New(framing.NewConn(toServerR, out), jail.DetectFeatures(), testbin.Helper(t), pol)
	h := &harness{
		conn:    framing.NewConn(fromServerR, toServerW),
		rawW:    toServerW,
		stopped: make(chan struct{}),
	}
	go func() { h.runErr = srv.Run(); close(h.stopped) }()
	t.Cleanup(func() {
		_ = toServerW.Close()
		h.waitStopped(t)
	})
	return h
}

func testPol(t *testing.T) policy.Policy {
	return policy.Policy{
		WritableRoots: []string{t.TempDir()},
		ReadableRoots: []string{},
		Protected:     []string{},
		Network:       policy.Network{Mode: policy.NetworkOff},
		Limits:        policy.Limits{WallSeconds: 30, OutputBytes: 1 << 20},
		EnvAllow:      []string{"PATH"},
		Scratch:       "tmpfs",
	}
}

// expectHello reads and validates the server's opening hello.
func expectHello(t *testing.T, h *harness) framing.Hello {
	t.Helper()
	f, err := h.conn.Read()
	if err != nil {
		t.Fatalf("read hello: %v", err)
	}
	if f.Kind != framing.KindHello {
		t.Fatalf("first frame kind = %s, want hello", f.Kind)
	}
	var hello framing.Hello
	if err := framing.DecodeBody(f.Body, &hello); err != nil {
		t.Fatalf("decode hello: %v", err)
	}
	if hello.Proto != framing.ExecProtocolVersion || hello.Peer != "exec-helper" {
		t.Fatalf("hello = %+v", hello)
	}
	return hello
}

func sendHello(t *testing.T, h *harness) {
	t.Helper()
	if err := h.conn.Write(1, framing.KindHello, framing.Hello{Proto: framing.ExecProtocolVersion, Peer: "broker"}); err != nil {
		t.Fatalf("send hello: %v", err)
	}
}

func TestHandshakeAndHeartbeat(t *testing.T) {
	h := newHarness(t, testPol(t))
	hello := expectHello(t, h)
	if len(hello.Features) == 0 {
		t.Fatal("hello carries no features")
	}
	sendHello(t, h)
	if err := h.conn.Write(5, framing.KindHeartbeat, map[string]any{}); err != nil {
		t.Fatal(err)
	}
	f, err := h.conn.Read()
	if err != nil {
		t.Fatalf("read heartbeat: %v", err)
	}
	if f.Kind != framing.KindHeartbeat || f.ID != 5 {
		t.Fatalf("heartbeat echo = %+v", f)
	}
}

func TestExecThroughProtocol(t *testing.T) {
	h := newHarness(t, testPol(t))
	expectHello(t, h)
	sendHello(t, h)

	if err := h.conn.Write(10, framing.KindExecStart, framing.ExecStart{
		Argv:  []string{"/bin/sh", "-c", "echo over-the-wire; exit 7"},
		Env:   map[string]string{"PATH": "/usr/bin:/bin"},
		Cwd:   "/",
		Token: make([]byte, 32),
	}); err != nil {
		t.Fatal(err)
	}
	if err := h.conn.Write(11, framing.KindExecStdin, framing.ExecStdin{EOF: true}); err != nil {
		t.Fatal(err)
	}

	var stdout strings.Builder
	var exit framing.ExecExit
	for {
		f, err := h.conn.Read()
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		switch f.Kind {
		case framing.KindExecOut:
			var out framing.ExecOut
			if err := framing.DecodeBody(f.Body, &out); err != nil {
				t.Fatal(err)
			}
			if f.ID != 10 {
				t.Fatalf("exec_out id = %d, want 10", f.ID)
			}
			if out.Stream == "stdout" {
				stdout.Write(out.Data)
				if out.Bytes != uint64(stdout.Len()) {
					t.Fatalf("cumulative counter %d != received %d", out.Bytes, stdout.Len())
				}
			}
		case framing.KindExecExit:
			if f.ID != 10 {
				t.Fatalf("exec_exit id = %d, want 10", f.ID)
			}
			if err := framing.DecodeBody(f.Body, &exit); err != nil {
				t.Fatal(err)
			}
			if exit.Code != 7 {
				t.Fatalf("exit code = %d, want 7", exit.Code)
			}
			if stdout.String() != "over-the-wire\n" {
				t.Fatalf("stdout = %q", stdout.String())
			}
			if exit.StdoutBytes != uint64(len("over-the-wire\n")) {
				t.Fatalf("StdoutBytes = %d", exit.StdoutBytes)
			}
			return
		case framing.KindError:
			var e framing.ErrorBody
			_ = framing.DecodeBody(f.Body, &e)
			t.Fatalf("error frame: %+v", e)
		}
	}
}

func TestExecStdinThroughProtocol(t *testing.T) {
	h := newHarness(t, testPol(t))
	expectHello(t, h)
	sendHello(t, h)

	if err := h.conn.Write(20, framing.KindExecStart, framing.ExecStart{
		Argv:  []string{"/bin/cat"},
		Env:   map[string]string{"PATH": "/usr/bin:/bin"},
		Cwd:   "/",
		Token: make([]byte, 32),
	}); err != nil {
		t.Fatal(err)
	}
	if err := h.conn.Write(21, framing.KindExecStdin, framing.ExecStdin{Data: []byte("ping\n")}); err != nil {
		t.Fatal(err)
	}
	if err := h.conn.Write(22, framing.KindExecStdin, framing.ExecStdin{EOF: true}); err != nil {
		t.Fatal(err)
	}
	var stdout strings.Builder
	for {
		f, err := h.conn.Read()
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		if f.Kind == framing.KindExecOut {
			var out framing.ExecOut
			_ = framing.DecodeBody(f.Body, &out)
			if out.Stream == "stdout" {
				stdout.Write(out.Data)
			}
		}
		if f.Kind == framing.KindExecExit {
			if stdout.String() != "ping\n" {
				t.Fatalf("stdout = %q", stdout.String())
			}
			return
		}
	}
}

func TestBusyRefusesSecondExec(t *testing.T) {
	h := newHarness(t, testPol(t))
	expectHello(t, h)
	sendHello(t, h)

	startBody := framing.ExecStart{
		Argv:  []string{"/bin/sleep", "10"},
		Env:   map[string]string{"PATH": "/usr/bin:/bin"},
		Cwd:   "/",
		Token: make([]byte, 32),
	}
	if err := h.conn.Write(30, framing.KindExecStart, startBody); err != nil {
		t.Fatal(err)
	}
	if err := h.conn.Write(31, framing.KindExecStart, startBody); err != nil {
		t.Fatal(err)
	}
	// The second start must be refused as busy; then cancel the first
	// and see its exec_exit.
	sawBusy := false
	if err := h.conn.Write(32, framing.KindCancel, map[string]any{}); err != nil {
		t.Fatal(err)
	}
	for {
		f, err := h.conn.Read()
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		if f.Kind == framing.KindError {
			var e framing.ErrorBody
			_ = framing.DecodeBody(f.Body, &e)
			if e.Code == framing.ErrCodeBusy && f.ID == 31 {
				sawBusy = true
			}
		}
		if f.Kind == framing.KindExecExit {
			if f.ID != 30 {
				t.Fatalf("exec_exit id = %d, want 30", f.ID)
			}
			if !sawBusy {
				t.Fatal("second exec_start was not refused busy")
			}
			return
		}
	}
}

// frameGate holds the first write whose bytes contain match until the
// test releases it. Conn.Write emits a whole frame in one Write call
// under its own mutex, so holding that call holds exactly that frame.
type frameGate struct {
	w        io.Writer
	match    []byte
	reached  chan struct{} // closed once the matching write has begun
	release  chan struct{} // closed by the test to let it through
	announce sync.Once
	freed    sync.Once
}

func (g *frameGate) Write(p []byte) (int, error) {
	if bytes.Contains(p, g.match) {
		g.announce.Do(func() { close(g.reached) })
		<-g.release
	}
	return g.w.Write(p)
}

// letThrough releases the held frame. Idempotent, so a test can defer it
// and still release early on the happy path.
func (g *frameGate) letThrough() {
	g.freed.Do(func() { close(g.release) })
}

// A helper is free the moment its child has been reaped, not the moment
// the exit frame it reports with has finished being written. The broker
// moves its own state machine to Idle on reading exec_exit and may
// dispatch the next exec_start immediately, so a helper that only
// stopped calling itself busy after that write refused a strictly
// sequential caller whenever the two orders raced. It was seen once on
// CI and passed on rerun, which is what a window this narrow looks like.
//
// The test closes the window deterministically instead of racing it: the
// first execution's exec_exit write is held inside the writer, so at the
// moment the second exec_start is dispatched the frame provably has not
// been written and the old "free" signal provably has not fired. The
// second execution's own child creating a file inside the writable root
// is the witness that it started, since every frame it would otherwise
// send is queued behind the held write.
//
// What it does not prove: nothing about the broker's side of the
// dispatch, and nothing about an execution overlapping another for real
// — one at a time still holds, and the second start here is only
// admitted because the first child is gone.
func TestExitFrameWriteDoesNotHoldTheHelperBusy(t *testing.T) {
	dir := t.TempDir()
	pol := testPol(t)
	pol.WritableRoots = []string{dir}

	gate := &frameGate{
		match:   []byte(framing.KindExecExit),
		reached: make(chan struct{}),
		release: make(chan struct{}),
	}
	h := newHarnessWrapped(t, pol, func(w io.Writer) io.Writer {
		gate.w = w
		return gate
	})
	defer gate.letThrough()

	expectHello(t, h)
	sendHello(t, h)

	if err := h.conn.Write(50, framing.KindExecStart, framing.ExecStart{
		Argv:  []string{"/bin/true"},
		Env:   map[string]string{"PATH": "/usr/bin:/bin"},
		Cwd:   "/",
		Token: make([]byte, 32),
	}); err != nil {
		t.Fatal(err)
	}

	select {
	case <-gate.reached:
	case <-time.After(30 * time.Second):
		t.Fatal("first execution never reached its exec_exit write")
	}

	// From here until letThrough, the helper is between reaping its
	// child and finishing the report of it. That is the whole window
	// the bug lived in.
	marker := dir + "/second-started"
	if err := h.conn.Write(51, framing.KindExecStart, framing.ExecStart{
		Argv:  []string{"/bin/sh", "-c", "> " + marker},
		Env:   map[string]string{"PATH": "/usr/bin:/bin"},
		Cwd:   "/",
		Token: make([]byte, 32),
	}); err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(15 * time.Second)
	started := false
	for time.Now().Before(deadline) {
		if _, err := os.Stat(marker); err == nil {
			started = true
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	gate.letThrough()
	if !started {
		// Drain what the helper did say; a busy refusal for id 51 is
		// the regression and deserves to be named rather than left as
		// an unexplained timeout.
		for {
			f, err := h.conn.Read()
			if err != nil {
				t.Fatal("second execution never started, and no frame explained why")
			}
			if f.Kind == framing.KindError {
				var e framing.ErrorBody
				_ = framing.DecodeBody(f.Body, &e)
				t.Fatalf("second exec_start refused: id=%d %+v", f.ID, e)
			}
			if f.Kind == framing.KindExecExit && f.ID == 51 {
				t.Fatal("second execution exited without creating its marker")
			}
		}
	}

	// Both executions must still settle in order, each under its own id.
	seen := []uint64{}
	for len(seen) < 2 {
		f, err := h.conn.Read()
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		if f.Kind == framing.KindError {
			var e framing.ErrorBody
			_ = framing.DecodeBody(f.Body, &e)
			t.Fatalf("error frame: id=%d %+v", f.ID, e)
		}
		if f.Kind == framing.KindExecExit {
			seen = append(seen, f.ID)
		}
	}
	if seen[0] != 50 || seen[1] != 51 {
		t.Fatalf("exec_exit ids = %v, want [50 51]", seen)
	}
}

func TestExecStartBeforeHelloCloses(t *testing.T) {
	h := newHarness(t, testPol(t))
	expectHello(t, h)
	if err := h.conn.Write(40, framing.KindExecStart, framing.ExecStart{
		Argv: []string{"/bin/true"}, Token: make([]byte, 32),
	}); err != nil {
		t.Fatal(err)
	}
	f, err := h.conn.Read()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if f.Kind != framing.KindError {
		t.Fatalf("kind = %s, want error", f.Kind)
	}
	if err := h.waitStopped(t); err == nil {
		t.Fatal("server did not treat pre-hello traffic as fatal")
	}
}

func TestProtoMismatchCloses(t *testing.T) {
	h := newHarness(t, testPol(t))
	expectHello(t, h)
	if err := h.conn.Write(1, framing.KindHello, framing.Hello{Proto: 99, Peer: "broker"}); err != nil {
		t.Fatal(err)
	}
	f, err := h.conn.Read()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var e framing.ErrorBody
	if f.Kind != framing.KindError || framing.DecodeBody(f.Body, &e) != nil || e.Code != framing.ErrCodeProto {
		t.Fatalf("frame = %+v body %+v", f, e)
	}
	if err := h.waitStopped(t); err == nil {
		t.Fatal("server survived a version-mismatched hello")
	}
}

func TestMalformedFrameCloses(t *testing.T) {
	h := newHarness(t, testPol(t))
	expectHello(t, h)
	sendHello(t, h)
	// Raw garbage with a plausible length prefix.
	raw := []byte{0x00, 0x00, 0x00, 0x04, 0xde, 0xad, 0xbe, 0xef}
	if _, err := writeRaw(h, raw); err != nil {
		t.Fatal(err)
	}
	f, err := h.conn.Read()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if f.Kind != framing.KindError {
		t.Fatalf("kind = %s, want error", f.Kind)
	}
	if err := h.waitStopped(t); err == nil {
		t.Fatal("server kept the channel after a malformed frame")
	}
}

func TestUnknownKindKeepsChannel(t *testing.T) {
	h := newHarness(t, testPol(t))
	expectHello(t, h)
	sendHello(t, h)
	if err := h.conn.Write(50, "cap_call", map[string]any{"cap": "fs.read"}); err != nil {
		t.Fatal(err)
	}
	f, err := h.conn.Read()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var e framing.ErrorBody
	if f.Kind != framing.KindError || framing.DecodeBody(f.Body, &e) != nil || e.Code != framing.ErrCodeUnknownKind {
		t.Fatalf("frame = %+v body %+v", f, e)
	}
	// Channel still alive: heartbeat round-trips.
	if err := h.conn.Write(51, framing.KindHeartbeat, map[string]any{}); err != nil {
		t.Fatal(err)
	}
	f, err = h.conn.Read()
	if err != nil || f.Kind != framing.KindHeartbeat {
		t.Fatalf("heartbeat after unknown kind: %+v, %v", f, err)
	}
}

func TestBadInlinePolicyRefused(t *testing.T) {
	h := newHarness(t, testPol(t))
	expectHello(t, h)
	sendHello(t, h)
	badPolicy, err := framing.MarshalBody(map[string]any{"v": 42})
	if err != nil {
		t.Fatal(err)
	}
	if err := h.conn.Write(60, framing.KindExecStart, framing.ExecStart{
		Argv:   []string{"/bin/true"},
		Token:  make([]byte, 32),
		Policy: badPolicy,
	}); err != nil {
		t.Fatal(err)
	}
	f, err := h.conn.Read()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var e framing.ErrorBody
	if f.Kind != framing.KindError || framing.DecodeBody(f.Body, &e) != nil || e.Code != framing.ErrCodeBadPolicy {
		t.Fatalf("frame = %+v body %+v", f, e)
	}
}

// writeRaw pushes raw bytes onto the broker→server pipe, bypassing the
// framing encoder (for malformed-input tests).
func writeRaw(h *harness, raw []byte) (int, error) {
	return h.rawW.Write(raw)
}
