# Install

This page shows how to install Loom from a release: download it, verify it, install it and update it with `loom update`. The last section builds Loom from source instead. The steps come from the repository's `docs/distribution.md`, `docs/updating.md` and `docs/running.md`. The release is built for one platform at a time, so you pick the archives that match your machine.

## Download a release

Open [the latest release](https://github.com/Roasbeef/loom/releases/latest) and download the archives for your platform. The release workflow builds Linux x86_64 (`linux-x86_64`) and macOS arm64 (`macos-arm64`). A release carries these files for each platform, where `{{version}}` is the release number without its `v`. The examples on this page use Linux x86_64, so substitute `macos-arm64` on a Mac:

| File | What it is |
|---|---|
| `loomd-{{version}}-<platform>.tar.gz` | The server. It carries the BEAM runtime, the sandbox helper `loom-exec`, the code-mode toolchain and a `SHA256SUMS` over every executable in it. |
| `loom-{{version}}-<platform>.tar.gz` | The terminal client with its own BEAM runtime. This is the one to download if you have no Erlang. |
| `loom-slim-{{version}}-<platform>.tar.gz` | The terminal client without a runtime. It uses the Erlang/OTP 29 on your `PATH`, which is the shape a package manager wants. |
| `manifest-<platform>.json` | The commit-bound manifest. It lists the three archives with their exact sizes and SHA-256 values. `loom update` verifies it. |
| `SHA256SUMS` | One checksum line for every other file in the release. |
| `reproduction.json` | The record of the byte-for-byte comparison between the two independent builds of each platform. |

Most people want the server and the self-contained client. The server and the client are separate downloads because they belong in different places: the client may run on a different machine from the server.

The release workflow does not sign anything. If the maintainers sign a manifest, they publish `manifest-<platform>.json.asc`, an armored OpenPGP signature of it. No production signing keys are bundled and unsigned manifests are allowed, so the HTTPS source is what vouches for an unsigned release.

## Verify the download

Put the files in one directory. Check each archive against `SHA256SUMS`. `SHA256SUMS` lists every file in the release, so check one archive at a time:

```sh
grep ' loomd-{{version}}-linux-x86_64.tar.gz$' SHA256SUMS | sha256sum -c -
grep ' loom-{{version}}-linux-x86_64.tar.gz$' SHA256SUMS | sha256sum -c -
```

On macOS, use `shasum -a 256 -c -` in place of `sha256sum -c -`. Each command prints `OK` for a file that matches.

If you have the signature and a key that you obtained through a separate channel, verify the manifest with `gpg --verify manifest-<platform>.json.asc manifest-<platform>.json`. The updater needs `gpgv` for this and never fetches keys.

## Install the release

Unpack both archives. Each unpacks to a directory named for the archive, with its commands in `bin`. Loom never writes an executable to disk at run time, so everything the server runs is a file that the archive put there.

```sh
lib="$HOME/.local/lib"
mkdir -p "$lib"
tar -xzf loomd-{{version}}-linux-x86_64.tar.gz -C "$lib"
tar -xzf loom-{{version}}-linux-x86_64.tar.gz -C "$lib"
export PATH="$lib/loomd-{{version}}-linux-x86_64/bin:$lib/loom-{{version}}-linux-x86_64/bin:$PATH"
```

`loom` looks for `loomd` on your `PATH`, so both `bin` directories have to be on it. Add the `export` line to your shell profile to keep it. The server also checks its own files: run `sha256sum -c SHA256SUMS` inside the unpacked server directory to check every executable and the code-mode seed.

Then check that the client runs:

```sh
loom version          # The client's version, commit and platform.
loom --demo           # The terminal with canned content. No daemon, network or provider.
```

## Check the sandbox

On Linux, the sandbox needs bubblewrap, user namespaces and delegated cgroup v2 resources. The repository's `packages/sandbox/README.md` and `docs/docker.md` describe the host setup.

By default the server refuses to start when a layer is missing: Linux must enforce everything, and macOS may lack only the three gaps that ADR-006 reports. `loomd --best-effort` accepts broader gaps for development machines, and `loomd --full-enforcement` demands the full contract on every platform.

## Choose a model

Copy the example catalogue from the repository to `~/.loom/loom.toml` and edit its model entries and role routes:

```sh
mkdir -p ~/.loom
curl -fsSL https://raw.githubusercontent.com/Roasbeef/loom/main/docs/examples/loom.toml -o ~/.loom/loom.toml
```

API keys stay in environment variables that the catalogue names, never in the file. Export them before you start the daemon. The [configuration page](#/docs/configuration) explains the file.

## Start a session

```sh
cd ~/src/my-project
loom
```

`loom` finds the shared local daemon or starts one, then opens the session picker. Choose **New session**, or pick a saved session to resume it. Inside a session, `/sessions` returns to the picker and `/model` switches to another model from your catalogue.

Starting the daemon and listing sessions open no session runtimes. A session opens when you select it.

## Update with loom update

`loom update` downloads a published release, verifies its manifest and archives, installs fresh immutable trees, and gracefully restarts the shared daemon. Running terminals keep their original client files until you reopen them.

```sh
loom version                      # The installed client's version, commit and platform.
loom update --check               # Verify the release metadata without installing.
loom update                       # Install the latest stable release.
loom update --version {{tag}}     # Install a published tag.
loom update --install-only        # Install, and leave the daemon restart to you.
```

Every archive must match its manifest's exact size and SHA-256. With `--keyring FILE --require-signature`, a signed manifest must also verify against your local keyring. Selecting the latest release refuses a known downgrade. An explicit tag is a deliberate choice and can move backwards.

A client that you unpacked by hand is unmanaged, so give it a prefix: `loom update --prefix DIR`. That makes `DIR` a managed install with its own `bin`, `lib/loom/server` and `lib/loom/client`, and the update restarts the daemon from `DIR/bin/loomd`. The trees you unpacked by hand are left alone, so put `DIR/bin` first on your `PATH` afterwards.

The updater waits up to 90 seconds for the old daemon to retire, then starts the new one and checks its commit. It never force-kills the old daemon. A daemon serves several workspaces, so coordinate the restart with anyone else who uses it. The repository's `docs/updating.md` covers rollback and cleanup.

## Build from source

Build from source if there is no release for your platform or you want to change Loom. You need these tools:

- Gleam 1.19.0.
- Erlang/OTP 29 or later. Only the build needs it. The installed client and server bundle their own BEAM runtime.
- Go 1.26 or later, which builds the sandbox helper `loom-exec`.
- `rebar3`.
- A C compiler, `make` and `strip`.

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

Every install writes fresh directories and switches links afterwards, so a running process keeps the files it started with. To check the sandbox on the machine where agents will run, use the helper's self-test:

```sh
make selftest
```

It prints `ENFORCED`, `SKIPPED` or `FAILED` for each probe.

To update a source build, run `make update` from a clean, committed checkout. It builds and smoke-tests its release artifacts, installs them and gracefully restarts the shared daemon. To package the archives that a release carries, run `make dist`. It writes the server tarball, the self-contained client tarball, the slim client tarball, a manifest and `SHA256SUMS`.

## Where to go next

- [Configuration](#/docs/configuration) for models, roles and limits.
- [Sessions](#/docs/sessions) for how a session is stored and resumed.
- [Terminal and web view](#/docs/terminal-and-web) for the two interfaces.
- [Approvals and sandboxing](#/docs/approvals-and-sandboxing) for what a command can touch.
- [Distributed runtime](#/docs/distributed-runtime) for running tools on another machine.
