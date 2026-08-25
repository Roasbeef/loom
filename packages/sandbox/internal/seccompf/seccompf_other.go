//go:build !linux

package seccompf

import (
	"fmt"
	"runtime"
)

// UnavailableReason is the one sentence every non-Linux caller gets, and
// it is deliberately about *Loom*, not about the kernel: seccomp is a
// Linux facility, so there is nothing here to detect, degrade to, or
// probe for. Whatever confinement the platform offers instead is not
// this layer and must not be reported as this layer.
var UnavailableReason = fmt.Sprintf(
	"seccomp is Linux-only; %s has no network filter in loom-exec",
	runtime.GOOS,
)

// Supported always reports false off Linux. It probes nothing: a probe
// that could not succeed is not a probe.
func Supported() bool { return false }

// Install always fails off Linux. Callers treat a false Supported() as a
// skip and never reach here; the error exists so a caller that ignored
// Supported() gets a refusal rather than a silent no-op that would leave
// the network open while the report claimed a filter.
func Install() error { return fmt.Errorf("seccompf: %s", UnavailableReason) }
