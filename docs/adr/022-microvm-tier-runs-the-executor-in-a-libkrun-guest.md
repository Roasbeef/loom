# ADR-022: the microVM tier runs the executor in a libkrun guest, through go-microvm

**Status**: accepted · **Date**: 2026-11-01 · **Supersedes**: nothing ·
**Spec ref**: Part 5 track 3 (microVM tier), track 10 (egress proxy) ·
**Issue**: #85

## The question

The [microVM design note](../design-notes/microvm-executor-tier.md) ended
with four prerequisites. Two have landed: explicit mounts
(`protocol-change/004`) and the driver-scoped layer demand
(`required_layers_for_features`). The other two were open: what a VM holds
when `fs_*` and `bash` must keep seeing the same files, and which hypervisor
the tier drives first and how. Issue #85's status comment of 2026-11-01
proposed answers to both. This record makes them decisions and adds what a
real boot on an Apple Silicon Mac measured.

## Measured

A throwaway launcher booted Alpine 3.22 under libkrun 1.19.4 and libkrunfw
5.5.0 through go-microvm v0.0.37 on macOS 27.2 (arm64, Hypervisor.framework).
The cross-compiled `loom-exec` ran inside the guest.

- **Boot.** `microvm.Run` returned in 2.0 to 2.4 s across six boots, with the
  image already cached. The guest kernel is 6.12.91.
- **The stock kernel has no Landlock.** `loom-exec --self-test` in the guest
  reports `landlock unavailable: function not implemented`, and
  `/sys/kernel/security` does not exist. cgroup v2 with the `memory` and
  `pids` controllers is present, and user namespaces are enabled.
- **bwrap restores the rest.** With bubblewrap 0.12.0 installed in the guest,
  the self-test run as uid 1000 enforces nine probes: writes outside
  `writable_roots`, protected paths, the daemon state root, the minimal base
  view, network off, the environment allowlist, the output cap, the orphan
  reap and the `setsid` escape. The pids probe skips until the helper runs
  inside a delegated cgroup subtree, and the self-test's own message says
  how to put it there. The unvetted-beam probe skips because the guest has
  no Erlang.
- **Default networking reaches the host.** With no network provider
  configured, libkrun uses TSI: the guest has no `eth0`, its sockets are
  carried out by the VMM process, and a request to `127.0.0.1:18777` inside
  the guest reached an HTTP server bound to the host's loopback.
- **An explicit provider closes it.** With go-microvm's hosted provider and
  an egress policy, the guest gets `eth0` at 192.168.127.2 by DHCP. Host
  loopback is refused, the gateway does not forward to host ports, an
  allowlisted host connects, and any other name returns NXDOMAIN.

## Decision

**D1. A VM holds a whole executor, not a helper.** The guest runs the
executor node: the broker, the helper pool, `fs_*`, `bash`, code mode, jobs
and LSP (`docs/architecture/distributed.md`, "What runs on the executor").
The orchestrator stays on the host. `fs_*` and `bash` share the guest's
inodes, so hashline plans keep their meaning, and no host workspace is shared
into the guest. The checkout arrives by copy-in and work leaves as git
bundles, the transport #1137 rules state moves by. A VM is booted per
executor placement, not per execution, so boot latency is paid once per
session and a snapshot is an optimisation rather than part of the minimum
driver.

**D2. `loom-exec` runs unchanged inside the guest.** The VM separates a
session from the host and from other sessions. The jail separates model code
from the executor node inside the same guest, which holds the tools' secrets,
the distribution credentials and the link to the orchestrator. The jail's
layer tags stay true because a real kernel, the guest's, applies them. The
launcher reports its VM layers alongside them; nothing is relabelled.

**D3. The guest kernel is a custom libkrunfw build with Landlock.** The
broker demands `landlock` on every Linux execution
(`packages/broker/src/broker/exec.gleam:1802`). The stock kernel would make
every `FullEnforcement` execution in the guest refuse, and relabelling some
other mechanism as `landlock` is the lie #54 was filed about. The demanded
set does not change. The tier ships its own libkrunfw with
`CONFIG_SECURITY_LANDLOCK` and `securityfs`, and until it does, the tier
refuses under `FullEnforcement` instead of claiming the layer.

**D4. Guest networking is always an explicit host-side stack with
default-deny egress.** The launcher never starts a guest on TSI. Every guest
gets go-microvm's hosted provider and an egress policy, empty when the
policy says the network is off. That allowlist is where `Proxy(allowlist)`
gets its enforcement, the case `narrow_unenforceable`
(`packages/broker/src/broker/policy.gleam:673`) narrows to `NetworkOff`
today. The VM-tier self-test probes, from inside a booted guest, that host
loopback is unreachable and that a name off the allowlist does not resolve.
A launcher change that lost the provider would fail that probe rather than
pass silently.

**D5. libkrun first, driven through `stacklok/go-microvm`; Firecracker
second.** libkrun runs on Linux/KVM and macOS/HVF from one code path.
go-microvm (Apache-2.0) is a CGO-free Go library over a separate cgo runner
binary that links libkrun. It already provides OCI or directory rootfs
staging, the hosted network stack with a hostname egress allowlist, vsock
ports and virtio-blk disks. Binding libkrun's C API ourselves through
`purego`, as containerd's nerdbox does, would mean rebuilding that network
stack and its egress policy. Firecracker, with its jailer and snapshots, is
the backend for hosted serving and warm pools, behind the same contract.

