//go:build linux

package server_test

import (
	"io"
	"os"
	"strings"
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
	srv := server.New(framing.NewConn(toServerR, fromServerW), jail.DetectFeatures(), testbin.Helper(t), pol)
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
	if hello.Proto != framing.ProtoVersion || hello.Peer != "exec-helper" {
		t.Fatalf("hello = %+v", hello)
	}
	return hello
}

func sendHello(t *testing.T, h *harness) {
	t.Helper()
	if err := h.conn.Write(1, framing.KindHello, framing.Hello{Proto: 1, Peer: "broker"}); err != nil {
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
