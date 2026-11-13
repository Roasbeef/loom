// Package libkrun boots machine.Spec guests under libkrun through
// stacklok/go-microvm (ADR-022 D5).
//
// go-microvm splits the work in two. This process runs the library, which is
// CGO-free: it stages the root filesystem, runs the host-side network stack
// and writes the guest's configuration. A separate runner binary links
// libkrun with cgo and becomes the VMM. On macOS the runner must carry the
// Hypervisor.framework entitlement, so the runner path is configuration, not
// something this package finds for itself.
//
// The one decision this package exists to hold is networking. libkrun's own
// default is TSI, under which the guest's sockets are executed by the VMM
// process on the host; a guest booted that way reached a server bound to the
// host's loopback (ADR-022, "Measured"). Every guest here therefore gets
// go-microvm's hosted network provider and an egress policy, empty when the
// Spec allows nothing. A virtio-net device attached that way disables TSI
// inside libkrun, and the policy makes the firewall deny by default.
package libkrun

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"

	microvm "github.com/stacklok/go-microvm"
	mvlibkrun "github.com/stacklok/go-microvm/hypervisor/libkrun"
	"github.com/stacklok/go-microvm/image"
	"github.com/stacklok/go-microvm/net/hosted"

	"github.com/roasbeef/loom/vmm/machine"
)

// Config locates the native pieces a boot needs. None of them is needed to
// build or test this package; they matter only when Start runs.
type Config struct {
	// RunnerPath is the go-microvm-runner binary, built from the same
	// go-microvm version this module imports and, on macOS, codesigned
	// with the hypervisor entitlement.
	RunnerPath string

	// LibDir holds libkrun and, unless FirmwareDir is set, libkrunfw.
	LibDir string

	// FirmwareDir holds a libkrunfw build to use in place of the one in
	// LibDir. ADR-022 D3 requires a kernel with Landlock, which the stock
	// libkrunfw lacks; this is where that build is pointed at.
	FirmwareDir string
}

// Backend is the libkrun implementation of machine.Backend.
type Backend struct {
	cfg Config
}

// New returns a libkrun backend that boots with cfg.
//
// ## Examples
//
//	b := libkrun.New(libkrun.Config{
//		RunnerPath: "/usr/local/bin/go-microvm-runner",
//		LibDir:     "/opt/homebrew/lib",
//	})
func New(cfg Config) *Backend {
	return &Backend{cfg: cfg}
}

// Name identifies the backend.
func (b *Backend) Name() string { return "libkrun" }

// Probe reports whether this host can boot a libkrun guest. It checks the
// hypervisor and the configured runner. It cannot check that the runner was
// built from the matching go-microvm version, so a mismatch surfaces at the
// first boot instead.
//
// ## Examples
//
//	if p := b.Probe(ctx); p.Available != machine.Usable {
//		fmt.Println(p.Reason)
//	}
func (b *Backend) Probe(_ context.Context) machine.Probe {
	if ok, reason := hostHasHypervisor(); !ok {
		return machine.Probe{Available: machine.Unusable, Reason: reason}
	}

	if b.cfg.RunnerPath == "" {
		return machine.Probe{
			Available: machine.Unusable,
			Reason:    "no go-microvm runner configured (set --runner)",
		}
	}

	if _, err := os.Stat(b.cfg.RunnerPath); err != nil {
		return machine.Probe{
			Available: machine.Unusable,
			Reason:    fmt.Sprintf("runner %s: %v", b.cfg.RunnerPath, err),
		}
	}

	return machine.Probe{
		Available: machine.Usable,
		Reason:    "libkrun on " + runtime.GOOS + "/" + runtime.GOARCH,
		Warnings: []string{
			"the libkrun VMM runs in a host process with this user's " +
				"privileges, so a guest escape lands there; Firecracker's " +
				"jailer is the stronger boundary",
		},
	}
}

