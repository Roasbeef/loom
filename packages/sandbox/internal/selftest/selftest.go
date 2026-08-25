// Package selftest is the sandbox regression suite run by
// `loom-exec --self-test`: real executions through the real jail path,
// probing what the current kernel actually enforces.
//
// Honesty rules: a probe whose enforcement layer the environment cannot
// provide prints SKIPPED with the reason — it never fakes a pass and
// never fails the run. A probe whose layer *is* available must enforce,
// or the run exits nonzero. The summary at the end states exactly what
// was enforced versus skipped, so a green self-test in a neutered
// container cannot be mistaken for a verified sandbox.
//
// One case is not a skip at all. On a platform Loom has no jail for, the
// probes cannot fail *or* be excused: nothing was attempted. The run says
// so and exits nonzero, because "skips are environmental, not passes" is a
// claim about a kernel that could have provided the layer, and repeating
// it where the layer was never built would be the exact substitution this
// package exists to prevent.
package selftest

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/roasbeef/loom/sandbox/internal/jail"
	"github.com/roasbeef/loom/sandbox/internal/policy"
)

// outcome of one probe.
type outcome int

const (
	enforced outcome = iota
	skipped
	failed
)

type probeResult struct {
	name    string
	outcome outcome
	detail  string
}

// Run executes every probe and prints the report to w. selfExe is the
// loom-exec binary to spawn as stage 2 and as the socket probe (main
// passes its own path; tests pass a freshly built helper). Returns
// false when any enforceable probe failed.
func Run(w io.Writer, selfExe string) bool {
	feat := jail.DetectFeatures()

	fmt.Fprintf(w, "loom-exec self-test\n")
	fmt.Fprintf(w, "  features: %s\n", strings.Join(feat.List(), ", "))
	if !platformGate(w, feat.Platform) {
		return false
	}

	probes := []struct {
		name string
		run  func(feat jail.Features, selfExe string) probeResult
	}{
		{"write outside writable_roots denied", probeWriteOutside},
		{"protected path write denied", probeProtected},
		{"direct socket denied under network off", probeSocketOff},
		{"env not in allowlist withheld", probeEnvAllowlist},
		{"fork bomb capped by pids limit", probeForkBomb},
		{"output flood truncated at cap", probeOutputFlood},
		{"orphaned grandchild reaped via pgroup", probeOrphanReap},
	}

	ok := true
	var enforcedNames, skippedNames []string
	for _, p := range probes {
		res := p.run(feat, selfExe)
		res.name = p.name
		switch res.outcome {
		case enforced:
			fmt.Fprintf(w, "  ENFORCED  %s\n", res.name)
			enforcedNames = append(enforcedNames, res.name)
		case skipped:
			fmt.Fprintf(w, "  SKIPPED   %s (%s)\n", res.name, res.detail)
			skippedNames = append(skippedNames, res.name+": "+res.detail)
		case failed:
			fmt.Fprintf(w, "  FAILED    %s (%s)\n", res.name, res.detail)
			ok = false
		}
	}

	fmt.Fprintf(w, "\n==== enforcement summary ====\n")
	fmt.Fprintf(w, "enforced (%d):\n", len(enforcedNames))
	for _, n := range enforcedNames {
		fmt.Fprintf(w, "  + %s\n", n)
	}
	fmt.Fprintf(w, "skipped (%d) — NOT verified in this environment:\n", len(skippedNames))
	for _, n := range skippedNames {
		fmt.Fprintf(w, "  - %s\n", n)
	}
	if !ok {
		fmt.Fprintf(w, "\nRESULT: FAIL (an enforceable probe did not enforce)\n")
	} else {
		fmt.Fprintf(w, "\nRESULT: OK (skips are environmental, not passes)\n")
	}
	return ok
}

// platformGate decides whether the probes run at all, writing the
// unsupported-platform report in their place when they do not. Split out
// and taking the support value as an argument so the branch no Linux host
// can reach is still exercised by a Linux test.
func platformGate(w io.Writer, p jail.PlatformSupport) bool {
	if p.Implemented {
		fmt.Fprintln(w)
		return true
	}
	fmt.Fprintf(w, "\n%s\n", unsupportedPlatformReport(p))
	return false
}

// unsupportedPlatformReport is what the self-test prints instead of
// probes on a build with no jail.
func unsupportedPlatformReport(p jail.PlatformSupport) string {
	return fmt.Sprintf(
		"  NOT RUN   every probe (%s)\n\n"+
			"==== enforcement summary ====\n"+
			"enforced (0):\n"+
			"nothing was attempted: loom-exec has no jail for %s\n\n"+
			"RESULT: UNSUPPORTED PLATFORM (not a pass; no confinement "+
			"was applied or probed)",
		p.Reason, p.GOOS,
	)
}

