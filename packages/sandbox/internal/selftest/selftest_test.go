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
