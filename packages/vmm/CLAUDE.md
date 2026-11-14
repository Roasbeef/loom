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
  clean absolute path below `/`, an egress entry that is not a bare hostname
  or is a wildcard over one label (`*.com`), or a forward with a zero port or a
  host port used twice.
- `machine.Forward` — a host loopback port carried into a guest port. The only
  inbound path into a guest; it never listens beyond `127.0.0.1`.
- `machine.HostService` — an `http.Handler` served on the gateway,
  192.168.127.1, at a fixed port. The libkrun backend registers each one with
  `hosted.Provider.AddService` before the provider starts; no host socket is
  bound, so only the guest connects. `Validate` refuses a zero port, a nil
  handler, or a port used twice.
- `ghproxy.Proxy` — the credential-injecting HTTPS proxy (stdlib only). A
  CONNECT-only handler: the target must be a hostname on port 443 that the
  allowlist admits and the deny list does not (host globs, exact or leading
  `*.`). Hosts on the separate injection list are intercepted with leaves from
  a per-VM in-memory ECDSA P-256 CA, and the placeholder in an `Authorization`
  header (`Basic`, `token`, `Bearer`) becomes the real token; other admitted
  hosts are tunnelled untouched; the rest get 403. `GuestFiles` renders the CA,
  `/etc/loom-vm/github.env` and `/etc/gitconfig`, none holding the token. The
  gitconfig also rewrites each injection host's SSH remote forms
  (`git@host:`, `ssh://git@host/`) to `https://host/`, because the guest has
  no ssh client or key and a checkout's origin is usually an SSH URL.
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
- `setup.Manifest` — the contract a launcher reads: `{"version": 1,
  "revision", "loom_vm", "runner", "lib_dir", "firmware_dir", "guest_root"}`,
  absolute paths, written to `$LOOM_VM_HOME/manifest.json` (default
  `~/.loom/vm`) by `setup.WriteManifest`, which replaces it atomically.
  `firmware_dir` is `""` for the stock libkrunfw; `revision` is a commit, or
  `dev` for a build tree. Changing a key or its meaning needs a new
  `ManifestVersion`, because another program reads it.
- `setup.Release` / `setup.FromBuild` / `setup.Doctor` — the two ways to
  produce a manifest and the check on one. `Release` first pulls
  `ghcr.io/<owner>/loom-guest:TAG` for the host architecture and checks its
  revision and version labels (and `Options.Revision`), then downloads the
  runner and firmware from a GitHub release, verifies them against
  `vmm-SHA256SUMS`, on macOS removes `com.apple.quarantine` and re-signs the
  runner ad hoc with `vmm.RunnerEntitlements`, and unpacks the image with
  `setup.ExtractRoot` into `cache/TAG/guest-root`. `FromBuild` records an
  existing build tree and copies nothing. `Doctor` checks each entry, the
  digests recorded at install (`installed.sums`, taken after the re-signing),
  the entitlement, and `/tmp`'s mode, and lists runners with no `loom-vm`
  parent without killing them. Downloads exist for darwin/arm64 only.
- `vmm.RunnerEntitlements` — `runner.entitlements`, embedded from the module
  root because `go:embed` cannot reach a parent directory. `make vmm-runner`
  signs with the same file.
- `cmd/loom-vm` — `probe`, `setup (--release TAG [--revision SHA] | --from-build DIR [--revision SHA])`,
  `doctor` and `run [flags] -- INIT ARGS`. Native paths come
  from `--runner`, `--lib-dir`, `--firmware-dir` or `LOOM_VM_RUNNER`,
  `LOOM_VM_LIB_DIR`, `LOOM_VM_FIRMWARE_DIR`. `run` takes `--file`,
  `--allow`, `--forward HOST:GUEST` and `--publish NAME:HOST:GUEST`, which
  forwards the port and registers NAME at HOST in the host's epmd (starting
  one with `epmd -daemon` when none answers) for the guest's life. An
  interrupt or SIGTERM stops the guest and exits 0; a timeout exits 1, and
  `--timeout 0` runs until stopped, as a standing guest does. A runner that
  exits before it creates the console file exits `run` 1 with `errNoConsole`
  (`follow` waits on the guest while it retries the missing file).
  `run` validates the spec after the credential proxy adds its host service.
  `--state-disk PATH` attaches a raw image as `/dev/vda` (`Spec.Disks`),
  creating a sparse one of `--state-disk-size` MiB on first use and reusing
  it after; `loom-guest-executor --state-device /dev/vda` formats it once and
  mounts it as the executor's state root.
  `--github-token-from gh|env` (`gh auth token`, or `LOOM_VM_GITHUB_TOKEN`) and
  `--inject-host` (repeatable) start the proxy on gateway port 3128 and stage
  its guest files (`cmd/loom-vm/github.go`); the proxy admits exactly the
  `--allow` hosts.
