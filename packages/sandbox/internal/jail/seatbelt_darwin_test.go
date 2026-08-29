//go:build darwin

package jail

import (
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/roasbeef/loom/sandbox/internal/policy"
)

func TestSeatbeltEnforcesFilesystemAndNetworkOnDarwin(t *testing.T) {
	if _, err := os.Stat(SeatbeltExecutable); err != nil {
		t.Skipf("%s unavailable: %v", SeatbeltExecutable, err)
	}

	root := t.TempDir()
	writable := filepath.Join(root, "writable")
	outside := filepath.Join(root, "outside")
	protected := filepath.Join(writable, "secret")
	for _, dir := range []string{writable, outside} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(protected, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	pol := policy.Policy{
		WritableRoots: []string{writable},
		Protected:     []string{protected},
		Network:       policy.Network{Mode: policy.NetworkOff},
		Scratch:       "tmpfs",
	}
	plan := SeatbeltPlanFor(pol, filepath.Join(root, "scratch"))

	insideFile := filepath.Join(writable, "created")
	runSeatbeltChild(t, plan, "write", insideFile)
	if _, err := os.Stat(insideFile); err != nil {
		t.Fatalf("write inside writable root failed: %v", err)
	}
	for name, target := range map[string]string{
		"outside write":   filepath.Join(outside, "escaped"),
		"protected write": protected,
		"protected read":  protected,
		"inet socket":     "unused",
	} {
		t.Run(name, func(t *testing.T) {
			mode := map[string]string{
				"outside write":   "write",
				"protected write": "write",
				"protected read":  "read",
				"inet socket":     "socket",
			}[name]
			runSeatbeltChildMustFail(t, plan, mode, target)
		})
	}
}

func runSeatbeltChild(t *testing.T, plan SeatbeltPlan, mode, target string) {
	t.Helper()
	argv := plan.Args([]string{os.Args[0], "-test.run=TestSeatbeltChildProcess"})
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Env = append(os.Environ(), "LOOM_SEATBELT_CHILD="+mode, "LOOM_SEATBELT_TARGET="+target)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("Seatbelt child failed: %v\n%s", err, out)
	}
}

func runSeatbeltChildMustFail(t *testing.T, plan SeatbeltPlan, mode, target string) {
	t.Helper()
	argv := plan.Args([]string{os.Args[0], "-test.run=TestSeatbeltChildProcess"})
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Env = append(os.Environ(), "LOOM_SEATBELT_CHILD="+mode, "LOOM_SEATBELT_TARGET="+target)
	if out, err := cmd.CombinedOutput(); err == nil {
		t.Fatalf("Seatbelt allowed %s on %s:\n%s", mode, target, out)
	}
}

func TestSeatbeltChildProcess(t *testing.T) {
	mode := os.Getenv("LOOM_SEATBELT_CHILD")
	if mode == "" {
		return
	}
	target := os.Getenv("LOOM_SEATBELT_TARGET")
	var err error
	switch mode {
	case "write":
		err = os.WriteFile(target, []byte("written"), 0o600)
	case "read":
		_, err = os.ReadFile(target)
	case "socket":
		var listener net.Listener
		listener, err = net.Listen("tcp4", "127.0.0.1:0")
		if listener != nil {
			_ = listener.Close()
		}
	default:
		t.Fatalf("unknown child mode %q", mode)
	}
	if err != nil {
		os.Exit(42)
	}
}
