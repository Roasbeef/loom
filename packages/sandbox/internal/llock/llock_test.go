package llock

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"

	"github.com/landlock-lsm/go-landlock/landlock"
)

func TestRules(t *testing.T) {
	got := Rules(PolicyView{
		WritableRoots: []string{"/work/b", "/work/a"},
		ReadableRoots: []string{"/opt"},
		WritableFiles: []string{"/dev/null"},
		ScratchPath:   "/tmp",
	})
	want := []Rule{
		{Path: "/", Access: ReadOnly},
		{Path: "/opt", Access: ReadOnly, Optional: true},
		{Path: "/work/a", Access: ReadWrite, Optional: true},
		{Path: "/work/b", Access: ReadWrite, Optional: true},
		{Path: "/dev/null", Access: ReadWrite, File: true},
		{Path: "/tmp", Access: ReadWrite, Optional: true},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Rules mismatch:\n got  %v\nwant %v", got, want)
	}
}

func TestRulesNoScratch(t *testing.T) {
	got := Rules(PolicyView{WritableRoots: []string{"/w"}})
	want := []Rule{
		{Path: "/", Access: ReadOnly},
		{Path: "/w", Access: ReadWrite, Optional: true},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Rules mismatch:\n got  %v\nwant %v", got, want)
	}
}

// The root grant must always be present and first: everything else is
// carve-up, and losing it would make the jail unable to exec anything.
func TestRulesAlwaysGrantRootRead(t *testing.T) {
	got := Rules(PolicyView{})
	if len(got) == 0 || got[0].Path != "/" || got[0].Access != ReadOnly {
		t.Fatalf("missing root read grant: %v", got)
	}
}

// Policy roots are path regions, not a promise that the named object is
// a directory. Both access classes must translate files and directories
// without widening the containing directory, including through symlinks.
func TestFilesystemRuleUsesTheJailObjectKind(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "file")
	if err := os.WriteFile(file, []byte("readable"), 0600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(file, link); err != nil {
		t.Fatal(err)
	}
	dirLink := filepath.Join(dir, "dir-link")
	if err := os.Symlink(dir, dirLink); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name string
		rule Rule
		want landlock.FSRule
	}{
		{"read file", Rule{Path: file, Access: ReadOnly}, landlock.ROFiles(file)},
		{"write file", Rule{Path: file, Access: ReadWrite}, landlock.RWFiles(file)},
		{"read directory", Rule{Path: dir, Access: ReadOnly}, landlock.RODirs(dir)},
		{"write directory", Rule{Path: dir, Access: ReadWrite}, landlock.RWDirs(dir)},
		{"read symlink", Rule{Path: link, Access: ReadOnly}, landlock.ROFiles(link)},
		{"write symlink", Rule{Path: link, Access: ReadWrite}, landlock.RWFiles(link)},
		{"read directory symlink", Rule{Path: dirLink, Access: ReadOnly}, landlock.RODirs(dirLink)},
		{"write directory symlink", Rule{Path: dirLink, Access: ReadWrite}, landlock.RWDirs(dirLink)},
		{"explicit null device", Rule{Path: "/dev/null", Access: ReadWrite, File: true}, landlock.RWFiles("/dev/null")},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := filesystemRule(tc.rule)
			if err != nil {
				t.Fatal(err)
			}
			if got.String() != tc.want.String() {
				t.Fatalf("rule = %s, want %s", got, tc.want)
			}
		})
	}
}

// Missing optional roots retain the dependency's ignore-at-open behavior;
// a required missing object and other stat failures still refuse.
func TestFilesystemRulePreservesMissingPaths(t *testing.T) {
	dir := t.TempDir()
	missing := filepath.Join(dir, "missing")
	got, err := filesystemRule(Rule{Path: missing, Access: ReadOnly, Optional: true})
	if err != nil {
		t.Fatal(err)
	}
	want := landlock.RODirs(missing).IgnoreIfMissing()
	if got.String() != want.String() {
		t.Fatalf("optional missing rule = %s, want %s", got, want)
	}
	_, err = filesystemRule(Rule{Path: missing, Access: ReadOnly})
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("required missing rule = %v, want not-exist refusal", err)
	}
	file := filepath.Join(dir, "file")
	if err := os.WriteFile(file, nil, 0600); err != nil {
		t.Fatal(err)
	}
	_, err = filesystemRule(Rule{Path: file + "/child", Access: ReadOnly, Optional: true})
	if err == nil {
		t.Fatal("optional path hid a non-missing stat failure")
	}
}

// Applying Landlock changes every thread irreversibly, so the kernel
// regression runs in a fresh test process. It carries the exact /bin/cat
// file grant that refused real model-authored bash on Linux, exercises a
// directory grant, and checks that an ungranted write remains denied.
func TestApplyFileAndDirectoryRoots(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("actual Landlock enforcement requires Linux")
	}
	if abi, reason := ABIVersion(); abi == 0 {
		t.Skip(reason)
	}
	if dir := os.Getenv("LOOM_LLOCK_TEST_ROOT"); dir != "" {
		rules := Rules(PolicyView{
			ReadableRoots: []string{"/bin/cat", filepath.Join(dir, "absent")},
			WritableRoots: []string{filepath.Join(dir, "writable"), filepath.Join(dir, "writable-file")},
		})
		if err := Apply(rules); err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command("/bin/cat")
		cmd.Stdin = strings.NewReader("file grant survived exec\n")
		out, err := cmd.CombinedOutput()
		if err != nil || string(out) != "file grant survived exec\n" {
			t.Fatalf("cat = %q, %v", out, err)
		}
		if err := os.WriteFile(filepath.Join(dir, "writable", "allowed"), []byte("allowed"), 0600); err != nil {
			t.Fatalf("directory grant did not allow write: %v", err)
		}
		if err := os.WriteFile(filepath.Join(dir, "writable-file"), []byte("allowed"), 0600); err != nil {
			t.Fatalf("file grant did not allow write: %v", err)
		}
		if err := os.WriteFile(filepath.Join(dir, "denied"), []byte("forbidden"), 0600); !errors.Is(err, os.ErrPermission) {
			t.Fatalf("outside write = %v, want permission denial", err)
		}
		return
	}

	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "writable"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "writable-file"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(binary, "-test.run=^TestApplyFileAndDirectoryRoots$", "-test.v")
	cmd.Env = append(os.Environ(), "LOOM_LLOCK_TEST_ROOT="+dir)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("Landlock child: %v\n%s", err, out)
	}
}
