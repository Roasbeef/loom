package jail

import (
	"crypto/sha256"
	"fmt"
	"path/filepath"
	"sort"
	"strings"

	"github.com/roasbeef/loom/sandbox/internal/policy"
)

// SeatbeltExecutable is the only sandbox-exec binary Loom will invoke. An
// absolute system path keeps a model-controlled PATH from selecting the jail.
const SeatbeltExecutable = "/usr/bin/sandbox-exec"

// SeatbeltUnwitnessedSkip is emitted when sandbox-exec was selected but stage
// 2 never proved that the profile admitted it far enough to report.
const SeatbeltUnwitnessedSkip = "seatbelt: stage 2 sent no enforcement report " +
	"on fd 4, so the generated filesystem and network profile cannot be " +
	"confirmed to have been applied"

const seatbeltBaseProfile = `(version 1)
(deny default)

; Children inherit the profile, and signals stay within this sandbox.
(allow process-exec)
(allow process-fork)
(allow signal (target same-sandbox))
(allow process-info* (target same-sandbox))

; Reads are an allowlist. The system view below and the policy's own
; regions are the only readable paths; everything else falls through to
; the deny-default at the top.
;
; The root directory itself is the one entry that has to be here rather
; than in the system view, and it is a read rather than a metadata read.
; Measured on macOS 15: with every system subpath allowed but "/" denied,
; /bin/sh aborts before it prints anything, with no diagnostic at all
; (exit 134, empty stderr) — path resolution walks the root and the deny
; ends the process rather than the open. Granting it exposes the names of
; the top-level directories, which are the same on every macOS install,
; and nothing under them.
(allow file-read* (literal "/"))
;
; And the three top-level symlinks into /private. Every profile path is
; normalized to its resolved form (/tmp becomes /private/tmp), but the
; paths a caller hands the payload are not: argv[0] can perfectly well be
; a /var/folders/... path, and resolving it reads the /var link itself.
; A denial there is reported as "execvp() ... Operation not permitted"
; for a binary the profile does grant, which is measurably confusing.
; Metadata on three known symlinks is what resolution needs and is all
; this grants.
(allow file-read-metadata (literal "/etc") (literal "/tmp") (literal "/var"))
(allow file-write-data
  (require-all
    (path "/dev/null")
    (vnode-type CHARACTER-DEVICE)))

; Runtime discovery needed by ordinary command-line toolchains.
(allow sysctl-read)
(allow sysctl-write (sysctl-name "kern.grade_cputype"))
(allow iokit-open (iokit-registry-entry-class "RootDomainUserClient"))
(allow ipc-posix-sem)
(allow mach-lookup
  (global-name "com.apple.PowerManagement.control")
  (global-name "com.apple.bsd.dirhelper")
  (global-name "com.apple.system.opendirectoryd.libinfo")
  (global-name "com.apple.system.opendirectoryd.membership"))

; Network-off still permits filesystem-confined local capability sockets.
(allow system-socket (socket-domain AF_UNIX))
(allow network-bind (local unix-socket))
(allow network-outbound (remote unix-socket))
`

const seatbeltFullNetworkProfile = `
; Full network access is an explicit policy grant.
(allow network-bind)
(allow network-inbound)
(allow network-outbound)
(allow mach-lookup
  (global-name "com.apple.SecurityServer")
  (global-name "com.apple.SystemConfiguration.DNSConfiguration")
  (global-name "com.apple.SystemConfiguration.configd")
  (global-name "com.apple.networkd")
  (global-name "com.apple.ocspd")
  (global-name "com.apple.trustd.agent"))
`

// SeatbeltScratchParent is where the private per-execution scratch
// directory is created on macOS. It is deliberately not the helper's own
// TMPDIR: that is the user temp directory, which the profile grants to
// every execution (see DarwinUserDirectories), and a scratch made there
// would be writable by any concurrent jailed process rather than by the
// one it was made for. /private/tmp is granted to none of them, so a
// mode-0700 directory under it keeps the one-execution-one-scratch
// property the Linux tmpfs mount gives for free. The self-test probes use
// it for the same reason: a fixture under the user temp directory is no
// longer outside the jail.
const SeatbeltScratchParent = "/private/tmp"

