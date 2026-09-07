package jail

import (
	"os"
	"sort"
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
// TERM therefore goes to the payload and everything it spawned, and
// SIGKILL — which no disposition may ignore and which an ancestor
// namespace may always deliver — goes to the whole group when the grace
// expires. Cleanup keeps its unconditional group-wide SIGKILL sweep, so
// nothing about "no orphaned jails" changes.
//
// # How the payload is found, and why not by process group
//
// The first version of this selected members of the supervisor's
// *process group*. A process group is something a process can leave, and
// `setsid(2)` needs no privilege: a payload that called it was simply
// not in the scan, the selection came back empty, and the caller fell
// back to `kill(-pgid, SIGTERM)` — the pre-cancel.go behaviour, which
// kills the supervisor and collapses the namespace onto a payload
// nothing asked to stop. Measured (#53): the handler never ran.
//
// Descent is not something a process can leave. Under `--unshare-pid`
// every process in the namespace is a descendant of the namespace init,
// including orphans, which the kernel reparents *to that init* rather
// than to host pid 1. So the selection walks the parent links from the
// supervisor and takes everything at depth two or more:
//
//	depth 0  the supervisor        (the cage — spared)
//	depth 1  bwrap's namespace init (the cage — spared)
//	depth 2+ the payload and everything below it (TERMed)
//
// Both exclusions are now **structural**: they are the supervisor whose
// pid the helper holds because it spawned it, and that process's own
// direct children. The old rule read `/proc/<pid>/status` and spared any
// process whose innermost `NSpid` was 1 — a shape any payload can give
// itself with `unshare -U -p -f` and no privilege at all, which made
// "spare the namespace init" into a one-syscall way to be skipped by
// name (#53 again). A payload that nests its own namespaces is welcome
// to; its inits are its own and are asked to stop like everything else.
// The kernel's own rule still applies to them (`pid_namespaces(7)`: a
// signal from an ancestor namespace reaches an init only if it installed
// a handler), so a nested init that ignores TERM ignores it exactly as
// any other payload would, and the KILL rung ends it.
//
// # What this still does not promise
//
// Complete against a hostile payload **under bwrap**, where the PID
// namespace guarantees the descendant walk enumerates every process in
// the jail. Best-effort **in degraded mode**, where there is no
// namespace: without bwrap the group leader is the payload itself, TERM
// addresses the whole group, and a payload that calls `setsid(2)` leaves
// it with nothing to put it back. That is one more thing a missing bwrap
// costs, it is reported as degraded like the rest, and the KILL rung's
// group sweep is what still bounds it.
//
// # What "ignoring TERM" means in here
//
// Two different things, and the difference is the reason for the rule.
//
// For the payload it means what it means anywhere: R is an ordinary
// process — under bwrap it is PID 2, not PID 1 — so its SIG_IGN discards
// the signal and the grace runs out, exactly as the contract says.
//
// For bwrap's own namespace init it means something stronger that the
// kernel provides whether or not anyone asked. `pid_namespaces(7)`: a
// signal sent from an ancestor namespace is delivered to a namespace
// init only if the init installed a handler for it; SIGKILL and SIGSTOP
// are the exceptions and are forcibly delivered and uncatchable. So Q
// survives our TERM regardless. Sparing it is belt to the kernel's
// braces — it costs a comparison and it stops the ladder depending on
// bwrap never growing a TERM handler in some future release. It is
// spared because it is the supervisor's child, not because it says it is
// an init.
//
// # Degraded mode is untouched
//
// With no bwrap there is no scaffolding: the group leader *is* stage 2
// execve'd into the payload, and the ladder addresses the whole group as
// it always did. Selection runs only under bwrap, and when it cannot
// read the process table it narrows nothing — see TermTargets.

// ProcEntry is one host process as the cancel ladder needs to see it:
// its own pid and its parent's. Descent is the only relation a payload
// cannot rearrange — it can leave a process group and it can claim to be
// a namespace init, but it cannot stop being its parent's child, and
// under a PID namespace even orphaning itself only reparents it onto the
// namespace's init, which is still inside the jail.
type ProcEntry struct {
	// Pid is the process id in the helper's own PID namespace.
	Pid int
	// Ppid is its parent's pid, same namespace.
	Ppid int
}

// TermTargets selects the processes the TERM half of the ladder is
// addressed to: every descendant of the supervisor except the
// supervisor's own direct children, which is bwrap's namespace init.
// Both exclusions are structural — the supervisor's pid is the one the
// helper spawned, and its children are whatever bwrap forked — so
// nothing a payload can do to itself puts it in the exempt set.
//
// The result is ordered by pid, so a caller's signalling order does not
// depend on readdir order.
//
// A nil result means "no opinion", and the caller must fall back to
// signalling the whole group. That is the honest answer in three cases
// that must never become a silently skipped TERM: a platform with no
// process table to read, a supervisor with no grandchildren yet (a race
// in which the payload has not appeared), and degraded mode, where there
// is no supervisor to descend from in the first place.
//
// A *partial* table is the case this function cannot answer at all, and
// the caller must not read a non-empty result as "the scan was
// complete". A row lost to a transient `/proc` read failure orphans
// everything below it in the walk, so losing the depth-2 row drops the
// whole payload subtree while any unrelated deeper descendant keeps the
// selection non-empty. TERM then goes to the wrong subset, nobody asks
// the payload to stop, and the caller waits out the full grace before
// SIGKILL — observed as `Code:137 Signal:9 WallMs:2016` on a run whose
// payload had a working TERM handler (#135). The table alone cannot
// distinguish that from a complete scan, which is why the completeness
// the walk assumes is checked against a second, independent reading of
// the same kernel state: see payloadRoots and termTargetsAreTrusted.
func TermTargets(entries []ProcEntry, supervisor int) []int {
	children := make(map[int][]int, len(entries))
	for _, e := range entries {
		if e.Pid == e.Ppid {
			continue // pid 1 parents itself on some kernels; not a cycle
		}
		children[e.Ppid] = append(children[e.Ppid], e.Pid)
	}

	// Breadth-first from the supervisor. Depth 0 and 1 are the cage; the
	// payload and everything it spawned start at depth 2.
	seen := map[int]bool{supervisor: true}
	frontier := children[supervisor]
	for _, pid := range frontier {
		seen[pid] = true
	}
	var targets []int
	for len(frontier) > 0 {
		var next []int
		for _, pid := range frontier {
			for _, child := range children[pid] {
				if seen[child] {
					continue // a recycled pid claiming an ancestor as parent
				}
				seen[child] = true
				targets = append(targets, child)
				next = append(next, child)
			}
		}
		frontier = next
	}
	sort.Ints(targets)
	return targets
}

// scanProcesses reads the whole process table as parent links. It
// returns nothing on a platform without procfs, which TermTargets turns
// into the whole-group fallback.
//
// The whole table, not one process group: the point of the walk is to
// find processes that left the group.
func scanProcesses() []ProcEntry {
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
		ppid, ok := parseStatPpid(string(stat))
		if !ok {
			continue
		}
		out = append(out, ProcEntry{Pid: pid, Ppid: ppid})
	}
	return out
}

