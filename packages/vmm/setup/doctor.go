package setup

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"

	"github.com/roasbeef/loom/vmm/machine"
	"github.com/roasbeef/loom/vmm/machine/libkrun"
)

// Status is the outcome of one doctor check.
type Status int

const (
	// OK means the check passed.
	OK Status = iota

	// Note is information that is neither a pass nor a problem, such as a
	// checksum that was never recorded for a development tree.
	Note

	// Warn is something worth fixing that does not stop a guest booting.
	Warn

	// Fail means a guest cannot boot, or cannot be trusted to, as installed.
	Fail
)

// String is the label doctor prints for the status.
func (s Status) String() string {
	return [...]string{"ok", "note", "warn", "FAIL"}[s]
}

// Check is one line of a doctor report.
type Check struct {
	Name   string
	Status Status
	Detail string
}

// Process is a runner process found by the orphan scan.
type Process struct {
	PID  int
	PPID int
	Args string
}

// Report is the result of Doctor.
type Report struct {
	Checks []Check

	// Orphans are go-microvm-runner processes with no loom-vm parent.
	// They are reported, never killed: a runner holds a guest's memory
	// and its data directory, and only its owner knows whether it is
	// still wanted.
	Orphans []Process
}

// Failed reports whether any check failed.
func (r Report) Failed() bool {
	for _, c := range r.Checks {
		if c.Status == Fail {
			return true
		}
	}

	return false
}

// Print writes the report in the form `loom-vm doctor` shows.
func (r Report) Print(w io.Writer) {
	for _, c := range r.Checks {
		fmt.Fprintf(w, "%-5s %-14s %s\n", c.Status, c.Name, c.Detail)
	}

	for _, p := range r.Orphans {
		fmt.Fprintf(w, "%-5s %-14s pid %d (parent %d): %s\n", Warn, "orphan runner", p.PID, p.PPID, p.Args)
	}
}

// DoctorOptions configures Doctor.
type DoctorOptions struct {
	// Home is the loom-vm home directory. Default: DefaultHome.
	Home string

	// GOOS names the host. Default: the running platform.
	GOOS string

	// Run executes codesign and ps. Default: ExecCommander.
	Run Commander
}

// Doctor reads the manifest under the home directory and checks that each
// artifact it names is present and usable: the binaries exist, the files that
// setup checksummed still match, the runner carries the hypervisor
// entitlement, libkrun is there, the guest root has the init and a
// world-writable /tmp, and the hypervisor is available. It then lists orphaned
// runner processes. It changes nothing.
//
// ## Examples
//
//	rep := setup.Doctor(ctx, setup.DoctorOptions{})
//	rep.Print(os.Stdout)
func Doctor(ctx context.Context, opts DoctorOptions) Report {
	o := opts
	if o.GOOS == "" {
		o.GOOS = runtime.GOOS
	}
	if o.Run == nil {
		o.Run = ExecCommander
	}

	var rep Report
	add := func(name string, s Status, format string, args ...any) {
		rep.Checks = append(rep.Checks, Check{name, s, fmt.Sprintf(format, args...)})
	}

	home := o.Home
	if home == "" {
		var err error
		if home, err = DefaultHome(); err != nil {
			add("manifest", Fail, "%v", err)

			return rep
		}
	}

	m, err := ReadManifest(home)
	if err != nil {
		add("manifest", Fail, "%v; run `loom-vm setup`", err)

		return rep
	}
	add("manifest", OK, "%s (revision %s)", ManifestPath(home), m.Revision)

	if err := isExecutable(m.LoomVM); err != nil {
		add("loom-vm", Fail, "%v", err)
	} else {
		add("loom-vm", OK, "%s", m.LoomVM)
	}

	sums, sumsErr := readInstalledSums(filepath.Dir(m.Runner))

	if err := isExecutable(m.Runner); err != nil {
		add("runner", Fail, "%v", err)
	} else {
		add("runner", OK, "%s", m.Runner)
		checkSum(add, "runner sha256", m.Runner, sums, sumsErr)

		if o.GOOS == "darwin" {
			checkEntitlement(ctx, o.Run, add, m.Runner)
		}
	}

	if hasLibkrun(m.LibDir) {
		add("libkrun", OK, "%s", m.LibDir)
	} else {
		add("libkrun", Fail, "no libkrun in %s; %s", m.LibDir, installHint(o.GOOS))
	}

	if m.FirmwareDir == "" {
		add("firmware", Warn, "none; the guest boots on the stock libkrunfw, which lacks Landlock")
	} else {
		fw := filepath.Join(m.FirmwareDir, firmwareName(o.GOOS))
		if _, err := os.Stat(fw); err != nil {
			add("firmware", Fail, "%v", err)
		} else {
			add("firmware", OK, "%s", fw)
			checkSum(add, "firmware sha256", fw, sums, sumsErr)
		}
	}

	checkGuestRoot(add, m.GuestRoot)

	p := libkrun.New(libkrun.Config{
		RunnerPath:  m.Runner,
		LibDir:      m.LibDir,
		FirmwareDir: m.FirmwareDir,
	}).Probe(ctx)
	if p.Available == machine.Usable {
		add("hypervisor", OK, "%s", p.Reason)
	} else {
		add("hypervisor", Fail, "%s", p.Reason)
	}

	if out, err := o.Run(ctx, "ps", "-axo", "pid=,ppid=,command="); err != nil {
		add("orphans", Warn, "cannot list processes: %v", err)
	} else {
		rep.Orphans = FindOrphans(string(out))
		if len(rep.Orphans) == 0 {
			add("orphans", OK, "no runner without a loom-vm parent")
		}
	}

	return rep
}

