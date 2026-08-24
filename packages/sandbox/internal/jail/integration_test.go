//go:build linux

package jail_test

import (
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/roasbeef/loom/sandbox/internal/jail"
	"github.com/roasbeef/loom/sandbox/internal/policy"
	"github.com/roasbeef/loom/sandbox/internal/testbin"
)

// collector is a threadsafe OutputSink.
type collector struct {
	mu     sync.Mutex
	stdout strings.Builder
	stderr strings.Builder
	trunc  map[string]bool
}

func newCollector() *collector { return &collector{trunc: map[string]bool{}} }

func (c *collector) sink(stream string, data []byte, total uint64, truncated bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if stream == "stdout" {
		c.stdout.Write(data)
	} else {
		c.stderr.Write(data)
	}
	if truncated {
		c.trunc[stream] = true
	}
}

func (c *collector) out() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.stdout.String()
}

func testPolicy(t *testing.T) policy.Policy {
	dir := t.TempDir()
	return policy.Policy{
		WritableRoots: []string{dir},
		ReadableRoots: []string{},
		Protected:     []string{},
		Network:       policy.Network{Mode: policy.NetworkOff},
		Limits:        policy.Limits{WallSeconds: 30, OutputBytes: 1 << 20},
		EnvAllow:      []string{"PATH"},
		Scratch:       "tmpfs",
	}
}

var testEnv = map[string]string{"PATH": "/usr/local/bin:/usr/bin:/bin"}

// waitFor polls cond until it holds or the deadline passes.
func waitFor(t *testing.T, d time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("condition not reached before deadline")
}

func start(t *testing.T, pol policy.Policy, argv []string, sink jail.OutputSink) *jail.Exec {
	t.Helper()
	ex, err := jail.Start(jail.Request{
		Argv: argv, Env: testEnv, Cwd: "/", Policy: pol,
	}, jail.DetectFeatures(), testbin.Helper(t), sink)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	return ex
}

func TestExecEcho(t *testing.T) {
	c := newCollector()
	ex := start(t, testPolicy(t), []string{"/bin/sh", "-c", "echo hello"}, c.sink)
	if err := ex.WriteStdin(nil, true); err != nil {
		t.Fatalf("WriteStdin: %v", err)
	}
	res := ex.Wait()
	if res.Code != 0 || res.Signal != 0 {
		t.Fatalf("exit = %d/%d, want 0/0 (enforcement %v)", res.Code, res.Signal, res.Enforcement)
	}
	if c.out() != "hello\n" {
		t.Fatalf("stdout = %q, want %q", c.out(), "hello\n")
	}
	// Stage 2 always applies no_new_privs; its presence in the report
	// proves the report pipe works end to end.
	found := false
	for _, e := range res.Enforcement {
		if e == "no-new-privs" {
			found = true
		}
	}
	if !found {
		t.Fatalf("enforcement report missing no-new-privs: %v", res.Enforcement)
	}
}

func TestExecStdinRoundtrip(t *testing.T) {
	c := newCollector()
	ex := start(t, testPolicy(t), []string{"/bin/cat"}, c.sink)
	if err := ex.WriteStdin([]byte("in through the pipe\n"), false); err != nil {
		t.Fatalf("WriteStdin: %v", err)
	}
	if err := ex.WriteStdin(nil, true); err != nil {
		t.Fatalf("WriteStdin eof: %v", err)
	}
	res := ex.Wait()
	if res.Code != 0 {
		t.Fatalf("exit %d", res.Code)
	}
	if c.out() != "in through the pipe\n" {
		t.Fatalf("stdout = %q", c.out())
	}
	if err := ex.WriteStdin([]byte("late"), false); err == nil {
		t.Fatal("write after eof accepted")
	}
}

func TestExecExitCode(t *testing.T) {
	c := newCollector()
	ex := start(t, testPolicy(t), []string{"/bin/sh", "-c", "exit 42"}, c.sink)
	_ = ex.WriteStdin(nil, true)
	if res := ex.Wait(); res.Code != 42 {
		t.Fatalf("exit = %d, want 42", res.Code)
	}
}

func TestEnvAllowlistEnforced(t *testing.T) {
	c := newCollector()
	pol := testPolicy(t)
	ex, err := jail.Start(jail.Request{
		Argv: []string{"/bin/sh", "-c", "env"},
		Env: map[string]string{
			"PATH":   "/usr/local/bin:/usr/bin:/bin",
			"SECRET": "leaky",
		},
		Cwd: "/", Policy: pol,
	}, jail.DetectFeatures(), testbin.Helper(t), c.sink)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	_ = ex.WriteStdin(nil, true)
	_ = ex.Wait()
	if strings.Contains(c.out(), "SECRET") {
		t.Fatalf("non-allowlisted env leaked into jail:\n%s", c.out())
	}
	if !strings.Contains(c.out(), "PATH=") {
		t.Fatalf("allowlisted PATH missing:\n%s", c.out())
	}
}

