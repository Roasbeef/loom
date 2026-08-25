# cap

## Purpose

The capability prelude: the language a code-mode program is written
against, plus the boot runtime that runs it. Every `cap/*` module a
submitted program may import is here, and every one of them is an RPC stub
— a typed local-looking call that marshals its arguments into a `cap_call`
frame, sends it over the one AF_UNIX channel to the satellite host, and
blocks for the `cap_result`. This package runs *inside* the jailed
satellite node, never in the harness VM, and is a separate build target so
it can one day be published on its own. WP-J.

## Key Types

- `cap/report.Outcome` — `Completed(value)` / `Errored(message, details)`.
  A program is a `fn() -> Outcome`; `to_msgpack` is the marshalling the
  boot runtime writes as the terminal frame, so a strand receives a
  structured value and never scrapes stdout.
- `cap/runtime.{Transport, BootError}` — the boot runtime's injected
  transport (`send`, `recv`, `outcome_sink`) and its four setup failures.
  `run(main)` is the production convenience the generated satellite entry
  module calls; `boot` is the testable core beneath it.
- `cap/proc.Command` — opaque, built through `command`/`in_dir`/`with_env`/
  `with_stdin`/`with_timeout`, so a non-empty argv holds by construction.
  `proc.run` is the one capability the harness's `default_router` services
  today.
- `cap/task.Failure(e)` — `Returned(index, error)` / `Crashed(index,
  reason)`. The result type of every combinator, and the reason a killed
  branch is distinguishable from a branch that returned an error.
- `cap/actor.{Address(state, msg), Next(state), Reply(value)}` — the
  unforgeable typed address, the handler's continue/stop verdict, and the
  reply channel for `call`. `Address` carries both type parameters, which
  is what makes `call` and `get` fully typed.
- `cap/internal/channel.{Channel, Handle, CapOutcome, CallError}` — the
  single seam every capability goes through. `Channel` is the one-function
  record stored in the VM-global slot; `Handle` is the boot module's
  private handle on the actor; `CallError` is `Denied` (the broker's
  in-band refusal) or `Unreachable` (transport).

## Relationships

- **Depends on**: `core` (msgpack values and the corruption report),
  `gleam_erlang` (processes, monitors, subjects), `gleam_otp` (the actor
  behind `cap/actor` and the channel), and the standard library. Nothing
  else.
- **Deliberately does not depend on `broker`.** The spec DAG (§0.1) puts
  WP-J at `J → G,I`, which holds for `codemode` but not here: `cap` is the
  untrusted far side of the effect-plane wire, not a peer of the broker, so
  the frozen Part 1.4 envelope it needs is reproduced over `core/msgpack`
  in `cap/internal/wire` (outbound) and `cap/internal/inbound` (the read
  half) rather than borrowed from `broker/framing`. Report the divergence;
  do not close it by adding the edge.
- **Depended on by**: nothing in the harness. `packages/codemode` is its
  counterpart and restates the shared names (`LOOM_CAP_SOCK`,
  `LOOM_CAP_TOKEN_FILE`, the `outcome` frame kind) rather than importing
  them, because linking model-facing code into the harness VM would break
  Rule Zero. A compiled program depends on `cap` by being built against it,
  vendored inside its own build root.
- **FFI**: two modules, and they are the whole of the package's impurity.
  `cap/internal/ffi_registry` binds `persistent_term` — VM-global, readable
  at local-memory speed from every process a program spawns, which no pure
  alternative can do. `cap/internal/ffi_transport` binds `getenv`, a file
  read, and `gen_tcp` over AF_UNIX. Both go through `cap_ffi.erl`.

## Traffic

- **Actor messages** — `cap/internal/channel.Msg` (opaque):
  `Perform(cap, args, deadline_ms, caller, reply)` is the call every public
  `cap/*` function makes; `Deliver(id, outcome)` and `Fail(reason)` are
  casts from the boot runtime's read loop; `CallerDown(down)` is the
  monitor firing when a caller is killed; `Stop` is teardown.
  `cap/actor` and `cap/task` spawn their own processes but exchange no
  package-level protocol.
