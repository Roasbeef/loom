package setup

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	v1 "github.com/google/go-containerregistry/pkg/v1"

	"github.com/roasbeef/loom/vmm"
)

const testTag = "v9.9.9"

// releaseFixture is a published release: assets on an HTTP server, a guest
// image in a registry, and an Options that reaches both.
type releaseFixture struct {
	files map[string]string
	srv   *releaseServer
	run   *fakeRun
	opts  Options
}

// newFixture publishes a well-formed release. Each test breaks one thing.
func newFixture(t *testing.T) *releaseFixture {
	t.Helper()

	files := map[string]string{
		"go-microvm-runner-darwin-arm64":          "runner-bytes",
		"libkrunfw-landlock-darwin-arm64.5.dylib": "firmware-bytes",
	}
	files[sumsAsset] = sumsFor(files)
	srv := newReleaseServer(t, files)

	host := startRegistry(t)
	ref := host + "/loom-guest:" + testTag
	labels := map[string]string{
		labelRevision: "0123456789abcdef0123456789abcdef01234567",
		labelVersion:  testTag,
	}
	pushIndex(t, ref, map[string]v1.Image{
		"arm64": imageOf(t, "arm64", labels, tarOf(t, guestEntries("arm64")...)),
		"amd64": imageOf(t, "amd64", labels, tarOf(t, guestEntries("amd64")...)),
	})

	run := &fakeRun{}

	return &releaseFixture{
		files: files,
		srv:   srv,
		run:   run,
		opts: Options{
			Home:     filepath.Join(t.TempDir(), "home"),
			Tag:      testTag,
			BaseURL:  srv.URL,
			ImageRef: ref,
			LibDir:   fakeLibDir(t),
			GOOS:     "darwin",
			GOARCH:   "arm64",
			LoomVM:   "/opt/loom/bin/loom-vm",
			Run:      run.run,
		},
	}
}

// TestReleaseInstalls runs the whole download path against fakes and checks
// the manifest, the files it names, and the commands run on macOS.
func TestReleaseInstalls(t *testing.T) {
	f := newFixture(t)

	m, err := Release(context.Background(), f.opts)
	if err != nil {
		t.Fatal(err)
	}

	cache := filepath.Join(f.opts.Home, "cache", testTag)
	want := Manifest{
		Version:     1,
		Revision:    "0123456789abcdef0123456789abcdef01234567",
		LoomVM:      "/opt/loom/bin/loom-vm",
		Runner:      filepath.Join(cache, "go-microvm-runner"),
		LibDir:      f.opts.LibDir,
		FirmwareDir: filepath.Join(cache, "firmware"),
		GuestRoot:   filepath.Join(cache, "guest-root"),
	}
	if m != want {
		t.Fatalf("manifest = %+v\nwant       %+v", m, want)
	}

	// The manifest on disk decodes to the same value, with exactly the
	// documented keys.
	raw, err := os.ReadFile(ManifestPath(f.opts.Home))
	if err != nil {
		t.Fatal(err)
	}
	var keys map[string]any
	if err := json.Unmarshal(raw, &keys); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"version", "revision", "loom_vm", "runner", "lib_dir", "firmware_dir", "guest_root"} {
		if _, ok := keys[k]; !ok {
			t.Errorf("manifest lacks key %q: %s", k, raw)
		}
	}
	if len(keys) != 7 {
		t.Errorf("manifest has %d keys, want 7: %s", len(keys), raw)
	}

	if got, _ := os.ReadFile(m.Runner); string(got) != "runner-bytes" {
		t.Errorf("runner = %q", got)
	}
	fw, _ := os.ReadFile(filepath.Join(m.FirmwareDir, "libkrunfw.5.dylib"))
	if string(fw) != "firmware-bytes" {
		t.Errorf("firmware = %q", fw)
	}

	// The host is arm64, so the arm64 image was extracted, with the
	// archive's modes intact.
	init, err := os.ReadFile(filepath.Join(m.GuestRoot, "usr/local/sbin/loom-guest-init"))
	if err != nil || !strings.HasSuffix(string(init), "arm64") {
		t.Errorf("init = %q, %v", init, err)
	}
	info, err := os.Stat(filepath.Join(m.GuestRoot, "tmp"))
	if err != nil || info.Mode().Perm() != 0o777 || info.Mode()&os.ModeSticky == 0 {
		t.Errorf("/tmp = %v, %v", info, err)
	}

	// No staging directory or temporary manifest is left behind.
	for _, dir := range []string{f.opts.Home, filepath.Dir(cache)} {
		ents, _ := os.ReadDir(dir)
		for _, e := range ents {
			if strings.HasPrefix(e.Name(), ".") {
				t.Errorf("leftover %s in %s", e.Name(), dir)
			}
		}
	}

	// The runner is re-signed with the embedded entitlements and both
	// downloaded files lose the quarantine attribute.
	signs := f.run.named("codesign")
	if len(signs) != 1 {
		t.Fatalf("codesign calls = %d, want 1", len(signs))
	}
	args := strings.Join(signs[0].args, " ")
	if !strings.Contains(args, "-s - --force") || !strings.HasSuffix(args, "go-microvm-runner") {
		t.Errorf("codesign args = %s", args)
	}
	if signs[0].entitlements != string(vmm.RunnerEntitlements) {
		t.Errorf("codesign used entitlements %q", signs[0].entitlements)
	}
	if n := len(f.run.named("xattr")); n != 2 {
		t.Errorf("xattr calls = %d, want 2", n)
	}

	// Doctor's record matches the installed bytes.
	sums, err := readInstalledSums(cache)
	if err != nil {
		t.Fatal(err)
	}
	if sums["go-microvm-runner"] != sha("runner-bytes") || sums["libkrunfw.5.dylib"] != sha("firmware-bytes") {
		t.Errorf("installed sums = %v", sums)
	}
}

