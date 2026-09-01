# Distribution

How Loom is packaged for somebody who wants to *run* it rather than work
on it, what that costs, and why the sandbox helper ships as a file beside
the server rather than inside it.

Everything below was measured on the Linux x86_64 CI runner with Gleam 1.18.1,
Erlang/OTP 29.0.5 (ERTS 17.0.5), and Go 1.24.7 by running the targets it
describes.

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
reachable, and requires a `/healthz` 200, a 401 from an unauthenticated
websocket upgrade, a written session file, the graceful-shutdown log line
on SIGTERM, and the four code-mode and helper checks the last section
describes.

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
  thoroughness for its own sake: the seed holds `vendor/cap` and
  `vendor/core`, the prelude compiled into every satellite a code-mode
  program runs as, so a tampered seed is arbitrary code inside every
  jailed node. "Executables only" would have left the one part of the
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

`make tui-shipment` exports the client's compiled BEAM closure and writes a
thin `bin/loom` launcher over it. `make dist` packages those together as
`loom-<version>-<platform>.tar.gz`. The archive deliberately carries no
second ERTS: the client host needs compatible Erlang/OTP 29 on `PATH`. This is
not the server's installation contract. The server tarball remains
self-contained and still needs no host Erlang installation.

When both downloads are installed on one machine, `loom` can start a local
server as a convenience. It finds a sibling `loomd`, an explicit `--server` or
`LOOM_SERVER`, or `loomd` through an absolute directory on `PATH`, then attaches
over the same loopback websocket an explicit client would use. Relative `PATH`
entries are ignored because they would make the workspace launch authority. It
neither loads a workspace `loom.toml` nor uses the workspace as the server's
working directory, because both surfaces can select host-side processes.
Nothing is linked or bundled together: a remote
client still carries no server runtime, a headless server still carries no
terminal, and `--addr` remains the attachment path between machines.

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

For comparison, the retired client was a 16 MB stripped Go binary. The native
client trades that self-contained process for a smaller BEAM shipment and an
explicit OTP-on-the-client-host dependency.

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
report the helper it found is the one beside it, must list `code_mode` in
its `server.tools` line, must refuse `--helper /nonexistent/loom-exec`
(so the flag still outranks the shipped helper), and must compile a clone
of the bundled seed in a network namespace with nothing but its own `bin`
on `PATH`. A `DIST_CODEMODE=0` release is held to the mirror image: no
`code_mode`, and a stated reason.

## What is still wanted from the source

Nothing about the helper ladder: #101 is closed above, and the launcher
is three lines shorter for it.

One thing this does not do is bundle a second ERTS for `loom`. The client
archive is a host-built Erlang shipment and requires compatible Erlang/OTP 29
on the machine where the terminal runs. Making that client archive
self-contained would be a separate packaging decision with its own size and
platform matrix.
