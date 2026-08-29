package jail

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/roasbeef/loom/sandbox/internal/policy"
)

func startGatedCommand(t *testing.T, argv []string) (*exec.Cmd, *os.File) {
	t.Helper()

	gateR, gateW, err := os.Pipe()
	if err != nil {
		t.Fatalf("gate pipe: %v", err)
	}
	null3, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		gateR.Close()
		gateW.Close()
		t.Fatalf("open fd 3 placeholder: %v", err)
	}
	null4, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		gateR.Close()
		gateW.Close()
		null3.Close()
		t.Fatalf("open fd 4 placeholder: %v", err)
	}

	wrapped := withStartGate(argv)
	cmd := exec.Command(wrapped[0], wrapped[1:]...)
	// Bash imports this spelling as an exported shell function. If privileged
	// mode is removed, it shadows read and releases the target before fd 5 has
	// a token. Other /bin/sh implementations safely ignore the hostile entry.
	cmd.Env = []string{"BASH_FUNC_read%%=() { return 0; }"}
	cmd.ExtraFiles = []*os.File{null3, null4, gateR}
	if err := cmd.Start(); err != nil {
		gateR.Close()
		gateW.Close()
		null3.Close()
		null4.Close()
		t.Fatalf("start gated command: %v", err)
	}
	gateR.Close()
	null3.Close()
	null4.Close()
	return cmd, gateW
}

func TestCgroupStartGateBlocksAndPreservesArgv(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "argv")
	target := []string{
		"/bin/sh", "-c",
		`out=$1; shift; printf '<%s>\n' "$@" > "$out"`,
		"target-zero", marker, "two words", "", "$(printf injected)", "semi;colon",
	}
	cmd, release := startGatedCommand(t, target)

	// Give an incorrectly ungated target ample time to leave its marker.
	time.Sleep(100 * time.Millisecond)
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		release.Close()
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		t.Fatalf("target ran before gate release: stat error %v", err)
	}

	if err := releaseStartGate(release); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		t.Fatalf("release gate: %v", err)
	}
	if err := cmd.Wait(); err != nil {
		t.Fatalf("wait for target: %v", err)
	}
	got, err := os.ReadFile(marker)
	if err != nil {
		t.Fatalf("read argv marker: %v", err)
	}
	want := "<two words>\n<>\n<$(printf injected)>\n<semi;colon>\n"
	if string(got) != want {
		t.Fatalf("target argv = %q, want %q", got, want)
	}
}

func TestCgroupStartGateCloseDoesNotLaunchTarget(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "ran")
	cmd, release := startGatedCommand(t, []string{"/usr/bin/touch", marker})

	// Error cleanup closes the pipe without a release token. The gate must
	// exit instead of turning that close into permission to launch the target.
	if err := release.Close(); err != nil {
		t.Fatalf("close gate: %v", err)
	}
	if err := cmd.Wait(); err == nil {
		t.Fatal("gate exited successfully without a release token")
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("target ran while gate was being cleaned up: stat error %v", err)
	}
}

func TestCgroupStartGateReleasesDegradedExecAfterSetupFailure(t *testing.T) {
	stage2 := filepath.Join(t.TempDir(), "stage2")
	const stage2Script = `#!/bin/sh
dd bs=1 count=1 <&3 >/dev/null 2>&1 || exit 124
: >&4 || exit 123
if (: <&5) 2>/dev/null; then
  exit 122
fi
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--" ]; then
    shift
    exec "$@"
  fi
  shift
done
exit 126
`
	if err := os.WriteFile(stage2, []byte(stage2Script), 0o700); err != nil {
		t.Fatalf("write stage 2 stub: %v", err)
	}

	// A detected base is represented by Features, but this plain directory
	// cannot configure cgroup.subtree_control. Start must release the blocked
	// child in degraded mode and retain the setup error as a cgroup skip.
	feat := Features{CgroupDir: t.TempDir(), Platform: PlatformFor("linux")}
	pol := policy.Policy{
		Network:  policy.Network{Mode: policy.NetworkFull},
		Limits:   policy.Limits{Pids: 8, OutputBytes: 1024},
		EnvAllow: []string{"PATH"},
		Scratch:  "tmpfs",
	}
	var stdout []byte
	ex, err := Start(Request{
		Argv:   []string{"/bin/sh", "-c", "printf degraded-ran"},
		Env:    map[string]string{"PATH": "/usr/local/bin:/usr/bin:/bin"},
		Cwd:    "/",
		Policy: pol,
	}, feat, stage2, func(stream string, data []byte, _ uint64, _ bool) {
		if stream == "stdout" {
			stdout = append(stdout, data...)
		}
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := ex.WriteStdin(nil, true); err != nil {
		t.Fatalf("WriteStdin: %v", err)
	}
	res := ex.Wait()
	if res.Code != 0 || string(stdout) != "degraded-ran" {
		t.Fatalf("degraded target exit/output = %d/%q", res.Code, stdout)
	}
	found := false
	for _, entry := range res.Enforcement {
		if strings.HasPrefix(entry, "skip:"+CgroupSkipPrefix+":") &&
			strings.Contains(entry, "cgroup.subtree_control") {
			found = true
		}
	}
	if !found {
		t.Fatalf("enforcement %v does not report the cgroup setup failure", res.Enforcement)
	}
}
