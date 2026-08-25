// Package testbin builds the loom-exec binary for integration tests.
// The jail runner re-invokes loom-exec as its restrict-and-exec stage,
// so tests that spawn real jails need the real binary, not the test
// binary that happens to be running them.
package testbin

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
	"testing"
)

var (
	once sync.Once
	path string
	err  error
)

// Helper compiles cmd/loom-exec once per test process and returns its
// path. Tests are skipped, not failed, when no Go toolchain is around
// (e.g. running a pre-built test binary on a bare CI runner).
func Helper(t *testing.T) string {
	t.Helper()
	once.Do(build)
	if err != nil {
		t.Skipf("cannot build loom-exec helper: %v", err)
	}
	return path
}

func build() {
	goTool := filepath.Join(runtime.GOROOT(), "bin", "go")
	if _, statErr := exec.LookPath(goTool); statErr != nil {
		if p, lookErr := exec.LookPath("go"); lookErr == nil {
			goTool = p
		} else {
			err = statErr
			return
		}
	}
	// Tests run with cwd = their package dir; every internal package
	// sits two levels below the module root.
	dir, mkErr := filepath.Abs("../../")
	if mkErr != nil {
		err = mkErr
		return
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
