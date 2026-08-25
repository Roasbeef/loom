// loom-exec is Loom's kernel-enforcement helper (WP-H, Linux phase 1).
//
// Roles, selected by the first argument:
//
//	(none)          server mode: read the base SandboxPolicyV1 from fd 3,
//	                then speak the Part 1.4 framing protocol on stdio.
//	--allow-unenforced
//	                server mode on a platform Loom has no jail for. Without
//	                it, such a build refuses to serve rather than run
//	                model-influenced code with nothing enforcing the policy.
//	--exec          stage 2 (restrict-and-exec): read the policy from
//	                fd 3, apply Landlock/seccomp/rlimits to self, report
//	                on fd 4, execve the target. Spawned by server mode,
//	                inside bwrap when available.
//	--self-test     run the sandbox regression probes against the live
//	                kernel; prints ENFORCED/SKIPPED per probe and an
//	                honest summary. Nonzero exit only when an enforceable
//	                probe fails.
//	--probe-socket  (internal) attempt socket(AF_INET, SOCK_STREAM) and
//	                report; the self-test's network-off witness.
//	--probe-setsid  (internal) leave the process group with setsid(2) and
//	                then hold stdout open; the self-test's witness that a
//	                session escape does not outlive the jail.
package main

import (
	"fmt"
	"os"
	"time"

	"github.com/roasbeef/loom/sandbox/internal/cgroup"
	"github.com/roasbeef/loom/sandbox/internal/framing"
	"github.com/roasbeef/loom/sandbox/internal/jail"
	"github.com/roasbeef/loom/sandbox/internal/selftest"
	"github.com/roasbeef/loom/sandbox/internal/server"

	"golang.org/x/sys/unix"
)

func main() {
	args := os.Args[1:]
	switch {
	case len(args) == 0:
		runServer(serverConfig{})
	case args[0] == jail.AllowUnenforcedFlag || args[0] == cgroupBaseFlag:
		cfg, err := parseServerArgs(args)
		if err != nil {
			fmt.Fprintf(os.Stderr, "loom-exec: %v\n%s", err, usage)
			os.Exit(2)
		}
		runServer(cfg)
	case args[0] == "--exec":
		runStage2(args[1:])
	case args[0] == "--self-test":
		selfExe, err := os.Executable()
		if err != nil {
			fmt.Fprintf(os.Stderr, "loom-exec: cannot resolve own executable: %v\n", err)
			os.Exit(1)
		}
		if !selftest.Run(os.Stdout, selfExe) {
			os.Exit(1)
		}
	case args[0] == "--probe-socket":
		probeSocket()
	case args[0] == "--probe-setsid":
		probeSetsid()
	case args[0] == "--help" || args[0] == "-h":
		fmt.Fprint(os.Stderr, usage)
		os.Exit(0)
	default:
		fmt.Fprintf(os.Stderr, "loom-exec: unknown argument %q\n%s", args[0], usage)
		os.Exit(2)
	}
}

const usage = `usage: loom-exec [--self-test] [--allow-unenforced] [--cgroup-base DIR]
Server mode (no arguments) expects a SandboxPolicyV1 on fd 3 and the
framing protocol on stdin/stdout. --exec, --probe-socket and
--probe-setsid are internal. --allow-unenforced serves anyway on a
platform with no jail (macOS, Windows); without it such a build refuses
to serve at all. --cgroup-base names a delegated, process-empty cgroup v2
directory to create per-exec cgroups under (` + cgroup.BaseEnvVar + ` does
the same); without one, memory and process ceilings are reported skipped
rather than silently dropped.
`

// cgroupBaseFlag names the delegated cgroup v2 base on the command
// line. The broker passes it through SpawnConfig's extra helper
// arguments; a systemd unit is likelier to set the environment variable
// instead, and either reaches the same place.
const cgroupBaseFlag = "--cgroup-base"

// serverConfig is everything server mode takes from its arguments.
type serverConfig struct {
	allowUnenforced bool
	// cgroupBase is empty when unset, which leaves the environment (and
	// then the own-cgroup fallback) to answer.
	cgroupBase string
}

