package setup

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/go-containerregistry/pkg/name"
	"github.com/google/go-containerregistry/pkg/registry"
	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/empty"
	"github.com/google/go-containerregistry/pkg/v1/mutate"
	"github.com/google/go-containerregistry/pkg/v1/remote"
	"github.com/google/go-containerregistry/pkg/v1/tarball"
)

// entry is one member of a test tar archive. A zero Type is a regular file.
type entry struct {
	Name string
	Type byte
	Mode int64
	Body string
	Link string
}

// tarOf builds an uncompressed tar archive from entries.
func tarOf(t *testing.T, entries ...entry) []byte {
	t.Helper()

	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)

	for _, e := range entries {
		typ := e.Type
		if typ == 0 {
			typ = tar.TypeReg
		}

		hdr := &tar.Header{
			Name:     e.Name,
			Typeflag: typ,
			Mode:     e.Mode,
			Linkname: e.Link,
			ModTime:  time.Unix(1_700_000_000, 0),
		}
		if typ == tar.TypeReg {
			hdr.Size = int64(len(e.Body))
		}

		if err := tw.WriteHeader(hdr); err != nil {
			t.Fatal(err)
		}
		if typ == tar.TypeReg {
			if _, err := tw.Write([]byte(e.Body)); err != nil {
				t.Fatal(err)
			}
		}
	}

	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}

	return buf.Bytes()
}

// guestEntries is a small guest root: the init the doctor looks for, a /tmp
// with the sticky bit, a symlink and a setuid file.
func guestEntries(marker string) []entry {
	return []entry{
		{Name: "usr/", Type: tar.TypeDir, Mode: 0o755},
		{Name: "usr/local/", Type: tar.TypeDir, Mode: 0o755},
		{Name: "usr/local/sbin/", Type: tar.TypeDir, Mode: 0o755},
		{Name: "usr/local/sbin/loom-guest-init", Mode: 0o755, Body: "#!/bin/sh\n" + marker},
		{Name: "tmp/", Type: tar.TypeDir, Mode: 0o1777},
		{Name: "bin", Type: tar.TypeSymlink, Link: "usr/bin"},
	}
}

// layerOf wraps a tar archive as an image layer.
func layerOf(t *testing.T, raw []byte) v1.Layer {
	t.Helper()

	l, err := tarball.LayerFromOpener(func() (io.ReadCloser, error) {
		return io.NopCloser(bytes.NewReader(raw)), nil
	})
	if err != nil {
		t.Fatal(err)
	}

	return l
}

// imageOf builds a one-layer image for arch with the given labels.
func imageOf(t *testing.T, arch string, labels map[string]string, raw []byte) v1.Image {
	t.Helper()

	img, err := mutate.AppendLayers(empty.Image, layerOf(t, raw))
	if err != nil {
		t.Fatal(err)
	}

	cfg, err := img.ConfigFile()
	if err != nil {
		t.Fatal(err)
	}
	cfg = cfg.DeepCopy()
	cfg.OS, cfg.Architecture = "linux", arch
	cfg.Config.Labels = labels

	img, err = mutate.ConfigFile(img, cfg)
	if err != nil {
		t.Fatal(err)
	}

	return img
}

// startRegistry serves an in-memory OCI registry and returns its host:port.
// go-containerregistry speaks plain HTTP to a loopback registry.
func startRegistry(t *testing.T) string {
	t.Helper()

	srv := httptest.NewServer(registry.New(registry.Logger(log.New(io.Discard, "", 0))))
	t.Cleanup(srv.Close)

	return strings.TrimPrefix(srv.URL, "http://")
}

// pushIndex publishes a manifest list with one image per architecture under
// ref, the way the release workflow publishes the guest image.
func pushIndex(t *testing.T, ref string, images map[string]v1.Image) {
	t.Helper()

	var idx v1.ImageIndex = empty.Index
	for arch, img := range images {
		idx = mutate.AppendManifests(idx, mutate.IndexAddendum{
			Add:        img,
			Descriptor: v1.Descriptor{Platform: &v1.Platform{OS: "linux", Architecture: arch}},
		})
	}

	parsed, err := name.ParseReference(ref)
	if err != nil {
		t.Fatal(err)
	}
	if err := remote.WriteIndex(parsed, idx); err != nil {
		t.Fatal(err)
	}
}

// sha is the hex SHA-256 of s.
func sha(s string) string {
	sum := sha256.Sum256([]byte(s))

	return hex.EncodeToString(sum[:])
}

// releaseServer serves release assets at the path layout GitHub uses.
type releaseServer struct {
	*httptest.Server

	mu       sync.Mutex
	files    map[string]string
	requests int
}

// count is the number of asset requests served so far.
func (rs *releaseServer) count() int {
	rs.mu.Lock()
	defer rs.mu.Unlock()

	return rs.requests
}

// newReleaseServer serves the asset names and bodies in files, under
// /OWNER/NAME/releases/download/TAG/.
func newReleaseServer(t *testing.T, files map[string]string) *releaseServer {
	t.Helper()

	rs := &releaseServer{files: files}
	rs.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rs.mu.Lock()
		defer rs.mu.Unlock()

		rs.requests++

		asset := r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:]
		body, ok := rs.files[asset]
		if !ok || !strings.Contains(r.URL.Path, "/releases/download/") {
			http.NotFound(w, r)

			return
		}

		io.WriteString(w, body)
	}))
	t.Cleanup(rs.Close)

	return rs
}

// sumsFor renders a checksum file covering every file except those named in
// skip.
func sumsFor(files map[string]string, skip ...string) string {
	var b strings.Builder

	for name, body := range files {
		if name == sumsAsset || contains(skip, name) {
			continue
		}
		fmt.Fprintf(&b, "%s  %s\n", sha(body), name)
	}

	return b.String()
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}

	return false
}

// call is one recorded external command.
type call struct {
	name string
	args []string

	// entitlements is the content of the file named by --entitlements at
	// the time of the call; the file is removed afterwards.
	entitlements string
}

// fakeRun records commands instead of running them. xattr behaves as it does
// on a file that was never quarantined: it fails with "No such xattr".
type fakeRun struct {
	mu    sync.Mutex
	calls []call
	out   map[string]string
}

func (f *fakeRun) run(_ context.Context, name string, args ...string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	c := call{name: name, args: args}
	for i, a := range args {
		if a == "--entitlements" && i+1 < len(args) {
			if raw, err := os.ReadFile(args[i+1]); err == nil {
				c.entitlements = string(raw)
			}
		}
	}
	f.calls = append(f.calls, c)

	if out, ok := f.out[name]; ok {
		return []byte(out), nil
	}

	if name == "xattr" {
		return []byte("xattr: No such xattr: com.apple.quarantine"), errors.New("exit status 1")
	}

	return nil, nil
}

// named returns the recorded calls of one program.
func (f *fakeRun) named(name string) []call {
	var out []call
	for _, c := range f.calls {
		if c.name == name {
			out = append(out, c)
		}
	}

	return out
}

// fakeLibDir makes a directory that looks like a libkrun install.
func fakeLibDir(t *testing.T) string {
	t.Helper()

	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "libkrun.1.dylib"), []byte("lib"), 0o644); err != nil {
		t.Fatal(err)
	}

	return dir
}
