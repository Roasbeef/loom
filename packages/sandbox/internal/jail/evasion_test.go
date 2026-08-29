//go:build linux

package jail_test

import (
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/roasbeef/loom/sandbox/internal/jail"
)

// requireTool skips when the evasion's tool is not installed. A missing
// util-linux is an environmental gap, not a passed test.
func requireTool(t *testing.T, name string) string {
	t.Helper()
	path, err := exec.LookPath(name)
	if err != nil {
		t.Skipf("%s not installed; the evasion it performs cannot be attempted", name)
	}
	return path
}

func requireBwrap(t *testing.T) jail.Features {
	t.Helper()
	feat := jail.DetectFeatures()
	if feat.BwrapPath == "" {
		t.Skip("no bubblewrap: there is no supervisor to spare and no " +
			"namespace to enumerate, so the targeting under test does not run")
	}
	return feat
}

// #53, evasion 1. `TermTargets` scanned the *host process group*, so a
// payload that calls setsid(2) simply is not in the scan: the selection
// came back empty and run.go fell back to kill(-pgid, SIGTERM), which is
// the pre-b1d1e08 behaviour — it kills the bwrap supervisor,
// --die-with-parent SIGKILLs the namespace init, and the namespace takes
// the payload with it. The handler never runs.
//
// Leaving the process group must not take a payload out of range. Its
// handler runs, and the status it chooses survives.
func TestCancelReachesAPayloadThatLeftTheProcessGroup(t *testing.T) {
	requireBwrap(t)
	setsid := requireTool(t, "setsid")
	c := newCollector()
	ex := start(t, testPolicy(t), []string{
		setsid, "-w", "/bin/sh", "-c",
		`trap 'echo HANDLER-RAN; exit 7' TERM; echo ready; sleep 30 & wait`,
	}, c.sink)
	_ = ex.WriteStdin(nil, true)
	waitFor(t, 10*time.Second, func() bool { return strings.Contains(c.out(), "ready") })
	ex.Cancel()
	res := ex.Wait()
	if !strings.Contains(c.out(), "HANDLER-RAN") {
		t.Fatalf("the payload left the process group and was never asked to "+
			"stop: out %q, %+v", c.out(), res)
	}
	if res.Code != 7 {
		t.Fatalf("exit = %d, want 7 (the status the payload's own TERM "+
			"handler chose): %+v", res.Code, res)
	}
}

// #53, evasion 2. `nestedNamespaceInit` excluded any process whose
// innermost NSpid is 1 — a shape a payload can give itself with
// `unshare -U -p -f` and no privilege at all, and so be skipped by name.
// The supervisor and bwrap's init are known by construction; nothing
// else inherits their exemption.
func TestCancelReachesAPayloadClaimingToBeANamespaceInit(t *testing.T) {
	requireBwrap(t)
	unshare := requireTool(t, "unshare")
	c := newCollector()
	ex := start(t, testPolicy(t), []string{
		unshare, "-U", "-p", "-f", "/bin/sh", "-c",
		`trap 'echo INNER-HANDLER; exit 7' TERM; echo ready; sleep 30 & wait`,
	}, c.sink)
	_ = ex.WriteStdin(nil, true)
	waitFor(t, 10*time.Second, func() bool { return strings.Contains(c.out(), "ready") })
	ex.Cancel()
	res := ex.Wait()
	if !strings.Contains(c.out(), "INNER-HANDLER") {
		t.Fatalf("a payload that made itself look like a namespace init was "+
			"excluded by name and never asked to stop: out %q, %+v", c.out(), res)
	}
}

// #53, part 3 — the half that matters. With the payload's sleep
// backgrounded, a cancelled run reported `code=0 signal=0`: a clean
// success, three times out of three, for an execution that was
// forcibly truncated. Nothing in the result said it had been cancelled,
// so the broker could not tell a truncated run from a finished one.
func TestCancelledRunSaysItWasCancelled(t *testing.T) {
	c := newCollector()
	ex := start(t, testPolicy(t), []string{
		"/bin/sh", "-c", `echo ready; sleep 30 & wait`,
	}, c.sink)
	_ = ex.WriteStdin(nil, true)
	waitFor(t, 10*time.Second, func() bool { return strings.Contains(c.out(), "ready") })
	ex.Cancel()
	res := ex.Wait()
	if !res.Cancelled {
		t.Fatalf("a cancelled run did not report itself cancelled, so "+
			"code=%d signal=%d reads as an ordinary completion: %+v",
			res.Code, res.Signal, res)
	}
}

// The other side of the same flag: a run nobody cancelled must not
// claim it was, or the flag means nothing.
func TestUncancelledRunIsNotMarkedCancelled(t *testing.T) {
	c := newCollector()
	ex := start(t, testPolicy(t), []string{"/bin/sh", "-c", "exit 143"}, c.sink)
	_ = ex.WriteStdin(nil, true)
	res := ex.Wait()
	if res.Cancelled {
		t.Fatalf("nothing cancelled this run: %+v", res)
	}
	if res.Code != 143 {
		t.Fatalf("exit = %d, want 143 — the code a TERM-killed payload also "+
			"reports, which is why the code is not evidence of a TERM: %+v",
			res.Code, res)
	}
}
