package jail

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/roasbeef/loom/sandbox/internal/policy"
)

func basePol() policy.Policy {
	return policy.Policy{
		WritableRoots: []string{"/work"},
		ReadableRoots: []string{"/opt/tools"},
		Protected:     []string{"/work/.git", "/work/.env"},
		Network:       policy.Network{Mode: policy.NetworkOff},
		Limits:        policy.Limits{OutputBytes: 1 << 20},
		EnvAllow:      []string{"PATH"},
		Scratch:       "tmpfs",
	}
}

// TestBwrapArgsGolden pins the exact argv for a representative policy.
// Any change here is a change to the jail's shape and must be reviewed
// as such — that is the point of a golden test at a security boundary.
//
// Read top to bottom, the argv is the precedence model: every grant,
// then every mask, each phase parent-before-child.
//
//	--ro-bind-try /usr … etc        the base view: a tolerant read-only
//	                                bind of each system root. The root
//	                                itself renders nothing, because
//	                                bwrap's new root is already an empty
//	                                tmpfs
//	--ro-bind-try /opt/tools …      a readable root nested inside it.
//	                                "-try": readable_roots may legitimately
//	                                be absent on a given host (#60), unlike
//	                                the base view above
//	--tmpfs /tmp                    the scratch area. A *grant*: it is
//	                                what provides writable scratch, so
//	                                it belongs in the grant phase.
//	                                Emitted last, which is where #51
//	                                found it, it replaced any protected
//	                                mask underneath it
//	--bind /work /work              the writable root. After /tmp only
//	                                because "/tmp" < "/work"; the two
//	                                do not overlap, so their relative
//	                                order means nothing
//	--dev /dev                      the masks begin. Nothing after this
//	--proc /proc                    point may widen anything
//	--ro-bind /dev/null /work/.env  a protected file, shadowed by an
//	                                empty device rather than bound onto
//	                                itself, so it is unreadable as well
//	                                as unwritable (#55)
//	--tmpfs /work/.git …            a protected directory: empty tmpfs,
//	                                remounted read-only. After the bind
//	                                of /work that contains it, which is
//	                                what the mask phase exists for
//
// The last two arguments are not part of the plan. `--remount-ro /`
// turns the root tmpfs read-only once every mountpoint under it has been
// created, so a region no grant covers is not a writable, unbounded
// directory inside the jail. bwrap remounts the one mount rather than
// the tree beneath it, so the writable roots and the scratch tmpfs above
// keep their access.
//
// Two differences from the argv this pinned before the precedence model
// landed, both deliberate. `--tmpfs /tmp` moved from last into the
// grant phase, because last is exactly where it could undo a mask. And
// `--dev` now precedes `--proc`, because one comparator orders the
// whole plan by path; the two paths do not overlap, so nothing about
// the resulting jail changes.
func TestBwrapArgsGolden(t *testing.T) {
	p := basePol()
	kinds := map[string]PathKind{
		"/work/.git": PathDir,
		"/work/.env": PathFile,
	}
	got := BwrapArgs(p, kinds, "")
	want := []string{
		"--die-with-parent",
		"--unshare-pid",
		"--unshare-ipc",
		"--unshare-uts",
		"--unshare-user-try",
		"--unshare-cgroup-try",
		"--unshare-net",
		"--ro-bind-try", "/bin", "/bin",
		"--ro-bind-try", "/etc", "/etc",
		"--ro-bind-try", "/lib", "/lib",
		"--ro-bind-try", "/lib32", "/lib32",
		"--ro-bind-try", "/lib64", "/lib64",
		"--ro-bind-try", "/nix/store", "/nix/store",
		"--ro-bind-try", "/opt", "/opt",
		"--ro-bind-try", "/opt/tools", "/opt/tools",
		"--ro-bind-try", "/run/current-system", "/run/current-system",
		"--ro-bind-try", "/sbin", "/sbin",
		"--tmpfs", "/tmp",
		"--ro-bind-try", "/usr", "/usr",
		"--ro-bind-try", "/var/lib", "/var/lib",
		"--bind", "/work", "/work",
		"--dev", "/dev",
		"--proc", "/proc",
		"--ro-bind", MaskSource, "/work/.env",
		"--tmpfs", "/work/.git", "--remount-ro", "/work/.git",
		"--remount-ro", "/",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("bwrap argv mismatch:\n got  %q\nwant %q", got, want)
	}
}

// A readable root of "/" is the ordinary case for a jailed build that
// needs a toolchain, and it is a bind of the ancestor of both /proc and
// /dev. If it is emitted after the two mask mounts it puts the host's
// procfs and the host's device tree back: a confinement gap (every host
// process readable from inside the jail) and a functional break (bwrap
// binds nodev, so no device node in the re-exposed /dev can be opened,
// and a jailed BEAM spins forever on /dev/null). So: every bind first,
// then the masks.
func TestBwrapArgsRootReadableDoesNotUnmaskProcOrDev(t *testing.T) {
	p := basePol()
	p.ReadableRoots = []string{"/"}
	p.Protected = nil
	got := BwrapArgs(p, nil, "")
	lastBindOfRoot, procAt, devAt := -1, -1, -1
	for i := 0; i+2 < len(got); i++ {
		// A readable root of "/" renders as the tolerant form, which is
		// what every entry of readable_roots gets; the base view's own
		// bind of the host is gone since protocol-change/020.
		if (got[i] == "--ro-bind" || got[i] == "--ro-bind-try" ||
			got[i] == "--bind") && got[i+1] == "/" && got[i+2] == "/" {
			lastBindOfRoot = i
		}
	}
	for i := 0; i+1 < len(got); i++ {
		switch {
		case got[i] == "--proc" && got[i+1] == "/proc":
			procAt = i
		case got[i] == "--dev" && got[i+1] == "/dev":
			devAt = i
		}
	}
	if lastBindOfRoot < 0 || procAt < 0 || devAt < 0 {
		t.Fatalf("argv missing a root bind, --proc or --dev: %q", got)
	}
	if procAt < lastBindOfRoot || devAt < lastBindOfRoot {
		t.Fatalf("--proc/--dev masked before the last bind of \"/\" and so undone by it: %q", got)
	}
}

