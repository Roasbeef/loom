//go:build darwin || linux

package server

import (
	"bytes"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/roasbeef/loom/sandbox/internal/framing"
	"github.com/roasbeef/loom/sandbox/internal/jail"
	"github.com/roasbeef/loom/sandbox/internal/policy"
	"github.com/roasbeef/loom/sandbox/internal/testbin"
)

type protocolHarness struct {
	peer    *framing.Conn
	server  *Server
	output  *os.File
	stopped chan error
}

func protocolHarnessFor(t *testing.T) *protocolHarness {
	t.Helper()
	inR, inW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	outR, outW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	pol := policy.Policy{WritableRoots: []string{t.TempDir()}, ReadableRoots: []string{}, Protected: []string{}, Network: policy.Network{Mode: policy.NetworkOff}, Limits: policy.Limits{WallSeconds: 30, OutputBytes: 64 << 20}, EnvAllow: []string{"PATH"}, Scratch: "tmpfs"}
	s := New(framing.NewConn(inR, outW), jail.DetectFeatures(), testbin.Helper(t), pol)
	h := &protocolHarness{server: s, peer: framing.NewConn(outR, inW), output: outR, stopped: make(chan error, 1)}
	go func() { h.stopped <- s.Run() }()
	t.Cleanup(func() {
		inW.Close()
		inR.Close()
		outW.Close()
		outR.Close()
		select {
		case <-h.stopped:
		case <-time.After(10 * time.Second):
			t.Error("real credited helper failed to join")
		}
	})
	h.read(t)
	h.write(t, 1, framing.KindHello, framing.Hello{Proto: framing.ExecProtocolVersion, Peer: "broker", Features: []string{framing.ProtocolCreditFeature}})
	return h
}

func (h *protocolHarness) read(t *testing.T) framing.Frame {
	t.Helper()
	_ = h.output.SetReadDeadline(time.Now().Add(10 * time.Second))
	f, err := h.peer.Read()
	if err != nil {
		t.Fatalf("read actual credited helper: %v", err)
	}
	return f
}
func (h *protocolHarness) write(t *testing.T, id uint64, kind string, body any) {
	t.Helper()
	if err := h.peer.Write(id, kind, body); err != nil {
		t.Fatal(err)
	}
}
func (h *protocolHarness) start(t *testing.T, id uint64, mode, script string) {
	h.write(t, id, framing.KindProtocolStart, framing.ProtocolStart{Argv: []string{"/bin/sh", "-c", script}, Env: map[string]string{"PATH": "/usr/bin:/bin"}, Cwd: "/", Token: bytes.Repeat([]byte{1}, 32), Mode: mode})
}

