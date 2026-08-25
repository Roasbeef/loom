# M4 adversarial review — compile service, satellite host, orchestrator

Scope: `packages/codemode/src/codemode/compile.gleam`,
`satellite.gleam`, `codemode.gleam`, and their tests/support, read against
`docs/architecture/code-mode.md` (whole) and `effects.md` (the broker, the one
door, pooled budget), with the broker public API (`broker/broker.gleam`,
`framing.gleam`, `token.gleam`, `policy.gleam`) taken as the trusted floor.
Reviewer stance: hostile. The running satellite is assumed already-escaped
(WP-J's own premise: a hand-written malicious `.beam` loaded past vetting); any
way the host, the compile service, or the orchestrator fails to hold its stated
guarantee is a finding.

Every claim was traced through the source. No source was modified. Where a
guarantee depends on a party this package only *injects* (the Go launcher, the
network-off `Builder`, the real kernel jail), I say so and push it to the
e2e-deferral list rather than assert it proven.

## Bottom line

**No token-check bypass, no pooled-budget amplification, no frame-decode crash,
and no module-name / self-naming escape was found.** Those four are solid and
are itemized under "Attacks that correctly fail".

What I did find: **two MED defense-in-depth / pinning gaps in the compile
service** (transitive prelude deps are *not* excluded from the build; no
lockfile and a wide stdlib range, so "at no other version" is not realized),
**one MED cleanup-completeness gap in the host** (a launch/deadline race leaks
the launched node, and there is no death-safety net equivalent to the broker's
fd-3 janitor), **one MED claim/coverage gap** (the cap-channel token does not
defend against the very adversary the tabletop credits it with, and the
tabletop tests a path that adversary would never take), and four LOW items.
None is a *direct* capability escape from a correctly-vetted program; the two
compile gaps and the token-claim gap all weaken the "two independent structural
defenses" narrative rather than break a single-layer control.

---

## Findings

### F1 — MED (hermeticity / defense-in-depth): the prelude's transitive dependencies enter the program build; compile "defense 2" is not independent of vetting

`compile.gleam` writes a `gleam.toml` pinning exactly `gleam_stdlib` and the
`cap` path dependency (`default_dependencies`, compile.gleam:136-141), and its
module doc claims this means *"no other package at any version can enter the
build even if the source named one"* (compile.gleam:26-30, defense 2).

That claim is false. `cap`'s own manifest (`packages/cap/gleam.toml`) declares:

```
gleam_erlang = ">= 1.0.0 and < 2.0.0"
gleam_otp    = ">= 1.0.0 and < 2.0.0"
core         = { path = "../core" }
```

`gleam build` resolves the program's dependencies transitively, so
`gleam_erlang`, `gleam_otp`, and `core` land in the program build graph (they
are present as compiled packages under `packages/codemode/build/packages/`).
Their **public** modules are therefore resolvable by name from
`loom_program.gleam`: `gleam/erlang/process` (raw spawn/send), `gleam/erlang/port`
(OS ports — subprocess and file handles), `gleam/erlang/node`, `gleam/otp/*`
(supervision), and every `core/*` module. A program that wrote
`import gleam/erlang/port` and opened a port would **compile**.

The only thing that stops it is **vetting rule 2** (the import allowlist in
`vet/policy.gleam`, which lists neither `gleam/erlang/*`, `gleam/otp/*`, nor
`core/*`). So for this whole class of modules the compile stage is *not* a
second, independent net — it delegates entirely to layer one. The design's
two-layer story ("escape requires both a vetting bypass and a kernel escape",
code-mode.md:88-90) survives only because the kernel jail (layer two) would
still confine a port opened inside the satellite; but the compile service's
stated role — shutting the nested-dependency path structurally — is not what
the generated build actually does.

What *is* correctly closed: `cap/internal/*` (which hold the real effectful FFI
— `ffi_transport.connect_unix`, `read_file`, `socket_send`, `getenv`, all
`@external`) cannot be imported by `loom_program` because Gleam makes
`internal/` modules package-private, and `cap/runtime`'s own doc leans on
exactly this (runtime.gleam:9-12). That is a genuine second layer; the
transitive *public* modules of `cap`'s dependencies are the hole.

- Why it breaks a claim: contradicts compile.gleam:26-30 defense 2 and the
  "second independent structural defense" framing in code-mode.md.
- Severity MED: exploiting it still requires a vetting miss (rule 2) *and*
  relies on the kernel jail to contain the resulting raw-BEAM primitives, so it
  is a defense-in-depth regression, not a standalone escape.
- Fix: make the build's package path contain *only* stdlib + `cap` + `cap`'s
  genuinely-required runtime, or post-resolution verify the manifest's package
  set against an allowlist and fail the build on any extra package, or vendor a
  `cap` whose runtime deps are themselves `internal`. At minimum, correct the
  defense-2 wording to state that transitive-dep public modules are gated by
  vetting, not by the manifest.

### F2 — MED (dependency pinning): no lockfile is generated and stdlib is a wide range, so "at no other version" is not realized, and the offline build cannot resolve stdlib at all without an unspecified cache

`gleam_toml` (compile.gleam:209-225) emits a `[dependencies]` table only. No
`manifest.toml` is written, and `gleam_stdlib` is pinned as
`">= 0.34.0 and < 2.0.0"` (compile.gleam:139). Design rule 3 is stated as
"exactly the vendored standard library … no other package, **at no other
version**" (code-mode.md:110-111) and compile.gleam:167 comments "the manifest
pins exactly the prelude and stdlib."

Two problems trace from this:

1. **Version is not pinned.** A `>= … and < 2.0.0` requirement with no
   `manifest.toml` lock admits any stdlib in a very wide range. Whatever the
   build's package cache happens to hold in that range is what gets compiled.
   "At no other version" is not achieved by the generated inputs.
2. **Offline resolvability is unproven and unprovided.** A hermetic,
   network-off `gleam build` (code-mode.md:203-206, effects.md network-off
   jail) cannot fetch `gleam_stdlib` from Hex. It must come from a pre-seeded
   local cache mounted into the jail. The compile service neither creates,
   vendors, nor verifies such a cache — it emits a Hex requirement and calls
   `config.build(root)`. So a genuinely offline build of the generated inputs
   fails unless the surrounding wiring silently supplies a cache the service
   knows nothing about.

- Why it breaks a claim: directly contradicts design rule 3's "at no other
  version" and the module comment's "pins exactly."
- Severity MED: a mis-pinned or cache-supplied stdlib is a supply-chain surface
  for model-run code; but it requires control of the build cache, which under
  the threat model is harness-owned.
- Fix: generate a `manifest.toml` locking exact versions+hashes (or make stdlib
  a vendored `path` dependency at an exact version), and have the compile
  service assert the resolved package set/versions before trusting the
  `BuildProducts`. Document the cache mount as part of the `Builder` contract.

### F3 — MED (resource cleanup): the launched node/socket leaks on a deadline-during-launch race, and there is no death-safety net for the token file / node

The host's teardown (`cleanup`, satellite.gleam:789-796 — `broker.abort` +
`destroy()` + `unlink_token_file`) runs **only from inside the host actor**
(`terminate` and the `Stop` handler). There is no monitor-based janitor, in
deliberate contrast to the broker, whose `CLAUDE.md` documents a janitor process
that monitors the helper actor precisely so an fd-3 file is unlinked "on every
reachable path." Two consequences:

