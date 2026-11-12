//go:build linux

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
	offArgs1Lo = 24 // low 32 bits of args[1]
	offArgs2Lo = 32 // low 32 bits of args[2]
)

// Constants of the loopback program. They are spelled as the kernel's
// ABI values (and not only through the unix package) because the filter
// compares the raw words the kernel hands it.
const (
	// sockTypeMask is SOCK_TYPE_MASK: the kernel masks the type argument
	// of socket(2) with it, so the flag bits SOCK_NONBLOCK and
	// SOCK_CLOEXEC ride above it and must not change the verdict.
	sockTypeMask = 0xf
	// tcpULP is TCP_ULP, the setsockopt option that attaches an upper
	// layer protocol such as kernel TLS to a TCP socket.
	tcpULP = 31
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
	setsockopt uint32
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
		setsockopt: 54, // __NR_setsockopt, x86_64
		checkX32:   true,
	},
	"arm64": {
		auditArch:  unix.AUDIT_ARCH_AARCH64,
		socket:     198, // __NR_socket, aarch64
		socketpair: 199, // __NR_socketpair, aarch64
		setsockopt: 208, // __NR_setsockopt, aarch64
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

// NetworkLoopbackProgram returns the cBPF program for network mode
// loopback (protocol-change/112). It is NetworkOffProgram's program with
// two additions, and the same architecture check and x32 kill:
//
//  1. socket(2) also allows AF_INET with a type of SOCK_STREAM (after
//     masking SOCK_NONBLOCK and SOCK_CLOEXEC off) and a protocol of 0 or
//     IPPROTO_TCP. Every other AF_INET socket (datagram, raw, SCTP,
//     MPTCP), AF_INET6, AF_PACKET and every netlink family stay EPERM.
//     socketpair(2) stays AF_UNIX only;
//  2. setsockopt(2) with level IPPROTO_TCP and option TCP_ULP is EPERM,
//     which keeps the kernel TLS upgrade out of reach.
//
// Connecting and binding are not filtered, as in off mode: seccomp
// cannot read the address, and the fresh network namespace (only `lo`,
// no route elsewhere) is what bounds where a TCP socket can go. The
// program is only sound inside that namespace, which is why the jail
// refuses loopback mode on any path that does not create one.
func NetworkLoopbackProgram(goarch string) ([]bpf.Instruction, error) {
	spec, ok := archs[goarch]
	if !ok {
		return nil, fmt.Errorf("seccompf: unsupported architecture %q", goarch)
	}

	var prog []bpf.Instruction

	// Arch check, syscall number load and x32 kill: the same as the off
	// program, and deliberately repeated here rather than shared so the
	// off program's bytes cannot move with this one.
	prog = append(prog,
		bpf.LoadAbsolute{Off: offArch, Size: 4},
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: spec.auditArch, SkipTrue: 1},
		bpf.RetConstant{Val: retKillProcess},
		bpf.LoadAbsolute{Off: offNr, Size: 4},
	)
	if spec.checkX32 {
		prog = append(prog,
			bpf.JumpIf{Cond: bpf.JumpBitsNotSet, Val: x32SyscallBit, SkipTrue: 1},
			bpf.RetConstant{Val: retKillProcess},
		)
	}

	eperm := retErrno | uint32(unix.EPERM)

	// Instruction indices below are relative to the first dispatch
	// instruction, p0. Each skip counts instructions to jump over.
	prog = append(prog,
		// p0..p3: dispatch on the syscall number.
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: spec.socket, SkipTrue: 7},      // p0 -> p8
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: spec.socketpair, SkipTrue: 2},  // p1 -> p4
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: spec.setsockopt, SkipTrue: 16}, // p2 -> p19
		bpf.RetConstant{Val: retAllow},                                      // p3

		// p4..p7: socketpair allows AF_UNIX only.
		bpf.LoadAbsolute{Off: offArgs0Lo, Size: 4},                      // p4
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: unix.AF_UNIX, SkipTrue: 1}, // p5
		bpf.RetConstant{Val: eperm},                                     // p6
		bpf.RetConstant{Val: retAllow},                                  // p7

		// p8..p18: socket allows AF_UNIX, and AF_INET SOCK_STREAM with
		// protocol 0 or IPPROTO_TCP.
		bpf.LoadAbsolute{Off: offArgs0Lo, Size: 4},                           // p8
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: unix.AF_UNIX, SkipTrue: 8},      // p9 -> p18
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: unix.AF_INET, SkipFalse: 6},     // p10 -> p17
		bpf.LoadAbsolute{Off: offArgs1Lo, Size: 4},                           // p11
		bpf.ALUOpConstant{Op: bpf.ALUOpAnd, Val: sockTypeMask},               // p12
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: unix.SOCK_STREAM, SkipFalse: 3}, // p13 -> p17
		bpf.LoadAbsolute{Off: offArgs2Lo, Size: 4},                           // p14
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: 0, SkipTrue: 2},                 // p15 -> p18
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: unix.IPPROTO_TCP, SkipTrue: 1},  // p16 -> p18
		bpf.RetConstant{Val: eperm},                                          // p17
		bpf.RetConstant{Val: retAllow},                                       // p18

		// p19..p24: setsockopt refuses TCP_ULP at level IPPROTO_TCP.
		bpf.LoadAbsolute{Off: offArgs1Lo, Size: 4},                           // p19
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: unix.IPPROTO_TCP, SkipFalse: 2}, // p20 -> p23
		bpf.LoadAbsolute{Off: offArgs2Lo, Size: 4},                           // p21
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: tcpULP, SkipTrue: 1},            // p22 -> p24
		bpf.RetConstant{Val: retAllow},                                       // p23
		bpf.RetConstant{Val: eperm},                                          // p24
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
func Install() error { return install(NetworkOffProgram) }

// InstallLoopback is Install for network mode loopback: the same
// installation, with NetworkLoopbackProgram as the filter.
func InstallLoopback() error { return install(NetworkLoopbackProgram) }

func install(build func(goarch string) ([]bpf.Instruction, error)) error {
	prog, err := build(runtime.GOARCH)
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