func TestOutputTruncation(t *testing.T) {
	pol := testPolicy(t)
	pol.Limits.OutputBytes = 4096
	c := newCollector()
	ex := start(t, pol, []string{"/bin/sh", "-c", "head -c 100000 /dev/zero; echo tail 1>&2"}, c.sink)
	_ = ex.WriteStdin(nil, true)
	res := ex.Wait()
	if !res.StdoutTruncated {
		t.Fatal("stdout not marked truncated")
	}
	if res.StdoutBytes != 4096 {
		t.Fatalf("StdoutBytes = %d, want 4096", res.StdoutBytes)
	}
	if uint64(len(c.out())) != 4096 {
		t.Fatalf("delivered %d bytes, want 4096", len(c.out()))
	}
	if res.StderrTruncated {
		t.Fatal("stderr wrongly truncated (caps are per-stream)")
	}
	if res.Code != 0 {
		t.Fatalf("flooding child failed with %d; truncation must not break the child", res.Code)
	}
}

func TestCancelTermCompliant(t *testing.T) {
	c := newCollector()
	ex := start(t, testPolicy(t), []string{"/bin/sleep", "30"}, c.sink)
	_ = ex.WriteStdin(nil, true)
	startT := time.Now()
	go func() {
		time.Sleep(200 * time.Millisecond)
		ex.Cancel()
	}()
	res := ex.Wait()
	if elapsed := time.Since(startT); elapsed > 10*time.Second {
		t.Fatalf("cancel took %s", elapsed)
	}
	if res.Signal == 0 && res.Code == 0 {
		t.Fatalf("cancelled sleep reported clean exit: %+v", res)
	}
}

func TestCancelEscalatesToKill(t *testing.T) {
	c := newCollector()
	// The child ignores TERM; only the 2s KILL escalation ends it. It
	// prints "ready" once the trap is installed — cancelling earlier
	// would TERM a shell that has not shielded itself yet.
	ex := start(t, testPolicy(t),
		[]string{"/bin/sh", "-c", `trap '' TERM; echo ready; i=0; while [ $i -lt 300 ]; do sleep 0.1 || true; i=$((i+1)); done`},
		c.sink)
	_ = ex.WriteStdin(nil, true)
	waitFor(t, 10*time.Second, func() bool { return strings.Contains(c.out(), "ready") })
	startT := time.Now()
	ex.Cancel()
	ex.Cancel() // idempotent by contract
	res := ex.Wait()
	elapsed := time.Since(startT)
	if elapsed < jail.KillGrace {
		t.Fatalf("TERM-ignoring child died in %s, before the %s grace (did TERM kill it?)", elapsed, jail.KillGrace)
	}
	if elapsed > 15*time.Second {
		t.Fatalf("escalation took %s", elapsed)
	}
	_ = res
}

func TestWallClockTimeout(t *testing.T) {
	pol := testPolicy(t)
	pol.Limits.WallSeconds = 1
	c := newCollector()
	ex := start(t, pol, []string{"/bin/sleep", "30"}, c.sink)
	_ = ex.WriteStdin(nil, true)
	startT := time.Now()
	res := ex.Wait()
	if !res.TimedOut {
		t.Fatal("TimedOut not set")
	}
	if elapsed := time.Since(startT); elapsed > 10*time.Second {
		t.Fatalf("wall timeout took %s", elapsed)
	}
}

func TestOrphanedGrandchildReaped(t *testing.T) {
	c := newCollector()
	startT := time.Now()
	ex := start(t, testPolicy(t), []string{"/bin/sh", "-c", "sleep 30 & echo spawned"}, c.sink)
	_ = ex.WriteStdin(nil, true)
	res := ex.Wait()
	// Wait returns only after every holder of the output pipe is dead;
	// returning promptly proves the orphan was reaped by the pgroup
	// sweep (or the dying PID namespace under bwrap).
	if elapsed := time.Since(startT); elapsed > 10*time.Second {
		t.Fatalf("orphan held the jail open for %s", elapsed)
	}
	if res.Code != 0 {
		t.Fatalf("exit %d", res.Code)
	}
}

// Feature-gated integration probes: enforced when the kernel offers the
// layer, skipped (with the reason) when the environment denies it.