- **Wire** — one AF_UNIX stream, length-prefixed msgpack, protocol version
  1, 16 MiB cap. Out: `cap_call` (carrying the token, the capability name,
  the marshalled args, and a deadline) and `cancel`. In: `cap_result`,
  which is the only kind the satellite acts on. Out, exactly once per
  execution: the terminal `outcome` frame
  (`{v: 1, id: 0, kind: "outcome", body}`) carrying
  `report.to_msgpack(outcome)`.
- **Commits / registers**: none. This package never touches durable
  storage; it has no way to.

## Invariants

- **A program cannot name the seam.** `cap/internal/*` is an internal
  module, which the Gleam compiler forbids another package from importing,
  and no public cap function takes a channel or a token as an argument.
  Both are held in the channel actor and fetched per call through
  `cap/internal/dispatch`. The program can neither supply, read, nor
  replace them.
- **The token authenticates the channel; it does not confine an escaped
  `.beam`.** The boot runtime must read the token file, so a hand-written
  `.beam` with its own `@external` can read it too and present the genuine
  token. What the token buys is rejection of a peer that never read it and
  binding to one `{op_id, step_id, deadline}` so it cannot be replayed.
  Confinement is the kernel jail plus the broker's per-call policy check.
  Do not write it the other way round.
- **Installing over a live channel is refused.** The channel lives in a
  VM-global slot installed per execution, so a process surviving execution
  *N* would read *N+1*'s channel and act under *N+1*'s token.
  `dispatch.install_exclusive` refuses to overwrite a slot whose channel
  actor is still alive, making the executor's reaping obligation fail
  loudly instead of silently lending authority. `release` is a
  compare-and-clear, so a slow teardown cannot clear a later execution's
  slot.
- **Cancellation is real, not advisory.** The channel monitors the caller
  of every in-flight call. Killing a `race` loser therefore produces a
  `DOWN`, which emits a `cancel` frame for that call id, which makes the
  broker revoke the effect and kill its executor process group. No
  cooperation from the dying process is needed.
- **Structured concurrency holds only while the combinator does.** Workers
  are unlinked and monitored, and the combinator drives cancellation from
  its own loop, so a combinator killed from outside — most plausibly by a
  linked `cap/actor` crash — orphans its workers until the node dies. The
  guarantee to state is "no work outlives the satellite".
- **The actor link runs to the *spawner*, not to the program root.** An
  actor spawned by `main` fails the program as a unit; one spawned inside a
  `cap/task` branch is contained to that branch and surfaces as a
  `Crashed` failure. "All-for-one" (spec §1.6, WP-J) describes the first
  case only.
- **Mailboxes are bounded and `send` parks.** Admission is synchronous and
  handling is asynchronous, so a fast producer meets backpressure rather
  than growing the heap. Parked senders are bounded by how many processes
  push at once, never by message rate.
- **Deny-by-default for `cap/net` is a broker property.** Nothing in
  `cap/net` refuses anything; it marshals and dispatches exactly as
  `cap/fs.read` does and only labels the broker's refusal. The design's
  guarantee holds because no policy field exists for a program to flip, not
  because this module checks anything.
- **Every boundary decodes totally.** A wrong-shape `cap_result` field is a
  `String` fault a caller maps to its own typed error; an oversized length
  prefix, an unparseable payload, or an unsupported version is an
  `inbound.Fault` that settles in-flight calls in-band and closes the
  channel; a well-formed frame of any other kind is dropped and the channel
  stays open. Nothing here panics, and a crash inside the submitted `main`
  becomes an `Errored` outcome rather than a dead node.

## Deep Docs

- [docs/architecture/code-mode.md](../../docs/architecture/code-mode.md) —
  the two layers, the prelude as the capability system, and what each layer
  actually confines.
- [docs/architecture/effects.md](../../docs/architecture/effects.md) — the
  one door, the framed wire, the jail, Rule Zero.
- [packages/codemode/CLAUDE.md](../codemode/CLAUDE.md) — the harness side:
  the lint, the hermetic build, the launcher, and the host at the other end
  of this channel.
- [docs/review/m4-triage.md](../../docs/review/m4-triage.md) — the review
  wave this package's current shape answers.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.
