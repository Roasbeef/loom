// bwrap argv construction. bwrap owns *all* namespace and mount work
// (spec WP-H, load-bearing): the Go runtime is multithreaded from the
// first instruction, and unshare/fork-based namespace assembly in a
// multithreaded process is the runc nsexec.c tar pit. The helper only
// composes an argv here — pure data, golden-tested — and later stacks
// in-process restrictions (Landlock, seccomp, rlimits) on itself before
// exec. If bwrap is missing at runtime we run degraded (in-process
// layers only) and say so in hello features and exec results; we never
// try to build namespaces ourselves.
package jail

import (
	"path/filepath"
	"sort"
	"strings"

	"github.com/roasbeef/loom/sandbox/internal/policy"
)

// PathKind classifies a protected path for masking purposes.
//
// It must describe the path's *resolved* target, not the link itself.
// bwrap resolves the destination of a mount, so a mask aimed at a
// symlink lands on whatever the symlink points at: classifying a
// symlink-to-directory as PathFile emits a file mask against a
// directory and bwrap refuses to start. An absolute symlink is worse
// still — during setup its target resolves inside bwrap's pivot root,
// where it does not exist, and *every* mask form fails with ENOENT.
// Both measured with bubblewrap 0.9.0. So callers stat through symlinks
// and mask the resolved path; `~/.ssh` being a symlink is not exotic.
type PathKind int

const (
	// PathMissing: the path does not exist. It is still masked (with a
	// read-only tmpfs) so the jailed process cannot *create* it — a
	// protected ~/.ssh that does not exist yet must stay uncreatable.
	PathMissing PathKind = iota
	// PathFile: an existing regular file, or any other non-directory.
	PathFile
	// PathDir: an existing directory.
	PathDir
)

// ScratchMount is where a "tmpfs" scratch policy mounts inside the jail.
const ScratchMount = "/tmp"

// MaskSource is the host path bound over a protected file. tmpfs cannot
// mount over a non-directory, so a protected file is shadowed by a
// read-only bind of an empty device instead. bwrap binds MS_NODEV
// unless asked for --dev-bind, so inside the jail the masked path
// cannot be opened at all — EACCES on read and on write, measured with
// bubblewrap 0.9.0. And were nodev ever absent, a read would still see
// an empty file and a write would still go nowhere near the host. Both
// readings are safe, which is why the mask does not have to know which
// one applies.
const MaskSource = "/dev/null"

// BlocksDirectNetwork reports whether a network mode requires the jail
// to deny direct socket access. NetworkOff blocks by definition.
// NetworkProxy blocks too: the egress sidecar that would carry
// allowlisted traffic is not implemented in phase 1, so proxy mode
// fails closed to no direct network rather than silently widening to
// unrestricted egress — the one failure mode the design forbids. Only
// NetworkFull leaves the host network reachable.
func BlocksDirectNetwork(m policy.NetworkMode) bool {
	return m == policy.NetworkOff || m == policy.NetworkProxy
}

// ProxyUnenforcedSkip is the enforcement-report entry stage 2 emits for
// a proxy-mode policy: the allowlist was NOT enforced (there is no
// sidecar to enforce it); direct network was disabled instead. Surfaced
// to the broker as "skip:" + this string, which fails a
// full-enforcement demand.
const ProxyUnenforcedSkip = "network-proxy: egress sidecar not implemented in phase 1; direct network disabled, allowlist not enforced"

