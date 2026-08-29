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

; The filesystem is host-visible but read-only except for explicit roots.
(allow file-read*)
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

// SeatbeltPlan is the generated profile and its audit data. Profile paths are
// passed as sandbox-exec parameters rather than interpolated into SBPL.
type SeatbeltPlan struct {
	Profile     string
	Definitions []string
	Writable    int
	Protected   int
	Scratch     string
	Digest      string
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
		fmt.Sprintf("seatbelt-fs:rw=%d,mask=%d,scratch=%s,plan=%s",
			p.Writable, p.Protected, p.Scratch, p.Digest),
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
func SeatbeltPlanFor(pol policy.Policy, scratchPath string) SeatbeltPlan {
	writable := normalizedSeatbeltPaths(pol.WritableRoots)
	if scratchPath != "" {
		writable = append(writable, normalizeSeatbeltPath(scratchPath))
	} else if !pol.ScratchIsTmpfs() {
		writable = append(writable, normalizeSeatbeltPath(pol.Scratch))
	}
	writable = uniqueSorted(writable)

	protected := protectedSeatbeltPaths(pol.Protected)
	definitions := make([]string, 0, len(writable)+len(protected))
	sections := []string{seatbeltBaseProfile}
	for i, path := range writable {
		key := fmt.Sprintf("WRITABLE_ROOT_%d", i)
		definitions = append(definitions, key+"="+path)
		sections = append(sections, fmt.Sprintf(
			"(allow file-write* (subpath (param %q)))", key))
	}
	if pol.Network.Mode == policy.NetworkFull {
		sections = append(sections, seatbeltFullNetworkProfile)
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
		Scratch:     scratch,
		Digest:      digest,
	}
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