// SeatbeltPlan is the generated profile and its audit data. Profile paths are
// passed as sandbox-exec parameters rather than interpolated into SBPL.
type SeatbeltPlan struct {
	Profile     string
	Definitions []string
	Writable    int
	Protected   int
	// BindRO and BindRW count the policy's explicit `mounts` entries the
	// profile emitted a rule for. Seatbelt has no mount namespace, so a
	// mount is a read (and, for "rw", a write) allow over the subpath
	// rather than a bind; the counts let the broker check the profile
	// against the mount list it sent.
	BindRO  int
	BindRW  int
	Scratch string

	// Base is "minimal" or "host-view": which of the two base views the
	// profile granted reads on. See BaseViewName.
	Base string

	Digest string
}

// Args wraps command in the system sandbox-exec binary.
func (p SeatbeltPlan) Args(command []string) []string {
	args := []string{SeatbeltExecutable, "-p", p.Profile}
	for _, definition := range p.Definitions {
		args = append(args, "-D"+definition)
	}
	args = append(args, "--")
	return append(args, command...)
}

// Enforcement returns the platform layers this plan applies. The caller may
// only publish them after stage 2 reports from inside the profile.
func (p SeatbeltPlan) Enforcement(network policy.NetworkMode) []string {
	out := []string{
		"seatbelt",
		fmt.Sprintf(
			"seatbelt-fs:rw=%d,mask=%d,bind_ro=%d,bind_rw=%d,scratch=%s,"+
				"base=%s,plan=%s",
			p.Writable, p.Protected, p.BindRO, p.BindRW, p.Scratch,
			p.Base, p.Digest),
	}
	if BlocksDirectNetwork(network) {
		out = append(out, "seatbelt-net")
	}
	return out
}

