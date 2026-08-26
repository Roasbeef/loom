package jail

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"syscall"

	"github.com/roasbeef/loom/sandbox/internal/llock"
	"github.com/roasbeef/loom/sandbox/internal/policy"
	"github.com/roasbeef/loom/sandbox/internal/seccompf"

	"golang.org/x/sys/unix"
)

// Stage2Config is the restrict-and-exec configuration, passed on the
// command line by the supervising helper (the policy itself arrives on
// fd 3 — the spec's own contract for the helper, reused verbatim for
// the inner stage).
type Stage2Config struct {
	Cwd  string
	Argv []string
}

const (
	policyFD = 3
	reportFD = 4
)

// RunStage2 is the spec's helper in its purest form: parse the policy
// from fd 3, apply every in-process restriction to *ourselves*, report
// what was applied on fd 4, then execve the target. Landlock domains,
// seccomp filters, rlimits, and no_new_privs all persist across execve,
// which is why restrict-then-exec composes: the target starts life
// already inside the cage with no code of ours left in its address
// space.
//
// On success this function does not return. A missing kernel feature is
// not an error — it is reported and skipped (degraded enforcement is
// the broker's call to refuse); only real failures (bad policy, exec
// failure, a layer that *should* work erroring) return.
func RunStage2(cfg Stage2Config) error {
	if len(cfg.Argv) == 0 {
		return fmt.Errorf("stage2: empty argv")
	}

	policyFile := os.NewFile(policyFD, "policy")
	if policyFile == nil {
		return fmt.Errorf("stage2: fd 3 (policy) not open")
	}
	pol, err := policy.ReadFrom(policyFile)
	policyFile.Close()
	if err != nil {
		return err
	}

	var rep Report

	// Working directory first: a bad cwd should fail loudly before any
	// restriction muddies the diagnosis.
	if cfg.Cwd != "" {
		if err := os.Chdir(cfg.Cwd); err != nil {
			return fmt.Errorf("stage2: chdir: %w", err)
		}
	}

	// rlimits: per-process ceilings that need no kernel opt-in.
	// RLIMIT_FSIZE turns runaway file growth into SIGXFSZ/EFBIG;
	// RLIMIT_CPU turns CPU spins into SIGXCPU (and SIGKILL at the hard
	// ceiling). Both inherited across fork+exec by all descendants.
	if n := pol.Limits.FsizeBytes; n > 0 {
		lim := unix.Rlimit{Cur: n, Max: n}
		if err := unix.Setrlimit(unix.RLIMIT_FSIZE, &lim); err != nil {
			return fmt.Errorf("stage2: setrlimit fsize: %w", err)
		}
		rep.Applied = append(rep.Applied, "rlimit-fsize")
	}
	if n := pol.Limits.CPUSeconds; n > 0 {
		lim := unix.Rlimit{Cur: n, Max: n + 1}
		if err := unix.Setrlimit(unix.RLIMIT_CPU, &lim); err != nil {
			return fmt.Errorf("stage2: setrlimit cpu: %w", err)
		}
		rep.Applied = append(rep.Applied, "rlimit-cpu")
	}

	// Landlock: second filesystem layer (first, in degraded mode).
	if abi, reason := llock.ABIVersion(); abi > 0 {
		if err := llock.Apply(llock.Rules(landlockView(pol))); err != nil {
			return fmt.Errorf("stage2: landlock: %w", err)
		}
		rep.Applied = append(rep.Applied, "landlock:abi="+strconv.Itoa(abi))
	} else {
		rep.Skipped = append(rep.Skipped, "landlock: "+reason)
	}

	// no_new_privs wherever the platform has it: nothing exec'd from a
	// jail may ever acquire privilege via setuid/fscaps, whether or not
	// seccomp below also demands it. Cheap, irreversible, inherited.
	// Where the prctl does not exist the layer is *skipped*, by name.
	switch reason, err := noNewPrivs(); {
	case err != nil:
		return fmt.Errorf("stage2: set no_new_privs: %w", err)
	case reason != "":
		rep.Skipped = append(rep.Skipped, reason)
	default:
		rep.Applied = append(rep.Applied, "no-new-privs")
	}

	// seccomp network filter whenever the policy denies direct sockets:
	// mode "off", and mode "proxy" — which in phase 1 fails closed to
	// no direct network (no sidecar exists to enforce the allowlist)
	// and must say so in the report rather than pretend the proxy
	// confinement was applied.
	if BlocksDirectNetwork(pol.Network.Mode) {
		if seccompf.Supported() {
			if err := seccompf.Install(); err != nil {
				return fmt.Errorf("stage2: seccomp: %w", err)
			}
			rep.Applied = append(rep.Applied, "seccomp-net")
		} else {
			rep.Skipped = append(rep.Skipped, "seccomp: kernel lacks seccomp filter support")
		}
	}
	if pol.Network.Mode == policy.NetworkProxy {
		rep.Skipped = append(rep.Skipped, ProxyUnenforcedSkip)
	}

	// Report, then sever the plumbing: fds 3 and 4 must not leak into
	// the target (fd 4 doubles as the parent's EOF signal that the
	// report is complete).
	reportFile := os.NewFile(reportFD, "report")
	if reportFile != nil {
		_ = WriteReport(reportFile, rep)
		reportFile.Close()
	}

	path, err := exec.LookPath(cfg.Argv[0])
	if err != nil {
		return fmt.Errorf("stage2: resolve %q: %w", cfg.Argv[0], err)
	}
	// execve: the restrictions above ride along; our code does not.
	if err := syscall.Exec(path, cfg.Argv, os.Environ()); err != nil {
		return fmt.Errorf("stage2: exec %q: %w", path, err)
	}
	return nil // unreachable
}

// landlockView derives the Landlock grant set from the decoded policy.
// Pure and total, unlike the rest of RunStage2, so the one decision that
// matters here — what ScratchPath becomes — is unit-testable without a
// kernel that speaks Landlock at all (see stage2_test.go).
//
// A tmpfs scratch is a directory only bwrap can create, for the jail's
// own exclusive use — see llock.PolicyView's ScratchPath doc, which
// already promised this and which stage 2 used to contradict by granting
// write at ScratchMount unconditionally, tmpfs or not (#59). There is
// nothing there for Landlock to grant: under bwrap the mount is a fresh
// tmpfs the jail owns outright, and the grant was pure redundancy;
// without bwrap there is no tmpfs at all, "in degraded mode there is no
// scratch mount" per that same doc, and a policy asking for one gets
// none rather than a silent substitute of real host storage nothing
// asked for. A host-path scratch is real storage bwrap merely binds in,
// so it keeps its explicit grant — the one case where Landlock is doing
// load-bearing work rather than restating what the mount layer already
// settled.
func landlockView(pol policy.Policy) llock.PolicyView {
	view := llock.PolicyView{
		WritableRoots: pol.WritableRoots,
		ReadableRoots: pol.ReadableRoots,
	}
	if !pol.ScratchIsTmpfs() {
		view.ScratchPath = pol.Scratch
	}
	return view
}