// BwrapArgs computes the bubblewrap argument list (excluding the bwrap
// executable itself and the command to run) for a policy.
//
// # The precedence model
//
// bwrap applies mount operations in argv order, so argv order *is* the
// precedence between overlapping mounts. Leaving that to the order the
// four policy path lists happen to be concatenated in is what produced
// #37, #41 and #51: the code asserted a rule in a comment and the loops
// below it did something else. So the argv is not built by
// concatenation here. It is built as an explicit plan of MountOps —
// each carrying the region it governs and a MountClass saying what it
// does to that region — and the plan is ordered by two rules.
//
// **Rule 1: grants first, masks last, and nothing whatsoever after a
// mask.** A grant (a readable root, a writable root, the scratch area)
// widens the jail's view; a mask (`/proc`, `/dev`, a protected path)
// subtracts from it. A grant emitted after a mask undoes it and fails
// *open* — that is the whole of #37 and #51. A mask emitted after a
// grant merely narrows it. So masks go last, unconditionally, including
// after the scratch mount, which is a grant and used to be emitted dead
// last.
//
// **Rule 1a: the policy's explicit mounts come after even the masks.**
// `mounts` (protocol-change/004) is the one verb whose whole purpose is
// to survive a shadow: the cap socket has to be visible inside the jail
// even where the scratch tmpfs covers it, and argv order is the only
// thing that decides that. So an explicit mount is emitted last, and 004
// states that ordering as the property rather than as an implementation
// detail. The shadow it wins over is the scratch tmpfs, and never a
// protected mask: a mount overlapping a protected entry in either
// direction is refused when the policy is decoded, on both sides of the
// wire, so no plan reaching here contains that pair.
//
// **Rule 2: inside a phase, the most specific region wins.** Ops are
// sorted by path, which for absolute paths puts a parent before every
// descendant of it — a descendant carries the parent's path as a prefix
// and is longer than it — so a nested op lands on top of the enclosing
// one. That is what makes a readable root nested inside a writable root
// come out read-only, and what lets a writable root the policy asked
// for survive the scratch tmpfs above it (#41) instead of silently
// evaporating.
//
// Masks are deliberately *not* subject to rule 2 against grants.
// `protected` is the only subtractive verb the policy has, so no grant
// at any depth may carve a hole in one: a writable root inside a
// protected directory stays masked.
//
// Two regions may also be named at the *same* path, where rule 2 has
// nothing to say. MountClass is ordered so the higher class takes the
// region and the loser is dropped rather than emitted and overwritten;
// the argv then says which one applies, exactly once:
//
//   - **Writable beats readable.** `policy.workspace_default` names the
//     workspace in `readable_roots` *and* in `writable_roots`, so this
//     tie is load-bearing and must resolve to writable. Nothing is lost
//     by that: a writable bind grants reads too, so the union of the two
//     grants is exactly the writable one.
//   - **A readable root beats the empty root tmpfs at "/".** That tie is
//     how an older harness keeps working. `readable_roots: ["/"]` binds
//     the host back over the tmpfs and reproduces the base view this
//     helper had before protocol-change/020, so a harness that has not
//     yet dropped that entry is unchanged by the narrowing. The audit
//     says which of the two views was in effect (`base=` in the
//     `mounts:` entry) so the enforcement report does not have to be
//     read as if the two were the same jail.
//   - **The scratch tmpfs beats a root at exactly ScratchMount.**
//     Taking the bind instead would drop the scratch area the policy
//     asked for, and the fresh tmpfs is the narrower of the two anyway
//     — it carries no host content — so this tie resolves fail-closed.
//
// The base view is an empty tmpfs at `/` plus a read-only bind of each
// entry in SystemRoots. Both are ordinary grants at the least specific
// regions there are, so they obey both rules like anything else: a
// policy path nested inside `/usr` still lands on top of the system
// bind, and a mask still comes after all of them.
//
// A mount whose destination is under one of those read-only system binds
// works because every operation here binds a path onto *itself*: bwrap
// cannot create a mount point under a read-only bind, but it does not
// have to, since the destination is the source and the source exists
// whenever the bind can happen at all. A required mount whose source is
// absent is refused before any argv is built (MissingRequiredMounts),
// and an optional one renders the `-try` form and is skipped. So there
// is no third case for the plan to refuse.
//
// `kinds` classifies each protected path; callers stat outside this
// function to keep it pure, and must classify the path's resolved
// target (see PathKind).
//
// # Masking
//
// A protected path is removed from the jail's view whatever its inode
// type. A directory — and a path that does not exist yet, so a
// protected ~/.ssh cannot be *created* — is shadowed by an empty tmpfs
// remounted read-only. A file is shadowed by a read-only bind of
// MaskSource. Neither can be read through, written through, or created
// in.
func BwrapArgs(p policy.Policy, kinds map[string]PathKind, helper string) []string {
	args := []string{
		// Tie the jail's lifetime to the helper: if the helper dies, the
		// kernel delivers SIGKILL to bwrap and the PID namespace dies
		// with it. No orphaned jails.
		"--die-with-parent",
		// Fresh PID/IPC/UTS namespaces; user and cgroup namespaces are
		// "try" so the same argv works both privileged and not.
		"--unshare-pid",
		"--unshare-ipc",
		"--unshare-uts",
		"--unshare-user-try",
		"--unshare-cgroup-try",
	}
	if BlocksDirectNetwork(p.Network.Mode) {
		// A fresh, interface-less network namespace. The seccomp filter
		// (stage 2) independently denies non-AF_UNIX socket creation;
		// two layers, either alone sufficient for egress denial. Proxy
		// mode lands here too: with no egress sidecar in phase 1 it
		// fails closed to no direct network (see BlocksDirectNetwork).
		args = append(args, "--unshare-net")
	}
	for _, op := range MountPlan(p, kinds, helper) {
		args = append(args, op.Argv...)
	}
	return args
}

