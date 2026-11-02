package ghproxy

import (
	"slices"
	"testing"
)

func TestHostSetMatching(t *testing.T) {
	set, err := newHostSet([]string{"github.com", "*.Githubusercontent.com", "api.example.org."})
	if err != nil {
		t.Fatal(err)
	}

	cases := map[string]bool{
		"github.com":                     true,
		"GITHUB.COM":                     true,
		"github.com.":                    true,
		"api.github.com":                 false,
		"raw.githubusercontent.com":      true,
		"a.b.githubusercontent.com":      true,
		"githubusercontent.com":          false,
		"evilgithubusercontent.com":      false,
		"api.example.org":                true,
		"notgithub.com":                  false,
		"github.com.evil.example":        false,
		"":                               false,
		"raw.githubusercontent.com.evil": false,
	}

	for host, want := range cases {
		if got := set.matches(host); got != want {
			t.Errorf("matches(%q) = %v, want %v", host, got, want)
		}
	}
}

func TestHostSetRejectsMalformedGlobs(t *testing.T) {
	for _, g := range []string{"", "*.", "*.com", "https://github.com", "github.com:443",
		"a*.example.com", "user@example.com", "two words.example"} {
		if _, err := newHostSet([]string{g}); err == nil {
			t.Errorf("newHostSet accepted %q", g)
		}
	}
}

func TestHostSetDomains(t *testing.T) {
	set, err := newHostSet([]string{"github.com", "*.example.org"})
	if err != nil {
		t.Fatal(err)
	}

	got := set.domains()
	slices.Sort(got)

	if !slices.Equal(got, []string{"example.org", "github.com"}) {
		t.Fatalf("domains = %v", got)
	}
}
