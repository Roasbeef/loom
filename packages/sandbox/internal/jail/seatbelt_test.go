package jail

import (
	"strings"
	"testing"

	"github.com/roasbeef/loom/sandbox/internal/policy"
)

func TestSeatbeltPlanIsDenyDefaultAndParameterized(t *testing.T) {
	pol := policy.Policy{
		WritableRoots: []string{"/work/space with quote \" and newline\n"},
		Protected:     []string{"/work/.git"},
		Network:       policy.Network{Mode: policy.NetworkOff},
		Scratch:       "tmpfs",
	}
	plan := SeatbeltPlanFor(pol, "/private/var/tmp/loom scratch")
	if !strings.Contains(plan.Profile, "(deny default)") {
		t.Fatalf("profile is not deny-default:\n%s", plan.Profile)
	}
	for _, raw := range []string{pol.WritableRoots[0], pol.Protected[0]} {
		if strings.Contains(plan.Profile, raw) {
			t.Fatalf("model-influenced path was interpolated into SBPL: %q", raw)
		}
	}
	if !strings.Contains(strings.Join(plan.Definitions, "\n"), "WRITABLE_ROOT_") ||
		!strings.Contains(strings.Join(plan.Definitions, "\n"), "PROTECTED_PATH_") {
		t.Fatalf("profile paths were not passed as definitions: %v", plan.Definitions)
	}
	if strings.Contains(plan.Profile, "network-outbound)\n") {
		t.Fatalf("network-off profile contains an unrestricted outbound grant:\n%s", plan.Profile)
	}
	if !strings.Contains(plan.Profile, "remote unix-socket") {
		t.Fatalf("network-off must retain filesystem-confined Unix sockets:\n%s", plan.Profile)
	}
	if plan.Scratch != "private-dir" {
		t.Fatalf("tmpfs must be reported as its macOS private-directory mapping: %+v", plan)
	}
}

func TestSeatbeltPlanEmitsSubtractiveRulesLast(t *testing.T) {
	pol := policy.Policy{
		WritableRoots: []string{"/work"},
		Protected:     []string{"/work/project/.git"},
		Network:       policy.Network{Mode: policy.NetworkFull},
		Scratch:       "/scratch",
	}
	plan := SeatbeltPlanFor(pol, "")
	lastAllow := strings.LastIndex(plan.Profile, "(allow ")
	firstDenyAfterBase := strings.Index(plan.Profile[len(seatbeltBaseProfile):], "(deny ")
	if firstDenyAfterBase < 0 {
		t.Fatalf("profile has no subtractive protected rules:\n%s", plan.Profile)
	}
	firstDenyAfterBase += len(seatbeltBaseProfile)
	if lastAllow > firstDenyAfterBase {
		t.Fatalf("an allow follows a protected deny:\n%s", plan.Profile)
	}
	if !strings.Contains(plan.Profile, "file-write-unlink") {
		t.Fatalf("profile does not pin protected ancestors against rename:\n%s", plan.Profile)
	}
	if !strings.Contains(plan.Profile, "Full network access") {
		t.Fatalf("network-full profile lacks its explicit grant:\n%s", plan.Profile)
	}
}

func TestSeatbeltPlanIsDeterministic(t *testing.T) {
	a := policy.Policy{
		WritableRoots: []string{"/b", "/a", "/b"},
		Protected:     []string{"/b/z", "/b/z"},
		Network:       policy.Network{Mode: policy.NetworkOff},
		Scratch:       "/scratch",
	}
	b := a
	b.WritableRoots = []string{"/a", "/b"}
	b.Protected = []string{"/b/z"}
	first := SeatbeltPlanFor(a, "")
	second := SeatbeltPlanFor(b, "")
	if first.Profile != second.Profile || first.Digest != second.Digest ||
		strings.Join(first.Definitions, "\n") != strings.Join(second.Definitions, "\n") {
		t.Fatalf("equivalent policies generated different plans:\n%+v\n%+v", first, second)
	}
}
