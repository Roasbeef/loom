//go:build !darwin

package jail

// DarwinUserDirectories has nothing to report off macOS: the profile it
// feeds is only ever rendered there, and a Linux test that renders one for
// its shape gets the policy's roots alone.
func DarwinUserDirectories() []string { return nil }
