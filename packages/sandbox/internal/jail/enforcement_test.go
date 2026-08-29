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
	cg := cgroupOutcome{
		ceilings: CgroupCeilings{Mem: true, Pids: true},
		reason:   feat.CgroupReason,
	}

	got := enforcementEntries(feat, cg, MountReport{}, nil,
		stage2Report{rep: rep, received: true})

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
	got := enforcementEntries(feat, cgroupOutcome{}, MountReport{}, nil,
		stage2Report{rep: Report{Applied: []string{"rlimit-cpu"}}, received: true})
	for _, e := range got {
		if strings.HasPrefix(e, "skip:") {
			t.Fatalf("nothing was demanded, so nothing was skipped: %v", got)
		}
	}
}

func TestEnforcementEntriesReportAnAttachedCgroupAsApplied(t *testing.T) {
	feat := Features{Platform: PlatformFor("linux"), CgroupDir: "/sys/fs/cgroup/loom"}
	cg := cgroupOutcome{ceilings: CgroupCeilings{Pids: true}, attached: true}
	got := enforcementEntries(feat, cg, MountReport{}, nil,
		stage2Report{rep: Report{Applied: []string{"no-new-privs"}}, received: true})
	if strings.Join(got, "|") != "cgroup-v2|no-new-privs" {
		t.Fatalf("an applied cgroup is one plain entry, got %v", got)
	}
}

// A skip must name what was actually dropped. A policy that asked only
// for `pids` was told "memory.max/pids.max were NOT applied", which
// names a ceiling it never wanted — conservative, still false, and the
// kind of inaccuracy that trains readers to stop reading skips.
func TestCgroupSkipNamesOnlyTheCeilingsThatWereAskedFor(t *testing.T) {
	cases := []struct {
		name     string
		ceilings CgroupCeilings
		want     string
		absent   string
	}{
		{"pids only", CgroupCeilings{Pids: true}, "pids.max", "memory.max"},
		{"memory only", CgroupCeilings{Mem: true}, "memory.max", "pids.max"},
		{"both", CgroupCeilings{Mem: true, Pids: true}, "memory.max and pids.max", ""},
	}
	for _, c := range cases {
		got := CgroupSkip("no delegated base", c.ceilings)
		if !strings.Contains(got, c.want) {
			t.Fatalf("%s: %q does not name %q", c.name, got, c.want)
		}
		if c.absent != "" && strings.Contains(got, c.absent) {
			t.Fatalf("%s: %q names a ceiling the policy never asked for (%q)",
				c.name, got, c.absent)
		}
	}
}

// #54's meta-finding: stage 2 died before writing fd 4, so the entire
// inner report is missing. The old list was `[bwrap]` — no `skip:`
// anywhere, and therefore a satisfied FullEnforcement demand. Silence
// about a layer must be a skip, and the mount/namespace layer must not
// be claimed when nothing witnessed it being built.
func TestEnforcementEntriesSkipWhenStage2NeverReported(t *testing.T) {
	feat := Features{Platform: PlatformFor("linux"), BwrapPath: "/usr/bin/bwrap"}
	got := enforcementEntries(feat, cgroupOutcome{}, MountReport{}, nil, stage2Report{})

	var skips []string
	for _, e := range got {
		if strings.HasPrefix(e, "skip:") {
			skips = append(skips, e)
		}
		if e == "bwrap" {
			t.Fatalf("nothing witnessed bwrap building a jail; it may not be "+
				"claimed as applied: %v", got)
		}
	}
	if len(skips) == 0 {
		t.Fatalf("a dead stage 2 produced no skip entry, so its silence "+
			"satisfies a full-enforcement demand: %v", got)
	}
	if !strings.Contains(strings.Join(skips, "|"), Stage2SkipPrefix) {
		t.Fatalf("the skip must name the stage-2 layer: %v", skips)
	}
}

// The witnessed case: stage 2 spoke, so bwrap demonstrably built a jail
// and exec'd inside it, and the mount plan's audit is reportable.
func TestEnforcementEntriesReportTheMountPlanWhenStage2Spoke(t *testing.T) {
	feat := Features{Platform: PlatformFor("linux"), BwrapPath: "/usr/bin/bwrap"}
	s2 := stage2Report{rep: Report{Applied: []string{"no-new-privs"}}, received: true}
	mounts := MountReport{Applied: "mounts:ro=1,rw=1,mask=1,scratch=tmpfs,plan=abcd"}
	got := enforcementEntries(feat, cgroupOutcome{}, mounts, nil, s2)
	joined := strings.Join(got, "|")
	if !strings.Contains(joined, "bwrap") || !strings.Contains(joined, mounts.Applied) {
		t.Fatalf("a witnessed jail reports both bwrap and its mount plan: %v", got)
	}
	for _, e := range got {
		if strings.HasPrefix(e, "skip:") {
			t.Fatalf("nothing was skipped: %v", got)
		}
	}
}
