//go:build darwin

package jail

import (
	"os"
	"os/exec"
	"testing"
	"time"
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

// BenchmarkProcessTrackerIdle measures cumulative allocation and CPU during a
// sleeping execution. Run with -benchtime=12s -benchmem -cpuprofile=idle.pprof;
// the benchmark timer and runtime are included, not just the tracker goroutine.
func BenchmarkProcessTrackerIdle(b *testing.B) {
	tracker, err := startProcessTracker(os.Getpid())
	if err != nil {
		b.Fatal(err)
	}
	defer tracker.close()
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		time.Sleep(processTrackInterval)
	}
}

// BenchmarkProcessTrackerForkActivity keeps the root actively forking instead
// of sleeping. Compare it alongside Idle: event-driven discovery must not buy
// idle savings by allocating a host snapshot for every short-lived child.
func BenchmarkProcessTrackerForkActivity(b *testing.B) {
	tracker, err := startProcessTracker(os.Getpid())
	if err != nil {
		b.Fatal(err)
	}
	defer tracker.close()
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		if err := exec.Command("/usr/bin/true").Run(); err != nil {
			b.Fatal(err)
		}
	}
}
