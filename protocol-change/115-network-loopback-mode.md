# protocol-change/115: a loopback-only network mode for the jail

**Status**: PROPOSED 2026-11-12, built in the PR that adds this file.
**Affects**: the `network.mode` vocabulary of `SandboxPolicyV1` (Part 1.4),
which gains the string `"loopback"` at policy version 2; `broker/policy`'s
`NetworkPolicy`, which gains the constructor `NetworkLoopback`; the client's
JSON vocabulary for grants and approvals (`client/grants`, `client/protocol`,
`session_view/approval`), which gains the same string; the helper's seccomp
programs and its refusal rules. No version number moves.
**Raised by**: aegis (lightninglabs/aegis), a security-review service built
on Loom. Its design is `docs/design-notes/itest-proof-arm.md` there, sections
1, 2 and 9: a proof that needs two daemons talking over real sockets cannot
run in a jail whose `socket(2)` refuses every IP socket.
**Builds on**: [004](004-sandbox-policy-explicit-mounts.md) (the policy
version and the strict decoder), ADR-003 (Rule Zero), ADR-006 (what Darwin
enforces).

## Problem

Network mode `off` gives a jail a fresh network namespace and a seccomp
program that fails every non-`AF_UNIX` `socket(2)` with `EPERM`. A test that
starts a process that listens on TCP, and a second process that connects to
it, cannot run. The namespace is not what stops it. bubblewrap runs
`loopback_setup()` when `--unshare-net` is given, so `lo` is already up with
`127.0.0.1/8` in every jail, and the comment in `bwrap.go` that called the
namespace "interface-less" was wrong. The only barrier to using that
loopback is the filter.

An embedding host that has decided to accept the cost for one kind of run
needs a mode that opens exactly that and nothing wider. `full` is the only
mode that does, and it removes the namespace's job and the filter together.

## Decision

A fourth network mode, `loopback`, ordered `off < loopback < proxy < full`.

**Wire.** `{mode: "loopback"}`, with no other key, as `off` and `full` are.
The policy version stays 2. A helper that predates the mode rejects the
policy at decode ("unknown network mode") and runs nothing, which is the
fail-closed answer; a broker that predates it cannot send it. A new
cross-language fixture, `sandbox_policy_4_network_loopback.bin`, is written
by the Gleam golden test and decoded by the Go suite.

