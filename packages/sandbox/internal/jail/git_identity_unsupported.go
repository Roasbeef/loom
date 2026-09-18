//go:build !linux && !darwin

package jail

import (
	"errors"

	"github.com/roasbeef/loom/sandbox/internal/policy"
)

func publishGitIdentity(_ policy.Policy, _ string, _ []byte) error {
	return errors.New("Git identity publication is unsupported on this platform")
}
