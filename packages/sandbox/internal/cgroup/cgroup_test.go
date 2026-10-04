package cgroup

import (
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strconv"
	"strings"
	"sync"
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

// One delegated base serves every helper on the host, so several helpers
// probe it at once whenever a test package boots daemons in parallel.
// While the probe directory had a fixed name, the second helper's mkdir
// returned EEXIST and it declared the base undelegated, which surfaced as
// a `skip:cgroup-v2` entry and a shipped fixture skipped for want of
// platform enforcement.
func TestUsableToleratesConcurrentProbes(t *testing.T) {
	base := fakeBase(t, "cpu memory pids\n", "", "memory pids\n")
	reasons := make(chan string, 16)

	var start sync.WaitGroup
	start.Add(1)
	for i := 0; i < cap(reasons); i++ {
		go func() {
			start.Wait()
			reasons <- usable(base)
		}()
	}

	// Releasing them together is what makes the probes overlap; started
	// one at a time they would never collide even under the old name.
	start.Done()
	for i := 0; i < cap(reasons); i++ {
		if reason := <-reasons; reason != "" {
			t.Fatalf("a concurrent probe found the base unusable: %s", reason)
		}
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

// diedExcept makes Sweep read every pid but the ones named here as gone.
func diedExcept(t *testing.T, alive ...int) {
	t.Helper()
	was := pidAlive
	pidAlive = func(pid int) bool {
		for _, a := range alive {
			if a == pid {
				return true
			}
		}
		return false
	}
	t.Cleanup(func() { pidAlive = was })
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// The leak of #702: a killed helper leaves exec-<id>-<pid> behind. The sweep
// removes the ones whose execution has gone, and only those: a live one (the
// execution's process still exists, even though its cgroup is empty until
// Enter), one the kernel reports populated, a name that is not an execution's
// at all, and a plain file are all left.
func TestSweepRemovesOnlyTheCgroupsOfExecutionsThatHaveGone(t *testing.T) {
	base := t.TempDir()
	diedExcept(t, 1111)
	for name, events := range map[string]string{
		"exec-3-4242":       "",              // gone, empty: swept
		"exec-5-1111":       "populated 0\n", // live pid, empty until Enter: kept
		"exec-7-99":         "populated 1\n", // gone pid, still has members: kept
		"loom-exec-probe-1": "",              // not an execution's name: kept
		"exec-8":            "",              // no pid: kept
		"exec-8-9-10":       "",              // not the pattern: kept
		"other":             "",              // kept
	} {
		dir := filepath.Join(base, name)
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if events != "" {
			if err := os.WriteFile(filepath.Join(dir, "cgroup.events"), []byte(events), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := os.WriteFile(filepath.Join(base, "exec-1-5"), nil, 0o644); err != nil {
		t.Fatal(err)
	}

	removed, err := Sweep(base)
	if removed != 1 || err != nil {
		t.Fatalf("Sweep = %d, %v; want 1, nil", removed, err)
	}
	if exists(filepath.Join(base, "exec-3-4242")) {
		t.Fatal("the gone, empty cgroup was not removed")
	}
	for _, kept := range []string{"exec-5-1111", "exec-7-99", "loom-exec-probe-1", "exec-8", "exec-8-9-10", "other", "exec-1-5"} {
		if !exists(filepath.Join(base, kept)) {
			t.Errorf("%s was removed and must not have been", kept)
		}
	}
}

// Child cgroups go first and the directory last, each by rmdir, as Cleanup
// does for a release.
func TestSweepRemovesAChildCgroupBeforeItsParent(t *testing.T) {
	base := t.TempDir()
	diedExcept(t)
	if err := os.MkdirAll(filepath.Join(base, "exec-2-77", "nested"), 0o755); err != nil {
		t.Fatal(err)
	}
	removed, err := Sweep(base)
	if err != nil || removed != 1 {
		t.Fatalf("Sweep = %d, %v; want 1, nil", removed, err)
	}
	if exists(filepath.Join(base, "exec-2-77")) {
		t.Fatal("the nested cgroup tree was left behind")
	}
}

// The removal is rmdir and never a recursive delete: a directory that holds
// something rmdir refuses (on a real cgroupfs, a process-holding child that
// raced the check) is reported and left with its contents, and the sweep goes
// on to the next candidate.
func TestSweepNeverDeletesRecursively(t *testing.T) {
	base := t.TempDir()
	diedExcept(t)
	kept := filepath.Join(base, "exec-1-50", "keep.txt")
	if err := os.MkdirAll(filepath.Dir(kept), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(kept, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(base, "exec-2-51"), 0o755); err != nil {
		t.Fatal(err)
	}
	removed, err := Sweep(base)
	if err == nil || !strings.Contains(err.Error(), "exec-1-50") {
		t.Fatalf("Sweep error = %v, want one naming exec-1-50", err)
	}
	if removed != 1 || exists(filepath.Join(base, "exec-2-51")) {
		t.Fatalf("the later candidate was not swept (removed %d)", removed)
	}
	if !exists(kept) {
		t.Fatal("a directory rmdir refused was deleted recursively")
	}
}

func TestSweepReportsAnUnreadableBase(t *testing.T) {
	if _, err := Sweep(filepath.Join(t.TempDir(), "absent")); err == nil {
		t.Fatal("sweeping a base that does not exist reported nothing")
	}
}

// On a host with a delegated cgroup v2 base, the leak itself: a cgroup of a
// dead execution made by Setup, removed by Sweep, while one with a live pid in
// its name is left. Hosts without a base skip; only the Linux signoff with a
// delegated cgroup runs this, and the cases above cover the logic everywhere.
func TestSweepRemovesARealCgroup(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("cgroups exist only on Linux")
	}
	base, reason := DetectBase(BaseFromEnv())
	if base == "" {
		t.Skipf("no delegated cgroup v2 base to sweep: %s", reason)
	}
	// A pid no process holds: past the kernel's largest pid_max.
	const gone = 4194305
	dead := mustSetup(t, base, "exec-9001-"+strconv.Itoa(gone))
	live := mustSetup(t, base, "exec-9002-"+strconv.Itoa(os.Getpid()))
	defer Cleanup(live)
	defer Cleanup(dead)

	if _, err := Sweep(base); err != nil {
		t.Fatalf("Sweep: %v", err)
	}
	if exists(dead) {
		t.Fatal("the cgroup of a dead execution was left behind")
	}
	if !exists(live) {
		t.Fatal("the cgroup of a live execution was removed")
	}
}

func mustSetup(t *testing.T, base, name string) string {
	t.Helper()
	dir, err := Setup(base, name, LimitsView{})
	if err != nil {
		t.Skipf("cannot create a cgroup under %s: %v", base, err)
	}
	return dir
}
