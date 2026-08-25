// Package cgroup translates policy limits into cgroup v2 file writes and
// applies them when a delegated cgroup v2 hierarchy is available.
//
// mem_bytes and pids limits need cgroups: RLIMIT_AS is per-process and
// trivially escaped by forking, and RLIMIT_NPROC is per-user (useless
// when the jail shares a uid, ignored entirely for root). The
// construction half is pure — policy in, {path, contents} pairs out — so
// the exact writes are unit-tested even inside containers that give us
// no v2 delegation (like this one, which mounts v1 controllers).
//
// # Where the base comes from
//
// cgroup v2's no-internal-process rule forbids a cgroup from having both
// member processes and controllers enabled for its children, so the
// helper's *own* cgroup — which always contains at least the helper — can
// never distribute memory and pids to per-exec children. That is not a
// property of cgroup v2 but of that choice of base: any delegated cgroup
// containing no processes distributes controllers to its children, which
// is precisely what delegation is for. The operator hands one over
// (systemd `Delegate=yes`, and on v254+ `DelegateSubgroup=`, which parks
// the service's own processes in a subgroup and leaves the delegated root
// empty), naming it in LOOM_CGROUP_BASE or `--cgroup-base`. Absent that,
// Detect falls back to the own-cgroup base, which works only in the true
// root cgroup, and says so rather than pretending.
package cgroup

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// FileWrite is one intended write into the cgroup filesystem.
type FileWrite struct {
	Path    string
	Content string
}

// LimitsView is the subset of policy limits cgroups enforce.
type LimitsView struct {
	MemBytes uint64
	Pids     uint64
}

// FileWrites computes the writes needed to configure dir as the child's
// cgroup. Zero-valued limits produce no write (the cgroup default is
// "max"). Deterministic order: memory.max, pids.max.
func FileWrites(dir string, l LimitsView) []FileWrite {
	var out []FileWrite
	if l.MemBytes > 0 {
		out = append(out, FileWrite{
			Path:    filepath.Join(dir, "memory.max"),
			Content: strconv.FormatUint(l.MemBytes, 10),
		})
	}
	if l.Pids > 0 {
		out = append(out, FileWrite{
			Path:    filepath.Join(dir, "pids.max"),
			Content: strconv.FormatUint(l.Pids, 10),
		})
	}
	return out
}

// BaseEnvVar names the delegated cgroup v2 base in the helper's
// environment. `--cgroup-base` on the command line overrides it; both
// exist because systemd units set environment and the broker sets
// arguments, and neither should have to translate for the other.
const BaseEnvVar = "LOOM_CGROUP_BASE"

// BaseFromEnv reads the operator-supplied base, empty when unset.
func BaseFromEnv() string { return strings.TrimSpace(os.Getenv(BaseEnvVar)) }

// Detect reports whether a writable, delegated cgroup v2 hierarchy with
// the memory and pids controllers is available, returning the directory
// under which per-exec cgroups can be created, or a human-readable
// reason why not. The base comes from the environment; see DetectBase.
func Detect() (dir string, reason string) { return DetectBase(BaseFromEnv()) }

// DetectBase is Detect with the configured base passed in, so both the
// delegated and the fallback path are reachable from a test.
//
// A non-empty configured base is the supported production shape and is
// checked strictly: it must be a cgroup v2 directory, it must have the
// memory and pids controllers available to it, and it must contain no
// processes — the last because cgroup v2 refuses to enable controllers
// for the children of a cgroup that has members, which is the whole
// reason the helper's own cgroup cannot serve. When those hold, the
// controllers are enabled in its `cgroup.subtree_control` (idempotently)
// so the per-exec children actually get `memory.max` and `pids.max`.
//
// With no configured base the helper falls back to its own cgroup, which
// satisfies the rule above only in the true root cgroup. Every failure
// returns a reason naming the fix rather than a bare "unavailable".
func DetectBase(configured string) (dir string, reason string) {
	if configured != "" {
		return delegatedBase(configured)
	}
	if reason := ownCgroupBase(); reason != "" {
		return "", reason + "; " + delegationHint
	}
	base, _ := ownCgroupPath()
	return base, ""
}

