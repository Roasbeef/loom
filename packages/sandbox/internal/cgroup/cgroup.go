// Package cgroup translates policy limits into cgroup v2 file writes and
// applies them when a delegated cgroup v2 hierarchy is available.
//
// mem_bytes and pids limits need cgroups: RLIMIT_AS is per-process and
// trivially escaped by forking, and RLIMIT_NPROC is per-user (useless
// when the jail shares a uid, ignored entirely for root). The
// construction half is pure — policy in, {path, contents} pairs out — so
// the exact writes are unit-tested even inside containers that give us
// no v2 delegation (like this one, which mounts v1 controllers).
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

// Detect reports whether a writable, delegated cgroup v2 hierarchy with
// the memory and pids controllers is available, returning the directory
// under which per-exec cgroups can be created, or a human-readable
// reason why not.
func Detect() (dir string, reason string) {
	const root = "/sys/fs/cgroup"
	controllers, err := os.ReadFile(filepath.Join(root, "cgroup.controllers"))
	if err != nil {
		return "", fmt.Sprintf("no cgroup v2 unified hierarchy at %s: %v", root, err)
	}
	have := map[string]bool{}
	for _, c := range strings.Fields(string(controllers)) {
		have[c] = true
	}
	if !have["memory"] || !have["pids"] {
		return "", fmt.Sprintf("cgroup v2 present but missing controllers (have %q)", strings.TrimSpace(string(controllers)))
	}
	// Our own cgroup must be writable for delegation to mean anything.
	self, err := os.ReadFile("/proc/self/cgroup")
	if err != nil {
		return "", fmt.Sprintf("cannot read /proc/self/cgroup: %v", err)
	}
	own := ownV2Path(string(self))
	if own == "" {
		return "", "process is not in a cgroup v2 hierarchy"
	}
	base := filepath.Join(root, own)
	probe := filepath.Join(base, "loom-exec-probe")
	if err := os.Mkdir(probe, 0o755); err != nil {
		return "", fmt.Sprintf("cgroup %s not delegated (mkdir failed: %v)", base, err)
	}
	_ = os.Remove(probe)
	return base, ""
}

// ownV2Path extracts the v2 path ("0::/foo/bar") from /proc/self/cgroup
// contents; empty when absent.
func ownV2Path(procSelfCgroup string) string {
	for _, line := range strings.Split(procSelfCgroup, "\n") {
		if rest, ok := strings.CutPrefix(line, "0::"); ok {
			return strings.TrimPrefix(strings.TrimSpace(rest), "/")
		}
	}
	return ""
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
