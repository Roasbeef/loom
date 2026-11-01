# vmm (Go)

## Purpose

The microVM tier's launcher (ADR-022, issue #85). `loom-vm` boots a libkrun
guest from a `machine.Spec` through `stacklok/go-microvm`, on Linux/KVM and
macOS/Hypervisor.framework. The guest is meant to hold a whole executor with
`loom-exec` unchanged inside it; the host keeps the orchestrator. This module
is separate from `packages/sandbox` so that go-microvm's dependency tree (a
registry client, gVisor's netstack) never enters the jail helper's module.

## Key Types

- `machine.Spec` — everything about one guest: root (`Root.Image` OCI ref
  or `Root.Dir`), vCPUs, memory, `Init` argv, `Files` copied into the root
  before boot, `Egress` allowlist, `Forwards`, data directory. `Validate`
  refuses a spec with no or two roots, no init, a file target that is not a
  clean absolute path below `/`, an egress entry that is not a bare hostname,
  or a forward with a zero port or a host port used twice.
- `machine.Forward` — a host loopback port carried into a guest port. The only
  inbound path into a guest; it never listens beyond `127.0.0.1`.
- `machine.Egress` — the complete outbound allowlist. The zero value allows
  nothing; it never means "the hypervisor's default".
- `machine.Backend` / `machine.Machine` — the hypervisor-independent
  contract: `Probe`, `Start`; `ID`, `ConsolePath`, `Wait`, `Stop`.
- `machine/libkrun.Backend` — the go-microvm implementation. `Config` names
  the runner binary, the libkrun directory, and an optional `FirmwareDir`
  for a custom libkrunfw searched before the stock one.
- `epmd.Register` — an ALIVE2 registration of a node name in an epmd, held
  open as a `Registration` because epmd withdraws a name when the registering
  connection closes.
- `cmd/loom-vm` — `probe` and `run [flags] -- INIT ARGS`. Native paths come
  from `--runner`, `--lib-dir`, `--firmware-dir` or `LOOM_VM_RUNNER`,
  `LOOM_VM_LIB_DIR`, `LOOM_VM_FIRMWARE_DIR`. `run` takes `--file`,
  `--allow`, `--forward HOST:GUEST` and `--publish NAME:HOST:GUEST`, which
  forwards the port and registers NAME at HOST in the host's epmd (starting
  one with `epmd -daemon` when none answers) for the guest's life.
- `guest/build-libkrunfw.sh` and `guest/libkrunfw-landlock.config` — build a
  libkrunfw v5.5.0 whose guest kernel has Landlock and securityfs (ADR-022,
  D3), which the stock Homebrew libkrunfw lacks. `make vmm-firmware` runs the
  kernel build in a podman container and writes
  `build/firmware/libkrunfw.5.dylib`, which `--firmware-dir` selects.
- `guest/Dockerfile` and `guest/loom-guest-init` — the linux/arm64 guest root.
  `make vmm-guest-root` builds the image natively in the arm64 podman machine
  named by `VMM_BUILD_CONNECTION` (default `loom-build`), because `make release`
  cannot cross-compile, and exports its runtime stage to
  `packages/vmm/build/guest-root`. The root holds the installed server release
  (`loomd`, bundled ERTS, `loom-exec` inside the release tree), bubblewrap,
  git, ripgrep, sqlite3, iproute2, and the `loom` user (uid 10000).
  `loom-guest-init` is the payload libkrun runs as root: it configures the
  network statically, chowns the loom user's directories, builds the delegated
  cgroup v2 subtree under `/sys/fs/cgroup/loom`, and runs its arguments as
  `loom` with `LOOM_CGROUP_BASE` set.