// SeatbeltPlanFor renders a deny-default profile from the frozen policy. A
// tmpfs scratch request maps to scratchPath, a fresh mode-0700 directory owned
// and removed by the supervising helper. Seatbelt has no mount namespace, so
// the private directory is the macOS equivalent rather than a claimed tmpfs.
// The user's own darwin temp and cache directories are granted alongside the
// policy's roots, because Apple's toolchain shims write there unasked.
func SeatbeltPlanFor(pol policy.Policy, scratchPath, helper string) SeatbeltPlan {
	writable := normalizedSeatbeltPaths(pol.WritableRoots)
	if scratchPath != "" {
		writable = append(writable, normalizeSeatbeltPath(scratchPath))
	} else if !pol.ScratchIsTmpfs() {
		writable = append(writable, normalizeSeatbeltPath(pol.Scratch))
	}

	// Apple's toolchain shims write caches to the user's own temp and
	// cache directories regardless of TMPDIR; see DarwinUserDirectories
	// for why those two are granted alongside the policy's roots.
	writable = append(writable, normalizedSeatbeltPaths(DarwinUserDirectories())...)
	writable = uniqueSorted(writable)

	protected := protectedSeatbeltPaths(pol.Protected)
	mounts := seatbeltMounts(pol.Mounts)
	definitions := make([]string, 0, len(writable)+len(protected)+len(mounts))
	sections := []string{seatbeltBaseProfile, seatbeltSystemView(pol)}

	// A writable root is readable too. Seatbelt's verbs are independent —
	// `file-write*` does not imply `file-read*` — so a workspace granted
	// only for writing would be a directory a build could create files in
	// and never read one back from.
	for i, path := range readableSeatbeltRoots(pol, writable, helper) {
		key := fmt.Sprintf("READABLE_ROOT_%d", i)
		definitions = append(definitions, key+"="+path)
		sections = append(sections, fmt.Sprintf(
			"(allow file-read* (subpath (param %q)))", key))
	}
	for i, path := range writable {
		key := fmt.Sprintf("WRITABLE_ROOT_%d", i)
		definitions = append(definitions, key+"="+path)
		sections = append(sections, fmt.Sprintf(
			"(allow file-write* (subpath (param %q)))", key))
	}
	if pol.Network.Mode == policy.NetworkFull {
		sections = append(sections, seatbeltFullNetworkProfile)
	}

	// The explicit mounts of protocol-change/004. Darwin has no mount
	// namespace, so the nearest thing to a bind is an allow rule over the
	// subpath: read for "ro", read and write for "rw". They are emitted
	// before the subtractive rules below, not after, because on Darwin
	// the last matching rule wins and the protected denies have to stay
	// final, which is what ADR-006 records: a protected path is
	// unreachable on Darwin whatever else the profile says. The two
	// platforms order a mount against the masks in opposite directions
	// and still enforce the same policy, because a mount overlapping a
	// protected entry is refused when the policy is decoded and no
	// profile built here can contain that pair.
	//
	// Since protocol-change/020 the read rule is the access rather than a
	// statement of intent: the base profile's unconditional
	// `(allow file-read*)` is gone, so a mount outside the system view
	// and outside the policy's roots is readable only because of this
	// rule.
	bindRO, bindRW := 0, 0
	for i, m := range mounts {
		key := fmt.Sprintf("MOUNT_%d", i)
		definitions = append(definitions, key+"="+m.path)
		sections = append(sections, fmt.Sprintf(
			"(allow file-read* (subpath (param %q)))", key))
		if m.access == policy.MountReadWrite {
			sections = append(sections, fmt.Sprintf(
				"(allow file-write* (subpath (param %q)))", key))
			bindRW++
			continue
		}
		bindRO++
	}

	// Subtractive rules are last. No later broad allow may reopen a protected
	// path or let a writable ancestor be renamed around its carveout.
	for i, path := range protected {
		key := fmt.Sprintf("PROTECTED_PATH_%d", i)
		definitions = append(definitions, key+"="+path)
		sections = append(sections,
			fmt.Sprintf("(deny file-read* (literal (param %q)))", key),
			fmt.Sprintf("(deny file-read* (subpath (param %q)))", key),
			fmt.Sprintf("(deny file-write* (literal (param %q)))", key),
			fmt.Sprintf("(deny file-write* (subpath (param %q)))", key),
		)
	}

	ancestors := protectedSeatbeltAncestors(writable, protected)
	for i, path := range ancestors {
		key := fmt.Sprintf("PROTECTED_ANCESTOR_%d", i)
		definitions = append(definitions, key+"="+path)
		sections = append(sections, fmt.Sprintf(
			"(deny file-write-unlink (require-all (vnode-type DIRECTORY) "+
				"(literal (param %q))))", key))
	}

	profile := strings.Join(sections, "\n") + "\n"
	digestInput := profile + "\x00" + strings.Join(definitions, "\x00")
	digest := fmt.Sprintf("%x", sha256.Sum256([]byte(digestInput)))[:16]
	scratch := "path"
	if pol.ScratchIsTmpfs() {
		scratch = "private-dir"
	}
	return SeatbeltPlan{
		Profile:     profile,
		Definitions: definitions,
		Writable:    len(writable),
		Protected:   len(protected),
		BindRO:      bindRO,
		BindRW:      bindRW,
		Scratch:     scratch,
		Base:        BaseViewName(pol.ReadableRoots),
		Digest:      digest,
	}
}

// seatbeltSystemView renders the read allows for the base system view.
//
// The paths are DarwinSystemRoots, a compile-time constant, so they are
// written into the profile directly rather than passed as `-D`
// parameters: the rule that model-influenced paths travel as parameters
// exists because SBPL has no escaping, and a constant carries no model
// input to escape.
//
// A policy naming "/" as a readable root gets the pre-020 view back, the
// same tie the Linux plan resolves in favour of the whole-host bind, so
// that a harness which still sends `readable_roots: ["/"]` is unchanged
// by the narrowing. That case is handled by readableSeatbeltRoots, which
// emits the subpath allow for "/" itself; this function then adds
// nothing the broader rule does not already cover, and says so in the
// profile so the two views are distinguishable by eye as well as by the
// `base=` field of the enforcement report.
func seatbeltSystemView(pol policy.Policy) string {
	var b strings.Builder
	if !PlanIsMinimal(pol.ReadableRoots) {
		b.WriteString("; base view: the whole host, from readable_roots \"/\".\n")
	} else {
		b.WriteString("; base view: the system directories a command needs to run.\n")
	}
	for _, root := range DarwinSystemRoots {
		fmt.Fprintf(&b, "(allow file-read* (subpath %q))\n", root)
	}
	return b.String()
}

