package seccompf

import (
	"encoding/binary"
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
}