- `guest/build-libkrunfw.sh` and `guest/libkrunfw-landlock.config` — build a
  libkrunfw v5.5.0 whose guest kernel has Landlock and securityfs (ADR-022,
  D3), which the stock Homebrew libkrunfw lacks. `make vmm-firmware` writes
  `build/firmware/libkrunfw.5.dylib` on macOS, with the kernel built in a
  podman container, and `libkrunfw.so.5` on Linux, with the kernel built
  natively for the machine's architecture (about 10 minutes on two x86_64
  cores); `--firmware-dir` selects it. The script has a mode per half:
  `--kernel OUTPUT_DIR` runs the Linux half natively and leaves `kernel.c`
  (CI's `firmware-kernel` job, on an arm64 runner), and `--link KERNEL_C
  OUTPUT_DIR` links the library (CI's `macos-assets` job). The link reads the
  kernel's architecture from the load-address footer of `kernel.c` and refuses
  one that does not match the library: aarch64 for the macOS dylib, the host's
  own on Linux. `guest/build-libkrunfw-test.sh` tests that refusal with stub
  kernels, and `make vmm-test` runs it.
- `guest/build-libkrun.sh` — Linux only. Builds libkrun v1.19.7 (the tag
  go-microvm v0.0.43 pins, checked against its commit) with `BLK=1 NET=1` into
  `build/libkrun` (`lib64/libkrun.so.1`, `include`, `lib64/pkgconfig/libkrun.pc`),
  because Ubuntu ships no libkrun and the runner links it through pkg-config.
  It uses the cargo on `PATH` or a minimal rustup kept in its work directory.
  `make vmm-libkrun` runs it; `KRUN_PREFIX` and `KRUN_LIBDIR` locate the result
  for `vmm-runner` and `vmm-install-dev`.
- `guest/Dockerfile` and `guest/loom-guest-init` — the guest root, for the
  host's architecture. `make vmm-guest-root` builds the image natively, because
  `make release` cannot cross-compile: in the arm64 podman machine named by
  `VMM_BUILD_CONNECTION` (default `loom-build`) on macOS, and with the local
  podman as linux/amd64 or linux/arm64 on Linux (`VMM_PODMAN_FLAGS='--runtime
  crun'` on Ubuntu 24.04, whose runc 1.3 refuses the cache mounts). It exports
  its runtime stage to `packages/vmm/build/guest-root`. The build stage removes
  its checkout in the step that installs the release, so that its layer does
  not hold gigabytes of build output, and the runtime stage strips setuid and
  setgid bits (see "A Linux share" below). The root holds the installed server release
  (`loomd`, bundled ERTS, `loom-exec` inside the release tree), bubblewrap,
  git, ripgrep, sqlite3, iproute2, and the `loom` user (uid 10000). The
  image carries `org.opencontainers.image.revision` and `.version` labels
  from the `LOOM_REVISION` and `LOOM_VERSION` build arguments (the make
  target passes the checkout's commit and `dev`; the release workflow passes
  the tag), which `setup.Release` reads. The release workflow builds it on
  both architectures and publishes `ghcr.io/<owner>/loom-guest:<tag>`.
  `loom-guest-init` is the payload libkrun runs as root: it configures the
  network statically, trusts the proxy CA (`update-ca-certificates`) and
  exports `/etc/loom-vm/github.env` when the CA file exists, runs
  `/etc/loom-vm/provision` as root once when it exists and
  `/etc/loom-vm/provisioned` does not (printing `LOOM-PROVISION-FAILED
  status=N` and exiting 1 on failure, which `loom vm up` reports), settles the
  loom user's ids (`--identity` does only that), chowns the loom
  user's directories, builds the delegated
  cgroup v2 subtree under `/sys/fs/cgroup/loom`, and runs its arguments as
  `loom` with `LOOM_CGROUP_BASE` set.
- `guest/loom-guest-executor NODE_DIR` — the guest side of an executor. As
  root it settles the loom user's ids, mounts the state disk or a tmpfs on
  `NODE_DIR/state` and gives `NODE_DIR` and
  `/srv/workspaces/*` to loom; then, through `loom-guest-init`, it renders the
  distribution options inside the guest, starts `loomd`, and prints
  `LOOM-EXECUTOR-READY <name>` once the node is registered with the guest's
  epmd and the daemon has logged `daemon.executor_serving` (or
  `LOOM-EXECUTOR-FAILED` and the daemon log). When the staged `loom.toml` has an
  `[executor_listener]` table (the untrusted link, `loom vm up --link
  untrusted`), the daemon is no distribution peer: the script renders no
  options file, needs no cookie (it chmods one only if present), and prints
  `LOOM-EXECUTOR-READY untrusted` once the log holds both
  `daemon.executor_serving` and `daemon.untrusted_listener`. The launcher is run
  with `--forward` and not `--publish` for such a guest.

## Relationships

Depends on `github.com/stacklok/go-microvm`, and on
`github.com/google/go-containerregistry` (already in go-microvm's tree) for
`setup`'s image pull. The server release carries the `loom-vm` binary
(`scripts/release.sh`, `DIST_VM=0` omits it), and `.github/workflows/vmm-release.yml`
publishes the guest image, runner and firmware that `loom-vm setup --release`
installs. No Loom package imports
this module and it imports none; `loom-exec` and `loomd` reach a guest as
part of the guest image. The client package's
`daemon_shipped_microvm_test` drives the `loom-vm` binary as a process, through
the product path: `loom-vm setup --from-build` writes a manifest in a private
`LOOM_VM_HOME`, `loomd vm up` boots the guest and enrolls it in an
orchestrator's configuration, and the test runs that orchestrator against the
guest, then `vm down` and `vm up` again.

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

With `--github-token-from`, git, gh and curl in the guest send `CONNECT
host:443` to the hosted service at 192.168.127.1:3128, which the provider's
firewall admits for that port. The proxy dials the real host from the launcher
process, outside the guest's egress firewall, so it enforces the allowlist
itself. A direct connection to an allowlisted host still works and carries no
credential.

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
- **A state disk is extended, never shrunk.** `--state-disk FILE` attaches a
  raw image as `/dev/vda`, created sparse at `--state-disk-size` MiB. The
  guest's first `mke2fs` zeroes the device's last 64 KiB and libkrun shortens
  the backing file by that much, so the filesystem would count a larger device
  than the next boot sees and the kernel would refuse to mount it. `ensureDisk`
  extends a shorter file back to the requested size and keeps its contents.
- **Staged files replace, never follow.** `stageFile` removes the target
  before writing, so a symlink in the image cannot redirect the write out of
  the root.
- **The real token never leaves the launcher process.** It is held by
  `ghproxy.Proxy`, substituted only into an `Authorization` header whose whole
  credential is the placeholder, never put in a URL, body, other header, log
  line or staged file. `TestGuestFilesHoldNoToken` and
  `TestLogsNeverCarryTheTokenOrPlaceholderOrHeaders` pin it. Do not log a
  header value in `ghproxy`, and do not add a way to export the CA key.
- **A host write under the guest root never follows a link out of it.** The
  guest's user owns directories in the root, so `stageFile` refuses a target
  whose resolved parent (or deepest existing ancestor) is outside the resolved
  root before it creates or writes anything (`resolvedWithin`). `loom vm up`
  does the same for its own writes (`vm_cli.make_inside`).
- **A provisioning script runs once, as root, before the executor.** The
  marker is created only on exit zero. The script is staged by `loom vm up
  --provision` and nothing else; the init never looks in a workspace. With the
  proxy on, root's `HTTPS_PROXY` is set (the init sources `github.env` with
  `set -a`); plain HTTP to an allowlisted host goes direct, which is how `apt`
  reaches `deb.debian.org`. The proxy still takes CONNECT to port 443 only.
- **Injection never widens egress.** The injection list says who gets a
  credential; the allowlist says who is reachable, and an injection host the
  allowlist omits is refused.
- **The runner is version-locked.** Build it from this module's go-microvm
  version (`make vmm-runner`) and, on macOS, codesign it with
  `runner.entitlements`; an older runner fails at boot, not at probe.
- **A wrong image changes nothing.** `Release` locates libkrun, then reads the
  guest image's labels (`pullGuest`; layers are fetched later, at extraction)
  before it downloads, stages or writes anything. A missing revision label, a
  version label other than the tag, or, with `Options.Revision` /
  `--revision SHA`, a revision that is neither equal to nor a prefix of
  (seven characters or more) the requested one, refuses with no cache
  directory, no download and no manifest change. `loom vm setup` passes
  `--revision` with the running build's commit so that a guessed tag of another
  commit is refused here and not found out after the manifest was replaced.
  With `--from-build`, `--revision` is the revision to record (default `dev`).
- **Nothing downloaded is used before it is verified, and nothing partial is
  visible.** `Release` locates libkrun first, checks each asset's SHA-256
  against `vmm-SHA256SUMS`, builds the whole install under
  `cache/.staging-TAG`, renames it into `cache/TAG`, and replaces the manifest
  last. A refusal leaves no manifest and no cache directory, and a failed
  re-install leaves the previous manifest pointing at intact files. The
  checksum asset is `vmm-SHA256SUMS`, not `SHA256SUMS`, which the server
  release already publishes.
- **Extraction never writes outside the root.** `ExtractRoot` refuses a `..`
  element and any entry whose parent path holds a symlink, creates symlinks
  without following them, and links only to regular files. Modes are applied
  by chmod, never left to the umask, and directory modes last and deepest
  first.
- **There is no Developer ID.** The runner's ad-hoc signature identifies no
  one; it carries the hypervisor entitlement, and the checksum is the
  integrity check. `Doctor` verifies the digests recorded after the
  re-signing, not the downloaded ones.
- **The guest image is tied to the loom release.** The executor protocol is
  exact-revision, so setup refuses an image whose version label is not the tag
  and records the revision label in the manifest.
- **The mask, not `/srv`, keeps an executor node's secrets.** The node's
  key, cookie and configuration are staged under `/srv/loom-node`, which lies
  outside the jail's minimal base view; under the default host read scope the
  jail sees the whole guest, `/srv` included, and only the daemon's
  `protecting_node_credentials` mask keeps the key and cookie from model code.
  Do not stage another secret there expecting the location to protect it.
- **A Linux share shows the host user's ids, and only root and that user can
  write it.** libkrun's virtio-fs passthrough has no ownership emulation
  outside macOS. A runner without CAP_CHOWN and CAP_SETUID presents every file
  as owned by its own user, refuses a chown, and refuses a write by any uid but
  0 and its own (`set_creds`, libkrun's `fs/linux/passthrough.rs`).
  `loom-guest-init` therefore tries to hand `/work` to uid 10000 and, when that
  fails, makes the loom user the share's owner by rewriting its passwd and
  group ids, every boot. Two consequences follow. Every file in the guest root,
  system files included, belongs to the loom user (that covers
  `loom-guest-init`, `loom-guest-executor`, `/opt/loom` and `/etc/loom-vm`, which
  root runs at each boot), so a jail escape becomes guest root at the next boot
  and lasts until the root is replaced; the jail (landlock, bubblewrap,
  no-new-privs) is the boundary, and a runner with the capabilities, or a
  root-run one, keeps uid 10000. The init refuses a share owned by root, and
  rewrites passwd and group on every boot, in both directions. A single-id user
  namespace (`WithUserNamespaceUID`) was tried instead and gives the same
  ownership, with root chowns failing. And a provisioning script that installs
  packages as root cannot work there, because dpkg's chown to root is refused.
  The image has no setuid files: a setuid-root `mount` on the share runs as the
  host user and fails for root.
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

- `docs/architecture/microvm.md` — components, startup, the orchestrator link,
  the isolation layers, the machine lifecycle and the concurrency rules
- `docs/adr/022-microvm-tier-runs-the-executor-in-a-libkrun-guest.md`
- `docs/design-notes/microvm-executor-tier.md` and its 2026-11-01 addendum
