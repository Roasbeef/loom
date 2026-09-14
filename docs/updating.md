# Updating Loom

How to move a running Loom from one release to the next without losing a
session, and why the pieces are arranged the way they are. The packaging
that makes an update cheap is described in [distribution.md](distribution.md);
this document is the operator's side of it.

## The short version

```sh
git pull                 # or unpack the new tarball
make install             # rebuilds, then lays the new release beside the old
```

Nothing else is required. A daemon that was running keeps running the build
it was started with; the next `loom` you open is the new client and, if it
starts a daemon, that daemon is the new release. From the operator's chair
an update is a build and a pause, not a lost session.

## What an update actually changes

`scripts/install.sh` writes each release into a versioned directory and
switches a symlink to point at it:

```
~/.local/lib/loom/server-0.1.0     the release tree for 0.1.0
~/.local/lib/loom/server           a symlink to server-0.1.0
```

The version comes from `packages/client/gleam.toml` (the server) and
`packages/tui/gleam.toml` (the client), which are also where
`scripts/release.sh` reads the release version. Two consequences follow,
and both are the point of the whole arrangement:

**A running daemon is never mutated under.** The release's own launcher
resolves its root with `pwd -P` — the physical directory, not the symlink
— so a daemon started before the update keeps reading `server-0.1.0`
while the symlink now names `server-0.2.0`. Its helper, its bundled
`gleam`, and its code-mode seed all still come from the tree it was built
against. The failure this prevents is specific: the server resolves
`bin/loom-exec`, `bin/gleam` and `share/codemode-seed` through
`code:root_dir()` *at spawn time*, so an install that overwrote the tree
in place could make the very next tool call or code-mode build spawn a
helper from a half-copied or mismatched tree.

**The switch is atomic.** The new symlink is created beside the old one
under a temporary name and renamed over it, so a reader resolves either
the old target or the new one and never an absent link. Deleting the link
and re-creating it would leave exactly that window, and a daemon or
client starting inside it would fail to find the tree it was pointed at.

Old version directories are pruned on one rule a shell script can apply
soundly: keep the version each symlink now points at and the version it
pointed at immediately before, and delete only what is older. The
previous version is kept because a daemon started before the install may
still be running from it. When the discovery record at
`${LOOM_STATE_DIR:-$HOME/.loom}/daemon.endpoint` names a live PID, the
prune is skipped entirely: a shell cannot ask which directory that PID was
rooted in, so anything it cannot rule out keeps its tree. A stale
directory costs disk; deleting a live tree is the bug this layout exists
to prevent.

## Knowing which build you are talking to

Each launcher — the `bin/loomd` and `bin/loom` wrappers `install.sh`
generates, the launchers `release.sh` and `release-client.sh` write into a
release, and the `make run-server`/`make run-tui` targets — exports two
variables before it `exec`s the binary:

```
LOOM_BUILD_VERSION=0.1.0
LOOM_BUILD_COMMIT=4c266dde
```

The values are baked in at build time, so a release unpacked on a machine
with no git and no checkout still reports its own build. A tree built with
no release metadata — `gleam run`, a hand-built checkout with the
variables unset — honestly reports `dev` and `unknown` rather than
inventing a version.

The daemon sends its build in the control-plane `hello`, and the terminal
compares it against its own when it attaches. If the two differ you get
one line in the transcript naming both:

```
daemon build 0.1.0 (4c266dde) differs from this client's 0.2.0 (abcdef12);
the daemon runs the build it was started with, so restart it to pick up an update
```

This is a **notice, not a refusal.** The two halves are protocol-compatible
by construction — the version string exists to tell you which binary is
which, not to decide whether a frame is legal — so the attach proceeds.
The line is the answer to the question an operator actually has after an
update: *did my daemon move?* If it did not, the message says so and says
what to do about it.

A daemon old enough to predate build identity sends no build at all, and
the client stays silent rather than warning on every attach. The version
comparison is additive: a new client reads an old daemon's hello and
reports that the build is unknown, rather than failing the handshake it
needs in order to report anything.

## The daemon does not move until it exits

The one thing an update deliberately does *not* do is restart a running
daemon for you. A daemon serves every workspace on the host and outlives
the terminal that started it, so restarting it is an event with
consequences for sessions this terminal may not own. What happens instead
depends on how the daemon is running:

- **No daemon running.** Nothing to do. The next `loom` starts the new
  release.
- **A daemon running, shared across workspaces.** It keeps running the
  build it was started with. New terminals attach to it as clients and
  report the mismatch above. To move it, stop it and let the next `loom`
  start the new one — its sessions are durable and a restarted daemon
  reopens them.

A restart is cheap because nothing in Loom depends on a process surviving:
events are hints, pulls are truth, a client resumes by sequence number,
and the conversation store is durable and write-once. That is why the
update path is "restart cleanly", not "hot-load the new code" — the BEAM
can swap modules, but neither `gleam_otp` actors nor weft state machines
expose a `code_change` for a moved state shape, and Loom's own invariants
already make a restart the honest operation.

## Rolling back

Because the previous version directory is kept, a rollback is a symlink
switch:

```sh
ln -sfn server-0.1.0 ~/.local/lib/loom/server.rollback
mv -hf ~/.local/lib/loom/server.rollback ~/.local/lib/loom/server
```

then restart the daemon so it starts from the restored tree. The two
moves are the same atomic switch `install.sh` performs; doing it by hand
works because the layout does not distinguish who switched the link. The
`-h` is load-bearing on macOS and the BSDs: without it `mv` follows a
destination that is a symlink to a directory and moves the new link
*inside* the old tree instead of replacing the link. (GNU `mv` wants
`-T` for the same guarantee; `install.sh` tries both.)

One forward-compat limit to know before you roll back: a daemon started
by 0.2.0 or later writes a version-two endpoint record, and a pre-0.2.0
client reads only version one, so the rolled-back `loom` will not
*discover* a running newer daemon — it will try to launch one, find the
daemon already running, and tell you. Stop the newer daemon first, or
attach the older client by hand; the record itself is rewritten by
whichever daemon next starts.

The same-version reinstall has the mirror-image wrinkle: with a daemon
live, `install.sh` will not replace a version directory that already
exists, so a rebuild at an unchanged version number is NOT installed —
the installer prints a WARNING naming this, and the way out is to stop
the daemon and re-run the install, or bump the version.

Finally, the prune's liveness check is a one-way ratchet: if the
discovery record's PID belongs to a recycled, unrelated process (a
daemon that died without cleaning up its record), every install keeps
every version until the record is cleared. Deleting the stale
`daemon.endpoint` file restores pruning; nothing is lost but disk
either way.

## When the versions disagree and you do not expect them to

- **The daemon reports `dev`.** Its launcher did not export the identity
  variables — it was started by something other than an installed or
  released launcher, such as `gleam run` directly or an older install
  script. Start it through `bin/loomd`.
- **The client reports `dev` and the daemon a version.** The client binary
  is not the installed one (an old `loom` earlier on `PATH`, or a stale
  checkout's `bin/loom`). `which loom` names what ran.
- **Both report the same version but different commits.** Two trees were
  built from the same declared version but different revisions — normal
  during development, where the version string does not move every commit.
  The commit is the discriminator; compare it against `git rev-parse
  --short HEAD` in the tree you built from.
