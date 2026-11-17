//go:build linux

package seccompf

import (
	"encoding/binary"
	"reflect"
	"runtime"
	"testing"

	"golang.org/x/net/bpf"
	"golang.org/x/sys/unix"
)

// seccompData builds a synthetic struct seccomp_data for running the
// filter in the x/net/bpf interpreter. One deliberate twist: the kernel
// evaluates seccomp cBPF with *native-endian* loads over seccomp_data,
// while the x/net/bpf VM implements classic packet BPF with big-endian
// loads. The program's logic (compare loaded words against constants)
// is endian-agnostic, so we encode each field big-endian here to make
// the VM observe exactly the values the kernel would. For arg0 the
// kernel reads the low 32 bits of the 64-bit slot at offset 16; we
// place those low 32 bits where the program's 4-byte load looks.
func seccompData(nr uint32, arch uint32, arg0 uint64) []byte {
	buf := make([]byte, 64)
	binary.BigEndian.PutUint32(buf[0:], nr)
	binary.BigEndian.PutUint32(buf[4:], arch)
	binary.BigEndian.PutUint32(buf[16:], uint32(arg0)) // low word, as the kernel loads it
	return buf
}

// seccompDataArgs is seccompData with the first three syscall arguments,
// for the programs that read the type, protocol, level or option words.
func seccompDataArgs(nr, arch uint32, a0, a1, a2 uint64) []byte {
	buf := seccompData(nr, arch, a0)
	binary.BigEndian.PutUint32(buf[24:], uint32(a1))
	binary.BigEndian.PutUint32(buf[32:], uint32(a2))
	return buf
}

// runFilter executes the program in x/net/bpf's interpreter — the same
// instruction semantics the kernel applies — and returns the verdict.
func runFilter(t *testing.T, prog []bpf.Instruction, data []byte) uint32 {
	t.Helper()
	vm, err := bpf.NewVM(prog)
	if err != nil {
		t.Fatalf("NewVM: %v", err)
	}
	verdict, err := vm.Run(data)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	return uint32(verdict)
}

func TestNetworkOffProgramAmd64(t *testing.T) {
	prog, err := NetworkOffProgram("amd64")
	if err != nil {
		t.Fatalf("NetworkOffProgram: %v", err)
	}
	const (
		arch      = unix.AUDIT_ARCH_X86_64
		sysSocket = 41
		sysSockpr = 53
		sysRead   = 0
		sysExecve = 59
		epermDeny = retErrno | uint32(unix.EPERM)
	)
	cases := []struct {
		name string
		data []byte
		want uint32
	}{
		{"AF_INET socket denied", seccompData(sysSocket, arch, unix.AF_INET), epermDeny},
		{"AF_INET6 socket denied", seccompData(sysSocket, arch, unix.AF_INET6), epermDeny},
		{"AF_NETLINK socket denied", seccompData(sysSocket, arch, unix.AF_NETLINK), epermDeny},
		{"AF_PACKET socket denied", seccompData(sysSocket, arch, unix.AF_PACKET), epermDeny},
		{"AF_UNIX socket allowed", seccompData(sysSocket, arch, unix.AF_UNIX), retAllow},
		{"AF_UNIX high-bits arg still unix after kernel truncation", seccompData(sysSocket, arch, 0xdead00000000|unix.AF_UNIX), retAllow},
		{"AF_INET socketpair denied", seccompData(sysSockpr, arch, unix.AF_INET), epermDeny},
		{"AF_UNIX socketpair allowed", seccompData(sysSockpr, arch, unix.AF_UNIX), retAllow},
		{"read allowed", seccompData(sysRead, arch, 12345), retAllow},
		{"execve allowed (restrict-then-exec must work)", seccompData(sysExecve, arch, 0), retAllow},
		{"foreign arch killed", seccompData(sysRead, unix.AUDIT_ARCH_I386, 0), retKillProcess},
		{"x32 ABI killed", seccompData(x32SyscallBit|sysSocket, arch, unix.AF_UNIX), retKillProcess},
		{"x32 read killed", seccompData(x32SyscallBit|sysRead, arch, 0), retKillProcess},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := runFilter(t, prog, tc.data); got != tc.want {
				t.Fatalf("verdict = %#x, want %#x", got, tc.want)
			}
		})
	}
}