// termTargetsAreTrusted decides whether a non-empty selection may be
// used as the TERM rung's only addressee, given the payload roots the
// kernel says are alive right now.
//
// The walk in TermTargets is only as complete as the table it was given,
// and a table that lost a row is indistinguishable from a complete one
// once the answer is back. So the one thing the selection must contain
// is checked directly: the processes the supervisor's own child spawned,
// which is where the payload subtree hangs from. A live root that is
// missing from the selection proves the scan was partial, and the caller
// falls back to the group exactly as it does for an empty selection —
// too wide a TERM is recoverable, a TERM the payload never received is
// not.
//
// An empty root set is "no opinion" and leaves the selection trusted.
// That is deliberate: the verification may only ever demote a selection
// on positive evidence of a missing live root, never on the absence of
// evidence. Otherwise a kernel built without CONFIG_PROC_CHILDREN would
// silently reinstate the whole-group TERM that #53 removed, on every
// cancel, for every payload.
func termTargetsAreTrusted(targets, roots []int) bool {
	selected := make(map[int]bool, len(targets))
	for _, pid := range targets {
		selected[pid] = true
	}
	for _, root := range roots {
		if !selected[root] {
			return false
		}
	}
	return true
}

// payloadRoots names the processes the payload subtree hangs from: the
// grandchildren of the supervisor, read by descending the two `children`
// files rather than by scanning the table. It returns nothing when the
// descent cannot be made — no procfs, a kernel without
// CONFIG_PROC_CHILDREN, a supervisor or namespace init that has already
// exited, or a payload that has not been forked yet — which
// termTargetsAreTrusted reads as "no opinion".
//
// This is a second reading of the same kernel state, and its value is
// that it is a much smaller one. The bug it guards against is a row lost
// among the hundreds a full `/proc` walk reads on a loaded runner; two
// targeted reads either succeed or fail visibly, and a failure here
// becomes "no opinion" instead of a wrong answer.
//
// The roots are grandchildren rather than children because depth 1 is
// bwrap's namespace init — the cage, spared by the same structural rule
// TermTargets applies.
func payloadRoots(supervisor int) []int {
	var roots []int
	for _, nsInit := range procChildren(supervisor) {
		roots = append(roots, procChildren(nsInit)...)
	}
	sort.Ints(roots)
	return roots
}

// procChildren reads the pids the kernel lists as children of pid's main
// thread. Unreadable for any reason means nothing is claimed, because
// the caller turns an empty answer into "no opinion" and a wrong answer
// into a whole-group TERM.
//
// Only the main thread's children are read, and both processes this is
// asked about are bwrap — a single-threaded C program — so that is the
// complete set. Were it ever not, the missed child would show up as an
// unverifiable root rather than as a false negative, since a root the
// file does not mention is a root this never asserts.
func procChildren(pid int) []int {
	name := strconv.Itoa(pid)
	raw, err := os.ReadFile("/proc/" + name + "/task/" + name + "/children")
	if err != nil {
		return nil
	}
	var out []int
	for _, field := range strings.Fields(string(raw)) {
		child, err := strconv.Atoi(field)
		if err != nil {
			continue
		}
		out = append(out, child)
	}
	return out
}

// parseStatPpid pulls field 4 (ppid) out of a /proc/<pid>/stat line. The
// comm field is parenthesised and may itself contain spaces and
// parentheses, so the split starts after its *last* ')'.
func parseStatPpid(stat string) (int, bool) {
	close := strings.LastIndex(stat, ")")
	if close < 0 || close+2 > len(stat) {
		return 0, false
	}
	fields := strings.Fields(stat[close+1:])
	// After comm: state, ppid, pgrp, ...
	if len(fields) < 2 {
		return 0, false
	}
	ppid, err := strconv.Atoi(fields[1])
	if err != nil {
		return 0, false
	}
	return ppid, true
}
