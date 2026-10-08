# Distribution

How Loom is packaged for somebody who wants to *run* it rather than work
on it, what that costs, and why the sandbox helper ships as a file beside
the server rather than inside it.

The historical size measurements below were taken on the Linux x86_64 CI runner with Gleam 1.18.1,
Erlang/OTP 29.0.5 (ERTS 17.0.5), and Go 1.26.3 by running the targets it
describes. They are not fresh measurements of the single-daemon implementation.
Current verification and remaining release gates are recorded in [next.md](next.md).

Ordinary source builds use released Gleam, currently 1.19.0. The `sqlight_loom` and `esqlite_loom` Hex packages supply the
SQLite repair, including the Rebar metadata that builds its C library. The
`stock compiler` CI jobs build and smoke-test the distribution with
unmodified Gleam on Linux and macOS. The tree still compiles with 1.18.1,
but the 1.19 formatter lays out long constants differently, so
`make fmt-check` expects 1.19.

The native seed must also survive relocation. Rebar creates an absolute link
from its production `pc` build plugin to the default-profile plugin inside the
seed. After compilation settles, seed preparation replaces only that known
link with regular files before checking the relocated offline clone. It refuses
an external target or nested links; the release archiver keeps its existing
link restrictions. The helper is included in the release recipe digests.

Reproducible release jobs use the maintained compiler described in the
[toolchain instructions](../scripts/toolchain/gleam/README.md). It is the
release tag, which carries the upstream path-dependency freshness fix for
issue #248, with the local compiler patches applied, including deterministic
cache serialization. Starting from the release tag retains its formatter. These jobs and both Docker recipes
include the patch digest in their compiler cache keys. A release-builder
image must be rebuilt and its immutable digest updated when its compiler
inputs change. Ordinary builds are not required to reproduce those bytes.

## The problem

`gleam export erlang-shipment` is Gleam's only packaging verb, and what
it produces is compiled BEAM files: 11 MB and 208 `.beam` for the
`client` package and its dependency closure, with no runtime system in
it. `make server-shipment` writes a `bin/loomd` shim over that,
and the shim `exec`s `erl`. So the shipment answers "how do I move the
code" and not "how do I run it on a machine that has no Erlang", which
is the question a download has to answer.

## The mechanism: an OTP release with `include_erts`

`make release` assembles an OTP release with the runtime system copied
into it, so the machine that runs it needs no Erlang installed. There is
no Gleam-native way to ask for that, so the release is built by
rebar3/relx over Gleam's own shipment output — the shipment is the one
artifact in the tree that already carries every dependency's `ebin` and
`priv` in one place, so relx needs nothing but a `lib_dirs` pointing at
it and works out the application closure itself. `scripts/release.sh`
generates the `rebar.config`; there is no checked-in one, because the
release version and the ERTS version are both read from the tree at
build time.

**To build**: `gleam`, `rebar3`, `erl`, `go`, `strip`, and a prepared
build seed (`make codemode-seed`, which is the one step in this tree
allowed the network; `DIST_CODEMODE=0` drops that requirement and the
bundle with it). **To run what comes out**: nothing. `make release-smoke`
proves that second claim rather than asserting it — it boots the built
release with `env -i PATH=/usr/bin:/bin`, so neither `erl` nor `gleam` is
reachable, and requires authenticated v2 readiness, a 401 from an unauthenticated
v2 control connection, a written catalogue with no resident sessions, explicit
admission of two sessions, and confirmed daemon shutdown on SIGTERM. It also
checks the code-mode and helper behavior described below. The target has an
independent 180-second process deadline and requires Python for that watchdog;
the downloaded daemon does not require Python.

One dependency in that closure is not the one hex publishes. The websocket
listener needs a per-connection frame ceiling, which mist and gramps do not
expose upstream, so the client shipment resolves both from forks:
`mist` at `Roasbeef/mist` revision `65b29375`, and `gramps` at
`Roasbeef/gramps` revision `a37a8ae3`, pulled in transitively by the mist
fork. The forked framing code is therefore inside the artifact people
download, and reproducing a build needs both git remotes rather than only
hex. [ADR-011](adr/011-bounded-websocket-forks.md) has the reasoning, the
upstream pull requests, and the maintenance cost.

