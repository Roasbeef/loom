package setup

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"

	"github.com/roasbeef/loom/vmm"
)

const (
	// DefaultRepo is the GitHub repository whose releases carry the
	// artifacts.
	DefaultRepo = "roasbeef/loom"

	// DefaultBaseURL serves release assets.
	DefaultBaseURL = "https://github.com"

	// sumsAsset names the checksum file of the microVM assets. It is not
	// SHA256SUMS: the server release already publishes an asset by that
	// name for its own archives, and a release cannot hold two.
	sumsAsset = "vmm-SHA256SUMS"

	// installedSums records the digests of the files as installed, which
	// differ from the downloaded ones once the runner is re-signed. Doctor
	// checks the files against it.
	installedSums = "installed.sums"

	// maxSumsBytes bounds the checksum file, which holds a few lines.
	maxSumsBytes = 1 << 20

	// maxAssetBytes bounds one downloaded asset. The largest, the
	// firmware, is 25 MB.
	maxAssetBytes = 512 << 20
)

// tagPattern and repoPattern admit what a release tag and an owner/name pair
// can be. Both end up in a URL and in a path under the cache, so neither may
// carry a separator, a dot-dot or whitespace.
var (
	tagPattern  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)
	repoPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$`)
)

// Options configures Release. Only Tag is required; the zero value of every
// other field means the production default.
type Options struct {
	// Home is the loom-vm home directory. Default: DefaultHome.
	Home string

	// Tag is the release to install, such as "v0.3.0".
	Tag string

	// Repo is the GitHub owner/name that published the release. Default:
	// DefaultRepo.
	Repo string

	// BaseURL serves release assets as
	// BASE/OWNER/NAME/releases/download/TAG/ASSET. Default: DefaultBaseURL.
	BaseURL string

	// Revision, when set, is the commit the guest image must have been built
	// from: the image's revision label must equal it, or share a prefix of at
	// least seven characters with it. A mismatch refuses the install before
	// anything is downloaded or written. Default: any revision.
	Revision string

	// ImageRef is the guest image to pull. Default: GuestImageRef for the
	// repository's owner and Tag.
	ImageRef string

	// LibDir is the directory holding libkrun. Default: found by
	// FindLibDir.
	LibDir string

	// GOOS and GOARCH name the host. Default: the running platform.
	GOOS, GOARCH string

	// LoomVM is the path recorded as loom_vm. Default: the running binary.
	LoomVM string

	// HTTP fetches assets. Default: http.DefaultClient.
	HTTP *http.Client

	// Run executes codesign, xattr and brew. Default: ExecCommander.
	Run Commander

	// Log receives one line per step. Default: discarded.
	Log io.Writer
}

// withDefaults fills the zero fields and rejects a malformed tag or repo.
func (o Options) withDefaults() (Options, error) {
	var err error
	if o.Home == "" {
		if o.Home, err = DefaultHome(); err != nil {
			return o, err
		}
	}

	if o.Repo == "" {
		o.Repo = DefaultRepo
	}
	if o.BaseURL == "" {
		o.BaseURL = DefaultBaseURL
	}
	if o.GOOS == "" {
		o.GOOS = runtime.GOOS
	}
	if o.GOARCH == "" {
		o.GOARCH = runtime.GOARCH
	}
	if o.HTTP == nil {
		o.HTTP = http.DefaultClient
	}
	if o.Run == nil {
		o.Run = ExecCommander
	}
	if o.Log == nil {
		o.Log = io.Discard
	}

	if !tagPattern.MatchString(o.Tag) {
		return o, fmt.Errorf("release tag %q is not a plain tag name", o.Tag)
	}
	if !repoPattern.MatchString(o.Repo) {
		return o, fmt.Errorf("repository %q is not OWNER/NAME", o.Repo)
	}

	if o.ImageRef == "" {
		o.ImageRef = GuestImageRef(strings.SplitN(o.Repo, "/", 2)[0], o.Tag)
	}

	return o, nil
}

// assets names the files a release publishes for one platform.
type assets struct {
	runner   string
	firmware string
}

// releaseAssets returns the asset names for a platform, or an error when no
// prebuilt download exists for it. Only macOS on Apple Silicon has one: that
// is where the runner can be built on a hosted runner against Homebrew's
// libkrun, and where the Landlock kernel has to be linked into a dylib. A
// Linux host builds the same artifacts itself and installs them with
// FromBuild.
func releaseAssets(goos, goarch string) (assets, error) {
	if goos != "darwin" || goarch != "arm64" {
		return assets{}, fmt.Errorf("releases publish prebuilt artifacts only for darwin/arm64, "+
			"not %s/%s; build them (make vmm vmm-runner vmm-guest-root) and run "+
			"`loom-vm setup --from-build packages/vmm/build`", goos, goarch)
	}

	return assets{
		runner:   fmt.Sprintf("go-microvm-runner-%s-%s", goos, goarch),
		firmware: fmt.Sprintf("libkrunfw-landlock-%s-%s.5.dylib", goos, goarch),
	}, nil
}

// Release installs a published release into the loom-vm home and writes the
// manifest, and returns what it wrote.
//
// The steps are ordered so that nothing is trusted before it is checked and
// nothing partial is ever visible. libkrun is located first, because its
// absence is the one failure the user has to fix by hand and it should not
// follow a 25 MB download. The runner and firmware are then downloaded and
// each digest compared with the release's checksum file; a mismatch, a
// missing entry or a missing asset ends the install. On macOS the runner is
// ad-hoc re-signed with the Hypervisor.framework entitlement and the
// quarantine attribute is removed from both files. The guest image is pulled
// for the host architecture and its labels checked first of all, after only
// libkrun is located, so a wrong version or revision downloads nothing.
// Everything is assembled
// under a staging directory next to the final one and renamed into
// cache/TAG only when complete, and the manifest is replaced last, so an
// interrupted install leaves the previous manifest pointing at the previous,
// intact files.
//
// ## Examples
//
//	m, err := setup.Release(ctx, setup.Options{Tag: "v0.3.0"})
func Release(ctx context.Context, opts Options) (Manifest, error) {
	o, err := opts.withDefaults()
	if err != nil {
		return Manifest{}, err
	}

	want, err := releaseAssets(o.GOOS, o.GOARCH)
	if err != nil {
		return Manifest{}, err
	}

	libDir, err := FindLibDir(ctx, o.LibDir, o.GOOS, o.Run)
	if err != nil {
		return Manifest{}, err
	}

	loomVM := o.LoomVM
	if loomVM == "" {
		if loomVM, err = selfPath(); err != nil {
			return Manifest{}, err
		}
	}

	// The image's labels are read before anything is downloaded or written, so
	// an image of the wrong version or revision costs a manifest fetch and
	// leaves the cache and the manifest as they were. Its layers are fetched
	// lazily, at extraction.
	img, revision, err := pullGuest(ctx, o.ImageRef, o.Tag, o.GOARCH)
	if err != nil {
		return Manifest{}, err
	}
	if o.Revision != "" && !sameRevision(o.Revision, revision) {
		return Manifest{}, fmt.Errorf("%s was built from revision %s, not the requested %s",
			o.ImageRef, revision, o.Revision)
	}

	cache := filepath.Join(o.Home, "cache")
	final := filepath.Join(cache, o.Tag)
	staging := filepath.Join(cache, ".staging-"+o.Tag)

	if err := RemoveTree(staging); err != nil {
		return Manifest{}, err
	}
	if err := os.MkdirAll(filepath.Join(staging, "firmware"), 0o755); err != nil {
		return Manifest{}, err
	}

	// A failed install leaves nothing behind for the next run to trip on.
	installed := false
	defer func() {
		if !installed {
			RemoveTree(staging)
		}
	}()

	sums, err := o.fetchSums(ctx)
	if err != nil {
		return Manifest{}, err
	}

	runner := filepath.Join(staging, "go-microvm-runner")
	firmware := filepath.Join(staging, "firmware", firmwareName(o.GOOS))
	for _, a := range []struct{ asset, dst string }{
		{want.runner, runner},
		{want.firmware, firmware},
	} {
		if err := o.download(ctx, a.asset, a.dst, sums); err != nil {
			return Manifest{}, err
		}
	}

	if err := o.sign(ctx, runner, firmware); err != nil {
		return Manifest{}, err
	}

	if err := writeInstalledSums(staging, runner, firmware); err != nil {
		return Manifest{}, err
	}

	fmt.Fprintf(o.Log, "extracting the guest root (revision %s)\n", revision)
	if err := extractGuest(img, filepath.Join(staging, "guest-root")); err != nil {
		return Manifest{}, fmt.Errorf("extract %s: %w", o.ImageRef, err)
	}

	if err := RemoveTree(final); err != nil {
		return Manifest{}, err
	}
	if err := os.Rename(staging, final); err != nil {
		return Manifest{}, err
	}
	installed = true

	m := Manifest{
		Version:     ManifestVersion,
		Revision:    revision,
		LoomVM:      loomVM,
		Runner:      filepath.Join(final, "go-microvm-runner"),
		LibDir:      libDir,
		FirmwareDir: filepath.Join(final, "firmware"),
		GuestRoot:   filepath.Join(final, "guest-root"),
	}

	if err := WriteManifest(o.Home, m); err != nil {
		return Manifest{}, err
	}

	fmt.Fprintf(o.Log, "installed %s; manifest %s\n", o.Tag, ManifestPath(o.Home))

	return m, nil
}

// sameRevision reports whether two commit names are the same commit. Either may
// be abbreviated, down to seven characters, as Loom's own revision check allows.
func sameRevision(want, got string) bool {
	const shortest = 7

	if len(want) < shortest || len(got) < shortest {
		return false
	}

	return strings.HasPrefix(got, want) || strings.HasPrefix(want, got)
}

// url is where one asset of the release is served.
func (o Options) url(asset string) string {
	return fmt.Sprintf("%s/%s/releases/download/%s/%s",
		strings.TrimRight(o.BaseURL, "/"), o.Repo, o.Tag, asset)
}

// get opens one asset's body, failing on any status but 200 and naming the
// asset, so a missing one reads as that and not as an HTTP code.
func (o Options) get(ctx context.Context, asset string) (io.ReadCloser, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, o.url(asset), nil)
	if err != nil {
		return nil, err
	}

	resp, err := o.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetch %s: %w", asset, err)
	}

	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()

		return nil, fmt.Errorf("release %s of %s has no asset %s (HTTP %d from %s)",
			o.Tag, o.Repo, asset, resp.StatusCode, o.url(asset))
	}

	return resp.Body, nil
}

// fetchSums downloads and parses the checksum file.
func (o Options) fetchSums(ctx context.Context) (map[string]string, error) {
	body, err := o.get(ctx, sumsAsset)
	if err != nil {
		return nil, err
	}
	defer body.Close()

	return parseSums(io.LimitReader(body, maxSumsBytes))
}

// parseSums reads `sha256sum` output: a lowercase hex digest, whitespace, an
// optional `*` marking binary mode, and a file name.
func parseSums(r io.Reader) (map[string]string, error) {
	sums := make(map[string]string)

	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}

		digest, file, ok := strings.Cut(line, " ")
		file = strings.TrimPrefix(strings.TrimSpace(file), "*")
		if !ok || len(digest) != sha256.Size*2 || file == "" || strings.Contains(file, "/") {
			return nil, fmt.Errorf("malformed checksum line %q", line)
		}

		if _, err := hex.DecodeString(digest); err != nil {
			return nil, fmt.Errorf("malformed checksum line %q", line)
		}

		if prev, dup := sums[file]; dup && prev != digest {
			return nil, fmt.Errorf("%s lists two digests for %s", sumsAsset, file)
		}
		sums[file] = digest
	}

	return sums, sc.Err()
}

// download fetches asset to dst and compares its SHA-256 with sums. The file
// is removed on any failure, so a corrupt download is never left where a
// later step could use it.
func (o Options) download(ctx context.Context, asset, dst string, sums map[string]string) error {
	want, ok := sums[asset]
	if !ok {
		return fmt.Errorf("%s has no entry for %s", sumsAsset, asset)
	}

	body, err := o.get(ctx, asset)
	if err != nil {
		return err
	}
	defer body.Close()

	fmt.Fprintf(o.Log, "downloading %s\n", asset)

	f, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}

	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(f, h), io.LimitReader(body, maxAssetBytes+1))
	err = errors.Join(err, f.Close())

	switch got := hex.EncodeToString(h.Sum(nil)); {
	case err != nil:
		os.Remove(dst)

		return fmt.Errorf("download %s: %w", asset, err)

	case n > maxAssetBytes:
		os.Remove(dst)

		return fmt.Errorf("%s is larger than %d bytes", asset, maxAssetBytes)

	case got != want:
		os.Remove(dst)

		return fmt.Errorf("%s: sha256 is %s, %s lists %s", asset, got, sumsAsset, want)
	}

	return nil
}

// sign makes the downloaded files usable by the macOS loader: it removes the
// quarantine attribute from both and re-signs the runner ad hoc with the
// Hypervisor.framework entitlement. There is no Developer ID, so the
// signature vouches for nothing; the entitlement is what lets the runner start
// a guest, and the checksum comparison above is the integrity check. Other
// platforms need neither.
func (o Options) sign(ctx context.Context, runner, firmware string) error {
	if o.GOOS != "darwin" {
		return nil
	}

	for _, f := range []string{runner, firmware} {
		if err := o.unquarantine(ctx, f); err != nil {
			return err
		}
	}

	plist, err := os.CreateTemp(filepath.Dir(runner), ".entitlements-*.plist")
	if err != nil {
		return err
	}
	defer os.Remove(plist.Name())

	if err := write(plist, vmm.RunnerEntitlements); err != nil {
		return err
	}

	fmt.Fprintf(o.Log, "signing %s ad hoc with the hypervisor entitlement\n", filepath.Base(runner))

	out, err := o.Run(ctx, "codesign", "--entitlements", plist.Name(), "-s", "-", "--force", runner)
	if err != nil {
		return fmt.Errorf("codesign %s: %w: %s", runner, err, strings.TrimSpace(string(out)))
	}

	return nil
}

// unquarantine removes com.apple.quarantine from path. A file that never had
// it is the normal case for a download made without a browser, and xattr
// reports that as an error, which is not one.
func (o Options) unquarantine(ctx context.Context, path string) error {
	out, err := o.Run(ctx, "xattr", "-d", "com.apple.quarantine", path)
	if err != nil && !strings.Contains(string(out), "No such xattr") {
		return fmt.Errorf("xattr %s: %w: %s", path, err, strings.TrimSpace(string(out)))
	}

	return nil
}

// writeInstalledSums records the digests of the installed runner and
// firmware in `sha256sum` format, keyed by file name. The names are distinct,
// so Doctor finds each file's digest from the manifest's paths alone.
func writeInstalledSums(dir string, files ...string) error {
	var b strings.Builder

	for _, f := range files {
		sum, err := fileSum(f)
		if err != nil {
			return err
		}

		fmt.Fprintf(&b, "%s  %s\n", sum, filepath.Base(f))
	}

	return os.WriteFile(filepath.Join(dir, installedSums), []byte(b.String()), 0o644)
}

// fileSum is the hex SHA-256 of a file.
func fileSum(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()

	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}

	return hex.EncodeToString(h.Sum(nil)), nil
}

// readInstalledSums loads the digests recorded at install time, keyed by
// file name.
func readInstalledSums(dir string) (map[string]string, error) {
	f, err := os.Open(filepath.Join(dir, installedSums))
	if err != nil {
		return nil, err
	}
	defer f.Close()

	return parseSums(f)
}
