//go:build darwin || linux

package server_test

import (
	"bytes"
	"io"
	"os"
	"testing"
	"time"

	"github.com/roasbeef/loom/sandbox/internal/framing"
	"github.com/roasbeef/loom/sandbox/internal/jail"
	"github.com/roasbeef/loom/sandbox/internal/policy"
	"github.com/roasbeef/loom/sandbox/internal/server"
	"github.com/roasbeef/loom/sandbox/internal/testbin"
)

// muxHarness uses real pipes with read deadlines so a stalled control loop
// fails the assertion instead of hanging the suite.
type muxHarness struct {
	conn   *framing.Conn
	input  *os.File
	output *os.File
	done   chan error
}

func newMuxHarness(t *testing.T) *muxHarness {
	return newMuxHarnessWriter(t, nil)
}

func newMuxHarnessWriter(t *testing.T, wrap func(io.Writer) io.Writer) *muxHarness {
	t.Helper()
	inR, inW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	outR, outW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	pol := policy.Policy{WritableRoots: []string{t.TempDir()}, ReadableRoots: []string{}, Protected: []string{}, Network: policy.Network{Mode: policy.NetworkOff}, Limits: policy.Limits{WallSeconds: 30, OutputBytes: 1 << 20}, EnvAllow: []string{"PATH"}, Scratch: "tmpfs"}
	var writer io.Writer = outW
	if wrap != nil {
		writer = wrap(writer)
	}
	srv := server.New(framing.NewConn(inR, writer), jail.DetectFeatures(), testbin.Helper(t), pol)
	h := &muxHarness{conn: framing.NewConn(outR, inW), input: inW, output: outR, done: make(chan error, 1)}
	go func() { h.done <- srv.Run() }()
	t.Cleanup(func() {
		inW.Close()
		outR.Close()
		outW.Close()
		inR.Close()
		select {
		case <-h.done:
		case <-time.After(10 * time.Second):
			t.Error("multiplex server did not join")
		}
	})
	f := h.read(t)
	var hello framing.Hello
	if f.Kind != framing.KindHello || framing.DecodeBody(f.Body, &hello) != nil || hello.MaxConcurrency != 4 {
		t.Fatalf("hello: %+v %+v", f, hello)
	}
	h.write(t, 1, framing.KindHello, framing.Hello{Proto: framing.ExecProtocolVersion, Peer: "broker"})
	return h
}

func (h *muxHarness) read(t *testing.T) framing.Frame {
	t.Helper()
	h.output.SetReadDeadline(time.Now().Add(10 * time.Second))
	f, err := h.conn.Read()
	if err != nil {
		t.Fatal(err)
	}
	return f
}
func (h *muxHarness) write(t *testing.T, id uint64, kind string, body any) {
	t.Helper()
	if err := h.conn.Write(id, kind, body); err != nil {
		t.Fatal(err)
	}
}
func (h *muxHarness) start(t *testing.T, id uint64, script string) {
	h.write(t, id, framing.KindExecStart, framing.ExecStart{Argv: []string{"/bin/sh", "-c", script}, Env: map[string]string{"PATH": "/usr/bin:/bin"}, Cwd: "/", Token: make([]byte, 32)})
}
func (h *muxHarness) up(t *testing.T, id uint64) {
	t.Helper()
	for {
		f := h.read(t)
		if f.Kind == framing.KindError {
			t.Fatalf("start failed: %s", f.Body)
		}
		if f.Kind == framing.KindExecOut && f.ID == id {
			var out framing.ExecOut
			if err := framing.DecodeBody(f.Body, &out); err != nil {
				t.Fatal(err)
			}
			if out.Stream == "stderr" {
				t.Fatalf("startup stderr: %s", out.Data)
			}
			if bytes.Contains(out.Data, []byte("ready")) {
				return
			}
		}
	}
}

