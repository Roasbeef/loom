package jail

import (
	"strings"
	"testing"
)

// The contract FullEnforcement rests on: every layer the policy asked
// for and the helper did not apply appears as a `skip:` entry. Omitting
// the entry does not make the ceiling best-effort, it makes it invisible
// — a policy demanding a memory or process ceiling would pass a strict
// enforcement demand with neither ceiling in place.
func TestEnforcementEntriesSkipUnappliedCgroupCeilings(t *testing.T) {
	feat := Features{
		Platform:     PlatformFor("linux"),
		BwrapPath:    "/usr/bin/bwrap",
		CgroupReason: "no cgroup v2 unified hierarchy at /sys/fs/cgroup",
	}
	rep := Report{Applied: []string{"rlimit-cpu"}}
	cg := cgroupOutcome{wanted: true, reason: feat.CgroupReason}

	got := enforcementEntries(feat, cg, rep)

	var skips []string
	for _, e := range got {
		if strings.HasPrefix(e, "skip:") {
			skips = append(skips, e)
		}
	}
	if len(skips) == 0 {
		t.Fatalf("a demanded-but-unapplied cgroup ceiling produced no skip "+
			"entry, so a full-enforcement demand accepts it silently: %v", got)
	}
	if !strings.Contains(skips[0], CgroupSkipPrefix) {
		t.Fatalf("the skip must name the cgroup layer: %v", skips)
	}
	if !strings.Contains(skips[0], feat.CgroupReason) {
		t.Fatalf("the skip must carry the reason: %v", skips)
	}
	for _, e := range got {
		if e == "cgroup-v2" {
			t.Fatalf("no cgroup was attached; nothing may claim one: %v", got)
		}
	}
}

// The other half of the same rule: a policy that asked for no ceiling
// cgroups enforce has nothing unenforced, so it must not be told that a
// layer it never wanted was skipped. A skip that is not a real reduction
// trains readers to ignore skips.
func TestEnforcementEntriesStaySilentWhenNoCeilingWasAsked(t *testing.T) {
	feat := Features{
		Platform:     PlatformFor("linux"),
		BwrapPath:    "/usr/bin/bwrap",
		CgroupReason: "no cgroup v2 unified hierarchy at /sys/fs/cgroup",
	}
	got := enforcementEntries(feat, cgroupOutcome{}, Report{Applied: []string{"rlimit-cpu"}})
	for _, e := range got {
		if strings.HasPrefix(e, "skip:") {
			t.Fatalf("nothing was demanded, so nothing was skipped: %v", got)
		}
	}
}

func TestEnforcementEntriesReportAnAttachedCgroupAsApplied(t *testing.T) {
	feat := Features{Platform: PlatformFor("linux"), CgroupDir: "/sys/fs/cgroup/loom"}
	cg := cgroupOutcome{wanted: true, attached: true}
	got := enforcementEntries(feat, cg, Report{})
	if strings.Join(got, "|") != "cgroup-v2" {
		t.Fatalf("an applied cgroup is one plain entry, got %v", got)
	}
}
