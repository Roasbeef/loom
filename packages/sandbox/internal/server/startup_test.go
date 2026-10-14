//go:build darwin || linux

package server

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/roasbeef/loom/sandbox/internal/framing"
	"github.com/roasbeef/loom/sandbox/internal/jail"
	"github.com/roasbeef/loom/sandbox/internal/policy"
	"github.com/roasbeef/loom/sandbox/internal/testbin"
)

type startupGate struct {
	ready chan struct{}
	once  sync.Once
}

func (g *startupGate) open() { g.once.Do(func() { close(g.ready) }) }

// The private start seam holds acquisition before calling the real jail. The
// wire and all terminal/enforcement handling remain production code.
type startupHarness struct {
	srv           *Server
	conn          *framing.Conn
	input, output *os.File
	entered       chan uint64
	gates         map[uint64]*startupGate
	done          chan error
	workspace     string
}

func newStartupHarness(t *testing.T, fail uint64, wrap func(io.Writer) io.Writer) *startupHarness {
	t.Helper()
	inR, inW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	outR, outW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	h := &startupHarness{input: inW, output: outR, conn: framing.NewConn(outR, inW), entered: make(chan uint64, 16), gates: map[uint64]*startupGate{}, done: make(chan error, 1), workspace: t.TempDir()}
	for id := uint64(1); id < 64; id++ {
		h.gates[id] = &startupGate{ready: make(chan struct{})}
	}
	pol := policy.Policy{WritableRoots: []string{h.workspace}, ReadableRoots: []string{}, Protected: []string{}, Network: policy.Network{Mode: policy.NetworkOff}, Limits: policy.Limits{WallSeconds: 30, OutputBytes: 1 << 20}, EnvAllow: []string{"PATH"}, Scratch: "tmpfs"}
	var writer io.Writer = outW
	if wrap != nil {
		writer = wrap(writer)
	}
	h.srv = New(framing.NewConn(inR, writer), jail.DetectFeatures(), testbin.Helper(t), pol)
	h.srv.start = func(req jail.Request, feat jail.Features, self string, sink jail.OutputSink) (*jail.Exec, error) {
		h.entered <- req.ID
		<-h.gates[req.ID].ready
		if req.ID == fail {
			return nil, fmt.Errorf("startup test refusal")
		}
		return jail.Start(req, feat, self, sink)
	}
	go func() { h.done <- h.srv.Run() }()
	t.Cleanup(func() {
		for _, gate := range h.gates {
			gate.open()
		}
		inW.Close()
		outR.Close()
		outW.Close()
		inR.Close()
		select {
		case <-h.done:
		case <-time.After(10 * time.Second):
			t.Error("startup worker did not join")
		}
	})
	if f := h.read(t); f.Kind != framing.KindHello {
		t.Fatalf("hello: %+v", f)
	}
	h.write(t, 1, framing.KindHello, framing.Hello{Proto: framing.ExecProtocolVersion, Peer: "broker"})
	return h
}
func (h *startupHarness) read(t *testing.T) framing.Frame {
	t.Helper()
	h.output.SetReadDeadline(time.Now().Add(10 * time.Second))
	f, err := h.conn.Read()
	if err != nil {
		t.Fatal(err)
	}
	return f
}
func (h *startupHarness) write(t *testing.T, id uint64, kind string, body any) {
	t.Helper()
	if err := h.conn.Write(id, kind, body); err != nil {
		t.Fatal(err)
	}
}
func (h *startupHarness) start(t *testing.T, id uint64, script string) {
	h.write(t, id, framing.KindExecStart, framing.ExecStart{Argv: []string{"/bin/sh", "-c", script}, Cwd: "/", Env: map[string]string{"PATH": "/usr/bin:/bin"}, Token: make([]byte, 32)})
}
func (h *startupHarness) starting(t *testing.T, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		select {
		case <-h.entered:
		case <-time.After(3 * time.Second):
			t.Fatal("startup was serialized behind another held start")
		}
	}
}
func (h *startupHarness) exits(t *testing.T, n int) (map[uint64]framing.ExecExit, map[uint64]string) {
	t.Helper()
	exits := map[uint64]framing.ExecExit{}
	output := map[uint64]string{}
	for len(exits) < n {
		f := h.read(t)
		switch f.Kind {
		case framing.KindError:
			t.Fatalf("unexpected error: %s", f.Body)
		case framing.KindExecOut:
			var out framing.ExecOut
			if err := framing.DecodeBody(f.Body, &out); err != nil {
				t.Fatal(err)
			}
			output[f.ID] += string(out.Data)
		case framing.KindExecExit:
			var exit framing.ExecExit
			if err := framing.DecodeBody(f.Body, &exit); err != nil {
				t.Fatal(err)
			}
			if _, seen := exits[f.ID]; seen {
				t.Fatal("duplicate terminal")
			}
			exits[f.ID] = exit
		}
	}
	return exits, output
}

