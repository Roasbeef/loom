package jail

// What the mount layer says about itself, and why it has to say
// anything at all.
//
// Every other layer of the jail reports on the same terms: an applied
// tag, or a `skip:` entry carrying a reason. The mount layer had exactly
// one token, `bwrap`, and it meant "bubblewrap ran" — never "the
// policy's paths were narrowed as asked". That is why a scratch bind
// that re-exposed the host read-write, a readable root that was silently
// writable, and a protected mask that a later bind undid all reported
// `[bwrap …]` with no skip and satisfied a full-enforcement demand
// (issues #51, #54).
//
// # What is reported, and why counts rather than a digest
//
// The plan bwrap is handed is an ordered list of mount operations
// (`MountPlan`), and every defect in that class is an *ordering* defect:
// the operations are all present, and a later one puts back what an
// earlier one took away. So the report is not a count of the operations
// requested — that number is identical in the healthy and the defeated
// plan — but a count of the policy's own paths whose **effective view,
// after replaying the whole ordered plan, is the one the policy asked
// for**:
//
//	mounts:ro=2,rw=1,mask=3,bind_ro=1,bind_rw=0,scratch=tmpfs,base=minimal,plan=1f4a09c8b2d3e6f7
//
// `bind_ro` and `bind_rw` are the same measurement for the policy's
// explicit `mounts` entries: how many of them the replayed plan leaves
// bound at the access they asked for. The broker holds the mount list it
// sent, so a shortfall is checkable against it.
//
// A mask that a later `--bind /work /work` defeats drops `mask` below
// the number of protected paths and emits `skip:mounts: …` naming the
// path and the operation that re-exposed it. A readable root turned
// writable does the same. The broker holds the policy it sent, so those
// counts are checkable against it rather than merely descriptive — which
// a digest is not: a digest detects *change*, and nobody holds the
// expected value to compare it against. The digest is carried anyway, as
// the cheap half: it lets two runs' plans be told apart at a glance, and
// it is what a golden test pins.
//
// # What this does not claim
//
// The audit is a replay of the plan the helper composed, so it proves
// the *plan* narrows what the policy named. It does not by itself prove
// bwrap executed the plan. That half is the stage-2 witness: the
// enforcement report on fd 4 can only arrive from a process bubblewrap
// built the namespace for and exec'd inside it, so run.go emits `bwrap`
// and these entries only when that report arrived. A stage 2 that dies
// first produces `skip:` entries instead of silence.
//
// Proving the *resulting view* rather than the plan would mean probing
// from inside stage 2 (statfs/faccessat per path), which is a separate
// piece of work: access checks are unreliable for uid 0, which is the
// common case inside a bwrap user namespace.

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/roasbeef/loom/sandbox/internal/policy"
)

// MountSkipPrefix opens every mount skip entry, so a reader (and the
// self-test, and CI) can recognise the layer without matching a reason
// that varies by policy.
const MountSkipPrefix = "mounts"

// MountReport is the mount layer's contribution to the per-exec
// enforcement summary: one applied entry stating what the resolved plan
// achieves for the policy's own paths, plus one skip per path the plan
// leaves wider than the policy asked for.
type MountReport struct {
	// Applied is the `mounts:…` entry, empty when no plan was audited.
	Applied string
	// Skipped carries the reasons, without the `skip:` prefix the
	// enforcement list adds.
	Skipped []string
}

// view is the effective state of one path after the whole plan: which
// operation last covered it, and what that operation does to the region.
type view struct {
	op MountOp
	// present is false when no operation covers the path at all, which
	// cannot happen for a plan carrying its base `--ro-bind / /` and is
	// treated as "not narrowed as asked" rather than assumed benign.
	present bool
}

// writable reports whether the region the view describes permits writes.
func (v view) writable() bool {
	switch v.op.Class {
	case ClassWritable, ClassScratchTmpfs, ClassMountReadWrite, ClassRootTmpfs:
		return true
	}
	return false
}

// The root tmpfs counts as writable here, and that is a statement about
// the jail rather than about the host. bwrap mounts a tmpfs read-write,
// so a region the minimal base view leaves uncovered is a writable
// directory *inside the jail* holding nothing — which is precisely what
// UnmountableProtected needs to know, because a mask for a path that
// does not exist yet needs its mount point created, and under the tmpfs
// bwrap can create it. Reporting it as read-only would make the helper
// refuse policies bwrap would have realised without complaint.

// masked reports whether the host's contents at the region are hidden —
// a tmpfs shadow, a fresh procfs, a minimal device tree, a protected
// path's mask.
func (v view) masked() bool {
	return v.op.Class.IsMask() || v.op.Class == ClassScratchTmpfs ||
		v.op.Class == ClassRootTmpfs
}

// describe renders the operation for a skip reason: the argv fragment
// bwrap was handed, which is the actionable half.
func (v view) describe() string {
	if !v.present {
		return "no mount operation at all"
	}

	// The root entry has no argv of its own; bwrap's new root is the
	// tmpfs, and naming it is more use to a reader than empty backticks.
	if len(v.op.Argv) == 0 {
		return "the jail's own root tmpfs"
	}
	return "`" + strings.Join(v.op.Argv, " ") + "`"
}

