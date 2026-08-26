//go:build linux

package jail_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/roasbeef/loom/sandbox/internal/jail"
	"github.com/roasbeef/loom/sandbox/internal/policy"
)

// A protected path that is a symlink must be masked at its target.
// bwrap resolves a mount's destination inside the pivot root it is
// building, where the link's target does not exist yet, so binding the
// link's own name fails outright — measured: "Can't bind mount ...: No
// such file or directory", exit 1, no jail at all. Masking the resolved
// target works and covers both names.
func TestProtectedSymlinkIsMaskedAtItsTarget(t *testing.T) {
	feat := jail.DetectFeatures()
	if feat.BwrapPath == "" {
		t.Skip("protected-path masking needs bwrap")
	}
	dir := t.TempDir()
	real := filepath.Join(dir, "real-secrets")
	if err := os.MkdirAll(real, 0o755); err != nil {
		t.Fatal(err)
	}
	const marker = "LOOM-PROBE-PRIVATE-KEY-BYTES"
	if err := os.WriteFile(filepath.Join(real, "key"), []byte(marker+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "dot-ssh")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}

	pol := policy.Policy{
		WritableRoots: []string{dir},
		ReadableRoots: []string{},
		Network:       policy.Network{Mode: policy.NetworkOff},
		Limits:        policy.Limits{WallSeconds: 30, OutputBytes: 1 << 20},
		EnvAllow:      []string{"PATH"},
		Scratch:       "tmpfs",
		Protected:     []string{link},
	}

	c := newCollector()
	ex := start(t, pol, []string{"/bin/sh", "-c",
		"echo JAIL-RAN; cat " + link + "/key; cat " + real + "/key"}, c.sink)
	_ = ex.WriteStdin(nil, true)
	res := ex.Wait()
	out := c.out()
	if !strings.Contains(out, "JAIL-RAN") {
		t.Fatalf("the jail never started, so nothing was masked: out %q err %q, %+v", out, c.stderrString(), res)
	}
	if strings.Contains(out, marker) {
		t.Fatalf("the protected symlink's contents were readable: out %q", out)
	}
}

func (c *collector) stderrString() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.stderr.String()
}