func TestMultiplexIndependentStdinOutputAndCancel(t *testing.T) {
	h := newMuxHarness(t)
	h.start(t, 10, "echo ready; exec sleep 30")
	h.up(t, 10)
	h.start(t, 20, "echo ready; exec cat")
	h.up(t, 20)
	h.write(t, 30, framing.KindCancel, framing.Cancel{ExecID: 999})
	h.write(t, 31, framing.KindCancel, framing.Cancel{ExecID: 10})
	h.write(t, 32, framing.KindExecStdin, framing.ExecStdin{ExecID: 20, Data: []byte("sibling survives\n"), EOF: true})
	exits := map[uint64]framing.ExecExit{}
	var output bytes.Buffer
	for len(exits) < 2 {
		f := h.read(t)
		switch f.Kind {
		case framing.KindError:
			t.Fatalf("unexpected error: %s", f.Body)
		case framing.KindExecOut:
			var out framing.ExecOut
			if err := framing.DecodeBody(f.Body, &out); err != nil {
				t.Fatal(err)
			}
			if f.ID == 20 {
				output.Write(out.Data)
			}
		case framing.KindExecExit:
			var exit framing.ExecExit
			if err := framing.DecodeBody(f.Body, &exit); err != nil {
				t.Fatal(err)
			}
			exits[f.ID] = exit
		}
	}
	if !exits[10].Cancelled || exits[20].Cancelled || exits[20].Code != 0 || output.String() != "sibling survives\n" {
		t.Fatalf("exits=%+v output=%q", exits, output.String())
	}
	// Completed cancellation is idempotent and does not prevent a heartbeat.
	h.write(t, 33, framing.KindCancel, framing.Cancel{ExecID: 10})
	h.write(t, 34, framing.KindHeartbeat, map[string]any{})
	if f := h.read(t); f.Kind != framing.KindHeartbeat || f.ID != 34 {
		t.Fatalf("heartbeat: %+v", f)
	}
}

func TestMultiplexDuplicateCapacityAndShutdown(t *testing.T) {
	h := newMuxHarness(t)
	for id := uint64(10); id < 14; id++ {
		h.start(t, id, "echo ready; exec sleep 30")
		h.up(t, id)
	}
	h.start(t, 10, "echo replacement")
	h.start(t, 14, "echo over capacity")
	for _, want := range []struct {
		id   uint64
		code string
	}{{10, framing.ErrCodeMalformed}, {14, framing.ErrCodeBusy}} {
		f := h.read(t)
		var body framing.ErrorBody
		if f.ID != want.id || f.Kind != framing.KindError || framing.DecodeBody(f.Body, &body) != nil || body.Code != want.code {
			t.Fatalf("refusal %+v %+v, want %+v", f, body, want)
		}
	}
	h.write(t, 40, framing.KindShutdown, map[string]any{})
	seen := map[uint64]bool{}
	for len(seen) < 4 {
		f := h.read(t)
		if f.Kind != framing.KindExecExit {
			continue
		}
		var exit framing.ExecExit
		if err := framing.DecodeBody(f.Body, &exit); err != nil {
			t.Fatal(err)
		}
		if !exit.Cancelled || f.ID < 10 || f.ID > 13 || seen[f.ID] {
			t.Fatalf("shutdown terminal: %+v %+v", f, exit)
		}
		seen[f.ID] = true
	}
}

func TestMultiplexFullStdinDoesNotStarveSiblingCancel(t *testing.T) {
	h := newMuxHarness(t)
	h.start(t, 10, "echo ready; exec sleep 30")
	h.up(t, 10)
	h.start(t, 20, "echo ready; exec sleep 30")
	h.up(t, 20)
	// Two frames fill the bounded queue. The next chunk must fail without
	// keeping the shared loop from reaching the sibling cancellation.
	chunk := make([]byte, 8<<20)
	for id := uint64(100); id < 103; id++ {
		h.write(t, id, framing.KindExecStdin, framing.ExecStdin{ExecID: 10, Data: chunk})
	}
	h.write(t, 104, framing.KindCancel, framing.Cancel{ExecID: 20})
	refused := false
	cancelled := map[uint64]bool{}
	for len(cancelled) < 2 {
		f := h.read(t)
		if f.Kind == framing.KindError && f.ID == 102 {
			refused = true
		}
		if f.Kind == framing.KindExecExit {
			var exit framing.ExecExit
			if err := framing.DecodeBody(f.Body, &exit); err != nil {
				t.Fatal(err)
			}
			if !exit.Cancelled || (f.ID != 10 && f.ID != 20) {
				t.Fatalf("wrong cancellation: %d %+v", f.ID, exit)
			}
			cancelled[f.ID] = true
		}
	}
	if !refused {
		t.Fatal("saturated stdin was not refused")
	}

}

