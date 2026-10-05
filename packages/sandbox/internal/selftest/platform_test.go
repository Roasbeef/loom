package selftest

import (
	"errors"
	"io/fs"
	"strings"
	"syscall"
	"testing"

	"github.com/roasbeef/loom/sandbox/internal/jail"
)

// The gate that decides whether the probes run at all. On a build with no
// jail they must not: there is nothing to probe, and a run of zero probes
// reported as zero failures is the shape of a false pass.
func TestPlatformGateStopsTheProbesAndSaysSo(t *testing.T) {
	var out strings.Builder
	if platformGate(&out, jail.PlatformFor("windows")) {
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

func TestPlatformGateLetsDarwinThrough(t *testing.T) {
	var out strings.Builder
	if !platformGate(&out, jail.PlatformFor("darwin")) {
		t.Fatal("darwin must run the real Seatbelt probes")
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
	report := unsupportedPlatformReport(jail.PlatformFor("windows"))
	for _, want := range []string{
		"NOT RUN",
		"Windows",
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

// A probe root the host refuses to create must stop the run with one NOT
// RUN summary, not eleven probe failures, and must not read as a pass.
func TestProbeRootGateReportsNotRunOnPermissionDenied(t *testing.T) {
	var out strings.Builder
	refused := func() (string, error) {
		return "", &fs.PathError{Op: "mkdir", Path: "/private/tmp/x", Err: syscall.EPERM}
	}
	if probeRootGate(&out, refused) {
		t.Fatal("the probes must not run when the probe root is refused")
	}
	for _, want := range []string{"NOT RUN", "already inside a sandbox", "RESULT: NOT RUN"} {
		if !strings.Contains(out.String(), want) {
			t.Fatalf("report must contain %q:\n%s", want, out.String())
		}
	}
	if strings.Contains(out.String(), "RESULT: OK") {
		t.Fatalf("a run that probed nothing is not a pass:\n%s", out.String())
	}
}

// Any other failure to make the directory is the probes' to report, and a
// writable root runs them.
func TestProbeRootGateLeavesOtherOutcomesToTheProbes(t *testing.T) {
	var out strings.Builder
	if !probeRootGate(&out, func() (string, error) { return t.TempDir(), nil }) {
		t.Fatal("a writable probe root must run the probes")
	}
	other := func() (string, error) { return "", errors.New("disk full") }
	if !probeRootGate(&out, other) {
		t.Fatal("a non-permission failure is reported by the probes themselves")
	}
	if strings.TrimSpace(out.String()) != "" {
		t.Fatalf("the gate prints nothing when it lets the probes run:\n%s", out.String())
	}
}
