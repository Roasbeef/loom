package libkrun

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestKvmUsableOpensTheDevice checks that the probe opens the device. A file
// the caller may read and write stands for a KVM device the user can use, a
// missing path for a host with no KVM, and a file the caller may not open for
// a device that exists but belongs to a group the user is not in.
func TestKvmUsableOpensTheDevice(t *testing.T) {
	dir := t.TempDir()

	open := filepath.Join(dir, "kvm")
	if err := os.WriteFile(open, nil, 0o600); err != nil {
		t.Fatal(err)
	}

	if ok, reason := kvmUsable(open); !ok {
		t.Fatalf("an openable device was refused: %s", reason)
	}

	missing := filepath.Join(dir, "absent")
	if ok, reason := kvmUsable(missing); ok || !strings.Contains(reason, missing) {
		t.Fatalf("a missing device: ok=%v reason=%q", ok, reason)
	}

	closed := filepath.Join(dir, "closed")
	if err := os.WriteFile(closed, nil, 0o000); err != nil {
		t.Fatal(err)
	}

	// Root opens a mode 000 file, so there is nothing to refuse.
	if os.Geteuid() == 0 {
		t.Skip("running as root: permissions do not apply")
	}

	if ok, reason := kvmUsable(closed); ok || !strings.Contains(reason, "permission denied") {
		t.Fatalf("a closed device: ok=%v reason=%q", ok, reason)
	}
}
