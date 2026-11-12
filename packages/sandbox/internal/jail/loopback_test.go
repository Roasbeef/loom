package jail

import (
	"strings"
	"testing"

	"github.com/roasbeef/loom/sandbox/internal/policy"
)

// Loopback mode is a seccomp program that admits TCP sockets, and only a
// fresh network namespace keeps those sockets off the host. Every path
// that does not create one must refuse the mode, not run it.
func TestStartRefusesLoopbackWithoutAFreshNetworkNamespace(t *testing.T) {
	pol := policy.Policy{
		WritableRoots: []string{t.TempDir()},
		ReadableRoots: []string{},
		Protected:     []string{},
		Network:       policy.Network{Mode: policy.NetworkLoopback},
		Limits:        policy.Limits{WallSeconds: 5, OutputBytes: 1 << 10},
		EnvAllow:      []string{"PATH"},
		Scratch:       "tmpfs",
	}
	cases := []struct {
		name string
		feat Features
	}{
		{"linux degraded, no bwrap", Features{Platform: PlatformFor("linux")}},
		{"darwin seatbelt", Features{
			Platform: PlatformFor("darwin"), SeatbeltPath: SeatbeltExecutable,
		}},
		{"unsupported platform", Features{Platform: PlatformFor("windows")}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ex, err := Start(Request{
				Argv: []string{"/bin/true"}, Cwd: "/", Policy: pol,
			}, tc.feat, "/nonexistent/loom-exec", nil)
			if err == nil {
				ex.Wait()
				t.Fatal("loopback mode started without a fresh network namespace")
			}
			if !strings.Contains(err.Error(), "loopback") {
				t.Fatalf("refusal does not name the mode: %v", err)
			}
		})
	}
}