**(a) Concrete, reachable leak — deadline preempts `Connected`.** The wall
deadline timer is armed in the initialiser, *before* the launcher is called:
`process.send_after(commands, delay, Deadline)` (satellite.gleam:466-467), and
`start_host` returns before `run_launched` calls `launch(spec)`
(satellite.gleam:341-370). If `launch` takes longer than `delay` (a slow or
resource-starved jail spawn, or simply a very short deadline), the sequence is:

1. `Deadline` fires → `terminate(state, Error(DeadlineExceeded))` → `cleanup`
   runs with `state.destroy == None` (never connected, so nothing to destroy) →
   `actor.stop()`.
2. `launch` finally returns `Ok(connection)`; `run_launched` does
   `process.send(host.commands, Connected(...))` (satellite.gleam:376-379) to
   the **now-stopped** actor — dropped.
3. `run` receives the already-sent `DeadlineExceeded` and returns.

The freshly-launched node and its socket (`connection.destroy`) are **never
reaped by the host**. Because `cleanup` did call `broker.abort(op_id)`, any
executor the node had spawned under `op_id` dies, and *if* the launcher
dispatched the `erl` node itself under the same `op_id` (J3c launch contract,
injected — not verified here) the abort would reap it; but nothing in this
package guarantees that, and the `CapConnection.destroy` that this module owns
as the reap path is skipped.

**(b) No safety net if the host actor dies.** The `run_launched` timeout branch
(satellite.gleam:382-388) only `process.send(host.commands, Stop)`. If the host
actor is already dead, `Stop` is a no-op and nothing unlinks the token file or
destroys the node. Unlike the broker, there is no monitor that runs cleanup on
host death; cleanup is entirely contingent on the host actor executing
`cleanup()` itself.

