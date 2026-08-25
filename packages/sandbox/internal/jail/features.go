package jail

import (
	"os/exec"

	"github.com/roasbeef/loom/sandbox/internal/cgroup"
	"github.com/roasbeef/loom/sandbox/internal/llock"
	"github.com/roasbeef/loom/sandbox/internal/seccompf"
)

// Features is what the current kernel and filesystem actually offer.
// Detected once at startup, advertised in the hello frame, and echoed
// per-exec so the broker can refuse degraded results by policy — the
// helper never silently pretends a layer it could not apply.
type Features struct {
	// BwrapPath is the resolved bubblewrap binary; empty means degraded
	// mode (no mount/namespace layer).
	BwrapPath string
	// LandlockABI is the kernel's Landlock ABI version; 0 with a reason
	// when unavailable.
	LandlockABI    int
	LandlockReason string
	// Seccomp reports seccomp-filter support.
	Seccomp bool
	// CgroupDir is the delegated cgroup v2 base for per-exec groups;
	// empty with a reason when unavailable.
	CgroupDir    string
	CgroupReason string
	// Platform is not a probe of the running kernel but a fact about
	// this build: whether Loom has a jail for the OS at all. See
	// platform.go for why the two kinds of gap are kept apart.
	Platform PlatformSupport
}

// DetectFeatures probes the runtime environment.
func DetectFeatures() Features {
	var f Features
	if p, err := exec.LookPath("bwrap"); err == nil {
		f.BwrapPath = p
	}
	f.LandlockABI, f.LandlockReason = llock.ABIVersion()
	f.Seccomp = seccompf.Supported()
	f.CgroupDir, f.CgroupReason = cgroup.Detect()
	f.Platform = Platform()
	return f
}

// List renders the feature set for the hello frame. rlimits and pgroup
// management need no kernel support beyond POSIX, so they are always
// present; "degraded" flags the absence of the bwrap layer, and
// "platform-unsupported" flags a build with no jail for its OS at all —
// a strictly worse thing than a degraded one, and named separately so
// the broker can tell them apart.
func (f Features) List() []string {
	out := []string{"rlimits", "pgroup"}
	if f.BwrapPath != "" {
		out = append(out, "bwrap")
	} else {
		out = append(out, "degraded")
	}
	if f.LandlockABI > 0 {
		out = append(out, "landlock")
	}
	if f.Seccomp {
		out = append(out, "seccomp")
	}
	if f.CgroupDir != "" {
		out = append(out, "cgroup-v2")
	}
	if !f.Platform.Implemented {
		out = append(out, PlatformUnsupportedFeature)
	}
	return out
}

// Degraded reports whether the strongest confinement this helper knows
// how to build was not built: the mount/namespace layer is missing, or
// there is no jail for the platform in the first place.
func (f Features) Degraded() bool {
	return f.BwrapPath == "" || !f.Platform.Implemented
}