func TestBwrapArgsNetworkFullKeepsNet(t *testing.T) {
	p := basePol()
	p.Network = policy.Network{Mode: policy.NetworkFull}
	for _, a := range BwrapArgs(p, nil, "") {
		if a == "--unshare-net" {
			t.Fatal("--unshare-net present under network full")
		}
	}
}

// Proxy mode has no enforcing sidecar in phase 1, so the jail must
// fail closed: network unshared exactly as under off, never silent
// unrestricted egress.
func TestBwrapArgsNetworkProxyUnsharesNet(t *testing.T) {
	p := basePol()
	p.Network = policy.Network{
		Mode:  policy.NetworkProxy,
		Allow: []string{"*.npmjs.org"},
		Proxy: "127.0.0.1:3128",
	}
	found := false
	for _, a := range BwrapArgs(p, nil, "") {
		if a == "--unshare-net" {
			found = true
		}
	}
	if !found {
		t.Fatal("--unshare-net missing under network proxy (must fail closed)")
	}
}

func TestBlocksDirectNetwork(t *testing.T) {
	cases := []struct {
		mode policy.NetworkMode
		want bool
	}{
		{policy.NetworkOff, true},
		{policy.NetworkProxy, true},
		{policy.NetworkFull, false},
	}
	for _, c := range cases {
		if got := BlocksDirectNetwork(c.mode); got != c.want {
			t.Fatalf("BlocksDirectNetwork(%q) = %v, want %v", c.mode, got, c.want)
		}
	}
}

func TestBwrapArgsNetworkOffUnsharesNet(t *testing.T) {
	found := false
	for _, a := range BwrapArgs(basePol(), nil, "") {
		if a == "--unshare-net" {
			found = true
		}
	}
	if !found {
		t.Fatal("--unshare-net missing under network off")
	}
}

// A protected path that does not exist yet is still masked so the jail
// cannot create it.
func TestBwrapArgsMissingProtectedMasked(t *testing.T) {
	p := basePol()
	p.Protected = []string{"/home/user/.ssh"}
	got := BwrapArgs(p, map[string]PathKind{"/home/user/.ssh": PathMissing}, "")
	if !containsSeq(got, []string{"--tmpfs", "/home/user/.ssh", "--remount-ro", "/home/user/.ssh"}) {
		t.Fatalf("missing protected path not tmpfs-masked: %q", got)
	}
}

// #60: a readable root may legitimately not exist on a given host (an
// optional toolchain path, a platform-specific system directory), so it
// is bound with the "-try" form rather than refusing the whole jail
// outright — matching the Optional flag llock.Rules already grants the
// same list at the Landlock layer (see the "which path lists tolerate a
// missing path" comment above readableRootOp).
func TestBwrapArgsReadableRootToleratesAbsence(t *testing.T) {
	p := basePol()
	p.ReadableRoots = []string{"/opt/maybe-missing"}
	got := BwrapArgs(p, nil, "")
	if !containsSeq(got, []string{"--ro-bind-try", "/opt/maybe-missing", "/opt/maybe-missing"}) {
		t.Fatalf("readable root not bound with --ro-bind-try: %q", got)
	}
	if containsSeq(got, []string{"--ro-bind", "/opt/maybe-missing", "/opt/maybe-missing"}) {
		t.Fatalf("readable root bound with the non-tolerant form: %q", got)
	}
}

// The minimal base view of protocol-change/020: an empty tmpfs at "/"
// and a tolerant read-only bind of each system root, and no bind of the
// host root at all. The tolerance is the point of the "-try" form here —
// a merged-usr distribution has no real /lib, a non-NixOS host has no
// /nix/store, and neither absence may refuse a jail.
func TestBwrapArgsMinimalBaseView(t *testing.T) {
	p := basePol()
	p.ReadableRoots = nil
	got := BwrapArgs(p, nil, "")

	// The root carries no argv of its own: bwrap's new root is already a
	// fresh tmpfs. What the plan says is that no grant replaced it, and
	// what the argv says is that it ends up read-only.
	if effective(MountPlan(p, nil, ""), "/").op.Class != ClassRootTmpfs {
		t.Fatalf("base view is not the jail's own root tmpfs: %q", got)
	}
	if !reflect.DeepEqual(got[len(got)-2:], []string{"--remount-ro", "/"}) {
		t.Fatalf("the root is left writable: %q", got)
	}
	if containsSeq(got, []string{"--ro-bind", "/", "/"}) {
		t.Fatalf("the whole host is still bound over the tmpfs: %q", got)
	}
	for _, root := range SystemRoots {
		if !containsSeq(got, []string{"--ro-bind-try", root, root}) {
			t.Fatalf("system root %s missing from the base view: %q", root, got)
		}
	}
	for _, absent := range []string{"/home", "/root", "/var/tmp", "/Users"} {
		for i := 0; i+2 < len(got); i++ {
			if got[i+1] == absent {
				t.Fatalf("%s is in the base view, which defeats the "+
					"narrowing: %q", absent, got)
			}
		}
	}
}

