package jail

import (
	"reflect"
	"testing"
)

// The jail's host-side shape, by descent: supervisor, bwrap's namespace
// init below it, the payload below that. See cancel.go.
func jailedTree(supervisor int) []ProcEntry {
	return []ProcEntry{
		{Pid: supervisor, Ppid: 1},
		{Pid: supervisor + 1, Ppid: supervisor},     // bwrap's ns init
		{Pid: supervisor + 3, Ppid: supervisor + 1}, // the payload
	}
}

func TestTermTargetsSparesTheScaffolding(t *testing.T) {
	got := TermTargets(jailedTree(100), 100)
	if want := []int{103}; !reflect.DeepEqual(got, want) {
		t.Fatalf("TermTargets = %v, want %v (payload only)", got, want)
	}
}

// A grandchild the payload forked is inside the jail and is part of what
// was asked to stop, so it is addressed too.
func TestTermTargetsIncludesGrandchildren(t *testing.T) {
	entries := append(jailedTree(100), ProcEntry{Pid: 104, Ppid: 103})
	got := TermTargets(entries, 100)
	if want := []int{103, 104}; !reflect.DeepEqual(got, want) {
		t.Fatalf("TermTargets = %v, want %v", got, want)
	}
}

// #53, evasion 1: setsid(2) takes a payload out of the process group the
// old selection scanned, which returned nothing and made the caller fall
// back to signalling the group — killing the supervisor and collapsing
// the namespace onto a payload nothing had asked to stop. Leaving the
// group changes no parent link, so it changes no target.
func TestTermTargetsFindAPayloadThatLeftTheProcessGroup(t *testing.T) {
	// Process-group membership is not modelled at all any more; the
	// escapee is here purely as a descendant.
	entries := append(jailedTree(100), ProcEntry{Pid: 105, Ppid: 103})
	got := TermTargets(entries, 100)
	if want := []int{103, 105}; !reflect.DeepEqual(got, want) {
		t.Fatalf("TermTargets = %v, want %v (the escapee is still a descendant)", got, want)
	}
}

// #53, evasion 2: the old rule spared any process whose innermost NSpid
// was 1, which `unshare -U -p -f` gives a payload for free. The
// exemption is now structural — the supervisor and its own children —
// so a payload that nests namespaces inherits nothing.
func TestTermTargetsDoNotExemptAPayloadsOwnNamespaceInit(t *testing.T) {
	entries := []ProcEntry{
		{Pid: 100, Ppid: 1},   // supervisor
		{Pid: 101, Ppid: 100}, // bwrap's ns init
		{Pid: 103, Ppid: 101}, // unshare
		{Pid: 104, Ppid: 103}, // the payload: PID 1 of its own namespace
		{Pid: 105, Ppid: 104}, // its sleep
	}
	got := TermTargets(entries, 100)
	if want := []int{103, 104, 105}; !reflect.DeepEqual(got, want) {
		t.Fatalf("TermTargets = %v, want %v", got, want)
	}
}

// Other processes are none of our business, however the table is ordered.
func TestTermTargetsIgnoreUnrelatedProcesses(t *testing.T) {
	entries := []ProcEntry{
		{Pid: 900, Ppid: 7},
		{Pid: 7, Ppid: 1},
		{Pid: 100, Ppid: 1},
		{Pid: 101, Ppid: 100},
		{Pid: 103, Ppid: 101},
	}
	got := TermTargets(entries, 100)
	if want := []int{103}; !reflect.DeepEqual(got, want) {
		t.Fatalf("TermTargets = %v, want %v", got, want)
	}
}

// The three "no opinion" cases must all answer nil, because the caller
// turns nil into a whole-group TERM. A selection that silently returned
// an empty non-nil list would be indistinguishable at the call site, but
// a selection that returned a *partial* answer here would be a TERM that
// never reached the payload — so these are pinned.
func TestTermTargetsNoOpinion(t *testing.T) {
	cases := map[string][]ProcEntry{
		"no process table at all": nil,
		"the supervisor alone (degraded mode)": {
			{Pid: 100, Ppid: 1},
		},
		"payload has not appeared in the table yet": {
			{Pid: 100, Ppid: 1},
			{Pid: 101, Ppid: 100},
		},
	}
	for name, entries := range cases {
		if got := TermTargets(entries, 100); got != nil {
			t.Fatalf("%s: TermTargets = %v, want nil (fall back to the group)", name, got)
		}
	}
}

