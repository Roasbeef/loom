package setup

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// buildTree makes a build directory like packages/vmm/build. Each argument
// names a piece to leave out.
func buildTree(t *testing.T, omit ...string) string {
	t.Helper()

	dir := t.TempDir()
	pieces := map[string]func(){
		"runner": func() {
			os.WriteFile(filepath.Join(dir, "go-microvm-runner"), []byte("r"), 0o755)
		},
		"root": func() {
			os.MkdirAll(filepath.Join(dir, "guest-root", "tmp"), 0o755)
		},
		"firmware": func() {
			os.MkdirAll(filepath.Join(dir, "firmware"), 0o755)
			os.WriteFile(filepath.Join(dir, "firmware", "libkrunfw.5.dylib"), []byte("f"), 0o755)
		},
	}
	for name, build := range pieces {
		if !contains(omit, name) {
			build()
		}
	}

	return dir
}

// TestFromBuildWritesAManifest checks the paths recorded for a build tree and
// the default revision.
func TestFromBuildWritesAManifest(t *testing.T) {
	dir := buildTree(t)
	home := filepath.Join(t.TempDir(), "home")
	lib := fakeLibDir(t)

	m, err := FromBuild(context.Background(), BuildOptions{
		Home: home, Dir: dir, LibDir: lib, GOOS: "darwin", LoomVM: "/x/loom-vm",
	})
	if err != nil {
		t.Fatal(err)
	}

	want := Manifest{
		Version:     1,
		Revision:    "dev",
		LoomVM:      "/x/loom-vm",
		Runner:      filepath.Join(dir, "go-microvm-runner"),
		LibDir:      lib,
		FirmwareDir: filepath.Join(dir, "firmware"),
		GuestRoot:   filepath.Join(dir, "guest-root"),
	}
	if m != want {
		t.Fatalf("manifest = %+v\nwant       %+v", m, want)
	}

	if got, err := ReadManifest(home); err != nil || got != want {
		t.Fatalf("ReadManifest = %+v, %v", got, err)
	}

	m, err = FromBuild(context.Background(), BuildOptions{
		Home: home, Dir: dir, LibDir: lib, GOOS: "darwin", LoomVM: "/x/loom-vm",
		Revision: "abc123",
	})
	if err != nil || m.Revision != "abc123" {
		t.Fatalf("revision = %q, %v", m.Revision, err)
	}
}

// TestFromBuildWithoutFirmware checks that a tree with no custom kernel is
// accepted and records an empty firmware directory.
func TestFromBuildWithoutFirmware(t *testing.T) {
	m, err := FromBuild(context.Background(), BuildOptions{
		Home: t.TempDir(), Dir: buildTree(t, "firmware"), LibDir: fakeLibDir(t),
		GOOS: "darwin", LoomVM: "/x/loom-vm",
	})
	if err != nil || m.FirmwareDir != "" {
		t.Fatalf("firmware_dir = %q, %v", m.FirmwareDir, err)
	}
}

// TestFromBuildRefusals checks that a missing piece is reported with the make
// target that builds it, and that a missing libkrun names brew.
func TestFromBuildRefusals(t *testing.T) {
	home := t.TempDir()

	for _, tc := range []struct {
		omit, want string
	}{
		{"runner", "make vmm-runner"},
		{"root", "make vmm-guest-root"},
	} {
		_, err := FromBuild(context.Background(), BuildOptions{
			Home: home, Dir: buildTree(t, tc.omit), LibDir: fakeLibDir(t),
			GOOS: "darwin", LoomVM: "/x/loom-vm",
		})
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("without %s: err = %v, want %q", tc.omit, err, tc.want)
		}
	}

	// With no --lib-dir and no libkrun under the prefix brew reports, setup
	// says what to install. A host with libkrun at Homebrew's default
	// prefix would find it through the fallback instead.
	if _, err := os.Stat("/opt/homebrew/lib/libkrun.dylib"); err == nil {
		t.Skip("this host has libkrun in the fallback directory")
	}

	fake := &fakeRun{out: map[string]string{"brew": t.TempDir() + "\n"}}
	_, err := FromBuild(context.Background(), BuildOptions{
		Home: home, Dir: buildTree(t), GOOS: "darwin", LoomVM: "/x/loom-vm",
		Run: fake.run,
	})
	if err == nil || !strings.Contains(err.Error(), "brew install libkrun") {
		t.Errorf("missing libkrun: err = %v", err)
	}

	if _, err := os.Stat(ManifestPath(home)); !os.IsNotExist(err) {
		t.Errorf("a manifest was written despite the refusals: %v", err)
	}
}

// TestFindLibDirUsesBrewPrefix checks that Homebrew's own prefix is asked
// before any default.
func TestFindLibDirUsesBrewPrefix(t *testing.T) {
	prefix := t.TempDir()
	lib := filepath.Join(prefix, "lib")
	if err := os.MkdirAll(lib, 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(lib, "libkrun.dylib"), nil, 0o644)

	fake := &fakeRun{out: map[string]string{"brew": prefix + "\n"}}
	got, err := FindLibDir(context.Background(), "", "darwin", fake.run)
	if err != nil || got != lib {
		t.Fatalf("FindLibDir = %q, %v; want %q", got, err, lib)
	}

	// An explicit directory without libkrun is refused, not skipped.
	if _, err := FindLibDir(context.Background(), t.TempDir(), "darwin", fake.run); err == nil {
		t.Error("accepted an explicit directory with no libkrun")
	}
}
