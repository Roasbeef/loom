# Getting started

This page shows how to build Loom from source on Linux or macOS, which is how you get it today. This page covers the build, the first run, and how to update. The commands come from the repository's `README.md` and `docs/distribution.md`.

## What you need

You need these tools to build Loom:

- Gleam 1.19.0.
- Erlang/OTP 29 or later. Only the build needs it. The installed client and server bundle their own BEAM runtime.
- Go 1.26 or later, which builds the sandbox helper `loom-exec`.
- `rebar3`.
- A C compiler, `make` and `strip`.

On Linux, the sandbox also needs bubblewrap, user namespaces and delegated cgroup v2 resources. The repository's `packages/sandbox/README.md` and `docs/docker.md` describe the host setup.

## Build and install

```sh
git clone https://github.com/Roasbeef/loom.git
cd loom
make install
export PATH="$HOME/.local/bin:$PATH"
```

`make install` runs three builds in order: the code-mode seed, the self-contained server release, and the client. It then lays the result out under `~/.local`, or under `PREFIX` if you set one.

| Path under the prefix | What it is |
|---|---|
| `bin/loom` | The terminal client. |
| `bin/loomd` | The daemon. |
| `lib/loom/server` | A symlink to the installed server tree: the sandbox helper, the Gleam compiler, the code-mode seed and the BEAM runtime. |
| `lib/loom/client` | A symlink to the installed client tree, which also bundles the BEAM runtime. |

Every install writes fresh directories and switches links afterwards, so a running process keeps the files it started with.

> **Packaging a release.** `make dist` writes `dist/` with a server tarball (`loomd-<version>-<platform>.tar.gz`), a self-contained client tarball (`loom-<version>-<platform>.tar.gz`), a slim client tarball (`loom-slim-<version>-<platform>.tar.gz`) that uses the Erlang/OTP 29 on your `PATH`, a commit-bound manifest and `SHA256SUMS`. A release is built for one platform. `docs/distribution.md` in the repository lists what each tarball carries.

## Check the sandbox

Loom runs commands in a kernel sandbox, and its helper can tell you which layers your kernel provides. Run this on the machine where agents will run:

```sh
make selftest
```

It prints `ENFORCED`, `SKIPPED` or `FAILED` for each probe. By default the server refuses to start when a layer is missing: Linux must enforce everything, and macOS may lack only the three gaps that ADR-006 reports. `loomd --best-effort` accepts broader gaps for development machines, and `loomd --full-enforcement` demands the full contract on every platform.

## Try the demo

```sh
loom --demo
```

The demo draws the terminal with canned content. It needs no daemon, no network and no model provider.

## Choose a model

Copy the example catalogue to `~/.loom/loom.toml` and edit its model entries and role routes:

```sh
mkdir -p ~/.loom
cp docs/examples/loom.toml ~/.loom/loom.toml
```

API keys stay in environment variables that the catalogue names, never in the file. Export them before you start the daemon. The [configuration page](#/docs/configuration) explains the file.

## Start a session

```sh
cd ~/src/my-project
loom
```

`loom` finds the shared local daemon or starts one, then opens the session picker. Choose **New session**, or pick a saved session to resume it. Inside a session, `/sessions` returns to the picker and `/model` switches to another model from your catalogue.

Starting the daemon and listing sessions open no session runtimes. A session opens when you select it.

## Update

```sh
loom version          # The installed client's version, commit and platform.
loom update --check   # Look at published release metadata without installing.
make update           # Build and activate the current checkout.
```

`make update` runs from a clean, committed checkout. It builds and smoke-tests its release artifacts, installs them, and gracefully restarts the shared daemon. Reopen your terminals afterwards to use the new client. `loom update` without `--check` installs a published release, when one exists for your platform.

Coordinate a daemon restart with anyone else who uses the same daemon. The repository's `docs/updating.md` covers restarts and rollback.

## Where to go next

- [Configuration](#/docs/configuration) for models, roles and limits.
- [Sessions](#/docs/sessions) for how a session is stored and resumed.
- [Terminal and web view](#/docs/terminal-and-web) for the two interfaces.
- [Approvals and sandboxing](#/docs/approvals-and-sandboxing) for what a command can touch.
