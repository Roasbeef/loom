package setup

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Commander runs an external program and returns its combined output. Setup
// and Doctor take one instead of calling os/exec so that tests can observe the
// codesign and xattr calls on a host that has neither.
type Commander func(ctx context.Context, name string, args ...string) ([]byte, error)

// ExecCommander runs the program for real.
func ExecCommander(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).CombinedOutput()
}

// libkrunNames are the file names under which a libkrun install is
// recognised, for macOS and for Linux.
var libkrunNames = []string{
	"libkrun.dylib", "libkrun.1.dylib", "libkrun.so", "libkrun.so.1",
}

// hasLibkrun reports whether dir holds a libkrun library.
func hasLibkrun(dir string) bool {
	for _, n := range libkrunNames {
		if _, err := os.Stat(filepath.Join(dir, n)); err == nil {
			return true
		}
	}

	return false
}

// firmwareName is the file name the runner's loader looks for, which is also
// the name a firmware directory must hold the Landlock kernel under.
func firmwareName(goos string) string {
	if goos == "darwin" {
		return "libkrunfw.5.dylib"
	}

	return "libkrunfw.so.5"
}

// linuxLibDirs are where a distribution package puts libkrun.
var linuxLibDirs = []string{
	"/usr/lib64", "/usr/lib", "/usr/local/lib",
	"/usr/lib/x86_64-linux-gnu", "/usr/lib/aarch64-linux-gnu",
}

// FindLibDir returns the absolute directory holding libkrun. An explicit
// directory wins and must contain libkrun. Otherwise macOS asks Homebrew for
// its prefix and Linux tries the usual library directories.
//
// A missing libkrun is the one setup failure the user must fix outside loom,
// so the error says how, rather than naming the paths that were searched.
//
// ## Examples
//
//	dir, err := FindLibDir(ctx, "", "darwin", setup.ExecCommander)
func FindLibDir(ctx context.Context, explicit, goos string, run Commander) (string, error) {
	if explicit != "" {
		abs, err := filepath.Abs(explicit)
		if err != nil {
			return "", err
		}

		if !hasLibkrun(abs) {
			return "", fmt.Errorf("no libkrun in --lib-dir %s", abs)
		}

		return abs, nil
	}

	var candidates []string
	switch goos {
	case "darwin":
		// Homebrew's own answer first, so a non-default prefix works. The
		// runner links libkrun at /opt/homebrew/opt/libkrun, so Apple
		// Silicon's prefix is also the fallback.
		if out, err := run(ctx, "brew", "--prefix"); err == nil {
			candidates = append(candidates, filepath.Join(strings.TrimSpace(string(out)), "lib"))
		}
		candidates = append(candidates, "/opt/homebrew/lib")

	default:
		candidates = linuxLibDirs
	}

	for _, dir := range candidates {
		if hasLibkrun(dir) {
			return dir, nil
		}
	}

	return "", fmt.Errorf("libkrun is not installed: %s", installHint(goos))
}

// installHint says how to get libkrun on goos.
func installHint(goos string) string {
	if goos == "darwin" {
		return "run `brew install libkrun` (from the libkrun/krun tap: " +
			"`brew tap libkrun/krun`), or pass --lib-dir"
	}

	return "build libkrun with `make vmm-libkrun` (Ubuntu ships none) and pass " +
		"--lib-dir packages/vmm/build/libkrun/lib64, or pass --lib-dir for " +
		"another libkrun"
}

// selfPath is the absolute, symlink-resolved path of the running binary,
// which the manifest records as loom_vm.
func selfPath() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}

	return filepath.EvalSymlinks(exe)
}
