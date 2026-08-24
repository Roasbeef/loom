package jail

import (
	"testing"
	"time"
)

// fake clock: just a time value the test advances.
func at(sec int) time.Time { return time.Unix(1000, 0).Add(time.Duration(sec) * time.Second) }

func TestEscalationHappyCancel(t *testing.T) {
	e := NewEscalation(2 * time.Second)

	if got := e.Tick(at(0)); got != SigNone {
		t.Fatalf("Tick before cancel = %v, want SigNone", got)
	}
	if got := e.Cancel(at(0)); got != SigTerm {
		t.Fatalf("first Cancel = %v, want SigTerm", got)
	}
	// Idempotence: repeated cancels are silent.
	if got := e.Cancel(at(1)); got != SigNone {
		t.Fatalf("second Cancel = %v, want SigNone", got)
	}
	// Within the grace window: no kill yet.
	if got := e.Tick(at(1)); got != SigNone {
		t.Fatalf("Tick inside grace = %v, want SigNone", got)
	}
	// Grace elapsed: exactly one SigKill.
	if got := e.Tick(at(2)); got != SigKill {
		t.Fatalf("Tick at grace = %v, want SigKill", got)
	}
	if got := e.Tick(at(3)); got != SigNone {
		t.Fatalf("Tick after kill = %v, want SigNone", got)
	}
	if !e.Cancelled() {
		t.Fatal("Cancelled() = false after cancel")
	}
}

func TestEscalationExitBeforeKill(t *testing.T) {
	e := NewEscalation(2 * time.Second)
	if e.Cancel(at(0)) != SigTerm {
		t.Fatal("want SigTerm")
	}
	deadline, ok := e.KillDeadline()
	if !ok || !deadline.Equal(at(2)) {
		t.Fatalf("KillDeadline = %v, %v; want %v, true", deadline, ok, at(2))
	}
	// The child exits during the grace window; the pending kill must
	// never fire.
	e.Exited()
	if got := e.Tick(at(5)); got != SigNone {
		t.Fatalf("Tick after exit = %v, want SigNone", got)
	}
	if got := e.Cancel(at(6)); got != SigNone {
		t.Fatalf("Cancel after exit = %v, want SigNone", got)
	}
}

func TestEscalationExitWithoutCancel(t *testing.T) {
	e := NewEscalation(2 * time.Second)
	e.Exited()
	if e.Cancelled() {
		t.Fatal("Cancelled() = true without any cancel")
	}
	if got := e.Cancel(at(1)); got != SigNone {
		t.Fatalf("Cancel after natural exit = %v, want SigNone", got)
	}
	if _, ok := e.KillDeadline(); ok {
		t.Fatal("KillDeadline valid without pending term")
	}
}
