package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/roasbeef/loom/vmm/setup"
)

// setupCmd installs the artifacts a guest boots from and writes the manifest,
// either from a published release or from a build tree.
func setupCmd(args []string) error {
	fs := flag.NewFlagSet("setup", flag.ContinueOnError)

	var (
		release   = fs.String("release", "", "install this release `TAG` (macOS on Apple Silicon)")
		fromBuild = fs.String("from-build", "", "write a manifest for the build tree `DIR` (packages/vmm/build)")
		repo      = fs.String("repo", setup.DefaultRepo, "GitHub `OWNER/NAME` that published the release")
		revision  = fs.String("revision", "", "with --from-build, the revision to record (default \"dev\"); "+
			"with --release, the commit the guest image must have been built from")
		libDir = fs.String("lib-dir", os.Getenv("LOOM_VM_LIB_DIR"),
			"directory holding libkrun (LOOM_VM_LIB_DIR; default: Homebrew's)")
		home = fs.String("home", "", "loom-vm home directory (LOOM_VM_HOME; default ~/.loom/vm)")
	)
	if err := fs.Parse(args); err != nil {
		return err
	}

	if (*release == "") == (*fromBuild == "") {
		return errors.New("setup needs exactly one of --release TAG or --from-build DIR")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var (
		m   setup.Manifest
		err error
	)
	if *release != "" {
		m, err = setup.Release(ctx, setup.Options{
			Home: *home, Tag: *release, Repo: *repo, LibDir: *libDir, Revision: *revision, Log: os.Stderr,
		})
	} else {
		m, err = setup.FromBuild(ctx, setup.BuildOptions{
			Home: *home, Dir: *fromBuild, Revision: *revision, LibDir: *libDir, Log: os.Stderr,
		})
	}
	if err != nil {
		return err
	}

	// The manifest goes to standard output, so a script can read what
	// setup decided; the progress lines went to standard error.
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")

	return enc.Encode(m)
}

// doctorCmd reports on the installation the manifest names and fails when a
// guest cannot boot from it.
func doctorCmd(args []string) error {
	fs := flag.NewFlagSet("doctor", flag.ContinueOnError)
	home := fs.String("home", "", "loom-vm home directory (LOOM_VM_HOME; default ~/.loom/vm)")
	if err := fs.Parse(args); err != nil {
		return err
	}

	rep := setup.Doctor(context.Background(), setup.DoctorOptions{Home: *home})
	rep.Print(os.Stdout)

	if rep.Failed() {
		return errors.New("the installation has problems")
	}

	fmt.Println("all checks passed")

	return nil
}