func TestNetworkOffProgramArm64(t *testing.T) {
	prog, err := NetworkOffProgram("arm64")
	if err != nil {
		t.Fatalf("NetworkOffProgram: %v", err)
	}
	const (
		arch      = unix.AUDIT_ARCH_AARCH64
		sysSocket = 198
	)
	if got := runFilter(t, prog, seccompData(sysSocket, arch, unix.AF_INET)); got != retErrno|uint32(unix.EPERM) {
		t.Fatalf("AF_INET socket verdict = %#x, want EPERM errno", got)
	}
	if got := runFilter(t, prog, seccompData(sysSocket, arch, unix.AF_UNIX)); got != retAllow {
		t.Fatalf("AF_UNIX socket verdict = %#x, want allow", got)
	}
	if got := runFilter(t, prog, seccompData(sysSocket, unix.AUDIT_ARCH_X86_64, unix.AF_INET)); got != retKillProcess {
		t.Fatalf("foreign arch verdict = %#x, want kill", got)
	}
}

func TestUnsupportedArch(t *testing.T) {
	if _, err := NetworkOffProgram("riscv64"); err == nil {
		t.Fatal("unsupported arch accepted")
	}
}

func TestProgramAssembles(t *testing.T) {
	for arch := range archs {
		for name, build := range map[string]func(string) ([]bpf.Instruction, error){
			"off": NetworkOffProgram, "loopback": NetworkLoopbackProgram,
		} {
			prog, err := build(arch)
			if err != nil {
				t.Fatalf("%s %s: %v", name, arch, err)
			}
			raw, err := bpf.Assemble(prog)
			if err != nil {
				t.Fatalf("%s %s: assemble: %v", name, arch, err)
			}
			if len(raw) == 0 || len(raw) > 4096 {
				t.Fatalf("%s %s: implausible program length %d", name, arch, len(raw))
			}
		}
		prog, err := NetworkOffProgram(arch)
		if err != nil {
			t.Fatalf("%s: %v", arch, err)
		}
		raw, err := bpf.Assemble(prog)
		if err != nil {
			t.Fatalf("%s: assemble: %v", arch, err)
		}
		if len(raw) == 0 || len(raw) > 4096 {
			t.Fatalf("%s: implausible program length %d", arch, len(raw))
		}
	}
}

// The literal syscall numbers in the arch table must agree with the
// unix package for whatever arch this test actually compiles on.
func TestArchTableMatchesUnixPackage(t *testing.T) {
	spec, ok := archs[runtime.GOARCH]
	if !ok {
		t.Skipf("no arch table entry for %s", runtime.GOARCH)
	}
	if spec.socket != unix.SYS_SOCKET {
		t.Fatalf("socket nr %d != unix.SYS_SOCKET %d", spec.socket, unix.SYS_SOCKET)
	}
	if spec.socketpair != unix.SYS_SOCKETPAIR {
		t.Fatalf("socketpair nr %d != unix.SYS_SOCKETPAIR %d", spec.socketpair, unix.SYS_SOCKETPAIR)
	}
	if unix.SYS_IO_URING_SETUP != sysIoUringSetup ||
		unix.SYS_IO_URING_ENTER != sysIoUringSetup+1 ||
		unix.SYS_IO_URING_REGISTER != sysIoUringRegister {
		t.Fatalf("io_uring numbers disagree with the unix package")
	}
	if spec.setsockopt != unix.SYS_SETSOCKOPT {
		t.Fatalf("setsockopt nr %d != unix.SYS_SETSOCKOPT %d", spec.setsockopt, unix.SYS_SETSOCKOPT)
	}
}

