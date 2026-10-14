//go:build darwin

package jail

import (
	"os"
	"testing"
)

// BenchmarkProcessTrackerStartup measures real fresh kernel-table acquisition,
// initial indexing and the tracker goroutine's startup/join. B/op is cumulative
// allocation per start, not retained heap or physical resident memory.
func BenchmarkProcessTrackerStartup(b *testing.B) {
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		tracker, err := startProcessTracker(os.Getpid())
		if err != nil {
			b.Fatal(err)
		}
		tracker.close()
	}
}
