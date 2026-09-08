package jail

import (
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/roasbeef/loom/sandbox/internal/policy"
)

// FilterEnv builds the jailed process's environment from the broker's
// requested env and the policy's allowlist. The environment is
// *constructed*, never inherited (design §5.2: secrets live only in
// ProviderGateway memory; tool environments are allowlist-built): a name
// absent from env_allow is dropped even if the broker sent it, so a
// policy alone is enough to audit what a jail could see. Deterministic
// (sorted) for tests and reproducibility.
func FilterEnv(requested map[string]string, allow []string) []string {
	allowed := make(map[string]bool, len(allow))
	for _, name := range allow {
		allowed[name] = true
	}
	names := make([]string, 0, len(requested))
	for name := range requested {
		if allowed[name] {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	out := make([]string, 0, len(names))
	for _, name := range names {
		out = append(out, name+"="+requested[name])
	}
	return out
}

// jailedPathDefaults is the floor every jailed PATH carries, appended
// after whatever the helper's own inherited PATH still offers. It is
// today's whole PATH kept as a fallback rather than the only source, so
// a jail never loses the base system directories even when the daemon
// that spawned the helper had an empty, relative-only, or entirely
// hostile PATH of its own.
var jailedPathDefaults = []string{"/usr/local/bin", "/usr/bin", "/bin"}

// BuildPath builds the directory list for the jailed process's PATH from
// the broker's requested PATH, the helper's own inherited PATH, and
// jailedPathDefaults, in that order. FilterEnv, above, scrubs the
// payload environment to keep the operator's secrets (API keys, tokens)
// out of the jail; a directory list is not a secret, so PATH is *built*
// here rather than dropped to a fixed constant. Without the inherited
// half a jailed `bash` cannot find `rg`, `go`, or `node` on a host where
// the toolchain lives outside `/usr/local/bin` — Homebrew's
// `/opt/homebrew/bin` on the repository owner's own machine — even
// though the jail's filesystem view already exposes those directories
// read-only (bwrap's `--ro-bind / /` on Linux, the Seatbelt profile's
// grants of `/usr` and `/opt` on macOS).
//
// The requested list leads because it is the only half that can name a
// directory the caller knows about and the daemon's own PATH does not.
// An unpacked release ships its `erl` at `erts-<vsn>/bin/erl` and its
// `gleam` beside it, neither of them ever on the operator's PATH; the
// client discovers those directories and sends them as the request's
// PATH, so overwriting the request would leave code mode registered but
// unable to build. Ordering them first also settles the weaker case:
// on a host that does have a system OTP, the toolchain the satellite's
// beams were compiled against wins over the one that happens to be
// installed. Folding the request in is safe because the broker's
// environment is harness-authored — the client builds it from its own
// discovery — never model-authored, so a model still cannot influence
// PATH resolution.
//
// Each entry of either list survives only if it is an absolute path,
// names a directory that exists right now, has not already been added,
// and does not lie under one of writableRoots. That last exclusion is
// load-bearing rather than cosmetic: a directory the model can write to
// — the workspace, a host-backed scratch area, the scratch tmpfs the
// jail mounts over `/tmp` — sitting on either PATH would let a jailed
// command shadow `rg` with a script the model wrote a moment earlier, a
// tool-substitution attack the read-only filesystem view does nothing to
// stop. Entries are cleaned before that test so `/work/.` and `/work/bin`
// are judged against the same spelling of the root.
// jailedPathDefaults is exempt from the check: it names fixed system
// directories no policy ever marks writable.
func BuildPath(requested, inherited string, writableRoots []string) []string {
	seen := make(map[string]bool)
	out := make([]string, 0, len(jailedPathDefaults))

	add := func(dir string) {
		if dir == "" || seen[dir] {
			return
		}
		seen[dir] = true
		out = append(out, dir)
	}

	// The two candidate lists are filtered identically; only their order
	// differs, and the order is what makes a discovered toolchain beat a
	// system one of the same name.
	addCandidates := func(list string) {
		for _, dir := range strings.Split(list, string(os.PathListSeparator)) {
			if dir == "" || !filepath.IsAbs(dir) {
				continue
			}
			dir = filepath.Clean(dir)
			if coveredBy(writableRoots, dir) {
				continue
			}
			info, err := os.Stat(dir)
			if err != nil || !info.IsDir() {
				continue
			}
			add(dir)
		}
	}

	addCandidates(requested)
	addCandidates(inherited)

	for _, dir := range jailedPathDefaults {
		add(dir)
	}
	return out
}

// pathExcludedRoots names every directory a jailed process can write to,
// as the PATH filter needs to see them: the policy's own writable roots
// plus the ones the sandbox grants on its own behalf. Reading the policy
// alone would miss those, and missing one is exactly the tool-substitution
// hole BuildPath's exclusion exists to close.
//
// Two come from the platform rather than the policy. On Linux a tmpfs
// scratch is mounted at ScratchMount, so inside the jail `/tmp` is the
// model's own writable tmpfs whatever it was on the host: a daemon PATH
// entry of `/tmp/tools` — a `mktemp -d` install, or a CI runner's layout
// — would resolve there. On macOS the Seatbelt profile grants
// `file-write*` over DarwinUserDirectories(), which is where `$TMPDIR`
// points, so a PATH entry beneath it is writable for the same reason.
// The goos argument rather than runtime.GOOS keeps the mapping testable
// from either host.
func pathExcludedRoots(pol policy.Policy, goos string) []string {
	roots := make([]string, 0, len(pol.WritableRoots)+3)
	roots = append(roots, pol.WritableRoots...)

	// A host-backed scratch is a real directory the policy names; a tmpfs
	// scratch has no host path to exclude, only its mount point.
	if !pol.ScratchIsTmpfs() {
		roots = append(roots, pol.Scratch)
	} else if goos == "linux" {
		roots = append(roots, ScratchMount)
	}

	if goos == "darwin" {
		roots = append(roots, DarwinUserDirectories()...)
	}

	cleaned := make([]string, 0, len(roots))
	for _, root := range roots {
		if root == "" {
			continue
		}
		cleaned = append(cleaned, filepath.Clean(root))
	}
	return cleaned
}
