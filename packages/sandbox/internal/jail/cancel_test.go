package jail

import (
	"reflect"
	"testing"
)

// The jail's host-side shape: supervisor (group leader), namespace init,
// payload. See cancel.go.
func jailedGroup(pgid int) []ProcEntry {
	return []ProcEntry{
		{Pid: pgid, Pgid: pgid, NamespaceInit: false},
		{Pid: pgid + 1, Pgid: pgid, NamespaceInit: true},
		{Pid: pgid + 3, Pgid: pgid, NamespaceInit: false},
	}
}

func TestTermTargetsSparesTheScaffolding(t *testing.T) {
	got := TermTargets(jailedGroup(100), 100, 100)
	if want := []int{103}; !reflect.DeepEqual(got, want) {
		t.Fatalf("TermTargets = %v, want %v (payload only)", got, want)
	}
}

// A grandchild the payload forked is inside the jail and is part of what
// was asked to stop, so it is addressed too.
func TestTermTargetsIncludesGrandchildren(t *testing.T) {
	entries := append(jailedGroup(100), ProcEntry{Pid: 104, Pgid: 100})
	got := TermTargets(entries, 100, 100)
	if want := []int{103, 104}; !reflect.DeepEqual(got, want) {
		t.Fatalf("TermTargets = %v, want %v", got, want)
	}
}

// Other groups are none of our business, however the table is ordered.
func TestTermTargetsIgnoresOtherGroups(t *testing.T) {
	entries := []ProcEntry{
		{Pid: 7, Pgid: 7},
		{Pid: 100, Pgid: 100},
		{Pid: 101, Pgid: 100, NamespaceInit: true},
		{Pid: 103, Pgid: 100},
		{Pid: 900, Pgid: 900},
	}
	got := TermTargets(entries, 100, 100)
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
		"group is the supervisor alone (degraded mode)": {
			{Pid: 100, Pgid: 100},
		},
		"payload has not appeared in the table yet": {
			{Pid: 100, Pgid: 100},
			{Pid: 101, Pgid: 100, NamespaceInit: true},
		},
	}
	for name, entries := range cases {
		if got := TermTargets(entries, 100, 100); got != nil {
			t.Fatalf("%s: TermTargets = %v, want nil (fall back to the group)", name, got)
		}
	}
}

func TestParseStatPgid(t *testing.T) {
	cases := []struct {
		name string
		stat string
		want int
		ok   bool
	}{
		{"ordinary", "1234 (bwrap) S 1200 1234 1234 0 -1 ...", 1234, true},
		// A comm containing spaces and parentheses is why the parse
		// starts after the *last* ')' and not the first.
		{"hostile comm", `9 (we ) (are) S) S 4 77 77 0`, 77, true},
		{"truncated", "1234 (bwrap)", 0, false},
		{"no comm", "garbage", 0, false},
	}
	for _, c := range cases {
		got, ok := parseStatPgid(c.stat)
		if ok != c.ok || (ok && got != c.want) {
			t.Fatalf("%s: parseStatPgid = %d,%v want %d,%v", c.name, got, ok, c.want, c.ok)
		}
	}
}

func TestNestedNamespaceInit(t *testing.T) {
	cases := []struct {
		name   string
		status string
		want   bool
	}{
		{"nested init", "Name:\tbwrap\nNSpid:\t4321\t1\nThreads:\t1\n", true},
		{"nested but not init", "NSpid:\t4322\t2\n", false},
		{"same namespace as us", "NSpid:\t4321\n", false},
		{"deeply nested init", "NSpid:\t4321\t7\t1\n", true},
		{"no NSpid line (kernel without pid namespaces)", "Name:\tsh\n", false},
	}
	for _, c := range cases {
		if got := nestedNamespaceInit(c.status); got != c.want {
			t.Fatalf("%s: nestedNamespaceInit = %v, want %v", c.name, got, c.want)
		}
	}
}
