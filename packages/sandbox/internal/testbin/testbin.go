// Package testbin locates or builds the loom-exec binary for integration
// tests. The jail runner re-invokes loom-exec as its restrict-and-exec
// stage, so tests that spawn real jails need the real binary, not the test
// binary that happens to be running them.
package testbin

import (
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

var (
	once        sync.Once
	path        string
	err         error
	noToolchain bool
)

// Helper returns the path of a loom-exec built from the current sources,
// resolving it once per test process.
//
// It prefers the binary `make sandbox` leaves at the module root when that
// binary is newer than every Go source, go.mod and go.sum in the module.
// `go test ./...` runs the four packages that call Helper as separate
// processes at once, and each used to run its own `go build`. The Gleam
// helper suites made the same concurrent builds, and on the containerised
// signoff some of those builds read a zero-filled Go build-cache object
// and failed to link (PR #585). Every make target and the signoff build
// the helper first, so there the tests build nothing. A stale or missing
// prebuilt binary falls back to one build per process, so a bare `go test`
// after a source edit still tests the edited code.
//
// A missing Go toolchain is a missing prerequisite, so the test skips. A
// build that fails with the toolchain present is a test failure: the gate
// runs `go test` without -v, so a skip there would never reach the skip
// census and the suite would pass having run nothing.
func Helper(t *testing.T) string {
	t.Helper()
	once.Do(resolve)
	switch {
	case err == nil:
		return path

	case noToolchain:
		t.Skipf("no Go toolchain to build the loom-exec helper: %v", err)

	default:
		t.Fatalf("cannot build loom-exec helper: %v", err)
	}
	return ""
}

func resolve() {
	// Tests run with cwd = their package dir; every package that calls
	// Helper sits two levels below the module root.
	dir, absErr := filepath.Abs("../../")
	if absErr != nil {
		err = absErr
		return
	}
	prebuilt := filepath.Join(dir, "loom-exec")
	if current(prebuilt, dir) {
		path = prebuilt
		return
	}
	build(dir)
}

// current reports whether the binary at bin exists and was written no
// earlier than every file its build reads from the module. The module's
// build directory holds test binaries, not sources, so it is not walked.
// A `make sandbox` that finds nothing to rebuild may leave the binary's
// mtime alone, in which case a touched but unchanged source makes this
// report false and the caller builds; that costs one build, never a stale
// binary.
func current(bin, dir string) bool {
	info, statErr := os.Stat(bin)
	if statErr != nil || !info.Mode().IsRegular() {
		return false
	}
	var newest time.Time
	skip := filepath.Join(dir, "build")
	walkErr := filepath.WalkDir(dir, func(p string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() && p == skip {
			return filepath.SkipDir
		}
		name := d.Name()
		source := strings.HasSuffix(name, ".go") || name == "go.mod" || name == "go.sum"
		if d.IsDir() || !source {
			return nil
		}
		fi, infoErr := d.Info()
		if infoErr != nil {
			return infoErr
		}
		if fi.ModTime().After(newest) {
			newest = fi.ModTime()
		}
		return nil
	})
	return walkErr == nil && !info.ModTime().Before(newest)
}

func build(dir string) {
	goTool := filepath.Join(runtime.GOROOT(), "bin", "go")
	if _, statErr := exec.LookPath(goTool); statErr != nil {
		p, lookErr := exec.LookPath("go")
		if lookErr != nil {
			err = statErr
			noToolchain = true
			return
		}
		goTool = p
	}

	// Not the system temp directory. A "tmpfs" scratch policy mounts a
	// fresh tmpfs over jail.ScratchMount ("/tmp"), so a helper built
	// there is invisible from inside every jail the tests then start —
	// including to the jail runner itself, which re-invokes this very
	// binary as its restrict-and-exec stage. The failure looks like a
	// broken sandbox rather than a misplaced file, which is how it went
	// unnoticed on hosts without bubblewrap installed. The module's own
	// build directory is git-ignored and never a mount target.
	outDir := filepath.Join(dir, "build")
	if mkErr := os.MkdirAll(outDir, 0o755); mkErr != nil {
		err = mkErr
		return
	}
	out := filepath.Join(outDir, fmt.Sprintf("loom-exec-test-%d", os.Getpid()))
	cmd := exec.Command(goTool, "build", "-o", out, "./cmd/loom-exec")
	cmd.Dir = dir
	if outBytes, buildErr := cmd.CombinedOutput(); buildErr != nil {
		err = &buildError{msg: string(outBytes), err: buildErr}
		return
	}
	path = out
}

type buildError struct {
	msg string
	err error
}

func (b *buildError) Error() string { return b.err.Error() + ": " + b.msg }