// MountClass says what a mount operation does to the region it names.
// The constants are ordered by precedence at an *identical* path: the
// higher class takes the region. Everything from ClassProc upwards is a
// mask, and no operation of any class may follow one. See BwrapArgs for
// why each tie resolves the way it does.
type MountClass int

const (
	// ClassRootTmpfs is the empty tmpfs the minimal base view mounts at
	// "/". It is the lowest class on purpose: a policy that names "/" as
	// a readable root replaces it with a read-only bind of the host, so
	// a harness that still sends `readable_roots: ["/"]` gets the base
	// view it had before this change rather than an empty jail.
	ClassRootTmpfs MountClass = iota
	// ClassReadable binds a region read-only.
	ClassReadable
	// ClassWritable binds a region read-write. A host-path scratch is
	// this and nothing more: an ordinary writable bind that happens to
	// be named by `scratch` rather than by `writable_roots`.
	ClassWritable
	// ClassScratchTmpfs mounts the fresh tmpfs scratch at ScratchMount.
	ClassScratchTmpfs
	// ClassProc is the fresh procfs the new PID namespace needs.
	ClassProc
	// ClassDev is the minimal device tree.
	ClassDev
	// ClassProtected is a protected-path mask.
	ClassProtected
	// ClassMountReadWrite is an explicit `mounts` entry bound
	// read-write, emitted after the masks so it is not shadowed.
	ClassMountReadWrite
	// ClassMountReadOnly is an explicit `mounts` entry bound read-only.
	ClassMountReadOnly
)

// IsMask reports whether operations of this class subtract from the
// jail's view rather than widen it. The explicit mounts are above the
// masks in the constant order because they are emitted after them, not
// because they subtract anything; they widen, which is what makes the
// audit treat a mount over a protected path as a widening.
func (c MountClass) IsMask() bool {
	return c >= ClassProc && c < ClassMountReadWrite
}

// The three phases of the plan, in argv order: grants, then masks, then
// the policy's explicit mounts. Ordering between phases is rule 1 and
// rule 1a; ordering inside a phase is rule 2.
const (
	phaseGrant = iota
	phaseMask
	phaseExplicit
)

// phase places a class in the argv order. The constant order alone
// cannot say this, because the explicit mounts sort above the masks
// without being masks.
func (c MountClass) phase() int {
	switch c {
	case ClassMountReadWrite, ClassMountReadOnly:
		return phaseExplicit
	}
	if c.IsMask() {
		return phaseMask
	}
	return phaseGrant
}