// AuditMounts replays the ordered mount plan and reports what it
// achieves for the policy's paths. Take the plan from MountPlan, which
// is the same value BwrapArgs renders into the argv — auditing the
// rendered argv instead would only re-derive it and could drift.
func AuditMounts(p policy.Policy, plan []MountOp) MountReport {
	if len(plan) == 0 {
		return MountReport{}
	}
	var rep MountReport

	ro := 0
	for _, r := range p.ReadableRoots {
		v := effective(plan, r)
		// A readable root the policy *also* names as writable (or nests
		// inside one it does) is writable because the policy said so:
		// the two lists are grants and their union is what was asked
		// for. Only a write the policy never granted is a widening.
		if v.writable() && !coveredBy(p.WritableRoots, r) {
			rep.Skipped = append(rep.Skipped, widened(
				"readable root", r, "is writable", v))
			continue
		}
		ro++
	}

	rw := 0
	for _, w := range p.WritableRoots {
		// A writable root the plan leaves unwritable is the fail-closed
		// direction: narrower than asked, never wider, so it is counted
		// out but is not a confinement skip. The counts carry it, and
		// the broker can see the shortfall against its own policy.
		if v := effective(plan, w); v.writable() && !v.masked() {
			rw++
		}
	}

	mask := 0
	for _, prot := range p.Protected {
		v := effective(plan, prot)
		switch {
		case v.writable():
			rep.Skipped = append(rep.Skipped, widened(
				"protected path", prot, "is writable", v))
		case !v.masked():
			rep.Skipped = append(rep.Skipped, widened(
				"protected path", prot, "is readable (its mask was undone)", v))
		default:
			mask++
		}
	}

	// The explicit mounts. A mount the plan leaves at a weaker access
	// than asked is narrower, not wider, so it is counted out without a
	// skip, exactly as a writable root that did not survive is. There is
	// no widening to report at all: the only way a read-only mount came
	// out writable was a policy naming the same region twice or naming a
	// region a protected entry also names, and the decoder on both sides
	// of the wire now refuses both.
	bindRO, bindRW := 0, 0
	for _, m := range p.Mounts {
		switch effective(plan, m.Path).op.Class {
		case ClassMountReadOnly:
			bindRO++
		case ClassMountReadWrite:
			bindRW++
		}
	}

	scratch := "bind"
	if p.ScratchIsTmpfs() {
		scratch = "tmpfs"
		if v := effective(plan, ScratchMount); v.op.Class != ClassScratchTmpfs {
			rep.Skipped = append(rep.Skipped, widened(
				"tmpfs scratch", ScratchMount,
				"is not the fresh tmpfs the policy asked for", v))
		}
	}

	// `base=` says which of the two base views the plan was built on, so
	// a reader of the enforcement report can tell a jail whose root is an
	// empty tmpfs from one whose root is a read-only bind of the whole
	// host. The counts cannot: both views produce the same numbers for
	// the same policy, and the difference between them is everything the
	// policy did *not* name.
	rep.Applied = fmt.Sprintf(
		"mounts:ro=%d,rw=%d,mask=%d,bind_ro=%d,bind_rw=%d,scratch=%s,base=%s,plan=%s",
		ro, rw, mask, bindRO, bindRW, scratch,
		BaseViewName(p.ReadableRoots), planDigest(plan))
	return rep
}

// UnmountableProtected reports every PathMissing protected path bwrap
// cannot actually mask: creating the mount point needs write access to
// the parent directory, and the plan leaves that parent read-only (the
// default of everything not otherwise granted). bwrap's own failure for
// this shape is a bare `Can't mkdir parents for PATH: Read-only file
// system` and exit 1 — indistinguishable from the payload's own command
// failing (#60). run.go calls this before ever building the argv, so the
// caller gets a refusal that names the path instead.
//
// A path that already exists needs no mount point created for it — its
// mask binds onto it (a file) or remounts it (a directory), never
// creates it — so only PathMissing entries are checked; see PathKind.
func UnmountableProtected(kinds map[string]PathKind, plan []MountOp) []string {
	var bad []string
	for path, kind := range kinds {
		if kind != PathMissing {
			continue
		}
		parent := filepath.Dir(clean(path))
		if !effective(plan, parent).writable() {
			bad = append(bad, path)
		}
	}
	sort.Strings(bad)
	return bad
}