func TestWriteOutsideRootsDenied(t *testing.T) {
	feat := jail.DetectFeatures()
	if feat.BwrapPath == "" && feat.LandlockABI == 0 {
		t.Skipf("needs bwrap or Landlock; neither available (%s)", feat.LandlockReason)
	}
	victim := t.TempDir() + "/victim"
	pol := testPolicy(t) // writable root is a *different* temp dir
	c := newCollector()
	ex := start(t, pol, []string{"/bin/sh", "-c", "echo escaped > " + victim + " && echo WROTE"}, c.sink)
	_ = ex.WriteStdin(nil, true)
	_ = ex.Wait()
	if strings.Contains(c.out(), "WROTE") {
		t.Fatal("write outside writable roots succeeded")
	}
	if _, err := os.Stat(victim); err == nil {
		t.Fatal("victim exists on host")
	}
}

func TestProtectedPathMasked(t *testing.T) {
	feat := jail.DetectFeatures()
	if feat.BwrapPath == "" {
		t.Skip("protected-path masking needs bwrap (Landlock has no deny rules)")
	}
	dir := t.TempDir()
	secret := dir + "/secret"
	if err := os.WriteFile(secret, []byte("original"), 0o600); err != nil {
		t.Fatal(err)
	}
	pol := testPolicy(t)
	pol.WritableRoots = []string{dir}
	pol.Protected = []string{secret}
	c := newCollector()
	ex := start(t, pol, []string{"/bin/sh", "-c", "echo clobbered > " + secret}, c.sink)
	_ = ex.WriteStdin(nil, true)
	_ = ex.Wait()
	got, err := os.ReadFile(secret)
	if err != nil || string(got) != "original" {
		t.Fatalf("protected file modified: %q, %v", got, err)
	}
}

func TestNetworkOffSocketDenied(t *testing.T) {
	feat := jail.DetectFeatures()
	if !feat.Seccomp {
		t.Skip("kernel lacks seccomp filter support")
	}
	c := newCollector()
	ex := start(t, testPolicy(t), []string{testbin.Helper(t), "--probe-socket"}, c.sink)
	_ = ex.WriteStdin(nil, true)
	res := ex.Wait()
	if !strings.Contains(c.out(), "socket-denied") {
		t.Fatalf("expected socket-denied, got %q (exit %d)", c.out(), res.Code)
	}
}

// Phase 1 has no egress sidecar, so proxy mode must deny direct
// sockets exactly like off — never unrestricted egress.
func TestNetworkProxySocketDenied(t *testing.T) {
	feat := jail.DetectFeatures()
	if !feat.Seccomp {
		t.Skip("kernel lacks seccomp filter support")
	}
	pol := testPolicy(t)
	pol.Network = policy.Network{
		Mode:  policy.NetworkProxy,
		Allow: []string{"registry.npmjs.org"},
		Proxy: "127.0.0.1:3128",
	}
	c := newCollector()
	ex := start(t, pol, []string{testbin.Helper(t), "--probe-socket"}, c.sink)
	_ = ex.WriteStdin(nil, true)
	res := ex.Wait()
	if !strings.Contains(c.out(), "socket-denied") {
		t.Fatalf("expected socket-denied under proxy mode, got %q (exit %d)", c.out(), res.Code)
	}
}

// A proxy-mode execution must say in its enforcement report that the
// allowlist was not enforced; the skip entry is what lets the broker
// refuse the result under a full-enforcement demand.
func TestNetworkProxyReportsSkip(t *testing.T) {
	pol := testPolicy(t)
	pol.Network = policy.Network{
		Mode:  policy.NetworkProxy,
		Allow: []string{"registry.npmjs.org"},
		Proxy: "127.0.0.1:3128",
	}
	c := newCollector()
	ex := start(t, pol, []string{"/bin/sh", "-c", "true"}, c.sink)
	_ = ex.WriteStdin(nil, true)
	res := ex.Wait()
	want := "skip:" + jail.ProxyUnenforcedSkip
	found := false
	for _, e := range res.Enforcement {
		if e == want {
			found = true
		}
	}
	if !found {
		t.Fatalf("enforcement %v missing %q", res.Enforcement, want)
	}
}

func TestForkBombCapped(t *testing.T) {
	feat := jail.DetectFeatures()
	if feat.CgroupDir == "" {
		t.Skipf("no delegated cgroup v2 (%s)", feat.CgroupReason)
	}
	pol := testPolicy(t)
	pol.Limits.Pids = 8
	c := newCollector()
	script := "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do sleep 1 & done 2>/dev/null; wait 2>/dev/null; echo attempted"
	ex := start(t, pol, []string{"/bin/sh", "-c", script}, c.sink)
	_ = ex.WriteStdin(nil, true)
	res := ex.Wait()
	if res.PidsMaxEvents == 0 {
		t.Fatal("no pids.max denials recorded for a 16-way fork burst under pids=8")
	}
}