// A readable root of "/" is what a harness that has not yet dropped it
// still sends, and it must reproduce the pre-020 view rather than
// leaving an empty jail: the bind of the host outranks the tmpfs at the
// same region, and the audit reports the difference as base=host-view.
func TestBwrapArgsReadableRootOfSlashRestoresTheHostView(t *testing.T) {
	p := basePol()
	p.ReadableRoots = []string{"/"}
	got := BwrapArgs(p, nil, "")
	if !containsSeq(got, []string{"--ro-bind-try", "/", "/"}) {
		t.Fatalf("readable root of \"/\" did not bind the host: %q", got)
	}
	if containsSeq(got, []string{"--tmpfs", "/"}) {
		t.Fatalf("the root tmpfs survived alongside the host bind, so which "+
			"one applies depends on argv order: %q", got)
	}
	if BaseViewName(p.ReadableRoots) != "host-view" {
		t.Fatalf("the audit calls this base view %q", BaseViewName(p.ReadableRoots))
	}
}

// The helper binary is not a policy path: stage 2 is loom-exec
// re-executed inside the jail, and a minimal base view that does not
// carry it produces a jail that cannot start.
func TestBwrapArgsBindsTheHelperBinary(t *testing.T) {
	got := BwrapArgs(basePol(), nil, "/srv/loom/bin/loom-exec")
	want := []string{"--ro-bind-try", "/srv/loom/bin/loom-exec",
		"/srv/loom/bin/loom-exec"}
	if !containsSeq(got, want) {
		t.Fatalf("the helper binary is not in the jail's view: %q", got)
	}
}

// A helper the jail's view already carries gets no operation of its own.
// The grant is a read-only bind of the file onto itself, which is a
// mountpoint the payload cannot then replace, and a daemon running from
// the checkout it is working on has its helper inside the workspace: the
// unconditional grant made `go build -o bin/loom-exec` fail with EBUSY
// inside the jail. See helperCovered.
func TestBwrapArgsSkipsAHelperTheViewAlreadyCarries(t *testing.T) {
	covering := map[string]func(*policy.Policy){
		"writable root": func(p *policy.Policy) {
			p.WritableRoots = []string{"/work"}
		},
		"readable root": func(p *policy.Policy) {
			p.ReadableRoots = []string{"/work"}
		},
		"explicit mount": func(p *policy.Policy) {
			p.Mounts = []policy.Mount{{
				Path: "/work", Access: policy.MountReadOnly, Required: true,
			}}
		},
		"whole-host readable root": func(p *policy.Policy) {
			p.ReadableRoots = []string{"/"}
		},
	}
	const helper = "/work/bin/loom-exec"
	for name, cover := range covering {
		t.Run(name, func(t *testing.T) {
			p := basePol()
			p.WritableRoots = nil
			p.ReadableRoots = nil
			p.Protected = nil
			cover(&p)
			for _, op := range MountPlan(p, nil, helper) {
				if op.Path == helper {
					t.Fatalf("the helper got an operation of its own "+
						"though the %s already carries it: %q", name, op.Argv)
				}
			}
		})
	}
}

// The same for the base view's own system directories, which is where an
// installed release puts the helper.
func TestBwrapArgsSkipsAHelperUnderASystemRoot(t *testing.T) {
	const helper = "/usr/local/lib/loom/loom-exec"
	for _, op := range MountPlan(basePol(), nil, helper) {
		if op.Path == helper {
			t.Fatalf("the helper under /usr got an operation of its own: %q",
				op.Argv)
		}
	}
}

// A helper nothing else covers still gets its grant: that is the case the
// grant exists for.
func TestBwrapArgsGrantsAHelperOutsideTheView(t *testing.T) {
	const helper = "/srv/loom/bin/loom-exec"
	var seen bool
	for _, op := range MountPlan(basePol(), nil, helper) {
		if op.Path == helper {
			seen = true
		}
	}
	if !seen {
		t.Fatal("a helper outside every granted region was not bound, so " +
			"the jail has nothing to exec as stage 2")
	}
}

// A protected entry covering the helper is refused rather than planned:
// the mask would remove the binary the jail exists to exec, and bwrap
// reports that as an anonymous `execvp failed`.
func TestHelperUnderProtected(t *testing.T) {
	got := HelperUnderProtected([]string{"/work/.git", "/srv/loom"},
		"/srv/loom/bin/loom-exec")
	if got != "/srv/loom" {
		t.Fatalf("the protected entry masking the helper was not named: %q",
			got)
	}
	if got := HelperUnderProtected([]string{"/work/.git"},
		"/srv/loom/bin/loom-exec"); got != "" {
		t.Fatalf("a helper no protected entry covers was refused: %q", got)
	}
}

func TestBwrapArgsPathScratch(t *testing.T) {
	p := basePol()
	p.Scratch = "/var/scratch"
	got := BwrapArgs(p, nil, "")
	if !containsSeq(got, []string{"--bind", "/var/scratch", "/var/scratch"}) {
		t.Fatalf("path scratch not bind-mounted rw: %q", got)
	}
	for _, a := range got {
		if a == ScratchMount {
			t.Fatalf("path scratch must not also mount %s", ScratchMount)
		}
	}
}

// Determinism: identical policies yield byte-identical argv regardless
// of input slice order (bind order is part of the security semantics).
func TestBwrapArgsDeterministic(t *testing.T) {
	p1 := basePol()
	p1.WritableRoots = []string{"/b", "/a"}
	p2 := basePol()
	p2.WritableRoots = []string{"/a", "/b"}
	if !reflect.DeepEqual(BwrapArgs(p1, nil, ""), BwrapArgs(p2, nil, "")) {
		t.Fatal("argv depends on input ordering")
	}
}

// --- the precedence model (issues #51, #41, #55) -------------------------

