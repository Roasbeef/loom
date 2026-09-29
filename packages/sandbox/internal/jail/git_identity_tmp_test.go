//go:build linux || darwin

package jail

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/roasbeef/loom/sandbox/internal/policy"
)

// tmpWorkspace makes a real workspace beneath /tmp, the ScratchMount, with a
// tmpfs scratch policy that grants only that workspace. On macOS /tmp is
// itself a symlink, so the same fixture also covers a symlinked spelling.
func tmpWorkspace(t *testing.T) (policy.Policy, string) {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "loom-gitid-")
	if err != nil {
		t.Skipf("no writable /tmp: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	if err := os.MkdirAll(filepath.Join(dir, ".codemode", "home"), 0700); err != nil {
		t.Fatal(err)
	}
	return policy.Policy{
		WritableRoots: []string{dir},
		ReadableRoots: []string{"/"},
		Network:       policy.Network{Mode: policy.NetworkOff},
		Scratch:       "tmpfs",
	}, dir
}

// Seatbelt mounts nothing over /tmp, so a workspace beneath it is an
// ordinary host path and publication must succeed, given as /tmp/x and as
// its canonical spelling.
func TestGitIdentityAuthorityAllowsTmpWorkspaceOnDarwin(t *testing.T) {
	pol, dir := tmpWorkspace(t)
	canonical, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, spelling := range []string{dir, canonical} {
		if _, _, err := gitIdentityAuthority(pol, spelling, ".gitconfig-test", "darwin"); err != nil {
			t.Fatalf("workspace %s refused: %v", spelling, err)
		}
	}
}

// Linux mounts a tmpfs over /tmp inside the jail, so the same workspace is
// hidden there and the private-scratch refusal stays in force.
func TestGitIdentityAuthorityRefusesTmpWorkspaceOnLinux(t *testing.T) {
	pol, dir := tmpWorkspace(t)
	if _, _, err := gitIdentityAuthority(pol, dir, ".gitconfig-test", "linux"); err == nil {
		t.Fatal("a workspace hidden by the tmpfs scratch was treated as a host grant")
	}
}

// The end-to-end publication under a symlinked parent still resolves the
// granted root and refuses links below it.
func TestGitIdentityPublicationSymlinkedWorkspaceSpelling(t *testing.T) {
	pol, workspace, home := gitIdentityFixture(t)
	alias := filepath.Join(t.TempDir(), "alias")
	if err := os.Symlink(filepath.Dir(workspace), alias); err != nil {
		t.Fatal(err)
	}
	aliased := filepath.Join(alias, "workspace")
	pol.WritableRoots = []string{aliased}
	if err := PublishGitIdentity(pol, aliased, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(home, "gitconfig")); err != nil {
		t.Fatal(err)
	}
}