func TestRealProtocolFiniteSequentialCollectorsThenOrdinary(t *testing.T) {
	h := protocolHarnessFor(t)
	for _, id := range []uint64{20, 40} {
		// Reading EOF keeps the collector alive until its one admitted empty input.
		h.start(t, id, framing.ProtocolFinite, "cat >/dev/null; printf collected")
		h.write(t, id, framing.KindProtocolInput, framing.ProtocolInput{ExecutionID: id, Ordinal: 1, FrameID: id + 1, EOF: true})
		accepted, terminal, reusable := false, false, false
		var output bytes.Buffer
		for !reusable {
			f := h.read(t)
			if f.ID != id {
				t.Fatalf("frame escaped original collector: %+v", f)
			}
			switch f.Kind {
			case framing.KindProtocolInputAccepted:
				accepted = true
			case framing.KindProtocolOutput:
				var out framing.ProtocolOutput
				if err := framing.DecodeBody(f.Body, &out); err != nil {
					t.Fatal(err)
				}
				if out.ExecutionID != id || out.Bytes != uint64(output.Len()+len(out.Data)) {
					t.Fatalf("cumulative output changed: %+v", out)
				}
				output.Write(out.Data)
				h.write(t, id, framing.KindProtocolOutputConsumed, framing.ProtocolOutputConsumed{ExecutionID: id, Ordinal: out.Ordinal})
			case framing.KindExecExit:
				var exit framing.ProtocolExit
				if err := framing.DecodeBody(f.Body, &exit); err != nil {
					t.Fatal(err)
				}
				if !accepted || exit.Code != 0 || exit.Protocol != "complete" {
					t.Fatalf("collector not complete: accepted=%v exit=%+v", accepted, exit)
				}
				terminal = true
			case framing.KindProtocolReusable:
				if !terminal {
					t.Fatal("reusable preceded native terminal")
				}
				reusable = true
			default:
				t.Fatalf("unexpected collector frame: %+v", f)
			}
		}
		if output.String() != "collected" {
			t.Fatalf("lost complete collector output: %q", output.String())
		}
	}
	// Consumed finite reuse must also preserve ordinary execution's old formats.
	h.write(t, 60, framing.KindExecStart, framing.ExecStart{Argv: []string{"/bin/sh", "-c", "printf ordinary"}, Env: map[string]string{"PATH": "/usr/bin:/bin"}, Cwd: "/", Token: []byte{1}})
	for {
		f := h.read(t)
		if f.Kind == framing.KindExecExit {
			var exit framing.ExecExit
			if err := framing.DecodeBody(f.Body, &exit); err != nil {
				t.Fatal(err)
			}
			if exit.Code != 0 {
				t.Fatal(exit)
			}
			break
		}
		if f.Kind != framing.KindExecOut {
			t.Fatalf("ordinary successor received credited format: %+v", f)
		}
	}
	h.write(t, 80, framing.KindShutdown, map[string]any{})
	select {
	case err := <-h.stopped:
		if err != nil {
			t.Fatal(err)
		}
		h.stopped <- nil
	case <-time.After(10 * time.Second):
		t.Fatal("ordinary successor prevented joined shutdown")
	}
}

func TestRealProtocolCancelWithUnconsumedOutputJoins(t *testing.T) {
	h := protocolHarnessFor(t)
	h.start(t, 90, framing.ProtocolServer, "printf held; sleep 30")
	f := h.read(t)
	if f.Kind != framing.KindProtocolOutput {
		t.Fatalf("expected held output, got %+v", f)
	}
	// No output-consumed frame is sent. Cancel must wake both pumps and join.
	h.write(t, 90, framing.KindCancel, map[string]any{})
	for {
		f = h.read(t)
		if f.Kind == framing.KindExecExit {
			var exit framing.ProtocolExit
			if err := framing.DecodeBody(f.Body, &exit); err != nil {
				t.Fatal(err)
			}
			if !exit.Cancelled || exit.Protocol != "failed" {
				t.Fatalf("unconsumed prefix was reported complete: %+v", exit)
			}
			break
		}
	}
	h.write(t, 92, framing.KindShutdown, map[string]any{})
	select {
	case err := <-h.stopped:
		if err != nil {
			t.Fatal(err)
		}
		h.stopped <- nil
	case <-time.After(10 * time.Second):
		t.Fatal("cancelled protocol failed native join")
	}
}

