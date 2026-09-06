//go:build linux || darwin

package main_test

import (
	"bytes"
	"context"
	"io"
	"os"
	"os/exec"
	"testing"
	"time"

	"github.com/roasbeef/loom/sandbox/internal/framing"
	"github.com/roasbeef/loom/sandbox/internal/policy"
	"github.com/roasbeef/loom/sandbox/internal/testbin"
)

// shutdownHelper retains stdin until the test has observed native exit.
// Closing stdin in the ordinary assertion path would test EOF cleanup, not
// the shutdown frame needed by an Erlang port that must retain exit_status.
type shutdownHelper struct {
	conn    *framing.Conn
	stdin   *os.File
	done    chan struct{}
	waitErr error
}

func startShutdownHelper(t *testing.T) *shutdownHelper {
	t.Helper()
	bin := testbin.Helper(t)
	pipe := func() (*os.File, *os.File) {
		r, w, err := os.Pipe()
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { r.Close(); w.Close() })
		return r, w
	}
	polR, polW := pipe()
	inR, inW := pipe()
	outR, outW := pipe()
	deadline := time.Now().Add(8 * time.Second)
	for _, f := range []*os.File{polW, inW, outR} {
		if err := f.SetDeadline(deadline); err != nil {
			t.Fatal(err)
		}
	}

	pol, err := policy.Encode(policy.Policy{
		WritableRoots: []string{t.TempDir()},
		ReadableRoots: []string{},
		Protected:     []string{},
		Network:       policy.Network{Mode: policy.NetworkOff},
		Limits:        policy.Limits{WallSeconds: 20, OutputBytes: 1024},
		EnvAllow:      []string{"PATH"},
		Scratch:       "tmpfs",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := polW.Write(pol); err != nil {
		t.Fatal(err)
	}
	polW.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)
	cmd := exec.CommandContext(ctx, bin)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = inR, outW, os.Stderr
	cmd.ExtraFiles = []*os.File{polR}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	polR.Close()
	inR.Close()
	outW.Close()
	h := &shutdownHelper{
		conn: framing.NewConn(outR, inW), stdin: inW, done: make(chan struct{}),
	}
	go func() { h.waitErr = cmd.Wait(); close(h.done) }()
	t.Cleanup(func() {
		// Failure cleanup may use EOF; success must already have witnessed
		// exit with this descriptor open. A broken helper cannot hang cleanup.
		inW.Close()
		select {
		case <-h.done:
		case <-time.After(12 * time.Second):
			t.Error("helper did not exit after its independent process deadline")
		}
	})
	if f := h.read(t); f.Kind != framing.KindHello {
		t.Fatalf("first frame = %+v, want hello", f)
	}
	if err := h.conn.Write(1, framing.KindHello, framing.Hello{Proto: 1, Peer: "broker"}); err != nil {
		t.Fatal(err)
	}
	return h
}

func (h *shutdownHelper) read(t *testing.T) framing.Frame {
	t.Helper()
	f, err := h.conn.Read()
	if err != nil {
		t.Fatalf("read helper frame: %v", err)
	}
	return f
}

func (h *shutdownHelper) wait(t *testing.T) error {
	t.Helper()
	if f, err := h.conn.Read(); err != io.EOF {
		t.Fatalf("expected closed output, got frame %+v, error %v", f, err)
	}
	select {
	case <-h.done:
		return h.waitErr
	case <-time.After(2 * time.Second):
		t.Fatal("helper closed output without completing native exit")
		return nil
	}
}

func TestShutdownIdleExitsWithStdinOpen(t *testing.T) {
	h := startShutdownHelper(t)

	// Queue another complete frame in the same write. Shutdown must leave
	// dispatch permanently, not acknowledge it and admit later commands.
	var queued bytes.Buffer
	conn := framing.NewConn(nil, &queued)
	for _, kind := range []string{framing.KindShutdown, framing.KindHeartbeat} {
		if err := conn.Write(2, kind, map[string]any{}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := h.stdin.Write(queued.Bytes()); err != nil {
		t.Fatal(err)
	}
	if err := h.wait(t); err != nil {
		t.Fatalf("orderly native shutdown: %v", err)
	}
}

func startRunningShutdownHelper(t *testing.T) *shutdownHelper {
	t.Helper()
	h := startShutdownHelper(t)
	if err := h.conn.Write(20, framing.KindExecStart, framing.ExecStart{
		Argv: []string{"/bin/sh", "-c", "trap '' TERM; echo ready; exec /bin/sleep 20"},
		Env:  map[string]string{"PATH": "/usr/bin:/bin"}, Cwd: "/", Token: make([]byte, 32),
	}); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	for !bytes.Contains(output.Bytes(), []byte("ready\n")) {
		f := h.read(t)
		var out framing.ExecOut
		if f.Kind != framing.KindExecOut || framing.DecodeBody(f.Body, &out) != nil {
			t.Fatalf("jail did not reach readiness: %+v", f)
		}
		output.Write(out.Data)
	}
	return h
}

func TestShutdownJoinsRunningJail(t *testing.T) {
	h := startRunningShutdownHelper(t)
	if err := h.conn.Write(21, framing.KindShutdown, map[string]any{}); err != nil {
		t.Fatal(err)
	}
	f := h.read(t)
	var ended framing.ExecExit
	if f.Kind != framing.KindExecExit || f.ID != 20 || framing.DecodeBody(f.Body, &ended) != nil {
		t.Fatalf("missing joined execution terminal: %+v", f)
	}
	if !ended.Cancelled || ended.TimedOut {
		t.Fatalf("shutdown did not cancel the active jail: %+v", ended)
	}
	if err := h.wait(t); err != nil {
		t.Fatalf("native shutdown after jail join: %v", err)
	}
}

func TestMalformedHelloJoinsRunningJail(t *testing.T) {
	h := startRunningShutdownHelper(t)
	if err := h.conn.Write(22, framing.KindHello, map[string]any{"unknown": 1}); err != nil {
		t.Fatal(err)
	}
	if f := h.read(t); f.Kind != framing.KindError || f.ID != 22 {
		t.Fatalf("missing malformed-hello refusal: %+v", f)
	}
	f := h.read(t)
	var ended framing.ExecExit
	if f.Kind != framing.KindExecExit || f.ID != 20 || framing.DecodeBody(f.Body, &ended) != nil || !ended.Cancelled {
		t.Fatalf("protocol failure skipped the active jail's join: %+v", f)
	}
	if err := h.wait(t); err == nil {
		t.Fatal("malformed hello reported orderly native exit")
	}
}

func TestShutdownRejectsMalformedBody(t *testing.T) {
	for name, body := range map[string]any{
		"unknown field": map[string]any{"force": true},
		"nil":           nil, "array": []any{}, "string": "", "integer": 0,
	} {
		t.Run(name, func(t *testing.T) {
			h := startShutdownHelper(t)
			if err := h.conn.Write(30, framing.KindShutdown, body); err != nil {
				t.Fatal(err)
			}
			f := h.read(t)
			wantID := uint64(30)

			// A nil body fails the envelope decoder before kind dispatch,
			// so its existing malformed-frame reply has no correlation ID.
			if body == nil {
				wantID = 0
			}
			var failure framing.ErrorBody
			if f.Kind != framing.KindError || f.ID != wantID || framing.DecodeBody(f.Body, &failure) != nil || failure.Code != framing.ErrCodeMalformed {
				t.Fatalf("expected malformed-body refusal: %+v", f)
			}
			if err := h.wait(t); err == nil {
				t.Fatal("malformed shutdown reported orderly native exit")
			}
		})
	}
}
