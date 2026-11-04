package setup

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// validManifest is a manifest that passes Validate.
func validManifest() Manifest {
	return Manifest{
		Version:     1,
		Revision:    "dev",
		LoomVM:      "/a/loom-vm",
		Runner:      "/a/runner",
		LibDir:      "/a/lib",
		FirmwareDir: "/a/fw",
		GuestRoot:   "/a/root",
	}
}

// TestManifestJSONShape pins the documented contract: these keys, in this
// order, with an empty firmware_dir kept as "".
func TestManifestJSONShape(t *testing.T) {
	m := validManifest()
	m.FirmwareDir = ""

	raw, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}

	want := `{"version":1,"revision":"dev","loom_vm":"/a/loom-vm","runner":"/a/runner",` +
		`"lib_dir":"/a/lib","firmware_dir":"","guest_root":"/a/root"}`
	if string(raw) != want {
		t.Fatalf("manifest JSON\n got %s\nwant %s", raw, want)
	}
}

// TestWriteManifestIsAtomic checks that writing replaces the manifest
// without leaving a temporary file, that the result decodes, and that a
// failed write leaves no temporary file behind.
func TestWriteManifestIsAtomic(t *testing.T) {
	home := filepath.Join(t.TempDir(), "home")

	first := validManifest()
	if err := WriteManifest(home, first); err != nil {
		t.Fatal(err)
	}

	second := validManifest()
	second.Revision = "abc123"
	if err := WriteManifest(home, second); err != nil {
		t.Fatal(err)
	}

	got, err := ReadManifest(home)
	if err != nil || got != second {
		t.Fatalf("ReadManifest = %+v, %v; want %+v", got, err, second)
	}

	ents, _ := os.ReadDir(home)
	if len(ents) != 1 || ents[0].Name() != "manifest.json" {
		t.Errorf("home holds %v, want only manifest.json", ents)
	}

	info, _ := os.Stat(ManifestPath(home))
	if info.Mode().Perm() != 0o644 {
		t.Errorf("manifest mode = %v", info.Mode().Perm())
	}

	// An invalid manifest is refused before the old one is touched.
	bad := validManifest()
	bad.Runner = "relative/runner"
	if err := WriteManifest(home, bad); err == nil {
		t.Fatal("accepted a relative path")
	}
	if got, err := ReadManifest(home); err != nil || got != second {
		t.Fatalf("manifest changed by a refused write: %+v, %v", got, err)
	}

	// A rename that cannot succeed (the target is a directory) fails and
	// leaves no temporary file.
	blocked := filepath.Join(t.TempDir(), "home")
	if err := os.MkdirAll(ManifestPath(blocked), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := WriteManifest(blocked, first); err == nil {
		t.Fatal("wrote over a directory")
	}
	ents, _ = os.ReadDir(blocked)
	if len(ents) != 1 {
		t.Errorf("failed write left %v", ents)
	}
}

// TestValidateRefusals covers each field the contract requires.
func TestValidateRefusals(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*Manifest)
		want   string
	}{
		{"version", func(m *Manifest) { m.Version = 2 }, "version 2"},
		{"revision", func(m *Manifest) { m.Revision = "" }, "no revision"},
		{"loom_vm", func(m *Manifest) { m.LoomVM = "loom-vm" }, "loom_vm"},
		{"runner", func(m *Manifest) { m.Runner = "" }, "runner"},
		{"lib_dir", func(m *Manifest) { m.LibDir = "lib" }, "lib_dir"},
		{"guest_root", func(m *Manifest) { m.GuestRoot = "root" }, "guest_root"},
		{"firmware_dir", func(m *Manifest) { m.FirmwareDir = "fw" }, "firmware_dir"},
	}

	for _, tc := range cases {
		m := validManifest()
		tc.mutate(&m)

		err := m.Validate()
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: err = %v, want %q", tc.name, err, tc.want)
		}
	}
}

// TestDefaultHome checks $LOOM_VM_HOME and the fallback under the user's
// home.
func TestDefaultHome(t *testing.T) {
	t.Setenv("LOOM_VM_HOME", "/x/y")
	if got, err := DefaultHome(); err != nil || got != "/x/y" {
		t.Errorf("DefaultHome = %q, %v", got, err)
	}

	t.Setenv("LOOM_VM_HOME", "")
	t.Setenv("HOME", "/users/me")
	if got, err := DefaultHome(); err != nil || got != "/users/me/.loom/vm" {
		t.Errorf("DefaultHome = %q, %v", got, err)
	}
}