// hostHasHypervisor reports whether the host offers hardware
// virtualisation libkrun can use: Hypervisor.framework on Apple Silicon, or
// KVM on Linux.
func hostHasHypervisor() (bool, string) {
	switch runtime.GOOS {
	case "darwin":
		if runtime.GOARCH != "arm64" {
			return false, "libkrun on macOS needs Apple Silicon"
		}

		return true, ""

	case "linux":
		return kvmUsable("/dev/kvm")

	default:
		return false, "libkrun does not run on " + runtime.GOOS
	}
}

// kvmUsable reports whether the caller can open the KVM device. Opening it,
// and not only finding it, is the check: a device that exists but is closed to
// the user (the user is not in the kvm group) would otherwise pass the probe
// and fail inside the runner at the first boot.
func kvmUsable(path string) (bool, string) {
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return false, "libkrun on Linux needs a usable " + path + ": " + err.Error()
	}

	_ = f.Close()

	return true, ""
}

// Start boots spec and returns the running guest. microvm.Run stages the
// root, starts the network stack and spawns the runner before it returns,
// so a returned Machine is already booted.
func (b *Backend) Start(ctx context.Context, spec machine.Spec) (machine.Machine, error) {
	if err := spec.Validate(); err != nil {
		return nil, err
	}

	if err := raiseNofile(); err != nil {
		return nil, err
	}

	dataDir, owned, err := dataDirFor(spec)
	if err != nil {
		return nil, err
	}

	// The provider is created here, not left to go-microvm, so the guest is
	// never booted without one. Owning it also lets Stop sever the network
	// before the VMM goes away.
	netProv := hosted.NewProvider()

	// A hosted service listens on the gateway inside the launcher's own
	// network stack, and the provider admits the guest's connections to its
	// port through the egress firewall. It must be registered before the
	// provider starts, which microvm.Run does.
	for _, svc := range spec.HostServices {
		netProv.AddService(hosted.Service{Port: svc.Port, Handler: svc.Handler})
	}

	opts := b.options(spec, dataDir, netProv)

	vm, err := microvm.Run(ctx, spec.Root.Image, opts...)
	if err != nil {
		netProv.Stop()
		if owned {
			_ = os.RemoveAll(dataDir)
		}

		return nil, fmt.Errorf("libkrun: boot %s: %w", spec.Name, err)
	}

	root := extractedRoot
	if spec.Root.Dir != "" {
		root = callerRoot
	}

	return &guest{
		vm:      vm,
		netProv: netProv,
		dataDir: dataDir,
		console: filepath.Join(vm.DataDir(), "console.log"),
		root:    root,
	}, nil
}

// dataDirFor returns the guest's data directory and whether Start created
// it, in which case a failed boot removes it again.
func dataDirFor(spec machine.Spec) (string, bool, error) {
	if spec.DataDir != "" {
		return spec.DataDir, false, nil
	}

	dir, err := os.MkdirTemp("", "loom-vm-")
	if err != nil {
		return "", false, fmt.Errorf("libkrun: data dir: %w", err)
	}

	return dir, true, nil
}

// options translates spec into go-microvm options. The network options are
// unconditional: see the package documentation for why a guest with no
// provider is never started.
func (b *Backend) options(spec machine.Spec, dataDir string,
	netProv *hosted.Provider) []microvm.Option {

	cpus, mem := spec.CPUs, spec.MemoryMiB
	if cpus == 0 {
		cpus = machine.DefaultCPUs
	}
	if mem == 0 {
		mem = machine.DefaultMemoryMiB
	}

	name := spec.Name
	if name == "" {
		name = "loom-vm"
	}

	opts := []microvm.Option{
		microvm.WithName(name),
		microvm.WithCPUs(cpus),
		microvm.WithMemory(mem),
		microvm.WithDataDir(dataDir),
		microvm.WithInitOverride(spec.Init...),

		// go-microvm's guest init would otherwise start an SSH server. The
		// launcher talks to the guest through its console and, later, a
		// vsock port, so an inbound listener is surface with no user.
		microvm.WithoutSSH(),

		microvm.WithNetProvider(netProv),
		microvm.WithEgressPolicy(egressPolicy(spec.Egress)),
		microvm.WithRootFSHook(stageFiles(spec.Files)),
		microvm.WithImageFetcher(image.NewLocalThenRemoteFetcher()),
	}

	if spec.Root.Dir != "" {
		opts = append(opts, microvm.WithRootFSPath(spec.Root.Dir))
	}

	// Disks keep their order, which fixes their device names in the guest.
	if len(spec.Disks) > 0 {
		disks := make([]microvm.Disk, 0, len(spec.Disks))
		for _, d := range spec.Disks {
			disks = append(disks, microvm.Disk{
				ID:       d.ID,
				HostPath: d.Path,
				Format:   microvm.DiskFormatRaw,
			})
		}
		opts = append(opts, microvm.WithDisks(disks...))
	}

	// The hosted provider binds each forward on the host's 127.0.0.1 and
	// admits the forwarded port through the guest firewall's ingress.
	if len(spec.Forwards) > 0 {
		ports := make([]microvm.PortForward, 0, len(spec.Forwards))
		for _, f := range spec.Forwards {
			ports = append(ports, microvm.PortForward{Host: f.Host, Guest: f.Guest})
		}
		opts = append(opts, microvm.WithPorts(ports...))
	}

	if bk := b.hypervisor(); bk != nil {
		opts = append(opts, microvm.WithBackend(bk))
	}

	return opts
}

