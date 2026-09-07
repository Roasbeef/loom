package jail

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
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
// the helper's own inherited PATH plus jailedPathDefaults. FilterEnv,
// above, scrubs the payload environment to keep the operator's secrets
// (API keys, tokens) out of the jail; a directory list is not a secret,
// so PATH is *built* here rather than dropped to a fixed constant.
// Without it a jailed `bash` cannot find `rg`, `go`, or `node` on a host
// where the toolchain lives outside `/usr/local/bin` — Homebrew's
// `/opt/homebrew/bin` on the repository owner's own machine — even
// though the jail's filesystem view already exposes those directories
// read-only (bwrap's `--ro-bind / /` on Linux, the Seatbelt profile's
// grants of `/usr` and `/opt` on macOS).
//
// Each entry of inherited survives only if it is an absolute path,
// names a directory that exists right now, has not already been added,
// and does not lie under one of writableRoots. That last exclusion is
// load-bearing rather than cosmetic: a directory the model can write to
// — the workspace, a host-backed scratch area — sitting on the
// inherited PATH would let a jailed command shadow `rg` with a script
// the model wrote a moment earlier, a tool-substitution attack the
// read-only filesystem view does nothing to stop. jailedPathDefaults is
// exempt from that check: it names fixed system directories no policy
// ever marks writable.
func BuildPath(inherited string, writableRoots []string) []string {
	seen := make(map[string]bool)
	out := make([]string, 0, len(jailedPathDefaults))

	add := func(dir string) {
		if dir == "" || seen[dir] {
			return
		}
		seen[dir] = true
		out = append(out, dir)
	}

	for _, dir := range strings.Split(inherited, string(os.PathListSeparator)) {
		if dir == "" || !filepath.IsAbs(dir) {
			continue
		}
		if coveredBy(writableRoots, dir) {
			continue
		}
		info, err := os.Stat(dir)
		if err != nil || !info.IsDir() {
			continue
		}
		add(dir)
	}

	for _, dir := range jailedPathDefaults {
		add(dir)
	}
	return out
}
