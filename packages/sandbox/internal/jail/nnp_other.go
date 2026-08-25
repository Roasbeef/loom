//go:build !linux

package jail

import (
	"fmt"
	"runtime"
)

// noNewPrivs has nothing to set off Linux: PR_SET_NO_NEW_PRIVS is a
// Linux prctl. It returns a skip reason rather than an error, because
// the layer is absent by platform rather than broken by environment —
// and a skip is what the report vocabulary exists to carry. Reporting it
// as applied would be the one thing that must never happen.
func noNewPrivs() (skipReason string, err error) {
	return fmt.Sprintf(
		"no-new-privs: PR_SET_NO_NEW_PRIVS is Linux-only (%s)",
		runtime.GOOS,
	), nil
}