// hypervisor builds go-microvm's libkrun backend from the configured paths.
// With a FirmwareDir, that directory goes first on the library path, so the
// runner loads the custom libkrunfw before the stock one in LibDir.
func (b *Backend) hypervisor() *mvlibkrun.Backend {
	if b.cfg.RunnerPath == "" {
		return nil
	}

	opts := []mvlibkrun.Option{
		mvlibkrun.WithRunnerPath(resolveRunner(b.cfg.RunnerPath)),
	}

	libDir := libraryPath(b.cfg)
	if libDir != "" {
		opts = append(opts, mvlibkrun.WithLibDir(libDir))
	}

	return mvlibkrun.NewBackend(opts...)
}

// resolveRunner returns the runner's path with symlinks resolved. go-microvm
// decides whether a pid is still its runner by comparing /proc/PID/exe, which
// the kernel resolves, with the path it was given. A path through a symlink
// never matches, so on Linux a guest's Stop saw no runner, sent no signal and
// left the runner holding the root and the state disk. A path that cannot be
// resolved is passed on unchanged, and the boot reports that the runner is
// missing.
func resolveRunner(path string) string {
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved
	}

	return path
}

// libraryPath joins the firmware and library directories in the order the
// runner should search them.
func libraryPath(cfg Config) string {
	switch {
	case cfg.FirmwareDir != "" && cfg.LibDir != "":
		return cfg.FirmwareDir + string(os.PathListSeparator) + cfg.LibDir

	case cfg.FirmwareDir != "":
		return cfg.FirmwareDir

	default:
		return cfg.LibDir
	}
}

// egressPolicy converts the allowlist. The result is never nil, because a
// nil policy is what leaves go-microvm's firewall allowing by default.
func egressPolicy(e machine.Egress) microvm.EgressPolicy {
	hosts := make([]microvm.EgressHost, 0, len(e.Hosts))
	for _, h := range e.Hosts {
		hosts = append(hosts, microvm.EgressHost{Name: h})
	}

	return microvm.EgressPolicy{AllowedHosts: hosts}
}

// stageFiles returns the root filesystem hook that copies files into the
// guest root. It runs after the image is extracted and before the guest
// boots, so the guest sees each file as part of its own filesystem.
func stageFiles(files []machine.File) microvm.RootFSHook {
	return func(rootfs string, _ *image.OCIConfig) error {
		for _, f := range files {
			if err := stageFile(rootfs, f); err != nil {
				return err
			}
		}

		return nil
	}
}