// Rule 1, stated as a property of the plan rather than of a verb
// spelling: once a mask is emitted, nothing else may be. The rule this
// replaces was "no *bind* follows --proc", and the scratch mount walked
// straight through it — it could be spelled `--tmpfs`, and the
// protected-file mask is itself spelled `--ro-bind`. Classifying the op
// is what makes the check hold for mount forms nobody has written yet.
// The one exception is rule 1a, the policy's explicit `mounts`, which are
// emitted after the masks on purpose; this policy carries none, and
// TestBwrapArgsExplicitMountsFollowTheMasks pins that ordering instead.
func TestBwrapArgsNothingFollowsTheMasks(t *testing.T) {
	p := basePol()
	p.ReadableRoots = []string{"/", "/opt/tools"}
	p.WritableRoots = []string{"/", "/work"}
	p.Scratch = "/var/scratch"
	kinds := map[string]PathKind{"/work/.git": PathDir, "/work/.env": PathFile}
	plan := MountPlan(p, kinds, "")
	seenMask := false
	for _, op := range plan {
		if op.Class.IsMask() {
			seenMask = true
			continue
		}
		if seenMask {
			t.Fatalf("grant %v follows a mask and can undo it: %v", op.Argv, plan)
		}
	}
	if !seenMask {
		t.Fatal("no mask in the plan at all, so the property is vacuous")
	}
	// And the argv really is the plan rendered, so the property above
	// is a property of what bwrap is handed and not of a parallel model.
	var want []string
	for _, op := range plan {
		want = append(want, op.Argv...)
	}
	// The rendered plan is followed by the read-only remount of the root
	// and nothing else, which is not a mount operation and cannot widen
	// anything; see BwrapArgs.
	got := BwrapArgs(p, kinds, "")
	got = got[:len(got)-2]
	if !reflect.DeepEqual(got[len(got)-len(want):], want) {
		t.Fatalf("argv does not end in the rendered plan:\n got  %q\nwant %q", got, want)
	}
}

// Rule 2. A readable root nested inside a writable root must come out
// read-only. The old code emitted every readable root before every
// writable one, so the enclosing `--bind` landed on top of the nested
// `--ro-bind` and the jail wrote through to the host — while the
// comment above that very loop claimed the opposite.
func TestBwrapArgsNestedReadableRootStaysReadOnly(t *testing.T) {
	p := basePol()
	p.WritableRoots = []string{"/work"}
	p.ReadableRoots = []string{"/work/vendor"}
	p.Protected = nil
	got := BwrapArgs(p, nil, "")
	parent := indexOfOp(got, []string{"--bind", "/work", "/work"})
	child := indexOfOp(got, []string{"--ro-bind-try", "/work/vendor", "/work/vendor"})
	if parent < 0 || child < 0 {
		t.Fatalf("argv missing the writable parent or the readable child: %q", got)
	}
	if child < parent {
		t.Fatalf("readable /work/vendor emitted before writable /work, so the "+
			"parent bind re-exposes it writable: %q", got)
	}
}

// The tie rule the workspace default depends on: the same path in
// readable_roots and writable_roots is writable, and the argv says so
// once rather than binding it twice and letting the second line win.
func TestBwrapArgsWritableBeatsReadableAtTheSamePath(t *testing.T) {
	p := basePol()
	p.ReadableRoots = []string{"/work"}
	p.WritableRoots = []string{"/work"}
	p.Protected = nil
	got := BwrapArgs(p, nil, "")
	if indexOfOp(got, []string{"--ro-bind", "/work", "/work"}) >= 0 ||
		indexOfOp(got, []string{"--ro-bind-try", "/work", "/work"}) >= 0 {
		t.Fatalf("the losing readable grant is still emitted: %q", got)
	}
	if indexOfOp(got, []string{"--bind", "/work", "/work"}) < 0 {
		t.Fatalf("the workspace is not writable: %q", got)
	}
}

// #51/#41: a protected path underneath a tmpfs scratch mount must stay
// masked. With the scratch emitted last, the mask was replaced by fresh
// empty tmpfs and the path became creatable and writable inside the
// jail — breaking PathMissing's own stated property.
func TestBwrapArgsProtectedUnderScratchTmpfsStaysMasked(t *testing.T) {
	p := basePol()
	p.Protected = []string{ScratchMount + "/vault"}
	got := BwrapArgs(p, map[string]PathKind{ScratchMount + "/vault": PathDir}, "")
	scratch := indexOfOp(got, []string{"--tmpfs", ScratchMount})
	mask := indexOfOp(got, []string{"--tmpfs", ScratchMount + "/vault"})
	if scratch < 0 || mask < 0 {
		t.Fatalf("argv missing the scratch mount or the protected mask: %q", got)
	}
	if mask < scratch {
		t.Fatalf("the scratch tmpfs is emitted after the protected mask and "+
			"replaces it: %q", got)
	}
}

// #51: the same defect with the host filesystem behind it — the
// reviewer read a cap token out of the masked vault and wrote through
// to the host file.
func TestBwrapArgsProtectedUnderScratchPathStaysMasked(t *testing.T) {
	p := basePol()
	p.Scratch = "/var/scratch"
	p.Protected = []string{"/var/scratch/vault"}
	got := BwrapArgs(p, map[string]PathKind{"/var/scratch/vault": PathDir}, "")
	bind := indexOfOp(got, []string{"--bind", "/var/scratch", "/var/scratch"})
	mask := indexOfOp(got, []string{"--tmpfs", "/var/scratch/vault"})
	if bind < 0 || mask < 0 {
		t.Fatalf("argv missing the scratch bind or the protected mask: %q", got)
	}
	if mask < bind {
		t.Fatalf("the scratch bind is emitted after the protected mask and "+
			"re-exposes it writable: %q", got)
	}
}

