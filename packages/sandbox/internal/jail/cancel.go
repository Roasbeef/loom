package jail

import (
	"os"
	"strconv"
	"strings"
)

// Who the TERM half of the cancel ladder is addressed to, and why it is
// not simply "the process group".
//
// # The shape of a jail, from the host's side
//
// bwrap does not run the target as a single process. With `--unshare-pid`
// it forks twice, and all three live in the one session the helper opened:
//
//	pid P    bwrap, in the host PID namespace       <- the supervisor
//	pid Q    bwrap again, PID 1 in the new namespace <- the namespace init
//	pid R    stage 2, execve'd into the target       <- the payload
//
// P is the process group leader, so `kill(-P, sig)` reaches all three.
//
// # What that did to the ladder
//
// The supervisor takes SIGTERM at its default disposition and dies. It is
// spawned with `--die-with-parent`, which is `PR_SET_PDEATHSIG(SIGKILL)`
// on the namespace init — so the supervisor's death SIGKILLs Q, and
// killing a PID namespace's init SIGKILLs every process in that namespace.
// The payload is gone in under a millisecond, by SIGKILL, no matter what
// its own SIGTERM disposition was. Measured on this tree: a payload with
// `trap '' TERM` and a 30-second loop died in 766µs, and a payload with a
// real TERM handler ran its handler and then had its chosen exit status
// destroyed by the teardown, reported to the broker as "killed by signal"
// rather than "exited 7".
//
// So `TERM -> grace -> KILL` described an unjailed process only. Inside a
// jail it was `KILL`, and the grace in the contract bought nobody
// anything. That is a documentation claim the jail did not honour, which
// is the finding, not the failing test.
//
// # The decision
//
// The grace is owed to the payload: the model-influenced command the
// broker addressed, and whatever it spawned inside the jail. It is not
// owed to the jail's scaffolding. The supervisor and the namespace init
// are the cage; signalling them does not ask the payload to stop, it
// demolishes the cage with the payload still inside.
//
// TERM therefore goes to every member of the process group except that
// scaffolding, and SIGKILL — which no disposition may ignore and which an
// ancestor namespace may always deliver — goes to the whole group when the
// grace expires. Cleanup keeps its unconditional group-wide SIGKILL sweep,
// so nothing about "no orphaned jails" changes.
//
// # What "ignoring TERM" means in here
//
// Two different things, and the difference is the reason for the rule.
//
// For the payload it means what it means anywhere: R is an ordinary
// process — under bwrap it is PID 2, not PID 1 — so its SIG_IGN discards
// the signal and the grace runs out, exactly as the contract says.
//
// For the namespace init it means something stronger that the kernel
// provides whether or not anyone asked. `pid_namespaces(7)`: a signal sent
// from an ancestor namespace is delivered to a namespace init only if the
// init installed a handler for it; SIGKILL and SIGSTOP are the exceptions
// and are forcibly delivered and uncatchable. So Q survives our TERM
// regardless. Sparing it is belt to the kernel's braces — it costs a
// comparison and it stops the ladder depending on bwrap never growing a
// TERM handler in some future release.
//
// # Degraded mode is untouched
//
// With no bwrap there is no scaffolding: the group leader *is* stage 2
// execve'd into the payload, and the ladder addresses the whole group as
// it always did. Selection only ever narrows a jailed group, and when it
// cannot read the process table it narrows nothing — see TermTargets.

// ProcEntry is one host process as the cancel ladder needs to see it.
type ProcEntry struct {
	// Pid is the process id in the helper's own PID namespace.
	Pid int
	// Pgid is the process group it belongs to, same namespace.
	Pgid int
	// NamespaceInit reports whether this process is PID 1 of a PID
	// namespace nested below the helper's own.
	NamespaceInit bool
}

// TermTargets selects the members of process group pgid that the TERM
// half of the ladder is addressed to: everything in the group except the
// jail's scaffolding — the bwrap supervisor, and any init of a nested PID
// namespace.
//
// A nil result means "no opinion", and the caller must fall back to
// signalling the whole group. That is the honest answer in three cases
// that must never become a silently skipped TERM: a platform with no
// process table to read, a group whose only member is the supervisor
// itself (degraded mode, where the leader is the payload), and a race in
// which the payload has not appeared in the table yet.
func TermTargets(entries []ProcEntry, pgid, supervisor int) []int {
	var targets []int
	for _, e := range entries {
		if e.Pgid != pgid || e.Pid == supervisor || e.NamespaceInit {
			continue
		}
		targets = append(targets, e.Pid)
	}
	return targets
}

// scanProcGroup reads the process table for the members of one process
// group. It returns nothing on a platform without procfs, which
// TermTargets turns into the whole-group fallback.
func scanProcGroup(pgid int) []ProcEntry {
	names, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	var out []ProcEntry
	for _, n := range names {
		pid, err := strconv.Atoi(n.Name())
		if err != nil {
			continue
		}
		stat, err := os.ReadFile("/proc/" + n.Name() + "/stat")
		if err != nil {
			continue // the process exited between readdir and read
		}
		got, ok := parseStatPgid(string(stat))
		if !ok || got != pgid {
			continue
		}
		status, _ := os.ReadFile("/proc/" + n.Name() + "/status")
		out = append(out, ProcEntry{
			Pid:           pid,
			Pgid:          got,
			NamespaceInit: nestedNamespaceInit(string(status)),
		})
	}
	return out
}

// parseStatPgid pulls field 5 (pgrp) out of a /proc/<pid>/stat line. The
// comm field is parenthesised and may itself contain spaces and
// parentheses, so the split starts after its *last* ')'.
func parseStatPgid(stat string) (int, bool) {
	close := strings.LastIndex(stat, ")")
	if close < 0 || close+2 > len(stat) {
		return 0, false
	}
	fields := strings.Fields(stat[close+1:])
	// After comm: state, ppid, pgrp, ...
	if len(fields) < 3 {
		return 0, false
	}
	pgid, err := strconv.Atoi(fields[2])
	if err != nil {
		return 0, false
	}
	return pgid, true
}

// nestedNamespaceInit reads /proc/<pid>/status and reports whether the
// process is PID 1 of a PID namespace below the reader's own. The NSpid
// line lists the process's id in each namespace from the reader's outwards
// in; more than one entry means it is nested, and a trailing 1 means it is
// that namespace's init.
func nestedNamespaceInit(status string) bool {
	for _, line := range strings.Split(status, "\n") {
		rest, ok := strings.CutPrefix(line, "NSpid:")
		if !ok {
			continue
		}
		ids := strings.Fields(rest)
		return len(ids) > 1 && ids[len(ids)-1] == "1"
	}
	return false
}
