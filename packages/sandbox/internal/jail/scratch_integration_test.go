//go:build darwin || linux

package jail_test

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"

	"github.com/roasbeef/loom/sandbox/internal/jail"
	"github.com/roasbeef/loom/sandbox/internal/policy"
	"github.com/roasbeef/loom/sandbox/internal/testbin"
)

// TestExecutionScratchDirectory exercises the real helper rather than just
// a Seatbelt profile: directory allocation, environment filtering, payload
// execution and cleanup all have to agree about the same directory.
func TestExecutionScratchDirectory(t *testing.T) {
	feat := jail.DetectFeatures()
	root := t.TempDir()
	pol := policy.Policy{
		WritableRoots: []string{root},
		ReadableRoots: []string{},
		Protected:     []string{},
		Network:       policy.Network{Mode: policy.NetworkOff},
		Limits:        policy.Limits{WallSeconds: 20, OutputBytes: 4096},
		EnvAllow:      []string{"PATH", "TMPDIR", "LOOM_SCRATCH_DIR"},
		Scratch:       "tmpfs",
	}

	run := func(pol policy.Policy, script string, args ...string) string {
		t.Helper()
		var mu sync.Mutex
		var stdout, stderr strings.Builder
		ex, err := jail.Start(jail.Request{
			Argv: append([]string{"/bin/sh", "-eu", "-c", script, "scratch-test"}, args...),
			Env: map[string]string{
				"PATH":             "/usr/bin:/bin",
				"TMPDIR":           root,
				"LOOM_SCRATCH_DIR": "/forged/caller/path",
			},
			Cwd: "/", Policy: pol,
		}, feat, testbin.Helper(t), func(stream string, data []byte, _ uint64, _ bool) {
			mu.Lock()
			defer mu.Unlock()
			if stream == "stdout" {
				stdout.Write(data)
			} else {
				stderr.Write(data)
			}
		})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { ex.Cancel() })
		if err := ex.WriteStdin(nil, true); err != nil {
			t.Fatal(err)
		}
		result := ex.Wait()
		mu.Lock()
		defer mu.Unlock()
		if result.Code != 0 || result.Signal != 0 {
			t.Fatalf("exit %d/%d: %s (enforcement %v)", result.Code, result.Signal, stderr.String(), result.Enforcement)
		}
		return strings.TrimSpace(stdout.String())
	}

	// Explicit TMPDIR remains a writable fallback, including when Linux
	// has no mount namespace. A forged helper-owned value never survives.
	if runtime.GOOS == "linux" && feat.BwrapPath == "" {
		run(pol, `test "${LOOM_SCRATCH_DIR+x}" != x; echo fallback > "$TMPDIR/fallback"`)
	} else {
		scratch := run(pol, `
test "$TMPDIR" = "$1"
echo fallback > "$TMPDIR/fallback"
test -n "$LOOM_SCRATCH_DIR"
probe=$(mktemp "$LOOM_SCRATCH_DIR/probe.XXXXXX")
echo private > "$probe"
test "$(cat "$probe")" = private
printf '%s\n' "$LOOM_SCRATCH_DIR"
`, root)
		if runtime.GOOS == "darwin" {
			if !strings.HasPrefix(scratch, "/private/tmp/loom-exec-scratch-") {
				t.Fatalf("unexpected private directory %q", scratch)
			}
			if _, err := os.Stat(scratch); !os.IsNotExist(err) {
				t.Fatalf("private scratch remains after Wait: %v", err)
			}

			// Another directory under the same host parent remains outside
			// this execution. Exposing one path must not grant all of /tmp.
			sibling, err := os.MkdirTemp(jail.SeatbeltScratchParent, "loom-scratch-outside-")
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { os.RemoveAll(sibling) })
			run(pol, `if (echo escaped > "$1/probe") 2>/dev/null; then exit 41; fi`, sibling)
		} else if scratch != jail.ScratchMount {
			t.Fatalf("mounted scratch = %q", scratch)
		}
	}
	if got, err := os.ReadFile(filepath.Join(root, "fallback")); err != nil || string(got) != "fallback\n" {
		t.Fatalf("explicit TMPDIR was not preserved: %q, %v", got, err)
	}

	// Even a generated path is withheld unless the effective policy
	// allows its name. The helper must not bypass the environment meet.
	pol.EnvAllow = []string{"PATH", "TMPDIR"}
	run(pol, `test "${LOOM_SCRATCH_DIR+x}" != x`)
}
