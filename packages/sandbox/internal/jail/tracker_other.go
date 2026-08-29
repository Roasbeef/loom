//go:build !darwin

package jail

import (
	"fmt"
	"runtime"
	"syscall"
)

type processTracker struct{}

func startProcessTracker(int) (*processTracker, error) { return nil, nil }

func (*processTracker) signal(syscall.Signal) bool { return false }

func (*processTracker) close() {}

// CurrentUserProcessCount is only meaningful for Darwin's per-user process
// rlimit. Other platforms use their native per-execution containment.
func CurrentUserProcessCount() (uint64, error) {
	return 0, fmt.Errorf("user process count is not used on %s", runtime.GOOS)
}
