package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// scriptedGuest is a machine.Machine whose exit the test controls. Closing
// exit makes Wait return, as a runner's death does.
type scriptedGuest struct {
	console string
	exit    chan struct{}
}

func (g *scriptedGuest) ID() string          { return "scripted" }
func (g *scriptedGuest) ConsolePath() string { return g.console }

func (g *scriptedGuest) Wait(ctx context.Context) error {
	select {
	case <-g.exit:
		return nil

	case <-ctx.Done():
		return ctx.Err()
	}
}

func (g *scriptedGuest) Stop(context.Context) error { return nil }

// followWithin runs follow and fails the test if it has not returned within
// limit, which is the property every case here is about.
func followWithin(t *testing.T, ctx context.Context, g *scriptedGuest,
	limit time.Duration) (string, error) {

	t.Helper()

	var out bytes.Buffer
	done := make(chan error, 1)
	go func() { done <- follow(ctx, g, &out) }()

	select {
	case err := <-done:
		return out.String(), err

	case <-time.After(limit):
		t.Fatalf("follow did not return within %s", limit)
		return "", nil
	}
}

// TestFollowReturnsWhenTheGuestDiesBeforeItsConsoleExists pins the fix for
// a runner that exits before it creates the console file, which is what a
// firmware the host cannot boot does. follow used to retry the missing file
// forever, so `loom vm up` waited out its whole boot budget on a dead guest.
func TestFollowReturnsWhenTheGuestDiesBeforeItsConsoleExists(t *testing.T) {
	g := &scriptedGuest{
		console: filepath.Join(t.TempDir(), "console.log"),
		exit:    make(chan struct{}),
	}
	close(g.exit)

	_, err := followWithin(t, context.Background(), g, 5*time.Second)
	if !errors.Is(err, errNoConsole) {
		t.Fatalf("follow = %v, want errNoConsole", err)
	}
}

// TestFollowCopiesAConsoleWrittenJustBeforeTheExit checks the last look:
// a console that exists when the exit is seen is copied in full, and the run
// is not reported as a silent guest.
func TestFollowCopiesAConsoleWrittenJustBeforeTheExit(t *testing.T) {
	g := &scriptedGuest{
		console: filepath.Join(t.TempDir(), "console.log"),
		exit:    make(chan struct{}),
	}
	if err := os.WriteFile(g.console, []byte("panic: no init\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	close(g.exit)

	out, err := followWithin(t, context.Background(), g, 5*time.Second)
	if err != nil {
		t.Fatalf("follow = %v, want nil", err)
	}
	if out != "panic: no init\n" {
		t.Fatalf("copied %q", out)
	}
}

// TestFollowWaitsForALateConsoleWhileTheGuestRuns checks that a missing
// console is still retried for a live guest, and that lines written after
// the file appears are copied before the exit ends the run.
func TestFollowWaitsForALateConsoleWhileTheGuestRuns(t *testing.T) {
	g := &scriptedGuest{
		console: filepath.Join(t.TempDir(), "console.log"),
		exit:    make(chan struct{}),
	}

	go func() {
		time.Sleep(150 * time.Millisecond)
		_ = os.WriteFile(g.console, []byte("LOOM-EXECUTOR-READY x\n"), 0o600)
		time.Sleep(300 * time.Millisecond)
		close(g.exit)
	}()

	out, err := followWithin(t, context.Background(), g, 5*time.Second)
	if err != nil {
		t.Fatalf("follow = %v, want nil", err)
	}
	if out != "LOOM-EXECUTOR-READY x\n" {
		t.Fatalf("copied %q", out)
	}
}

// TestFollowReportsCancellationBeforeAConsoleAsCancellation checks that a
// stop requested while the console is still missing is a cancellation, which
// run treats as a clean end, and not a boot failure.
func TestFollowReportsCancellationBeforeAConsoleAsCancellation(t *testing.T) {
	g := &scriptedGuest{
		console: filepath.Join(t.TempDir(), "console.log"),
		exit:    make(chan struct{}),
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, err := followWithin(t, ctx, g, 5*time.Second)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("follow = %v, want context.Canceled", err)
	}
}
