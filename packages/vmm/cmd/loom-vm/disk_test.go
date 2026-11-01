package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestEnsureDiskCreatesSparseImageOnce checks that a missing state disk is
// created at the requested size and that an existing one is reused as it is,
// which is what keeps a standing guest's state across restarts.
func TestEnsureDiskCreatesSparseImageOnce(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.img")

	got, err := ensureDisk(path, 8<<20)
	if err != nil {
		t.Fatal(err)
	}
	if got != path {
		t.Fatalf("ensureDisk = %q, want %q", got, path)
	}

	info, err := os.Stat(path)
	if err != nil || info.Size() != 8<<20 || info.Mode().Perm() != 0o600 {
		t.Fatalf("created disk = %v, %v", info, err)
	}

	// Data the guest wrote must survive a second call with another size.
	if err := os.WriteFile(path, []byte("ext4 data"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ensureDisk(path, 16<<20); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(path)
	if string(raw) != "ext4 data" {
		t.Fatalf("existing disk rewritten: %q", raw)
	}
}

// TestEnsureDiskRefusesDirectory checks that a directory at the path is an
// error rather than something the hypervisor is asked to open.
func TestEnsureDiskRefusesDirectory(t *testing.T) {
	if _, err := ensureDisk(t.TempDir(), 1<<20); err == nil {
		t.Fatal("a directory was accepted as a state disk")
	}
}

// TestRunContextZeroTimeoutHasNoDeadline checks that --timeout 0 runs until
// it is cancelled, as a standing guest must.
func TestRunContextZeroTimeoutHasNoDeadline(t *testing.T) {
	ctx, cancel := runContext(0)
	defer cancel()

	if _, ok := ctx.Deadline(); ok {
		t.Fatal("a zero timeout set a deadline")
	}

	ctx, cancel = runContext(time.Minute)
	defer cancel()
	if _, ok := ctx.Deadline(); !ok {
		t.Fatal("a nonzero timeout set no deadline")
	}
}

// TestProxyLifetimeForStandingRun checks that a run with no timeout gets the
// standing CA lifetime rather than one hour past a zero timeout.
func TestProxyLifetimeForStandingRun(t *testing.T) {
	if got := proxyLifetime(0); got != standingProxyLifetime {
		t.Fatalf("proxyLifetime(0) = %v", got)
	}
	if got := proxyLifetime(time.Minute); got != time.Minute+proxyLifetimeMargin {
		t.Fatalf("proxyLifetime(1m) = %v", got)
	}
}
