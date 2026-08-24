package jail

import "sort"

// FilterEnv builds the jailed process's environment from the broker's
// requested env and the policy's allowlist. The environment is
// *constructed*, never inherited (design §5.2: secrets live only in
// ProviderGateway memory; tool environments are allowlist-built): a name
// absent from env_allow is dropped even if the broker sent it, so a
// policy alone is enough to audit what a jail could see. Deterministic
// (sorted) for tests and reproducibility.
func FilterEnv(requested map[string]string, allow []string) []string {
	allowed := make(map[string]bool, len(allow))
	for _, name := range allow {
		allowed[name] = true
	}
	names := make([]string, 0, len(requested))
	for name := range requested {
		if allowed[name] {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	out := make([]string, 0, len(names))
	for _, name := range names {
		out = append(out, name+"="+requested[name])
	}
	return out
}
