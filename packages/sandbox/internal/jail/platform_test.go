package jail

import (
	"strings"
	"testing"
)

// Everything here tests the non-Linux answers from Linux, which is the
// only place they can be tested at all: no macOS or Windows host has ever
// run this code, and until WP-H phases 2 and 3 exist none should be able
// to mistake these strings for evidence that one did.

func TestPlatformSupportLinuxIsImplemented(t *testing.T) {
	p := PlatformFor("linux")
	if !p.Implemented {
		t.Fatalf("linux must be implemented: %+v", p)
	}
	if p.Reason != "" {
		t.Fatalf("an implemented platform carries no skip reason: %q", p.Reason)
	}
	if got := p.Refusal(false); got != "" {
		t.Fatalf("linux must not refuse to serve: %q", got)
	}
}

func TestPlatformSupportDarwinNamesSeatbeltAndRefuses(t *testing.T) {
	p := PlatformFor("darwin")
	if p.Implemented {
		t.Fatal("darwin has no jail: nothing in this tree has ever run on it")
	}
	// The reason has to say what is missing, not merely that something
	// is: a bare "unsupported" would be indistinguishable from a kernel
	// that failed a probe.
	for _, want := range []string{"Seatbelt", "WP-H phase 2", "network filter"} {
		if !strings.Contains(p.Reason, want) {
			t.Fatalf("darwin reason %q must mention %q", p.Reason, want)
		}
	}
	// It is a skip reason, so it must read as one in the report, where it
	// is emitted with a "skip:" prefix.
	if !strings.HasPrefix(p.Reason, "jail: ") {
		t.Fatalf("reason %q must be prefixed for the skip: vocabulary", p.Reason)
	}
	refusal := p.Refusal(false)
	if refusal == "" {
		t.Fatal("darwin must refuse to serve by default")
	}
	if !strings.Contains(refusal, AllowUnenforcedFlag) {
		t.Fatalf("the refusal %q must name the opt-out", refusal)
	}
	if got := p.Refusal(true); got != "" {
		t.Fatalf("an explicit opt-in must be honoured: %q", got)
	}
}

func TestPlatformSupportWindowsIsAlsoUnbuilt(t *testing.T) {
	p := PlatformFor("windows")
	if p.Implemented {
		t.Fatal("windows has no jail")
	}
	if !strings.Contains(p.Reason, "WP-H phase 3") {
		t.Fatalf("windows reason %q must name its phase", p.Reason)
	}
}

func TestPlatformSupportUnknownOSFailsClosed(t *testing.T) {
	p := PlatformFor("plan9")
	if p.Implemented {
		t.Fatal("an unrecognized OS must not be treated as implemented")
	}
	if !strings.Contains(p.Reason, "plan9") {
		t.Fatalf("reason %q must name the OS it is refusing", p.Reason)
	}
	if p.Refusal(false) == "" {
		t.Fatal("an unrecognized OS must refuse to serve")
	}
}

// --- how the absence reaches the wire ------------------------------------

func TestFeaturesListFlagsAnUnsupportedPlatform(t *testing.T) {
	f := Features{Platform: PlatformFor("darwin")}
	list := strings.Join(f.List(), ",")
	if !strings.Contains(list, PlatformUnsupportedFeature) {
		t.Fatalf("hello.features %q must carry %q", list, PlatformUnsupportedFeature)
	}
	if !f.Degraded() {
		t.Fatal("a build with no jail is degraded whatever else it found")
	}
}

func TestFeaturesListSaysNothingExtraOnLinux(t *testing.T) {
	f := Features{Platform: PlatformFor("linux"), BwrapPath: "/usr/bin/bwrap"}
	list := strings.Join(f.List(), ",")
	if strings.Contains(list, PlatformUnsupportedFeature) {
		t.Fatalf("a supported platform must not flag itself: %q", list)
	}
	if f.Degraded() {
		t.Fatal("bwrap present on a supported platform is not degraded")
	}
}

func TestEnforcementEntriesLeadWithTheUnsupportedPlatform(t *testing.T) {
	feat := Features{Platform: PlatformFor("darwin")}
	rep := Report{Applied: []string{"rlimit-cpu"}, Skipped: []string{"landlock: nope"}}
	got := enforcementEntries(feat, false, rep)
	if len(got) == 0 || !strings.HasPrefix(got[0], "skip:jail: ") {
		t.Fatalf("the platform skip must lead the summary: %v", got)
	}
	if !strings.Contains(got[0], "Seatbelt") {
		t.Fatalf("the leading entry must name what is missing: %v", got)
	}
	// Nothing about the platform may turn a skip into an applied entry.
	for _, e := range got {
		if e == "seatbelt" || e == "sandbox-exec" {
			t.Fatalf("no Seatbelt layer exists to report: %v", got)
		}
	}
}

func TestEnforcementEntriesUnchangedOnASupportedPlatform(t *testing.T) {
	feat := Features{Platform: PlatformFor("linux"), BwrapPath: "/usr/bin/bwrap"}
	rep := Report{Applied: []string{"rlimit-cpu", "seccomp-net"}, Skipped: []string{"landlock: nope"}}
	got := enforcementEntries(feat, true, rep)
	want := []string{"bwrap", "cgroup-v2", "rlimit-cpu", "seccomp-net", "skip:landlock: nope"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("supported-platform summary changed:\ngot  %v\nwant %v", got, want)
	}
}
