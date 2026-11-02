package libkrun

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/roasbeef/loom/vmm/machine"
)

// TestEgressPolicyNeverNil checks that an empty allowlist still produces a
// policy. A nil policy is what leaves go-microvm's firewall allowing by
// default, so "no hosts" must reach it as an empty list, not as nothing.
func TestEgressPolicyNeverNil(t *testing.T) {
	p := egressPolicy(machine.Egress{})
	if p.AllowedHosts == nil {
		t.Fatal("empty egress produced a nil host list")
	}

	p = egressPolicy(machine.Egress{Hosts: []string{"a.example", "*.b.example"}})
	if len(p.AllowedHosts) != 2 || p.AllowedHosts[1].Name != "*.b.example" {
		t.Fatalf("hosts = %+v", p.AllowedHosts)
	}
}

// TestLibraryPathPutsFirmwareFirst checks that a custom libkrunfw is found
// before the stock one in the libkrun directory (ADR-022 D3).
func TestLibraryPathPutsFirmwareFirst(t *testing.T) {
	sep := string(os.PathListSeparator)

	cases := []struct {
		cfg  Config
		want string
	}{
		{Config{LibDir: "/lib"}, "/lib"},
		{Config{FirmwareDir: "/fw"}, "/fw"},
		{Config{LibDir: "/lib", FirmwareDir: "/fw"}, "/fw" + sep + "/lib"},
		{Config{}, ""},
	}

	for _, tc := range cases {
		if got := libraryPath(tc.cfg); got != tc.want {
			t.Errorf("libraryPath(%+v) = %q, want %q", tc.cfg, got, tc.want)
		}
	}
}

// TestStageFileReplacesSymlink checks that a symlink an image left at a
// target is replaced, not followed out of the root.
func TestStageFileReplacesSymlink(t *testing.T) {
	root := t.TempDir()
	outside := filepath.Join(t.TempDir(), "victim")
	if err := os.WriteFile(outside, []byte("host"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := os.MkdirAll(filepath.Join(root, "etc"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "etc", "x")); err != nil {
		t.Fatal(err)
	}

	src := filepath.Join(t.TempDir(), "src")
	if err := os.WriteFile(src, []byte("guest"), 0o644); err != nil {
		t.Fatal(err)
	}

	f := machine.File{Source: src, Target: "/etc/x", Mode: 0o600}
	if err := stageFile(root, f); err != nil {
		t.Fatal(err)
	}

	host, _ := os.ReadFile(outside)
	if string(host) != "host" {
		t.Fatalf("host file rewritten through symlink: %q", host)
	}

	info, err := os.Lstat(filepath.Join(root, "etc", "x"))
	if err != nil || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0o600 {
		t.Fatalf("staged file = %v, %v", info, err)
	}
}

// TestStageFileRefusesLinkedParent plants real symlinks, to a directory
// outside the root, at a middle and at a last directory component, and checks
// that staging is refused and the outside directory is left empty.
func TestStageFileRefusesLinkedParent(t *testing.T) {
	src := filepath.Join(t.TempDir(), "src")
	if err := os.WriteFile(src, []byte("guest"), 0o644); err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		name, link, target string
	}{
		{"middle", "etc", "/etc/loom-vm/x"},
		{"last", "etc/loom-vm", "/etc/loom-vm/x"},
		{"dangling", "etc/loom-vm", "/etc/loom-vm/x"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			outside := t.TempDir()

			linkPath := filepath.Join(root, filepath.FromSlash(tc.link))
			if err := os.MkdirAll(filepath.Dir(linkPath), 0o755); err != nil {
				t.Fatal(err)
			}

			dest := outside
			if tc.name == "dangling" {
				dest = filepath.Join(outside, "absent")
			}
			if err := os.Symlink(dest, linkPath); err != nil {
				t.Fatal(err)
			}

			f := machine.File{Source: src, Target: tc.target, Mode: 0o600}
			if err := stageFile(root, f); err == nil {
				t.Fatal("stageFile followed a link out of the root")
			}

			entries, err := os.ReadDir(outside)
			if err != nil || len(entries) != 0 {
				t.Fatalf("outside directory touched: %v, %v", entries, err)
			}
		})
	}
}

// TestProbeNeedsRunner checks that a backend with no runner never claims
// to be usable, whatever the hypervisor says.
func TestProbeNeedsRunner(t *testing.T) {
	p := New(Config{}).Probe(t.Context())
	if p.Available == machine.Usable {
		t.Fatalf("probe without a runner = %+v", p)
	}

	p = New(Config{RunnerPath: filepath.Join(t.TempDir(), "absent")}).Probe(t.Context())
	if p.Available == machine.Usable {
		t.Fatalf("probe with a missing runner = %+v", p)
	}
}