// #51: `scratch: "/"` is the #37 fingerprint again — a bind of the
// ancestor of /proc and /dev, emitted after the two masks, putting the
// host's process table and device tree back inside the jail. `--bind`
// this time rather than `--ro-bind`, so writable.
func TestBwrapArgsScratchOfRootDoesNotUnmaskProcOrDev(t *testing.T) {
	p := basePol()
	p.Scratch = "/"
	p.Protected = nil
	got := BwrapArgs(p, nil, "")
	bind := indexOfOp(got, []string{"--bind", "/", "/"})
	procAt := indexOfOp(got, []string{"--proc", "/proc"})
	devAt := indexOfOp(got, []string{"--dev", "/dev"})
	if bind < 0 || procAt < 0 || devAt < 0 {
		t.Fatalf("argv missing the scratch bind, --proc or --dev: %q", got)
	}
	if procAt < bind || devAt < bind {
		t.Fatalf("scratch of \"/\" is bound after the virtual mounts and "+
			"restores the host's /proc and /dev: %q", got)
	}
}

// #41: an explicitly granted writable root underneath the scratch mount
// must survive it. bwrap creates the mountpoint inside the fresh tmpfs
// and binds the host directory there, so honouring the grant costs
// nothing — and the alternative is a write that silently evaporates.
func TestBwrapArgsWritableRootSurvivesTheScratchTmpfs(t *testing.T) {
	p := basePol()
	p.WritableRoots = []string{ScratchMount + "/build"}
	p.Protected = nil
	got := BwrapArgs(p, nil, "")
	scratch := indexOfOp(got, []string{"--tmpfs", ScratchMount})
	root := indexOfOp(got, []string{"--bind", ScratchMount + "/build", ScratchMount + "/build"})
	if scratch < 0 || root < 0 {
		t.Fatalf("argv missing the scratch mount or the writable root: %q", got)
	}
	if root < scratch {
		t.Fatalf("the scratch tmpfs shadows the writable root it was asked "+
			"to keep: %q", got)
	}
}

// A protected path nested inside another protected path is already
// masked by its ancestor, and giving it a mask of its own makes bwrap
// refuse to start — the ancestor's tmpfs is remounted read-only, so the
// mountpoint cannot be created:
//
//	bwrap: Can't mkdir /home/u/.ssh/id_rsa: Read-only file system
//
// Measured with bubblewrap 0.9.0. `protected: ["~/.ssh",
// "~/.ssh/id_rsa"]` is an ordinary belt-and-braces policy and it killed
// every jail built from it.
func TestBwrapArgsNestedProtectedPathIsMaskedOnlyOnce(t *testing.T) {
	p := basePol()
	p.Protected = []string{"/home/u/.ssh", "/home/u/.ssh/id_rsa"}
	for _, op := range MountPlan(p, map[string]PathKind{
		"/home/u/.ssh":        PathDir,
		"/home/u/.ssh/id_rsa": PathFile,
	}, "") {
		if op.Path == "/home/u/.ssh/id_rsa" {
			t.Fatalf("a protected path inside a protected path got its own "+
				"mount %v, which makes bwrap refuse to start", op.Argv)
		}
	}
}

// #55: a protected path is removed from the jail's view whatever its
// inode type. The old code bind-mounted a protected *file* onto itself
// read-only, which left it fully readable — so `protected:
// ["~/.aws/credentials"]`, the most obvious use of the feature, handed
// the credentials to the jailed process and only stopped it writing
// them back.
func TestBwrapArgsProtectedFileIsUnreadable(t *testing.T) {
	p := basePol()
	p.Protected = []string{"/work/.env"}
	got := BwrapArgs(p, map[string]PathKind{"/work/.env": PathFile}, "")
	if indexOfOp(got, []string{"--ro-bind", "/work/.env", "/work/.env"}) >= 0 {
		t.Fatalf("a protected file is bound onto itself and stays readable: %q", got)
	}
	if indexOfOp(got, []string{"--ro-bind", MaskSource, "/work/.env"}) < 0 {
		t.Fatalf("a protected file is not masked: %q", got)
	}
}

// Regions are compared as canonical paths, so a policy that spells the
// workspace `/work` in one list and `/work/` in another still gets one
// grant, and the tie rule decides it rather than the sort order.
func TestBwrapArgsRegionsAreCanonical(t *testing.T) {
	p := basePol()
	p.ReadableRoots = []string{"/work/"}
	p.WritableRoots = []string{"/work"}
	p.Protected = []string{"/work/.git/"}
	got := BwrapArgs(p, map[string]PathKind{"/work/.git/": PathDir}, "")
	if indexOfOp(got, []string{"--ro-bind-try", "/work/", "/work/"}) >= 0 ||
		indexOfOp(got, []string{"--ro-bind-try", "/work", "/work"}) >= 0 {
		t.Fatalf("the losing readable grant survived a trailing slash: %q", got)
	}
	if indexOfOp(got, []string{"--bind", "/work", "/work"}) < 0 {
		t.Fatalf("the workspace is not writable: %q", got)
	}
	if !containsSeq(got, []string{"--tmpfs", "/work/.git", "--remount-ro", "/work/.git"}) {
		t.Fatalf("the protected directory lost its kind to a trailing slash: %q", got)
	}
}

// A grant nested inside a protected path does not carve a hole in it:
// masks are not subject to the specificity rule.
func TestBwrapArgsWritableRootInsideProtectedStaysMasked(t *testing.T) {
	p := basePol()
	p.WritableRoots = []string{"/work", "/work/.git/objects"}
	p.Protected = []string{"/work/.git"}
	got := BwrapArgs(p, map[string]PathKind{"/work/.git": PathDir}, "")
	grant := indexOfOp(got, []string{"--bind", "/work/.git/objects", "/work/.git/objects"})
	mask := indexOfOp(got, []string{"--tmpfs", "/work/.git"})
	if grant < 0 || mask < 0 {
		t.Fatalf("argv missing the nested writable root or the mask: %q", got)
	}
	if grant > mask {
		t.Fatalf("a writable root inside a protected directory is emitted "+
			"after the mask and re-opens it: %q", got)
	}
}

