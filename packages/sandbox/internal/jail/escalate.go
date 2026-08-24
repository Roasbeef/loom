package jail

import "time"

// KillGrace is the window between SIGTERM and SIGKILL on cancel. The
// wire contract (spec Part 1.4) gives the helper 2 seconds to kill its
// pgroup before the broker escalates to killing the helper itself; we
// use the same 2s internally so a well-behaved child gets its TERM
// handler and a stubborn one still dies inside the broker's patience.
const KillGrace = 2 * time.Second

// Sig is the action the escalation machine asks the caller to perform.
type Sig int

const (
	// SigNone: nothing to do.
	SigNone Sig = iota
	// SigTerm: send SIGTERM to the process group.
	SigTerm
	// SigKill: send SIGKILL to the process group.
	SigKill
)

// escState is the escalation phase.
type escState int

const (
	escRunning escState = iota
	escTermSent
	escKilled
	escExited
)

// Escalation is the cancel state machine, pure so the TERM→KILL
// escalation is testable with a fake clock. The caller owns the actual
// signalling and timers; this type only decides.
//
//	Running --Cancel--> TermSent --(grace elapsed)--> Killed
//	   any state --Exited--> Exited (terminal)
//
// Cancel is idempotent by construction: every state after the first
// Cancel answers SigNone.
type Escalation struct {
	state  escState
	termAt time.Time
	grace  time.Duration
}

// NewEscalation returns a machine using the given grace window (callers
// pass KillGrace; tests pass whatever they like).
func NewEscalation(grace time.Duration) *Escalation {
	return &Escalation{state: escRunning, grace: grace}
}

// Cancel requests termination. First call in Running answers SigTerm;
// every later call answers SigNone (idempotence per the wire contract).
func (e *Escalation) Cancel(now time.Time) Sig {
	if e.state != escRunning {
		return SigNone
	}
	e.state = escTermSent
	e.termAt = now
	return SigTerm
}

// Tick advances time. Once the grace window after TERM has elapsed and
// the process still has not exited, it answers SigKill (exactly once).
func (e *Escalation) Tick(now time.Time) Sig {
	if e.state != escTermSent {
		return SigNone
	}
	if now.Sub(e.termAt) < e.grace {
		return SigNone
	}
	e.state = escKilled
	return SigKill
}

// KillDeadline reports when Tick will answer SigKill, valid only after
// a successful Cancel and before exit.
func (e *Escalation) KillDeadline() (time.Time, bool) {
	if e.state != escTermSent {
		return time.Time{}, false
	}
	return e.termAt.Add(e.grace), true
}

// Exited marks the process gone; all further inputs answer SigNone.
func (e *Escalation) Exited() { e.state = escExited }

// Cancelled reports whether a cancel was ever accepted.
func (e *Escalation) Cancelled() bool {
	return e.state == escTermSent || e.state == escKilled
}
