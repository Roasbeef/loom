package jail

import (
	"reflect"
	"testing"

	"github.com/roasbeef/loom/sandbox/internal/policy"
)

func basePol() policy.Policy {
	return policy.Policy{
		WritableRoots: []string{"/work"},
		ReadableRoots: []string{"/opt/tools"},
		Protected:     []string{"/work/.git", "/work/.env"},
		Network:       policy.Network{Mode: policy.NetworkOff},
		Limits:        policy.Limits{OutputBytes: 1 << 20},
		EnvAllow:      []string{"PATH"},
		Scratch:       "tmpfs",
	}
}

// TestBwrapArgsGolden pins the exact argv for a representative policy.
// Any change here is a change to the jail's shape and must be reviewed
// as such — that is the point of a golden test at a security boundary.
func TestBwrapArgsGolden(t *testing.T) {
	p := basePol()
	kinds := map[string]PathKind{
		"/work/.git": PathDir,
		"/work/.env": PathFile,
	}
	got := BwrapArgs(p, kinds)
	want := []string{
		"--die-with-parent",
		"--unshare-pid",
		"--unshare-ipc",
		"--unshare-uts",
		"--unshare-user-try",
		"--unshare-cgroup-try",
		"--unshare-net",
		"--ro-bind", "/", "/",
		"--proc", "/proc",
		"--dev", "/dev",
		"--ro-bind", "/opt/tools", "/opt/tools",
		"--bind", "/work", "/work",
		"--ro-bind", "/work/.env", "/work/.env",
		"--tmpfs", "/work/.git", "--remount-ro", "/work/.git",
		"--tmpfs", "/tmp",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("bwrap argv mismatch:\n got  %q\nwant %q", got, want)
	}
}

func TestBwrapArgsNetworkFullKeepsNet(t *testing.T) {
	p := basePol()
	p.Network = policy.Network{Mode: policy.NetworkFull}
	for _, a := range BwrapArgs(p, nil) {
		if a == "--unshare-net" {
			t.Fatal("--unshare-net present under network full")
		}
	}
}

// Proxy mode has no enforcing sidecar in phase 1, so the jail must
// fail closed: network unshared exactly as under off, never silent
// unrestricted egress.
func TestBwrapArgsNetworkProxyUnsharesNet(t *testing.T) {
	p := basePol()
	p.Network = policy.Network{
		Mode:  policy.NetworkProxy,
		Allow: []string{"*.npmjs.org"},
		Proxy: "127.0.0.1:3128",
	}
	found := false
	for _, a := range BwrapArgs(p, nil) {
		if a == "--unshare-net" {
			found = true
		}
	}
	if !found {
		t.Fatal("--unshare-net missing under network proxy (must fail closed)")
	}
}

func TestBlocksDirectNetwork(t *testing.T) {
	cases := []struct {
		mode policy.NetworkMode
		want bool
	}{
		{policy.NetworkOff, true},
		{policy.NetworkProxy, true},
		{policy.NetworkFull, false},
	}
	for _, c := range cases {
		if got := BlocksDirectNetwork(c.mode); got != c.want {
			t.Fatalf("BlocksDirectNetwork(%q) = %v, want %v", c.mode, got, c.want)
		}
	}
}

func TestBwrapArgsNetworkOffUnsharesNet(t *testing.T) {
	found := false
	for _, a := range BwrapArgs(basePol(), nil) {
		if a == "--unshare-net" {
			found = true
		}
	}
	if !found {
		t.Fatal("--unshare-net missing under network off")
	}
}

// A protected path that does not exist yet is still masked so the jail
// cannot create it.
func TestBwrapArgsMissingProtectedMasked(t *testing.T) {
	p := basePol()
	p.Protected = []string{"/home/user/.ssh"}
	got := BwrapArgs(p, map[string]PathKind{"/home/user/.ssh": PathMissing})
	if !containsSeq(got, []string{"--tmpfs", "/home/user/.ssh", "--remount-ro", "/home/user/.ssh"}) {
		t.Fatalf("missing protected path not tmpfs-masked: %q", got)
	}
}

func TestBwrapArgsPathScratch(t *testing.T) {
	p := basePol()
	p.Scratch = "/var/scratch"
	got := BwrapArgs(p, nil)
	if !containsSeq(got, []string{"--bind", "/var/scratch", "/var/scratch"}) {
		t.Fatalf("path scratch not bind-mounted rw: %q", got)
	}
	for _, a := range got {
		if a == ScratchMount {
			t.Fatalf("path scratch must not also mount %s", ScratchMount)
		}
	}
}

// Determinism: identical policies yield byte-identical argv regardless
// of input slice order (bind order is part of the security semantics).
func TestBwrapArgsDeterministic(t *testing.T) {
	p1 := basePol()
	p1.WritableRoots = []string{"/b", "/a"}
	p2 := basePol()
	p2.WritableRoots = []string{"/a", "/b"}
	if !reflect.DeepEqual(BwrapArgs(p1, nil), BwrapArgs(p2, nil)) {
		t.Fatal("argv depends on input ordering")
	}
}

func containsSeq(haystack, needle []string) bool {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if reflect.DeepEqual(haystack[i:i+len(needle)], needle) {
			return true
		}
	}
	return false
}