- Why it breaks a claim: `run`'s doc promises it "destroys the node and unlinks
  the token file on every exit path" (satellite.gleam:291-293); path (a) is an
  exit path that does neither for the node/socket.
- Severity MED: leaked jailed node consumes resources past its deadline; the
  token file is mode-0600-in-0700 so its leak is disk, not disclosure.
- Fix: do not arm the deadline until `Connected` is processed (or arm it in the
  `Connected` handler); and have `run_launched` `monitor` the host and, on any
  non-`Ok` outcome, call `connection.destroy()` / `unlink_token_file` itself as
  a backstop — mirroring the broker's janitor.

### F4 — MED (overstated guarantee + tabletop strawman): the cap-channel token does not deny the WP-J adversary, and the "denied" test exercises a path that adversary never takes

`satellite.gleam:62-66` calls the cap token "the defence that denies a hostile
`.beam` which slipped vetting: even inside the jail it reaches only this one
token-checked door." Trace the token's actual reachability:

- The host writes the 32-byte token to `LOOM_CAP_TOKEN_FILE`, a mode-0600 file
  bind-mounted **read-only into the jail** so `cap/runtime` can read it
  (satellite.gleam:41-46; runtime.gleam env-var contract). The path is in
  `LOOM_CAP_TOKEN_FILE`, an ordinary env var visible to everything in the node.
- The WP-J tabletop adversary is *a hand-written malicious `.beam` loaded
  directly to bypass vetting* (code-mode.md:198-200). Such a `.beam` has its own
  `@external` (that is what "bypass vetting" means), so it can call
  `os:getenv/1` and `file:read_file/1` and simply **read the token file and
  present the genuine token**. `token.check_for` then returns `Ok` — the check
  passes.

So the token does *not* stop that adversary. What actually confines it is the
**kernel jail** (only the cap socket is reachable) plus the **broker's per-call
policy** (`clear_call` composes and checks policy on every `cap_call`
regardless of token). The token's real value is narrower and worth stating
honestly: it rejects socket peers that never read the file, and it *binds* the
channel to one `{op_id, step_id, deadline}` so a captured token cannot be
replayed into another execution or after the deadline (`check_for` →
`WrongBinding`/`Expired`, token.gleam:170-190).

The tabletop test inherits the confusion.
`cap_calls_without_the_token_are_all_denied_test` (satellite_test.gleam:134-150)
sends `0xAA`-filled bogus tokens and asserts three `unauthorized` refusals. That
proves the *mechanism* (a non-matching 32 bytes is refused) but exercises a path
the real adversary would never use — it would read the real token first. The
test that would actually pin the guarantee is missing: present the **real**
token and assert that a policy-forbidden `cap_call` is still refused *by policy*,
i.e. that the token is not a bearer capability that widens what the channel may
do.

- Why it breaks a claim: the inline comment and the "un-tokened denied" tabletop
  case together imply the token is the defense against the escaped `.beam`; it
  is not.
- Severity MED: no code defect, but a security *claim* the review is charged to
  falsify, and a test that gives false assurance about the WP-J exit criterion.
- Fix: reword satellite.gleam:62-66 to credit the jail + per-call policy and
  scope the token to authentication + execution-binding/anti-replay; add a
  tabletop case presenting the real token and asserting policy is the limiter.

### F5 — LOW (decoder totality): the host's own outcome-frame decoder skips the protocol-version and id checks

`decode_envelope` (satellite.gleam:883-894) extracts only `kind` and `body`; for
`kind == "outcome"` it hands `body` straight to `decode_outcome`
(satellite.gleam:660-665) and **never checks `v == protocol_version` or that
`id` is a valid u64**. Every non-outcome kind is routed through
`framing.decode_payload`, which *does* enforce the version (framing.gleam:361-364),
so the terminal frame is the one place the strict-decoder doctrine
(effects.md:139-140) is not applied. Impact is low — the satellite authors its
own terminal frame — but it is an inconsistency: a satellite speaking `v:2`
outcome frames is silently accepted.

- Fix: validate `v` (and reject a negative/absent `id`) in `decode_envelope`.

### F6 — LOW (resource): every inbound `cap_call` spawns an unlinked collector *before* any budget or outstanding-count gate

`route_cap_call` (satellite.gleam:669-711) unconditionally
`spawn_collector(...)` for each admitted-by-router `cap_call`; the pooled-budget
check lives *inside* the spawned process's `broker.clear_call`
(satellite.gleam:716-752). Pooled budget therefore bounds outstanding
*effects*, not inbound *cap_call processing*: a satellite can emit `cap_call`
frames up to the wall deadline, each spawning a short-lived harness-VM process
that immediately gets `BudgetRefused` and answers. The processes are cheap and
the deadline bounds the window, but the count is unbounded within it and runs in
the trusted VM.

