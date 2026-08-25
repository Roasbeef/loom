package cgroup

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestFileWrites(t *testing.T) {
	cases := []struct {
		name   string
		limits LimitsView
		want   []FileWrite
	}{
		{
			name:   "both limits",
			limits: LimitsView{MemBytes: 1 << 30, Pids: 256},
			want: []FileWrite{
				{Path: "/cg/exec-1/memory.max", Content: "1073741824"},
				{Path: "/cg/exec-1/pids.max", Content: "256"},
			},
		},
		{
			name:   "pids only",
			limits: LimitsView{Pids: 8},
			want:   []FileWrite{{Path: "/cg/exec-1/pids.max", Content: "8"}},
		},
		{
			name:   "mem only",
			limits: LimitsView{MemBytes: 4096},
			want:   []FileWrite{{Path: "/cg/exec-1/memory.max", Content: "4096"}},
		},
		{
			name:   "no limits, no writes",
			limits: LimitsView{},
			want:   nil,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := FileWrites("/cg/exec-1", tc.limits)
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("FileWrites = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestOwnV2Path(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
		ok   bool
	}{
		{"pure v2", "0::/user.slice/session-1.scope\n", "user.slice/session-1.scope", true},
		{"hybrid picks v2 line", "12:pids:/init\n0::/box\n", "box", true},
		// The root cgroup is in the v2 hierarchy and is the one place the
		// fallback base works; an empty path is not an absent one.
		{"root cgroup", "0::/\n", "", true},
		{"v1 only", "12:pids:/init\n3:memory:/init\n", "", false},
		{"empty", "", "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := ownV2Path(tc.in)
			if got != tc.want || ok != tc.ok {
				t.Fatalf("ownV2Path(%q) = %q,%v, want %q,%v", tc.in, got, ok, tc.want, tc.ok)
			}
		})
	}
}

// fakeBase builds a directory shaped like a delegated cgroup v2 base.
// Nothing here needs a kernel: DetectBase's whole contract is what it
// reads out of the three interface files and whether it can mkdir a
// child, all of which an ordinary directory can present.
func fakeBase(t *testing.T, controllers, procs, subtree string) string {
	t.Helper()
	dir := t.TempDir()
	for name, content := range map[string]string{
		"cgroup.controllers":     controllers,
		"cgroup.procs":           procs,
		"cgroup.subtree_control": subtree,
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatalf("seed %s: %v", name, err)
		}
	}
	return dir
}

func TestDetectBaseAcceptsADelegatedEmptyBase(t *testing.T) {
	base := fakeBase(t, "cpu memory pids\n", "", "memory pids\n")
	dir, reason := DetectBase(base)
	if reason != "" {
		t.Fatalf("a delegated, process-empty base must be usable: %s", reason)
	}
	if dir != base {
		t.Fatalf("DetectBase = %q, want %q", dir, base)
	}
}

// The point of taking the base as configuration: the operator's cgroup
// may be delegated without the controllers yet distributed to its
// children, and distributing them is exactly what a process-empty base
// permits and a populated one does not.
func TestDetectBaseEnablesTheControllersItsChildrenNeed(t *testing.T) {
	base := fakeBase(t, "cpu memory pids\n", "", "cpu\n")
	dir, reason := DetectBase(base)
	if reason != "" {
		t.Fatalf("controllers should have been enabled, not refused: %s", reason)
	}
	if dir != base {
		t.Fatalf("DetectBase = %q, want %q", dir, base)
	}
	got, err := os.ReadFile(filepath.Join(base, "cgroup.subtree_control"))
	if err != nil {
		t.Fatal(err)
	}
	if missingControllers(string(got)) != "" {
		t.Fatalf("subtree_control is still missing controllers: %q", got)
	}
}

func TestDetectBaseRefusesAPopulatedBase(t *testing.T) {
	base := fakeBase(t, "memory pids\n", "1701\n", "")
	dir, reason := DetectBase(base)
	if dir != "" {
		t.Fatalf("a populated base must not be used: %q", dir)
	}
	if !strings.Contains(reason, "no-internal-process") {
		t.Fatalf("the reason must name the rule that forbids it: %q", reason)
	}
}

func TestDetectBaseRefusesAnUndelegatedController(t *testing.T) {
	base := fakeBase(t, "cpu io\n", "", "")
	dir, reason := DetectBase(base)
	if dir != "" {
		t.Fatalf("a base without memory/pids must not be used: %q", dir)
	}
	if !strings.Contains(reason, "memory and pids") {
		t.Fatalf("the reason must name what was not delegated: %q", reason)
	}
}

func TestDetectBaseRefusesANonCgroupPath(t *testing.T) {
	dir, reason := DetectBase(t.TempDir())
	if dir != "" {
		t.Fatalf("an ordinary directory is not a cgroup base: %q", dir)
	}
	if !strings.Contains(reason, "not a cgroup v2 directory") {
		t.Fatalf("unhelpful reason: %q", reason)
	}
}

// With no base configured the helper falls back to its own cgroup, and
// every way that fails must name the delegation that would fix it —
// otherwise the operator is told a layer is unavailable and not told
// that it is theirs to grant.
func TestDetectBaseFallbackNamesTheDelegationThatWouldFixIt(t *testing.T) {
	dir, reason := DetectBase("")
	if dir != "" && reason == "" {
		return // this machine really does have a usable own-cgroup base
	}
	if !strings.Contains(reason, BaseEnvVar) {
		t.Fatalf("fallback reason must name %s: %q", BaseEnvVar, reason)
	}
}

func TestMissingControllers(t *testing.T) {
	cases := []struct{ in, want string }{
		{"memory pids", ""},
		{"+memory +pids", ""},
		{"cpu memory pids io", ""},
		{"memory", "pids"},
		{"pids", "memory"},
		{"cpu io", "memory and pids"},
		{"", "memory and pids"},
	}
	for _, tc := range cases {
		if got := missingControllers(tc.in); got != tc.want {
			t.Fatalf("missingControllers(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