// MissingMountSources names every path the plan binds read-write whose
// source is not there to bind from: a `writable_roots` entry, or the
// host-path form of `scratch`. Both render as `--bind`, which requires
// the source to exist, so one absent path makes bubblewrap refuse the
// whole jail with a bare `Can't bind mount SRC: No such file or
// directory` and exit 1 — indistinguishable from the payload's own
// command failing (#63). run.go calls this before ever building the
// argv, so the caller gets a refusal naming the path and the list it
// came from instead.
//
// Refusing is the decision, not the defect. Neither list tolerates
// absence on purpose: a tool that believes it has write access it does
// not have is a correctness hazard, and narrowing the jail in silence is
// the quiet failure the design forbids. Only the diagnosis was missing.
// See "Which path lists tolerate a missing path" in bwrap.go for why the
// other two lists answer differently — `readable_roots` binds with
// `--ro-bind-try` and shrugs, and `protected` is *allowed* to name a
// path that does not exist, which is why its own pre-dispatch check
// (UnmountableProtected, above) asks whether the mask can be created
// rather than whether the path is there.
//
// Any stat failure counts, not just ENOENT. A source the helper cannot
// stat is one bwrap cannot bind either — it resolves the source before
// it unshares, under this same uid — so a mode-700 parent gets the same
// named refusal rather than the anonymous exit 1, and the entry carries
// the kernel's own reason to tell the two apart.
func MissingMountSources(p policy.Policy) []string {
	var bad []string

	// MountPlan binds the canonical region rather than the policy's
	// spelling of it, so stat exactly the path bwrap will be handed.
	// An empty path is dropped by MountPlan's `grant` and names nothing
	// a reader could act on, so it is not this check's failure to
	// report.
	check := func(list, path string) {
		src := region(path)
		if src == "" {
			return
		}
		if _, err := os.Stat(src); err != nil {
			bad = append(bad, fmt.Sprintf("%s: %s (%s)", list, src,
				statReason(err)))
		}
	}

	for _, w := range p.WritableRoots {
		check("writable_roots", w)
	}

	// The tmpfs form of scratch mounts a fresh filesystem and has no
	// host source at all; only the host-path form can be missing.
	if !p.ScratchIsTmpfs() {
		check("scratch", p.Scratch)
	}

	return bad
}

// MissingRequiredMounts names every `mounts` entry marked required whose
// source is not on this host. A required mount is the sender saying the
// execution is pointless without that path — the cap socket is the
// motivating case — so the helper refuses before any jail starts rather
// than running one the caller believes carries it.
//
// This is the platform-independent half of the mount checks: unlike
// MissingMountSources, which diagnoses a bwrap argv that would fail
// anonymously, the required-mount refusal is a property of the policy and
// holds on Darwin, where there is no bind mount at all. An optional
// mount whose source is absent is skipped in silence, which is what
// bwrap's "-try" forms do and what the Seatbelt profile does by emitting
// no rule for it.
//
// Any stat failure counts, not just ENOENT, for the same reason
// MissingMountSources counts them: a source the helper cannot stat is one
// no jail can bind either, and the entry carries the kernel's own reason
// so the two are told apart.
func MissingRequiredMounts(p policy.Policy) []string {
	var bad []string
	for _, m := range p.Mounts {
		if !m.Required {
			continue
		}
		src := region(m.Path)
		if src == "" {
			continue
		}
		if _, err := os.Stat(src); err != nil {
			bad = append(bad, fmt.Sprintf("mounts: %s (%s)", src,
				statReason(err)))
		}
	}
	return bad
}

// statReason renders why a stat failed with the path stripped off, so a
// rendered entry names the path once instead of twice.
func statReason(err error) string {
	var pathErr *fs.PathError
	if errors.As(err, &pathErr) {
		return pathErr.Err.Error()
	}
	return err.Error()
}

// widened renders one skip reason, naming both the path and the
// operation that left it wider than the policy asked for — the second
// half is what turns "something is wrong" into a fix.
func widened(kind, path, what string, v view) string {
	return fmt.Sprintf("%s: %s %s %s: %s is the last mount operation "+
		"covering it", MountSkipPrefix, kind, path, what, v.describe())
}

// effective replays the plan for one path: the last operation whose
// region is the path itself or an ancestor of it wins, because bwrap
// applies operations in argv order and a later mount over an ancestor
// covers everything beneath it.
func effective(plan []MountOp, path string) view {
	target := clean(path)
	for i := len(plan) - 1; i >= 0; i-- {
		if covers(clean(plan[i].Path), target) {
			return view{op: plan[i], present: true}
		}
	}
	return view{}
}

// covers reports whether a mount at mount is the path itself or one of
// its ancestors.
func covers(mount, path string) bool {
	if mount == path || mount == "/" {
		return true
	}
	return strings.HasPrefix(path, mount+"/")
}

func clean(p string) string { return filepath.Clean(p) }

// planDigest fingerprints the resolved plan: the ordered argv fragments,
// which is exactly the thing whose ordering is load-bearing. Sixteen hex
// digits is plenty to tell two plans apart in a log line, and this is a
// diffing aid, not a security check.
func planDigest(plan []MountOp) string {
	h := sha256.New()
	for _, op := range plan {
		fmt.Fprintf(h, "%s\n", strings.Join(op.Argv, " "))
	}
	return hex.EncodeToString(h.Sum(nil))[:16]
}
