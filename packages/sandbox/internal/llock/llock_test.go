package llock

import (
	"reflect"
	"testing"
)

func TestRules(t *testing.T) {
	got := Rules(PolicyView{
		WritableRoots: []string{"/work/b", "/work/a"},
		ReadableRoots: []string{"/opt"},
		ScratchPath:   "/tmp",
	})
	want := []Rule{
		{Path: "/", Access: ReadOnly},
		{Path: "/opt", Access: ReadOnly, Optional: true},
		{Path: "/work/a", Access: ReadWrite, Optional: true},
		{Path: "/work/b", Access: ReadWrite, Optional: true},
		{Path: "/tmp", Access: ReadWrite, Optional: true},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Rules mismatch:\n got  %v\nwant %v", got, want)
	}
}

func TestRulesNoScratch(t *testing.T) {
	got := Rules(PolicyView{WritableRoots: []string{"/w"}})
	want := []Rule{
		{Path: "/", Access: ReadOnly},
		{Path: "/w", Access: ReadWrite, Optional: true},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Rules mismatch:\n got  %v\nwant %v", got, want)
	}
}

// The root grant must always be present and first: everything else is
// carve-up, and losing it would make the jail unable to exec anything.
func TestRulesAlwaysGrantRootRead(t *testing.T) {
	got := Rules(PolicyView{})
	if len(got) == 0 || got[0].Path != "/" || got[0].Access != ReadOnly {
		t.Fatalf("missing root read grant: %v", got)
	}
}
