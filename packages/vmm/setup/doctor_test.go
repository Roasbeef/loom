package setup

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// signed is `codesign -d --entitlements -` output for a runner that holds the
// entitlement, in the dump format macOS prints.
const signed = `Executable=/x/runner
[Dict]
	[Key] com.apple.security.cs.allow-jit
	[Value]
		[Bool] true
	[Key] com.apple.security.hypervisor
	[Value]
		[Bool] true
`

// doctorFixture installs a release into a temporary home and returns options
// for Doctor.
func doctorFixture(t *testing.T) (DoctorOptions, Manifest, *fakeRun) {
	t.Helper()

	f := newFixture(t)
	m, err := Release(context.Background(), f.opts)
	if err != nil {
		t.Fatal(err)
	}

	run := &fakeRun{out: map[string]string{"codesign": signed, "ps": ""}}

	return DoctorOptions{Home: f.opts.Home, GOOS: "darwin", Run: run.run}, m, run
}

// status finds the status of one check.
func status(t *testing.T, r Report, name string) Status {
	t.Helper()

	for _, c := range r.Checks {
		if c.Name == name {
			return c.Status
		}
	}
	t.Fatalf("no check %q in %+v", name, r.Checks)

	return Fail
}

// TestDoctorHealthyInstall checks every manifest entry reports ok. The
// loom-vm path the fixture records does not exist on the host, and the
// hypervisor answer depends on the host, so those two are not asserted ok.
func TestDoctorHealthyInstall(t *testing.T) {
	opts, _, _ := doctorFixture(t)

	rep := Doctor(context.Background(), opts)
	for _, name := range []string{
		"manifest", "runner", "runner sha256", "entitlement",
		"libkrun", "firmware", "firmware sha256", "guest root", "orphans",
	} {
		if s := status(t, rep, name); s != OK {
			t.Errorf("%s = %v: %+v", name, s, rep.Checks)
		}
	}

	if status(t, rep, "loom-vm") != Fail {
		t.Errorf("loom-vm should fail for a missing binary")
	}
}

// TestDoctorDetectsDamage checks each way an installation goes wrong after
// setup: a changed runner, an unsigned runner, a root that lost /tmp's mode,
// a missing libkrun.
func TestDoctorDetectsDamage(t *testing.T) {
	t.Run("changed runner", func(t *testing.T) {
		opts, m, _ := doctorFixture(t)
		os.WriteFile(m.Runner, []byte("different"), 0o755)

		if s := status(t, Doctor(context.Background(), opts), "runner sha256"); s != Fail {
			t.Errorf("runner sha256 = %v", s)
		}
	})

	t.Run("unsigned runner", func(t *testing.T) {
		opts, _, run := doctorFixture(t)
		run.out["codesign"] = "Executable=/x/runner\n[Dict]\n\t[Key] com.apple.security.cs.allow-jit\n"

		if s := status(t, Doctor(context.Background(), opts), "entitlement"); s != Fail {
			t.Errorf("entitlement = %v", s)
		}
	})

	t.Run("xml entitlements", func(t *testing.T) {
		opts, _, run := doctorFixture(t)
		run.out["codesign"] = `<plist><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>`

		if s := status(t, Doctor(context.Background(), opts), "entitlement"); s != OK {
			t.Errorf("entitlement = %v", s)
		}
	})

	t.Run("lost sticky bit", func(t *testing.T) {
		opts, m, _ := doctorFixture(t)
		os.Chmod(filepath.Join(m.GuestRoot, "tmp"), 0o755)

		if s := status(t, Doctor(context.Background(), opts), "guest root"); s != Fail {
			t.Errorf("guest root = %v", s)
		}
	})

	t.Run("no libkrun", func(t *testing.T) {
		opts, m, _ := doctorFixture(t)
		os.RemoveAll(m.LibDir)

		if s := status(t, Doctor(context.Background(), opts), "libkrun"); s != Fail {
			t.Errorf("libkrun = %v", s)
		}
	})
}

// TestDoctorWithoutManifest checks the report points at setup.
func TestDoctorWithoutManifest(t *testing.T) {
	rep := Doctor(context.Background(), DoctorOptions{Home: t.TempDir()})
	if !rep.Failed() || !strings.Contains(rep.Checks[0].Detail, "loom-vm setup") {
		t.Errorf("report = %+v", rep.Checks)
	}
}

// TestDoctorOnABuildTree checks that a tree installed with FromBuild has no
// recorded digests and says so as a note, not a failure.
func TestDoctorOnABuildTree(t *testing.T) {
	home := t.TempDir()
	if _, err := FromBuild(context.Background(), BuildOptions{
		Home: home, Dir: buildTree(t), LibDir: fakeLibDir(t), GOOS: "darwin", LoomVM: "/x/loom-vm",
	}); err != nil {
		t.Fatal(err)
	}

	run := &fakeRun{out: map[string]string{"codesign": signed, "ps": ""}}
	rep := Doctor(context.Background(), DoctorOptions{Home: home, GOOS: "darwin", Run: run.run})

	if s := status(t, rep, "runner sha256"); s != Note {
		t.Errorf("runner sha256 = %v", s)
	}
}

// TestFindOrphans checks which runners are reported: those whose parent is
// gone or is not loom-vm.
func TestFindOrphans(t *testing.T) {
	ps := `    1     0 /sbin/launchd
  100     1 /Users/me/bin/loom-vm run --root-dir /x -- /bin/true
  101   100 /Users/me/.loom/vm/cache/v1/go-microvm-runner --config /a
  200     1 /Users/me/.loom/vm/cache/v1/go-microvm-runner --config /b
  300   999 /opt/x/go-microvm-runner --config /c
  400   100 /bin/sleep 1
garbage line
`

	got := FindOrphans(ps)
	if len(got) != 2 || got[0].PID != 200 || got[1].PID != 300 {
		t.Fatalf("orphans = %+v, want pids 200 and 300", got)
	}

	if got[0].PPID != 1 || !strings.Contains(got[0].Args, "--config /b") {
		t.Errorf("orphan = %+v", got[0])
	}
}

// TestReportPrintsOrphans checks the orphans reach the output.
func TestReportPrintsOrphans(t *testing.T) {
	var out strings.Builder
	Report{
		Checks:  []Check{{"runner", OK, "/x"}},
		Orphans: []Process{{PID: 7, PPID: 1, Args: "/x/go-microvm-runner"}},
	}.Print(&out)

	for _, want := range []string{"ok", "runner", "orphan runner", "pid 7"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("output lacks %q:\n%s", want, out.String())
		}
	}
}