// stageFile copies one file. Validate has already refused a target that is
// relative or climbs with "..", so joining it onto rootfs stays inside.
func stageFile(rootfs string, f machine.File) error {
	raw, err := os.ReadFile(f.Source)
	if err != nil {
		return fmt.Errorf("libkrun: stage %s: %w", f.Target, err)
	}

	dst := filepath.Join(rootfs, filepath.FromSlash(f.Target))

	// A link in the root, left by an earlier boot of this guest, must not
	// carry the write or the directory creation outside it.
	if err := resolvedWithin(rootfs, filepath.Dir(dst)); err != nil {
		return fmt.Errorf("libkrun: stage %s: %w", f.Target, err)
	}

	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return fmt.Errorf("libkrun: stage %s: %w", f.Target, err)
	}

	// Remove first, so a symlink the image left at the target is replaced
	// rather than followed out of the root.
	if err := os.Remove(dst); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("libkrun: stage %s: %w", f.Target, err)
	}

	if err := os.WriteFile(dst, raw, f.Mode.Perm()); err != nil {
		return fmt.Errorf("libkrun: stage %s: %w", f.Target, err)
	}

	return nil
}

// resolvedWithin refuses a directory whose deepest existing ancestor resolves,
// through every link, to a place outside the resolved root. Components that do
// not exist yet are created later as real directories, so only the existing
// part can lead out. A dangling link counts as existing and cannot be
// resolved, which is refused too.
func resolvedWithin(root, dir string) error {
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return err
	}

	existing := dir
	for {
		if _, err := os.Lstat(existing); err == nil {
			break
		}

		parent := filepath.Dir(existing)
		if parent == existing {
			break
		}
		existing = parent
	}

	real, err := filepath.EvalSymlinks(existing)
	if err != nil {
		return fmt.Errorf("%s does not resolve: %w", existing, err)
	}

	rel, err := filepath.Rel(realRoot, real)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return fmt.Errorf("%s resolves to %s, outside the guest root; "+
			"replace the guest's root", existing, real)
	}

	return nil
}

// rootOwnership says who owns a guest's root filesystem directory, which
// decides whether Stop may delete it.
type rootOwnership int

const (
	// extractedRoot is a root go-microvm extracted from an image for this
	// guest alone, so Stop removes it with the rest of the guest.
	extractedRoot rootOwnership = iota

	// callerRoot is a Spec.Root.Dir the caller prepared. go-microvm's
	// Remove deletes any root outside its image cache, which here would be
	// the caller's directory, so Stop only stops the runner.
	callerRoot
)

// guest is a running libkrun machine.
type guest struct {
	vm      *microvm.VM
	netProv *hosted.Provider
	dataDir string
	console string
	root    rootOwnership

	stopOnce sync.Once
	stopErr  error
}

// ID identifies the guest by its runner.
func (g *guest) ID() string { return g.vm.ID() }

// ConsolePath is where the runner writes the guest console.
func (g *guest) ConsolePath() string { return g.console }

// Wait polls the runner until it exits. go-microvm exposes no exit channel,
// and the runner is not this process's child after go-microvm detaches it,
// so a zero signal is the only liveness question this process can ask.
func (g *guest) Wait(ctx context.Context) error {
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()

	for {
		if !g.alive() {
			return nil
		}

		select {
		case <-ctx.Done():
			return ctx.Err()

		case <-tick.C:
		}
	}
}

// alive reports whether the runner process still exists.
func (g *guest) alive() bool {
	pid := g.vm.RunnerPID()
	if pid <= 0 {
		return false
	}

	return syscall.Kill(pid, 0) == nil
}

// Stop severs the network, stops the runner and removes the data
// directory. The teardown runs under its own bounded context, so a caller
// whose context is already cancelled still releases the machine.
func (g *guest) Stop(_ context.Context) error {
	g.stopOnce.Do(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		// Egress goes first, so nothing leaves the guest while the VMM is
		// shutting down.
		g.netProv.Stop()

		var errs []error
		switch g.root {
		case extractedRoot:
			if err := g.vm.Remove(ctx); err != nil {
				errs = append(errs, fmt.Errorf("libkrun: remove: %w", err))
			}

		case callerRoot:
			if err := g.vm.Stop(ctx); err != nil {
				errs = append(errs, fmt.Errorf("libkrun: stop: %w", err))
			}
		}

		if err := os.RemoveAll(g.dataDir); err != nil {
			errs = append(errs, fmt.Errorf("libkrun: data dir: %w", err))
		}

		g.stopErr = errors.Join(errs...)
	})

	return g.stopErr
}
