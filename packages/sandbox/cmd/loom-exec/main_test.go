//go:build linux

package main_test

import (
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/roasbeef/loom/sandbox/internal/framing"
	"github.com/roasbeef/loom/sandbox/internal/policy"
	"github.com/roasbeef/loom/sandbox/internal/testbin"
)

func smokePolicy() policy.Policy {
	return policy.Policy{
		WritableRoots: []string{os.TempDir()},
		ReadableRoots: []string{},
		Protected:     []string{},
		Network:       policy.Network{Mode: policy.NetworkOff},
		Limits:        policy.Limits{WallSeconds: 20, OutputBytes: 1 << 20},
		EnvAllow:      []string{"PATH"},
		Scratch:       "tmpfs",
	}
}

// startServer launches the real binary in server mode with pol on fd 3
// and returns the broker-side conn plus the exec.Cmd.
func startServer(t *testing.T, polBytes []byte) (*framing.Conn, *exec.Cmd) {
	t.Helper()
	bin := testbin.Helper(t)

	polR, polW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := polW.Write(polBytes); err != nil {
		t.Fatal(err)
	}
	polW.Close()

	inR, inW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	outR, outW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(bin)
	cmd.Stdin = inR
	cmd.Stdout = outW
	cmd.Stderr = os.Stderr
	cmd.ExtraFiles = []*os.File{polR}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	polR.Close()
	inR.Close()
	outW.Close()
	t.Cleanup(func() {
		inW.Close()
		outR.Close()
		_ = cmd.Wait()
	})
	return framing.NewConn(outR, inW), cmd
}

// TestServerModeEndToEnd drives the real binary exactly as the broker
// will: policy on fd 3, hello exchange, one execution, exit frame.
func TestServerModeEndToEnd(t *testing.T) {
	raw, err := policy.Encode(smokePolicy())
	if err != nil {
		t.Fatal(err)
	}
	conn, _ := startServer(t, raw)

	f, err := conn.Read()
	if err != nil {
		t.Fatalf("read hello: %v", err)
	}
	var hello framing.Hello
	if f.Kind != framing.KindHello || framing.DecodeBody(f.Body, &hello) != nil {
		t.Fatalf("first frame: %+v", f)
	}
	if hello.Proto != 1 || hello.Peer != "exec-helper" {
		t.Fatalf("hello: %+v", hello)
	}

	if err := conn.Write(1, framing.KindHello, framing.Hello{Proto: 1, Peer: "broker"}); err != nil {
		t.Fatal(err)
	}
	if err := conn.Write(2, framing.KindExecStart, framing.ExecStart{
		Argv:  []string{"/bin/sh", "-c", "echo smoke-$((6*7))"},
		Env:   map[string]string{"PATH": "/usr/bin:/bin"},
		Cwd:   "/",
		Token: make([]byte, 32),
	}); err != nil {
		t.Fatal(err)
	}
	if err := conn.Write(3, framing.KindExecStdin, framing.ExecStdin{EOF: true}); err != nil {
		t.Fatal(err)
	}

	var stdout strings.Builder
	for {
		f, err := conn.Read()
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		switch f.Kind {
		case framing.KindExecOut:
			var o framing.ExecOut
			if err := framing.DecodeBody(f.Body, &o); err != nil {
				t.Fatal(err)
			}
			if o.Stream == "stdout" {
				stdout.Write(o.Data)
			}
		case framing.KindExecExit:
			var e framing.ExecExit
			if err := framing.DecodeBody(f.Body, &e); err != nil {
				t.Fatal(err)
			}
			if e.Code != 0 {
				t.Fatalf("exit code %d", e.Code)
			}
			if stdout.String() != "smoke-42\n" {
				t.Fatalf("stdout %q", stdout.String())
			}
			if len(e.Enforcement) == 0 {
				t.Fatal("empty enforcement report")
			}
			return
		case framing.KindError:
			var eb framing.ErrorBody
			_ = framing.DecodeBody(f.Body, &eb)
			t.Fatalf("error frame: %+v", eb)
		}
	}
}

// The binary's first duty is a strict parse of fd 3: garbage must be an
// error exit before any frame is spoken.
func TestBadFd3PolicyIsFatal(t *testing.T) {
	conn, cmd := startServer(t, []byte{0xde, 0xad})
	waitErr := make(chan error, 1)
	go func() { waitErr <- cmd.Wait() }()
	select {
	case err := <-waitErr:
		if err == nil {
			t.Fatal("binary exited 0 on a garbage fd-3 policy")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("binary did not exit on a garbage fd-3 policy")
	}
	// And it must not have spoken: the channel just closes.
	if f, err := conn.Read(); err == nil {
		t.Fatalf("unexpected frame before death: %+v", f)
	}
}

func TestMissingFd3IsFatal(t *testing.T) {
	bin := testbin.Helper(t)
	cmd := exec.Command(bin)
	cmd.Stdin = strings.NewReader("")
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("binary exited 0 with no fd 3 (output %q)", out)
	}
}

// Version-0 policies must be refused even when structurally plausible.
func TestWrongVersionFd3IsFatal(t *testing.T) {
	// An otherwise-valid policy map, except v=2.
	bad, err := framing.MarshalBody(map[string]any{
		"v": 2, "writable_roots": []any{}, "readable_roots": []any{},
		"protected": []any{}, "network": map[string]any{"mode": "off"},
		"limits": map[string]any{"cpu_s": 0, "wall_s": 0, "mem_bytes": 0,
			"pids": 0, "fsize_bytes": 0, "output_bytes": 0},
		"env_allow": []any{}, "scratch": "tmpfs",
	})
	if err != nil {
		t.Fatal(err)
	}
	_, cmd := startServer(t, bad)
	waitErr := make(chan error, 1)
	go func() { waitErr <- cmd.Wait() }()
	select {
	case err := <-waitErr:
		if err == nil {
			t.Fatal("binary accepted a v=2 policy")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("binary did not exit on a v=2 policy")
	}
}
