// Package setup installs the artifacts a microVM guest boots from and records
// where they are.
//
// A guest needs four things on the host: the loom-vm launcher, the
// go-microvm runner, a libkrun and libkrunfw to load, and a guest root
// filesystem. Building them takes minutes (the guest root 11, the Landlock
// kernel 7), so a release publishes them and this package fetches them. A
// developer who has already built them points setup at the build tree
// instead. Either way the result is the same: a Manifest under the loom-vm
// home directory, which names every path, so a consumer reads one file and
// never searches.
//
// Two commands sit on top of the package. `loom-vm setup` is [Release] or
// [FromBuild]. `loom-vm doctor` is [Doctor], which reads the manifest back
// and checks that what it names still works.
package setup

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// ManifestVersion is the schema version a manifest carries. A reader refuses
// any other number rather than guessing at fields.
const ManifestVersion = 1

// manifestName is the file under the home directory that holds the manifest.
const manifestName = "manifest.json"

// Manifest names the installed artifacts. Its JSON form is a contract: a
// separate program reads it to launch guests, so the field names and their
// meanings do not change without a new ManifestVersion.
type Manifest struct {
	// Version is ManifestVersion.
	Version int `json:"version"`

	// Revision is the loom commit the guest root was built from, or "dev"
	// for a tree installed with FromBuild and no revision.
	Revision string `json:"revision"`

	// LoomVM is the absolute path of the loom-vm binary that ran setup.
	LoomVM string `json:"loom_vm"`

	// Runner is the absolute path of the go-microvm runner.
	Runner string `json:"runner"`

	// LibDir is the absolute directory holding libkrun.
	LibDir string `json:"lib_dir"`

	// FirmwareDir is the absolute directory holding the Landlock
	// libkrunfw, or "" when the guest boots on the stock one.
	FirmwareDir string `json:"firmware_dir"`

	// GuestRoot is the absolute directory of the guest root filesystem.
	// It is a template: a boot uses a `cp -cRp` clone of it, never the
	// directory itself.
	GuestRoot string `json:"guest_root"`
}

// Validate reports why m is not a usable manifest, or nil. It checks shape
// only; Doctor checks that the paths exist.
func (m Manifest) Validate() error {
	if m.Version != ManifestVersion {
		return fmt.Errorf("manifest version %d, want %d", m.Version, ManifestVersion)
	}

	if m.Revision == "" {
		return errors.New("manifest has no revision")
	}

	required := []struct{ name, path string }{
		{"loom_vm", m.LoomVM},
		{"runner", m.Runner},
		{"lib_dir", m.LibDir},
		{"guest_root", m.GuestRoot},
	}
	for _, r := range required {
		if !filepath.IsAbs(r.path) {
			return fmt.Errorf("manifest %s %q is not an absolute path", r.name, r.path)
		}
	}

	if m.FirmwareDir != "" && !filepath.IsAbs(m.FirmwareDir) {
		return fmt.Errorf("manifest firmware_dir %q is not an absolute path", m.FirmwareDir)
	}

	return nil
}

// DefaultHome is the loom-vm home directory: $LOOM_VM_HOME, else
// ~/.loom/vm. The result is absolute.
//
// ## Examples
//
//	home, err := setup.DefaultHome()
func DefaultHome() (string, error) {
	if h := os.Getenv("LOOM_VM_HOME"); h != "" {
		return filepath.Abs(h)
	}

	user, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("no home directory (set LOOM_VM_HOME): %w", err)
	}

	return filepath.Join(user, ".loom", "vm"), nil
}

// ManifestPath is where the manifest lives under home.
func ManifestPath(home string) string {
	return filepath.Join(home, manifestName)
}

// WriteManifest validates m and writes it under home, replacing any earlier
// manifest. The write is atomic: the bytes go to a temporary file in the same
// directory, which is synced and renamed over the manifest, so a reader sees
// the old manifest or the new one and never a partial file, and a failed
// write leaves the old one in place.
//
// ## Examples
//
//	err := setup.WriteManifest(home, m)
func WriteManifest(home string, m Manifest) error {
	if err := m.Validate(); err != nil {
		return err
	}

	raw, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	raw = append(raw, '\n')

	if err := os.MkdirAll(home, 0o755); err != nil {
		return err
	}

	tmp, err := os.CreateTemp(home, ".manifest-*.tmp")
	if err != nil {
		return err
	}

	// CreateTemp makes the file private, and a manifest holds no secret
	// that another local program must not read.
	err = errors.Join(
		write(tmp, raw),
		os.Chmod(tmp.Name(), 0o644),
	)
	if err == nil {
		err = os.Rename(tmp.Name(), ManifestPath(home))
	}

	if err != nil {
		os.Remove(tmp.Name())
	}

	return err
}

// write fills f, syncs it and closes it.
func write(f *os.File, raw []byte) error {
	_, err := f.Write(raw)
	if err == nil {
		err = f.Sync()
	}

	return errors.Join(err, f.Close())
}

// ReadManifest loads and validates the manifest under home.
//
// ## Examples
//
//	m, err := setup.ReadManifest(home)
func ReadManifest(home string) (Manifest, error) {
	raw, err := os.ReadFile(ManifestPath(home))
	if err != nil {
		return Manifest{}, err
	}

	var m Manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		return Manifest{}, fmt.Errorf("%s: %w", ManifestPath(home), err)
	}

	if err := m.Validate(); err != nil {
		return Manifest{}, fmt.Errorf("%s: %w", ManifestPath(home), err)
	}

	return m, nil
}
