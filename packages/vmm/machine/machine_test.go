package machine

import (
	"net/http"
	"strings"
	"testing"
)

// valid returns a Spec that passes Validate, for tests to break one field
// at a time.
func valid() Spec {
	return Spec{
		Root: Root{Image: "alpine:3.22"},
		Init: []string{"/bin/true"},
	}
}

// TestValidateRefusesBadSpecs checks each refusal Validate exists to make
// before a backend has pulled an image or written into a directory.
func TestValidateRefusesBadSpecs(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*Spec)
		want   string
	}{
		{"no root", func(s *Spec) { s.Root = Root{} }, "no root"},
		{"both roots", func(s *Spec) { s.Root.Dir = "/r" }, "both"},
		{"no init", func(s *Spec) { s.Init = nil }, "no init"},
		{"empty init", func(s *Spec) { s.Init = []string{""} }, "no init"},
		{"relative target", func(s *Spec) {
			s.Files = []File{{Source: "a", Target: "etc/x"}}
		}, "clean absolute"},
		{"climbing target", func(s *Spec) {
			s.Files = []File{{Source: "a", Target: "/etc/../../x"}}
		}, "clean absolute"},
		{"root target", func(s *Spec) {
			s.Files = []File{{Source: "a", Target: "/"}}
		}, "clean absolute"},
		{"no source", func(s *Spec) {
			s.Files = []File{{Target: "/etc/x"}}
		}, "no source"},
		{"empty host", func(s *Spec) { s.Egress.Hosts = []string{""} }, "empty"},
		{"bare wildcard", func(s *Spec) { s.Egress.Hosts = []string{"*."} }, "empty"},
		{"url host", func(s *Spec) {
			s.Egress.Hosts = []string{"https://example.com"}
		}, "bare hostname"},
		{"port host", func(s *Spec) {
			s.Egress.Hosts = []string{"example.com:443"}
		}, "bare hostname"},
		{"top-level wildcard", func(s *Spec) {
			s.Egress.Hosts = []string{"*.com"}
		}, "top-level"},
		{"inner wildcard", func(s *Spec) {
			s.Egress.Hosts = []string{"a.*.com"}
		}, "bare hostname"},
		{"zero forward", func(s *Spec) {
			s.Forwards = []Forward{{Host: 0, Guest: 22}}
		}, "zero port"},
		{"duplicate forward", func(s *Spec) {
			s.Forwards = []Forward{{Host: 4000, Guest: 1}, {Host: 4000, Guest: 2}}
		}, "twice"},
		{"service without handler", func(s *Spec) {
			s.HostServices = []HostService{{Port: 3128}}
		}, "needs a port and a handler"},
		{"service without port", func(s *Spec) {
			s.HostServices = []HostService{{Handler: http.NotFoundHandler()}}
		}, "needs a port and a handler"},
		{"duplicate service", func(s *Spec) {
			h := http.NotFoundHandler()
			s.HostServices = []HostService{{Port: 3128, Handler: h}, {Port: 3128, Handler: h}}
		}, "used twice"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := valid()
			tc.mutate(&s)

			err := s.Validate()
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("Validate() = %v, want error containing %q", err, tc.want)
			}
		})
	}
}

// TestValidateAcceptsGoodSpecs checks the shapes a launcher actually sends.
func TestValidateAcceptsGoodSpecs(t *testing.T) {
	s := valid()
	s.Files = []File{{Source: "/tmp/loom-exec", Target: "/usr/local/bin/loom-exec"}}
	s.Egress.Hosts = []string{"dl-cdn.alpinelinux.org", "*.github.com"}

	if err := s.Validate(); err != nil {
		t.Fatalf("Validate() = %v", err)
	}

	s.Root = Root{Dir: "/var/lib/loom/root"}
	if err := s.Validate(); err != nil {
		t.Fatalf("Validate() with Root.Dir = %v", err)
	}
}
