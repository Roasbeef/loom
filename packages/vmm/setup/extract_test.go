package setup

import (
	"archive/tar"
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// TestExtractPreservesModesAndLinks checks the properties the guest depends
// on: directory modes survive the umask, setuid and sticky bits are kept,
// symlinks are created as written (absolute, relative and dangling) and a
// directory the archive makes read-only does not block the files inside it.
func TestExtractPreservesModesAndLinks(t *testing.T) {
	// A restrictive umask is what breaks a naive extraction.
	old := syscall.Umask(0o077)
	defer syscall.Umask(old)

	raw := tarOf(t,
		entry{Name: "./", Type: tar.TypeDir, Mode: 0o755},
		entry{Name: "tmp/", Type: tar.TypeDir, Mode: 0o1777},
		entry{Name: "ro/", Type: tar.TypeDir, Mode: 0o555},
		entry{Name: "ro/inside", Mode: 0o444, Body: "x"},
		entry{Name: "implicit/child/file", Mode: 0o644, Body: "y"},
		entry{Name: "bin/", Type: tar.TypeDir, Mode: 0o755},
		entry{Name: "bin/sudo", Mode: 0o4755, Body: "suid"},
		entry{Name: "bin/tool", Mode: 0o755, Body: "tool"},
		entry{Name: "bin/alias", Type: tar.TypeSymlink, Link: "tool"},
		entry{Name: "bin/hard", Type: tar.TypeLink, Link: "bin/tool"},
		entry{Name: "abs", Type: tar.TypeSymlink, Link: "/etc/passwd"},
		entry{Name: "dangling", Type: tar.TypeSymlink, Link: "nowhere"},
		entry{Name: "dev/null", Type: tar.TypeChar},
		entry{Name: "fifo", Type: tar.TypeFifo},
	)

	dir := t.TempDir()
	if err := ExtractRoot(bytes.NewReader(raw), dir); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { RemoveTree(dir) })

	modes := map[string]os.FileMode{
		"tmp":       os.ModeDir | os.ModeSticky | 0o777,
		"ro":        os.ModeDir | 0o555,
		"ro/inside": 0o444,
		"implicit":  os.ModeDir | 0o755,
		"bin/sudo":  os.ModeSetuid | 0o755,
		"bin/tool":  0o755,
		"bin/hard":  0o755,
		".":         os.ModeDir | 0o755,
	}
	for rel, want := range modes {
		info, err := os.Lstat(filepath.Join(dir, rel))
		if err != nil {
			t.Errorf("%s: %v", rel, err)

			continue
		}
		if info.Mode() != want {
			t.Errorf("%s mode = %v, want %v", rel, info.Mode(), want)
		}
	}

	for link, target := range map[string]string{
		"bin/alias": "tool",
		"abs":       "/etc/passwd",
		"dangling":  "nowhere",
	} {
		got, err := os.Readlink(filepath.Join(dir, link))
		if err != nil || got != target {
			t.Errorf("%s -> %q, %v; want %q", link, got, err, target)
		}
	}

	a, _ := os.Stat(filepath.Join(dir, "bin/tool"))
	b, _ := os.Stat(filepath.Join(dir, "bin/hard"))
	if !os.SameFile(a, b) {
		t.Error("hard link was copied, not linked")
	}

	for _, rel := range []string{"dev/null", "fifo"} {
		if _, err := os.Lstat(filepath.Join(dir, rel)); !os.IsNotExist(err) {
			t.Errorf("%s was created: %v", rel, err)
		}
	}

	if got, _ := os.ReadFile(filepath.Join(dir, "ro/inside")); string(got) != "x" {
		t.Errorf("ro/inside = %q", got)
	}
}

// TestExtractRefusesEscapes checks that an archive cannot write outside the
// root, by naming a parent directory or by planting a symlink first.
func TestExtractRefusesEscapes(t *testing.T) {
	cases := []struct {
		name    string
		entries []entry
		want    string
	}{
		{"dot-dot", []entry{
			{Name: "../evil", Body: "x"},
		}, "climbs out"},
		{"nested dot-dot", []entry{
			{Name: "a/../../evil", Body: "x"},
		}, "climbs out"},
		{"write through a symlink", []entry{
			{Name: "link", Type: tar.TypeSymlink, Link: "/tmp"},
			{Name: "link/evil", Body: "x"},
		}, "symlink"},
		{"hard link to a symlink", []entry{
			{Name: "s", Type: tar.TypeSymlink, Link: "/etc/passwd"},
			{Name: "h", Type: tar.TypeLink, Link: "s"},
		}, "not a regular file"},
		{"hard link out of the root", []entry{
			{Name: "h", Type: tar.TypeLink, Link: "../../etc/passwd"},
		}, "climbs out"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			parent := t.TempDir()
			dir := filepath.Join(parent, "root")
			if err := os.Mkdir(dir, 0o755); err != nil {
				t.Fatal(err)
			}

			err := ExtractRoot(bytes.NewReader(tarOf(t, tc.entries...)), dir)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err = %v, want it to contain %q", err, tc.want)
			}

			if _, err := os.Lstat(filepath.Join(parent, "evil")); !os.IsNotExist(err) {
				t.Errorf("a file escaped the root: %v", err)
			}
		})
	}
}

// TestExtractReplacesEarlierEntries checks that a later entry of the same
// name replaces the earlier one.
func TestExtractReplacesEarlierEntries(t *testing.T) {
	raw := tarOf(t,
		entry{Name: "f", Mode: 0o644, Body: "old"},
		entry{Name: "f", Mode: 0o600, Body: "new"},
		entry{Name: "l", Type: tar.TypeSymlink, Link: "a"},
		entry{Name: "l", Type: tar.TypeSymlink, Link: "b"},
	)

	dir := t.TempDir()
	if err := ExtractRoot(bytes.NewReader(raw), dir); err != nil {
		t.Fatal(err)
	}

	if got, _ := os.ReadFile(filepath.Join(dir, "f")); string(got) != "new" {
		t.Errorf("f = %q", got)
	}
	if got, _ := os.Readlink(filepath.Join(dir, "l")); got != "b" {
		t.Errorf("l -> %q", got)
	}
}

// TestRemoveTreeHandlesReadOnlyDirectories checks that a tree with a
// directory the owner cannot write is still removed, since an extracted guest
// root can contain one.
func TestRemoveTreeHandlesReadOnlyDirectories(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "root")
	if err := os.MkdirAll(filepath.Join(dir, "ro", "deep"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "ro", "deep", "f"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	for _, d := range []string{"ro/deep", "ro"} {
		if err := os.Chmod(filepath.Join(dir, d), 0o500); err != nil {
			t.Fatal(err)
		}
	}

	if err := RemoveTree(dir); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Errorf("tree remains: %v", err)
	}

	// Removing a tree that is already gone is not an error.
	if err := RemoveTree(dir); err != nil {
		t.Fatal(err)
	}
}
