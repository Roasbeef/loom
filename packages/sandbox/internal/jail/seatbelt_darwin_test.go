//go:build darwin

package jail

import (
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/roasbeef/loom/sandbox/internal/policy"
)

func TestSeatbeltEnforcesFilesystemAndNetworkOnDarwin(t *testing.T) {
	if _, err := os.Stat(SeatbeltExecutable); err != nil {
		t.Skipf("%s unavailable: %v", SeatbeltExecutable, err)
	}

	// Not t.TempDir(): that lives under the user temp directory, which the
	// plan grants, so a sibling there is no longer "outside" the jail.
	root, err := os.MkdirTemp(SeatbeltScratchParent, "loom-seatbelt-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
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

	// The per-user darwin temp and cache directories are writable too, so
	// xcrun's cache and clang's module cache do not fail under the jail.
	// Read through the same confstr the plan used, not $TMPDIR, which a
	// test runner may have pointed elsewhere.
	userDirs := DarwinUserDirectories()
	if len(userDirs) != 2 {
		t.Fatalf("expected the user temp and cache directories, got %v", userDirs)
	}
	for _, dir := range userDirs {
		cacheFile := filepath.Join(dir, "loom-seatbelt-test-"+filepath.Base(root))
		runSeatbeltChild(t, plan, "write", cacheFile)
		if _, err := os.Stat(cacheFile); err != nil {
			t.Fatalf("write inside user directory %s failed: %v", dir, err)
		}
		os.Remove(cacheFile)
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

// TestSeatbeltJailedPathFindsHomebrewTools proves BuildPath end to end on
// this host: given an inherited PATH containing Homebrew's
// /opt/homebrew/bin — where rg actually lives on the repository owner's
// machine, and nowhere named by jailedPathDefaults — the jailed shell
// still finds it. The Seatbelt profile's own filesystem grants (/usr,
// /opt, /bin) already make the binary visible inside the jail; the only
// question this test answers is whether the environment we hand the
// jail carries the directory that names it.
func TestSeatbeltJailedPathFindsHomebrewTools(t *testing.T) {
	if _, err := os.Stat(SeatbeltExecutable); err != nil {
		t.Skipf("%s unavailable: %v", SeatbeltExecutable, err)
	}
	rgPath, err := exec.LookPath("rg")
	if err != nil {
		t.Skip("rg not installed on this host")
	}
	homebrewBin := filepath.Dir(rgPath)

	root, err := os.MkdirTemp(SeatbeltScratchParent, "loom-seatbelt-path-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })

	pol := policy.Policy{
		Network: policy.Network{Mode: policy.NetworkOff},
		Scratch: "tmpfs",
	}
	plan := SeatbeltPlanFor(pol, filepath.Join(root, "scratch"))

	// Mirrors run.go: an inherited PATH naming only the Homebrew
	// directory, folded with the fixed defaults by BuildPath, is what the
	// jailed process actually receives as its PATH.
	jailedPath := strings.Join(BuildPath("", homebrewBin, nil), ":")

	argv := plan.Args([]string{"/bin/sh", "-c", "command -v rg"})
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Env = []string{"PATH=" + jailedPath}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("jailed `command -v rg` failed: %v\n%s", err, out)
	}
	got := strings.TrimSpace(string(out))
	if got != rgPath {
		t.Fatalf("jailed `command -v rg` = %q, want %q", got, rgPath)
	}
}
