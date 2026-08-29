package jail

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
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

// DarwinLifecycleSkip records the one containment property Seatbelt cannot
// provide. The profile follows every fork, so a missed descendant remains
// filesystem- and network-confined, but macOS has no PID namespace or
// subreaper. A daemonizing double-fork can therefore be reparented between
// process-table samples and outlive the execution. FullEnforcement must see
// that limitation rather than accept sampled cleanup as a kernel guarantee.
const DarwinLifecycleSkip = "darwin-process-lifecycle: macOS has no PID " +
	"namespace or subreaper; rapid reparenting can evade sampled descendant " +
	"cleanup while retaining the Seatbelt profile"

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

	switch runtime.GOOS {
	case "linux":
		// Landlock is the second filesystem layer on Linux, and the first in
		// degraded mode.
		if abi, reason := llock.ABIVersion(); abi > 0 {
			if err := llock.Apply(llock.Rules(landlockView(pol))); err != nil {
				return fmt.Errorf("stage2: landlock: %w", err)
			}
			rep.Applied = append(rep.Applied, "landlock:abi="+strconv.Itoa(abi))
		} else {
			rep.Skipped = append(rep.Skipped, "landlock: "+reason)
		}

		// no_new_privs prevents privilege gain through setuid binaries and
		// file capabilities, and seccomp blocks direct sockets under the two
		// network-restricted policies.
		switch reason, err := noNewPrivs(); {
		case err != nil:
			return fmt.Errorf("stage2: set no_new_privs: %w", err)
		case reason != "":
			rep.Skipped = append(rep.Skipped, reason)
		default:
			rep.Applied = append(rep.Applied, "no-new-privs")
		}
		if BlocksDirectNetwork(pol.Network.Mode) {
			if seccompf.Supported() {
				if err := seccompf.Install(); err != nil {
					return fmt.Errorf("stage2: seccomp: %w", err)
				}
				rep.Applied = append(rep.Applied, "seccomp-net")
			} else {
				rep.Skipped = append(rep.Skipped,
					"seccomp: kernel lacks seccomp filter support")
			}
		}

	case "darwin":
		// Seatbelt owns filesystem and network confinement outside this
		// stage. Current Darwin kernels expose RLIMIT_AS but reject a finite
		// value, so that known unsupported result is reported instead of
		// aborting an otherwise confined execution. If a future kernel accepts
		// the limit, the same path reports it applied. RLIMIT_NPROC is
		// inherited, though it is a per-user rather than per-execution ceiling;
		// the report names the exact mechanism rather than pretending Linux
		// cgroups exist here.
		if n := pol.Limits.MemBytes; n > 0 {
			lim := unix.Rlimit{Cur: n, Max: n}
			if err := unix.Setrlimit(unix.RLIMIT_AS, &lim); err != nil {
				rep.Skipped = append(rep.Skipped,
					"rlimit-address-space: "+err.Error()+
						"; mem_bytes was NOT applied")
			} else {
				rep.Applied = append(rep.Applied, "rlimit-address-space")
			}
		}
		if n := pol.Limits.Pids; n > 0 {
			current, countErr := CurrentUserProcessCount()
			switch {
			case countErr != nil:
				rep.Skipped = append(rep.Skipped,
					"rlimit-processes: count current uid processes: "+
						countErr.Error()+"; pids was NOT applied")
			case current >= n:
				rep.Skipped = append(rep.Skipped, fmt.Sprintf(
					"rlimit-processes: current uid already has %d processes, "+
						"not below requested limit %d; pids was NOT applied",
					current, n))
			default:
				lim := unix.Rlimit{Cur: n, Max: n}
				if err := unix.Setrlimit(unix.RLIMIT_NPROC, &lim); err != nil {
					rep.Skipped = append(rep.Skipped,
						"rlimit-processes: "+err.Error()+
							"; pids was NOT applied")
				} else {
					rep.Applied = append(rep.Applied, "rlimit-processes")
				}
			}
		}
		rep.Skipped = append(rep.Skipped, DarwinLifecycleSkip)

	default:
		rep.Skipped = append(rep.Skipped,
			"platform-restrictions: no in-process driver for "+runtime.GOOS)
	}

	// Proxy mode remains narrowed to network-off on every platform until
	// the harness-owned allowlisting sidecar exists.
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
// Pure and total, unlike the rest of RunStage2, so its grants are unit-testable
// without a kernel that speaks Landlock at all (see stage2_test.go).
//
// /dev/null is the one synthetic-mount exception. Programs need a null sink
// in both bwrap and degraded mode, and granting that single harmless file is
// safe in either: it does not widen the rest of the host's /dev tree. /proc
// deliberately remains read-only because even a private PID mount exposes
// host-global kernel knobs under /proc/sys.
func landlockView(pol policy.Policy) llock.PolicyView {
	view := llock.PolicyView{
		WritableRoots: pol.WritableRoots,
		ReadableRoots: pol.ReadableRoots,
		WritableFiles: []string{"/dev/null"},
	}
	if !pol.ScratchIsTmpfs() {
		view.ScratchPath = pol.Scratch
	}
	return view
}