func TestStartupRunsConcurrentlyAndPreservesEarlyStdin(t *testing.T) {
	h := newStartupHarness(t, 0, nil)
	h.start(t, 10, "exec cat")
	h.start(t, 20, "exec cat")
	h.starting(t, 2)
	h.write(t, 100, framing.KindExecStdin, framing.ExecStdin{ExecID: 10, Data: []byte("first-")})
	h.write(t, 101, framing.KindExecStdin, framing.ExecStdin{ExecID: 20, Data: []byte("other\n"), EOF: true})
	h.write(t, 102, framing.KindExecStdin, framing.ExecStdin{ExecID: 10, Data: []byte("second\n"), EOF: true})
	h.write(t, 104, framing.KindExecStdin, framing.ExecStdin{ExecID: 10, Data: []byte("after-eof")})
	f := h.read(t)
	var refusal framing.ErrorBody
	if f.ID != 104 || f.Kind != framing.KindError || framing.DecodeBody(f.Body, &refusal) != nil || refusal.Code != framing.ErrCodeNoExec {
		t.Fatalf("late startup input: %+v %+v", f, refusal)
	}
	h.gates[10].open()
	h.gates[20].open()
	exits, out := h.exits(t, 2)
	if out[10] != "first-second\n" || out[20] != "other\n" || exits[10].Code != 0 || exits[20].Code != 0 || exits[10].Cancelled || exits[20].Cancelled {
		t.Fatalf("outputs=%+v exits=%+v", out, exits)
	}
}

func TestStartupCancellationAndInputOverflowStayTargeted(t *testing.T) {
	for _, overflow := range []bool{false, true} {
		t.Run(map[bool]string{false: "cancel", true: "overflow"}[overflow], func(t *testing.T) {
			h := newStartupHarness(t, 0, nil)
			h.start(t, 10, "exec sleep 30")
			h.start(t, 20, "exec cat")
			h.starting(t, 2)
			if overflow {
				for id := uint64(100); id < 103; id++ {
					h.write(t, id, framing.KindExecStdin, framing.ExecStdin{ExecID: 10, Data: make([]byte, 8<<20)})
				}
				f := h.read(t)
				var refusal framing.ErrorBody
				if f.ID != 102 || f.Kind != framing.KindError || framing.DecodeBody(f.Body, &refusal) != nil || refusal.Code != framing.ErrCodeNoExec {
					t.Fatalf("overflow: %+v %+v", f, refusal)
				}
				h.srv.mu.Lock()
				pending := len(h.srv.running[10].pending)
				h.srv.mu.Unlock()
				if pending != 0 {
					t.Fatal("cancelled startup retained stdin")
				}
			} else {
				h.write(t, 100, framing.KindCancel, framing.Cancel{ExecID: 10})
			}
			h.write(t, 103, framing.KindExecStdin, framing.ExecStdin{ExecID: 20, Data: []byte("survivor\n"), EOF: true})
			h.gates[10].open()
			h.gates[20].open()
			exits, out := h.exits(t, 2)
			if !exits[10].Cancelled || exits[20].Cancelled || exits[20].Code != 0 || out[20] != "survivor\n" {
				t.Fatalf("outputs=%+v exits=%+v", out, exits)
			}
		})
	}
}