// MountOp is one entry of the ordered mount plan: the region it
// governs, what it does to that region, and the argv fragment that
// expresses it.
type MountOp struct {
	Class MountClass
	Path  string
	Argv  []string
}

// MountPlan resolves a policy into the ordered mount operations
// BwrapArgs renders. It is the precedence model in executable form:
// overlaps between the four path lists are decided here, once, instead
// of falling out of the order the lists are appended in.
func MountPlan(p policy.Policy, kinds map[string]PathKind, helper string) []MountOp {
	// Grants, keyed by region, so two grants naming the same path
	// resolve by class instead of being emitted twice and overwritten.
	grants := make(map[string]MountOp)
	grant := func(op MountOp) {
		if op.Path == "" {
			return
		}
		if prev, seen := grants[op.Path]; seen && prev.Class >= op.Class {
			return
		}
		grants[op.Path] = op
	}
	// The base view: an empty tmpfs at "/", then the system directories a
	// command needs to run at all. Everything else the jail can see is
	// named by the policy. A `readable_roots` entry of "/" outranks the
	// tmpfs at the same region and restores the whole-host view, which is
	// what an older harness still sends; see PlanIsMinimal.
	grant(MountOp{Class: ClassRootTmpfs, Path: "/",
		Argv: []string{"--tmpfs", "/"}})
	for _, sys := range SystemRoots {
		grant(readableRootOp(sys))
	}

	// The helper's own binary. Stage 2 is this executable re-executed
	// inside the jail, so a base view that does not contain it is a jail
	// that cannot start at all: bwrap reports `execvp failed` for a path
	// the payload never chose. It is not a policy path, since the sender
	// does not know where the helper was installed and the release layout
	// puts it wherever the operator unpacked it, so the helper supplies
	// it from what it knows about itself. The grant is skipped when some
	// other region already carries it; see helperCovered for why an
	// unconditional grant breaks a daemon running from its own checkout.
	if !helperCovered(p, helper) {
		grant(readableRootOp(helper))
	}
	for _, r := range p.ReadableRoots {
		grant(readableRootOp(r))
	}
	for _, w := range p.WritableRoots {
		grant(writableOp(w))
	}
	if p.ScratchIsTmpfs() {
		grant(MountOp{Class: ClassScratchTmpfs, Path: ScratchMount,
			Argv: []string{"--tmpfs", ScratchMount}})
	} else {
		grant(writableOp(p.Scratch))
	}

	plan := make([]MountOp, 0, len(grants)+2+len(p.Protected))
	for _, op := range grants {
		plan = append(plan, op)
	}

	// The masks. A fresh /proc and a minimal /dev are here rather than
	// beside the base view because that is what they are: `--ro-bind /
	// /` brings the host's process table and device tree in with
	// everything else, and these two cover them.
	plan = append(plan,
		MountOp{Class: ClassProc, Path: "/proc", Argv: []string{"--proc", "/proc"}},
		MountOp{Class: ClassDev, Path: "/dev", Argv: []string{"--dev", "/dev"}},
	)
	// kinds is keyed by the policy's own spelling of each path, and
	// sortedPaths canonicalises; look the kind up under both.
	kindOf := func(path string) PathKind {
		if k, ok := kinds[path]; ok {
			return k
		}
		for raw, k := range kinds {
			if region(raw) == path {
				return k
			}
		}
		return PathMissing
	}
	var masked []string
	for _, prot := range sortedPaths(p.Protected) {
		// A protected path inside another protected path is already
		// gone, and masking it a second time makes bwrap refuse to
		// start: the ancestor's tmpfs is remounted read-only, so the
		// mountpoint for the descendant cannot be created there.
		// Dropping it weakens nothing — the ancestor's mask covers it.
		if coveredBy(masked, prot) {
			continue
		}
		masked = append(masked, prot)
		plan = append(plan, maskOp(prot, kindOf(prot)))
	}

	// Each explicit mount is emitted once, with no tie to break: the
	// decoder refuses a repeated mount path, and refuses the two
	// spellings ("/a/", "..") that would make one region look like two.
	for _, m := range p.Mounts {
		if op := mountOp(m); op.Path != "" {
			plan = append(plan, op)
		}
	}

	// Rule 1, rule 1a, then rule 2: grants, masks, explicit mounts, and
	// within each phase a parent before every descendant of it.
	sort.SliceStable(plan, func(i, j int) bool {
		if a, b := plan[i].Class.phase(), plan[j].Class.phase(); a != b {
			return a < b
		}
		if plan[i].Path != plan[j].Path {
			return plan[i].Path < plan[j].Path
		}
		return plan[i].Class < plan[j].Class
	})
	return plan
}