**D6. The launcher is a loom-owned contract in its own Go module.** The
backend interface (probe, start, wait, stop) lives in `packages/vmm`, beside
`packages/sandbox` but not inside it. `loom-exec` is the binary inside the
jail boundary, and go-microvm's dependency tree (a container registry
client, gVisor's netstack) does not belong in its module. Per ADR-018 the
launcher's protocol code stays in Go.

**D7. `lightninglabs/hazmat` is a reference, not a dependency.** hazmat is a
private repository and Loom is public, so Loom cannot import it. Its design
validated go-microvm on Apple Silicon and supplies shapes worth reusing: a
provider/instance contract, a metadata service registered on the virtual
gateway rather than a host socket, severing the network by stopping the
provider, and a console readiness marker. Loom's code is written fresh.

## Why

The ordering in the design note was forced by one failure mode: a driver
that works in a demo and misreports its own enforcement. D2 and D3 keep the
existing report honest by making it true, not by teaching the broker a new
vocabulary. D4 exists because the measurement showed that a microVM is not a
network boundary by default. TSI, libkrun's own default, hands the guest the
host's network namespace, loopback included.

D1 replaces the note's two-option workspace fork. Both of its options
assumed `fs_*` runs in the harness and `bash` in the jail. The distributed
runtime has since moved the whole workspace plane onto the executor node, so
putting the node in the guest keeps the two tools on one tree without
sharing any host directory. Matchlock's removal of its FUSE-over-vsock host
mounts in 0.3.0, for latency and near-Linux semantic failures, is outside
evidence for copy-in over sharing.

## Consequences

- The tier needs hardware virtualisation: `/dev/kvm` on Linux or
  Hypervisor.framework on Apple Silicon. The bwrap and Seatbelt tiers stay
  the default everywhere else; this is an additional tier.
- libkrun runs the VMM in a host process with the user's privileges, so a
  guest escape lands in that process. That is weaker than Firecracker's
  jailer, and the launcher says so in its probe output.
- go-microvm is pre-1.0 and versioned in lockstep with its runner. The
  launcher builds the runner from the same module version it imports, and on
  macOS codesigns it with the hypervisor entitlement.
- The guest rootfs under go-microvm is itself a virtio-fs share of a per-VM
  host directory (`rootfstype=virtiofs` on the guest command line). That
  directory is an extracted image copy, not the workspace, but the virtio-fs
  device is still guest-reachable attack surface. A block-device rootfs is
  the narrower option and is left open.
- A custom libkrunfw adds a kernel build to the guest image pipeline, and on
  macOS that build needs a Linux build environment.
- The guest init must start the executor inside a delegated cgroup v2
  subtree. The tier owns the guest, so this is init configuration, not
  operator setup.
- Running `loom-exec --self-test` as root in the root cgroup reported the
  pids probe `FAILED` with `release cgroup start gate: write |1: broken
  pipe`. The executor does not run as root, but the failure is real and is
  tracked separately.

## Addendum, 2026-11-01: the first end-to-end run

`daemon_shipped_microvm_test` now drives the tier end to end on an Apple
Silicon Mac. An orchestrator runs on the host. The executor is the same
`loomd` release, booted inside a libkrun guest from a copied linux/arm64 root
(`make vmm-guest-root`) on the Landlock kernel (`make vmm-firmware`). A
scripted model issues one `bash` call through a session registered on the
guest executor. The call ran on `6.12.91-loom-landlock` under `loom-exec`
(no-new-privileges set) and wrote into the guest's copy of the checkout. The
whole test, boot included, takes about ten seconds.

**The link (settles how D1's executor is reached).** The orchestrator dials
the executor by its unchanged node name, `<name>@127.0.0.1`. `loom-vm run
--publish NAME:HOST:GUEST` forwards the guest's `listen_port` to a host
loopback port and holds NAME at that port in the host's epmd with an ALIVE2
registration for the guest's life. The dial path asks the epmd at the name's
host for the port and then connects there, so the pinned TLS handshake, the
certificate's node-name SAN and the distribution handshake's exact-name check
all run unchanged. No daemon or boot-flag change was needed. An epmd-less
distribution and a vsock carrier were considered and rejected as more
machinery for the same property.

**D2 did not hold until it was fixed.** In the first run, model code in the
guest read the executor node's Erlang cookie. Nothing masked a distributed
daemon's `[distribution]` key or cookie: both live outside the state root,
and the default read scope is `host`. The same exposure held for an executor
on a host. Commit 73126ab14 adds the node's key and cookie to the protected
paths of every jailed child an executor runs, and the test now requires that
the cookie read fails. Sessions local to an orchestrator still lack the mask;
that is tracked as follow-up work.

**D3 measured.** With the stock libkrunfw the turn does not complete. The
test therefore requires the Landlock kernel and skips without it, rather than
relabelling a layer.

**Details a future driver inherits.** go-microvm v0.0.43 serves no DHCP, so
the guest configures 192.168.127.2/24 statically. The guest root is a
virtio-fs share that the guest writes into, so each boot uses a `cp -cRp`
clone. The executor's state root is a tmpfs inside the guest, for SQLite and
the code-mode socket. The node's secrets are staged under `/srv`, which lies
outside the jail's minimal base view but not outside the default host read
scope. The credential mask, not the location, is what protects them.