// A non-reading child fills the actual native stdin queue. The one admission
// worker may wait there, while the frame reader must still accept cancellation.
func TestRealProtocolCancelWithFullStdinQueueJoins(t *testing.T) {
	h := protocolHarnessFor(t)
	const execution = uint64(100)
	h.start(t, execution, framing.ProtocolServer, "sleep 30")
	type received struct {
		frame framing.Frame
		err   error
	}
	replies := make(chan received, 1)
	_ = h.output.SetReadDeadline(time.Now().Add(10 * time.Second))
	go func() {
		for {
			frame, err := h.peer.Read()
			replies <- received{frame, err}
			if err != nil || frame.Kind == framing.KindExecExit {
				return
			}
		}
	}()
	var held uint64
	for ordinal := uint64(1); ordinal <= 2200; ordinal++ {
		h.write(t, execution, framing.KindProtocolInput, framing.ProtocolInput{ExecutionID: execution, Ordinal: ordinal, FrameID: ordinal, Data: bytes.Repeat([]byte{1}, 8192)})
		select {
		case reply := <-replies:
			if reply.err != nil {
				t.Fatal(reply.err)
			}
			var accepted framing.ProtocolInputAccepted
			if reply.frame.Kind != framing.KindProtocolInputAccepted {
				t.Fatalf("unexpected admission disposition: %+v", reply.frame)
			}
			if err := framing.DecodeBody(reply.frame.Body, &accepted); err != nil {
				t.Fatal(err)
			}
			if accepted.ExecutionID != execution || accepted.Ordinal != ordinal || accepted.FrameID != ordinal {
				t.Fatalf("admission lost original coordinates: %+v", accepted)
			}
		case <-time.After(100 * time.Millisecond):
			if ordinal < jail.StdinPendingMax/8192 {
				t.Fatalf("admission stalled before the native queue could fill: %d", ordinal)
			}
			held = ordinal
		}
		if held != 0 {
			break
		}
	}
	if held == 0 {
		t.Fatal("non-reading child did not fill the native queue")
	}
	h.server.protocol.mu.Lock()
	pending := h.server.protocol.pending
	if pending == nil || pending.Ordinal != held {
		h.server.protocol.mu.Unlock()
		t.Fatal("held native queue admission lost original input")
	}
	h.server.protocol.mu.Unlock()
	h.write(t, execution, framing.KindCancel, map[string]any{})
	refused := false
	for {
		select {
		case reply := <-replies:
			if reply.err != nil {
				t.Fatal(reply.err)
			}
			switch reply.frame.Kind {
			case framing.KindProtocolInputRefused:
				var refusal framing.ProtocolInputRefused
				if err := framing.DecodeBody(reply.frame.Body, &refusal); err != nil {
					t.Fatal(err)
				}
				if refusal.ExecutionID != execution || refusal.Ordinal != held || refusal.FrameID != held || refusal.Reason != "queue_rejected" {
					t.Fatalf("blocked admission lost original refusal: %+v", refusal)
				}
				refused = true
			case framing.KindExecExit:
				var exit framing.ProtocolExit
				if err := framing.DecodeBody(reply.frame.Body, &exit); err != nil {
					t.Fatal(err)
				}
				if !refused || !exit.Cancelled || exit.Protocol != "failed" {
					t.Fatalf("blocked admission did not join before failed terminal: refused=%v exit=%+v", refused, exit)
				}
				h.write(t, 102, framing.KindShutdown, map[string]any{})
				return
			default:
				t.Fatalf("unexpected blocked-admission frame: %+v", reply.frame)
			}
		case <-time.After(10 * time.Second):
			t.Fatal("cancel did not release actual native queue admission")
		}
	}
}

// A fast overflowing child can fail its pump before StartProtocol returns.
// Attaching its original Exec must retain that failure and cancel the child.
func TestRealProtocolOverflowBeforeOriginalAttachmentCancels(t *testing.T) {
	writer := newCreditWriter(framing.NewConn(bytes.NewReader(nil), io.Discard))
	protocol := newProtocolRun(110, framing.ProtocolServer, writer)
	reached := make(chan struct{})
	pol := policy.Policy{WritableRoots: []string{t.TempDir()}, ReadableRoots: []string{}, Protected: []string{}, Network: policy.Network{Mode: policy.NetworkOff}, Limits: policy.Limits{WallSeconds: 30, OutputBytes: 1}, EnvAllow: []string{"PATH"}, Scratch: "tmpfs"}
	original, err := jail.StartProtocol(jail.Request{Argv: []string{"/bin/sh", "-c", "printf overflow; sleep 30"}, Env: map[string]string{"PATH": "/usr/bin:/bin"}, Cwd: "/", Policy: pol, ID: 110}, jail.DetectFeatures(), testbin.Helper(t), func(stream string, data []byte, total uint64, truncated bool) {
		protocol.output(stream, data, total, truncated)
		if truncated {
			close(reached)
		}
	}, jail.ProtocolHooks{ChildExited: protocol.seal, DrainExpired: protocol.drainExpired})
	if err != nil {
		writer.abort()
		<-writer.done
		t.Fatal(err)
	}
	select {
	case <-reached:
	case <-time.After(5 * time.Second):
		original.Cancel()
		t.Fatal("fast overflow did not reach pre-attachment pump")
	}
	if protocol.original() != nil {
		t.Fatal("test accidentally attached the original before pump failure")
	}
	protocol.attachOriginal(original)
	result, release := original.Settle()
	release()
	if !result.Cancelled || !result.StdoutTruncated || result.TimedOut {
		t.Fatalf("pre-attachment failure did not cancel original promptly: %+v", result)
	}
	writer.abort()
	<-writer.done
}

