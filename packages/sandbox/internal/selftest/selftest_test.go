//go:build linux

package selftest_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/roasbeef/loom/sandbox/internal/jail"
	"github.com/roasbeef/loom/sandbox/internal/selftest"
	"github.com/roasbeef/loom/sandbox/internal/testbin"
)

// The self-test must succeed wherever it runs: probes for layers the
// environment lacks report SKIPPED, and only a probe whose layer exists
// but fails to enforce may flunk the run.
func TestSelfTestRuns(t *testing.T) {
	var out strings.Builder
	ok := selftest.Run(&out, testbin.Helper(t))
	t.Logf("self-test output:\n%s", out.String())
	if !ok {
		t.Fatal("self-test reported an enforceable probe failure")
	}
	if !strings.Contains(out.String(), "enforcement summary") {
		t.Fatal("summary section missing")
	}
	// The two supervision-level probes need no kernel opt-in and must
	// be ENFORCED everywhere, containers included.
	for _, must := range []string{
		"ENFORCED  output flood truncated at cap",
		"ENFORCED  orphaned grandchild reaped via pgroup",
		"ENFORCED  env not in allowlist withheld",
	} {
		if !strings.Contains(out.String(), must) {
			t.Fatalf("expected %q in output", must)
		}
	}
}

// A probe whose writable root sits under the jail's own scratch mount
// tests nothing: the tmpfs scratch is mounted after the writable binds,
// so the root it was given is shadowed and every write to it fails. The
// probe then reports the jail broken when it is merely misconfigured —
// and on a runner with no TMPDIR set, which is the usual CI shape, the
// default temp directory is exactly that place.
func TestProbeDirectoriesAreNotUnderTheScratchMount(t *testing.T) {
	dir, err := selftest.ProbeDirForTest()
	if err != nil {
		t.Fatalf("probe dir: %v", err)
	}
	defer os.RemoveAll(dir)
	if strings.HasPrefix(filepath.Clean(dir)+string(filepath.Separator),
		jail.ScratchMount+string(filepath.Separator)) {
		t.Fatalf("probe directory %q is under the scratch mount %q; the "+
			"jail's own tmpfs will hide the writable root the probes "+
			"were given", dir, jail.ScratchMount)
	}

	// Nor under a directory every Seatbelt plan grants, or the probes'
	// "outside" victim would be inside the jail.
	for _, granted := range jail.DarwinUserDirectories() {
		if strings.HasPrefix(filepath.Clean(dir)+string(filepath.Separator),
			filepath.Clean(granted)+string(filepath.Separator)) {
			t.Fatalf("probe directory %q is under the granted user directory %q", dir, granted)
		}
	}
}

// A cgroup base the helper can create children in but not move
// processes into (cgroup v2 delegation containment) leaves the ceilings
// binding nothing. That is a grant the machine did not give, not a jail
// that broke, and the probe must say SKIPPED with the helper's own
// reason rather than FAILED.
func TestForkBombProbeReadsTheCgroupSkipRatherThanBlamingTheJail(t *testing.T) {
	reason := "cgroup-v2: enter denied; memory.max/pids.max were NOT applied"
	got := selftest.CgroupSkipEntryForTest([]string{
		"bwrap", "seccomp-net", "skip:" + reason, "skip:landlock: nope",
	})
	if got != reason {
		t.Fatalf("cgroupSkipEntry = %q, want %q", got, reason)
	}
	if none := selftest.CgroupSkipEntryForTest([]string{
		"bwrap", "cgroup-v2", "skip:landlock: nope",
	}); none != "" {
		t.Fatalf("an applied cgroup must not read as skipped: %q", none)
	}
}

