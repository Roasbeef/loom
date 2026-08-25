package selftest

import (
	"strings"
	"testing"

	"github.com/roasbeef/loom/sandbox/internal/jail"
)

// The gate that decides whether the probes run at all. On a build with no
// jail they must not: there is nothing to probe, and a run of zero probes
// reported as zero failures is the shape of a false pass.
func TestPlatformGateStopsTheProbesAndSaysSo(t *testing.T) {
	var out strings.Builder
	if platformGate(&out, jail.PlatformFor("darwin")) {
		t.Fatal("the probes must not run on a build with no jail")
	}
	if !strings.Contains(out.String(), "UNSUPPORTED PLATFORM") {
		t.Fatalf("the gate must say why it stopped:\n%s", out.String())
	}
}

func TestPlatformGateLetsLinuxThrough(t *testing.T) {
	var out strings.Builder
	if !platformGate(&out, jail.PlatformFor("linux")) {
		t.Fatal("linux must run its probes")
	}
	if strings.TrimSpace(out.String()) != "" {
		t.Fatalf("a supported platform prints no verdict here:\n%s", out.String())
	}
}

// The self-test's one refusal that is not a probe failure: a build with
// no jail for its platform. Exercised from Linux against the pure report
// builder, because the only host that could drive the live path is a Mac
// and none has ever run this code.
func TestUnsupportedPlatformIsNotAPass(t *testing.T) {
	report := unsupportedPlatformReport(jail.PlatformFor("darwin"))
	for _, want := range []string{
		"NOT RUN",
		"Seatbelt",
		"nothing was attempted",
		"RESULT: UNSUPPORTED PLATFORM",
	} {
		if !strings.Contains(report, want) {
			t.Fatalf("report must contain %q:\n%s", want, report)
		}
	}
	// Neither sentence a green Linux run prints may appear: one would
	// blame the environment for the skips, the other would call the run
	// a pass.
	for _, forbidden := range []string{"RESULT: OK", "skips are environmental"} {
		if strings.Contains(report, forbidden) {
			t.Fatalf("report must not claim %q:\n%s", forbidden, report)
		}
	}
}