// readableSeatbeltRoots is every region the profile grants reads on
// besides the system view: the policy's own readable roots, and the
// writable regions, which are readable because writing to a file one
// cannot read back is not what any caller means by a writable root.
//
// The explicit `mounts` are not here; each already emits its own read
// rule below, where its access decides whether a write rule joins it.
func readableSeatbeltRoots(pol policy.Policy, writable []string, helper string) []string {
	roots := normalizedSeatbeltPaths(pol.ReadableRoots)
	roots = append(roots, writable...)

	// The helper's own binary, for the reason the Linux plan binds it:
	// stage 2 is this executable re-executed inside the profile, and a
	// profile that cannot read it fails with sandbox-exec's own
	// `execvp() ... Operation not permitted` before the payload exists.
	// Where the helper was installed is the helper's knowledge, not the
	// sender's, so it is not a policy path.
	if helper != "" {
		roots = append(roots, normalizeSeatbeltPath(helper))
	}
	return uniqueSorted(roots)
}

// seatbeltMount is one explicit mount reduced to what the profile needs:
// the normalized path and the access. The requirement is not here,
// because whether a missing source refuses the execution is decided
// before the platform split (MissingRequiredMounts) and an optional
// absent path simply produces no rule.
type seatbeltMount struct {
	path   string
	access policy.MountAccess
}

// seatbeltMounts normalizes the mount list and orders it by path, so the
// profile and its digest do not depend on the order the sender happened
// to write. There is no tie to resolve: the decoder refuses a repeated
// mount path before the policy reaches either platform.
func seatbeltMounts(mounts []policy.Mount) []seatbeltMount {
	out := make([]seatbeltMount, 0, len(mounts))
	for _, m := range mounts {
		out = append(out, seatbeltMount{
			path:   normalizeSeatbeltPath(m.Path),
			access: m.Access,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].path < out[j].path })
	return out
}

func normalizedSeatbeltPaths(paths []string) []string {
	out := make([]string, 0, len(paths))
	for _, path := range paths {
		out = append(out, normalizeSeatbeltPath(path))
	}
	return out
}

// protectedSeatbeltPaths covers both the policy spelling and the resolved
// inode. The pair closes top-level aliases and symlinked credential paths.
func protectedSeatbeltPaths(paths []string) []string {
	out := make([]string, 0, len(paths)*2)
	for _, path := range paths {
		out = append(out, filepath.Clean(path), normalizeSeatbeltPath(path))
	}
	return uniqueSorted(out)
}

// normalizeSeatbeltPath resolves the deepest existing prefix, then restores
// any missing suffix. This also canonicalizes macOS aliases such as /tmp to
// /private/tmp without requiring the leaf to exist yet.
func normalizeSeatbeltPath(path string) string {
	clean := filepath.Clean(path)
	prefix := clean
	for {
		if resolved, err := filepath.EvalSymlinks(prefix); err == nil {
			rel, relErr := filepath.Rel(prefix, clean)
			if relErr == nil && rel != "." {
				return filepath.Clean(filepath.Join(resolved, rel))
			}
			return filepath.Clean(resolved)
		}
		parent := filepath.Dir(prefix)
		if parent == prefix {
			return clean
		}
		prefix = parent
	}
}

func protectedSeatbeltAncestors(writable, protected []string) []string {
	var out []string
	for _, protectedPath := range protected {
		for _, root := range writable {
			if !pathCovers(root, protectedPath) {
				continue
			}
			for ancestor := filepath.Dir(protectedPath); pathCovers(root, ancestor); ancestor = filepath.Dir(ancestor) {
				out = append(out, ancestor)
				if ancestor == root || ancestor == filepath.Dir(ancestor) {
					break
				}
			}
		}
	}
	// Writable roots are authority boundaries reused by later profiles. A
	// sandboxed process may modify their contents but not replace the roots.
	out = append(out, writable...)
	return uniqueSorted(out)
}

func pathCovers(root, path string) bool {
	root = filepath.Clean(root)
	path = filepath.Clean(path)
	return root == string(filepath.Separator) || root == path ||
		strings.HasPrefix(path, root+string(filepath.Separator))
}

func uniqueSorted(paths []string) []string {
	seen := make(map[string]struct{}, len(paths))
	out := make([]string, 0, len(paths))
	for _, path := range paths {
		if _, ok := seen[path]; ok {
			continue
		}
		seen[path] = struct{}{}
		out = append(out, path)
	}
	sort.Strings(out)
	return out
}