// basePolicy builds a network-off policy writable only in dir.
func basePolicy(dir string) policy.Policy {
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

var defaultEnv = map[string]string{"PATH": "/usr/local/bin:/usr/bin:/bin"}

// runShell executes a shell snippet under pol, returning the result and
// collected stdout.
func runShell(feat jail.Features, selfExe string, pol policy.Policy, script string) (jail.Result, string, error) {
	var out strings.Builder
	sink := func(stream string, data []byte, total uint64, trunc bool) {
		if stream == "stdout" {
			out.Write(data)
		}
	}
	ex, err := jail.Start(jail.Request{
		Argv:   []string{"/bin/sh", "-c", script},
		Env:    defaultEnv,
		Cwd:    "/",
		Policy: pol,
	}, feat, selfExe, sink)
	if err != nil {
		return jail.Result{}, "", err
	}
	if err := ex.WriteStdin(nil, true); err != nil {
		return jail.Result{}, "", err
	}
	res := ex.Wait()
	return res, out.String(), nil
}

func probeWriteOutside(feat jail.Features, selfExe string) probeResult {
	if feat.BwrapPath == "" && feat.LandlockABI == 0 {
		return probeResult{outcome: skipped,
			detail: "needs bwrap or Landlock; neither available: " + feat.LandlockReason}
	}
	dir, err := os.MkdirTemp("", "loom-selftest-*")
	if err != nil {
		return probeResult{outcome: failed, detail: err.Error()}
	}
	defer os.RemoveAll(dir)

	victim := filepath.Join(dir, "outside", "victim")
	if err := os.MkdirAll(filepath.Dir(victim), 0o755); err != nil {
		return probeResult{outcome: failed, detail: err.Error()}
	}
	inside := filepath.Join(dir, "inside")
	if err := os.MkdirAll(inside, 0o755); err != nil {
		return probeResult{outcome: failed, detail: err.Error()}
	}

	pol := basePolicy(inside)
	script := fmt.Sprintf("echo escaped > %s && echo WROTE; echo ok > %s/allowed && echo ALLOWED-OK", victim, inside)
	res, out, err := runShell(feat, selfExe, pol, script)
	if err != nil {
		return probeResult{outcome: failed, detail: "spawn: " + err.Error()}
	}
	_ = res
	if strings.Contains(out, "WROTE") {
		return probeResult{outcome: failed, detail: "write outside writable root succeeded"}
	}
	if _, err := os.Stat(victim); err == nil {
		return probeResult{outcome: failed, detail: "victim file exists on host"}
	}
	if !strings.Contains(out, "ALLOWED-OK") {
		return probeResult{outcome: failed, detail: "write inside writable root failed too (jail broken, not tight)"}
	}
	return probeResult{outcome: enforced}
}

func probeProtected(feat jail.Features, selfExe string) probeResult {
	if feat.BwrapPath == "" {
		return probeResult{outcome: skipped,
			detail: "protected-path masking needs bwrap (Landlock has no deny rules)"}
	}
	dir, err := os.MkdirTemp("", "loom-selftest-*")
	if err != nil {
		return probeResult{outcome: failed, detail: err.Error()}
	}
	defer os.RemoveAll(dir)

	secret := filepath.Join(dir, "secret.env")
	const original = "TOKEN=hunter2\n"
	if err := os.WriteFile(secret, []byte(original), 0o600); err != nil {
		return probeResult{outcome: failed, detail: err.Error()}
	}

	pol := basePolicy(dir) // the protected file sits INSIDE the writable root
	pol.Protected = []string{secret}
	script := fmt.Sprintf("echo clobbered > %s && echo WROTE; rm -f %s && echo REMOVED", secret, secret)
	_, out, err := runShell(feat, selfExe, pol, script)
	if err != nil {
		return probeResult{outcome: failed, detail: "spawn: " + err.Error()}
	}
	got, err := os.ReadFile(secret)
	if err != nil || string(got) != original {
		return probeResult{outcome: failed,
			detail: fmt.Sprintf("protected file modified (jail said: %q)", strings.TrimSpace(out))}
	}
	return probeResult{outcome: enforced}
}

func probeSocketOff(feat jail.Features, selfExe string) probeResult {
	if !feat.Seccomp {
		return probeResult{outcome: skipped, detail: "kernel lacks seccomp filter support"}
	}
	dir, err := os.MkdirTemp("", "loom-selftest-*")
	if err != nil {
		return probeResult{outcome: failed, detail: err.Error()}
	}
	defer os.RemoveAll(dir)

	// The probe target is this very binary in --probe-socket mode: it
	// tries socket(AF_INET, SOCK_STREAM) and reports. No dependence on
	// python/curl living in the jail.
	pol := basePolicy(dir)
	var out strings.Builder
	sink := func(stream string, data []byte, total uint64, trunc bool) {
		if stream == "stdout" {
			out.Write(data)
		}
	}
	ex, err := jail.Start(jail.Request{
		Argv:   []string{selfExe, "--probe-socket"},
		Env:    defaultEnv,
		Cwd:    "/",
		Policy: pol,
	}, feat, selfExe, sink)
	if err != nil {
		return probeResult{outcome: failed, detail: "spawn: " + err.Error()}
	}
	_ = ex.WriteStdin(nil, true)
	res := ex.Wait()
	switch {
	case strings.Contains(out.String(), "socket-denied"):
		return probeResult{outcome: enforced}
	case strings.Contains(out.String(), "socket-created"):
		return probeResult{outcome: failed, detail: "AF_INET socket creation succeeded under network off"}
	default:
		return probeResult{outcome: failed,
			detail: fmt.Sprintf("probe inconclusive (exit %d, out %q)", res.Code, out.String())}
	}
}

func probeEnvAllowlist(feat jail.Features, selfExe string) probeResult {
	dir, err := os.MkdirTemp("", "loom-selftest-*")
	if err != nil {
		return probeResult{outcome: failed, detail: err.Error()}
	}
	defer os.RemoveAll(dir)

	pol := basePolicy(dir)
	var out strings.Builder
	sink := func(stream string, data []byte, total uint64, trunc bool) {
		if stream == "stdout" {
			out.Write(data)
		}
	}
	ex, err := jail.Start(jail.Request{
		Argv: []string{"/bin/sh", "-c", "env"},
		Env: map[string]string{
			"PATH":               "/usr/local/bin:/usr/bin:/bin",
			"LOOM_SECRET_CANARY": "if-you-can-read-this-the-allowlist-leaks",
		},
		Cwd:    "/",
		Policy: pol, // env_allow: ["PATH"] only
	}, feat, selfExe, sink)
	if err != nil {
		return probeResult{outcome: failed, detail: "spawn: " + err.Error()}
	}
	_ = ex.WriteStdin(nil, true)
	_ = ex.Wait()
	if strings.Contains(out.String(), "LOOM_SECRET_CANARY") {
		return probeResult{outcome: failed, detail: "non-allowlisted variable visible in jail"}
	}
	if !strings.Contains(out.String(), "PATH=") {
		return probeResult{outcome: failed, detail: "allowlisted PATH missing (env construction broken)"}
	}
	return probeResult{outcome: enforced}
}

func probeForkBomb(feat jail.Features, selfExe string) probeResult {
	if feat.CgroupDir == "" {
		return probeResult{outcome: skipped, detail: "no delegated cgroup v2: " + feat.CgroupReason}
	}
	dir, err := os.MkdirTemp("", "loom-selftest-*")
	if err != nil {
		return probeResult{outcome: failed, detail: err.Error()}
	}
	defer os.RemoveAll(dir)

	pol := basePolicy(dir)
	pol.Limits.Pids = 8
	pol.Limits.WallSeconds = 15
	// Try to hold 32 concurrent sleeps under pids.max=8; the ground
	// truth is the cgroup's own pids.events "max" counter (read by the
	// runner before cleanup), not shell chatter about failed forks.
	script := `for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32; do
  sleep 1 &
done 2>/dev/null
wait 2>/dev/null
echo attempted`
	res, _, err := runShell(feat, selfExe, pol, script)
	if err != nil {
		return probeResult{outcome: failed, detail: "spawn: " + err.Error()}
	}
	if res.PidsMaxEvents == 0 {
		return probeResult{outcome: failed,
			detail: "32-way fork burst produced no pids.max denials under pids=8"}
	}
	return probeResult{outcome: enforced}
}

func probeOutputFlood(feat jail.Features, selfExe string) probeResult {
	dir, err := os.MkdirTemp("", "loom-selftest-*")
	if err != nil {
		return probeResult{outcome: failed, detail: err.Error()}
	}
	defer os.RemoveAll(dir)

	const capBytes = 64 * 1024
	pol := basePolicy(dir)
	pol.Limits.OutputBytes = capBytes
	res, out, err := runShell(feat, selfExe, pol, "head -c 1048576 /dev/zero; echo done 1>&2")
	if err != nil {
		return probeResult{outcome: failed, detail: "spawn: " + err.Error()}
	}
	if !res.StdoutTruncated {
		return probeResult{outcome: failed, detail: "1 MiB flood not marked truncated at 64 KiB cap"}
	}
	if res.StdoutBytes != capBytes || uint64(len(out)) != capBytes {
		return probeResult{outcome: failed,
			detail: fmt.Sprintf("counter mismatch: reported %d, received %d, cap %d", res.StdoutBytes, len(out), capBytes)}
	}
	return probeResult{outcome: enforced}
}

func probeOrphanReap(feat jail.Features, selfExe string) probeResult {
	dir, err := os.MkdirTemp("", "loom-selftest-*")
	if err != nil {
		return probeResult{outcome: failed, detail: err.Error()}
	}
	defer os.RemoveAll(dir)

	// The shell exits immediately, leaving `sleep 30` holding our
	// output pipe. Wait() only returns once every pipe writer is dead,
	// so a prompt return *is* the proof the orphan was reaped (pgroup
	// sweep in degraded mode; dying PID namespace under bwrap).
	pol := basePolicy(dir)
	start := time.Now()
	res, _, err := runShell(feat, selfExe, pol, "sleep 30 & echo orphan-started")
	if err != nil {
		return probeResult{outcome: failed, detail: "spawn: " + err.Error()}
	}
	elapsed := time.Since(start)
	if elapsed > 10*time.Second {
		return probeResult{outcome: failed,
			detail: fmt.Sprintf("Wait took %s; orphan held the jail open", elapsed)}
	}
	_ = res
	return probeResult{outcome: enforced}
}
