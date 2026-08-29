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
	"strconv"
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
		{"protected path masked from reads and writes", probeProtected},
		{"direct socket denied under network off", probeSocketOff},
		{"env not in allowlist withheld", probeEnvAllowlist},
		{"fork bomb capped by pids limit", probeForkBomb},
		{"output flood truncated at cap", probeOutputFlood},
		{"orphaned grandchild reaped via pgroup", probeOrphanReap},
		{"setsid escape contained by pid namespace", probeSetsidEscape},
		{"unvetted beam denied host write, secret, and network", probeHostileBeam},
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

// probeDir creates a scratch directory for one probe, outside the
// jail's scratch mount.
//
// This is load-bearing, not hygiene. A "tmpfs" scratch policy mounts a
// fresh tmpfs at jail.ScratchMount ("/tmp") *after* the writable binds,
// so a writable root underneath it is shadowed by the jail's own
// scratch and every write to it fails. os.MkdirTemp("") lands exactly
// there on a host with no TMPDIR set, which is most CI runners — and
// the probe would then report "jail broken, not tight" for a jail that
// is neither. The confinement is fail-closed either way (the root
// becomes unwritable, never wider), so this is the probe's bug to fix
// and not the jail's.
func probeDir() (string, error) {
	base := os.TempDir()
	if underScratchMount(base) {
		// /var/tmp is POSIX and is never the tmpfs scratch target.
		if fi, err := os.Stat(alternateTempRoot); err == nil && fi.IsDir() {
			base = alternateTempRoot
		}
	}
	return os.MkdirTemp(base, "loom-selftest-*")
}

// alternateTempRoot is where probes go when the default temp directory
// is the one the scratch tmpfs will cover.
const alternateTempRoot = "/var/tmp"

// underScratchMount reports whether dir would be hidden by a tmpfs
// scratch mount at jail.ScratchMount.
func underScratchMount(dir string) bool {
	clean := filepath.Clean(dir)
	return clean == jail.ScratchMount ||
		strings.HasPrefix(clean, jail.ScratchMount+string(filepath.Separator))
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
	dir, err := probeDir()
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
	dir, err := probeDir()
	if err != nil {
		return probeResult{outcome: failed, detail: err.Error()}
	}
	defer os.RemoveAll(dir)

	// Two markers, one per inode type, each unique enough that finding
	// it anywhere in the jail's output is unambiguous.
	const fileMarker = "LOOM-PROBE-FILE-SECRET-BYTES"
	const dirMarker = "LOOM-PROBE-DIR-SECRET-BYTES"
	secret := filepath.Join(dir, "secret.env")
	original := "TOKEN=" + fileMarker + "\n"
	if err := os.WriteFile(secret, []byte(original), 0o600); err != nil {
		return probeResult{outcome: failed, detail: err.Error()}
	}
	secretDir := filepath.Join(dir, "secrets.d")
	if err := os.MkdirAll(secretDir, 0o700); err != nil {
		return probeResult{outcome: failed, detail: err.Error()}
	}
	dirEntry := filepath.Join(secretDir, "loom-probe-private-key")
	dirContents := dirMarker + "\n"
	if err := os.WriteFile(dirEntry, []byte(dirContents), 0o600); err != nil {
		return probeResult{outcome: failed, detail: err.Error()}
	}

	pol := basePolicy(dir) // the protected paths sit INSIDE the writable root
	pol.Protected = []string{secret, secretDir}
	// The witness: an effect the policy *allows*, performed by the same
	// payload, in the same jail, before the two it forbids. An untouched
	// secret file is equally consistent with a mask that held and with a
	// payload that never started — and #54 was reported from exactly the
	// second case, a `bwrap` that exited 1 before exec'ing anything.
	// ALLOWED-OK is what tells those apart. It is the discriminator the
	// hostile-`.beam` probe was built around, applied here.
	allowed := filepath.Join(dir, "allowed")
	script := fmt.Sprintf(
		"echo ok > %s && echo ALLOWED-OK; "+
			"cat %s; cat %s; ls %s; "+
			"echo clobbered > %s && echo WROTE; rm -f %s && echo REMOVED",
		allowed, secret, dirEntry, secretDir, secret, secret)
	_, out, err := runShell(feat, selfExe, pol, script)
	if err != nil {
		return probeResult{outcome: failed, detail: "spawn: " + err.Error()}
	}
	got, err := os.ReadFile(secret)
	if err != nil || string(got) != original {
		return probeResult{outcome: failed,
			detail: fmt.Sprintf("protected file modified (jail said: %q)", strings.TrimSpace(out))}
	}
	if got, err := os.ReadFile(dirEntry); err != nil || string(got) != dirContents {
		return probeResult{outcome: failed,
			detail: fmt.Sprintf("protected directory modified (jail said: %q)",
				strings.TrimSpace(out))}
	}
	// "Protected" means the contents are gone from the jail's view, not
	// merely unwritable — for a directory and, since #55, for a file
	// too. A read is what an adversary in the jail actually wants from a
	// credential file, and `protected: [".aws/credentials"]` handing
	// those over while refusing the write back is the shape that bug had.
	if strings.Contains(out, fileMarker) {
		return probeResult{outcome: failed,
			detail: "the protected file's contents were readable inside the jail"}
	}
	if strings.Contains(out, dirMarker) ||
		strings.Contains(out, filepath.Base(dirEntry)) {
		return probeResult{outcome: failed,
			detail: "the protected directory's contents were readable inside the jail"}
	}
	if !strings.Contains(out, "ALLOWED-OK") {
		return probeResult{outcome: failed,
			detail: fmt.Sprintf("the payload never announced itself, so the "+
				"untouched secret is evidence of nothing (out %q)", out)}
	}
	return probeResult{outcome: enforced}
}