// indexOfOp returns the index of the first occurrence of seq in argv, or -1.
func indexOfOp(argv, seq []string) int {
	for i := 0; i+len(seq) <= len(argv); i++ {
		if reflect.DeepEqual(argv[i:i+len(seq)], seq) {
			return i
		}
	}
	return -1
}

func containsSeq(haystack, needle []string) bool {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if reflect.DeepEqual(haystack[i:i+len(needle)], needle) {
			return true
		}
	}
	return false
}

// --- the same properties, in a real jail ---------------------------------
//
// The argv assertions above say what this file emits. These say what
// bubblewrap does with it, which is the only claim that settles a
// mount-precedence question: the man page is a hypothesis, a run is a
// result. Every one of them reproduced the defect before the precedence
// model landed — the outputs are in issue #51 — and refuses it after.
//
// They exercise bwrap directly rather than through the helper: the
// properties are properties of the mount view, and stage 2's Landlock
// and seccomp layers are neither necessary nor sufficient for any of
// them (Landlock has no deny rules, so it cannot carve a protected path
// out of a writable root at all).

// jailFixture makes a directory tree for one jailed test, outside the
// scratch mount for the same reason probeDir is: a tmpfs scratch would
// otherwise shadow the fixture itself on a host with no TMPDIR.
func jailFixture(t *testing.T) string {
	t.Helper()
	base := os.TempDir()
	if base == ScratchMount || strings.HasPrefix(base, ScratchMount+"/") {
		if fi, err := os.Stat("/var/tmp"); err == nil && fi.IsDir() {
			base = "/var/tmp"
		}
	}
	dir, err := os.MkdirTemp(base, "loom-bwrap-*")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}

// inJail runs sh -c script inside the jail this policy describes and
// returns its combined output. Network is left alone: --unshare-net
// costs a namespace setup these tests do not need, and none of them
// touch the network.
func inJail(t *testing.T, p policy.Policy, kinds map[string]PathKind, script string) string {
	t.Helper()
	bwrap, err := exec.LookPath("bwrap")
	if err != nil {
		t.Skip("mount precedence is bwrap's to apply; no bwrap on this host")
	}
	p.Network = policy.Network{Mode: policy.NetworkFull}
	argv := append(BwrapArgs(p, kinds, ""), "/bin/sh", "-c", script)
	out, _ := exec.Command(bwrap, argv...).CombinedOutput()
	return string(out)
}

// #51, 1a. Before: `cat vault/cap-token` printed the token and a write
// through it landed on the host file. The scratch bind was emitted
// after the mask and replaced it.
func TestJailedProtectedPathUnderScratchPathIsNotReExposed(t *testing.T) {
	dir := jailFixture(t)
	vault := filepath.Join(dir, "scratch", "vault")
	if err := os.MkdirAll(vault, 0o700); err != nil {
		t.Fatal(err)
	}
	token := filepath.Join(vault, "cap-token")
	const secret = "LOOM_CAP_TOKEN=top-secret\n"
	if err := os.WriteFile(token, []byte(secret), 0o600); err != nil {
		t.Fatal(err)
	}
	p := basePol()
	p.WritableRoots = []string{dir}
	p.ReadableRoots = nil
	p.Scratch = filepath.Join(dir, "scratch")
	p.Protected = []string{vault}
	out := inJail(t, p, map[string]PathKind{vault: PathDir},
		"cat "+token+"; echo pwned > "+token+" && echo WROTE")
	if strings.Contains(out, "top-secret") {
		t.Fatalf("the protected vault was readable inside the jail: %q", out)
	}
	if strings.Contains(out, "WROTE") {
		t.Fatalf("the protected vault was writable inside the jail: %q", out)
	}
	got, err := os.ReadFile(token)
	if err != nil || string(got) != secret {
		t.Fatalf("the host token was altered through the jail: %q, %v", got, err)
	}
}

// #51, 1b. Before: 83 host pids, /proc/1/cmdline reading the host init,
// all 111 host device nodes and /dev/null unopenable — the #37
// fingerprint, with `--bind` rather than `--ro-bind` behind it.
func TestJailedScratchOfRootDoesNotRestoreHostProcAndDev(t *testing.T) {
	p := basePol()
	p.Protected = nil
	// basePol's roots are illustrative paths that need not exist; a
	// bind of a missing source makes bwrap refuse to start.
	p.ReadableRoots = nil
	p.WritableRoots = nil
	p.Scratch = "/"
	hostInit, err := os.ReadFile("/proc/1/cmdline")
	if err != nil {
		t.Skip("no /proc/1/cmdline to compare the jail's against")
	}
	out := inJail(t, p, nil,
		`echo pids=$(ls -d /proc/[0-9]* | wc -l); `+
			`echo init=$(tr "\0" " " < /proc/1/cmdline); `+
			`if echo x > /dev/null; then echo devnull=ok; else echo devnull=EACCES; fi`)
	if !strings.Contains(out, "devnull=ok") {
		t.Fatalf("the host device tree is back and nodev makes it useless: %q", out)
	}
	// The host's init, seen as pid 1 from inside, is the sharp reading
	// of "this is the host's /proc" — the count below is the readable
	// one.
	if host := strings.TrimSpace(strings.ReplaceAll(string(hostInit), "\x00", " ")); host != "" &&
		strings.Contains(out, "init="+host) {
		t.Fatalf("/proc/1 is the *host* init, so /proc is the host's: %q", out)
	}
	var pids int
	if _, err := fmt.Sscanf(strings.TrimSpace(strings.Split(out, "\n")[0]), "pids=%d", &pids); err != nil {
		t.Fatalf("probe output unreadable: %q", out)
	}
	if pids > 8 {
		t.Fatalf("%d pids visible: the host process table is in the jail: %q", pids, out)
	}
}

