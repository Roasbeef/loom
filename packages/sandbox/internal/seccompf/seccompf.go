// Package seccompf builds and installs the network-off seccomp filter.
//
// Under network mode "off" the policy's intent is: no sockets to the
// outside world. The enforcement point is socket *creation*: seccomp
// cannot dereference the sockaddr pointer passed to connect(2), but it
// can read the integer domain argument of socket(2)/socketpair(2). If a
// process can never obtain an AF_INET/AF_INET6/AF_PACKET/... socket, it
// has nothing to connect(), bind(), or sendto() with — the helper
// constructs the child's fd table and environment, so no network fd can
// be smuggled in. AF_UNIX is allowed: it reaches only the filesystem
// view, which bwrap/Landlock already confine.
//
// The program is constructed as pure data (testable without a kernel)
// and installed with SECCOMP_FILTER_FLAG_TSYNC so it binds every thread
// of the multithreaded Go runtime, not just the calling one — without
// TSYNC another runtime thread could simply make the blocked syscall.
// Installation requires no_new_privs, which also guarantees the filter
// cannot be used to confuse a setuid binary. Both no_new_privs and the
// filter persist across execve, which is the whole trick: the helper
// restricts itself, then execs the untrusted target into the cage.
package seccompf

import (
	"fmt"
	"runtime"
	"unsafe"

	"golang.org/x/net/bpf"
	"golang.org/x/sys/unix"
)

// seccomp_data offsets (include/uapi/linux/seccomp.h). cBPF loads are
// 32-bit; args are 64-bit little-endian on the archs we support, so the
// low word of arg0 sits exactly at offArgs0Lo.
const (
	offNr      = 0  // u32 syscall number
	offArch    = 4  // u32 AUDIT_ARCH_*
	offArgs0Lo = 16 // low 32 bits of args[0]
)

// seccomp return values (include/uapi/linux/seccomp.h).
const (
	retAllow       = 0x7fff0000
	retErrno       = 0x00050000
	retKillProcess = 0x80000000
)

// x32SyscallBit marks the x32 ABI on amd64; those syscall numbers alias
// the 64-bit table with different semantics, so a filter that only
// matched the 64-bit numbers could be bypassed through x32. We kill the
// process on any x32 syscall rather than audit the alias table.
const x32SyscallBit = 0x40000000

// archSpec captures the per-architecture facts the filter needs.
type archSpec struct {
	auditArch  uint32
	socket     uint32
	socketpair uint32
	// checkX32 is true on amd64 where the x32 ABI must be rejected.
	checkX32 bool
}

// Syscall numbers are spelled as ABI literals rather than unix.SYS_*
// because those Go constants take the value of the *compile-time* GOARCH,
// while this table must describe every supported arch from any build. A
// test asserts the running arch's row against the unix package.
var archs = map[string]archSpec{
	"amd64": {
		auditArch:  unix.AUDIT_ARCH_X86_64,
		socket:     41, // __NR_socket, x86_64
		socketpair: 53, // __NR_socketpair, x86_64
		checkX32:   true,
	},
	"arm64": {
		auditArch:  unix.AUDIT_ARCH_AARCH64,
		socket:     198, // __NR_socket, aarch64
		socketpair: 199, // __NR_socketpair, aarch64
		checkX32:   false,
	},
}