// The loopback program, as data: each case is one syscall as the kernel
// would present it, with the verdict the mode promises. The type column
// is the raw argument, flags included, because the masking is the claim.
func TestNetworkLoopbackProgramAmd64(t *testing.T) {
	prog, err := NetworkLoopbackProgram("amd64")
	if err != nil {
		t.Fatalf("NetworkLoopbackProgram: %v", err)
	}
	const (
		arch         = unix.AUDIT_ARCH_X86_64
		sysSocket    = 41
		sysSockpr    = 53
		sysSetsock   = 54
		sysRead      = 0
		sysExecve    = 59
		sockNonblock = 0o4000
		sockCloexec  = 0o2000000
		epermDeny    = retErrno | uint32(unix.EPERM)
	)
	sock := func(domain, typ, proto uint64) []byte {
		return seccompDataArgs(sysSocket, arch, domain, typ, proto)
	}
	pair := func(domain, typ, proto uint64) []byte {
		return seccompDataArgs(sysSockpr, arch, domain, typ, proto)
	}
	setopt := func(level, opt uint64) []byte {
		return seccompDataArgs(sysSetsock, arch, 3, level, opt)
	}
	cases := []struct {
		name string
		data []byte
		want uint32
	}{
		// Allowed: AF_UNIX as in off mode, and IPv4 TCP.
		{"AF_UNIX stream", sock(unix.AF_UNIX, unix.SOCK_STREAM, 0), retAllow},
		{"AF_UNIX dgram", sock(unix.AF_UNIX, unix.SOCK_DGRAM, 0), retAllow},
		{"AF_INET stream proto 0", sock(unix.AF_INET, unix.SOCK_STREAM, 0), retAllow},
		{"AF_INET stream IPPROTO_TCP", sock(unix.AF_INET, unix.SOCK_STREAM, unix.IPPROTO_TCP), retAllow},
		{"AF_INET stream nonblock", sock(unix.AF_INET, unix.SOCK_STREAM|sockNonblock, 0), retAllow},
		{"AF_INET stream cloexec", sock(unix.AF_INET, unix.SOCK_STREAM|sockCloexec, 0), retAllow},
		{"AF_INET stream nonblock cloexec tcp", sock(unix.AF_INET, unix.SOCK_STREAM|sockNonblock|sockCloexec, unix.IPPROTO_TCP), retAllow},
		{"AF_INET high bits of args are not read", sock(0xdead00000000|unix.AF_INET, 0xbeef00000000|unix.SOCK_STREAM, 0xcafe00000000), retAllow},

		// Refused: everything else about sockets.
		{"AF_INET dgram", sock(unix.AF_INET, unix.SOCK_DGRAM, 0), epermDeny},
		{"AF_INET dgram IPPROTO_UDP", sock(unix.AF_INET, unix.SOCK_DGRAM, unix.IPPROTO_UDP), epermDeny},
		{"AF_INET dgram nonblock", sock(unix.AF_INET, unix.SOCK_DGRAM|sockNonblock, 0), epermDeny},
		{"AF_INET raw", sock(unix.AF_INET, unix.SOCK_RAW, unix.IPPROTO_RAW), epermDeny},
		{"AF_INET raw ICMP", sock(unix.AF_INET, unix.SOCK_RAW, unix.IPPROTO_ICMP), epermDeny},
		{"AF_INET seqpacket SCTP", sock(unix.AF_INET, unix.SOCK_SEQPACKET, unix.IPPROTO_SCTP), epermDeny},
		{"AF_INET stream SCTP", sock(unix.AF_INET, unix.SOCK_STREAM, unix.IPPROTO_SCTP), epermDeny},
		{"AF_INET stream MPTCP", sock(unix.AF_INET, unix.SOCK_STREAM, unix.IPPROTO_MPTCP), epermDeny},
		{"AF_INET stream UDP protocol", sock(unix.AF_INET, unix.SOCK_STREAM, unix.IPPROTO_UDP), epermDeny},
		{"AF_INET packet-type 10", sock(unix.AF_INET, 10, 0), epermDeny},
		{"AF_INET6 stream", sock(unix.AF_INET6, unix.SOCK_STREAM, 0), epermDeny},
		{"AF_INET6 stream tcp", sock(unix.AF_INET6, unix.SOCK_STREAM, unix.IPPROTO_TCP), epermDeny},
		{"AF_INET6 dgram", sock(unix.AF_INET6, unix.SOCK_DGRAM, 0), epermDeny},
		{"AF_PACKET", sock(unix.AF_PACKET, unix.SOCK_RAW, 0), epermDeny},
		{"AF_NETLINK route", sock(unix.AF_NETLINK, unix.SOCK_RAW, unix.NETLINK_ROUTE), epermDeny},
		{"AF_NETLINK generic", sock(unix.AF_NETLINK, unix.SOCK_RAW, unix.NETLINK_GENERIC), epermDeny},
		{"AF_NETLINK netfilter", sock(unix.AF_NETLINK, unix.SOCK_RAW, unix.NETLINK_NETFILTER), epermDeny},
		{"AF_NETLINK diag", sock(unix.AF_NETLINK, unix.SOCK_DGRAM, unix.NETLINK_SOCK_DIAG), epermDeny},
		{"AF_NETLINK stream-typed", sock(unix.AF_NETLINK, unix.SOCK_STREAM, 0), epermDeny},
		{"AF_VSOCK stream", sock(unix.AF_VSOCK, unix.SOCK_STREAM, 0), epermDeny},
		{"AF_ALG", sock(unix.AF_ALG, unix.SOCK_SEQPACKET, 0), epermDeny},
		{"AF_TIPC", sock(unix.AF_TIPC, unix.SOCK_STREAM, 0), epermDeny},

		// socketpair stays AF_UNIX only, whatever the type.
		{"socketpair AF_UNIX", pair(unix.AF_UNIX, unix.SOCK_STREAM, 0), retAllow},
		{"socketpair AF_INET stream", pair(unix.AF_INET, unix.SOCK_STREAM, 0), epermDeny},
		{"socketpair AF_INET stream tcp", pair(unix.AF_INET, unix.SOCK_STREAM, unix.IPPROTO_TCP), epermDeny},
		{"socketpair AF_INET6", pair(unix.AF_INET6, unix.SOCK_STREAM, 0), epermDeny},
		{"socketpair AF_NETLINK", pair(unix.AF_NETLINK, unix.SOCK_RAW, 0), epermDeny},

		// setsockopt: only TCP_ULP at the TCP level is refused.
		{"setsockopt TCP_ULP", setopt(unix.IPPROTO_TCP, tcpULP), epermDeny},
		{"setsockopt TCP_NODELAY", setopt(unix.IPPROTO_TCP, unix.TCP_NODELAY), retAllow},
		{"setsockopt TCP_KEEPIDLE", setopt(unix.IPPROTO_TCP, unix.TCP_KEEPIDLE), retAllow},
		{"setsockopt SOL_SOCKET SO_REUSEADDR", setopt(unix.SOL_SOCKET, unix.SO_REUSEADDR), retAllow},
		{"setsockopt option 31 at another level", setopt(unix.IPPROTO_IP, tcpULP), retAllow},
		{"setsockopt level 6 high bits ignored for TCP_ULP", setopt(0xdead00000000|unix.IPPROTO_TCP, 0xbeef00000000|tcpULP), epermDeny},

		// Unrelated syscalls and the guards, as in off mode.
		{"read allowed", seccompData(sysRead, arch, 12345), retAllow},
		{"execve allowed", seccompData(sysExecve, arch, 0), retAllow},
		{"foreign arch killed", seccompData(sysRead, unix.AUDIT_ARCH_I386, 0), retKillProcess},
		{"x32 read killed", seccompData(x32SyscallBit|sysRead, arch, 0), retKillProcess},
		{"x32 socket AF_INET stream killed", seccompData(x32SyscallBit|sysSocket, arch, unix.AF_INET), retKillProcess},
		{"x32 setsockopt killed", seccompData(x32SyscallBit|sysSetsock, arch, 0), retKillProcess},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := runFilter(t, prog, tc.data); got != tc.want {
				t.Fatalf("verdict = %#x, want %#x", got, tc.want)
			}
		})
	}
}