// #51, the readable-inside-writable row. Before: `echo CLOBBERED >
// /w/ro/readonly.txt` wrote through to the host, because every readable
// root was emitted before every writable one.
func TestJailedNestedReadableRootIsReadOnly(t *testing.T) {
	dir := jailFixture(t)
	ro := filepath.Join(dir, "ro")
	if err := os.MkdirAll(ro, 0o700); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(ro, "readonly.txt")
	const original = "readonly-content\n"
	if err := os.WriteFile(file, []byte(original), 0o600); err != nil {
		t.Fatal(err)
	}
	p := basePol()
	p.WritableRoots = []string{dir}
	p.ReadableRoots = []string{ro}
	p.Protected = nil
	out := inJail(t, p, nil,
		"echo CLOBBERED > "+file+" && echo WROTE; echo ok > "+dir+"/w && echo PARENT-WRITABLE")
	if strings.Contains(out, "WROTE") {
		t.Fatalf("the nested readable root was writable: %q", out)
	}
	if !strings.Contains(out, "PARENT-WRITABLE") {
		t.Fatalf("the enclosing writable root lost its write access: %q", out)
	}
	got, err := os.ReadFile(file)
	if err != nil || string(got) != original {
		t.Fatalf("the host file was altered through the jail: %q, %v", got, err)
	}
}

// #41, the protected-under-scratch row. Before: the scratch tmpfs
// landed on the mask and the protected path became creatable, breaking
// PathMissing's own property.
func TestJailedProtectedPathUnderScratchTmpfsStaysUncreatable(t *testing.T) {
	prot := ScratchMount + "/loom-bwrap-vault"
	if err := os.MkdirAll(prot, 0o700); err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(prot)
	p := basePol()
	p.WritableRoots = nil
	p.ReadableRoots = nil
	p.Protected = []string{prot}
	out := inJail(t, p, map[string]PathKind{prot: PathDir},
		"echo STARTED; mkdir -p "+prot+" && echo pwn > "+prot+"/s && echo CREATED")
	// Without the marker this test passes for the wrong reason: the
	// same defect can also make bwrap refuse to start outright, and a
	// jail that never ran creates nothing either.
	if !strings.Contains(out, "STARTED") {
		t.Fatalf("the jail did not start, so nothing here was measured: %q", out)
	}
	if strings.Contains(out, "CREATED") {
		t.Fatalf("a protected path under the scratch mount was creatable: %q", out)
	}
}

// #41, the row the issue is named for: a writable root the policy asked
// for, underneath the scratch mount. Before, it was replaced by empty
// scratch and every write to it evaporated.
func TestJailedWritableRootUnderScratchTmpfsSurvives(t *testing.T) {
	root := ScratchMount + "/loom-bwrap-build"
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)
	p := basePol()
	p.WritableRoots = []string{root}
	p.ReadableRoots = nil
	p.Protected = nil
	out := inJail(t, p, nil, "echo landed > "+root+"/out && echo WROTE")
	if !strings.Contains(out, "WROTE") {
		t.Fatalf("the granted writable root was shadowed by scratch: %q", out)
	}
	got, err := os.ReadFile(filepath.Join(root, "out"))
	if err != nil || string(got) != "landed\n" {
		t.Fatalf("the write did not reach the host directory it named: %q, %v", got, err)
	}
}