// NetworkOffProgram returns the cBPF program enforcing network-off for
// the given GOARCH ("amd64" or "arm64"). The program:
//
//  1. kills the process if the audit arch is not the compile-time one
//     (a foreign-arch syscall would be interpreted against the wrong
//     syscall table, an old and well-known filter bypass);
//  2. on amd64, kills the process on any x32-ABI syscall;
//  3. for socket(2)/socketpair(2): allows AF_UNIX, fails everything
//     else with EPERM (an errno, not a kill, so tools that probe for
//     network and fall back keep working);
//  4. allows everything else — this is a network filter, not a general
//     syscall allowlist.
func NetworkOffProgram(goarch string) ([]bpf.Instruction, error) {
	spec, ok := archs[goarch]
	if !ok {
		return nil, fmt.Errorf("seccompf: unsupported architecture %q", goarch)
	}

	var prog []bpf.Instruction

	// [0] Load arch, kill if unexpected.
	prog = append(prog,
		bpf.LoadAbsolute{Off: offArch, Size: 4},
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: spec.auditArch, SkipTrue: 1},
		bpf.RetConstant{Val: retKillProcess},
	)

	// Load syscall number once; everything below dispatches on it.
	prog = append(prog, bpf.LoadAbsolute{Off: offNr, Size: 4})

	if spec.checkX32 {
		// Kill any x32-ABI syscall (nr with bit 30 set).
		prog = append(prog,
			bpf.JumpIf{Cond: bpf.JumpBitsNotSet, Val: x32SyscallBit, SkipTrue: 1},
			bpf.RetConstant{Val: retKillProcess},
		)
	}

	// socket/socketpair: inspect the domain argument.
	//
	//   if nr == socket     -> goto check_domain
	//   if nr == socketpair -> goto check_domain
	//   ret ALLOW
	// check_domain:
	//   A = args[0] low word
	//   if A == AF_UNIX -> ret ALLOW
	//   ret ERRNO(EPERM)
	prog = append(prog,
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: spec.socket, SkipTrue: 2},
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: spec.socketpair, SkipTrue: 1},
		bpf.RetConstant{Val: retAllow},
		bpf.LoadAbsolute{Off: offArgs0Lo, Size: 4},
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: unix.AF_UNIX, SkipTrue: 1},
		bpf.RetConstant{Val: retErrno | uint32(unix.EPERM)},
		bpf.RetConstant{Val: retAllow},
	)

	return prog, nil
}

// Supported probes whether the kernel supports seccomp filters without
// installing one: seccomp(SECCOMP_SET_MODE_FILTER, 0, NULL) returns
// EFAULT when the filter mode exists (it got as far as reading the
// program pointer) and EINVAL/ENOSYS when it does not.
func Supported() bool {
	_, _, errno := unix.Syscall(unix.SYS_SECCOMP, unix.SECCOMP_SET_MODE_FILTER, 0, 0)
	return errno == unix.EFAULT
}

// Install assembles and installs the network-off filter for the current
// architecture on every thread of the process. It sets no_new_privs
// first (mandatory for unprivileged seccomp, and desirable regardless:
// nothing execed from the jail may ever gain privilege).
func Install() error {
	prog, err := NetworkOffProgram(runtime.GOARCH)
	if err != nil {
		return err
	}
	raw, err := bpf.Assemble(prog)
	if err != nil {
		return fmt.Errorf("seccompf: assemble: %w", err)
	}
	filters := make([]unix.SockFilter, len(raw))
	for i, ins := range raw {
		filters[i] = unix.SockFilter{Code: ins.Op, Jt: ins.Jt, Jf: ins.Jf, K: ins.K}
	}
	fprog := unix.SockFprog{Len: uint16(len(filters)), Filter: &filters[0]}

	if err := unix.Prctl(unix.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0); err != nil {
		return fmt.Errorf("seccompf: set no_new_privs: %w", err)
	}
	// TSYNC: atomically apply to all threads; if any thread has an
	// incompatible filter the call fails with that thread's id, which we
	// surface as an error — a partially filtered process would be a lie.
	r1, _, errno := unix.Syscall(
		unix.SYS_SECCOMP, unix.SECCOMP_SET_MODE_FILTER,
		unix.SECCOMP_FILTER_FLAG_TSYNC, uintptr(unsafe.Pointer(&fprog)),
	)
	if errno != 0 {
		return fmt.Errorf("seccompf: seccomp(SET_MODE_FILTER, TSYNC): %w", errno)
	}
	if r1 != 0 {
		return fmt.Errorf("seccompf: TSYNC could not synchronize thread %d", r1)
	}
	return nil
}