**Gleam.** `NetworkPolicy` gains `NetworkLoopback`. `meet` takes the lower
rank, `join` the higher, `network_exceeds` follows the ranks, except that a loopback request also
exceeds a `proxy` grant, because a host allowlist does not bound it and
proxy is enforced as `off` (the client's approval ceiling agrees), and `narrow_unenforceable`
leaves it alone: it is enforceable where the helper can enforce it and the
helper refuses it everywhere else, so there is no narrower form to fall back
to. The required-layer matrix demands `seccomp-net` for it, as for `off`.

**Helper.** `BlocksDirectNetwork` is true for it: the jail still has no
reach beyond its own `lo`. Stage 2 installs a second program, built from the
same architecture check and x32 kill as the off program, which allows what
the off program allows and also `socket(AF_INET, type, protocol)` when the
type, masked with `0xf` (so `SOCK_NONBLOCK` and `SOCK_CLOEXEC` do not
matter), is `SOCK_STREAM` and the protocol is 0 or `IPPROTO_TCP`. It refuses
`setsockopt(IPPROTO_TCP, TCP_ULP)`. Everything else about sockets stays
`EPERM`: `AF_INET6`, datagram, raw, SCTP and MPTCP, `AF_PACKET`, every
netlink family, and `socketpair` outside `AF_UNIX`. The off program is
unchanged, and a test pins its instructions.

**Where it runs.** Only on Linux under bwrap. `jail.Start` refuses the mode,
naming it, when there is no bwrap (the degraded path runs in the host's
network namespace, where this filter would hand out host sockets) and on
Darwin (Seatbelt has no network namespace; its profile is untouched and the
mode is unenforced there). It never narrows to `off` in silence.

**Preconditions.** The mode runs only in a jail that holds no capabilities
and cannot create a nested user namespace. For a loopback policy alone the
bwrap argv requires its own user namespace (`--unshare-user`, not
`--unshare-user-try`) and adds `--disable-userns` and `--cap-drop ALL`; the
off and full argv are unchanged. The helper probes bwrap once at startup
with exactly those flags, and `jail.Start` refuses the mode, naming it, when
the probe fails. A hand-built feature set that was not probed is refused.

**Who selects it.** Nothing in Loom does. No tool, profile or configuration
requests it, and `permissions.network` still accepts only `full`. It exists
for an embedding host to put in a policy it sends.

## Alternatives

*`full` inside the existing fresh namespace.* The same namespace with no
filter. It would also admit UDP, raw sockets and netlink, and "no other
interface can appear" would then rest on dropped capabilities alone.
Rejected.

*IPv6.* bwrap adds an IPv4 address only, Go falls back to IPv4 when the
IPv6 probe fails, and it would add a second address family to the kernel
surface for a need nobody showed. Refused for now.

*A policy version bump.* An old helper already refuses an unknown mode, and
a bump would break every sender that does not use the mode. Not taken.

*Filtering `connect` and `bind`.* seccomp cannot read the sockaddr. The
namespace bounds the destination, and a connect outside `127.0.0.0/8` fails
with `ENETUNREACH`.

## Cost

The host kernel's TCP code becomes reachable from jailed code, through
`socket`, `bind`, `listen`, `connect`, `accept`, `sendmsg` and `setsockopt`
on IPv4 stream sockets. That is new kernel attack surface for
model-influenced code, and it is the whole cost. Netlink, raw and packet
sockets, UDP, SCTP, MPTCP and the kernel TLS upgrade stay closed. The
namespace is fresh per execution, so the jail cannot reach the host's
loopback, the runner's address or another jail's listeners. The jail's
ceilings are unchanged, and there is none on descriptors, ports or
connections; sockets are charged to the memory cgroup where one is attached.

One thing this change does not fix, and it is true of `off` today: a host
that runs lnd's integration tests needs a `NETLINK_ROUTE` socket. See the
evidence below.

The seccomp programs for `off` and `loopback` both fail `io_uring_setup`,
`io_uring_enter` and `io_uring_register` with `EPERM`. The network programs
constrain socket creation by filtering the `socket` system calls, and
io_uring is a second way to ask the kernel for the same operations that the
filter does not see; standard container profiles deny it for the same
reason. This changes the `off` program, which a test pins.

## Evidence

The permitted set was measured, not guessed. One case (`channel force
close-anchor`, btcd backend, lnd at `69ab4e9acebe`) was run in a
`golang:1.27.3` container on linux/arm64 under
`strace -f -e trace=socket,socketpair,setsockopt`. It passes, and makes these
calls, by process:

- `itest.test`: `AF_INET` stream (protocol 0 and `IPPROTO_TCP`); `AF_INET6`
  stream (protocol 0 and `IPPROTO_TCP`); `AF_NETLINK`/`SOCK_RAW`/`NETLINK_ROUTE`
  twice.
- `btcd-itest`: `AF_INET` stream only.
- `lnd-itest`: `AF_INET` stream; `AF_INET6` stream; `AF_INET` and `AF_INET6`
  datagram, about 225 each, with `SO_BROADCAST`; `AF_NETLINK`/`NETLINK_ROUTE`
  twice.
- No `TCP_ULP` anywhere. The socket options are `SO_KEEPALIVE`,
  `SO_REUSEADDR`, `SO_BROADCAST`, `IPV6_V6ONLY`, `TCP_NODELAY`,
  `TCP_KEEP*` and `TCP_USER_TIMEOUT`.

So three things in the trace are outside the allowed set: IPv6 stream
sockets, UDP sockets and the route netlink socket. The filter was not
widened for them. Re-run under the real loopback program in a fresh network
namespace with `lo` up:

- With the program as specified, the case fails before it starts a node:
  `rpctest.New` in `itest.test` makes a `NETLINK_ROUTE` socket (Go's
  `net.InterfaceAddrs`) and gets `EPERM` ("route ip+net: netlinkrib:
  operation not permitted").
- With the program as specified plus `socket(AF_NETLINK, *, NETLINK_ROUTE)`
  allowed, the case passes. The UDP sockets in `lnd-itest` and the IPv6
  stream sockets in `itest.test` fail with `EPERM` and nothing depends on
  them.

Whether to admit `NETLINK_ROUTE` is a decision this proposal leaves to the
owner. The proposal as written refuses every netlink family, which means an
lnd integration test does not run under it.

## Tests

The program as data on both architectures, with each case a
`(syscall, domain, type, protocol)` and a verdict, including the masked
flags, `AF_INET6`, datagram, raw, SCTP, MPTCP, every netlink family,
`socketpair` and `TCP_ULP`, and that the off program is unchanged. The
lattice for every pair of the four modes, both as meet and as join. The
codec round trip, the golden fixture and the rejection of a stray key.
Refusal of the mode on Darwin, on an unsupported platform and without bwrap.
On a Linux host with bwrap, in a real jail: a listener on `127.0.0.1` and a
connection to it; a host listener at the same port is refused; a connect to a
non-loopback address fails; UDP, IPv6, raw and netlink sockets and `TCP_ULP`
get `EPERM`; two jails cannot reach each other; and an `off` jail still
refuses the TCP socket.
