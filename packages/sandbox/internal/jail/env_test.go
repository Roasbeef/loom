package jail

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestFilterEnv(t *testing.T) {
	cases := []struct {
		name      string
		requested map[string]string
		allow     []string
		want      []string
	}{
		{
			name:      "allowlist filters and sorts",
			requested: map[string]string{"PATH": "/bin", "HOME": "/root", "SECRET": "x"},
			allow:     []string{"PATH", "HOME"},
			want:      []string{"HOME=/root", "PATH=/bin"},
		},
		{
			name:      "empty allowlist yields empty env",
			requested: map[string]string{"PATH": "/bin"},
			allow:     nil,
			want:      []string{},
		},
		{
			name:      "allowlisted but unset is simply absent",
			requested: map[string]string{},
			allow:     []string{"PATH"},
			want:      []string{},
		},
		{
			name:      "no wildcard semantics",
			requested: map[string]string{"PATH_EXTRA": "x"},
			allow:     []string{"PATH"},
			want:      []string{},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := FilterEnv(tc.requested, tc.allow)
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("FilterEnv = %q, want %q", got, tc.want)
			}
		})
	}
}

// TestBuildPath exercises BuildPath in isolation, against real
// directories created under the test's own scratch tree rather than
// hardcoded host paths — a directory has to exist for BuildPath to keep
// it, and the test would be at the mercy of whatever happens to be on
// the machine running it otherwise.
func TestBuildPath(t *testing.T) {
	root := t.TempDir()
	a := filepath.Join(root, "a")
	b := filepath.Join(root, "b")
	dup := filepath.Join(root, "a") // same path as a, to test dedup
	writable := filepath.Join(root, "writable")
	inWritable := filepath.Join(writable, "bin")
	missing := filepath.Join(root, "does-not-exist")
	notAbs := "relative/bin"

	for _, dir := range []string{a, b, inWritable} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("MkdirAll(%s): %v", dir, err)
		}
	}

	t.Run("filters, dedups, and appends defaults", func(t *testing.T) {
		inherited := strings.Join([]string{a, b, dup, missing, notAbs}, ":")
		got := BuildPath(inherited, nil)
		want := append([]string{a, b}, jailedPathDefaults...)
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("BuildPath = %q, want %q", got, want)
		}
	})

	t.Run("empty inherited PATH yields exactly today's defaults", func(t *testing.T) {
		got := BuildPath("", nil)
		if !reflect.DeepEqual(got, jailedPathDefaults) {
			t.Fatalf("BuildPath(\"\", nil) = %q, want %q", got, jailedPathDefaults)
		}
	})

	t.Run("a hostile inherited PATH still yields the defaults", func(t *testing.T) {
		hostile := strings.Join([]string{notAbs, missing, "../also/relative"}, ":")
		got := BuildPath(hostile, nil)
		if !reflect.DeepEqual(got, jailedPathDefaults) {
			t.Fatalf("BuildPath(hostile, nil) = %q, want %q", got, jailedPathDefaults)
		}
	})

	t.Run("an entry under a writable root is excluded", func(t *testing.T) {
		inherited := strings.Join([]string{a, inWritable, b}, ":")
		got := BuildPath(inherited, []string{writable})
		want := append([]string{a, b}, jailedPathDefaults...)
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("BuildPath = %q, want %q (inWritable should be excluded)", got, want)
		}
	})

	t.Run("defaults are never dropped even when also inherited", func(t *testing.T) {
		defaultDir := jailedPathDefaults[0]
		got := BuildPath(defaultDir, nil)
		if !reflect.DeepEqual(got, jailedPathDefaults) {
			t.Fatalf("BuildPath(%q, nil) = %q, want %q (no duplicate, defaults intact)",
				defaultDir, got, jailedPathDefaults)
		}
	})
}