// A recycled pid claiming an ancestor as its parent must not send the
// walk round in circles.
func TestTermTargetsTerminateOnACycle(t *testing.T) {
	entries := []ProcEntry{
		{Pid: 100, Ppid: 1},
		{Pid: 101, Ppid: 100},
		{Pid: 103, Ppid: 101},
		{Pid: 104, Ppid: 103},
		{Pid: 101, Ppid: 104}, // the same pid, now claiming its own descendant
	}
	got := TermTargets(entries, 100)
	if want := []int{103, 104}; !reflect.DeepEqual(got, want) {
		t.Fatalf("TermTargets = %v, want %v", got, want)
	}
}

// #135: a table that lost the depth-2 row still answers non-empty if
// any unrelated deeper descendant survived the scan, and the walk cannot
// tell that apart from a complete answer. The kernel's own list of the
// supervisor's grandchildren can: pid 103 is alive, the selection does
// not contain it, so the scan was partial and the caller must fall back
// to the group rather than TERM a subset that does not include the
// payload.
func TestTermTargetsPartialScanIsNotTrusted(t *testing.T) {
	// 103 (the payload) and its child 104 are lost with it, leaving a
	// second descendant of the namespace init as the only selection.
	partial := []ProcEntry{
		{Pid: 100, Ppid: 1},   // supervisor
		{Pid: 101, Ppid: 100}, // bwrap's ns init
		{Pid: 110, Ppid: 101}, // an unrelated deeper descendant
	}
	targets := TermTargets(partial, 100)
	if want := []int{110}; !reflect.DeepEqual(targets, want) {
		t.Fatalf("TermTargets = %v, want %v (the premise of the test)",
			targets, want)
	}

	// What the kernel says is actually hanging off the namespace init.
	roots := []int{103, 110}
	if termTargetsAreTrusted(targets, roots) {
		t.Fatal("a selection missing a live payload root was trusted; " +
			"the caller would TERM a subset and wait out the grace")
	}
}

// The converse, and the case that must keep working: the payload row is
// present, so every live root is covered and the narrow selection —
// which spares the supervisor and the namespace init — is the one that
// gets the TERM.
func TestTermTargetsCompleteScanIsTrusted(t *testing.T) {
	targets := TermTargets(append(jailedTree(100),
		ProcEntry{Pid: 104, Ppid: 103}), 100)
	if want := []int{103, 104}; !reflect.DeepEqual(targets, want) {
		t.Fatalf("TermTargets = %v, want %v (the premise of the test)",
			targets, want)
	}
	if !termTargetsAreTrusted(targets, []int{103}) {
		t.Fatal("a complete selection was demoted to the group fallback")
	}
}

// An unreadable `children` file gives no roots, and no roots must mean
// "no opinion" rather than "nothing is alive". Reading it the other way
// would demote every cancel on a kernel without CONFIG_PROC_CHILDREN to
// the whole-group TERM that #53 removed.
func TestTermTargetsTrustedWithoutRoots(t *testing.T) {
	if !termTargetsAreTrusted([]int{103}, nil) {
		t.Fatal("an unverifiable selection was demoted; absence of " +
			"evidence is not evidence of a partial scan")
	}
}

func TestParseStatPpid(t *testing.T) {
	cases := []struct {
		name string
		stat string
		want int
		ok   bool
	}{
		{"ordinary", "1234 (bwrap) S 1200 1234 1234 0 -1 ...", 1200, true},
		// A comm containing spaces and parentheses is why the parse
		// starts after the *last* ')' and not the first.
		{"hostile comm", `9 (we ) (are) S) S 4 77 77 0`, 4, true},
		{"truncated", "1234 (bwrap)", 0, false},
		{"no comm", "garbage", 0, false},
	}
	for _, c := range cases {
		got, ok := parseStatPpid(c.stat)
		if ok != c.ok || (ok && got != c.want) {
			t.Fatalf("%s: parseStatPpid = %d,%v want %d,%v", c.name, got, ok, c.want, c.ok)
		}
	}
}