func probeSocketOff(feat jail.Features, selfExe string) probeResult {
	if !feat.Seccomp {
		return probeResult{outcome: skipped, detail: "kernel lacks seccomp filter support"}
	}
	dir, err := probeDir()
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
	dir, err := probeDir()
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
	dir, err := probeDir()
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
	// That chatter must stay on the existing stderr pipe: redirecting the
	// compound loop to /dev/null asks Landlock for a write this policy does
	// not grant, so the shell rejects the loop before attempting one fork.
	script := `for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32; do
  sleep 1 &
done
wait
echo attempted`
	res, _, err := runShell(feat, selfExe, pol, script)
	if err != nil {
		return probeResult{outcome: failed, detail: "spawn: " + err.Error()}
	}
	// Detect proved it could create a child of the base; it cannot prove
	// a process may be *moved* into one, which cgroup v2's delegation
	// containment rule governs separately (the base must be the common
	// ancestor of the helper and the per-exec cgroup, so the helper has
	// to live inside the delegated subtree). When that fails the ceiling
	// bound nothing, and the run says so — reporting it as a failed probe
	// would blame the jail for a grant it was never given.
	if skip := cgroupSkipEntry(res.Enforcement); skip != "" {
		return probeResult{outcome: skipped, detail: skip}
	}
	if res.PidsMaxEvents == 0 {
		return probeResult{outcome: failed,
			detail: "32-way fork burst produced no pids.max denials under pids=8"}
	}
	return probeResult{outcome: enforced}
}

// cgroupSkipEntry returns the reason from a cgroup skip entry in an
// enforcement report, or "" when the ceilings were applied.
func cgroupSkipEntry(enforcement []string) string {
	prefix := "skip:" + jail.CgroupSkipPrefix
	for _, e := range enforcement {
		if strings.HasPrefix(e, prefix) {
			return strings.TrimPrefix(e, "skip:")
		}
	}
	return ""
}

// setsidPatience is how long the runner waits before calling a session
// escape uncontained. The escapee sleeps far longer (see
// cmd/loom-exec's --probe-setsid), so the two cases are not close
// together: a contained escape returns in well under a second.
const setsidPatience = 10 * time.Second

