package jail

import (
	"os"
	"testing"
	"time"
)

// A process that escapes every cleanup address may still inherit stdout. The
// helper must eventually close its own read end instead of letting that one
// writer turn a completed execution into an unbounded Wait.
func TestOutputPumpDrainIsBounded(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	defer writer.Close()

	exec := &Exec{
		stdoutR: reader,
		stdout:  NewStreamLimiter(1024),
	}
	exec.pumps.Add(1)
	go exec.pump("stdout", reader, exec.stdout,
		func(string, []byte, uint64, bool) {})

	started := time.Now()
	exec.waitForOutputPumps()
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("an inherited writer held the output pump for %s", elapsed)
	}
	if _, err := writer.Write([]byte("still-open")); err == nil {
		t.Fatal("bounded drain returned without closing the inherited pipe")
	}
}