// isExecutable fails unless path is a regular file with an execute bit.
func isExecutable(path string) error {
	info, err := os.Stat(path)
	switch {
	case err != nil:
		return err

	case !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0:
		return fmt.Errorf("%s is not an executable file", path)
	}

	return nil
}

// checkSum compares path with the digest recorded when it was installed. A
// tree installed with FromBuild has none, which is a note and not a failure.
func checkSum(add func(string, Status, string, ...any), name, path string,
	sums map[string]string, sumsErr error) {

	want, ok := sums[filepath.Base(path)]
	if sumsErr != nil || !ok {
		add(name, Note, "no digest recorded (installed from a build tree)")

		return
	}

	got, err := fileSum(path)
	switch {
	case err != nil:
		add(name, Fail, "%v", err)

	case got != want:
		add(name, Fail, "%s is %s, installed as %s", filepath.Base(path), got, want)

	default:
		add(name, OK, "%s", got)
	}
}

// Both forms `codesign -d --entitlements` prints: the plain dump, and the
// XML property list.
var (
	entitlementDump = regexp.MustCompile(`com\.apple\.security\.hypervisor\s*\[Value\]\s*\[Bool\]\s*true`)
	entitlementXML  = regexp.MustCompile(`<key>com\.apple\.security\.hypervisor</key>\s*<true\s*/>`)
)

// checkEntitlement verifies that the runner is signed with the
// Hypervisor.framework entitlement, without which macOS kills it at boot.
func checkEntitlement(ctx context.Context, run Commander,
	add func(string, Status, string, ...any), runner string) {

	out, err := run(ctx, "codesign", "-d", "--entitlements", "-", runner)
	switch {
	case err != nil:
		add("entitlement", Fail, "runner is not signed: %s", strings.TrimSpace(string(out)))

	case entitlementDump.Match(out) || entitlementXML.Match(out):
		add("entitlement", OK, "com.apple.security.hypervisor")

	default:
		add("entitlement", Fail, "runner is signed without com.apple.security.hypervisor; "+
			"re-run `loom-vm setup`, or `make vmm-runner` for a built tree")
	}
}

// checkGuestRoot checks the two properties a failed extraction breaks first:
// the init the guest runs is present and executable, and /tmp kept its
// world-write and sticky bits, which an extraction that applied the umask
// would have cleared.
func checkGuestRoot(add func(string, Status, string, ...any), root string) {
	init := filepath.Join(root, "usr", "local", "sbin", "loom-guest-init")
	if err := isExecutable(init); err != nil {
		add("guest root", Fail, "%v", err)

		return
	}

	info, err := os.Stat(filepath.Join(root, "tmp"))
	switch {
	case err != nil:
		add("guest root", Fail, "%v", err)

	case info.Mode().Perm() != 0o777 || info.Mode()&os.ModeSticky == 0:
		add("guest root", Fail, "/tmp is %v, want drwxrwxrwt; the root was copied without "+
			"preserving modes (clone with cp -cRp on macOS, cp -a on Linux)", info.Mode())

	default:
		add("guest root", OK, "%s", root)
	}
}

// FindOrphans parses `ps -axo pid=,ppid=,command=` output and returns the
// go-microvm-runner processes whose parent is not a loom-vm process.
//
// go-microvm starts the runner in its own session but leaves loom-vm as its
// parent, so a runner of a live guest has a loom-vm ppid. When loom-vm dies
// without running its teardown, which only SIGKILL does, the runner is
// reparented to init and keeps the guest's memory and data directory.
//
// ## Examples
//
//	orphans := setup.FindOrphans(psOutput)
func FindOrphans(ps string) []Process {
	procs := make(map[int]Process)
	var order []int

	for _, line := range strings.Split(ps, "\n") {
		f := strings.Fields(line)
		if len(f) < 3 {
			continue
		}

		pid, err1 := strconv.Atoi(f[0])
		ppid, err2 := strconv.Atoi(f[1])
		if err1 != nil || err2 != nil {
			continue
		}

		procs[pid] = Process{PID: pid, PPID: ppid, Args: strings.Join(f[2:], " ")}
		order = append(order, pid)
	}

	var orphans []Process
	for _, pid := range order {
		p := procs[pid]
		if !isNamed(p.Args, "go-microvm-runner") {
			continue
		}

		if parent, ok := procs[p.PPID]; ok && isNamed(parent.Args, "loom-vm") {
			continue
		}

		orphans = append(orphans, p)
	}

	return orphans
}

// isNamed reports whether the program a command line runs has base name
// name. Only the first word is read, so a path with spaces in it is not
// matched, which costs a missed report and never a false one.
func isNamed(args, name string) bool {
	first, _, _ := strings.Cut(args, " ")

	return filepath.Base(first) == name
}