// parseServerArgs reads the server-mode flags. Unknown arguments are an
// error rather than a shrug: a misspelled --cgroup-base that were
// ignored would leave the helper silently without the ceilings the
// operator meant to grant it.
func parseServerArgs(args []string) (serverConfig, error) {
	var cfg serverConfig
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case jail.AllowUnenforcedFlag:
			cfg.allowUnenforced = true
		case cgroupBaseFlag:
			if i+1 >= len(args) {
				return cfg, fmt.Errorf("%s requires a directory", cgroupBaseFlag)
			}
			cfg.cgroupBase = args[i+1]
			i++
		default:
			return cfg, fmt.Errorf("unknown server argument %q", args[i])
		}
	}
	return cfg, nil
}

// runServer starts the frame loop, unless this build has no jail for its
// platform and the caller did not explicitly ask for one without.
//
// The refusal is deliberate and is not the same decision as running
// degraded. A Linux host missing bwrap or Landlock still enforces
// something and could enforce the rest; a build with no jail enforces
// nothing, and `network: off` in a policy would be a sentence with no
// verb. The broker refuses degraded results only when the caller demanded
// full enforcement, so a BestEffort caller — code mode is one — would
// otherwise run model-written programs unconfined and call it a success.
func runServer(cfg serverConfig) {
	if refusal := jail.Platform().Refusal(cfg.allowUnenforced); refusal != "" {
		fmt.Fprintf(os.Stderr, "loom-exec: %s\n", refusal)
		os.Exit(1)
	}
	basePol, err := server.ReadBasePolicy()
	if err != nil {
		// The spec's first duty: a strict parse of fd 3. Failure is a
		// hard error exit before any frame is exchanged.
		fmt.Fprintf(os.Stderr, "loom-exec: %v\n", err)
		os.Exit(1)
	}
	selfExe, err := os.Executable()
	if err != nil {
		fmt.Fprintf(os.Stderr, "loom-exec: cannot resolve own executable: %v\n", err)
		os.Exit(1)
	}
	cgroupBase := cfg.cgroupBase
	if cgroupBase == "" {
		cgroupBase = cgroup.BaseFromEnv()
	}
	feat := jail.DetectFeaturesWith(cgroupBase)
	conn := framing.NewConn(os.Stdin, os.Stdout)
	if err := server.New(conn, feat, selfExe, basePol).Run(); err != nil {
		fmt.Fprintf(os.Stderr, "loom-exec: %v\n", err)
		os.Exit(1)
	}
}

func runStage2(rest []string) {
	var cfg jail.Stage2Config
	i := 0
	for i < len(rest) {
		switch rest[i] {
		case "--cwd":
			if i+1 >= len(rest) {
				stage2Fail("--cwd requires a value")
			}
			cfg.Cwd = rest[i+1]
			i += 2
		case "--":
			cfg.Argv = rest[i+1:]
			i = len(rest)
		default:
			stage2Fail(fmt.Sprintf("unknown stage-2 argument %q", rest[i]))
		}
	}
	if err := jail.RunStage2(cfg); err != nil {
		stage2Fail(err.Error())
	}
}

// stage2Fail reports on stderr (which reaches the broker as exec_out on
// the "stderr" stream) and exits 126, the conventional
// "found but cannot execute" code.
func stage2Fail(msg string) {
	fmt.Fprintf(os.Stderr, "loom-exec[stage2]: %s\n", msg)
	os.Exit(126)
}

// probeSetsid is the escape half of the pgroup contract. The helper
// kills the child's *process group*, so a process that starts its own
// session with setsid(2) is out of reach of that signal; only bwrap's
// PID namespace, which dies with its init, still covers it. This mode
// performs exactly that escape and then holds stdout open for longer
// than the self-test is willing to wait, so "the jail returned promptly"
// is proof the escapee was reaped rather than merely unobserved.
func probeSetsid() {
	if _, err := unix.Setsid(); err != nil {
		// Already a process group leader: the escape did not happen, so
		// nothing about containment was tested. Say which it was.
		fmt.Println("setsid-denied")
		os.Exit(1)
	}
	fmt.Println("setsid-ok")
	time.Sleep(probeSetsidHold)
	fmt.Println("setsid-survived")
}

// probeSetsidHold is how long the escapee lingers. It only has to
// outlast the self-test's patience; see internal/selftest.
const probeSetsidHold = 30 * time.Second

// probeSocket attempts to create an AF_INET stream socket, printing
// exactly one token on stdout. Exit code mirrors the token so callers
// can use either.
func probeSocket() {
	fd, err := unix.Socket(unix.AF_INET, unix.SOCK_STREAM, 0)
	if err == nil {
		unix.Close(fd)
		fmt.Println("socket-created")
		os.Exit(0)
	}
	fmt.Println("socket-denied")
	os.Exit(1)
}
