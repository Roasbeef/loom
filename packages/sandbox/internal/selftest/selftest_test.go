//go:build linux

package selftest_test

import (
	"strings"
	"testing"

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