- Fix: gate on an in-actor outstanding-count (or a distinct inbound-rate cap)
  before spawning, so a refused `cap_call` costs no process.

### F7 — LOW (robustness): a second length-prefix splitter duplicates `framing.push`, and non-outcome payloads are msgpack-decoded twice

`deframe_loop` (satellite.gleam:836-860) reimplements the u32 length read and the
`max_frame_bytes` guard that `framing.push` already owns, purely so the host can
peek `kind` and intercept the `outcome` frame. The two splitters can drift
(e.g. if `max_frame_bytes` handling changes on one side only). Separately, a
non-outcome payload is decoded once by `decode_envelope` (to read `kind`) and
again by `framing.decode_payload` (satellite.gleam:606) — wasted work and a
possible divergence if the two disagree on what is a well-formed map.

- Fix: expose a `kind`-peek (or an `Inbound` variant carrying the raw body) on
  `broker/framing` and let the host reuse the single `Deframer`.

### F8 — LOW (doc graph): `packages/codemode` has source but no `CLAUDE.md`/`AGENTS.md`

Root `CLAUDE.md` requires every package with source to carry a per-package
`CLAUDE.md` (and byte-identical `AGENTS.md`); `make doc-check` enforces it.
`packages/codemode/` has neither. Not a security issue, but the package's
invariants (pinned module name, host cleanup contract, pooled `{op_id,
step_id}`) are exactly the kind of thing that doc is supposed to pin.

### Minor notes (no severity)

- `private_token_writer`'s failure branch (satellite.gleam:1003-1019): if
  `set_permissions_octal` fails *after* `write_bits`, the token file is left on
  disk and `run` returns `TokenFileFailed` without unlinking. Disk leak only —
  the enclosing directory is already 0700, so no disclosure.
- `cleanup` unlinks the token file but not the AF_UNIX socket path or the
  private directory; both persist on disk after teardown (launcher's `destroy`
  closes the socket fd, not necessarily its filesystem node).
- Duplicate `cap_call` `id`s (satellite.gleam:695-708) overwrite the `inflight`
  entry and spawn a second collector; the second settlement is dropped. Wastes
  the satellite's own pooled budget; not a cross-tenant issue.

---

## Attacks that correctly fail (traced)

- **Module-name pinning / self-naming / prelude-shadowing.** The submitted
  source is written to `src/<program_module>.gleam` = `src/loom_program.gleam`
  (compile.gleam:159-162); a Gleam module's name is its file path, and the
  source content — comment, string, or any attribute — cannot change the
  filename. Only two files are ever written (`loom_program.gleam`,
  `loom_satellite.gleam`), and one string cannot become two modules (Gleam has
  no macros/codegen), so a program cannot spawn a second module, name itself
  `loom_satellite`, or place a `cap/fs.gleam` to shadow the prelude. Importing
  `loom_program`/`loom_satellite`/`cap/internal/*` is separately rejected by
  vetting (not on the allowlist) and, for `cap/internal/*`, by Gleam's
  package-private `internal/` rule.
- **Pooled-budget amplification (the exact hole pooling closes).** Every
  `cap_call` is routed with `op_id`/`step_id`/`budget` taken from host state
  (`route_cap_call`, satellite.gleam:675-686; `proc_plan`,
  satellite.gleam:938-953), never from the frame — the `CapCall` body carries no
  `op_id`/`step_id`, and its `deadline_ms` is discarded (satellite.gleam:620).
  The broker keys one `budget.Ledger` per `{op_id, step_id}` and ignores a
  later clearance's budget field (broker `CLAUDE.md` "Budget is pooled per
  execution"). N distinct ledgers is therefore unconstructible from the
  satellite. Verified live by `pooled_budget_refuses_fanout_past_the_cap_test`
  (cap 2, four calls, two refused).
