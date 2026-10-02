package jail

import (
	"fmt"
	"runtime"
)

// PlatformSupport answers one question about this *build* of loom-exec:
// does Loom have a jail implementation for the operating system it was
// compiled for?
//
// It is deliberately not a probe. Everything else in Features asks the
// running kernel what it can provide, and reports a missing layer as an
// environmental skip — a kernel without Landlock, a container without a
// delegated cgroup hierarchy. This is the other kind of gap: the layer is
// missing from *Loom*, not from the machine. Conflating the two would let
// a macOS run print the same reassuring "skips are environmental, not
// passes" that a Linux container prints, when the truthful statement is
// that no confinement was even attempted.
//
// WP-H phase 1 is Linux and phase 2 is macOS Seatbelt. Phase 3 (Windows
// restricted tokens and ACLs) remains specified and unbuilt.
type PlatformSupport struct {
	// GOOS is the operating system this binary was built for.
	GOOS string
	// Implemented is true only where a jail actually exists.
	Implemented bool
	// Reason states what is missing, in the `skip:` report vocabulary.
	// Empty exactly when Implemented.
	Reason string
}

// The feature tag and the argument that opts out of the refusal. Both are
// named here so the server, the self-test, and the tests agree on the
// spelling.
const (
	// PlatformUnsupportedFeature appears in hello.features when this
	// build has no jail for its platform.
	PlatformUnsupportedFeature = "platform-unsupported"
	// AllowUnenforcedFlag is the explicit opt-in that lets loom-exec
	// serve anyway, with no confinement at all.
	AllowUnenforcedFlag = "--allow-unenforced"
)

// Platform reports the jail support compiled into this binary.
func Platform() PlatformSupport { return PlatformFor(runtime.GOOS) }

// PlatformFor is the pure decision, taking the OS as an argument so every
// platform answer is testable on every host. Live backend tests separately
// exercise the kernel implementation on its native operating system.
func PlatformFor(goos string) PlatformSupport {
	switch goos {
	case "linux":
		return PlatformSupport{GOOS: goos, Implemented: true}
	case "darwin":
		return PlatformSupport{GOOS: goos, Implemented: true}
	case "windows":
		return PlatformSupport{GOOS: goos, Reason: "jail: the Windows " +
			"sandbox (WP-H phase 3) is not implemented — loom-exec " +
			"applies no restricted token, no ACLs, and no firewall rule"}
	default:
		return PlatformSupport{GOOS: goos, Reason: fmt.Sprintf(
			"jail: loom-exec has no sandbox implementation for %s; "+
				"Linux and macOS are built (WP-H phases 1 and 2)", goos)}
	}
}

// Refusal is the message loom-exec prints instead of serving, or empty
// when it may serve. An unsupported platform refuses by default: running
// model-influenced code with a policy that says `network: off` on a host
// that cannot enforce it is not a degraded sandbox, it is no sandbox, and
// the broker's own BestEffort callers would proceed regardless. The
// opt-out exists so the refusal is a decision rather than a dead end.
func (p PlatformSupport) Refusal(allowUnenforced bool) string {
	if p.Implemented || allowUnenforced {
		return ""
	}
	return fmt.Sprintf(
		"loom-exec refuses to serve on %s: %s. Pass %s to run anyway, "+
			"with no kernel enforcement whatsoever.",
		p.GOOS, p.Reason, AllowUnenforcedFlag,
	)
}