func TestNetworkLoopbackProgramArm64(t *testing.T) {
	prog, err := NetworkLoopbackProgram("arm64")
	if err != nil {
		t.Fatalf("NetworkLoopbackProgram: %v", err)
	}
	const (
		arch       = unix.AUDIT_ARCH_AARCH64
		sysSocket  = 198
		sysSockpr  = 199
		sysSetsock = 208
		eperm      = retErrno | uint32(unix.EPERM)
	)
	cases := []struct {
		name string
		data []byte
		want uint32
	}{
		{"AF_INET stream", seccompDataArgs(sysSocket, arch, unix.AF_INET, unix.SOCK_STREAM, 0), retAllow},
		{"AF_INET dgram", seccompDataArgs(sysSocket, arch, unix.AF_INET, unix.SOCK_DGRAM, 0), eperm},
		{"AF_INET6 stream", seccompDataArgs(sysSocket, arch, unix.AF_INET6, unix.SOCK_STREAM, 0), eperm},
		{"AF_NETLINK", seccompDataArgs(sysSocket, arch, unix.AF_NETLINK, unix.SOCK_RAW, 0), eperm},
		{"socketpair AF_INET", seccompDataArgs(sysSockpr, arch, unix.AF_INET, unix.SOCK_STREAM, 0), eperm},
		{"TCP_ULP", seccompDataArgs(sysSetsock, arch, 3, unix.IPPROTO_TCP, tcpULP), eperm},
		{"TCP_NODELAY", seccompDataArgs(sysSetsock, arch, 3, unix.IPPROTO_TCP, unix.TCP_NODELAY), retAllow},
		{"foreign arch killed", seccompDataArgs(sysSocket, unix.AUDIT_ARCH_X86_64, unix.AF_INET, unix.SOCK_STREAM, 0), retKillProcess},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := runFilter(t, prog, tc.data); got != tc.want {
				t.Fatalf("verdict = %#x, want %#x", got, tc.want)
			}
		})
	}
}

