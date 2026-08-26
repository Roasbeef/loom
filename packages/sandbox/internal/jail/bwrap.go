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
//     tie is load-bearing and must resolve to writable. No narrowing is
//     lost by that: `readable_roots` does not restrict reads at all,
//     since the base view is the whole host filesystem read-only, so an
//     entry that is also writable is redundant rather than a
//     restriction (protocol-change/004).
//   - **The scratch tmpfs beats a root at exactly ScratchMount.**
//     Taking the bind instead would drop the scratch area the policy
//     asked for, and the fresh tmpfs is the narrower of the two anyway
//     — it carries no host content — so this tie resolves fail-closed.
//
// The base view, the entire host filesystem read-only, is simply the
// least specific readable grant: `/`. It obeys both rules like anything
// else.
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
func BwrapArgs(p policy.Policy, kinds map[string]PathKind) []string {
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
	for _, op := range MountPlan(p, kinds) {
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
	// ClassReadable binds a region read-only.
	ClassReadable MountClass = iota
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
)

// IsMask reports whether operations of this class subtract from the
// jail's view rather than widen it. Nothing may be emitted after one.
func (c MountClass) IsMask() bool { return c >= ClassProc }

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
func MountPlan(p policy.Policy, kinds map[string]PathKind) []MountOp {
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
	// The base view: the entire host filesystem, read-only. It is the
	// least specific readable grant and nothing more.
	grant(readableOp("/"))
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

	// Rule 1 then rule 2: masks after grants, and within each phase a
	// parent before every descendant of it.
	sort.SliceStable(plan, func(i, j int) bool {
		if a, b := plan[i].Class.IsMask(), plan[j].Class.IsMask(); a != b {
			return b
		}
		if plan[i].Path != plan[j].Path {
			return plan[i].Path < plan[j].Path
		}
		return plan[i].Class < plan[j].Class
	})
	return plan
}

// readableOp binds path read-only, refusing the jail outright if path
// does not exist. Used only for the base view ("/"), which is exempt
// from the tolerance question below by construction — the root always
// exists.
func readableOp(path string) MountOp {
	path = region(path)
	return MountOp{Class: ClassReadable, Path: path,
		Argv: []string{"--ro-bind", path, path}}
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
//     loud failure, not a quiet one. It still fails as a bare bwrap
//     exit 1 today; giving it the same up-front, path-naming refusal as
//     `protected` below is a follow-up, not done here.
//   - **the host-path form of scratch does not**, for the same reason:
//     an operator who names a real directory as the jail's dedicated
//     scratch is asking for that directory specifically, and a silent
//     substitute (or none at all) is not what was asked for. Also an
//     open follow-up rather than fixed here.
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
