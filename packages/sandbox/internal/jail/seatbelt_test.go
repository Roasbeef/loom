package jail

import (
	"fmt"
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

// Darwin has no mount namespace, so an explicit mount is an allow rule
// over the subpath. What matters is where it lands: before the
// subtractive rules, so a protected path stays unreachable whatever the
// mount list says. That is the opposite of the bwrap argv, where an
// explicit mount is emitted after the masks and wins.
func TestSeatbeltPlanEmitsMountsBeforeTheDenies(t *testing.T) {
	pol := policy.Policy{
		WritableRoots: []string{"/work"},
		Protected:     []string{"/work/.env"},
		Network:       policy.Network{Mode: policy.NetworkOff},
		Scratch:       "tmpfs",
		Mounts: []policy.Mount{
			{Path: "/srv/cap", Access: policy.MountReadOnly, Required: true},
			{Path: "/srv/out", Access: policy.MountReadWrite, Required: true},
		},
	}
	plan := SeatbeltPlanFor(pol, "/private/tmp/scratch")
	if plan.BindRO != 1 || plan.BindRW != 1 {
		t.Fatalf("mount counts = ro %d, rw %d, want 1 and 1", plan.BindRO, plan.BindRW)
	}

	var roKey, rwKey string
	for _, definition := range plan.Definitions {
		switch {
		case strings.HasSuffix(definition, "=/srv/cap"):
			roKey = strings.SplitN(definition, "=", 2)[0]
		case strings.HasSuffix(definition, "=/srv/out"):
			rwKey = strings.SplitN(definition, "=", 2)[0]
		}
	}
	if roKey == "" || rwKey == "" {
		t.Fatalf("both mounts must be parameters, got %v", plan.Definitions)
	}

	read := fmt.Sprintf("(allow file-read* (subpath (param %q)))", roKey)
	write := fmt.Sprintf("(allow file-write* (subpath (param %q)))", rwKey)
	if !strings.Contains(plan.Profile, read) {
		t.Fatalf("profile lacks the read-only mount rule:\n%s", plan.Profile)
	}
	if !strings.Contains(plan.Profile, write) {
		t.Fatalf("profile lacks the read-write mount rule:\n%s", plan.Profile)
	}
	// A read-only mount gets no write rule of its own.
	if strings.Contains(plan.Profile,
		fmt.Sprintf("(allow file-write* (subpath (param %q)))", roKey)) {
		t.Fatalf("a read-only mount must not grant writes:\n%s", plan.Profile)
	}

	deny := strings.Index(plan.Profile, "(deny file-read* (literal")
	if deny < 0 {
		t.Fatalf("no protected deny rule in the profile:\n%s", plan.Profile)
	}
	if strings.Index(plan.Profile, write) > deny {
		t.Fatalf("a mount rule follows the denies and can reopen a "+
			"protected path:\n%s", plan.Profile)
	}
}
