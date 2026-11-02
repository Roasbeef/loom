// Package vmm carries the one file of this module that other packages need
// at run time and that cannot live beside them.
//
// runner.entitlements is read by two things: `make vmm-runner` passes its
// path to codesign when it builds a runner, and `loom-vm setup` signs a
// downloaded runner with the same bytes. go:embed cannot reach a file in a
// parent directory, so the embedding lives here, at the module root, where
// the file is. One copy of the plist means the runner a developer builds and
// the runner a user installs are signed with the same entitlements.
package vmm

import _ "embed"

// RunnerEntitlements is the property list that grants the go-microvm runner
// the Hypervisor.framework entitlement (and the JIT entitlement libkrun's
// VMM needs). macOS refuses to start a guest from a runner without it.
//
//go:embed runner.entitlements
var RunnerEntitlements []byte
