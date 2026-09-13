# Running loomd in a container

A Docker image for people who want to run the daemon without building the
toolchain: `docker build .` from the repository root produces an image
carrying the self-contained server release (`make install`'s output),
started as a non-root user. This page says what the image carries, what
it does not, the two ways to run it, and what each one trades away.

## What the image carries, and what it does not

The build stage (`FROM ... AS build` in the root `Dockerfile`) installs
the same toolchain `scripts/signoff/Dockerfile` installs for the test
signoff on branch `build/signoff-container`: Ubuntu 24.04, Erlang/OTP
29.0.5, Gleam 1.18.1 built from source with the cherry-picked fix for
issue #248, Go, and the C toolchain `esqlite3_nif.so` needs. It runs
`make install PREFIX=/opt/loom`, the same command a person building from
source runs (`docs/distribution.md`, "Installing from a checkout"), which
in turn builds the code-mode seed, the self-contained server release, and
the self-contained client release.

The runtime stage starts over from a plain `ubuntu:24.04` and copies in
only `/opt/loom`, the installed tree. `make release-smoke` is the
project's own proof that a built release needs no Erlang, no Gleam, and
no Go to run (`docs/distribution.md`), and the runtime stage takes that
proof at face value: none of the three toolchains are installed there.
What is installed is `bubblewrap` (the sandbox helper's own
namespace-and-mount layer; without it the jail degrades, see below),
`sqlite3`, `ripgrep`, `git`, `ca-certificates`, and `tini` as PID 1. The
daemon runs as a non-root `loom` user (uid 10000).

Both stages pin `--platform=linux/amd64`. `make release` refuses to build
for anything but the host it runs on (`docs/distribution.md`,
"Cross-compilation: there is none"), because the copied ERTS and
`esqlite3_nif.so` are both native code, and the OTP tarball this build
fetches is the `ubuntu-24.04` x86_64 build `builds.hex.pm` publishes;
there is no arm64 counterpart at that path. Building on an arm64
workstation therefore goes through emulation; that is a build-time cost,
not a run-time one, since the resulting image is a normal amd64 image.

## The bind restriction, and what it means for reaching the daemon

`loomd`'s `--bind` flag accepts only a loopback address:
`127.0.0.1:<port>` or `[::1]:<port>`
(`packages/client/src/client/daemon/main.gleam`, `bind_address`). This is
not a container-specific restriction the image adds; it is a property of
the daemon itself, on any host. It means a `docker run -p` port
publication does not reach the daemon the way it would for a server that
binds `0.0.0.0`: Docker's bridge networking forwards to the container's
external interface, and the daemon is not listening there.

The image's entrypoint runs `loomd --state-dir /var/lib/loom --bind
127.0.0.1:7331`. `EXPOSE 7331` documents the port; it does not by itself
make the daemon reachable from outside the container. The two ways that
actually work are the ones the run lines below use:

- **`docker exec`** into the running container, where the client shares
  the daemon's network namespace and loopback is simply loopback. This is
  what both run lines in this doc do, and it is the intended way to drive
  a container that only ever listens on loopback.
- **`--network host`**, which puts the container's loopback on the host's
  own, so a client on the host reaches `127.0.0.1:7331` directly. This
  trades away the network namespace along with everything else `--network
  host` removes; it is not part of either posture below, but is available
  to an operator who wants it.

The daemon token is never baked into the image. It is written by the
daemon itself under `/var/lib/loom/owner.token` on first boot, alongside
the discovery record at `/var/lib/loom/daemon.endpoint`
(`docs/architecture/sessions.md`, "Implemented shared endpoint boundary").
Reaching it means reading the volume or running a client inside the same
container; nothing in the image or its build reveals it.

## Two postures

Both run lines below mount a workspace at `/work` and a state volume at
`/var/lib/loom`, so a session's data and the daemon's own catalogue
outlive a container replacement.

### Plain

```
docker run -d --name loom \
  -v "$PWD:/work" \
  -v loom-state:/var/lib/loom \
  loom-runtime:dev
```

Docker's own container boundary is the jail here, and it is a different
boundary than loom's own: a default container withholds unprivileged
user namespaces and a writable, delegated cgroup v2 base, so
`loom-exec`'s bubblewrap layer and its cgroup v2 memory/pids ceilings
cannot come up. What that means concretely: a model-written program in
this posture shares the container with the daemon's own state and its
token, confined by whatever Docker itself enforces (its default seccomp
profile, its own namespaces) rather than by loom's own Landlock ruleset,
network-off seccomp filter, or cgroup ceilings.

Run the self-test inside the container to see exactly what came up:

```
docker exec loom loom-exec --self-test
```

### Full isolation

```
docker run -d --name loom \
  --cgroupns=host \
  --cap-add SYS_ADMIN \
  --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined \
  --security-opt systempaths=unconfined \
  -v "$PWD:/work" \
  -v loom-state:/var/lib/loom \
  loom-runtime:dev
docker exec loom sh -c '
  mount -o remount,rw /sys/fs/cgroup
  mkdir -p /sys/fs/cgroup/loom
  echo "+pids +memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
  echo "+pids +memory" > /sys/fs/cgroup/loom/cgroup.subtree_control
'
```

The five `docker run` flags and the in-container cgroup v2 delegation
step are the ones `scripts/signoff_remote.sh` (branch
`build/signoff-container`) measured close the gap for `loom-exec`'s own
enforcement lane. Each flag removes a piece of Docker's own confinement
rather than adding one: `--cgroupns=host` shares the host's cgroup v2
tree instead of a private one; `--cap-add SYS_ADMIN` is what bwrap needs
to create user, mount and PID namespaces; the three `--security-opt`
flags lift Docker's default seccomp profile, its AppArmor profile (which
on Ubuntu otherwise restricts unprivileged user namespaces), and its
`/sys` and `/proc` path masking. The remount and delegation step makes
`/sys/fs/cgroup` writable (Docker mounts it read-only even with
`--cgroupns=host`) and carves out a fresh, process-empty cgroup v2 base
for `loom-exec`'s pids/memory ceilings.

**What this posture trades.** With these flags, Docker's own container
boundary is mostly gone. What is left is closer to a process group with
a different filesystem view than to a sandboxed container. What replaces
it is loom's own jail: `loom-exec`'s bubblewrap namespaces, Landlock
ruleset, seccomp network-off filter, and cgroup v2 ceilings, the same
layers a bare Linux host provides. This is the right trade for a box the
operator already controls and uses as a dedicated build or signoff
machine, such as the one `LOOM_SIGNOFF_HOST` names, not for a shared
host where Docker's own confinement is the thing keeping one container's
compromise from reaching another's.

```
docker exec loom loom-exec --self-test
```

## Measured self-test counts

`loom-exec --self-test` runs nine probes (`docs/architecture/effects.md`)
and reports each as `ENFORCED` or `SKIPPED`, never a false pass. Issue
#384 already measured the two postures on real Linux hardware:

| Posture | Enforced | Skipped |
|---|---|---|
| Bare host, no Erlang toolchain on PATH | 10 of 11 | 1 |
| Bare host, Erlang toolchain on PATH | 11 of 11 | 0 |
| Plain `docker run` | fewer; userns and writable cgroupfs withheld | several |
| Full isolation (`--cgroupns=host` etc. + cgroup delegation) | 11 of 11 | 0 |

Those rows are issue #384's own numbers, not a fresh measurement from
this branch; `docs/next.md`-style honesty means saying so rather than
implying this Dockerfile was the machine that produced them. Reproducing
them against `loom-runtime:dev` needs a real Linux x86_64 host; see
"What could not be verified from this branch" below for why that could
not be done here, and run `make docker-smoke` (plain posture) or the
full-isolation run line above plus `docker exec loom loom-exec
--self-test` to get a number for a specific machine.

## What could not be verified from this branch

Building this image was attempted on an Apple Silicon Mac through
Docker Desktop's `linux/amd64` emulation, which is Rosetta 2 rather than
QEMU on this machine. The build's OTP step (`erl -noinput -noshell`,
verifying the freshly extracted toolchain) crashes there with `undefined
function erlang:nif_error/1` inside `prim_tty:tty_create/1`, the
terminal-handling NIF failing to resolve a BIF that always exists on a
correctly running emulator, which points at the BEAM's JIT-generated
native code disagreeing with Rosetta's translation rather than at
anything in this Dockerfile: the same command, byte for byte, is the one
`scripts/signoff/Dockerfile` already relies on and CI already runs
successfully on real x86_64. This was reproduced in a bare `ubuntu:24.04
--platform linux/amd64` container outside the Dockerfile entirely, so it
is an environment property of this Mac's emulation path, not a defect
introduced here.

What that means for this PR: the Dockerfile, the Makefile targets, and
`scripts/docker_smoke.sh` are written and reviewed but the image has not
been built and booted end to end from this branch, and the self-test
counts above are issue #384's, not a fresh run. This needs a real Linux
x86_64 (or arm64, once that release path is exercised) host to verify,
either a developer's own machine or the `LOOM_SIGNOFF_HOST` box already
used for the signoff container.

## Building and smoking it

```
make docker-image          # DOCKER_IMAGE=name:tag to override the default loom-runtime:dev
make docker-smoke          # builds, boots the plain posture, runs a client command and the self-test, stops it
```

`make docker-smoke` skips with a clear message rather than failing when
Docker is not available; where Docker is available it exits nonzero on
any failure, including the container exiting before the daemon becomes
ready, `loom sessions list` failing, or `loom-exec --self-test` reporting
an enforceable probe that did not enforce.
