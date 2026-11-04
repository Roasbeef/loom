package setup

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
)

// DevRevision is the revision a tree installed by FromBuild records when the
// caller names none. It is not a commit, and a consumer that compares
// revisions must treat it as "whatever this checkout built".
const DevRevision = "dev"

// BuildOptions configures FromBuild.
type BuildOptions struct {
	// Home is the loom-vm home directory. Default: DefaultHome.
	Home string

	// Dir is the build tree: packages/vmm/build, holding
	// go-microvm-runner, guest-root and optionally firmware.
	Dir string

	// Revision is recorded in the manifest. Default: DevRevision.
	Revision string

	// LibDir is the directory holding libkrun. Default: found by
	// FindLibDir.
	LibDir string

	// GOOS names the host. Default: the running platform.
	GOOS string

	// LoomVM is the path recorded as loom_vm. Default: the running binary.
	LoomVM string

	// Run executes brew. Default: ExecCommander.
	Run Commander

	// Log receives one line per step. Default: discarded.
	Log io.Writer
}

// FromBuild writes a manifest that points at the artifacts of a build tree,
// without copying or modifying any of them, and returns it. It is the
// developer path: the tree is already built and signed by the make targets, so
// nothing is downloaded, verified or re-signed, and the guest root stays
// where `make vmm-guest-root` put it.
//
// The runner and the guest root are required. A missing runner or root is
// reported with the make target that produces it. A missing firmware
// directory is not an error: it leaves firmware_dir empty and the guest boots
// on the stock libkrunfw, which lacks Landlock, and the executor test says so
// itself.
//
// ## Examples
//
//	m, err := setup.FromBuild(ctx, setup.BuildOptions{Dir: "packages/vmm/build"})
func FromBuild(ctx context.Context, opts BuildOptions) (Manifest, error) {
	o := opts

	var err error
	if o.Home == "" {
		if o.Home, err = DefaultHome(); err != nil {
			return Manifest{}, err
		}
	}
	if o.GOOS == "" {
		o.GOOS = runtime.GOOS
	}
	if o.Run == nil {
		o.Run = ExecCommander
	}
	if o.Log == nil {
		o.Log = io.Discard
	}
	if o.Revision == "" {
		o.Revision = DevRevision
	}

	dir, err := filepath.Abs(o.Dir)
	if err != nil {
		return Manifest{}, err
	}

	runner := filepath.Join(dir, "go-microvm-runner")
	if err := requireFile(runner, "make vmm-runner"); err != nil {
		return Manifest{}, err
	}

	root := filepath.Join(dir, "guest-root")
	if err := requireDir(root, "make vmm-guest-root"); err != nil {
		return Manifest{}, err
	}

	firmware := filepath.Join(dir, "firmware")
	if _, err := os.Stat(filepath.Join(firmware, firmwareName(o.GOOS))); err != nil {
		fmt.Fprintf(o.Log, "no Landlock firmware in %s (make vmm-firmware); "+
			"the guest will boot on the stock libkrunfw\n", firmware)
		firmware = ""
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

	m := Manifest{
		Version:     ManifestVersion,
		Revision:    o.Revision,
		LoomVM:      loomVM,
		Runner:      runner,
		LibDir:      libDir,
		FirmwareDir: firmware,
		GuestRoot:   root,
	}
	if err := WriteManifest(o.Home, m); err != nil {
		return Manifest{}, err
	}

	fmt.Fprintf(o.Log, "manifest %s points at %s\n", ManifestPath(o.Home), dir)

	return m, nil
}

// requireFile fails with the make target that builds path when it is not a
// regular file.
func requireFile(path, target string) error {
	info, err := os.Stat(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return fmt.Errorf("%s does not exist; run `%s`", path, target)

	case err != nil:
		return err

	case !info.Mode().IsRegular():
		return fmt.Errorf("%s is not a regular file", path)
	}

	return nil
}

// requireDir is requireFile for a directory.
func requireDir(path, target string) error {
	info, err := os.Stat(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return fmt.Errorf("%s does not exist; run `%s`", path, target)

	case err != nil:
		return err

	case !info.IsDir():
		return fmt.Errorf("%s is not a directory", path)
	}

	return nil
}
