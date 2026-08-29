package cgroup

import (
	"os"
	"path/filepath"
	"reflect"
	"runtime"
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
// Nothing here needs a kernel: the interface-file half of the contract
// is what `usable` reads out of the three files and whether it can mkdir
// a child, all of which an ordinary directory can present.
//
// That it *can* present them is the point of #52, and the reason these
// tests address `usable` rather than `DetectBase`. `DetectBase` asks the
// kernel by `statfs(2)` before it asks anything else, so a directory
// shaped like a base is refused there and never reaches this reasoning
// — which is exactly what must happen in production and exactly what
// would make these cases untestable without a real delegated cgroup.
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

func TestUsableAcceptsADelegatedEmptyBase(t *testing.T) {
	base := fakeBase(t, "cpu memory pids\n", "", "memory pids\n")
	if reason := usable(base); reason != "" {
		t.Fatalf("a delegated, process-empty base must be usable: %s", reason)
	}
}

// Detection is a question, not a reconfiguration. Writing "+memory
// +pids" into the operator's cgroup.subtree_control — never reverted —
// was a side effect of a probe that reads as read-only (#52). The write
// belongs to Setup, which runs after the base is validated and an
// execution actually needs a child.
func TestUsableDoesNotMutateTheBase(t *testing.T) {
	base := fakeBase(t, "cpu memory pids\n", "", "")
	if reason := usable(base); reason != "" {
		t.Fatalf("a delegated, process-empty base must be usable: %s", reason)
	}
	got, err := os.ReadFile(filepath.Join(base, "cgroup.subtree_control"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "" {
		t.Fatalf("detection mutated the operator's cgroup tree: "+
			"subtree_control = %q", got)
	}
}

// The point of taking the base as configuration: the operator's cgroup
// may be delegated without the controllers yet distributed to its
// children, and distributing them is exactly what a process-empty base
// permits and a populated one does not. Setup is where that happens.
func TestSetupEnablesTheControllersItsChildrenNeed(t *testing.T) {
	base := fakeBase(t, "cpu memory pids\n", "", "cpu\n")
	dir, err := Setup(base, "exec-1-2", LimitsView{Pids: 8})
	if err != nil {
		t.Fatalf("controllers should have been enabled, not refused: %v", err)
	}
	if dir != filepath.Join(base, "exec-1-2") {
		t.Fatalf("Setup = %q, want a child of %q", dir, base)
	}
	got, err := os.ReadFile(filepath.Join(base, "cgroup.subtree_control"))
	if err != nil {
		t.Fatal(err)
	}
	if missingControllers(string(got)) != "" {
		t.Fatalf("subtree_control is still missing controllers: %q", got)
	}
}

func TestUsableRefusesAPopulatedBase(t *testing.T) {
	base := fakeBase(t, "memory pids\n", "1701\n", "")
	reason := usable(base)
	if reason == "" {
		t.Fatal("a populated base must not be used")
	}
	if !strings.Contains(reason, "no-internal-process") {
		t.Fatalf("the reason must name the rule that forbids it: %q", reason)
	}
}

func TestUsableRefusesAnUndelegatedController(t *testing.T) {
	base := fakeBase(t, "cpu io\n", "", "")
	reason := usable(base)
	if reason == "" {
		t.Fatal("a base without memory/pids must not be used")
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
	if !strings.Contains(reason, "cgroup v2") {
		t.Fatalf("unhelpful reason: %q", reason)
	}
}

// #52's reproduction, as a test. Three text files in a plain directory
// answered every question the old DetectBase asked, so a typo'd
// --cgroup-base became a "cgroup v2 base": memory.max and pids.max were
// written as ordinary files, Enter wrote a pid into one and returned
// nil, and the exec_exit frame told the broker `cgroup-v2` applied while
// a 32-way fork burst under pids=8 ran to completion. On Linux, only
// statfs(2) can tell a directory from a cgroup. Other platforms must refuse
// before pretending that they can inspect a Linux-only filesystem.
func TestDetectBaseRefusesADirectoryDressedAsACgroup(t *testing.T) {
	base := fakeBase(t, "cpuset cpu io memory hugetlb pids rdma misc\n", "", "")
	dir, reason := DetectBase(base)
	if dir != "" {
		t.Fatalf("a plain directory was accepted as a cgroup v2 base: %q", dir)
	}
	if runtime.GOOS == "linux" {
		if !strings.Contains(reason, "cgroup2") {
			t.Fatalf("the refusal must name the filesystem it wanted: %q", reason)
		}
		return
	}
	if !strings.Contains(reason, "cgroups are a Linux facility") {
		t.Fatalf("the refusal must name the unsupported platform boundary: %q", reason)
	}
}

// A cgroup directory holds kernel-created interface files that cannot be
// unlinked and, sometimes, child cgroups. os.Remove alone fails on the
// second and leaves an exec-N-PID/ behind, which is what #52 observed.
func TestCleanupRemovesAChildCgroup(t *testing.T) {
	dir := t.TempDir()
	child := filepath.Join(dir, "exec-1-99", "nested")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := Cleanup(filepath.Join(dir, "exec-1-99")); err != nil {
		t.Fatalf("Cleanup: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "exec-1-99")); !os.IsNotExist(err) {
		t.Fatalf("the per-exec cgroup was left behind: %v", err)
	}
}

// commonAncestor is what the delegation-containment check reasons over,
// and getting it wrong would either invent a refusal or miss a real one.
func TestCommonAncestor(t *testing.T) {
	cases := []struct{ a, b, want string }{
		{"/sys/fs/cgroup/a/b", "/sys/fs/cgroup/a/c", "/sys/fs/cgroup/a"},
		{"/sys/fs/cgroup/loom", "/sys/fs/cgroup/loom/exec-1", "/sys/fs/cgroup/loom"},
		{"/sys/fs/cgroup/loom/exec-1", "/sys/fs/cgroup/loom", "/sys/fs/cgroup/loom"},
		{"/a", "/b", "/"},
	}
	for _, c := range cases {
		if got := commonAncestor(c.a, c.b); got != c.want {
			t.Fatalf("commonAncestor(%q, %q) = %q, want %q", c.a, c.b, got, c.want)
		}
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
