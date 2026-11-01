// Package machine is the hypervisor-independent contract the microVM tier
// boots guests through.
//
// ADR-022 puts a whole executor inside a guest and lets the hypervisor vary
// behind one interface: libkrun first, Firecracker later. Everything a caller
// decides about a guest lives in Spec, and a Backend turns a Spec into a
// running Machine. The package holds no hypervisor code, so the launcher's
// decisions (what the guest may reach, what is staged into it) can be tested
// on any host, including the Linux CI containers that have no /dev/kvm.
//
// Two rules shape the types. Networking is never implicit: a Spec carries an
// Egress value, and an empty allowlist means the guest reaches nothing, never
// that the hypervisor's default applies. That default, for libkrun, is TSI,
// which hands the guest the host's network namespace, loopback included
// (ADR-022, "Measured"). And nothing from the host is shared into the guest:
// files are copied into the guest's root filesystem before boot, so the guest
// sees a snapshot rather than a live host directory.
package machine

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"path"
	"strings"
)

// Spec describes one guest. It is complete: a Backend reads nothing else,
// so two boots of the same Spec differ only in what the guest itself does.
type Spec struct {
	// Name labels the guest in logs and in the backend's state directory.
	Name string

	// Root is the guest's root filesystem.
	Root Root

	// CPUs is the guest's vCPU count. Zero selects DefaultCPUs.
	CPUs uint32

	// MemoryMiB is the guest's memory in MiB. Zero selects DefaultMemoryMiB.
	MemoryMiB uint32

	// Init is the guest's first program and its arguments. It replaces the
	// image's entrypoint, so the guest runs exactly what the launcher chose.
	Init []string

	// Files are copied into the root filesystem before boot.
	Files []File

	// Egress is the complete set of hosts the guest may reach.
	Egress Egress

	// Forwards are the only inbound paths into the guest: each listens on
	// the host's loopback and connects to a guest port.
	Forwards []Forward

	// DataDir is the directory the backend keeps the guest's state and
	// console log in. The backend creates it if it is missing, and Stop
	// removes it. Empty asks the backend for a fresh temporary directory.
	DataDir string
}

// Root names where the guest's root filesystem comes from. Exactly one
// field is set; Validate refuses both or neither.
type Root struct {
	// Image is an OCI image reference, resolved from the local container
	// daemon first and a registry second.
	Image string

	// Dir is a prepared root filesystem directory on the host. The backend
	// boots from it as given, so a caller that needs a pristine root passes
	// a fresh copy.
	Dir string
}

// File is one host file copied into the guest root before boot.
type File struct {
	// Source is the host path to read.
	Source string

	// Target is the absolute path inside the guest.
	Target string

	// Mode is the permission bits the guest copy gets.
	Mode fs.FileMode
}

// Egress is the guest's outbound allowlist. The zero value allows nothing:
// the guest still gets an interface and DHCP from the host-side stack, but
// every name outside Hosts fails to resolve and no other host is reachable.
type Egress struct {
	// Hosts are hostnames the guest may resolve and connect to, on any
	// port. A leading "*." matches one or more subdomain labels.
	Hosts []string
}

// Forward carries TCP connections made to Host on 127.0.0.1 into the guest's
// Guest port. A forward never listens beyond loopback, so a guest port is
// reachable from this machine only.
type Forward struct {
	Host  uint16
	Guest uint16
}

// Default guest sizes, used when a Spec leaves them zero so a backend never
// asks its VMM for an empty machine.
const (
	DefaultCPUs      = 2
	DefaultMemoryMiB = 1024
)