// A protected path inside another protected path used to make bwrap
// refuse to start, which surfaced as an ordinary code=1.
func TestJailedNestedProtectedPathsStillStartTheJail(t *testing.T) {
	dir := jailFixture(t)
	ssh := filepath.Join(dir, ".ssh")
	if err := os.MkdirAll(ssh, 0o700); err != nil {
		t.Fatal(err)
	}
	key := filepath.Join(ssh, "id_rsa")
	if err := os.WriteFile(key, []byte("PRIVATE KEY\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := basePol()
	p.WritableRoots = []string{dir}
	p.ReadableRoots = nil
	p.Protected = []string{ssh, key}
	out := inJail(t, p, map[string]PathKind{ssh: PathDir, key: PathFile},
		"echo STARTED; cat "+key)
	if !strings.Contains(out, "STARTED") {
		t.Fatalf("the jail did not start with nested protected paths: %q", out)
	}
	if strings.Contains(out, "PRIVATE KEY") {
		t.Fatalf("the nested protected file was readable: %q", out)
	}
}

// #55. Before: `cat secret.env` printed SECRET=plain-file from inside
// the jail, because a protected file was bound onto itself read-only.
func TestJailedProtectedFileIsUnreadable(t *testing.T) {
	dir := jailFixture(t)
	secret := filepath.Join(dir, "secret.env")
	const original = "SECRET=plain-file\n"
	if err := os.WriteFile(secret, []byte(original), 0o600); err != nil {
		t.Fatal(err)
	}
	p := basePol()
	p.WritableRoots = []string{dir}
	p.ReadableRoots = nil
	p.Protected = []string{secret}
	out := inJail(t, p, map[string]PathKind{secret: PathFile},
		"cat "+secret+"; echo pwn > "+secret+" && echo WROTE")
	if strings.Contains(out, "plain-file") {
		t.Fatalf("the protected file was readable inside the jail: %q", out)
	}
	if strings.Contains(out, "WROTE") {
		t.Fatalf("the protected file was writable inside the jail: %q", out)
	}
	got, err := os.ReadFile(secret)
	if err != nil || string(got) != original {
		t.Fatalf("the host file was altered through the jail: %q, %v", got, err)
	}
}

// Rule 1a. The policy's explicit mounts are the one thing emitted after
// the masks, because the cap socket has to be visible inside the jail
// even where the scratch tmpfs would shadow it. Neither mount here
// overlaps a protected entry, and neither could: the decoder refuses that
// pair on both sides of the wire, so the only shadow left for a mount to
// win over is the scratch tmpfs. This pins the whole argv rather than a
// relation, because the ordering is the property protocol-change/004
// states.
func TestBwrapArgsExplicitMountsFollowTheMasks(t *testing.T) {
	p := basePol()
	p.Mounts = []policy.Mount{
		{Path: "/srv/cap/s", Access: policy.MountReadOnly, Required: true},
		{Path: "/tmp/cap", Access: policy.MountReadWrite, Required: false},
	}
	kinds := map[string]PathKind{"/work/.git": PathDir, "/work/.env": PathFile}
	got := BwrapArgs(p, kinds, "")
	want := []string{
		"--die-with-parent",
		"--unshare-pid",
		"--unshare-ipc",
		"--unshare-uts",
		"--unshare-user-try",
		"--unshare-cgroup-try",
		"--unshare-net",
		"--ro-bind-try", "/bin", "/bin",
		"--ro-bind-try", "/etc", "/etc",
		"--ro-bind-try", "/lib", "/lib",
		"--ro-bind-try", "/lib32", "/lib32",
		"--ro-bind-try", "/lib64", "/lib64",
		"--ro-bind-try", "/nix/store", "/nix/store",
		"--ro-bind-try", "/opt", "/opt",
		"--ro-bind-try", "/opt/tools", "/opt/tools",
		"--ro-bind-try", "/run/current-system", "/run/current-system",
		"--ro-bind-try", "/sbin", "/sbin",
		"--tmpfs", "/tmp",
		"--ro-bind-try", "/usr", "/usr",
		"--ro-bind-try", "/var/lib", "/var/lib",
		"--bind", "/work", "/work",
		"--dev", "/dev",
		"--proc", "/proc",
		"--ro-bind", MaskSource, "/work/.env",
		"--tmpfs", "/work/.git", "--remount-ro", "/work/.git",
		"--ro-bind", "/srv/cap/s", "/srv/cap/s",
		"--bind-try", "/tmp/cap", "/tmp/cap",
		"--remount-ro", "/",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("bwrap argv mismatch:\n got  %q\nwant %q", got, want)
	}
}

// `required` is the difference between bwrap refusing the jail and
// skipping the mount, so it must reach the argv and not only the
// up-front stat in MissingRequiredMounts.
func TestBwrapArgsOptionalMountUsesTheTryForm(t *testing.T) {
	p := basePol()
	p.Protected = nil
	p.Mounts = []policy.Mount{
		{Path: "/opt/seed", Access: policy.MountReadOnly, Required: false},
		{Path: "/opt/toolchain", Access: policy.MountReadOnly, Required: true},
		{Path: "/var/out", Access: policy.MountReadWrite, Required: true},
		{Path: "/var/cache", Access: policy.MountReadWrite, Required: false},
	}
	got := strings.Join(BwrapArgs(p, nil, ""), " ")
	for _, want := range []string{
		"--ro-bind-try /opt/seed /opt/seed",
		"--ro-bind /opt/toolchain /opt/toolchain",
		"--bind /var/out /var/out",
		"--bind-try /var/cache /var/cache",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("argv %q does not contain %q", got, want)
		}
	}
}

// Inside the mount phase rule 2 still holds: a parent is emitted before
// every descendant of it, so a narrower mount lands on top of the wider
// one rather than under it.
func TestBwrapArgsMountsAreParentBeforeChild(t *testing.T) {
	p := basePol()
	p.Protected = nil
	p.Mounts = []policy.Mount{
		{Path: "/srv/a/b", Access: policy.MountReadOnly, Required: true},
		{Path: "/srv", Access: policy.MountReadWrite, Required: true},
		{Path: "/srv/a", Access: policy.MountReadWrite, Required: true},
	}
	var paths []string
	for _, op := range MountPlan(p, nil, "") {
		if op.Class == ClassMountReadOnly || op.Class == ClassMountReadWrite {
			paths = append(paths, op.Path)
		}
	}
	want := []string{"/srv", "/srv/a", "/srv/a/b"}
	if !reflect.DeepEqual(paths, want) {
		t.Fatalf("mount order %q, want %q", paths, want)
	}
}

// A mount whose destination lies under one of the read-only system
// binds. bwrap cannot create a mount point inside a read-only bind, so
// this shape looks like it should need a refusal, and it does not: every
// operation in the plan binds a path onto itself, so the destination
// exists inside the system bind whenever the source exists on the host,
// and the source is what MissingRequiredMounts already checks for a
// required mount and what the "-try" form tolerates for an optional one.
// The argv is what states that rule, so it is what this pins: the system
// bind first, the mount after it.
func TestBwrapArgsMountUnderASystemRoot(t *testing.T) {
	p := basePol()
	p.Mounts = []policy.Mount{
		{Path: "/usr/lib/erlang", Access: policy.MountReadOnly, Required: true},
	}
	got := BwrapArgs(p, nil, "")
	usrAt, mountAt := -1, -1
	for i := 0; i+2 < len(got); i++ {
		if got[i] == "--ro-bind-try" && got[i+1] == "/usr" {
			usrAt = i
		}
		if got[i] == "--ro-bind" && got[i+1] == "/usr/lib/erlang" {
			mountAt = i
		}
	}
	if usrAt < 0 || mountAt < 0 {
		t.Fatalf("argv missing the system bind or the mount: %q", got)
	}
	if mountAt < usrAt {
		t.Fatalf("the mount precedes the system bind that would shadow "+
			"it: %q", got)
	}
}