// helperCovered reports whether the jail's view already carries the
// helper binary without a grant naming the file itself.
//
// The grant is not merely redundant when some enclosing region already
// supplies it. It binds the helper file read-only onto itself, and a
// read-only bind of a file is a mountpoint: the file can no longer be
// replaced, removed or truncated from inside the jail, whatever the
// region containing it allows. A daemon running from the checkout it is
// working on hits exactly that, because `os.Executable()` is
// `bin/loom-exec` under the workspace and the workspace is a writable
// root, so `go build -o bin/loom-exec` fails with EBUSY and `git
// checkout` and `make clean` fail with it too. Skipping the grant costs
// nothing: the enclosing region is what makes the helper reachable, and
// it was already emitted.
//
// A helper under a protected entry is a third case and is not decided
// here. The mask would remove the binary from a jail that has to exec
// it, and the resulting failure is bwrap's anonymous `execvp failed`, so
// run.go refuses the execution naming the path before any argv is built;
// see HelperUnderProtected.
func helperCovered(p policy.Policy, helper string) bool {
	h := region(helper)
	if h == "" {
		return true
	}
	regions := append([]string{}, SystemRoots...)
	regions = append(regions, sortedPaths(p.ReadableRoots)...)
	regions = append(regions, sortedPaths(p.WritableRoots)...)
	for _, m := range p.Mounts {
		regions = append(regions, region(m.Path))
	}
	return coveredBy(regions, h)
}

// HelperUnderProtected names the protected entry that would mask the
// helper binary, or "" when none does. Stage 2 is the helper re-executed
// inside the jail, so a mask covering it produces a jail that cannot
// start, and bwrap's report for that is `execvp failed` naming a path the
// payload never chose. The caller refuses the execution instead, naming
// the entry that caused it.
//
// The protected paths must already be resolved through their symlinks,
// which is the same input MountPlan is given; see resolveProtected.
func HelperUnderProtected(protected []string, helper string) string {
	h := region(helper)
	if h == "" {
		return ""
	}
	for _, prot := range sortedPaths(protected) {
		if coveredBy([]string{prot}, h) {
			return prot
		}
	}
	return ""
}

// readableRootOp binds one of the policy's own readable_roots read-only,
// tolerating its absence. See "Which path lists tolerate a missing
// path" below for why this list and no other gets the "-try" form.
func readableRootOp(path string) MountOp {
	path = region(path)
	return MountOp{Class: ClassReadable, Path: path,
		Argv: []string{"--ro-bind-try", path, path}}
}