func TestLoopbackUnsupportedArch(t *testing.T) {
	if _, err := NetworkLoopbackProgram("riscv64"); err == nil {
		t.Fatal("unsupported arch accepted")
	}
}

// The off program must not move without a deliberate edit here: the
// tests above check its verdicts, and this one pins its instructions, so
// a change that kept every verdict but altered the program is still seen.
// It last changed to add the io_uring denial.
// The expected lists are written out from the filter's documented shape,
// independently of the builder.
func TestNetworkOffProgramIsUnchanged(t *testing.T) {
	prologue := func(arch uint32) []bpf.Instruction {
		return []bpf.Instruction{
			bpf.LoadAbsolute{Off: 4, Size: 4},
			bpf.JumpIf{Cond: bpf.JumpEqual, Val: arch, SkipTrue: 1},
			bpf.RetConstant{Val: 0x80000000},
			bpf.LoadAbsolute{Off: 0, Size: 4},
		}
	}
	tail := func(socket, socketpair uint32) []bpf.Instruction {
		return []bpf.Instruction{
			// Added deliberately with the io_uring denial: 425 to 427
			// fail with EPERM in every mode.
			bpf.JumpIf{Cond: bpf.JumpGreaterOrEqual, Val: 425, SkipFalse: 2},
			bpf.JumpIf{Cond: bpf.JumpGreaterThan, Val: 427, SkipTrue: 1},
			bpf.RetConstant{Val: 0x00050000 | 1},
			bpf.JumpIf{Cond: bpf.JumpEqual, Val: socket, SkipTrue: 2},
			bpf.JumpIf{Cond: bpf.JumpEqual, Val: socketpair, SkipTrue: 1},
			bpf.RetConstant{Val: 0x7fff0000},
			bpf.LoadAbsolute{Off: 16, Size: 4},
			bpf.JumpIf{Cond: bpf.JumpEqual, Val: 1, SkipTrue: 1},
			bpf.RetConstant{Val: 0x00050000 | 1},
			bpf.RetConstant{Val: 0x7fff0000},
		}
	}
	x32 := []bpf.Instruction{
		bpf.JumpIf{Cond: bpf.JumpBitsNotSet, Val: 0x40000000, SkipTrue: 1},
		bpf.RetConstant{Val: 0x80000000},
	}
	want := map[string][]bpf.Instruction{
		"amd64": append(append(prologue(0xc000003e), x32...), tail(41, 53)...),
		"arm64": append(prologue(0xc00000b7), tail(198, 199)...),
	}
	for arch, wantProg := range want {
		got, err := NetworkOffProgram(arch)
		if err != nil {
			t.Fatalf("%s: %v", arch, err)
		}
		gotRaw, err := bpf.Assemble(got)
		if err != nil {
			t.Fatalf("%s: assemble: %v", arch, err)
		}
		wantRaw, err := bpf.Assemble(wantProg)
		if err != nil {
			t.Fatalf("%s: assemble want: %v", arch, err)
		}
		if !reflect.DeepEqual(gotRaw, wantRaw) {
			t.Fatalf("%s: the off program changed:\n got %v\nwant %v", arch, gotRaw, wantRaw)
		}
	}
}

// io_uring_setup, io_uring_enter and io_uring_register fail with EPERM in
// every mode, on both architectures, and the neighbouring numbers do not.
func TestIoUringDeniedInEveryProgram(t *testing.T) {
	builders := map[string]func(string) ([]bpf.Instruction, error){
		"off": NetworkOffProgram, "loopback": NetworkLoopbackProgram,
	}
	archData := map[string]uint32{
		"amd64": unix.AUDIT_ARCH_X86_64, "arm64": unix.AUDIT_ARCH_AARCH64,
	}
	for name, build := range builders {
		for goarch, audit := range archData {
			prog, err := build(goarch)
			if err != nil {
				t.Fatal(err)
			}
			for nr, want := range map[uint32]uint32{
				424: retAllow, 425: retErrno | uint32(unix.EPERM),
				426: retErrno | uint32(unix.EPERM), 427: retErrno | uint32(unix.EPERM),
				428: retAllow,
			} {
				if got := runFilter(t, prog, seccompData(nr, audit, 0)); got != want {
					t.Errorf("%s %s nr %d: verdict %#x, want %#x", name, goarch, nr, got, want)
				}
			}
		}
	}
}
