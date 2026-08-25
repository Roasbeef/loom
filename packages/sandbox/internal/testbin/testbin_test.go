package testbin_test

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/roasbeef/loom/sandbox/internal/jail"
	"github.com/roasbeef/loom/sandbox/internal/testbin"
)

// The helper this package builds is re-invoked from inside the jail as
// the restrict-and-exec stage, and it is the target of several probes.
// If it lives under the scratch mount, the jail's own tmpfs hides it and
// every jailed test fails for a reason that has nothing to do with the
// jail — which is exactly what happens when it is built into the system
// temp directory on a host that has bubblewrap.
func TestHelperIsVisibleFromInsideAJail(t *testing.T) {
	path := testbin.Helper(t)
	clean := filepath.Clean(path)
	if clean == jail.ScratchMount ||
		strings.HasPrefix(clean, jail.ScratchMount+string(filepath.Separator)) {
		t.Fatalf("the helper is built at %q, under the scratch mount %q; a "+
			"tmpfs scratch policy will hide it from every jail", path,
			jail.ScratchMount)
	}
}
