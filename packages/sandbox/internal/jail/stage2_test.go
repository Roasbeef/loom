package jail

import (
	"reflect"
	"testing"

	"github.com/roasbeef/loom/sandbox/internal/llock"
	"github.com/roasbeef/loom/sandbox/internal/policy"
	"golang.org/x/sys/unix"
)

// A tmpfs scratch must not become a write grant over the host's /tmp in
// degraded mode, where nothing is mounted there and the path is the
// account's shared temp directory. The single-file null sink grant is
// independent.
func TestLandlockViewGrantsNoDirectoryForATmpfsScratch(t *testing.T) {
	pol := policy.Policy{
		WritableRoots: []string{"/work"},
		ReadableRoots: []string{"/opt"},
		Scratch:       "tmpfs",
	}
	got := landlockView(pol, false)
	want := llock.PolicyView{
		WritableRoots: []string{"/work"},
		ReadableRoots: []string{"/opt"},
		WritableFiles: []string{"/dev/null"},
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
	got := landlockView(pol, false)
	want := llock.PolicyView{
		WritableRoots: []string{"/work"},
		WritableFiles: []string{"/dev/null"},
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
func TestLandlockViewFeedsRulesWithNoDegradedSyntheticGrant(t *testing.T) {
	pol := policy.Policy{Scratch: "tmpfs"}
	rules := llock.Rules(landlockView(pol, false))
	for _, r := range rules {
		if r.Access == llock.ReadWrite && !r.File {
			t.Fatalf("tmpfs scratch produced a directory write grant: %+v", rules)
		}
	}
}

// Under bwrap the same policy is the other way round. Landlock grants
// read on "/" and write only where a rule says so, so a tmpfs scratch
// with no rule of its own is a scratch directory the payload cannot
// write to: measured as `touch /tmp/probe` failing inside a jail
// reporting landlock:abi=1. The mount is real here, and only the helper
// that built it can say so.
func TestLandlockViewGrantsTheMountedTmpfsScratch(t *testing.T) {
	pol := policy.Policy{WritableRoots: []string{"/work"}, Scratch: "tmpfs"}
	got := landlockView(pol, true)
	want := llock.PolicyView{
		WritableRoots: []string{"/work"},
		WritableFiles: []string{"/dev/null"},
		ScratchPath:   ScratchMount,
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("landlockView mismatch:\n got  %+v\nwant %+v", got, want)
	}
}

// The null sink is writable without widening the rest of /dev.
func TestLandlockViewGrantsOnlyTheNullDeviceFile(t *testing.T) {
	pol := policy.Policy{WritableRoots: []string{"/work"}, Scratch: "tmpfs"}
	got := landlockView(pol, false)
	want := llock.PolicyView{
		WritableRoots: []string{"/work"},
		WritableFiles: []string{"/dev/null"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("landlockView mismatch:\n got  %+v\nwant %+v", got, want)
	}
}

func TestTargetSoftNofileRaisesLowDefaultWithoutExceedingHardCap(t *testing.T) {
	// Darwin default: soft=256, hard=RLIM_INFINITY -> soft=10240, hard=RLIM_INFINITY.
	next, changed := targetSoftNofile(unix.Rlimit{Cur: 256, Max: unix.RLIM_INFINITY})
	if !changed || next.Cur != defaultSoftNofile || next.Max != unix.RLIM_INFINITY {
		t.Fatalf("unexpected infinite-max raise: %+v (changed=%v)", next, changed)
	}

	// Finite hard ceiling below 10240 clamps the raise to Max.
	next, changed = targetSoftNofile(unix.Rlimit{Cur: 256, Max: 4096})
	if !changed || next.Cur != 4096 || next.Max != 4096 {
		t.Fatalf("unexpected bounded-max raise: %+v (changed=%v)", next, changed)
	}

	// Higher soft ceilings (e.g. Linux 65536) are never lowered.
	next, changed = targetSoftNofile(unix.Rlimit{Cur: 65536, Max: 65536})
	if changed || next.Cur != 65536 {
		t.Fatalf("higher soft limit should stay untouched: %+v (changed=%v)", next, changed)
	}
}
