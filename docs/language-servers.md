# Set up language servers

Loom's language-server capabilities give the agent semantic definitions,
references, types, diagnostics and rename operations. Install a language profile to select
the server and its sandbox permissions. The profile is configuration data;
the server binary and language toolchain are separate prerequisites.

The maintained profiles are
[Gleam](https://github.com/Roasbeef/loom-lsp-gleam),
[Go](https://github.com/Roasbeef/loom-lsp-go) and
[Rust](https://github.com/Roasbeef/loom-lsp-rust). Install any combination you
need. Loom has no built-in server profiles, and starts a server on demand.

Fresh sessions expose `cap/lsp` through `code_mode` when a profile is available.
The system prompt directs agents to prefer it for semantic questions, and
`fs_read` at `cap://lsp` provides the full API and installed language hints.
There are no default top-level `lsp_*` tools. Existing saved sessions retain
their pinned prompt; start a fresh session to receive the new guidance.
Unsupported methods need a supported query or text search; a server load
failure needs its reported setup or access problem corrected before retrying.

For joins and aggregates over explicit outline files and reference targets,
see [Query language-server facts with SQL](lsp-sql.md). It uses the same
profiles and jailed servers through `cap/lsp_sql` in code mode.

## Prepare Loom and the daemon environment

Use a Loom build that includes [the LSP stack](https://github.com/Roasbeef/loom/pull/680).
From a clean source checkout containing that merge, `make update` builds,
installs and activates it. See [Updating Loom](updating.md) for published
releases and graceful restart. `loom version` identifies the installed client;
it does not identify an already running daemon.

Install `rg` (ripgrep) and the language prerequisites below on the daemon's
host. Bare-symbol queries use `rg` to find candidate files. Put the tools on
the PATH used to start the daemon; changing PATH in an attached terminal does
not update the daemon's environment. A service manager needs those settings
in its own configuration. Coordinate a graceful restart when changing the
environment of a shared daemon.

The commands below use `loomd ext`, which also works as `loom ext`. Extension
installs live under `~/.loom/extensions`. Run them as the daemon's user. For a
different home, `install` and `check` accept `--home /path/to/home`; that path
selects the home containing `.loom/extensions`, not the extensions directory
itself. `--state-dir` selects daemon state separately and does not change this
extension installation location. The daemon's `--home` also selects where it
loads approved extensions. Install into that same home if it was overridden.

`--home` does not change the checking process's environment. Profile `~/` roots,
cache locations and server HOME still come from that environment. Run the check
with the same home and tool settings as the daemon it is meant to validate.
Run `loomd ext install`, `list`, and `check` from the host terminal. A jailed
Bash call has a private `HOME` under `.codemode/home`; its extension commands
inspect that private installation rather than the daemon's global one. A
nested `ext check` may also be refused when it tries to create its own jail
and scratch directory. That refusal does not mean the host check failed.

## Gleam

Install Gleam and its normal project toolchain using the
[Gleam installation instructions](https://gleam.run/install/).
There is no separate Gleam language-server package: the server is `gleam lsp`.
Check that the shell running the profile check can find both prerequisites:

```sh
gleam --version
command -v rg
loomd ext install https://github.com/Roasbeef/loom-lsp-gleam --rev v0.1.0
loomd ext check lsp_gleam
```

In a real session, the bare `gleam` command uses the compiler located for code
mode when one is available. The standalone `ext check` does not locate a
code-mode toolchain, so it resolves `gleam` from its invocation's PATH.

A profile that declares `prepare = "gleam-dependencies"` prepares the selected
package automatically before its first server starts. Loom runs `gleam deps
download` in that package through a finite sandbox job with network access,
then starts `gleam lsp` with networking off. Warm queries reuse the prepared
server. A new worktree needs no manual download when this recipe is approved.

The recipe is opt-in authority. The published v0.1.0 profile predates it and
retains its previous permissions until you install an updated profile and
start a new session. To opt in with an operator-owned `loom.toml` table, copy
the complete Gleam profile and add:

```toml
prepare = "gleam-dependencies"
cache_env = { XDG_CACHE_HOME = "hex" }
```

The command must be `["gleam", "lsp"]` (or an explicit Gleam executable), and
`project = "writable"` is required. Approval grants full network access to one
setup call, bounded by 60 seconds wall and CPU time and 1 MiB per output stream.
It does not grant networking to the language server or ordinary tools. Setup
and LSP share a private HOME and cache; this also gives macOS Gleam its private
`HOME/Library/Caches` directory. The operator's package archives and credentials
are not shared.

The profile chooses the nearest `gleam.toml` above the queried file. In a
monorepo, preparing one package does not prepare another package's
`build/packages/packages.toml`. Loom prepares each selected root on its cold
start and permits sibling reads only within the session-authorized workspace.
For the automatic recipe, path dependencies must be workspace-local. Changes
to those package configurations, the selected manifest, or its installed
inventory restart the server and rerun preparation. Source edits keep the
normal LSP synchronization behavior.

A failed download returns the selected package and the setup failure. Fix the
registry, dependency or setup-policy error before retrying; sleeping cannot
complete a download inside the offline server. With an older profile, prepare
the exact project outside the LSP jail:

```sh
cd /path/to/selected-gleam-package
gleam deps download
```

Preparing dependencies does not compile the whole repository. Gleam resolves
the package and its path dependencies, writes the installation inventory, and
the language server then compiles the project for analysis.

For Loom's own monorepo, `make lsp-seed` downloads dependencies for every
workspace package and repeats resolution until each inventory is stable.
It is separate from `make codemode-seed`, whose dependency graph belongs to
submitted satellite programs. Run both after changing capabilities or preparing
a fresh workspace for analysis. Neither target grants networking to an LSP
server. The automatic recipe remains the supported way to prepare an arbitrary
project through the approved profile's private cache.

On macOS, Loom resolves `/usr/bin/git` through the host's `xcrun` before the
Gleam downloader or server starts, then puts the real Git directory on their
PATH. This avoids invoking Apple's shim with a jailed HOME. A PATH entry does
not grant a read: a Git inside a nonstandard Xcode installation must still
fit the session or profile's readable roots. If the host itself cannot run
`xcrun --find git`, install or select the Command Line Tools, or put a working
Git ahead of `/usr/bin` on the daemon's PATH.

`lsp.diagnostics(None)` is a partial snapshot of the current package server,
always returned as `Unsettled`. It cannot establish that the whole workspace
is clean, even after a healthy control query. Use an explicit file path for a
settled answer; a package whose server cannot start returns an error for that
file rather than a clean result.

## Go

Install Go, then install `gopls`. With the default Go executable directory:

```sh
go install golang.org/x/tools/gopls@latest
export PATH="$(go env GOPATH)/bin:$PATH"
go version
gopls version
command -v rg
loomd ext install https://github.com/Roasbeef/loom-lsp-go --rev v0.1.0
loomd ext check lsp_go
```

If you set `GOBIN`, add that directory instead. Include the same executable
directories in the daemon's PATH, including the directory containing `go`.
`gopls` invokes `go list`; finding `gopls` alone is insufficient.

Prepare the project's module dependencies outside the jail:

```sh
cd /path/to/go-project
go mod download
go env GOROOT GOMODCACHE
```

The profile selects `.go` files beneath a `go.mod` root. It assumes the module
cache is `~/go/pkg/mod`. Go installations under `/usr`, `/opt` or macOS
Homebrew's `/opt/homebrew` are covered by the jail's system view. A custom
GOROOT, such as `~/sdk`, or a different module cache needs a configuration
override described below.

The Go profile keeps the project read-only and uses private writable caches
for `GOCACHE`, `GOPLSCACHE` and `XDG_CACHE_HOME`. Keep those `cache_env` settings
in an override; granting the host's ordinary writable build cache would mix
jailed work with artifacts trusted by host builds.

## Rust

With a rustup-managed toolchain, install the server and standard-library
sources, then fetch the standard library's dependencies for the host target:

```sh
rustup component add rust-analyzer rust-src
RUSTC_BOOTSTRAP=1 cargo fetch --target "$(rustc -vV | sed -n 's/^host: //p')" \
  --manifest-path "$(rustc --print sysroot)/lib/rustlib/src/rust/library/Cargo.toml"
export PATH="$HOME/.cargo/bin:$PATH"
rust-analyzer --version
command -v rg
loomd ext install https://github.com/Roasbeef/loom-lsp-rust --rev v0.1.0
loomd ext check lsp_rust
```

The standard library is a Cargo workspace too. Its dependencies need to be
cached before the server starts because the jail has no network.
`RUSTC_BOOTSTRAP=1` applies only to that fetch command: the standard-library
manifest uses an unstable Cargo feature. See the
[Rust profile's setup explanation](https://github.com/Roasbeef/loom-lsp-rust#what-the-host-must-hold).

Prepare a lockfile and fetch the project's dependencies outside the jail:

```sh
cd /path/to/rust-project
# If the project does not already have Cargo.lock:
cargo generate-lockfile
cargo fetch --locked
```

The profile selects `.rs` files through `Cargo.toml`. It reads `~/.rustup` and
`~/.cargo/registry` and keeps the project read-only. Without `Cargo.lock`,
Cargo metadata may try to create it and fail. Keep the lockfile with the project.
Custom `RUSTUP_HOME` or `CARGO_HOME` layouts need a complete configuration
override naming their actual roots and passing through those environment
variable names.

The shipped Rust profile grants no writable build directory. Crates that need
generated output from build scripts or proc macros can therefore have incomplete
analysis. A successful fixture check proves the included small crate works;
it does not establish full analysis of every Rust project.

## Verify installation and activate it

```sh
loomd ext list
loomd ext verify lsp_go
loomd ext check lsp_go
```

Substitute `lsp_gleam` or `lsp_rust` for the selected profile. `verify` checks
the installed record and tree. `check` copies the profile's fixture to a fresh
scratch workspace, runs its server through the jail, and tests definition and
reference queries. It prints the enforcement report and individual outcomes;
each shipped profile currently has two checks. Any failed check exits nonzero.
This requires no model invocation or inference cost.

Start a new Loom session in the project after installing a profile. Existing
resident sessions keep the profiles loaded when they booted. A graceful daemon
restart followed by explicitly reopening the saved session reloads them; closing
and reattaching a terminal alone does not rebuild a resident session.

For a first query, ask the agent to find a definition and its references using
`cap/lsp` inside code mode. Qualify names as the code spells them:

| Language | Example | Project marker |
|---|---|---|
| Gleam | `util.greet` or `pkg/mod.name` | `gleam.toml` |
| Go | `util.Greet` | `go.mod` |
| Rust | `util::greet`, without a leading `crate::` | `Cargo.toml` |

The typed `cap/lsp` module provides `definition`, `references`, `hover`,
`outline`, `calls`, `diagnostics` and `rename`. Build a query with `lsp.symbol`,
then narrow it with `lsp.in` and `lsp.at_line` using a workspace path and
one-based line. Read `cap://lsp` for exact signatures before writing a program.
Call hierarchy support depends on the server; use references when unsupported.

Rename requires an explicit `lsp.Preview` or `lsp.Apply`. Preview first and
inspect the plan before submitting a separate apply program. Apply is not
atomic across files; Loom checks every base before writing and reports each
outcome. Automatic diagnostics remain on `fs_write` and `fs_edit` results.

## Custom paths and configuration

The daemon's `loom.toml` can declare `[lsp.gleam]`, `[lsp.go]` or `[lsp.rust]`
instead of using an installed profile. A table of the same name replaces the
installed profile **entirely**, so copy the full table before modifying it.
The maintained tables are in each repository's `extension.toml`:
[Gleam](https://github.com/Roasbeef/loom-lsp-gleam/blob/main/extension.toml),
[Go](https://github.com/Roasbeef/loom-lsp-go/blob/main/extension.toml) and
[Rust](https://github.com/Roasbeef/loom-lsp-rust/blob/main/extension.toml).
The [catalogue example](examples/loom.toml) documents every configuration key.

For example, a complete Go table can retain its private caches while allowing
a custom toolchain and module cache:

```toml
[lsp.go]
command = ["gopls"]
extensions = [".go"]
root_markers = ["go.mod"]
readable = ["~/sdk/go", "~/go/pkg/mod"]
cache_env = { XDG_CACHE_HOME = "xdg", GOCACHE = "go-build", GOPLSCACHE = "gopls" }
env = ["GOFLAGS", "GOROOT", "GOPATH", "GOMODCACHE"]
hint = "Qualify a name with its package name as imported: util.Greet"
```

Replace the readable roots with your actual `go env GOROOT` and
`go env GOMODCACHE` locations. For a custom module cache, set `GOMODCACHE` in
the daemon's environment as well as granting the readable root. The example
forwards `GOROOT`, `GOPATH` and `GOMODCACHE` when set; granting a directory does
not tell Go to use it. `command` is an argv array, not a shell command.
Restart the daemon after editing its catalogue.
`ext check` tests the installed profile, not a same-name catalogue override;
verify an override with a real query in a newly opened session.

## Troubleshooting and maintenance

| Symptom | Check |
|---|---|
| `cap/lsp` absent from code-mode discovery | Install a profile or configure a table, then start a new session. Check `ext list` for refused profiles. |
| Executable not found | Check the daemon's PATH and the PATH of the standalone `ext check` invocation. A terminal's new PATH does not update a running daemon. |
| Empty or incomplete results | Check dependencies, project markers, custom readable roots and the Rust restrictions above. Narrow the symbol with a path and line. |
| Server still loading | Retry after the reported readiness delay. Unsettled diagnostics do not mean the project is clean. |
| Dependency preparation failed | Read the named package and downloader error. Fix the dependency, registry or setup policy before retrying. The offline server was not started. |
| Profile conflict | Only one effective profile may own a file extension. Remove the duplicate or replace it with an explicit catalogue table. |
| Jail probe refused | Read the reported missing enforcement layers and correct host setup using the [sandbox guide](../packages/sandbox/README.md). |
| Fixture passes but project fails | Fixtures are small and self-contained. Check the real project's external dependencies, environment and generated-code requirements. |

To change versions, record the installed revision, remove the existing profile,
then install the desired published revision and run its checks. The installer
refuses an existing name rather than overwriting it. Activate the new profile
in a new session. To remove a profile:

```sh
loomd ext remove lsp_go
```

Removal affects subsequent session boots; a configured `[lsp.go]` table still
provides Go support. The [LSP architecture](architecture/lsp.md) explains
server ownership and isolation, and the
[extension lifecycle](architecture/extensions.md) explains installation,
verification and profile precedence.