func TestStartupCapacityAndDuplicateAreReservedBeforeAcquisition(t *testing.T) {
	h := newStartupHarness(t, 0, nil)
	for id := uint64(10); id < 14; id++ {
		h.start(t, id, "exec sleep 30")
	}
	h.starting(t, 4)
	h.start(t, 10, "exit 0")
	h.start(t, 14, "exit 0")
	for _, want := range []struct {
		id   uint64
		code string
	}{{10, framing.ErrCodeMalformed}, {14, framing.ErrCodeBusy}} {
		f := h.read(t)
		var refusal framing.ErrorBody
		if f.ID != want.id || f.Kind != framing.KindError || framing.DecodeBody(f.Body, &refusal) != nil || refusal.Code != want.code {
			t.Fatalf("refusal: %+v %+v", f, refusal)
		}
	}
	select {
	case id := <-h.entered:
		t.Fatalf("extra startup admitted: %d", id)
	default:
	}
	h.write(t, 100, framing.KindShutdown, map[string]any{})
	for id := uint64(10); id < 14; id++ {
		h.gates[id].open()
	}
	exits, _ := h.exits(t, 4)
	for id, exit := range exits {
		if !exit.Cancelled {
			t.Fatalf("shutdown missed startup %d: %+v", id, exit)
		}
	}
}

func TestStartupShutdownEOFAndMalformedJoinAcquisition(t *testing.T) {
	for _, kind := range []string{"shutdown", "eof", "malformed"} {
		t.Run(kind, func(t *testing.T) {
			h := newStartupHarness(t, 0, nil)
			h.start(t, 10, "exec sleep 30")
			h.start(t, 20, "exec sleep 30")
			h.starting(t, 2)
			switch kind {
			case "shutdown":
				h.write(t, 100, framing.KindShutdown, map[string]any{})
			case "eof":
				h.input.Close()
			case "malformed":
				if _, err := h.input.Write([]byte{0, 0, 0, 1, 0xc1}); err != nil {
					t.Fatal(err)
				}
			}
			// The source-of-truth entry flags show teardown has reached the starts;
			// native exit cannot be reported while their acquisition remains held.
			deadline := time.Now().Add(3 * time.Second)
			for {
				h.srv.mu.Lock()
				cancelled := h.srv.running[10].cancelled && h.srv.running[20].cancelled
				h.srv.mu.Unlock()
				if cancelled {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("teardown did not mark starting entries")
				}
				time.Sleep(time.Millisecond)
			}
			select {
			case err := <-h.done:
				t.Fatalf("returned before startup join: %v", err)
			default:
			}
			h.gates[10].open()
			h.gates[20].open()
			exited := map[uint64]bool{}
			for len(exited) < 2 {
				f := h.read(t)
				if f.Kind == framing.KindExecExit {
					var exit framing.ExecExit
					if err := framing.DecodeBody(f.Body, &exit); err != nil {
						t.Fatal(err)
					}
					if !exit.Cancelled {
						t.Fatalf("uncancelled startup: %+v", exit)
					}
					exited[f.ID] = true
				}
			}
		})
	}
}

// A start refusal is a terminal obligation too. Delay its Write return after
// the peer receives the error to exercise immediate full-capacity refill.
type delayedStartupError struct{ writer io.Writer }

func (w delayedStartupError) Write(p []byte) (int, error) {
	n, err := w.writer.Write(p)
	if bytes.Contains(p, []byte("spawn_failed")) {
		time.Sleep(20 * time.Millisecond)
	}
	return n, err
}
func TestStartupFailureReportsOnceAndAllowsFullCapacityRefill(t *testing.T) {
	h := newStartupHarness(t, 10, func(w io.Writer) io.Writer { return delayedStartupError{writer: w} })
	for id := uint64(10); id < 14; id++ {
		h.start(t, id, "exec sleep 30")
	}
	h.starting(t, 4)
	h.gates[10].open()
	f := h.read(t)
	var refusal framing.ErrorBody
	if f.ID != 10 || f.Kind != framing.KindError || framing.DecodeBody(f.Body, &refusal) != nil || refusal.Code != framing.ErrCodeSpawn {
		t.Fatalf("start refusal: %+v %+v", f, refusal)
	}
	h.start(t, 20, "exit 0")
	h.starting(t, 1)
	h.gates[20].open()
	exits, _ := h.exits(t, 1)
	if exits[20].Code != 0 {
		t.Fatalf("replacement: %+v", exits)
	}
}