// Policy controls cross the actual negotiated helper reader before any child starts.
func TestRealProtocolPolicyBounds(t *testing.T) {
	cases := []struct {
		name    string
		mode    string
		wall    uint64
		output  uint64
		network policy.NetworkMode
		message string
	}{
		{"finite-zero", framing.ProtocolFinite, 0, 64 << 20, policy.NetworkOff, "bounded original"},
		{"finite-over", framing.ProtocolFinite, 61, 64 << 20, policy.NetworkOff, "bounded original"},
		{"server-over", framing.ProtocolServer, 43201, 64 << 20, policy.NetworkOff, "bounded original"},
		{"server-output-zero", framing.ProtocolServer, 0, 0, policy.NetworkOff, "bounded original"},
		{"server-output-over", framing.ProtocolServer, 0, (64 << 20) + 1, policy.NetworkOff, "bounded original"},
		{"server-network", framing.ProtocolServer, 0, 64 << 20, policy.NetworkFull, "network off"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := protocolHarnessFor(t)
			pol := h.server.basePol
			pol.Limits.WallSeconds, pol.Limits.OutputBytes = tc.wall, tc.output
			pol.Network.Mode = tc.network
			encoded, err := policy.Encode(pol)
			if err != nil {
				t.Fatal(err)
			}
			h.write(t, 20, framing.KindProtocolStart, framing.ProtocolStart{Argv: []string{"/bin/sh", "-c", "exit 0"}, Env: map[string]string{"PATH": "/usr/bin:/bin"}, Cwd: "/", Token: bytes.Repeat([]byte{1}, 32), Mode: tc.mode, Policy: encoded})
			f := h.read(t)
			var refused framing.ErrorBody
			if f.Kind != framing.KindError || framing.DecodeBody(f.Body, &refused) != nil || !strings.Contains(refused.Msg, tc.message) {
				t.Fatalf("exact pre-start policy refusal: %+v %+v", f, refused)
			}
			if h.server.running != nil {
				t.Fatal("refused policy started a child")
			}
		})
	}
}

// A server with zero policy wall time reaches the existing jailed child path.
func TestRealProtocolServerZeroWall(t *testing.T) {
	h := protocolHarnessFor(t)
	pol := h.server.basePol
	pol.Limits.CPUSeconds, pol.Limits.WallSeconds = 0, 0
	encoded, err := policy.Encode(pol)
	if err != nil {
		t.Fatal(err)
	}
	h.write(t, 20, framing.KindProtocolStart, framing.ProtocolStart{Argv: []string{"/bin/sh", "-c", "printf zero-wall"}, Env: map[string]string{"PATH": "/usr/bin:/bin"}, Cwd: "/", Token: bytes.Repeat([]byte{1}, 32), Mode: framing.ProtocolServer, Policy: encoded})
	var output bytes.Buffer
	for {
		f := h.read(t)
		switch f.Kind {
		case framing.KindProtocolOutput:
			var out framing.ProtocolOutput
			if err := framing.DecodeBody(f.Body, &out); err != nil {
				t.Fatal(err)
			}
			output.Write(out.Data)
			h.write(t, 20, framing.KindProtocolOutputConsumed, framing.ProtocolOutputConsumed{ExecutionID: 20, Ordinal: out.Ordinal})
		case framing.KindExecExit:
			var exit framing.ProtocolExit
			if err := framing.DecodeBody(f.Body, &exit); err != nil {
				t.Fatal(err)
			}
			if exit.Code != 0 || exit.Protocol != "complete" || output.String() != "zero-wall" {
				t.Fatalf("original zero-wall server failed: %+v output=%q", exit, output.String())
			}
			h.write(t, 40, framing.KindShutdown, map[string]any{})
			return
		default:
			t.Fatalf("zero-wall server did not reach normal credited execution: %+v", f)
		}
	}
}