// TestReleasePicksTheHostArchitecture checks that an amd64 host asking for
// the same release gets the amd64 variant of the manifest list.
func TestReleasePicksTheHostArchitecture(t *testing.T) {
	f := newFixture(t)

	// The platform table has no amd64 download, so the choice is observed
	// at the image layer directly.
	img, _, err := pullGuest(context.Background(), f.opts.ImageRef, testTag, "amd64")
	if err != nil {
		t.Fatal(err)
	}

	dir := t.TempDir()
	if err := extractGuest(img, dir); err != nil {
		t.Fatal(err)
	}
	init, _ := os.ReadFile(filepath.Join(dir, "usr/local/sbin/loom-guest-init"))
	if !strings.HasSuffix(string(init), "amd64") {
		t.Errorf("init = %q", init)
	}
}

// TestReleaseRefusals checks every way the download can be wrong, and that
// each leaves no manifest and no cache directory behind.
func TestReleaseRefusals(t *testing.T) {
	cases := []struct {
		name   string
		break_ func(*releaseFixture)
		want   string
	}{
		{"digest mismatch", func(f *releaseFixture) {
			f.srv.files["go-microvm-runner-darwin-arm64"] = "tampered"
		}, "sha256 is"},
		{"firmware digest mismatch", func(f *releaseFixture) {
			f.srv.files["libkrunfw-landlock-darwin-arm64.5.dylib"] = "tampered"
		}, "sha256 is"},
		{"missing asset", func(f *releaseFixture) {
			delete(f.srv.files, "go-microvm-runner-darwin-arm64")
		}, "has no asset go-microvm-runner-darwin-arm64"},
		{"missing sums file", func(f *releaseFixture) {
			delete(f.srv.files, sumsAsset)
		}, "has no asset " + sumsAsset},
		{"missing sums entry", func(f *releaseFixture) {
			f.srv.files[sumsAsset] = sumsFor(f.files, "go-microvm-runner-darwin-arm64")
		}, "has no entry for go-microvm-runner-darwin-arm64"},
		{"malformed sums", func(f *releaseFixture) {
			f.srv.files[sumsAsset] = "not a checksum line\n"
		}, "malformed checksum line"},
		{"tag with a slash", func(f *releaseFixture) {
			f.opts.Tag = "../x"
		}, "not a plain tag"},
		{"bad repo", func(f *releaseFixture) {
			f.opts.Repo = "no-slash"
		}, "not OWNER/NAME"},
		{"linux has no download", func(f *releaseFixture) {
			f.opts.GOOS = "linux"
		}, "--from-build"},
		{"no libkrun", func(f *releaseFixture) {
			f.opts.LibDir = t.TempDir()
		}, "no libkrun"},
		{"wrong image version", func(f *releaseFixture) {
			pushOther(t, f)
		}, "is version"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			tc.break_(f)

			_, err := Release(context.Background(), f.opts)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err = %v, want it to contain %q", err, tc.want)
			}

			if _, err := os.Stat(ManifestPath(f.opts.Home)); !os.IsNotExist(err) {
				t.Errorf("a manifest was written: %v", err)
			}
			cache := filepath.Join(f.opts.Home, "cache")
			if ents, _ := os.ReadDir(cache); len(ents) != 0 {
				t.Errorf("cache is not empty after a refusal: %v", ents)
			}
		})
	}
}