// ownCgroupPath resolves the helper's own cgroup directory, or ok=false
// when it is not in a unified hierarchy at all.
func ownCgroupPath() (string, bool) {
	self, err := os.ReadFile("/proc/self/cgroup")
	if err != nil {
		return "", false
	}
	own, ok := ownV2Path(string(self))
	if !ok {
		return "", false
	}
	return filepath.Join(unifiedRoot, own), true
}

// ownCgroupBase reports why the fallback base is unusable, or "" when
// it is. Split out so DetectBase can append the same delegation hint to
// every one of its failures: the operator needs the reason and the
// remedy in the same sentence.
func ownCgroupBase() string {
	controllers, err := os.ReadFile(filepath.Join(unifiedRoot, "cgroup.controllers"))
	if err != nil {
		return fmt.Sprintf("no cgroup v2 unified hierarchy at %s: %v", unifiedRoot, err)
	}
	if missing := missingControllers(string(controllers)); missing != "" {
		return fmt.Sprintf("cgroup v2 present but missing controllers "+
			"(have %q, need %s)", strings.TrimSpace(string(controllers)), missing)
	}
	base, ok := ownCgroupPath()
	if !ok {
		return "process is not in a cgroup v2 hierarchy"
	}
	return usable(base)
}

// delegationHint is appended to every fallback failure: the reason a
// base is unusable is only half the message, and the other half is the
// same every time.
const delegationHint = "hand the helper a delegated, process-empty " +
	"cgroup v2 base in " + BaseEnvVar + " or --cgroup-base (systemd: " +
	"Delegate=yes, plus DelegateSubgroup= on v254+ so the delegated root " +
	"stays empty)"

// delegatedBase validates an operator-supplied base and enables the
// controllers its children need.
func delegatedBase(base string) (dir string, reason string) {
	if reason := usable(base); reason != "" {
		return "", reason
	}
	return base, ""
}

// usable reports why base cannot host per-exec cgroups, or "" when it
// can — enabling the memory and pids controllers for its children as a
// side effect when they are available but not yet distributed.
func usable(base string) string {
	controllers, err := os.ReadFile(filepath.Join(base, "cgroup.controllers"))
	if err != nil {
		return fmt.Sprintf("%s is not a cgroup v2 directory: %v", base, err)
	}
	if missing := missingControllers(string(controllers)); missing != "" {
		return fmt.Sprintf("cgroup %s was not delegated the %s controller(s) "+
			"(has %q)", base, missing, strings.TrimSpace(string(controllers)))
	}
	// The no-internal-process rule: a cgroup with member processes cannot
	// enable controllers for its children. A delegated base is expected to
	// be empty; the helper's own cgroup never is, outside the root cgroup.
	procs, err := os.ReadFile(filepath.Join(base, "cgroup.procs"))
	if err != nil {
		return fmt.Sprintf("cannot read %s/cgroup.procs: %v", base, err)
	}
	if n := len(strings.Fields(string(procs))); n > 0 && base != unifiedRoot {
		return fmt.Sprintf("cgroup %s holds %d process(es), so cgroup v2's "+
			"no-internal-process rule forbids enabling controllers for its "+
			"children", base, n)
	}
	if reason := enableSubtree(base); reason != "" {
		return reason
	}
	probe := filepath.Join(base, "loom-exec-probe")
	if err := os.Mkdir(probe, 0o755); err != nil {
		return fmt.Sprintf("cgroup %s not delegated (mkdir failed: %v)", base, err)
	}
	_ = os.Remove(probe)
	return ""
}

// unifiedRoot is the one cgroup exempt from the no-internal-process
// rule, and therefore the one place the fallback base works.
const unifiedRoot = "/sys/fs/cgroup"

