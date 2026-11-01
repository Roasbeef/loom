// Command loom-vm boots the microVM tier's guests from the command line.
//
// It is the launcher ADR-022 places beside loom-exec: a host-side program
// that turns a machine.Spec into a running guest, so the tier can be driven
// and measured before the broker learns to place an executor inside one.
//
//	loom-vm probe
//	loom-vm run [flags] -- INIT [ARGS...]
//
// probe reports whether this host can boot a guest. run boots one, copies
// the guest console to standard output until the guest exits, and then
// releases the machine. Native paths come from flags, or from LOOM_VM_RUNNER,
// LOOM_VM_LIB_DIR and LOOM_VM_FIRMWARE_DIR.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/roasbeef/loom/vmm/machine"
	"github.com/roasbeef/loom/vmm/machine/libkrun"
)

const usage = `usage:
  loom-vm probe [native flags]
  loom-vm run [native flags] [run flags] -- INIT [ARGS...]
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}

	var err error
	switch os.Args[1] {
	case "probe":
		err = probe(os.Args[2:])

	case "run":
		err = run(os.Args[2:])

	case "-h", "--help", "help":
		fmt.Fprint(os.Stdout, usage)

	default:
		fmt.Fprintf(os.Stderr, "loom-vm: unknown command %q\n%s", os.Args[1], usage)
		os.Exit(2)
	}

	if err != nil {
		fmt.Fprintf(os.Stderr, "loom-vm: %v\n", err)
		os.Exit(1)
	}
}

// nativeFlags registers the flags that locate the runner and libraries,
// shared by every command that touches a backend.
func nativeFlags(fs *flag.FlagSet) *libkrun.Config {
	cfg := &libkrun.Config{}
	fs.StringVar(&cfg.RunnerPath, "runner", os.Getenv("LOOM_VM_RUNNER"),
		"go-microvm-runner binary (LOOM_VM_RUNNER)")
	fs.StringVar(&cfg.LibDir, "lib-dir", os.Getenv("LOOM_VM_LIB_DIR"),
		"directory holding libkrun (LOOM_VM_LIB_DIR)")
	fs.StringVar(&cfg.FirmwareDir, "firmware-dir", os.Getenv("LOOM_VM_FIRMWARE_DIR"),
		"directory holding a custom libkrunfw (LOOM_VM_FIRMWARE_DIR)")

	return cfg
}

// probe prints the backend's answer about this host and fails when the
// backend cannot boot here.
func probe(args []string) error {
	fs := flag.NewFlagSet("probe", flag.ContinueOnError)
	cfg := nativeFlags(fs)
	if err := fs.Parse(args); err != nil {
		return err
	}

	b := libkrun.New(*cfg)
	p := b.Probe(context.Background())

	state := "unusable"
	if p.Available == machine.Usable {
		state = "usable"
	}

	fmt.Printf("%s: %s (%s)\n", b.Name(), state, p.Reason)
	for _, w := range p.Warnings {
		fmt.Printf("  warning: %s\n", w)
	}

	if p.Available != machine.Usable {
		return errors.New("no usable backend")
	}

	return nil
}

// listFlag collects a repeatable string flag.
type listFlag []string

func (l *listFlag) String() string { return strings.Join(*l, ",") }

func (l *listFlag) Set(v string) error {
	*l = append(*l, v)
	return nil
}

// run boots one guest and copies its console until it exits.
func run(args []string) error {
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	cfg := nativeFlags(fs)

	var (
		spec    machine.Spec
		allow   listFlag
		files   listFlag
		fwds    listFlag
		timeout time.Duration
	)
	fs.StringVar(&spec.Name, "name", "loom-vm", "guest name")
	fs.StringVar(&spec.Root.Image, "image", "", "OCI image for the guest root")
	fs.StringVar(&spec.Root.Dir, "root-dir", "", "prepared root directory")
	cpus := fs.Uint("cpus", 0, "vCPUs (0 = default)")
	mem := fs.Uint("mem", 0, "memory in MiB (0 = default)")
	fs.Var(&allow, "allow", "allowlisted egress host (repeatable)")
	fs.Var(&files, "file", "SRC:DST[:MODE] copied into the guest (repeatable)")
	fs.Var(&fwds, "forward", "HOST:GUEST port forwarded from host loopback (repeatable)")
	fs.DurationVar(&timeout, "timeout", 10*time.Minute, "stop the guest after this long")
	if err := fs.Parse(args); err != nil {
		return err
	}

	spec.CPUs, spec.MemoryMiB = uint32(*cpus), uint32(*mem)
	spec.Init = fs.Args()
	spec.Egress.Hosts = allow

	for _, f := range files {
		parsed, err := parseFile(f)
		if err != nil {
			return err
		}
		spec.Files = append(spec.Files, parsed)
	}

	for _, f := range fwds {
		parsed, err := parseForward(f)
		if err != nil {
			return err
		}
		spec.Forwards = append(spec.Forwards, parsed)
	}

	if err := spec.Validate(); err != nil {
		return err
	}

	// An interrupt ends the run the same way a timeout does: through the
	// context, so the deferred Stop still releases the machine.
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()

	m, err := libkrun.New(*cfg).Start(ctx, spec)
	if err != nil {
		return err
	}
	defer m.Stop(context.Background())

	return follow(ctx, m, os.Stdout)
}

// parseFile reads a SRC:DST[:MODE] flag. MODE is octal and defaults to
// 0644.
func parseFile(v string) (machine.File, error) {
	parts := strings.Split(v, ":")
	if len(parts) < 2 || len(parts) > 3 {
		return machine.File{}, fmt.Errorf("--file %q: want SRC:DST[:MODE]", v)
	}

	f := machine.File{Source: parts[0], Target: parts[1], Mode: 0o644}
	if len(parts) == 3 {
		mode, err := strconv.ParseUint(parts[2], 8, 32)
		if err != nil {
			return machine.File{}, fmt.Errorf("--file %q: mode: %w", v, err)
		}
		f.Mode = os.FileMode(mode)
	}

	return f, nil
}

// parseForward reads a HOST:GUEST flag.
func parseForward(v string) (machine.Forward, error) {
	host, guest, ok := strings.Cut(v, ":")
	if !ok {
		return machine.Forward{}, fmt.Errorf("--forward %q: want HOST:GUEST", v)
	}

	h, herr := strconv.ParseUint(host, 10, 16)
	g, gerr := strconv.ParseUint(guest, 10, 16)
	if herr != nil || gerr != nil {
		return machine.Forward{}, fmt.Errorf("--forward %q: ports must be 1-65535", v)
	}

	return machine.Forward{Host: uint16(h), Guest: uint16(g)}, nil
}

// follow copies the console file to w until the guest exits or ctx ends.
// The runner creates the file after boot begins, so a missing file is
// retried rather than reported.
func follow(ctx context.Context, m machine.Machine, w io.Writer) error {
	var console *os.File
	for console == nil {
		f, err := os.Open(m.ConsolePath())
		switch {
		case err == nil:
			console = f

		case !errors.Is(err, os.ErrNotExist):
			return err

		default:
			if err := sleep(ctx, 50*time.Millisecond); err != nil {
				return err
			}
		}
	}
	defer console.Close()

	// A guest that exited has written its last line, so one final copy
	// after Wait returns drains what arrived between the last read and the
	// exit.
	done := make(chan error, 1)
	go func() { done <- m.Wait(ctx) }()

	for {
		if _, err := io.Copy(w, console); err != nil {
			return err
		}

		select {
		case err := <-done:
			_, cerr := io.Copy(w, console)
			return errors.Join(err, cerr)

		case <-time.After(100 * time.Millisecond):
		}
	}
}

// sleep waits d or until ctx ends.
func sleep(ctx context.Context, d time.Duration) error {
	select {
	case <-ctx.Done():
		return ctx.Err()

	case <-time.After(d):
		return nil
	}
}
