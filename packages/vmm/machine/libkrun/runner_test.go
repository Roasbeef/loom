package libkrun

import (
	"os"
	"path/filepath"
	"testing"
)

// TestResolveRunnerFollowsSymlinks checks that a runner reached through a
// symlink, as the integration fixture and a package manager's bin directory
// reach it, is handed to go-microvm under its real path. go-microvm compares
// /proc/PID/exe with that path before it signals a pid, so the link's own
// path made Stop a silent no-op on Linux.
func TestResolveRunnerFollowsSymlinks(t *testing.T) {
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}

	real := filepath.Join(dir, "go-microvm-runner")
	if err := os.WriteFile(real, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	link := filepath.Join(dir, "link")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}

	if got := resolveRunner(link); got != real {
		t.Fatalf("resolveRunner(link) = %q, want %q", got, real)
	}

	if got := resolveRunner(real); got != real {
		t.Fatalf("resolveRunner(real) = %q, want %q", got, real)
	}

	missing := filepath.Join(dir, "absent")
	if got := resolveRunner(missing); got != missing {
		t.Fatalf("resolveRunner(missing) = %q, want it unchanged", got)
	}
}
