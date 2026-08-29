package jail

import (
	"strings"
	"testing"
)

// PlatformFor is pure so every build can pin all three backend decisions.

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

func TestPlatformSupportDarwinIsImplemented(t *testing.T) {
	p := PlatformFor("darwin")
	if !p.Implemented {
		t.Fatalf("darwin must have the WP-H phase 2 backend: %+v", p)
	}
	if p.Reason != "" {
		t.Fatalf("an implemented platform carries no skip reason: %q", p.Reason)
	}
	if refusal := p.Refusal(false); refusal != "" {
		t.Fatalf("darwin must not require the unenforced opt-out: %q", refusal)
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
	f := Features{Platform: PlatformFor("windows")}
	list := strings.Join(f.List(), ",")
	if !strings.Contains(list, PlatformUnsupportedFeature) {
		t.Fatalf("hello.features %q must carry %q", list, PlatformUnsupportedFeature)
	}
	if !f.Degraded() {
		t.Fatal("a build with no jail is degraded whatever else it found")
	}
}

func TestFeaturesListReportsSeatbeltOnDarwin(t *testing.T) {
	f := Features{Platform: PlatformFor("darwin"), SeatbeltPath: SeatbeltExecutable}
	list := strings.Join(f.List(), ",")
	if !strings.Contains(list, "seatbelt") || strings.Contains(list, "degraded") {
		t.Fatalf("a usable Darwin backend must advertise Seatbelt without degradation: %q", list)
	}
	if f.Degraded() {
		t.Fatal("the pinned Seatbelt executable is an available Darwin confinement backend")
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
	feat := Features{Platform: PlatformFor("windows")}
	rep := Report{Applied: []string{"rlimit-cpu"}, Skipped: []string{"landlock: nope"}}
	got := enforcementEntries(feat, cgroupOutcome{}, MountReport{}, nil,
		stage2Report{rep: rep, received: true})
	if len(got) == 0 || !strings.HasPrefix(got[0], "skip:jail: ") {
		t.Fatalf("the platform skip must lead the summary: %v", got)
	}
	if !strings.Contains(got[0], "Windows") {
		t.Fatalf("the leading entry must name what is missing: %v", got)
	}
	// Nothing about the platform may turn a skip into an applied entry.
	for _, e := range got {
		if e == "seatbelt" || e == "sandbox-exec" {
			t.Fatalf("no Seatbelt layer exists to report: %v", got)
		}
	}
}

func TestEnforcementEntriesPublishWitnessedSeatbeltPlan(t *testing.T) {
	feat := Features{Platform: PlatformFor("darwin"), SeatbeltPath: SeatbeltExecutable}
	seatbelt := []string{"seatbelt", "seatbelt-fs:rw=1,mask=1,scratch=private-dir,plan=abcd", "seatbelt-net"}
	got := enforcementEntries(feat, cgroupOutcome{}, MountReport{}, seatbelt,
		stage2Report{rep: Report{Applied: []string{"rlimit-cpu"}}, received: true})
	if strings.Join(got, "|") != strings.Join(append(seatbelt, "rlimit-cpu"), "|") {
		t.Fatalf("witnessed Seatbelt plan was not reported exactly: %v", got)
	}
}

func TestEnforcementEntriesRefuseUnwitnessedSeatbeltPlan(t *testing.T) {
	feat := Features{Platform: PlatformFor("darwin"), SeatbeltPath: SeatbeltExecutable}
	got := enforcementEntries(feat, cgroupOutcome{}, MountReport{}, []string{"seatbelt"}, stage2Report{})
	joined := strings.Join(got, "|")
	if !strings.Contains(joined, "skip:"+SeatbeltUnwitnessedSkip) || strings.Contains(joined, "|seatbelt|") {
		t.Fatalf("unwitnessed Seatbelt profile must be skipped, never claimed: %v", got)
	}
}

func TestEnforcementEntriesUnchangedOnASupportedPlatform(t *testing.T) {
	feat := Features{Platform: PlatformFor("linux"), BwrapPath: "/usr/bin/bwrap"}
	rep := Report{Applied: []string{"rlimit-cpu", "seccomp-net"}, Skipped: []string{"landlock: nope"}}
	mounts := MountReport{Applied: "mounts:ro=0,rw=1,mask=0,scratch=tmpfs,plan=0011223344556677"}
	got := enforcementEntries(feat,
		cgroupOutcome{ceilings: CgroupCeilings{Mem: true}, attached: true},
		mounts, nil, stage2Report{rep: rep, received: true})
	want := []string{
		"bwrap", mounts.Applied, "cgroup-v2", "rlimit-cpu", "seccomp-net",
		"skip:landlock: nope",
	}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("supported-platform summary changed:\ngot  %v\nwant %v", got, want)
	}
}