// probeSetsidEscape checks the one hole in the pgroup contract. The
// helper reaps by signalling the child's *process group*, and a process
// that calls setsid(2) is no longer in it — under bwrap that does not
// matter, because the PID namespace dies with its init and takes every
// process in it, escapee included. This probe makes the escape and then
// uses the same ground truth as the orphan probe: the escapee holds the
// jail's stdout open, so Wait can only return promptly if it is dead.
//
// Degraded mode is a skip, not a failure. Without bwrap there is no PID
// namespace and the pgroup sweep genuinely does not reach a new session
// — that is a missing layer, honestly reported, and pretending to test
// it here would be the substitution this package exists to prevent.
func probeSetsidEscape(feat jail.Features, selfExe string) probeResult {
	if feat.BwrapPath == "" {
		return probeResult{outcome: skipped,
			detail: "containing a setsid escape needs bwrap's PID namespace; " +
				"the pgroup sweep alone cannot reach a new session"}
	}
	dir, err := probeDir()
	if err != nil {
		return probeResult{outcome: failed, detail: err.Error()}
	}
	defer os.RemoveAll(dir)

	pol := basePolicy(dir)
	// The launcher waits a beat before exiting, only so the escapee has
	// time to report that it really did leave the session — under bwrap
	// the namespace dies the instant the launcher does, which is the
	// containment being measured and would otherwise race the evidence
	// of the escape. After that the escapee, in its own session, is
	// alone holding the output pipe.
	script := "'" + selfExe + "' --probe-setsid & sleep 1; echo launcher-done"
	start := time.Now()
	_, out, err := runShell(feat, selfExe, pol, script)
	if err != nil {
		return probeResult{outcome: failed, detail: "spawn: " + err.Error()}
	}
	elapsed := time.Since(start)
	switch {
	case strings.Contains(out, "setsid-denied"):
		return probeResult{outcome: skipped,
			detail: "the escapee could not call setsid (already a group " +
				"leader), so no escape was attempted and none was tested"}
	case !strings.Contains(out, "setsid-ok"):
		return probeResult{outcome: failed,
			detail: fmt.Sprintf("probe inconclusive: no escape reported (out %q)", out)}
	case strings.Contains(out, "setsid-survived"):
		return probeResult{outcome: failed,
			detail: "the escapee outlived the jail it left"}
	case elapsed > setsidPatience:
		return probeResult{outcome: failed,
			detail: fmt.Sprintf("Wait took %s; the setsid escapee held the jail open", elapsed)}
	}
	return probeResult{outcome: enforced}
}

func probeOutputFlood(feat jail.Features, selfExe string) probeResult {
	dir, err := probeDir()
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
	dir, err := probeDir()
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
	// The shell prints the orphan's own pid, which it can only do after
	// forking it — the witness that there was an orphan to reap. A
	// prompt `Wait` on its own is equally consistent with a reaped
	// grandchild and with a jail that never started one, and #54 was
	// reported from the second case.
	res, out, err := runShell(feat, selfExe, pol, "sleep 30 & echo orphan-started $!")
	if err != nil {
		return probeResult{outcome: failed, detail: "spawn: " + err.Error()}
	}
	elapsed := time.Since(start)
	if pid := orphanPid(out); pid <= 0 {
		return probeResult{outcome: failed,
			detail: fmt.Sprintf("no orphan was ever forked, so a prompt Wait "+
				"proves nothing (out %q, exit %d)", out, res.Code)}
	}
	if elapsed > 10*time.Second {
		return probeResult{outcome: failed,
			detail: fmt.Sprintf("Wait took %s; orphan held the jail open", elapsed)}
	}
	return probeResult{outcome: enforced}
}

// orphanPid reads the pid the orphan probe's shell announced, or 0 when
// it announced nothing readable. Inside the jail's PID namespace the
// number is namespace-local and cannot be signalled from here; it is
// the *announcement* that is the evidence, not the value.
func orphanPid(out string) int {
	rest, ok := strings.CutPrefix(strings.TrimSpace(out), "orphan-started ")
	if !ok {
		return 0
	}
	pid, err := strconv.Atoi(strings.TrimSpace(rest))
	if err != nil {
		return 0
	}
	return pid
}

// ProbeDirForTest exposes probeDir so the invariant it exists to keep —
// probe directories outside the scratch mount — is testable from the
// package's external test, which is where the rest of the self-test's
// own tests live.
func ProbeDirForTest() (string, error) { return probeDir() }

// CgroupSkipEntryForTest exposes cgroupSkipEntry to the package's
// external test, where the rest of the self-test's tests live.
func CgroupSkipEntryForTest(enforcement []string) string {
	return cgroupSkipEntry(enforcement)
}
