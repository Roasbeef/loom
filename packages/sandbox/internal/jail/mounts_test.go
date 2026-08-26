package jail

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/roasbeef/loom/sandbox/internal/policy"
)

func protectedPolicy() (policy.Policy, map[string]PathKind) {
	pol := policy.Policy{
		WritableRoots: []string{"/work"},
		ReadableRoots: []string{"/usr"},
		Protected:     []string{"/work/.env"},
		Network:       policy.Network{Mode: policy.NetworkOff},
		Scratch:       "tmpfs",
	}
	return pol, map[string]PathKind{"/work/.env": PathFile}
}

// The mount layer must contribute report entries at all: without them
// the whole class of "the policy's paths were not narrowed as asked" is
// invisible, and `bwrap` alone only ever meant "bubblewrap ran".
func TestAuditMountsReportsWhatTheResolvedPlanAchieved(t *testing.T) {
	pol, kinds := protectedPolicy()
	got := AuditMounts(pol, MountPlan(pol, kinds))
	if len(got.Skipped) != 0 {
		t.Fatalf("a well-ordered plan narrows every path; skips: %v", got.Skipped)
	}
	for _, want := range []string{"mounts:", "ro=1", "rw=1", "mask=1", "plan="} {
		if !strings.Contains(got.Applied, want) {
			t.Fatalf("applied entry %q lacks %q", got.Applied, want)
		}
	}
}

// The finding this exists to catch: a mask that a later bind of an
// ancestor puts back. The counts are of *effective* outcomes replayed
// from the ordered plan, so the defeated mask drops out of them and the
// path is named in a skip.
func TestAuditMountsCatchesADefeatedMask(t *testing.T) {
	pol, kinds := protectedPolicy()
	// A plan whose protected mask is undone by a later writable bind of
	// an ancestor — exactly the ordering defect of #51. MountPlan will
	// not produce this today; the audit exists so that if it ever did,
	// or if bwrap's own precedence changed under it, the report would
	// say so instead of staying silent.
	defeated := append(MountPlan(pol, kinds), writableOp("/work"))
	got := AuditMounts(pol, defeated)
	if len(got.Skipped) == 0 {
		t.Fatalf("a defeated mask produced no skip entry: %+v", got)
	}
	if !strings.Contains(got.Skipped[0], "/work/.env") {
		t.Fatalf("the skip must name the re-exposed path: %v", got.Skipped)
	}
	if !strings.Contains(got.Applied, "mask=0") {
		t.Fatalf("the applied counts must not claim a mask that was undone: %q", got.Applied)
	}
}

// A readable root that a later writable bind makes writable is the same
// class of defect and must be caught the same way.
func TestAuditMountsCatchesAReadableRootMadeWritable(t *testing.T) {
	pol, kinds := protectedPolicy()
	defeated := append(MountPlan(pol, kinds), writableOp("/usr"))
	got := AuditMounts(pol, defeated)
	if len(got.Skipped) == 0 {
		t.Fatalf("a readable root turned writable produced no skip: %+v", got)
	}
	if !strings.Contains(strings.Join(got.Skipped, "|"), "/usr") {
		t.Fatalf("the skip must name the widened path: %v", got.Skipped)
	}
}

// A path a policy names in *both* lists is writable because the policy
// asked for it: the lists are grants and their union is the answer. The
// audit must not report the policy's own grant as a defeated narrowing —
// a skip that is not a real reduction trains readers to ignore skips.
func TestAuditMountsAcceptAReadableRootThePolicyAlsoMakesWritable(t *testing.T) {
	pol := policy.Policy{
		WritableRoots: []string{"/work"},
		ReadableRoots: []string{"/work"},
		Network:       policy.Network{Mode: policy.NetworkOff},
		Scratch:       "tmpfs",
	}
	got := AuditMounts(pol, MountPlan(pol, nil))
	if len(got.Skipped) != 0 {
		t.Fatalf("the policy granted the write itself; skips: %v", got.Skipped)
	}
	if !strings.Contains(got.Applied, "ro=1") {
		t.Fatalf("the readable root was satisfied: %q", got.Applied)
	}
}

// statKinds classifies the *target*, not the link. The mask forms differ
// by inode type, and masking a directory with the file form is a bind of
// a character device over a directory: ENOTDIR, and no jail at all. That
// fails closed rather than open, but a jail that will not start is still
// a jail nobody gets. Callers resolve before they classify, so this is
// belt to that brace — and the brace is one edit away from being undone.
func TestStatKindsClassifiesTheSymlinksTarget(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "real")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	got := statKinds([]string{link})
	if got[link] != PathDir {
		t.Fatalf("statKinds(%q) = %v, want PathDir (the target is a directory)",
			link, got[link])
	}
}

// The other half: resolveProtected puts the mask on the inode rather
// than the name, because bwrap resolves a mount destination inside the
// pivot root it is building, where the link's target does not exist yet.
func TestResolveProtectedRewritesASymlinkToItsTarget(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "real")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	missing := filepath.Join(dir, "not-created-yet")
	got := resolveProtected([]string{link, missing})
	resolvedTarget, err := filepath.EvalSymlinks(target)
	if err != nil {
		t.Fatal(err)
	}
	if got[0] != resolvedTarget {
		t.Fatalf("resolveProtected[0] = %q, want %q", got[0], resolvedTarget)
	}
	// A path that does not exist keeps its own name: masking the name is
	// exactly the point there — a protected path that does not exist yet
	// must stay uncreatable.
	if got[1] != missing {
		t.Fatalf("resolveProtected[1] = %q, want %q", got[1], missing)
	}
}
