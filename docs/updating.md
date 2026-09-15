# Updating Loom

Installing a new build leaves running clients and daemons on their original
files. Restart the daemon when you want it to use the new build. This guide
covers installation, restart, rollback, and cleanup; [distribution](distribution.md)
describes the release artifacts.

## Install the new build

From a checkout containing the revision you want:

```sh
make install
# Or use the host's Erlang for the terminal client:
make install INSTALL_CLIENT=slim
```

`PREFIX` defaults to `$HOME/.local`. For example,
`make install PREFIX="$HOME/.local/loom-test"` installs a separate set of
launchers and release trees. A separate prefix still uses the default daemon
state root unless you select another with `--state-dir`.

Before updating an existing installation, record the targets of its `server`
and `client` (or `tui`) links if you want to identify the rollback pair later.
`readlink "$HOME/.local/lib/loom/server"` prints the selected server path.

The installer copies complete builds into fresh directories, then atomically
switches the `server` and selected client links. An example layout is:

```text
~/.local/lib/loom/server.N8jK6tQx/
~/.local/lib/loom/server -> /.../server.N8jK6tQx
~/.local/lib/loom/client.L2rP5cVz/
~/.local/lib/loom/client -> /.../client.L2rP5cVz
```

The suffix identifies an installation, not a version. Reinstalling a rebuilt
0.2.0 creates another directory and installs its new contents. It never skips
a same-version rebuild because an older daemon is running. The slim client
uses `tui.<suffix>` and a `tui` link instead of `client`.

Each launcher resolves its selected tree to a physical path before starting
the runtime. The daemon can keep loading its original helper, compiler, seed,
and BEAM files after another installation changes the links. Slim clients also
keep physical module paths, and use the profiling launcher packaged with their
shipment. Launchers themselves are replaced by renaming complete files.

Publication is atomic per link or launcher, not a transaction across the whole
installation. An interrupted install can leave complete client and server
builds from different installations selected. Rerun installation to select a
complete pair. Failed copies remain on disk, but are never published as a
successful release.

The installer never restarts a daemon or deletes an older release tree. Disk
usage grows with each installation; see manual cleanup below.

## Migrate a legacy installation

An older installation may have real directories at `lib/loom/server`,
`lib/loom/client`, or `lib/loom/tui`. The installer refuses that layout before
copying or switching anything. Renaming a live directory is unsafe because a
process may later load a file using the old absolute path.

To migrate, stop every daemon and client using that prefix and prevent them
from restarting during maintenance. Move the legacy directories to unused
backup names, then run `make install` again. Keep the backups until you have
verified the new installation. If you cannot stop those processes, install
under a fresh prefix and leave the old prefix intact. Do not infer that every
process has stopped merely because a daemon endpoint record is absent.

## Check the build and restart deliberately

The release and shipment launchers export `LOOM_BUILD_VERSION` and
`LOOM_BUILD_COMMIT`, captured when the artifacts are built. Installing an older
artifact does not relabel it with the installer's current git revision.
Builds without git metadata report `unknown`; direct development entrypoints
without identity report `dev` and `unknown`.

The authenticated daemon hello carries its build identity. If it differs from
the terminal's identity, the terminal appends a notice naming both builds and
explaining that the daemon needs a restart. Matching builds are silent. A
daemon predating build identity is also silent; that absence does not prove
the builds match. Build comparison is informational and does not establish
compatibility with an arbitrary future wire protocol.

A daemon serves multiple workspaces. Coordinate its restart with their users.
Use its process manager's graceful stop, or send SIGTERM to the daemon PID you
have positively identified. The authenticated `daemon.shutdown` control
command also requests graceful shutdown. Do not use an unverified stale PID
from an endpoint file. Force-killing the daemon cannot perform a graceful
drain.

During graceful drain the daemon refuses new mutations and attempts to return
held prompt text to the submitting connections before it closes their
sockets. The terminal restores returned text as a draft, appending it beneath
any text already in the composer. Image bytes are not returned: reattach the
images named in the notice before resubmitting. Held input is memory-only;
a disconnected client or expired drain budget can prevent its return.
Socket-write confirmation does not prove the client received or saved it.

The daemon requests aborts for in-flight turns within its bounded shutdown
budget. Confirmed aborts remain in the durable transcript with the existing
generic interrupted diagnostic. Shutdown still requires the original lifetime
retirement evidence; a timeout is not proof that cleanup finished.

A locally launched terminal with an attached session makes one bounded
relaunch/reattach attempt after daemon loss. A remote attachment does not
launch a daemon. If recovery fails, reopen `loom` and select the saved session;
uncertain submissions are not automatically replayed. Installing files does
not hot-load code into a running VM.

## Roll back

Coordinate shutdown first, including local terminals that could automatically
relaunch the daemon. Select a retained server tree and the matching client tree
from the release you want. Each link can be replaced atomically; on macOS:

```sh
lib="$HOME/.local/lib/loom"
ln -s "$lib/server.N8jK6tQx" "$lib/server.rollback"
mv -hf "$lib/server.rollback" "$lib/server"
ln -s "$lib/client.L2rP5cVz" "$lib/client.rollback"
mv -hf "$lib/client.rollback" "$lib/client"
```

Substitute your actual retained paths. On GNU/Linux use `mv -Tf` instead of
`mv -hf`. Use `tui` for a slim client. The installed `loom` wrapper selects the
client shape chosen at installation, so switching between bundled and slim
shapes requires reinstalling the chosen shape. Restart after both links name
the intended builds. The installer preserves old client-shape links too.

An older client that only understands endpoint schema version one cannot
read a version-two endpoint, even after its daemon exits. That record survives
shutdown. Such a downgrade requires an offline endpoint recovery step using a
schema the older release accepts, preserving the recorded native fence. Do not
delete the record alone: an existing catalogue without its fence also fails
closed. This guide does not provide an automatic schema downgrade; use a
release-specific recovery procedure before attempting that rollback. Retaining
binaries does not establish backward compatibility of future durable data
formats either: check the release's compatibility notes.

## Manual cleanup

Keep every tree selected by `server`, `client`, or `tui`, and any rollback
builds you want. Remove other trees only after establishing that no running
client or daemon uses them. A current/previous-link policy is insufficient:
a long-lived process can survive several installs, and clients are not
represented by the daemon endpoint record.

The simplest maintenance procedure is to stop all Loom clients and daemons
using the prefix, prevent automatic restarts, inspect the links, and remove
only explicitly selected obsolete directories. Interrupted unpublished copies
can be removed during that same maintenance window. Normal installation
performs no pruning.