func TestMultiplexEOFAndMalformedJoinAll(t *testing.T) {
	for _, malformed := range []bool{false, true} {
		t.Run(map[bool]string{false: "eof", true: "malformed"}[malformed], func(t *testing.T) {
			h := newMuxHarness(t)
			h.start(t, 10, "echo ready; exec sleep 30")
			h.up(t, 10)
			h.start(t, 20, "echo ready; exec sleep 30")
			h.up(t, 20)
			if malformed {
				_, err := h.input.Write([]byte{0, 0, 0, 1, 0xc1})
				if err != nil {
					t.Fatal(err)
				}
			} else {
				h.input.Close()
			}
			seen := map[uint64]bool{}
			for len(seen) < 2 {
				f := h.read(t)
				if f.Kind == framing.KindExecExit {
					var exit framing.ExecExit
					if err := framing.DecodeBody(f.Body, &exit); err != nil {
						t.Fatal(err)
					}
					if !exit.Cancelled {
						t.Fatalf("uncancelled: %+v", exit)
					}
					seen[f.ID] = true
				}
			}
		})
	}
}

// Missing or invalid targets are request errors; none can accidentally target
// a sibling or turn an empty legacy cancel into a helper-wide cancellation.
func TestMultiplexControlTargetsAreRequired(t *testing.T) {
	h := newMuxHarness(t)
	for _, kind := range []string{framing.KindCancel, framing.KindExecStdin} {
		for _, body := range []map[string]any{{}, {"exec_id": uint64(0)}, {"exec_id": int64(-1)}, {"exec_id": "10"}} {
			h.write(t, 100, kind, body)
			f := h.read(t)
			var refusal framing.ErrorBody
			if f.Kind != framing.KindError || f.ID != 100 || framing.DecodeBody(f.Body, &refusal) != nil || refusal.Code != framing.ErrCodeMalformed {
				t.Fatalf("invalid %s target: %+v %+v", kind, f, refusal)
			}
		}
	}
	h.write(t, 101, framing.KindExecStdin, framing.ExecStdin{ExecID: 999, Data: []byte("absent")})
	f := h.read(t)
	var refusal framing.ErrorBody
	if f.Kind != framing.KindError || f.ID != 101 || framing.DecodeBody(f.Body, &refusal) != nil || refusal.Code != framing.ErrCodeNoExec {
		t.Fatalf("unknown stdin: %+v %+v", f, refusal)
	}
	h.write(t, 102, framing.KindHeartbeat, map[string]any{})
	if f := h.read(t); f.Kind != framing.KindHeartbeat || f.ID != 102 {
		t.Fatalf("heartbeat: %+v", f)
	}
}

// delayedTerminalReturn widens the real scheduling window after the peer
// receives an exit but before the helper's Write returns. Capacity retirement
// must still be atomic from a caller immediately refilling that slot.
type delayedTerminalReturn struct{ writer io.Writer }

func (w delayedTerminalReturn) Write(p []byte) (int, error) {
	n, err := w.writer.Write(p)
	if bytes.Contains(p, []byte(framing.KindExecExit)) {
		time.Sleep(10 * time.Millisecond)
	}
	return n, err
}

func TestMultiplexTerminalReceiptAllowsImmediateFullCapacityRefill(t *testing.T) {
	h := newMuxHarnessWriter(t, func(w io.Writer) io.Writer { return delayedTerminalReturn{writer: w} })
	for id := uint64(10); id < 14; id++ {
		h.start(t, id, "echo ready; exec cat")
		h.up(t, id)
	}
	active := uint64(10)
	for iteration := 0; iteration < 30; iteration++ {
		h.write(t, 1000+uint64(iteration), framing.KindExecStdin, framing.ExecStdin{ExecID: framing.ExecutionID(active), EOF: true})
		f := h.read(t)
		var exit framing.ExecExit
		if f.Kind != framing.KindExecExit || f.ID != active || framing.DecodeBody(f.Body, &exit) != nil || exit.Code != 0 {
			t.Fatalf("settlement %d: %+v %+v", iteration, f, exit)
		}
		active = uint64(100 + iteration)
		h.start(t, active, "echo ready; exec cat")
		h.up(t, active)
	}
}
