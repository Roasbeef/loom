package jail

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/roasbeef/loom/sandbox/internal/policy"
)

// systemAliasFixture models merged and ordinary system directories without
// depending on the test host's distribution or OS.
func systemAliasFixture(t *testing.T) (string, []string, []string) {
	t.Helper()
	dir := jailFixture(t)
	dir, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(dir, "usr", "bin")
	plain := filepath.Join(dir, "etc")
	for _, path := range []string{target, plain} {
		if err := os.MkdirAll(path, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(path, "sentinel"), []byte("original"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	alias := filepath.Join(dir, "bin")
	if err := os.Symlink("usr/bin", alias); err != nil {
		t.Fatal(err)
	}
	missing := filepath.Join(dir, "absent")
	return dir, []string{alias, plain, missing}, []string{target, plain, missing}
}

func wholeRootPolicies() map[string]policy.Policy {
	return map[string]policy.Policy{
		"readable": {ReadableRoots: []string{"/"}, Scratch: "tmpfs"},
		"writable": {WritableRoots: []string{"/"}, Scratch: "tmpfs"},
		"scratch":  {Scratch: "/"},
	}
}

func TestSystemRootsResolveOnlyWithAHostRoot(t *testing.T) {
	_, roots, resolved := systemAliasFixture(t)
	minimal := policy.Policy{Scratch: "tmpfs"}
	if got := systemRootsFor(minimal, roots); !reflect.DeepEqual(got, roots) {
		t.Fatalf("minimal root lost its legacy paths: %v", got)
	}
	for name, p := range wholeRootPolicies() {
		t.Run(name, func(t *testing.T) {
			got := systemRootsFor(p, roots)
			if !reflect.DeepEqual(got, resolved) {
				t.Fatalf("system roots = %v, want %v", got, resolved)
			}
			plan := mountPlanWithSystemRoots(p, nil, "", got)
			for _, path := range resolved {
				if v := effective(plan, path); v.op.Class != ClassReadable || v.writable() {
					t.Fatalf("system target %s lost its read-only bind: %+v", path, v)
				}
			}
			for _, path := range []string{"/proc", "/dev"} {
				if !effective(plan, path).masked() {
					t.Fatalf("host tree exposed at %s", path)
				}
			}
			if report := AuditMounts(p, plan); len(report.Skipped) != 0 || !strings.Contains(report.Applied, "base=host-view") {
				t.Fatalf("audit differs from the host-root plan: %+v", report)
			}
		})
	}
}

// Writes to the control must succeed, but the system binds must narrow both
// the alias and its real name. The ordinary directory covers unmerged hosts.
func TestJailedSystemAliasesStayReadOnlyUnderHostRoot(t *testing.T) {
	dir, roots, _ := systemAliasFixture(t)
	for name, p := range wholeRootPolicies() {
		t.Run(name, func(t *testing.T) {
			p.WritableRoots = append(p.WritableRoots, dir)
			allRoots := append(append([]string{}, SystemRoots...), roots...)
			plan := mountPlanWithSystemRoots(p, nil, "", systemRootsFor(p, allRoots))
			script := "echo writable > " + dir + "/control && echo CONTROL; " +
				"cat " + dir + "/bin/sentinel; " +
				"for d in " + dir + "/bin " + dir + "/usr/bin " + dir + "/etc; do " +
				"if echo changed > $d/sentinel; then echo WROTE; fi; done"
			out := inJailPlan(t, p, plan, script)
			if !strings.Contains(out, "CONTROL") || !strings.Contains(out, "original") {
				t.Fatalf("payload did not exercise allowed read/write controls: %q", out)
			}
			if strings.Contains(out, "WROTE") {
				t.Fatalf("system alias or directory became writable: %q", out)
			}
		})
	}
}
