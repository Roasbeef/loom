//go:build linux

package jail_test

import (
	"os"
	"strconv"
	"strings"
	"sync"
	"syscall"
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

// #60 case 1: a protected path that does not exist, under a directory
// the policy leaves read-only, must refuse in Loom's own words before
// bwrap ever runs — not launch a jail that dies with a bare `Can't mkdir
// parents for PATH: Read-only file system` and exit 1, indistinguishable
// from the payload's own command failing. `~/.ssh` is exactly this
// shape: a default protected path whose parent ($HOME) an ordinary
// policy does not also grant write under.
func TestStartRefusesAnUnmaskableProtectedPath(t *testing.T) {
	feat := jail.DetectFeatures()
	if feat.BwrapPath == "" {
		t.Skip("this refusal only applies when bwrap builds the mount plan")
	}
	pol := testPolicy(t)
	// Use a host-path scratch so /tmp is not itself a writable tmpfs in
	// this plan. The missing sibling is then genuinely under the base
	// read-only view on Linux, where t.TempDir lives beneath /tmp.
	pol.Scratch = pol.WritableRoots[0]
	// testPolicy's writable root is a fresh temp dir; "missing" is
	// guaranteed absent under it, and its parent (the temp dir) is not
	// itself writable — only the temp dir's *subtree* the writable root
	// names is.
	missing := pol.WritableRoots[0] + "-sibling/missing"
	pol.Protected = []string{missing}
	_, err := jail.Start(jail.Request{
		Argv: []string{"/bin/sh", "-c", "echo unreachable"},
		Env:  testEnv, Cwd: "/", Policy: pol,
	}, feat, testbin.Helper(t), func(string, []byte, uint64, bool) {})
	if err == nil {
		t.Fatal("Start succeeded for a protected path bwrap cannot mask")
	}
	if !strings.Contains(err.Error(), missing) {
		t.Fatalf("refusal does not name the path: %v", err)
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

// A TERM-compliant payload must die *of the TERM*: exit status 128+15,
// not 128+9. That is a real tightening over the "not a clean exit" this
// used to ask for, which a SIGKILL satisfies just as well.
//
// It is deliberately not the test that proves the ladder reaches the
// payload, and it cannot be. Under bwrap the direct child is the
// supervisor, which reports a signalled payload by exiting 128+signal
// itself, so the status the broker sees is the same whether the payload
// took the TERM or the namespace collapsed around it. Telling those two
// apart needs a payload that can say what happened to it, which is
// TestCancelHonoursThePayloadsTermHandler below.
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
	if want := 128 + int(syscall.SIGTERM); res.Code != want {
		t.Fatalf("cancelled sleep exited %d, want %d (128+SIGTERM): %+v",
			res.Code, want, res)
	}
}

// The claim the cancel ladder actually makes: a payload gets its TERM,
// on its own terms, and what it decides to do about it survives. This is
// the assertion the jail could not satisfy before cancel.go — the
// handler ran, printed, and chose to exit 7, and the namespace teardown
// then destroyed that status and reported "killed by signal" instead.
//
// It is also the test that would notice the opposite mistake: if TERM
// stopped reaching the payload at all, the handler would never run, the
// grace would expire, and SIGKILL would report a signal rather than 7.
func TestCancelHonoursThePayloadsTermHandler(t *testing.T) {
	c := newCollector()
	ex := start(t, testPolicy(t),
		[]string{"/bin/sh", "-c", `trap 'exit 7' TERM; echo ready; sleep 30`},
		c.sink)
	_ = ex.WriteStdin(nil, true)
	waitFor(t, 10*time.Second, func() bool { return strings.Contains(c.out(), "ready") })
	startT := time.Now()
	ex.Cancel()
	res := ex.Wait()
	elapsed := time.Since(startT)
	if elapsed > jail.KillGrace {
		t.Fatalf("payload took %s to honour TERM, past the %s grace: %+v",
			elapsed, jail.KillGrace, res)
	}
	if res.Signal != 0 {
		t.Fatalf("payload reported killed by signal %d; its TERM handler chose to exit 7: %+v",
			res.Signal, res)
	}
	if res.Code != 7 {
		t.Fatalf("payload exit code = %d, want 7 (the status its own TERM handler chose): %+v",
			res.Code, res)
	}
}

// The other rung: a payload that ignores TERM must outlive the grace and
// be ended by the KILL, in a jail as much as out of one.
//
// The failure this test exists to catch is not "TERM killed it" — a
// SIG_IGN payload cannot be killed by TERM. It is the jail being
// demolished around a payload that was never asked to stop: under bwrap
// the group leader is the supervisor, and killing it SIGKILLs the PID
// namespace init and everything in the namespace with it. That is what
// used to happen here, in 766µs, and the escalation the test names was
// never exercised at all. See cancel.go.
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
		t.Fatalf("TERM-ignoring child died in %s, before the %s grace; "+
			"nothing asked it to stop, so something tore the jail down around it: %+v",
			elapsed, jail.KillGrace, res)
	}
	if elapsed > 15*time.Second {
		t.Fatalf("escalation took %s", elapsed)
	}
	if want := 128 + int(syscall.SIGKILL); res.Code != want {
		t.Fatalf("TERM-ignoring child exited %d, want %d (128+SIGKILL): %+v",
			res.Code, want, res)
	}
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

// A policy that names "/" as a readable root — which is exactly what a
// jailed build asking for the toolchain sends, and what the code-mode
// session base sends — must still get the fresh /proc and the minimal
// /dev the new namespaces need. The base view is `--ro-bind / /`, so the
// host's procfs and device tree are in the jail until the two mask
// mounts cover them; a bind of "/" emitted after those masks puts them
// straight back.
//
// Two distinct things go wrong when it does, and this test asserts both
// because they fail independently.
//
// /proc is a confinement gap: every host process, its command line and
// its environment, readable from inside a jail that reports itself fully
// enforced, with /proc/self resolving to the host pid.
//
// /dev is a functional break, and it is the one that made
// `make e2e-codemode` look like a timeout. bwrap binds with MS_NODEV
// unless asked for --dev-bind, so the re-exposed host device tree is a
// nodev view in which no node can be opened at all. The BEAM that
// `gleam build` spawns retries openat("/dev/null", O_WRONLY) against the
// resulting EACCES forever; the build never returns. See issue #37.
func TestFreshProcAndDevSurviveAReadableRootOfSlash(t *testing.T) {
	feat := jail.DetectFeatures()
	if feat.BwrapPath == "" {
		t.Skip("a private /proc and /dev are bwrap's to mount; no bwrap here")
	}
	pol := testPolicy(t)
	pol.ReadableRoots = []string{"/"}
	c := newCollector()
	// Every field is computed before anything is written, and the write
	// goes to stdout, because in the broken jail /dev/null cannot be
	// opened and a probe that redirected to it would die before
	// reporting.
	ex := start(t, pol, []string{"/bin/sh", "-c",
		`p=$(ls -d /proc/[0-9]* | wc -l); i=$(tr "\0" " " < /proc/1/cmdline | cut -c1-24); ` +
			`if echo x > /dev/null; then d=ok; else d=EACCES; fi; ` +
			`if (exec 8<> /proc/self/oom_score_adj) 2>/dev/null; then w=WRITABLE; else w=denied; fi; ` +
			`if (exec 9<> /proc/sys/kernel/randomize_va_space) 2>/dev/null; then k=WRITABLE; else k=denied; fi; ` +
			`echo "pids=$p devnull=$d procwrite=$w hostknob=$k init=$i"`},
		c.sink)
	_ = ex.WriteStdin(nil, true)
	res := ex.Wait()
	if res.Code != 0 {
		t.Fatalf("probe failed: %+v", res)
	}
	out := strings.TrimSpace(c.out())

	// The helper's own pid is a process the jail must not be able to see.
	// Counting is the readable assertion; this is the sharp one.
	hostPids := len(hostProcDirs(t))
	var jailPids int
	for _, field := range strings.Fields(out) {
		if n, ok := strings.CutPrefix(field, "pids="); ok {
			jailPids, _ = strconv.Atoi(n)
		}
	}
	if jailPids == 0 {
		t.Fatalf("probe produced no pid count: %q", out)
	}
	// bwrap's own jail holds the supervisor's init, stage 2 and the
	// probe's own pipeline: a handful. The host has every process on the
	// machine. A jail seeing anything close to the host's count is
	// looking at the host's procfs.
	if jailPids > 16 || jailPids >= hostPids {
		t.Fatalf("jail sees %d pids in /proc (host has %d): the fresh procfs was "+
			"undone by a later bind of \"/\". Output: %q", jailPids, hostPids, out)
	}
	// And pid 1 in there is the jail's own init, not the host's.
	hostInit, err := os.ReadFile("/proc/1/cmdline")
	if err == nil && len(hostInit) > 4 {
		head := strings.TrimSpace(strings.ReplaceAll(string(hostInit[:min(24, len(hostInit))]), "\x00", " "))
		if head != "" && strings.Contains(out, head) {
			t.Fatalf("jail's /proc/1 is the *host* init (%q): %q", head, out)
		}
	}
	// The sharp one for #37: a device node the jail owns must be
	// openable. When the host /dev is back, it is not — and nothing in
	// the jail that wants a null sink will ever make progress again.
	if !strings.Contains(out, "devnull=ok") {
		t.Fatalf("jail cannot open /dev/null: the minimal /dev was undone by a "+
			"later bind of \"/\" and re-exposed the host device tree nodev. Output: %q", out)
	}
	// Opening proc files O_RDWR without writing any bytes is a non-mutating
	// witness for whether the Landlock grant widened /proc. oom_score_adj is
	// otherwise writable and catches the grant even when bwrap independently
	// remounts /proc/sys read-only; the sysctl checks the host-global case.
	if feat.LandlockABI > 0 && (!strings.Contains(out, "procwrite=denied") ||
		!strings.Contains(out, "hostknob=denied")) {
		t.Fatalf("Landlock allows write access through the jail's private "+
			"/proc: %q", out)
	}
}

func hostProcDirs(t *testing.T) []string {
	t.Helper()
	entries, err := os.ReadDir("/proc")
	if err != nil {
		t.Fatalf("read /proc: %v", err)
	}
	var pids []string
	for _, e := range entries {
		if _, err := strconv.Atoi(e.Name()); err == nil {
			pids = append(pids, e.Name())
		}
	}
	return pids
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
	// Keep stderr on the existing pipe. A redirection on the compound loop
	// would make Landlock reject the loop before it attempts any forks.
	script := "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do sleep 1 & done; wait; echo attempted"
	ex := start(t, pol, []string{"/bin/sh", "-c", script}, c.sink)
	_ = ex.WriteStdin(nil, true)
	res := ex.Wait()
	if res.PidsMaxEvents == 0 {
		t.Fatal("no pids.max denials recorded for a 16-way fork burst under pids=8")
	}
}

// A policy asking for ceilings only cgroups can hold must come back
// saying whether it got them. Either outcome is honest; silence is not,
// and silence is what a full-enforcement demand reads as success.
//
// The assertion holds on both kinds of machine, which is the point: a
// developer container with no v2 delegation reports the skip, a host
// with a delegated base reports the layer, and neither reports nothing.
func TestCgroupCeilingsAreEitherAppliedOrReportedSkipped(t *testing.T) {
	pol := testPolicy(t)
	pol.Limits.Pids = 32
	pol.Limits.MemBytes = 256 << 20
	c := newCollector()
	ex := start(t, pol, []string{"/bin/sh", "-c", "true"}, c.sink)
	_ = ex.WriteStdin(nil, true)
	res := ex.Wait()

	applied, skipped := false, false
	for _, e := range res.Enforcement {
		switch {
		case e == jail.CgroupSkipPrefix:
			applied = true
		case strings.HasPrefix(e, "skip:"+jail.CgroupSkipPrefix):
			skipped = true
		}
	}
	if applied == skipped {
		t.Fatalf("mem/pids ceilings were demanded; enforcement %v says neither "+
			"that a cgroup held them nor that none did", res.Enforcement)
	}
	if skipped && jail.DetectFeatures().CgroupDir != "" {
		t.Fatalf("a delegated cgroup base exists but the ceilings were skipped: %v",
			res.Enforcement)
	}
}

// The converse: an execution that asked for no cgroup-held ceiling has
// no cgroup gap to report, and inventing one would devalue every real
// skip entry the broker refuses on.
func TestNoCgroupSkipWhenNoCeilingWasDemanded(t *testing.T) {
	pol := testPolicy(t) // Limits.Pids and MemBytes both zero
	c := newCollector()
	ex := start(t, pol, []string{"/bin/sh", "-c", "true"}, c.sink)
	_ = ex.WriteStdin(nil, true)
	res := ex.Wait()
	for _, e := range res.Enforcement {
		if strings.HasPrefix(e, "skip:"+jail.CgroupSkipPrefix) {
			t.Fatalf("nothing cgroup-held was demanded: %v", res.Enforcement)
		}
	}
}
