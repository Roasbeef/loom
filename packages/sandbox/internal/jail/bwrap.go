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
	"sort"

	"github.com/roasbeef/loom/sandbox/internal/policy"
)

// PathKind classifies a protected path for masking purposes.
type PathKind int

const (
	// PathMissing: the path does not exist. It is still masked (with a
	// read-only tmpfs) so the jailed process cannot *create* it — a
	// protected ~/.ssh that does not exist yet must stay uncreatable.
	PathMissing PathKind = iota
	// PathFile: an existing regular file.
	PathFile
	// PathDir: an existing directory.
	PathDir
)

// ScratchMount is where a "tmpfs" scratch policy mounts inside the jail.
const ScratchMount = "/tmp"

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
// Ordering is load-bearing: bwrap applies mount operations in argv
// order, so protected-path masks must come after the writable binds that
// would otherwise re-expose them, and the scratch tmpfs after the
// read-only root it punches through. `kinds` classifies each protected
// path (callers stat outside this function to keep it pure).
//
// Masking choices: an existing protected *file* is bind-mounted onto
// itself read-only — unwritable, still readable (design §5.2 defaults
// keep e.g. .git internals readable). A protected *directory* (or a
// missing path) is shadowed with an empty read-only tmpfs — its contents
// are neither readable nor writable, and nothing can be created there.
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

	// The base view: the entire host filesystem, read-only, then fresh
	// /proc and a minimal /dev for the new namespaces.
	args = append(args, "--ro-bind", "/", "/", "--proc", "/proc", "--dev", "/dev")

	// Explicit read-only binds. Usually redundant with the ro root, but
	// kept explicit so a readable root nested inside a writable root is
	// re-masked read-only (binds are applied in argv order).
	for _, r := range sortedPaths(p.ReadableRoots) {
		args = append(args, "--ro-bind", r, r)
	}
	for _, w := range sortedPaths(p.WritableRoots) {
		args = append(args, "--bind", w, w)
	}

	// Protected masks come after writable binds so a protected path
	// inside a writable root is still masked.
	for _, prot := range sortedPaths(p.Protected) {
		if kinds[prot] == PathFile {
			args = append(args, "--ro-bind", prot, prot)
		} else {
			// Directory or missing: empty tmpfs, then remounted
			// read-only so nothing can be written into the shadow
			// either.
			args = append(args, "--tmpfs", prot, "--remount-ro", prot)
		}
	}

	if p.ScratchIsTmpfs() {
		args = append(args, "--tmpfs", ScratchMount)
	} else {
		args = append(args, "--bind", p.Scratch, p.Scratch)
	}

	return args
}

func sortedPaths(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}
