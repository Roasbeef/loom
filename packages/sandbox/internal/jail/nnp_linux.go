//go:build linux

package jail

import (
	"fmt"

	"golang.org/x/sys/unix"
)

// noNewPrivs sets PR_SET_NO_NEW_PRIVS on the current process.
//
// Unconditional on Linux: nothing exec'd from a jail may ever acquire
// privilege via setuid or file capabilities, whether or not the seccomp
// layer below also demands it. Cheap, irreversible, inherited across
// fork and execve. A failure here is a real failure, not a skip.
func noNewPrivs() (skipReason string, err error) {
	if err := unix.Prctl(unix.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0); err != nil {
		return "", fmt.Errorf("prctl(PR_SET_NO_NEW_PRIVS): %w", err)
	}
	return "", nil
}
