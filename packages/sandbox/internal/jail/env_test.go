package jail

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/roasbeef/loom/sandbox/internal/policy"
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
		got := BuildPath("", inherited, nil)
		want := append([]string{a, b}, jailedPathDefaults...)
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("BuildPath = %q, want %q", got, want)
		}
	})

	t.Run("empty inherited PATH yields exactly today's defaults", func(t *testing.T) {
		got := BuildPath("", "", nil)
		if !reflect.DeepEqual(got, jailedPathDefaults) {
			t.Fatalf("BuildPath(\"\", \"\", nil) = %q, want %q", got, jailedPathDefaults)
		}
	})

	t.Run("a hostile inherited PATH still yields the defaults", func(t *testing.T) {
		hostile := strings.Join([]string{notAbs, missing, "../also/relative"}, ":")
		got := BuildPath("", hostile, nil)
		if !reflect.DeepEqual(got, jailedPathDefaults) {
			t.Fatalf("BuildPath(hostile) = %q, want %q", got, jailedPathDefaults)
		}
	})

	t.Run("an entry under a writable root is excluded", func(t *testing.T) {
		inherited := strings.Join([]string{a, inWritable, b}, ":")
		got := BuildPath("", inherited, []string{writable})
		want := append([]string{a, b}, jailedPathDefaults...)
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("BuildPath = %q, want %q (inWritable should be excluded)", got, want)
		}
	})

	t.Run("defaults are never dropped even when also inherited", func(t *testing.T) {
		defaultDir := jailedPathDefaults[0]
		got := BuildPath("", defaultDir, nil)
		if !reflect.DeepEqual(got, jailedPathDefaults) {
			t.Fatalf("BuildPath(%q) = %q, want %q (no duplicate, defaults intact)",
				defaultDir, got, jailedPathDefaults)
		}
	})
}

// TestBuildPathRequested covers the half of BuildPath that carries a
// bundled toolchain: the broker's requested PATH. The precedence is what
// makes an unpacked release usable — its `erl` sits under
// `erts-<vsn>/bin` and is never on the daemon's own PATH — and the
// filtering is what keeps the request from reopening the
// tool-substitution hole the inherited list is already closed against.
func TestBuildPathRequested(t *testing.T) {
	root := t.TempDir()
	bundle := filepath.Join(root, "bundle", "bin")
	system := filepath.Join(root, "system", "bin")
	writable := filepath.Join(root, "workspace")
	inWritable := filepath.Join(writable, "bin")
	notDir := filepath.Join(root, "gleam")

	for _, dir := range []string{bundle, system, inWritable} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("MkdirAll(%s): %v", dir, err)
		}
	}
	if err := os.WriteFile(notDir, []byte("not a directory"), 0o644); err != nil {
		t.Fatalf("WriteFile(%s): %v", notDir, err)
	}

	t.Run("requested entries lead inherited ones", func(t *testing.T) {
		got := BuildPath(bundle, system, nil)
		want := append([]string{bundle, system}, jailedPathDefaults...)
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("BuildPath = %q, want %q", got, want)
		}
	})

	t.Run("a requested entry under a writable root is dropped", func(t *testing.T) {
		requested := strings.Join([]string{inWritable, bundle}, ":")
		got := BuildPath(requested, "", []string{writable})
		want := append([]string{bundle}, jailedPathDefaults...)
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("BuildPath = %q, want %q (inWritable should be excluded)", got, want)
		}
	})

	t.Run("an uncleaned requested entry is still contained", func(t *testing.T) {
		got := BuildPath(inWritable+"/.", "", []string{writable + "/"})
		if !reflect.DeepEqual(got, jailedPathDefaults) {
			t.Fatalf("BuildPath = %q, want %q", got, jailedPathDefaults)
		}
	})

	t.Run("a requested entry that is not a directory is dropped", func(t *testing.T) {
		got := BuildPath(notDir, "", nil)
		if !reflect.DeepEqual(got, jailedPathDefaults) {
			t.Fatalf("BuildPath(notDir) = %q, want %q", got, jailedPathDefaults)
		}
	})
}

// TestPathExcludedRoots pins the exclusion set to what the sandbox
// actually makes writable, not merely to what the policy names. The
// Linux tmpfs case is the one a policy read alone would miss: inside the
// jail `/tmp` is the model's own tmpfs, so a PATH entry beneath it is a
// directory the model can write to.
func TestPathExcludedRoots(t *testing.T) {
	t.Run("a tmpfs scratch excludes the mount point on linux", func(t *testing.T) {
		pol := policy.Policy{Scratch: "tmpfs", WritableRoots: []string{"/work"}}
		got := pathExcludedRoots(pol, "linux")
		want := []string{"/work", ScratchMount}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("pathExcludedRoots = %q, want %q", got, want)
		}
		if !coveredBy(got, filepath.Clean(ScratchMount+"/tools")) {
			t.Fatalf("%s/tools should be excluded under a tmpfs scratch", ScratchMount)
		}
	})

	t.Run("a host-backed scratch excludes its own directory", func(t *testing.T) {
		pol := policy.Policy{Scratch: "/host/scratch/", WritableRoots: []string{"/work/."}}
		got := pathExcludedRoots(pol, "linux")
		want := []string{"/work", "/host/scratch"}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("pathExcludedRoots = %q, want %q", got, want)
		}
	})
}