// Which path lists tolerate a missing path (#60)
//
// bwrap's non-"-try" bind forms require the source to exist and refuse
// the whole jail outright when it does not — a bare `Can't bind mount
// SRC: No such file or directory` and exit 1, no different from the
// payload's own command failing. Four lists feed the mount plan, and the
// decision is not the same for all of them:
//
//   - **readable_roots tolerates absence** (`--ro-bind-try`, above).
//     These are broker- or tool-named paths that vary by host — an
//     optional toolchain root, a system directory only some platforms
//     carry — and losing one narrows what the jail can read, never what
//     it can write or leaves unprotected. That is the same judgment
//     `llock.Rules` already made for this exact list (`Optional: true`,
//     `IgnoreIfMissing()`), so the two layers now agree rather than one
//     refusing what the other shrugs at.
//   - **writable_roots does not** (`writableOp`, `--bind`, below). A
//     missing writable root silently narrowed would mean a tool believes
//     it has write access it does not — a correctness hazard worth a
//     loud failure, not a quiet one. The failure is loud in Loom's own
//     words rather than bwrap's: `MissingMountSources` (mounts.go) stats
//     the sources of the read-write binds up front and `run.go` refuses
//     before the argv exists, naming the path and the list (#63).
//   - **the host-path form of scratch does not**, for the same reason:
//     an operator who names a real directory as the jail's dedicated
//     scratch is asking for that directory specifically, and a silent
//     substitute (or none at all) is not what was asked for. It goes
//     through the same up-front refusal.
//   - **protected never tolerates absence, and never silently skips
//     either** — a mask that got skipped because its target does not
//     exist yet is the one outcome the feature exists to prevent. So a
//     `PathMissing` protected path always gets its mask op (`maskOp`,
//     unchanged); what changed is upstream of bwrap entirely.
//     `UnmountableProtected` (mounts.go) catches the one shape that mask
//     cannot itself satisfy — a parent bwrap has no write access to
//     create the mount point under — and `run.go` refuses the policy
//     before bwrap ever runs, naming the path and the reason. `~/.ssh`,
//     a default protected path, hits exactly this on any policy that
//     does not also grant write under $HOME, which is the ordinary case,
//     not an edge one.

// mountOp renders one explicit `mounts` entry.
//
// The "-try" form is the difference `required` makes to bwrap itself. An
// optional mount whose source is absent is skipped and the jail still
// starts; a required one has no "-try", so even if the up-front stat in
// MissingRequiredMounts were somehow passed, bwrap refuses rather than
// running a jail the caller believes carries the path.
func mountOp(m policy.Mount) MountOp {
	path := region(m.Path)
	flag := "--bind"
	class := ClassMountReadWrite
	if m.Access == policy.MountReadOnly {
		flag = "--ro-bind"
		class = ClassMountReadOnly
	}
	if !m.Required {
		flag += "-try"
	}
	return MountOp{Class: class, Path: path, Argv: []string{flag, path, path}}
}

func writableOp(path string) MountOp {
	path = region(path)
	return MountOp{Class: ClassWritable, Path: path,
		Argv: []string{"--bind", path, path}}
}

// region is the canonical name of the area a mount op governs. Both
// precedence rules compare regions as strings — the tie rule for
// equality, the specificity rule for the prefix relation — so "/work"
// and "/work/" have to be the same region or a policy that spells the
// workspace both ways gets two grants and the wrong one wins.
func region(path string) string {
	if path == "" {
		return ""
	}
	return filepath.Clean(path)
}

// maskOp shadows one protected path. See BwrapArgs, "Masking".
func maskOp(path string, kind PathKind) MountOp {
	if kind == PathFile {
		return MountOp{Class: ClassProtected, Path: path,
			Argv: []string{"--ro-bind", MaskSource, path}}
	}
	return MountOp{Class: ClassProtected, Path: path,
		Argv: []string{"--tmpfs", path, "--remount-ro", path}}
}

// coveredBy reports whether path lies at or inside one of roots.
func coveredBy(roots []string, path string) bool {
	for _, root := range roots {
		if path == root || strings.HasPrefix(path, strings.TrimSuffix(root, "/")+"/") {
			return true
		}
	}
	return false
}

func sortedPaths(in []string) []string {
	out := make([]string, 0, len(in))
	for _, p := range in {
		out = append(out, region(p))
	}
	sort.Strings(out)
	return out
}
