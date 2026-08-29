// Package llock derives Landlock rules from a sandbox policy and applies
// them to the current process.
//
// Landlock is the *second* filesystem layer, behind bwrap's mount-level
// view. It matters twice over: in degraded mode (no bwrap) it is the only
// filesystem confinement, and even under bwrap it survives tricks that
// operate within the mount namespace. One honest limitation, stated here
// so nobody assumes otherwise: Landlock has no deny rules, so a protected
// path *inside* a writable root cannot be carved out at this layer —
// masking protected paths is bwrap's job (tmpfs/ro-bind shadowing). The
// broker learns from the enforcement report whether the bwrap layer ran.
//
// Like seccomp filters, Landlock domains persist across execve and stack
// (a child can only tighten, never loosen), so restrict-then-exec is
// sound.
package llock

import (
	"fmt"
	"sort"

	"github.com/landlock-lsm/go-landlock/landlock"
	llsys "github.com/landlock-lsm/go-landlock/landlock/syscall"
)

// Access is the coarse access class a rule grants.
type Access string

const (
	// ReadOnly grants read/execute on a directory tree.
	ReadOnly Access = "ro"
	// ReadWrite grants full file access on a directory tree.
	ReadWrite Access = "rw"
)

// Rule is one path grant. The set of rules is a pure, deterministic
// function of the policy so it can be unit-tested without a kernel.
type Rule struct {
	Path   string
	Access Access
	// File selects a file rule instead of a recursive directory rule.
	File bool
	// Optional marks paths whose absence is tolerated (a writable root
	// that does not exist yet is the broker's business, not a reason to
	// refuse the whole jail).
	Optional bool
}

// PolicyView is the subset of the sandbox policy Landlock consumes.
// Defined here to keep this package free of a dependency on the policy
// package's full type (and trivially constructible in tests).
type PolicyView struct {
	WritableRoots []string
	ReadableRoots []string
	// WritableFiles grants write access to individual files without
	// widening their containing directories.
	WritableFiles []string
	// ScratchPath is the scratch directory when it is a host path; empty
	// when scratch is a tmpfs (which only bwrap can provide — in degraded
	// mode there is no scratch mount, and the report says so).
	ScratchPath string
}

// Rules computes the Landlock grant set: read on the entire filesystem
// root plus explicit readable roots (harmless duplicates are fine —
// Landlock grants union), write only on writable roots, explicitly named
// writable files, and a path-backed scratch. Everything not granted is
// denied by the ruleset's handled access mask.
func Rules(p PolicyView) []Rule {
	var rules []Rule
	// The jailed process may read everything it can see: under bwrap the
	// visible tree is already the policy's view; degraded mode matches
	// the bwrap baseline of a read-only "/".
	rules = append(rules, Rule{Path: "/", Access: ReadOnly})
	for _, r := range sorted(p.ReadableRoots) {
		rules = append(rules, Rule{Path: r, Access: ReadOnly, Optional: true})
	}
	for _, w := range sorted(p.WritableRoots) {
		rules = append(rules, Rule{Path: w, Access: ReadWrite, Optional: true})
	}
	for _, w := range sorted(p.WritableFiles) {
		rules = append(rules, Rule{Path: w, Access: ReadWrite, File: true})
	}
	if p.ScratchPath != "" {
		rules = append(rules, Rule{Path: p.ScratchPath, Access: ReadWrite, Optional: true})
	}
	return rules
}

// ABIVersion probes the kernel's Landlock ABI without creating a
// ruleset. Returns 0 with a reason when Landlock is unavailable.
func ABIVersion() (int, string) {
	v, err := llsys.LandlockGetABIVersion()
	if err != nil {
		return 0, fmt.Sprintf("landlock unavailable: %v", err)
	}
	return v, ""
}

// Apply enforces the rule set on the current process. It uses the
// highest ABI go-landlock knows, downgrading on older kernels
// (BestEffort); the caller reports the *probed* ABI version so a
// downgrade is visible rather than silent. Callers must check
// ABIVersion() > 0 first; applying on a Landlock-less kernel is a no-op
// BestEffort would hide.
func Apply(rules []Rule) error {
	var opts []landlock.Rule
	for _, r := range rules {
		var fr landlock.FSRule
		switch r.Access {
		case ReadOnly:
			fr = landlock.RODirs(r.Path)
		case ReadWrite:
			if r.File {
				fr = landlock.RWFiles(r.Path)
			} else {
				fr = landlock.RWDirs(r.Path)
			}
		default:
			return fmt.Errorf("llock: unknown access %q", r.Access)
		}
		if r.Optional {
			fr = fr.IgnoreIfMissing()
		}
		opts = append(opts, fr)
	}
	if err := landlock.V5.BestEffort().RestrictPaths(opts...); err != nil {
		return fmt.Errorf("llock: restrict: %w", err)
	}
	return nil
}

func sorted(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}
