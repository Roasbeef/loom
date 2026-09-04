//go:build darwin

package jail

import (
	"os/exec"
	"strings"
	"sync"
)

// getconfExecutable is the only getconf Loom will run. An absolute system
// path keeps a model-controlled PATH from choosing what answers.
const getconfExecutable = "/usr/bin/getconf"

var (
	userDirectoriesOnce sync.Once
	userDirectories     []string
)

// DarwinUserDirectories returns the per-user temporary and cache
// directories macOS assigns this account — the `/var/folders/<x>/<y>/T`
// and `.../C` pair — as confstr(3) reports them through getconf(1). That
// is the only authoritative source: they are not derivable from $TMPDIR,
// which the policy environment overrides, and not stable across logins.
// getconf rather than cgo keeps the helper buildable with CGO_ENABLED=0,
// which Go selects on its own on a Mac with no C compiler; the answer is
// read once per helper process, since dirhelper caches it per login.
//
// They are Seatbelt writable roots because Apple's own command-line tools
// use them behind the caller's back. `/usr/bin/git`, `make` and `clang`
// are Xcode shims that run `xcrun`, and `xcrun` writes its lookup cache
// to the user temp directory whatever TMPDIR says; clang's module cache
// goes to the user cache directory. Under a profile that grants only the
// workspace, every `git status` in a jailed shell printed "couldn't
// create cache file ... Operation not permitted" to stderr — noise the
// model then tried to fix. Both directories are mode 0700 and hold only
// this user's caches and temporaries, so widening writes to them costs
// nothing the workspace grant had not already conceded; Codex's Seatbelt
// policy makes the same grant for the same reason.
//
// An empty result on a host where getconf fails leaves the profile as it
// was: narrower, and noisier, but never wider than asked.
func DarwinUserDirectories() []string {
	userDirectoriesOnce.Do(func() {
		for _, name := range []string{"DARWIN_USER_TEMP_DIR", "DARWIN_USER_CACHE_DIR"} {
			out, err := exec.Command(getconfExecutable, name).Output()
			dir := strings.TrimSpace(string(out))
			if err != nil || !strings.HasPrefix(dir, "/") {
				continue
			}
			userDirectories = append(userDirectories, dir)
		}
	})
	return userDirectories
}
