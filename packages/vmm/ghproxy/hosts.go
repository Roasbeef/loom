package ghproxy

import (
	"fmt"
	"strings"
)

// hostSet is a list of host globs: exact names, and names with a leading "*."
// that match one or more subdomain labels. The vocabulary is the one
// go-microvm's egress policy and machine.Egress use, so an operator writes the
// same entry in either place and gets the same hosts.
type hostSet struct {
	exact    map[string]bool
	suffixes []string
}

// newHostSet validates and normalises globs. An entry that is not a bare
// hostname, or that puts a wildcard over a whole top-level domain, is an
// error: a silently dead entry is how an allowlist gets widened by someone who
// never suspected the entry.
func newHostSet(globs []string) (hostSet, error) {
	s := hostSet{exact: make(map[string]bool, len(globs))}

	for _, g := range globs {
		name := normalizeHost(g)
		bare := strings.TrimPrefix(name, "*.")

		switch {
		case bare == "":
			return hostSet{}, fmt.Errorf("ghproxy: empty host glob %q", g)

		case strings.ContainsAny(bare, "*/:@ "):
			return hostSet{}, fmt.Errorf("ghproxy: host glob %q is not a bare hostname", g)

		case bare != name && !strings.Contains(bare, "."):
			return hostSet{}, fmt.Errorf("ghproxy: host glob %q covers a whole "+
				"top-level domain", g)
		}

		if bare != name {
			s.suffixes = append(s.suffixes, name[1:])
		} else {
			s.exact[name] = true
		}
	}

	return s, nil
}

// matches reports whether host is covered by the set. A wildcard never covers
// the bare domain it hangs from: "*.github.com" matches "api.github.com" and
// not "github.com".
func (s hostSet) matches(host string) bool {
	host = normalizeHost(host)
	if s.exact[host] {
		return true
	}

	for _, suffix := range s.suffixes {
		if strings.HasSuffix(host, suffix) && len(host) > len(suffix) {
			return true
		}
	}

	return false
}

// domains returns the set as the DNS domains an x509 name constraint takes:
// the wildcard prefix is dropped, and a constraint on "github.com" already
// covers its subdomains.
func (s hostSet) domains() []string {
	out := make([]string, 0, len(s.exact)+len(s.suffixes))
	for name := range s.exact {
		out = append(out, name)
	}

	for _, suffix := range s.suffixes {
		out = append(out, strings.TrimPrefix(suffix, "."))
	}

	return out
}

// normalizeHost lowercases a name and drops one trailing dot.
func normalizeHost(h string) string {
	return strings.ToLower(strings.TrimSuffix(h, "."))
}
