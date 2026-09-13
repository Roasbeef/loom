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

Built end to end on the Linux signoff host (Linux 5.15, x86_64): a cold
`make docker-image` (Gleam built from source, no warm Hex/Go caches)
takes about ten minutes, and `docker image ls` reports the finished
`loom-runtime:dev` image at 325 MB.

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

Measured on the Linux signoff host, this is worse than "some probes
enforce, some skip": `bwrap` refuses to create a user namespace at all
under Docker's default seccomp profile, even though the kernel's own
`kernel.unprivileged_userns_clone` sysctl allows it, so the jail never
comes up and nine of the eleven probes report `FAILED`, not `SKIPPED`.
`SKIPPED` means the self-test looked and found a layer absent before
trying; `FAILED` here means the jail tried, could not start, and every
check that depends on it correctly reports that nothing was confined.
Only the cgroup v2 delegation check and the missing-Erlang-toolchain
check report `SKIPPED`, since those are genuinely absent rather than
attempted and broken. `make docker-smoke` runs this exact posture and
records the self-test's exit code without failing the build on it, for
the same reason: an insecure plain posture is what this document already
says to expect, not a defect in the image.

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
docker exec -u root loom sh -c '
  mount -o remount,rw /sys/fs/cgroup
  mkdir -p /sys/fs/cgroup/loom/host
  echo "+pids +memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
  echo "+pids +memory" > /sys/fs/cgroup/loom/cgroup.subtree_control
  chown -R 10000:10000 /sys/fs/cgroup/loom
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
for `loom-exec`'s pids/memory ceilings; the `chown` hands that base to
the same uid the daemon and `loom-exec` run as, since delegation is a
filesystem permission, not just an entry in `cgroup.subtree_control`.

With `--cgroupns=host`, the container's own process (`tini`, and
everything it spawns) starts inside the host cgroup tree at whatever
scope Docker's own systemd cgroup driver placed it, a sibling of
`/sys/fs/cgroup/loom`, not a descendant of it. cgroup v2's delegation
containment rule needs write access to the *common ancestor* of a
process's current cgroup and its destination to move it, and that
common ancestor is `/sys/fs/cgroup` itself, owned by root. A probe run
with plain `docker exec loom loom-exec --self-test` therefore still
reports the fork-bomb probe `SKIPPED`, now with a reason naming exactly
this: the delegated base exists but the helper's own cgroup sits outside
it. Moving the helper's own process into a subgroup under the delegated
base first, before it forks a sandboxed child, closes that gap:

```
docker exec -u root loom sh -c '
  echo $$ > /sys/fs/cgroup/loom/host/cgroup.procs
  exec env LOOM_CGROUP_BASE=/sys/fs/cgroup/loom loom-exec --self-test
'
```

This is what the daemon's own process would need to do at boot, before
spawning any session's jail, to keep every one of `loom-exec`'s per-exec
cgroups inside the delegated tree; the image does not wire that up
itself (see "What remains unverified" below), so reproducing the full
count by hand needs the migration step spelled out here rather than a
bare `docker exec loom loom-exec --self-test`.

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

## Measured self-test counts

`loom-exec --self-test` runs eleven probes (`docs/architecture/effects.md`)
and reports each as `ENFORCED`, `SKIPPED`, or `FAILED`, never a false
pass. Issue #384 measured the two postures on real Linux hardware
outside a container; this table adds a fresh measurement of
`loom-runtime:dev` itself, built and run on the Linux signoff host
(Linux 5.15.0-58-generic, x86_64, Docker 23.0.1):

| Posture | Enforced | Skipped | Failed |
|---|---|---|---|
| Bare host, no Erlang toolchain on PATH (issue #384) | 10 of 11 | 1 | 0 |
| Bare host, Erlang toolchain on PATH (issue #384) | 11 of 11 | 0 | 0 |
| Plain `docker run` (measured against `loom-runtime:dev`) | 0 of 11 | 2 | 9 |
| Full isolation, with the process-migration step above (measured against `loom-runtime:dev`) | 10 of 11 | 1 | 0 |

The full-isolation row matches "bare host, no Erlang toolchain" exactly,
which is what it should: the runtime image never installs Erlang
(`erl`/`erlc`), so the "unvetted beam" probe stays `SKIPPED` there the
same way it would on any Erlang-less Linux box, and every other probe
enforces. The plain row is worse than issue #384's own text implied:
that issue described a container as withholding "userns and writable
cgroupfs", which reads as some probes skipping gracefully. Measured
here, `bwrap` fails outright when it cannot create a user namespace
under Docker's default seccomp profile, so nine probes come back
`FAILED` rather than `SKIPPED`; see "Plain" above for the full account.
Both rows against `loom-runtime:dev` came from `make docker-smoke`
(plain) and the full-isolation run line plus the migration step above
(full isolation), run by hand on the same host.

## What remains unverified

Two things this PR did not reach. First, the full-isolation row above
needed the daemon's own process moved into the delegated cgroup
subgroup by hand, once, from a root shell, before running the self-test
directly; the image itself does not do this at boot, so a `loomd`
started by the entrypoint still spawns its sandboxed sessions from
outside the delegated tree unless an operator repeats that step (or a
future change teaches the daemon to do it itself). Second, this was
verified as a single operator running one container at a time on a
shared signoff host; it says nothing about two containers on the same
host both using `--cgroupns=host`, which share the same host cgroup
tree and could in principle collide on `/sys/fs/cgroup/loom` if both
used the same delegated path. Naming the base per container (for
example `/sys/fs/cgroup/loom-<container-id>`) would remove that, but it
was not exercised here.

Building the image itself was, at an earlier point in this branch's
history, attempted on an Apple Silicon Mac through Docker Desktop's
`linux/amd64` emulation (Rosetta 2, not QEMU), where the build's OTP
step crashed with `undefined function erlang:nif_error/1` inside
`prim_tty:tty_create/1`. That was an artifact of Rosetta's translation
disagreeing with the BEAM's JIT-generated code on that machine, not a
defect in the Dockerfile. The build, boot, smoke, and self-test
measurements throughout this page are the fresh, complete run that
Apple Silicon attempt could not produce, done instead on a real Linux
x86_64 host (the Linux signoff host).

## Building and smoking it

```
make docker-image          # DOCKER_IMAGE=name:tag to override the default loom-runtime:dev
make docker-smoke          # builds, boots the plain posture, runs a client command and the self-test, stops it
```

`make docker-smoke` skips with a clear message rather than failing when
Docker is not available; where Docker is available it exits nonzero on
the container exiting before the daemon becomes ready or `loom sessions
list` failing. It runs `loom-exec --self-test` at the end and prints
its output and exit code, but does not fail the build on that exit code:
the plain posture it exercises is documented above to leave most of the
self-test's probes unenforced, so a nonzero self-test there is the
expected outcome, not evidence the smoke run itself failed.

Hosted CI runs the same smoke through `.github/workflows/docker.yml`,
but only when one of the files that define the image changes: the
Dockerfile, `.dockerignore`, the smoke script, or the workflow itself.
The build compiles Gleam from source and takes on the order of twenty
minutes on a hosted runner, which is too much to add to every push, and a
Dockerfile nothing exercises is the one that drifts. The workflow proves
the plain posture only; the full-isolation counts above come from a real
host, because a hosted runner does not offer the cgroup delegation that
posture needs.