// Validate reports the first reason a Spec cannot boot. It checks what a
// backend would otherwise discover halfway through staging a root, after
// it has already pulled an image or written into a directory.
//
// ## Examples
//
//	spec := machine.Spec{Root: machine.Root{Image: "alpine:3.22"},
//		Init: []string{"/bin/true"}}
//	err := spec.Validate() // nil
func (s Spec) Validate() error {
	switch {
	case s.Root.Image == "" && s.Root.Dir == "":
		return errors.New("machine: spec has no root: set Root.Image or Root.Dir")

	case s.Root.Image != "" && s.Root.Dir != "":
		return errors.New("machine: spec sets both Root.Image and Root.Dir")
	}

	if len(s.Init) == 0 || s.Init[0] == "" {
		return errors.New("machine: spec has no init program")
	}

	// A staged file must land inside the guest root. A relative target, or
	// one that climbs out through "..", would be joined onto the host-side
	// root directory and could write anywhere the launcher can.
	for _, f := range s.Files {
		if err := checkTarget(f.Target); err != nil {
			return err
		}

		if f.Source == "" {
			return fmt.Errorf("machine: file %q has no source", f.Target)
		}
	}

	for _, h := range s.Egress.Hosts {
		if err := checkHost(h); err != nil {
			return err
		}
	}

	// Two forwards on one host port would leave which guest port answers to
	// the order the provider happens to bind them in.
	seen := make(map[uint16]bool, len(s.Forwards))
	for _, f := range s.Forwards {
		if f.Host == 0 || f.Guest == 0 {
			return fmt.Errorf("machine: forward %d->%d has a zero port", f.Host, f.Guest)
		}

		if seen[f.Host] {
			return fmt.Errorf("machine: host port %d forwarded twice", f.Host)
		}
		seen[f.Host] = true
	}

	return nil
}

// checkTarget refuses a guest path that is not absolute and clean.
func checkTarget(target string) error {
	if !path.IsAbs(target) || path.Clean(target) != target || target == "/" {
		return fmt.Errorf("machine: file target %q is not a clean absolute "+
			"path below /", target)
	}

	return nil
}

// checkHost refuses an allowlist entry that is empty, carries a scheme or
// port, or uses a wildcard anywhere but a leading "*.". The allowlist names
// hosts; a URL in it would never match, and a silently dead entry is how an
// operator ends up widening a list that was never the problem.
func checkHost(h string) error {
	name := strings.TrimPrefix(h, "*.")

	switch {
	case name == "":
		return errors.New("machine: empty egress host")

	case strings.ContainsAny(name, "*/:@ "):
		return fmt.Errorf("machine: egress host %q is not a bare hostname", h)
	}

	return nil
}

// Backend boots guests on one hypervisor.
type Backend interface {
	// Name is the backend's identifier, such as "libkrun".
	Name() string

	// Probe reports whether this host can run the backend's guests.
	Probe(ctx context.Context) Probe

	// Start boots a guest. The returned Machine is running, and the caller
	// owns it until Stop.
	Start(ctx context.Context, spec Spec) (Machine, error)
}

// Probe is a backend's answer about the current host.
type Probe struct {
	// Available is Usable when the backend can boot a guest here.
	Available Availability

	// Reason explains Available in one sentence an operator can act on.
	Reason string

	// Warnings are properties of the backend an operator should know even
	// when it is usable, such as where its VMM runs.
	Warnings []string
}

// Availability says whether a backend can boot guests on this host.
type Availability int

const (
	// Unusable means the host lacks what the backend needs.
	Unusable Availability = iota

	// Usable means the backend can boot guests here.
	Usable
)

// Machine is one running guest.
type Machine interface {
	// ID identifies the guest in logs.
	ID() string

	// ConsolePath is the host file the guest's console is written to. The
	// guest's init writes its standard output and error there.
	ConsolePath() string

	// Wait blocks until the guest has exited or ctx ends.
	Wait(ctx context.Context) error

	// Stop ends the guest if it is running and releases every host resource
	// it held, its data directory included. It is idempotent, and it runs
	// to completion even when ctx is already cancelled, because a guest
	// left running is a leaked machine, not a leaked process.
	Stop(ctx context.Context) error
}