- **Constant-time token check, before any effect.** `handle_cap_call`
  (satellite.gleam:635-657) calls `token.check_for` *before* `route_cap_call`;
  no clearance, spawn, or policy compose happens on the un-checked path. The
  check folds over every vault entry via `ffi_crypto.constant_time_equal` with
  no early exit (`scan`, token.gleam:242-250), and the subsequent binding
  comparison is over non-secret `op_id`/`step_id`. `cancel` and `heartbeat` are
  the only un-tokened frames, and neither causes an effect (cancel only reaches
  this execution's own `inflight`; heartbeat only echoes).
- **`cancel(id)` reaches exactly one clearance.** `handle_cancel`
  (satellite.gleam:754-774) → `inflight[id]` → that call's `CallHandle` →
  `broker.cancel` → `CancelCall` → `dict.get(state.active, handle.id)` → that
  helper only (broker.gleam:382-388). `inflight` is per-host, so no sibling
  execution is reachable; the pre-`CapStarted` race is handled by the
  `cancelled` flag (satellite.gleam:520-541). Verified by
  `cancel_kills_the_losers_clearance_only_test` (exit 137 on the cancelled id,
  the other still pending).
- **Token binding / replay.** The token is bound to
  `{op_id, step_id, policy, budget.deadline_ms}` (satellite.gleam:302-308); a
  token from another execution refuses `WrongBinding`, and past the deadline
  refuses `Expired` (token.gleam:151-190). A program cannot extend its own
  deadline via the frame's `deadline_ms` (ignored).
- **Frame-decode totality.** Oversized length → `deframe_loop` fault →
  `ChannelFaulted` close (satellite.gleam:838-847, 573-577); torn frame →
  carried, no crash; zero-length frame → empty payload → msgpack decode error →
  `ChannelFaulted`; malformed cap frame → `ChannelFaulted`
  (satellite.gleam:611-612); unknown well-formed kind → ignored, channel kept
  (satellite.gleam:610); stray *known* kinds that shouldn't flow
  satellite→host (`exec_start`, `cap_result`, `hello`, `error`) → ignored via
  `handle_frame`'s `_` arm (satellite.gleam:631); two `outcome` frames in one
  chunk → the first short-circuits `handle_payloads` (satellite.gleam:581-593),
  the second is never processed.
- **0600-in-0700 creation race.** `private_directory` (satellite.gleam:1021-1028)
  creates and chmods the directory to 0700 *before* the token file is written;
  the brief window in which the file may carry default perms sits inside an
  already-0700 directory, so the token bytes are never reachable by another OS
  user. (Pre-creation of the directory/file by a local attacker is out of scope
  per the effects.md threat model, which excludes a hostile local user.)

---

## What remains for the real-kernel e2e (`make e2e`) — explicit deferrals

The in-process tests use a cooperative fake peer (`support/satellite_peer.gleam`)
and fake helpers (`support/fake_helper.gleam`) over `ChannelTransport`. They
prove the host's *protocol* half only. The following are **not** proven here and
must be the e2e's burden:

1. **Node dies as a unit.** In-process `destroy` is just
   `process.send(inbox, InboundClose)` (satellite_peer.gleam:60-62); nothing
   proves a real jailed `erl` node is reaped when `destroy`/`broker.abort` fire.
2. **A CPU-bound, zero-`cap_call` pure-Gleam program is actually killed at the
   wall deadline.** No cooperative peer can stand in for this — it is exactly the
   case where the host's timer must translate into a real cgroup/wall kill +
   node reap. The deadline test only proves the host *timer* fires and the host
   tears down (satellite_test.gleam:163-177).
3. **The build is genuinely network-off and offline-resolvable against a
   locked, vendored stdlib** (F1/F2). The `Builder` is faked in every codemode
   test (`ok_builder`); no test runs a real hermetic `gleam build`.
4. **Kernel confinement of a hand-written malicious `.beam` to the cap socket
   only** — no filesystem, network, or syscall egress. This is the other, larger
   half of the WP-J tabletop and is entirely unexercised in-process; the fake
   peer only ever speaks the polite protocol (see F4).
5. **The launcher dispatches the `erl` node under the same `op_id`** so that
   `broker.abort(op_id)` in `cleanup` actually reaps the node (J3c launch
   contract). The `Launcher` is injected and faked here.
6. **Socket-close-mid-`cap_call` surfaces to the program as `Unreachable` and
   unblocks it** (J3a EOF semantics). The fake peer just receives `InboundClose`.
7. **The token file is bind-mounted read-only and is not writable by program
   code**, and the socket is the node's only reachable descriptor (two-channel
   doctrine).

The escaped-satellite tabletop, as implemented, proves precisely two host-owned
facts: a `cap_call` bearing 32 non-matching bytes is refused, and a satellite
that never emits an `outcome` is torn down when the host's deadline timer fires.
It does **not** prove the WP-J exit-criterion sentence ("reaches *nothing* but
token-checked RPCs and must die at its deadline") — that sentence is about
kernel confinement and a real node death, both deferred, and its "token-checked"
clause is weaker than it sounds (F4).
