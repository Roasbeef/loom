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
	return f
}

// List renders the feature set for the hello frame. rlimits and pgroup
// management need no kernel support beyond POSIX, so they are always
// present; "degraded" flags the absence of the bwrap layer.
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
	return out
}

// Degraded reports whether the mount/namespace layer is missing.
func (f Features) Degraded() bool { return f.BwrapPath == "" }
