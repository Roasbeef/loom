package jail

import (
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/roasbeef/loom/sandbox/internal/policy"
)

func TestSeatbeltPlanIsDenyDefaultAndParameterized(t *testing.T) {
	pol := policy.Policy{
		WritableRoots: []string{"/work/space with quote \" and newline\n"},
		Protected:     []string{"/work/.git"},
		Network:       policy.Network{Mode: policy.NetworkOff},
		Scratch:       "tmpfs",
	}
	plan := SeatbeltPlanFor(pol, "/private/var/tmp/loom scratch")
	if !strings.Contains(plan.Profile, "(deny default)") {
		t.Fatalf("profile is not deny-default:\n%s", plan.Profile)
	}
	for _, raw := range []string{pol.WritableRoots[0], pol.Protected[0]} {
		if strings.Contains(plan.Profile, raw) {
			t.Fatalf("model-influenced path was interpolated into SBPL: %q", raw)
		}
	}
	if !strings.Contains(strings.Join(plan.Definitions, "\n"), "WRITABLE_ROOT_") ||
		!strings.Contains(strings.Join(plan.Definitions, "\n"), "PROTECTED_PATH_") {
		t.Fatalf("profile paths were not passed as definitions: %v", plan.Definitions)
	}
	if strings.Contains(plan.Profile, "network-outbound)\n") {
		t.Fatalf("network-off profile contains an unrestricted outbound grant:\n%s", plan.Profile)
	}
	if !strings.Contains(plan.Profile, "remote unix-socket") {
		t.Fatalf("network-off must retain filesystem-confined Unix sockets:\n%s", plan.Profile)
	}
	if plan.Scratch != "private-dir" {
		t.Fatalf("tmpfs must be reported as its macOS private-directory mapping: %+v", plan)
	}
}

func TestSeatbeltPlanEmitsSubtractiveRulesLast(t *testing.T) {
	pol := policy.Policy{
		WritableRoots: []string{"/work"},
		Protected:     []string{"/work/project/.git"},
		Network:       policy.Network{Mode: policy.NetworkFull},
		Scratch:       "/scratch",
	}
	plan := SeatbeltPlanFor(pol, "")
	lastAllow := strings.LastIndex(plan.Profile, "(allow ")
	firstDenyAfterBase := strings.Index(plan.Profile[len(seatbeltBaseProfile):], "(deny ")
	if firstDenyAfterBase < 0 {
		t.Fatalf("profile has no subtractive protected rules:\n%s", plan.Profile)
	}
	firstDenyAfterBase += len(seatbeltBaseProfile)
	if lastAllow > firstDenyAfterBase {
		t.Fatalf("an allow follows a protected deny:\n%s", plan.Profile)
	}
	if !strings.Contains(plan.Profile, "file-write-unlink") {
		t.Fatalf("profile does not pin protected ancestors against rename:\n%s", plan.Profile)
	}
	if !strings.Contains(plan.Profile, "Full network access") {
		t.Fatalf("network-full profile lacks its explicit grant:\n%s", plan.Profile)
	}
}

func TestSeatbeltPlanIsDeterministic(t *testing.T) {
	a := policy.Policy{
		WritableRoots: []string{"/b", "/a", "/b"},
		Protected:     []string{"/b/z", "/b/z"},
		Network:       policy.Network{Mode: policy.NetworkOff},
		Scratch:       "/scratch",
	}
	b := a
	b.WritableRoots = []string{"/a", "/b"}
	b.Protected = []string{"/b/z"}
	first := SeatbeltPlanFor(a, "")
	second := SeatbeltPlanFor(b, "")
	if first.Profile != second.Profile || first.Digest != second.Digest ||
		strings.Join(first.Definitions, "\n") != strings.Join(second.Definitions, "\n") {
		t.Fatalf("equivalent policies generated different plans:\n%+v\n%+v", first, second)
	}
}

func TestSeatbeltEnforcesFilesystemAndNetworkOnDarwin(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("requires the macOS Seatbelt kernel")
	}
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
	cmd := exec.Command(plan.Args([]string{os.Args[0], "-test.run=TestSeatbeltChildProcess"})[0],
		plan.Args([]string{os.Args[0], "-test.run=TestSeatbeltChildProcess"})[1:]...)
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
