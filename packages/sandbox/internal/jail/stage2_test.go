package jail

import (
	"reflect"
	"testing"

	"github.com/roasbeef/loom/sandbox/internal/llock"
	"github.com/roasbeef/loom/sandbox/internal/policy"
)

// #59: a tmpfs scratch is a directory only bwrap can create for the
// jail's own exclusive use, so Landlock grants it nothing — see
// landlockView's doc and llock.PolicyView's ScratchPath doc, the
// contract stage 2 used to contradict.
func TestLandlockViewGrantsNothingForATmpfsScratch(t *testing.T) {
	pol := policy.Policy{
		WritableRoots: []string{"/work"},
		ReadableRoots: []string{"/opt"},
		Scratch:       "tmpfs",
	}
	got := landlockView(pol)
	want := llock.PolicyView{
		WritableRoots: []string{"/work"},
		ReadableRoots: []string{"/opt"},
		ScratchPath:   "",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("landlockView mismatch:\n got  %+v\nwant %+v", got, want)
	}
}

// A host-path scratch is real storage bwrap merely binds in, so it is
// the one case where Landlock is doing load-bearing work and keeps its
// explicit grant.
func TestLandlockViewGrantsAHostPathScratch(t *testing.T) {
	pol := policy.Policy{
		WritableRoots: []string{"/work"},
		Scratch:       "/var/scratch",
	}
	got := landlockView(pol)
	want := llock.PolicyView{
		WritableRoots: []string{"/work"},
		ScratchPath:   "/var/scratch",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("landlockView mismatch:\n got  %+v\nwant %+v", got, want)
	}
}

// The historical bug this guards: granting RWDirs at ScratchMount for a
// tmpfs scratch regardless of whether bwrap actually built one. Asserted
// directly against llock.Rules, the same way TestRules pins the grant
// set as pure data — so a regression here fails at the layer that
// decides what gets enforced, not only at the one that renders it.
func TestLandlockViewFeedsRulesWithNoScratchGrant(t *testing.T) {
	pol := policy.Policy{Scratch: "tmpfs"}
	rules := llock.Rules(landlockView(pol))
	for _, r := range rules {
		if r.Access == llock.ReadWrite {
			t.Fatalf("a tmpfs scratch produced a Landlock write grant: %+v", rules)
		}
	}
}
