package jail

import (
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

// The harness refuses native reads under the roots this jail replaces with
// its own (a fresh /proc, a minimal /dev and the scratch tmpfs), because a
// tool never sees the host's version of them. The list lives in
// broker/policy.gleam as `jail_replaced_roots`; the mounts live in bwrap.go.
// Nothing but this test ties the two together, so a mount added here without
// a matching entry there would silently reopen the hole.
func TestGleamReplacedRootsMatchTheJailsMounts(t *testing.T) {
	_, here, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate this test file")
	}
	// packages/sandbox/internal/jail -> packages/broker/src/broker/policy.gleam
	gleam := filepath.Join(filepath.Dir(here), "..", "..", "..", "broker", "src", "broker", "policy.gleam")
	raw, err := os.ReadFile(gleam)
	if err != nil {
		t.Fatalf("read %s: %v", gleam, err)
	}
	source := string(raw)

	list := regexp.MustCompile(`pub const jail_replaced_roots = \[([^\]]*)\]`).FindStringSubmatch(source)
	if list == nil {
		t.Fatalf("no `pub const jail_replaced_roots = [...]` literal in %s; "+
			"the list the harness refuses native reads under moved or was renamed, "+
			"and it must stay equal to the mounts in bwrap.go", gleam)
	}

	var got []string
	for element := range strings.SplitSeq(list[1], ",") {
		element = strings.TrimSpace(element)
		if element == "" {
			continue
		}
		if strings.HasPrefix(element, `"`) {
			got = append(got, strings.Trim(element, `"`))
			continue
		}
		// A reference to another constant in the same file.
		ref := regexp.MustCompile(`pub const ` + regexp.QuoteMeta(element) + ` = "([^"]*)"`).FindStringSubmatch(source)
		if ref == nil {
			t.Fatalf("`jail_replaced_roots` names %q in %s, which is not a string constant there", element, gleam)
		}
		got = append(got, ref[1])
	}

	want := []string{"/proc", "/dev", ScratchMount}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("broker/policy.gleam jail_replaced_roots = %v, but bwrap.go mounts %v "+
			"(/proc and /dev in the mask plan, ScratchMount for the scratch tmpfs); "+
			"update both files together", got, want)
	}
}