// pushOther publishes an image whose version label names a different
// release, under the tag the fixture asks for.
func pushOther(t *testing.T, f *releaseFixture) {
	t.Helper()

	labels := map[string]string{labelRevision: "abc", labelVersion: "other"}
	pushIndex(t, f.opts.ImageRef, map[string]v1.Image{
		"arm64": imageOf(t, "arm64", labels, tarOf(t, guestEntries("x")...)),
	})
}

// TestReleaseRefusesAnUnlabelledImage checks that an image the release
// workflow did not build is refused for lacking the revision label.
func TestReleaseRefusesAnUnlabelledImage(t *testing.T) {
	f := newFixture(t)

	pushIndex(t, f.opts.ImageRef, map[string]v1.Image{
		"arm64": imageOf(t, "arm64", nil, tarOf(t, guestEntries("x")...)),
	})

	_, err := Release(context.Background(), f.opts)
	if err == nil || !strings.Contains(err.Error(), "no "+labelRevision+" label") {
		t.Fatalf("err = %v", err)
	}
}

// TestReleaseKeepsThePreviousManifestOnFailure checks that a failed install
// leaves an earlier install intact, which is what makes the manifest swap the
// last step.
func TestReleaseKeepsThePreviousManifestOnFailure(t *testing.T) {
	f := newFixture(t)

	first, err := Release(context.Background(), f.opts)
	if err != nil {
		t.Fatal(err)
	}

	f.srv.files["go-microvm-runner-darwin-arm64"] = "tampered"
	if _, err := Release(context.Background(), f.opts); err == nil {
		t.Fatal("tampered download was accepted")
	}

	got, err := ReadManifest(f.opts.Home)
	if err != nil || got != first {
		t.Fatalf("manifest = %+v, %v; want %+v", got, err, first)
	}
	if b, _ := os.ReadFile(first.Runner); string(b) != "runner-bytes" {
		t.Errorf("installed runner changed: %q", b)
	}
}

// TestParseSums covers the checksum file formats `sha256sum` writes.
func TestParseSums(t *testing.T) {
	digest := sha("x")

	sums, err := parseSums(strings.NewReader(digest + "  a\n\n" + digest + " *b\n"))
	if err != nil || sums["a"] != digest || sums["b"] != digest {
		t.Fatalf("sums = %v, %v", sums, err)
	}

	for _, bad := range []string{
		"short  a\n",
		digest + "\n",
		digest + "  dir/a\n",
		strings.Repeat("z", 64) + "  a\n",
		digest + "  a\n" + sha("y") + "  a\n",
	} {
		if _, err := parseSums(strings.NewReader(bad)); err == nil {
			t.Errorf("accepted %q", bad)
		}
	}
}
