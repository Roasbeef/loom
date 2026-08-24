// loom-exec is Loom's kernel-enforcement helper (WP-H, Linux phase 1).
//
// Roles, selected by the first argument:
//
//	(none)          server mode: read the base SandboxPolicyV1 from fd 3,
//	                then speak the Part 1.4 framing protocol on stdio.
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
package main

import (
	"fmt"
	"os"

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
		runServer()
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
	case args[0] == "--help" || args[0] == "-h":
		fmt.Fprint(os.Stderr, usage)
		os.Exit(0)
	default:
		fmt.Fprintf(os.Stderr, "loom-exec: unknown argument %q\n%s", args[0], usage)
		os.Exit(2)
	}
}

const usage = `usage: loom-exec [--self-test]
Server mode (no arguments) expects a SandboxPolicyV1 on fd 3 and the
framing protocol on stdin/stdout. --exec and --probe-socket are internal.
`

func runServer() {
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
	feat := jail.DetectFeatures()
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