- `guest/loom-guest-executor NODE_DIR` — the guest side of an executor. As
  root it mounts a tmpfs on `NODE_DIR/state` and gives `NODE_DIR` and
  `/srv/workspaces/*` to loom; then, through `loom-guest-init`, it renders the
  distribution options inside the guest, starts `loomd`, and prints
  `LOOM-EXECUTOR-READY <name>` once the node is registered with the guest's
  epmd and the daemon has logged `daemon.executor_serving` (or
  `LOOM-EXECUTOR-FAILED` and the daemon log).

## Relationships

Depends on `github.com/stacklok/go-microvm` only. No Loom package imports
this module and it imports none; `loom-exec` and `loomd` reach a guest as
part of the guest image. The client package's
`daemon_shipped_microvm_test` (with `test/support/microvm_executor`) drives
the `loom-vm` binary as a process: it stages a node directory and checkout
into a cloned root, boots it with `--publish`, and runs an orchestrator on
the host against it.

## Traffic

An executor in a guest speaks Loom's ordinary TLS distribution. The
orchestrator on the host resolves the executor's unchanged node name
(`<name>@127.0.0.1`) through the host epmd entry `--publish` holds, connects
to the forwarded host port, and the hosted stack carries the connection to
the guest's `listen_port`; the pinned handshake, the certificate's node-name
SAN and the distribution name check run as between two host nodes. The
guest's own epmd is never reached from the host. The guest's console is a host file
(`<data dir>/console.log`) the runner writes. The guest's network is a
virtio-net device whose other end is go-microvm's hosted gVisor stack in the
launcher process: guest 192.168.127.2/24, gateway and DNS 192.168.127.1. The
guest configures that statically; go-microvm v0.0.43 serves no DHCP lease.

## Invariants

- **Never boot on TSI.** libkrun's default networking runs guest sockets in
  the VMM on the host, and a guest booted that way reached a host loopback
  listener. `Start` always installs `hosted.NewProvider()` and a non-nil
  egress policy (an empty host list is still a policy, which makes the
  firewall deny by default). `TestEgressPolicyNeverNil` pins the second half.
- **Stop never deletes a caller's root.** go-microvm's `VM.Remove` deletes
  any rootfs outside its image cache, which for `Root.Dir` is the caller's
  directory. A guest started from `Root.Dir` is stopped with `VM.Stop`; only
  an image-extracted root goes through `Remove`.
- **Stop is unconditional.** It runs under its own 30 s context so a
  cancelled caller still releases the VMM, the network stack and the data
  directory.
- **Staged files replace, never follow.** `stageFile` removes the target
  before writing, so a symlink in the image cannot redirect the write out of
  the root.
- **The runner is version-locked.** Build it from this module's go-microvm
  version (`make vmm-runner`) and, on macOS, codesign it with
  `runner.entitlements`; an older runner fails at boot, not at probe.
- **The mask, not `/srv`, keeps an executor node's secrets.** The node's
  key, cookie and configuration are staged under `/srv/loom-node`, which lies
  outside the jail's minimal base view; under the default host read scope the
  jail sees the whole guest, `/srv` included, and only the daemon's
  `protecting_node_credentials` mask keeps the key and cookie from model code.
  Do not stage another secret there expecting the location to protect it.
- **Boot a clone of the guest root, never the export.** The root is a
  virtio-fs share the guest writes into. Clone it with `cp -cRp`: without `-p`
  macOS `cp` applies the umask to directory modes and `/tmp` loses its
  world-write bit.
- **The export is owned by the host user.** The guest sees every file as the
  host uid, and root in the guest can `chown` on the share, so the init chowns
  the loom user's home, state and work directories at every boot instead of
  relying on the image's ownership.
- **The init keeps the cgroup layout the helper's checks need.** `loom/` holds
  no processes and is owned by loom, `loom/init` holds the init, `loom/work`
  holds the workload and `loom/exec` is the process-empty base. A helper
  outside the delegated subtree cannot migrate processes into the base.

## Deep Docs

- `docs/adr/022-microvm-tier-runs-the-executor-in-a-libkrun-guest.md`
- `docs/design-notes/microvm-executor-tier.md` and its 2026-11-01 addendum