The Markdown skill loader also pins `glaml` to `Roasbeef/glaml` revision
`084857e`, proposed upstream in
[glaml PR #6](https://github.com/katekyy/glaml/pull/6). Version 3.0.2 declares
`yamerl` both as a dependency and in `extra_applications`, producing duplicate
entries in its OTP application metadata. Ordinary application startup accepts
that metadata, but relx refuses it when assembling either the server or client
release. The fork removes only the redundant declaration; parser source and the
normal dependency remain unchanged. Return to Hex when a release carries the
fix. Both release scripts retain relx output so assembly errors appear in CI.

The public `openai-responses` adapter is Gleam code inside the existing
provider application. It adds no release component or native helper and
uses the same HTTP transport as the other API-key adapters. The release
does not read Codex credential files, refresh subscription credentials, or
bundle Codex App Server. [ADR-012](adr/012-responses-and-subscription-boundaries.md)
records why subscription inference remains deferred.

The build places one compiled test probe in `build/release/smoke-support`,
outside the distributed `loom` tree. The smoke runs that probe on the bundled
emulator, using the server's existing WebSocket transport. It adds no test
command to `loomd` and needs no host Erlang to drive control requests.

### What was rejected

**Burrito.** It is Mix/Elixir tooling, so adopting it means adding a
whole language toolchain to a build that today needs only Gleam, OTP and
Go — too much for a packaging convenience. Its cross-compilation
advantage is also small here: `esqlite3_nif.so` must be compiled for the
target, and the moment the NIF's build does not cooperate with a
cross-compiler you are building per-platform anyway, which is the thing
Burrito was supposed to avoid. And its extract-and-exec model is the
hazard discussed below applied to the entire payload rather than to one
file.

**A self-extracting archive.** A single downloadable file is nicer than
a tarball, and a shell stub over this same release tree would produce
one. It is a follow-up, not a prerequisite: it buys presentation and
costs the property in the next section. If it is built, the extraction
directory has to be argued from scratch.

**relx's own launcher.** The release is assembled by relx but does not
ship relx's start script. That script is a daemon supervisor: it starts
a *distributed* node from a `vm.args` relx generates with `-sname loom
-setcookie loom`, and offers `ping`/`rpc`/`remsh` over it. A guessable
cookie on a node that accepts remote calls is exactly what the design's
two-channel doctrine says must never be the default — native
distribution never crosses a trust boundary — and Loom has no control
plane for it to serve anyway. `scripts/release.sh` deletes relx's start
scripts and the `vm.args` and `sys.config` only they read — but not the
`*.boot` files sharing that directory, which are standard OTP and which
the bundled `escript` needs, and which an earlier `rm -f bin/*` was
quietly taking with them — and writes a launcher that is the shipment entrypoint's invocation with two changes:
`erl` is the bundled one, and the boot script is `no_dot_erlang`, so a
`~/.erlang` nobody audited is not evaluated inside the harness VM on the
way up.

## The helper ships beside the release, and nothing is extracted at run time

`loom-exec` is the component that builds namespaces, applies Landlock
and seccomp, drops privileges and reports what the kernel actually
enforced. Rule Zero rests on it being a **different OS process** from
the harness VM, and that is unchanged by packaging: the broker still
spawns it, still speaks the framed msgpack protocol to it over stdio,
and still reads its enforcement report. Bundling it into a download is
fine; collapsing it into the harness process would not be.

The packaging question is narrower: does the artifact carry the helper
as an embedded blob written to disk on first run, or as a file that is
simply *there* once the tarball is unpacked? It is the second, and the
property worth stating outright is:

> **Loom never writes an executable to disk at run time and then execs
> it.** Every binary the artifact runs — the emulator, the NIFs, the
> helper — is a file the tarball put there, at a path the person who
> unpacked it chose, with the permissions their umask gave it.

That is not a small property, because the alternative is the well-worn
hazard: an executable extracted to a predictable path and then run. Had
the helper been embedded, every one of these would have needed an answer
and a test — where the extraction directory lives and whether any other
uid can create it first; whether it is verified to be owned by the
invoking user rather than repaired into place; what two instances
starting concurrently do about a half-written tree, and whether "the
directory exists" is a sound completeness test; whether a digest is
checked before exec, on first run or on every run, and what that digest
proves when it travels inside the same file as the payload it describes.
The honest answer to that last one is *not much against a same-uid
attacker*, who can rewrite the downloaded artifact itself — which is
precisely why paying the complexity was the wrong trade when a file
beside the binary costs nothing.

What the release does instead:

- `bin/loom-exec` sits next to `bin/loomd` in the unpacked tree, and the
  **server finds it there itself**. The launcher used to inject
  `--helper "$here/loom-exec"`, because the server's ladder was
  `--helper`, then `PATH`, then `./bin` and an unpacked release is none
  of those. That injection is gone; the ladder is now `--helper`, then
  the tree this server shipped in, then `PATH`, then `./bin`. An
  operator who wants a separately packaged or separately audited helper
  still wins, which is what that flag already means. See "The
  installation anchor" below for how the tree is located, and #101 for
  why it had to stop being the launcher's job.
- `SHA256SUMS` in the tree covers every executable file in it — the
  helper, every NIF, the bundled `gleam` — **and everything under
  `share/`**, which is the build seed. That second half is not
  thoroughness for its own sake: the seed holds `vendor/cap`,
  `vendor/core` and `vendor/ext` — the two preludes compiled into every
  satellite a code-mode program or an installed extension runs as — so a
  tampered seed is arbitrary code inside every jailed node. "Executables only" would have left the one part of the
  tarball that *becomes* code without being one outside the manifest.
  Every listed file is checkable with `sha256sum -c` from the moment the
  tarball is unpacked, by anyone, at any later time — which is the thing a
  blob inside a binary is not. The count is deliberately not part of the
  contract because the OTP and seed closures change across toolchain releases.
- The helper is byte-identical across `make binaries`, `make sandbox`
  and `make release`, because all three go through `scripts/go-build.sh`
  with the same `-trimpath -ldflags="-s -w"`. That is what makes `make
  selftest`'s ENFORCED/SKIPPED verdict evidence about the *shipped*
  helper rather than about a development build of it.

## The installation anchor: `code:root_dir()`

Four of the release's own components are looked for by the running
server: the sandbox helper, the emulator a code-mode satellite is
launched with, the Gleam compiler a program is built with, and the build
seed that build is cloned from. All four used to be looked up on `PATH`,
or in the seed's case at a fixed workspace-relative path.

**One measurement first, because without it this section claims more than
it delivers.** OTP's `erl` start script prepends `$BINDIR:$ROOTDIR/bin`
to `PATH` before it execs the emulator. Booting the release with
`env -i PATH=/usr/bin:/bin` and asking the VM gives:

```
PATH=<root>/erts-17.0.5/bin:<root>/bin:/usr/bin:/bin
```

So a release was **not** failing to find `erl` — #102's "it is simply not
on `PATH`" is wrong about the mechanism, though right that code mode was
absent — and it would not fail to find a `loom-exec` or a `gleam` placed
in its `bin/`. The launcher's `--helper` injection was never load-bearing.
Nor does #101's precedence worry arise in a release: the tree's own `bin`
is at the *front* of that `PATH`, so a stray `loom-exec` later on it never
wins. That worry is real for every **non-release** run, and the anchor
does not help there either — under an OTP installation root there is no
`loom-exec` to find, so a checkout still resolves `PATH` before `./bin`.
An operator who cares passes `--helper`, and `./bin` was deliberately not
promoted above `PATH`, because a working-directory executable outranking
`PATH` is a hazard of its own rather than a repair.

What is left is still worth doing, and it is two things. A release that
works *because a start script rewrites an environment variable* is an
accident being relied on: undocumented, inherited by every process the VM
later spawns, and untrue the day the launcher execs `beam.smp` directly.
And no `PATH` mechanism will ever find `share/codemode-seed`, which is
not an executable — that rung is genuinely new, and it is the one a
mutation of the release smoke can actually break.

The obvious way to state the anchor is "the directory of the running
executable", and **on the BEAM that phrase is ambiguous**. What the operating system executed
is `beam.smp`, several directories down inside `erts-<vsn>/bin`; what the
operator typed is a shell script that has already `exec`ed away. Neither
is the release root.

OTP answers the question itself. `code:root_dir/0` returns the `ROOTDIR`
the emulator resolved for itself at boot:

| how Loom was started | `code:root_dir()` |
|---|---|
| an unpacked release, through `bin/loomd` | the release root — the directory holding `bin/`, `lib/`, `releases/` and `erts-<vsn>/` |
| `gleam run`, the erlang shipment, a dev shell | the OTP installation root the `erl` on `PATH` came from — `/usr/local/otp` on the development container |

Both were checked by running them. It is absolute in both cases, it does
not move with the working directory, and it survives being reached
through a launcher or a symlink, because the emulator resolved it rather
than argv. That is why the anchor lives in `client/install` rather than
in the generated launcher: the launcher is where #101 was already being
papered over, and fixing it there again would have been the same defect
in a new place.

**Nothing special-cases the second row.** The paths are probed and
existence is the whole discriminator:

- `bin/loom-exec` and `bin/gleam` do not exist under an OTP installation
  root, so those rungs are skipped and the ladder falls through to `PATH`
  exactly as before — which, for a *release*, is the same answer the rung
  itself gives, per the measurement above. If a `loom-exec` ever *is*
  installed there, that is a Loom installed there and finding it is right.
- `erts-<vsn>/bin/erl` exists under **both**, and under an OTP
  installation it is the very emulator running the harness. So that rung
  answers on a development host too — and answers *better* than `PATH`
  does, because a satellite loads `.beam` files the hermetic build just
  produced and the running emulator is by construction the one whose OTP
  that build resolved against, while the first `erl` on `PATH` is
  whichever installation a shell profile points at.
- `share/codemode-seed` exists only in a release built with the code-mode
  bundle, so a checkout keeps using its own `build/codemode-seed`.

The three ladders, in full, highest rung first:

| what | ladder |
|---|---|
| the sandbox helper | `--helper`, the release tree, `PATH`, `./bin` |
| `gleam` and `erl` | the release tree, `PATH` |
| the build seed | `--codemode-seed`, `<workspace>/build/codemode-seed`, the release tree |

The two flags stay on top: that is how an operator points at a component
they audited or prepared themselves, and a flag naming a missing file
fails saying so rather than falling through to something they did not
choose. The seed ladder puts the *workspace* above the bundle for the
opposite reason — a checkout's seed is regenerated by `make codemode-seed`
against the tree being worked on, and a contributor who changed the
compile service's dependency table must build against their own rather
than against a frozen one `seed.verify` would then reject.

## The client is a separate download

`loom` is not in the `loomd` tarball. It is the native Gleam client over the frozen
gateway protocol, and three things follow from that:

- The two halves belong on different machines as often as not. The
  server runs where the repository and the kernel jail are; the client
  runs where the human is. Bundling one particular client into the
  server artifact contradicts the thin-client design, under which an
  editor plugin and a phone are peers of the terminal.
- Neither half should pay for the other. A headless deploy would carry
  16 MB of terminal UI it can never draw; a laptop attaching to a remote
  server would carry 58 MB of BEAM and toolchain it will never boot.
- Fusing them implies they must match versions. The protocol being
  frozen is exactly the claim that they need not.

The client ships in two shapes, and `make dist` produces both:

- **Self-contained**, `loom-<version>-<platform>.tar.gz`, built by `make
  release-client` with the same relx treatment the server gets: the
  client's BEAM closure with the runtime system copied in, so `loom` runs
  on a machine with no Erlang at all. `make release-client-smoke` proves
  it by booting the launcher with `erl` removed from `PATH`. This is the
  download, and what `make install` installs by default. It is
  per-platform, like the server.
- **Slim**, `loom-slim-<version>-<platform>.tar.gz`, built by `make tui-shipment`:
  the compiled BEAM closure and a thin `bin/loom` launcher over the `erl`
  on `PATH`, needing compatible Erlang/OTP 29 on the host. It carries no
  ERTS; the filename identifies its builder, while it remains portable across
  compatible OTP hosts. This is the shape a package manager that
  provides Erlang as a dependency wants; `INSTALL_CLIENT=slim make
  install` installs it.

`make dist` stages the slim client from the same current shipment that
`release-client` uses for the bundled client. Gleam 1.19's shipment export
clears its production build before compiling, so exporting again would rebuild
the complete TUI dependency closure.

The shipment targets and release scripts use `scripts/shipment.py`. Its private
`build/shipment-cache` verifies source and production dependency contents,
compiler/OTP bytes, environment and output digests before restoring an unchanged
TUI shipment. A changed or removed module takes the official clean export path,
with reuse limited to the exact source contents of the reviewed pure Erlang
dependency versions, including their transitive build inputs. SQLite and
unknown builders always compile afresh and prevent whole-shipment reuse, so the
server retains its native build. Dependency cache misses are published only after
a successful export whose inputs still match. No cache state is shipped.

Use `LOOM_SHIPMENT_CACHE=0 make dist` (or `make tui-shipment`) for a completely
fresh export, or `python3 scripts/shipment.py tui --fresh` for the export alone.
Global rebar configuration and file-valued Erlang/rebar overrides also force
fresh compilation. Reuse is local
to the same checkout and production paths; it does not share BEAM files across
server and TUI roots. The release warning check, probes and smoke tests still run
when an export is reused.

Either way the server tarball is a separate download and remains
self-contained.

On macOS, the bundled releases appear in Activity Monitor as `loom` for the
terminal and `loomd` for the server. The release renames the native emulator
and keeps `beam.smp` as a relative symlink for OTP's launchers. The emulator's
signed contents and startup arguments are unchanged. A slim client uses the
host's emulator and still appears as `beam.smp`; Linux packaging is unchanged.
Short-lived compiler and code-mode processes using the bundled server emulator
also appear as `loomd`, so the name alone does not identify the daemon.

When both downloads are installed on one machine, `loom` can start a local
server as a convenience. It finds a sibling `loomd`, an explicit `--server` or
`LOOM_SERVER`, or `loomd` through an absolute directory on `PATH`, then attaches
over the same loopback websocket an explicit client would use. Relative `PATH`
entries are ignored because they would make the workspace launch authority. It
neither loads a workspace `loom.toml` nor uses the workspace as the server's
working directory, because both surfaces can select host-side processes. A
catalogue the operator names on the command line, `loom --config <loom.toml>`,
is trusted like an explicit server's `--config`. Without that flag, the local
client uses `<state-root>/loom.toml` when present, normally `~/.loom/loom.toml`.
The client resolves that path for automatic daemon startup and each new
session, including creation through an already-running daemon. Explicit relative
paths resolve from the terminal's working directory. If no trusted file exists,
an empty session configuration retains the daemon's session defaults.

Reusing a daemon does not reconfigure its shared maintenance services, and
opening an existing session preserves its recorded configuration reference.
Nothing is linked or bundled together: a remote
client still carries no server runtime, a headless server still carries no
terminal, and `--addr` remains the attachment path between machines.

## Installing from a checkout

`make install` is the one command for the person building from source who
wants to type `loom` in a directory and have a session start there. It
runs the three builds in order — the code-mode seed, the self-contained
server release, the client shipment — and then `scripts/install.sh` lays
them out under `PREFIX`, `~/.local` by default:

| path | what |
|---|---|
| `$PREFIX/lib/loom/server.<suffix>` | a complete server release: helper, compiler, code-mode seed, and bundled ERTS |
| `$PREFIX/lib/loom/server` | a symlink selecting the installed server tree |
| `$PREFIX/lib/loom/client.<suffix>` | the complete client release with ERTS (`INSTALL_CLIENT=bundled`, the default) |
| `$PREFIX/lib/loom/client` | a symlink selecting the bundled client tree |
| `$PREFIX/lib/loom/tui.<suffix>` | the compiled shipment and profiling launcher, without ERTS (`INSTALL_CLIENT=slim`) |
| `$PREFIX/lib/loom/tui` | a symlink selecting the slim client tree |
| `$PREFIX/bin/loom` | the launcher for the selected client shape |
| `$PREFIX/bin/loomd` | the daemon launcher |
| `$PREFIX/bin/loom-profile` | the selected client's profiling census launcher |

Every installation gets fresh physical directories, even for an unchanged
version. Copies finish before their links are published. The launchers resolve
those links to physical paths before executing, so a running process retains
its original modules and bundled tools across later installations. The slim
shipment carries its own build identity and profiling launcher, just as the
bundled release does. The client wrapper preserves its installed location for
sibling daemon discovery.

Links and complete wrapper files are renamed individually; installation is not
a transaction across the whole client/server pair. Existing legacy directories
at `server`, `client`, or `tui` require an offline migration or a fresh prefix.
See [updating](updating.md) for restart, rollback, and cleanup procedures.

After the links are switched, the installer removes superseded trees of the
two stems it just repointed: `server` and the installed client stem (`client`,
or `tui` for a slim install). It keeps the tree every link selects, the tree
each repointed link selected before this installation (one rollback step), and
any tree a live process uses. A tree is in use when a command line from
`ps -axo command` contains its path, or when `lsof` reports an open file or
working directory inside it. If `lsof` is absent only the `ps` check runs. If
`ps` or `lsof` fails, nothing is deleted. Only real directories named exactly
`server.<8 alphanumerics>`, `client.<8 alphanumerics>` or `tui.<8
alphanumerics>` are candidates, so `legacy-backup.*`, `update.lock`, symlinks
and other entries are never touched. The installer prints one line per tree
removed, one per tree kept because it is in use, and a total. Set
`LOOM_KEEP_OLD_TREES=1` to skip pruning. This applies to every prefix and to
`make install-debug`, because they share the installer, and to `loom update`,
which runs the same script.

Pruning assumes no other installation runs on the same prefix at the same
time. `loom update` serializes on `update.lock`; two concurrent `make install`
runs do not, and one could remove the tree the other is still copying.

## Installing for live profiling

`make install-debug` installs the same client and server with BEAM debug
information retained, stripping of bundled ERTS/toolchain binaries disabled,
and OTP's profiling modules included. The Go sandbox helper keeps its normal
stripped build. `PREFIX` and `INSTALL_CLIENT` work as they do for `make install`.
For example, `make install-debug PREFIX="$HOME/.local/loom-debug"` keeps the
normal installation beside a diagnostic installation. Installation does not
stop or replace a running daemon; its next start uses the installed files.

Use `--profile` on either normal launcher to opt into a local BEAM distribution
node. The launcher creates a fresh random node name and cookie, binds it to
loopback, and stores the 0600 cookie in a private directory below the selected
state root's `tokens` directory. That directory is masked from session tools and the
code-mode build plane. `--state-dir` selects that root for both `loom` and
`loomd`; otherwise it is `~/.loom`.

```sh
loomd --profile --state-dir /private/loom-profile
loom --profile --state-dir /private/loom-profile
```

For a daemon that an operator starts regularly, the same restart-only choice
can live in its existing catalogue file:

```toml
[daemon]
profile = true
```

`loomd` reads that setting from `--config <loom.toml>`, or from
`<state-dir>/loom.toml` when no config path is supplied. It is deliberately a
daemon-only setting: distribution is chosen before the VM starts, so changing
the file affects the next daemon start and cannot expose an already-running
node. The release first starts a short local parser process using its bundled
TOML library, then starts the daemon once with the selected mode. This extra
boot preserves the same TOML key semantics the daemon validates rather than
approximating them in shell. `false`, a missing table, and an unprofiled
client launch leave distribution off.

Each launch prints the exact `loom-profile` command for its generated node. Run
that command in another terminal to take an observational memory census. The
helper uses the bundled `mem_report` module and exits after reporting process
heaps, binary memory, ETS, and allocator carriers. It does not force garbage
collection or inspect session payloads.

Open the GUI with either launcher:

```sh
loom observer
loomd observer
loom observer --pid 12345 --state-dir /private/loom-profile
loom observer --erl /opt/homebrew/bin/erl
```

Both commands select the single running profiled daemon under the chosen state
root. `--pid` selects a specific profiled daemon or terminal client. Discovery
matches the live PID, generated node and private cookie directory against its
launch arguments, so it also works with profile nodes started by older releases.
It ignores code-mode satellites and stale credential directories. If more than
one daemon matches, the command requires `--pid`. An unprofiled running process
must be started with profiling enabled before Observer can attach.

The GUI runs in a separate hidden node bound to loopback. The command reads the
existing cookie through Erlang's private HOME and preserves the operator's
application-facing HOME; it never passes the cookie in process arguments. Close
the window to finish. The machine opening the window needs a local Erlang/OTP
installation with `observer` and `wx`; the bundled headless Loom runtime does
not carry the GUI. Use `--erl` to select a compatible GUI-capable installation.

In **Processes**, sort **Memory** to find large heaps, or **Reductions** to find
busy processes, then open a row to inspect its memory, mailbox and links. In
**Load Charts**, compare process, binary and ETS allocation over time. The
**Applications** tab shows application-owned supervision trees; Loom's release
starts its root outside an application callback, so that tab does not show the
complete Loom tree. Follow process links for the live layout. Observer's heap
counters are BEAM allocation, not native RSS or physical footprint.

The launcher consumes `--profile` before it starts Erlang. When that client
finds no local daemon, its one-time local launch carries `--profile` to the new
`loomd`; an already-published daemon is only authenticated and never
reconfigured. The client does not send the flag in a control RPC. It does not
inspect the complete tails of `ext`, `replay`, or `sessions`, stops recognizing
options after `--`, and preserves values such as `--token --profile` as client
arguments. The cookie never enters `ERL_FLAGS`, the application argument vector, OS process
arguments, or a child emulator's environment.

Profiling applies only to an invocation that starts a long-lived node. `--help`,
`-h`, `help`, `loomd access`, `loomd peer`, `loomd ext`, and the client's `ext`,
`replay`, `sessions`, `version`, `claim`, `enroll`, `access`, and `update`
commands run and exit, so they create no credential directory, print no node
name, and ignore `daemon.profile = true`. Their arguments, including a
`--profile`, reach the application unchanged.

The credential directory belongs to the profiled process and is removed when
that process exits. The launcher still `exec`s the emulator, which keeps the
PID that the node name embeds and that `loom observer` matches, so it starts a
small detached watcher first. The watcher polls the launcher's PID every two
seconds and deletes the directory once the PID is gone, including after a
signal or `SIGKILL`. Every profiled launch also sweeps its own state root's
`tokens` directory for leftovers: directories named exactly
`loom-daemon-profile.XXXXXXXX` or `loom-client-profile.XXXXXXXX` that no running
process uses as its HOME and that are more than two minutes old, such as those
left by older releases or by a reboot. Nothing else under `tokens` is touched,
and nothing is removed if the process table cannot be read. Observer discovery
needs a live PID, a matching node name and an existing cookie directory, so it
never selects a directory that has been removed.

An ordinary stripped release includes the census and OTP `runtime_tools`, so it
can report heap and allocator state without debug symbols. `make install-debug`
also retains BEAM debug information and carries OTP's detailed profilers. OTP
29 provides `instrument` and `msacc` in `runtime_tools`; `tprof` comes from
OTP `tools`. Loom has an application named `tools`, so the debug release copies
OTP's modules into a separate diagnostics directory without replacing Loom's
application metadata.

Diagnostic release launchers also retain `LOOM_DEBUG_ARGS_FILE` for an operator
who must attach a prepared OTP argument file. It is consumed before boot and
does not reach code-mode emulators. Use `--profile` for normal profiling
because it creates a unique node and credential without a wrapper script.
`make install` restores the normal stripped artifacts and launcher on disk.

### Inspecting a running daemon with pickglass

[Pickglass](https://github.com/Roasbeef/pickglass) is a separate inspector for
BEAM nodes that attributes memory, reductions and ETS tables to the session
that owns them, which Observer cannot do. It attaches to the node that
`loomd --profile` publishes and needs nothing else from Loom:

```sh
loomd --profile --state-dir /private/loom-profile
pickglass attach --state-dir /private/loom-profile
pickglass open --state-dir /private/loom-profile
```

`attach` prints one census (memory by owner, the largest processes, ETS) and
detaches. `open` serves pages on loopback and prints a one-time URL; Owners,
Processes and Process show heap, mailbox and reductions per owner, and the
Process page lists a process's initial call, registered name, spawner and the
ETS tables it owns. Without `--state-dir` it reads `~/.loom`, and
`--pid` selects one daemon when several are profiled. The path must be spelled
as it was given to `loomd`, because pickglass matches it against the daemon's
launch arguments and does not resolve symbolic links. Pickglass reads the
cookie from the same private directory the launcher created and never takes it
as an argument. `docs/attach.md` in the pickglass repository covers attaching
to a node by name, the security model, and profiling.

A BEAM process cannot be attributed to a session from its pid, so Loom labels
the processes it owns with `proc_lib:set_label/1`, once, from the process
itself ([protocol-change/065](../protocol-change/065-pickglass-owner-label.md)).
An owner is a path and a role. `session:ID (gateway)` is a session's client
gateway; `session:ID/strand:main (strand_driver)` is that strand's driver; a
role with no path, such as `page_sessions`, belongs to the daemon and to no
session. The session roles are `gateway`, `session_host`, `agency`,
`escalation`, `async_runs`, `background_jobs`, `advisor`, `glance`,
`block_summarizer`, `rule_scanner`, `schedule_scanner`, and the per-strand
`strand_driver`, `effect_worker` and `provider_effect_worker`.

`unknown` means a process Loom did not label, and it is expected to be large.
Supervisors that Loom builds with `gleam_otp` start inside the library and
cannot label themselves, and the heap of a session's supervisors is mostly the
child specifications they retain, so a large `unknown` entry led by
hibernating `supervisor` processes is that retention and not a leak. OTP's own
processes (`code_server`, `application_controller`, `logger`) and the ETS
tables they own, together with the `pg` scope and weft's per-scope registry
tables, are also `unknown` by design. The protocol-change lists every role and
what stays unlabelled.

A label exposes session and strand ids to anyone who can attach to the node.
That principal already has full control of it, and the node's owner-only
cookie remains the only gate.

## Joining a distributed deployment

A daemon that has a `[distribution]` table must boot its VM on TLS distribution
before any Gleam code runs, so both launchers add `-proto_dist inet_tls
-ssl_dist_optfile <file>` when `LOOM_DISTRIBUTION_OPTFILE` names an options
file, and add nothing when it is unset. The `bin/loomd` that `make
server-shipment` writes does this through `ERL_FLAGS`; the release launcher
`scripts/release.sh` writes does it with arguments to `erl`, so a path with a
space survives. `loomd distribution options CONFIG OUTPUT` renders the file. The
release itself is unchanged and a deployment needs no second build:
[the distributed setup guide](distributed-setup.md) covers the credentials, the
networking and the container example.

## Cross-compilation: there is none

A release targets one platform, and `make dist` does not produce
universal artifacts. Two things in it are native to the build host:

- **`esqlite3_nif.so`** — 4.3 MB of compiled C, the SQLite backend the
  durability plane runs on.
- **the copied ERTS** — the emulator and its helper binaries, taken from
  the OTP installation that built the release.

`scripts/release.sh` refuses a `GOOS`/`GOARCH` that is not the host
rather than producing a tree whose name lies about what is in it. So a
release process is one runner per supported platform, each building and
smoke-testing its own artifact:

| platform | how it is built | state |
|---|---|---|
| `linux-x86_64` | a Linux x86_64 runner with Gleam, OTP, Go, rebar3 | built and smoke-tested |
| `linux-arm64` | the same on arm64 | never run |
| `macos-arm64` | a macOS runner | not yet published; helper runs under Seatbelt |

The macOS helper uses the system `/usr/bin/sandbox-exec` with a generated
Seatbelt profile. That binary is intentionally not bundled: the absolute
system path is part of the trust boundary. Release smoke and CI run the live
profile rather than accepting profile text as proof of confinement.

The native client shipment is also built on the host. Its BEAM files are
portable across compatible OTP systems, while etui still talks to the host's
terminal and the launcher depends on a host `erl`. The archive keeps the
platform label so release automation can validate one server/client pair per
runner instead of implying an untested universal client artifact.

## Sizes, measured

Stripping the Go helper was free and was taken:

| binary | before | after `-s -w` | |
|---|---|---|---|
| `bin/loom-exec` | 4,878,696 | 3,281,120 | 32.7% off |

The bundled `gleam` was not stripped upstream and everything else in the
release is, so it is stripped on the way in — 29,168,608 to 22,826,152
bytes, 21.7% off, and the stripped binary still builds the seed offline
(the release smoke proves that, not just `--version`).

The copied ERTS is stripped too. Erlang stack traces and crash dumps come from
the BEAM's own tables rather than ELF debug sections, so the tradeoff is native
debugging detail, not Erlang crash diagnostics. `DIST_STRIP_ERTS=0` turns off
both strips. The table records only the shipped, stripped ERTS: the size of the
unstripped input depends on how that particular OTP package was built, and the
old 53 MB observation was not an OTP 29 measurement.

Every figure below is `du -sh` on the built tree, and both columns were built
and smoke-tested by that CI runner.

| | with code mode | `DIST_CODEMODE=0` |
|---|---|---|
| ERTS stripped | 11 MB | 11 MB |
| `lib/` (208 app beams with `Dbgi` stripped, plus the OTP applications, plus `esqlite3_nif.so` at 4.3 MB) | 17 MB | 16 MB |
| — of which the `compiler` application | 764 KB | — |
| `bin/loom-exec` | 3.2 MB | 3.2 MB |
| `bin/gleam`, stripped | 22 MB | — |
| `share/codemode-seed` | 5.9 MB | — |
| **the release tree** | **59 MB** | **30 MB** |
| **`dist/loomd-0.1.0-linux-x86_64.tar.gz`** | **22 MB** | **11 MB** |
| `dist/loom-0.1.0-linux-x86_64.tar.gz` | native BEAM shipment; measured by the current build | same archive |

So code mode costs **+29 MB unpacked and +11 MB compressed**, a little
over a doubling either way. That is close to the estimate #102 worked
from (≈64 MB unpacked) and lands lower, because stripping `gleam` was
worth 6 MB and the issue's 5.8 MB seed figure is block-allocated —
`du --apparent-size` puts it at 4.0 MB.

**Where the seed's bulk is, and what it buys.** 5.4 MB of the seed's
5.8 MB is `build/`, split 4.3 MB of compiled dependency `.beam` under
`build/dev/erlang` and 1.2 MB of dependency *source* under
`build/packages`. Only the second is load-bearing: Gleam ships
pre-generated `.erl` inside its Hex packages, so `build/packages` is what
makes a clone build with the network off at all, and a seed without it
reaches for Hex and fails. `build/dev` is purely a cache of `erlc` output.
Dropping it takes the seed to 1.1 MB and takes a hermetic build from
**0.45 s to 1.44 s** — measured, three times each, on a clone of the
shipped seed with nothing but the release's own `bin` on `PATH`. Every
code-mode execution pays that, on top of a jail spin-up, so the 4.3 MB
stays; but the reason is a second of `erlc` per call, not "a fresh
compile of the world", and it is worth stating the real number.

For comparison, the retired client was a 16 MB stripped Go binary. The slim
client uses the host's OTP installation; the self-contained client carries its
own runtime. Their sizes must be measured separately.

## Code mode ships in the release, and doubling the artifact is the cost

The server registers the `code_mode` tool only on a host that has a Gleam
compiler, an emulator, *and* a build seed whose dependency table is
byte-identical to the one the compile service generates. A release already
contained `erts-<vsn>/bin/erl`; as measured above, the OTP start script also
prepended that directory to the running VM's `PATH`. The installation anchor
therefore does not rescue a missing emulator. It makes the dependency explicit
and independent of a shell-script side effect. Code mode was absent because
the compiler and matching build seed were genuinely missing.

Those real files now ship:

| prerequisite | where it comes from |
|---|---|
| `erl` | `erts-<vsn>/bin/erl`, already in the tarball; found through `code:root_dir()` |
| `gleam` | `bin/gleam`, copied from the build host and stripped — 22 MB |
| the build seed | `share/codemode-seed`, copied from `make codemode-seed` — 5.8 MB |
| the `compiler` OTP application | listed in the release for a code-mode build only — 617 KB |

That last row is not obvious and was found by running the thing rather
than by reading it. `gleam build` compiles Erlang through an `escript`,
an escript is compiled at load time by `compile:forms/1`, and
`compile:forms/1` lives in the `compiler` application — which nothing in
the server's own closure pulls in. Without it the bundled toolchain boots
and fails `undef` on its first module. None of it is reachable from the
harness VM: it is loaded by the emulator the *build jail* runs.

Finding that also uncovered a plain bug in the release. The script
deleted `bin/*` to be rid of relx's daemon-supervisor launcher, and
`no_dot_erlang.boot` was in there — `$ROOTDIR/bin/*.boot` is where
`escript` looks for its own boot file, so every release built so far had
an ERTS whose `escript` and `erlc` could not start. Nothing noticed,
because the launcher names its boot file absolutely and the launcher was
the only thing that had ever booted that ERTS. The deletion now spares
`*.boot` and the build fails loudly if relx stops writing it.

### Why the main artifact, rather than a second archive

Three options were on the table (#102): ship both in the main artifact,
ship a `loom-codemode-<version>-<platform>.tar.gz` that unpacks beside
the release, or keep the status quo and document it honestly.

**The main artifact, with `DIST_CODEMODE=0` as the opt-out**, on the
project's own priority order — security and isolation, correctness,
robustness, performance, capability.

The decisive argument is *correctness*, and it is the second-archive
option's own weakness. The TUI splits off because the gateway protocol is
frozen; "the protocol being frozen is exactly the claim that they need
not match versions" is the sentence three sections up, and it does not
transfer. There is no frozen interface between the harness and the seed —
there is `seed.verify`, which demands the seed's `gleam.toml` be *byte
identical* to what `compile.default_dependencies()` renders. Two
separately downloaded archives that must agree byte-for-byte on an
internal, unfrozen table is the arrangement most likely to leave someone
with a release that boots, says "the seed was prepared from a different
dependency table", and drops the tool again — which is #102 with an extra
download in front of it. Robustness points the same way: one artifact,
one `SHA256SUMS` covering every executable in it, one thing to verify.

What the second archive buys is a 10 MB download for a deploy that will
never write a program, and that is a real cost paid by real deployments —
so the opt-out exists and is one environment variable. What it does not
get to be is the default, because the default should deliver the thing
the project is about. `DIST_CODEMODE=0` also keeps `make release` free of
`make codemode-seed`, which is the one step in this tree allowed the
network.

Against the status quo there is little to say beyond #102's own sentence:
a release that omits code mode delivers a harness whose flagship
capability works only for people who could already build from source. The
argument for keeping it was that "a machine running a release has none of
those", and a third of that was false.

### The absence mechanism is unchanged; the message is not

A host that fails any of the three still registers **no `code_mode`
definition at all**, and that stays. A tool definition renders ahead of
the system prompt and is therefore a byte prefix of the provider's cached
region, paid on every request of every strand for the life of the
session; advertising a tool that can only refuse is worse than omitting
it.

What changed is that the reason is no longer terminal. It names what is
missing, where it was looked for, and how to supply it — the standard
`8d09689` set when a stale helper started naming `make binaries`. A
`DIST_CODEMODE=0` release says, verbatim:

```
gleam is not beside this server at /opt/loom/bin/gleam and not on PATH;
code mode compiles the model's program with it, so put `gleam` (>= 1.18)
on PATH, or run the `bin/loomd` of a release built with the code-mode
bundle, which ships one. No code_mode tool is registered.
```

and the symmetric `codemode.ready` line names the `gleam`, the `erl` and
the seed a working host settled on, because with four rungs across three
ladders "code mode is on" is much less useful than which toolchain it
will build with.

`make release-smoke` checks all of this on the built artifact rather than
asserting it. Booted with `env -i PATH=/usr/bin:/bin`, the release must
resolve the helper beside itself when a session is admitted, must list
`code_mode` in that session's `server.tools` line, and must refuse
`--helper /nonexistent/loom-exec` through the same managed resolver. Helper
resolution is lazy: the daemon does not validate session defaults merely by
opening its catalogue. The smoke also attempts to compile a clone
of the bundled seed in a network namespace with nothing but its own `bin`
on `PATH`; a host that refuses that namespace reports this build check as
unverified, not passed. A `DIST_CODEMODE=0` release is held to the mirror image: no
`code_mode`, and a stated reason.

## Memory distils on the release's own lifecycle

A release ships both the memory consumer and producer. One daemon can serve
many sessions, but memory maintenance belongs to their persisted domain, not
to each session or to daemon startup. Catalogue restoration opens neither
conversations nor domain resources. See [sessions](architecture/sessions.md)
and [multiplayer](architecture/multiplayer.md) for domain ownership and access.

**The cadence follows domain admission and confirmed session closure.** The
first explicitly opened session starts the shared domain owner and its initial
pass. A successfully closed session requests another pass. At most one pass
runs at a time, with at most one coalesced follow-up; there is no periodic
timer. Before retiring the last domain owner, shutdown waits for its current
and already coalesced work. Source identities and paths come from current
catalogue mappings, never a directory scan. Maintenance skips a source with a
live writer lease; shared read-only history search has a separate contract.

**Maintenance uses the domain's captured owner configuration:**

```toml
[memory]
distill = "on-boot"      # domain admission and closure cadence; or "off"
distill_wall_ms = 600000 # how long one whole pass may take; also the ceiling
```

`distill_wall_ms` cannot be raised above its default, because that is
how long the memory session's writer lease lasts and nothing renews a
lease but a commit — a pass that outlived it would fail at its next
commit instead of being cut cleanly, so a larger value is refused at
domain admission with an error. `distill = "off"` starts no maintenance
worker; it does not disable shared history search. Each session retains its
own runtime configuration, even when it shares the domain's memory and index
paths. A malformed maintenance configuration refuses domain admission rather
than silently enabling maintenance.

**The model cost is unchanged by shipping it:** one extraction request
per eligible closed session plus one consolidation request, routed to
the catalogue's `summarize` role when it declares one and to the
resolved main model when it does not. Both turns' usage rows land in the
memory session's own ledger. A pass with nothing new to read dispatches
**no** request at all, which is why a fresh install costs nothing until
there is something to distil.

**Failure does not trigger an automatic retry.** A refused or expired pass
retains any progress already committed and discards its already coalesced
follow-up. A later authorized closure trigger or fresh domain admission can
retry. Lost cleanup proof is different: the original owner remains blocked
and consumes domain capacity. A timeout or closed port is not permission to
open a replacement owner over the same files.

**A new digest becomes visible at the next run start** for sessions sharing
that memory domain, including later runs of the session whose closure
triggered the pass. It is injected as a fenced, attributed user message and never into
the pinned system prompt, so a changed digest costs a rolling tail write
rather than a cache-head rewrite.

**What ran is in the log**, under `memory.distill.started`,
`memory.distill.completed` (with `sources`, `skipped`, `candidates`,
`rows` and whether the digest was written, emptied or unchanged),
`memory.distill.failed` and `memory.distill.expired`.

`make release-smoke` holds the artifact to the first of those: booted
with `env -i PATH=/usr/bin:/bin` in a directory of its own, the release
must first restore metadata without assembling a session. The test probe
explicitly creates two empty sessions, confirms both become resident, and
closes one while the other remains available. A domain pass must complete
with zero candidates and rows before shutdown. Empty transcripts require no
provider request; the test needs no API key and does not claim extraction
quality. SIGTERM must then retire the remaining session and shared domain,
with both `daemon.stopped` and a successful native process exit.

## What is still wanted from the source

Nothing about the helper ladder: #101 is closed above, and the launcher
is three lines shorter for it.

The self-contained client already bundles its own ERTS; only the slim archive
requires a host OTP installation. The remaining single-daemon release gates,
including current platform coverage, are recorded in [next.md](next.md).

## Default development policy and lockdown

New sessions can read host files and use the network. Installed compilers,
SDKs, interpreters, and sibling checkouts therefore work without a list of
language-specific paths. Writes remain confined to the workspace and explicit
writable mounts. The daemon's credentials, session databases, and private
indexes remain masked in either mode.

Tool shells use the daemon's PATH after the bundled compiler and any explicit
`[tools] path` additions. They run non-login Bash with `pipefail`, so host shell
startup files cannot replace that PATH and a successful `tail` cannot hide an
earlier failed command. HOME and TMPDIR point into the workspace's `.codemode`
directory, giving development tools writable caches without host-home writes.
Native search uses PATH but receives no shell credentials and has no network
or write access.

To restrict a daemon's sessions, start it with:

```sh
loomd --read-scope workspace --network off
```

Or persist the policy in the trusted configuration selected by `loom --config`
or `loomd --config`:

```toml
[workspace]
read_scope = "workspace"
# mounts = [{ path = "/absolute/shared/data", access = "ro" }]

[tools]
network = "off"
```

`read_scope = "host"` and `network = "full"` are the defaults. The two settings
are independent. Workspace reads retain the helper's system runtime and the
explicitly admitted code-mode toolchain; other outside paths need `mounts`.
Use `access = "rw"` only for an additional directory that tools must write.
Daemon flags override the corresponding configuration fields, and misspelled
values refuse startup. Settings take effect when a session is opened; they do
not change the policy of an already resident session.

Credential pass-through remains explicit: `[tools] env = ["GH_TOKEN"]` makes
an intended GitHub token available without asking the model to open credential
files. `[tools.set]` can provide other ordinary environment settings. PATH,
HOME, and TMPDIR remain server-owned. Provider credentials are not implicitly
copied into tool environments.


## Reproducible candidates and release manifests

`scripts/release-build.sh` is the clean-source candidate recipe. The initial
hosted workflow, `release-candidate.yml`, accepts a full source commit and an
OCI toolchain image pinned by SHA-256. Two separate Linux x86_64 runners clone
into different host directories; each container builds at `/work/loom` without
a shared build cache. Tool versions alone are insufficient: the manifest also
records the builder identity, executable digests, and complete OTP and Go tree
digests. The image must provide the repository's documented Gleam, OTP, Go,
rebar3, C compiler, Python and release-smoke dependencies.

The recipe retains the warm code-mode seed and its compiler caches.
The maintained [Gleam patch](../scripts/toolchain/gleam/README.md) makes their
serialization and imported type-ID assignment deterministic. CI and both Docker
recipes apply the same patch, and their compiler/compiled-module cache keys
include its digest.
`scripts/codemode-seed-manifest.toml` pins its complete dependency graph; seed
preparation fails if resolution changes that committed lock. Those
caches contain source paths and timestamps, so the fixed prefix and normalized
source times are part of the build inputs. It does not claim that arbitrary
checkout paths yield identical releases, or that a supplied toolchain image was
itself reproducibly bootstrapped.

`scripts/dist.sh` emits the three native artifacts, `manifest-<platform>.json`
and `SHA256SUMS`. The manifest binds their exact sizes, roots and SHA-256 values
to the full source commit. Its default tag is `commit-<full-sha>`;
`LOOM_RELEASE_TAG` supplies a version tag. Canonical ustar and gzip metadata
remove directory iteration order, host ownership and packaging-time differences.
The command refuses an uncommitted source tree. Plain development packaging
records an unrecorded builder; it is not an independently reproduced candidate.

Compare complete outputs from independent builders with:

```sh
python3 scripts/release-compare.py first/dist second/dist > reproduction.json
```

The comparison refuses missing artifacts and manifest/hash mismatches. A
successful result covers the supplied platform's complete files, including the
server, bundled client and slim shipment. Each other supported platform needs
its own comparison. The slim launcher determines the execution platform at runtime, so copying it
to a different compatible OTP host does not select the original builder's
server artifacts. The standalone candidate workflow covers Linux x86_64. The tag workflow below
adds native macOS arm64 builders; Linux arm64 has no hosted release lane.
No workflow signs an artifact. To build the
committed toolchain image and compare two candidates before merging, dispatch
`CI` on the source branch with `build-release-image=true`. Its image job
publishes only the toolchain to GHCR; candidate jobs pull the resulting immutable
registry digest on separate runners. `release-builder` accepts an existing
pinned image instead. The candidate workflow is also directly dispatchable
once it is on the default branch.

Signing remains an operator action after successful independent comparison. A
detached armored OpenPGP signature is named `manifest-<platform>.json.asc` and
covers the exact manifest bytes. Publish it beside the manifest and its three
archives when signing is enabled. Distribute verification keys and fingerprints
through a separately authenticated channel. The updater requires an explicit
local keyring to verify a present signature; no production keys are currently
embedded. See [updating](updating.md) and
[ADR-012](adr/012-release-manifests-and-updates.md) for verification and rotation.

`make check-release-update` runs canonical-archive tests and private native HTTPS,
installation and signature fixtures. It is also part of the full `make check`
gate. These fixtures establish updater behavior; complete artifact equality is a
separate release-build result and must not be inferred from their success.


## Tagging and uploading a release

Update [the release notes](release-notes.md), then commit the intended version in both `packages/client/gleam.toml` and
`packages/tui/gleam.toml`, then run from a clean checkout. The existing `v0.2.0` tag must not be reused;
the example assumes the package versions have been committed as `0.2.1`:

```sh
make release-tag TAG=v0.2.1                         # Preview only.
make release-tag TAG=v0.2.1 RELEASE_ARGS=--push     # Create and push the tag.
```

The script releases the current checkout's **HEAD**. It checks the two package
versions, refuses existing tags, fetches the remote main tip and requires HEAD
to contain it. It creates an annotated tag and atomically pushes HEAD to main
and the tag to the same remote. Branch protections still apply; normally merge
and verify the release commit first, then run this command at that commit.
Use `python3 scripts/release-tag.py v0.2.1 --remote origin --push` to choose a
remote explicitly. It accepts `-alpha.N`, `-beta.N` and `-rc.N` versions when
both package versions contain the same suffix. Python 3.11 or newer is required.

A rejected atomic push changes neither remote ref. The local annotated tag
remains for inspection; inspect the remote and resolve the rejection before
retrying the printed push command. Never move a release tag that reached the
remote. The script does not install anything or restart a daemon.

A `v*` tag starts `.github/workflows/release.yml`:

1. Resolve the tag to a full commit and check its package versions.
2. Build Linux x86_64 twice on separate runners using the pinned GHCR toolchain
   image and the existing candidate workflow.
3. Build macOS arm64 twice on native `macos-15` runners, with pinned language
   toolchains and the fixed `/Users/Shared/loom-release` source directory.
4. Require complete byte equality for each platform, including the manifests
   and toolchain inventory, and bind every manifest to the tag and commit.
5. Upload the six archives, two manifests, aggregate `SHA256SUMS` and comparison
   record to a **draft** GitHub release. Release candidates are also marked as
   prereleases. Only this final job receives repository write permission.

Each build runs the server and bundled-client release smoke checks. Regular CI
and required signoff remain separate gates to check before publishing the draft.
The macOS runner image is recorded, but its label is not immutable like the
Linux image digest; equality is checked for each run, never assumed. The new
macOS release lane still needs its first successful hosted comparison. A
mismatch stops the workflow and leaves the candidate artifacts available for
inspection. Do not publish a platform based on local unit tests alone.

After merging the workflow, a failed run can be dispatched again with its
existing tag. The upload step refuses an existing release rather than replacing
its assets. If GitHub creation or upload was interrupted, inspect the draft and
its assets before deciding how to recover. After review, publish the draft in
GitHub; only then will normal updater release discovery see it. Authentication
for private GHCR pulls is confined to the Linux runner, outside the build
container. Bump the workflow's Linux image digest when its committed toolchain
recipe changes, and keep the macOS version inputs aligned with regular CI.

## Opt-in profiling at launch

`[daemon] profile = true` in the selected `loom.toml` enables local profiling
for both long-lived daemon and terminal-client launches. The client reads
`--config`, otherwise `<state-dir>/loom.toml`, otherwise `~/.loom/loom.toml`,
using the same TOML parser as the daemon. The client reads only the typed
profiling setting; the daemon still owns validation of its whole catalogue.
`--profile` also enables it explicitly, including when the setting is false.
Help, version and other exit-only subcommands create no profiling node.

The setting adds a loopback Erlang node and allocator tagging; sampling and
call tracing still require an attached profiler. The reader boots a short-lived
VM when the config may name the setting, so configured launches pay its startup
cost. A file that cannot name the key avoids that VM. Profiling cookies remain
owner-only below the state root and are removed after exit. A holder of the
cookie has full access to the profiled VM, so distribution stays on loopback.