// The hostile-`.beam` probe reports ENFORCED when three attempts fail —
// and three attempts failing is also exactly what a broken probe, a
// module that never loaded, or a mistyped path looks like. So the probe
// is worth nothing without this: the same adversary, the same argv, and
// the same jail, run once with the three mechanisms it measures granted
// rather than withheld. If that run does not reach all three, the
// confined run's denials are not evidence of anything and this test says
// so instead of letting the probe stay green.
//
// The escape it demonstrates is real but reaches nothing that outlives
// the test: a writable root the probe created under its own scratch
// directory, and a loopback listener the probe is holding open.
func TestTheHostileBeamReachesEverythingWhenTheJailStopsRefusing(t *testing.T) {
	got, why, err := selftest.RunHostileBeamForTest(testbin.Helper(t), false)
	if err != nil {
		t.Fatalf("permissive run: %v", err)
	}
	if why != "" {
		t.Skipf("cannot assemble the adversary here: %s", why)
	}
	t.Logf("permissive run: %s", got.Summary)
	if !got.Loaded || !got.Done {
		t.Fatalf("the adversary did not run to completion even unconfined, "+
			"so the probe's denials mean nothing: %s", got.Summary)
	}
	for _, reach := range []struct {
		name string
		got  bool
	}{
		{"read the protected secret", got.SecretRead},
		{"write outside the writable root", got.OutsideWrite},
		{"connect to the host listener", got.NetConnect},
	} {
		if !reach.got {
			t.Errorf("with the mechanism granted, the adversary still could "+
				"not %s — the probe's ENFORCED verdict for it is vacuous: %s",
				reach.name, got.Summary)
		}
	}
}

// And the other side of the same pair, so the two verdicts sit next to
// each other in one log: with the policy asking for confinement, the
// adversary still runs and still performs the effects the policy allows,
// and reaches none of the three.
func TestTheHostileBeamReachesNothingWhenTheJailRefuses(t *testing.T) {
	got, why, err := selftest.RunHostileBeamForTest(testbin.Helper(t), true)
	if err != nil {
		t.Fatalf("confined run: %v", err)
	}
	if why != "" {
		t.Skipf("cannot assemble the adversary here: %s", why)
	}
	t.Logf("confined run: %s", got.Summary)
	if !got.Loaded || !got.Done {
		t.Fatalf("the node never ran to completion in the jail, so nothing "+
			"was contained: %s", got.Summary)
	}
	if !got.ReadOK || !got.WriteOK {
		t.Fatalf("the adversary could not do what the policy ALLOWS, so its "+
			"denials are not the jail's doing: %s", got.Summary)
	}
	if got.SecretRead || got.OutsideWrite || got.NetConnect {
		t.Fatalf("the adversary reached past the jail: %s", got.Summary)
	}
}

// #54: with a `bwrap` on PATH that exits 1 without running anything,
// every jailed exec dies before the payload starts. Eight probes said
// FAILED; two said ENFORCED, because their success condition was the
// *absence* of an effect — an untouched secret file, a prompt `Wait` —
// and nothing having run satisfies both. A probe must not report
// containment on silence: the payload has to announce that it ran, the
// way the hostile-`.beam` probe's controls do.
func TestNoProbeReportsEnforcedWhenNothingRan(t *testing.T) {
	shim := t.TempDir()
	script := "#!/bin/sh\nexit 1\n"
	if err := os.WriteFile(filepath.Join(shim, "bwrap"), []byte(script), 0o755); err != nil {
		t.Fatalf("write bwrap shim: %v", err)
	}
	helper := testbin.Helper(t)
	t.Setenv("PATH", shim+string(os.PathListSeparator)+os.Getenv("PATH"))

	var out strings.Builder
	if selftest.Run(&out, helper) {
		t.Fatalf("the suite passed with a bwrap that never ran:\n%s", out.String())
	}
	t.Logf("self-test output:\n%s", out.String())
	for _, line := range strings.Split(out.String(), "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "ENFORCED") {
			t.Errorf("probe reported enforcement with a bwrap that exits 1 "+
				"before the payload runs: %q", strings.TrimSpace(line))
		}
	}
}
