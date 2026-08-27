# Distribution

How Loom is packaged for somebody who wants to *run* it rather than work
on it, what that costs, and why the sandbox helper ships as a file beside
the server rather than inside it.

Everything below was measured on the development container — Linux
x86_64, Gleam 1.18.1, Erlang/OTP 28 (ERTS 16.4.0.5), Go 1.24.7 — by
running the targets it describes.

## The problem

`gleam export erlang-shipment` is Gleam's only packaging verb, and what
it produces is compiled BEAM files: 11 MB and 208 `.beam` for the
`client` package and its dependency closure, with no runtime system in
it. `make server-shipment` writes a `bin/loom-server` shim over that,
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

**To build**: `gleam`, `rebar3`, `erl`, `go`, `strip`. **To run what
comes out**: nothing. `make release-smoke` proves that second claim
rather than asserting it — it boots the built release with
`env -i PATH=/usr/bin:/bin`, so neither `erl` nor `gleam` is reachable,
and requires a `/healthz` 200, a 401 from an unauthenticated websocket
upgrade, a written session file, and the graceful-shutdown log line on
SIGTERM.

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
plane for it to serve anyway. `scripts/release.sh` deletes relx's `bin/`
and the `vm.args` and `sys.config` only that script reads, and writes a
launcher that is the shipment entrypoint's invocation with two changes:
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

- `bin/loom-exec` sits next to `bin/loom` in the unpacked tree, and the
  launcher passes `--helper "$here/loom-exec"` unless the caller already
  passed `--helper`. So the default is the shipped helper and an
  operator who wants a separately packaged or separately audited one
  still wins, which is what that flag already means.
- `SHA256SUMS` in the tree covers every executable file in it, including
  the helper and every NIF. It is checkable with `sha256sum -c` from the
  moment the tarball is unpacked, by anyone, at any later time — which
  is the thing a blob inside a binary is not.
- The helper is byte-identical across `make binaries`, `make sandbox`
  and `make release`, because all three go through `scripts/go-build.sh`
  with the same `-trimpath -ldflags="-s -w"`. That is what makes `make
  selftest`'s ENFORCED/SKIPPED verdict evidence about the *shipped*
  helper rather than about a development build of it.

## The TUI is a separate download

`loom-tui` is not in the server tarball. It is a client over the frozen
gateway protocol, and three things follow from that:

- The two halves belong on different machines as often as not. The
  server runs where the repository and the kernel jail are; the client
  runs where the human is. Bundling one particular client into the
  server artifact contradicts the thin-client design, under which an
  editor plugin and a phone are peers of the terminal.
- Neither half should pay for the other. A headless deploy would carry
  16 MB of terminal UI it can never draw; a laptop attaching to a remote
  server would carry 29 MB of BEAM it will never boot.
- Fusing them implies they must match versions. The protocol being
  frozen is exactly the claim that they need not.

It is also a single static Go binary, so it needs no tree around it and
ships as a bare file rather than a tarball.

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
| `macos-arm64` | a macOS runner | never run, **and the helper has no jail there** |

The macOS row carries a caveat the other two do not. `loom-exec`
compiles for darwin but has no jail: it reports `platform-unsupported`
and refuses to serve without `--allow-unenforced`. A macOS release would
therefore ship a server that cannot run a tool call unless the operator
explicitly opts out of enforcement, which is the correct behaviour and a
poor download. Packaging is not what is missing there.

`loom-tui` is the exception: Go cross-compiles it with `GOOS`/`GOARCH`
alone, so client binaries for every platform can be built anywhere. The
`make dist` target does not do that today — it builds the client for the
host beside the server, because that is what has been run and tested.

## Sizes, measured

Stripping the two Go binaries was free and was taken:

| binary | before | after `-s -w` | |
|---|---|---|---|
| `bin/loom-exec` | 4,878,696 | 3,281,120 | 32.7% off |
| `bin/loom-tui` | 21,700,138 | 15,798,564 | 27.2% off |

The copied ERTS is stripped too, which is the single largest saving in
the artifact: `beam.smp` arrives at 53 MB, of which about 42 MB is a
symbol table and DWARF the emulator never reads. Erlang stack traces and
crash dumps come from the BEAM's own tables, not from ELF, so this costs
a C-level backtrace under `gdb` and nothing else. `DIST_STRIP_ERTS=0`
turns it off.

| | |
|---|---|
| ERTS as copied | 57.3 MB |
| ERTS stripped | 11.3 MB |
| `lib/` (208 app beams with `Dbgi` stripped, plus the OTP applications, plus `esqlite3_nif.so` at 4.3 MB) | 15 MB |
| `bin/loom-exec` | 3.2 MB |
| **the release tree** | **29 MB** |
| `dist/loom-0.1.0-linux-x86_64.tar.gz` | **11 MB** |
| `dist/loom-tui-0.1.0-linux-x86_64` | **16 MB** |

For comparison, what the tree produced before any of this: an 11 MB
shipment plus 26.6 MB of unstripped Go binaries, which needed an OTP
installation on top.

## Code mode is absent from a release, on purpose

The server registers the `code_mode` tool only on a host that has
`gleam` and `erl` on `PATH` *and* a build seed whose dependency table
matches the compile service's. A machine running a release has none of
those unless it also happens to be a development machine, so the server
prints the reason once at boot and ships no `code_mode` definition at
all — which is the existing behaviour and the right one, since a tool
definition is paid for on every request of every strand for the life of
the session. Every other tool works normally. Turning that around would
mean shipping a Gleam compiler and an offline package cache inside the
artifact; nobody has argued for it.

## What is wanted from the source and was not changed here

One change would remove the launcher's `--helper` injection: the
server's helper ladder is `--helper`, then `PATH`, then `./bin`, and an
unpacked release is usually neither, since a person runs
`loom-0.1.0-linux-x86_64/bin/loom` from wherever they happen to be. If
the ladder gained "the directory of the running executable" between the
flag and `PATH`, the helper beside the binary would be found however
Loom is invoked, and the launcher would be three lines shorter. That is
a change in `packages/client`, and it is not made here.