// enableSubtree makes sure base distributes memory and pids to its
// children, writing `cgroup.subtree_control` only when something is
// missing (the write is rejected outright on a populated cgroup, and
// writing nothing is one fewer way to fail).
func enableSubtree(base string) string {
	path := filepath.Join(base, "cgroup.subtree_control")
	current, err := os.ReadFile(path)
	if err != nil {
		return fmt.Sprintf("cannot read %s: %v", path, err)
	}
	if missing := missingControllers(string(current)); missing != "" {
		if err := os.WriteFile(path, []byte("+memory +pids"), 0o644); err != nil {
			return fmt.Sprintf("cgroup %s does not distribute %s to its "+
				"children and they could not be enabled (write %s: %v)",
				base, missing, path, err)
		}
		again, err := os.ReadFile(path)
		if err != nil || missingControllers(string(again)) != "" {
			return fmt.Sprintf("cgroup %s still does not distribute memory "+
				"and pids to its children after enabling them", base)
		}
	}
	return ""
}

// missingControllers names which of memory and pids a controller list
// lacks, or "" when it has both. Used for both `cgroup.controllers`
// (what is available here) and `cgroup.subtree_control` (what reaches
// the children), which is why it takes the raw file contents.
func missingControllers(list string) string {
	have := map[string]bool{}
	for _, c := range strings.Fields(list) {
		// A real cgroupfs reads back plain names; the "+name" form is
		// only ever what we wrote, and tolerating it keeps the
		// verifying re-read below honest against a filesystem fake.
		have[strings.TrimPrefix(c, "+")] = true
	}
	switch {
	case !have["memory"] && !have["pids"]:
		return "memory and pids"
	case !have["memory"]:
		return "memory"
	case !have["pids"]:
		return "pids"
	}
	return ""
}

// ownV2Path extracts the v2 path from /proc/self/cgroup contents
// ("0::/foo/bar" yields "foo/bar"). The root cgroup's own line is
// "0::/", which yields "" *and* ok — a distinction the caller needs,
// since the root cgroup is the one place the fallback base works.
func ownV2Path(procSelfCgroup string) (string, bool) {
	for _, line := range strings.Split(procSelfCgroup, "\n") {
		if rest, ok := strings.CutPrefix(line, "0::"); ok {
			return strings.TrimPrefix(strings.TrimSpace(rest), "/"), true
		}
	}
	return "", false
}

// Setup creates a per-exec cgroup under base, applies the limit writes,
// and returns its path. The caller moves the child in by writing its pid
// to cgroup.procs (see Enter); descendants inherit membership, which is
// exactly what makes pids.max fork-bomb-proof.
func Setup(base, name string, l LimitsView) (string, error) {
	dir := filepath.Join(base, name)
	if err := os.Mkdir(dir, 0o755); err != nil && !os.IsExist(err) {
		return "", fmt.Errorf("cgroup: mkdir %s: %w", dir, err)
	}
	for _, w := range FileWrites(dir, l) {
		if err := os.WriteFile(w.Path, []byte(w.Content), 0o644); err != nil {
			return "", fmt.Errorf("cgroup: write %s: %w", w.Path, err)
		}
	}
	return dir, nil
}

// Enter moves pid into the cgroup at dir.
func Enter(dir string, pid int) error {
	p := filepath.Join(dir, "cgroup.procs")
	if err := os.WriteFile(p, []byte(strconv.Itoa(pid)), 0o644); err != nil {
		return fmt.Errorf("cgroup: enter %s: %w", dir, err)
	}
	return nil
}

// ReadPidsEventsMax returns the pids.events "max" counter for the
// cgroup at dir: how many times a fork was denied by pids.max. The
// self-test uses it as ground truth that the fork-bomb cap actually
// fired (parsing "Cannot fork" chatter out of a shell would be guesswork).
func ReadPidsEventsMax(dir string) uint64 {
	raw, err := os.ReadFile(filepath.Join(dir, "pids.events"))
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(raw), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[0] == "max" {
			n, err := strconv.ParseUint(fields[1], 10, 64)
			if err == nil {
				return n
			}
		}
	}
	return 0
}

// Cleanup removes the per-exec cgroup; processes must be dead first.
func Cleanup(dir string) error {
	if err := os.Remove(dir); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("cgroup: remove %s: %w", dir, err)
	}
	return nil
}
