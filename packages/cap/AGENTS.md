# cap

## Purpose

The capability prelude: the language a code-mode program is written
against, plus the boot runtime that runs it. Every `cap/*` module a
submitted program may import is here, and every one of them is an RPC stub
— a typed local-looking call that marshals its arguments into a `cap_call`
frame, sends it over the one AF_UNIX channel to the satellite host, and
blocks for the `cap_result`. This package runs *inside* the jailed
satellite node, never in the harness VM, and is a separate build target so
it can one day be published on its own. WP-J, and WP-N for `cap/strand`.

The prelude serves **three seams**, and a submission is vetted against one
of them (`codemode/vet/policy.Seam`). The *workspace* seam is
`cap/{fs, proc, net, git, lsp, report, task, actor, kv}` — a program that
orchestrates effects. The *orchestration* seam is `cap/strand` +
`cap/report` and nothing else — a program that orchestrates agents. Those
two sets are disjoint but for `cap/report`, and that disjointness is the
point: an orchestrator that could also write files is a materially worse
thing to hand a model than one that cannot. The *extension* seam is the
workspace seam widened by the `ext` prelude alone, and its relation to
the other two is a superset rather than a disjointness on purpose — an
installed extension's tool is a workspace program with a different entry
point. It widens by no *capability* at all: `cap/ext.call` was phase 1's
"which call am I serving?" pull, and `protocol-change/012` deleted it,
because a satellite that lives for a session is *told* what to answer
over a `hook_call`.

This package therefore serves **two boot shapes**. `cap/runtime.run`
boots one program, writes one terminal `outcome` frame and dies — code
mode's disposable node. `cap/runtime.serve` boots the same channel over
the same socket and then waits, answering `hook_call`s until the harness
cancels or the channel closes — an installed extension's session-lived
satellite. The capability language beneath them is identical; what
differs is where a node's authority comes from, which is the invariants
below.

## Key Types

- `cap/report.{Outcome, Value}` — `Completed(value)` /
  `Errored(message, details)`. A program is a `fn() -> Outcome`;
  `to_msgpack` is the marshalling the boot runtime writes as the terminal
  frame, so a strand receives a structured value and never scrapes stdout.
  `Value` is a re-export of the wire's value type plus builders
  (`string`/`int`/`float`/`bool`/`list`/`object`/`null`) and readers
  (`field`/`as_string`/`as_int`/`as_float`/`as_bool`/`as_list`), none of
  which coerces: `as_int` refuses a float and `as_float` refuses an int,
  so the pair still answers which tag arrived. They live here
  because a program cannot name `core/msgpack`: the allowlist omits it and
  the hermetic build's `--warnings-as-errors` turns importing a transitive
  dependency into a compile error, so without them `report.text` was the
  only thing a program could say.
- `cap/mcp.{Content, ToolResult, McpError}` — the shared vocabulary for
  the generated `cap/mcp/<server>` façades (issue #106): `Text`/`Other`
  content blocks (non-text kinds carried by name only in v1), the tool
  result with its optional structured output, and the error in
  `cap/fs.FsError`'s shape (`ToolFailed` / `ServerUnavailable` /
  `McpDenied` with the broker's code verbatim / `ResultMalformed`).
  Types only, no authority: the one marshaling seam is
  `cap/internal/mcp.invoke`, which sends `{tool, arguments}` — `tool`
  the server's original name verbatim — under the per-server capability
  `"mcp." <> server`, and being internal it is reachable only through a
  generated façade the vetting allowlist names. On no *static* seam
  (`harness_only_cap_modules`), and that is now permanent rather than a
  wait: a façade exists only where a server is configured, so a host with
  MCP servers widens the workspace seam's allowlist at boot with
  `cap/mcp` and each generated module (`client/codemode.seam_allowlist`),
  and a host with none allows neither.
- `cap/strand.{Assignment, Handle, Waited, TerminalResult, StrandError}` —
  the orchestration seam. `assignment`/`within`/`detached`/
  `from_my_conversation`/`with_tools`/`expecting` build a spawn; `spawn`,
  `wait` (a list of handles against **one** deadline), `send`, `note`,
  `notes` and `roster` are the six calls, serviced by the same
  `client/agency` closures the `agent_*` tools call. Every `StrandError`
  variant but the last two is one of the harness's own refusal names
  carrying the harness's own sentence — except the two ceilings, which are
  the seam's own: `SpawnCeilingReached` and `AdmissionCeilingReached`, the
  second covering `send`, `note` and `notes` alike because a program at
  any of them does the same thing and the message names which. The named
  set matches `codemode/orchestration.refusal_code`'s range as of today,
  `map_error` being the other half of that contract: `NameAlreadyMinted`
  and `PlaneFailed` are there for that reason and not because a program is
  expected to recover from either. `StrandRefused` stays the arm for a
  code this module has not learned, so a new name still reaches a program
  as itself — which is also why the two sides can drift silently, and what
  the pins are for. **Nothing gates the pairing across the wire**: `cap`
  and `codemode` share no dependency, so no check in either package can
  see the other's list. What *is* gated is each end against its own type —
  `strand_test.named_code` and `orchestration_test.expected_code` are
  total `case`s, so adding a variant to `StrandError` or to
  `agent.Refusal` breaks that package's test compile and forces whoever
  adds it to write the code down and look at the paired list. Adding a
  variant on one side and not the other still compiles everywhere; the
  alarm is that you were made to read the sentence saying so.
- `cap/runtime.{Transport, BootError}` — the boot runtime's injected
  transport (`send`, `recv`, `outcome_sink`) and its four setup failures.
  `run(main)` is the production convenience the generated satellite entry
  module calls; `boot` is the testable core beneath it.
- `cap/runtime.{Invocation, Answer, Asked}` with `serve`/`serve_over` —
  the other boot shape, and a persistent satellite's whole main loop.
  `serve(answer)` reads the environment, boots the channel and waits;
  `serve_over(token, transport, answer)` is the same loop over an injected
  transport, the seam `boot` takes and for the same reason. `Asked(
  invocation, args, deadline_ms)` is one `hook_call` with its `kind`
  string already turned into a closed set — `Tool(name)` or `Event(name)`,
  anything else refused `bad_kind` — and `Answer` is `Answered(value)` /
  `Refused(code, message)`, mirroring the `hook_result` body. The three
  codes this loop mints itself are `bad_kind`, `busy` and `crashed`;
  every other code is the serving function's own vocabulary
  (`packages/ext`'s, in practice).
- `cap/schedule.{Schedule, Created, Wake, Bounds, ScheduleError}` — heartbeats a
  program sets for the strand it is running on or for a strand that
  strand spawned, the code-mode half of the door `tools/schedule` opens
  for a tool call. Both land on one
  implementation (`client/scheduleseam.Door`), so either door can cancel
  what the other created. `Created.wake` is what the host actually
  granted and is not always what was asked for — an operator policy may
  permit scheduling and forbid waking — so a program that needs waking to
  be meaningful must read the field rather than assume the request. It is
  a `Wake` (`WakesIdle | SteersOnly`) rather than a `Bool`, so the
  request and the grant read the same way at both ends; the capability
  wire still carries a boolean in both directions.
  **Four timings, and two of them are not conveniences.** `every` is a
  fixed interval, `at` a UTC instant, `cron` a five-field calendar
  expression, and `after` a one-shot a fixed while from now — one of the
  four per schedule. `after` exists because *nothing tells a program the
  current time*: the strand's prompt carries no clock and no date, so an
  absolute instant for `at` cannot be computed inside a program and a
  guessed one is either refused or fired at the wrong moment; the host
  resolves it against the session's own clock, bounded at 1..604800
  seconds. `cron` exists because an interval cannot express a *phase* —
  the grid is aligned to the epoch, so `every(…, 86_400, …)` is always
  00:00 UTC — and it is the standard five fields and nothing more: UTC
  throughout, no seconds field, no month or day names, none of
  `L`/`W`/`?`/`#`, and the two day fields ORed rather than ANDed when
  both are restricted. `every_within` and `cron_within` are the same two
  recurring shapes with `Bounds(max_fires:, expires_after_s:)` stated
  rather than defaulted; `DefaultBounds` is what the four plain
  functions pass, and `Bounds` can only *narrow* — the host holds both
  numbers to the same ceilings it holds its own configuration to and
  denies anything above one as `invalid_schedule`.
  **A target is a request, never an instruction.** `every_on`, `at_on`,
  `cron_on`, `after_on` and `cancel_on` are the functions that name one, and the host
  admits only the calling strand itself or a strand it spawned, decided
  from its own lineage ledger and refused as `invalid_schedule`
  otherwise — a program cannot reach a sibling's or a parent's context by
  writing a name. The plain `every`/`at`/`cron`/`after`/`cancel` mean
  this strand. Two consequences a program has to read rather than
  assume: a schedule onto a subagent is always `SteersOnly`, because a
  subagent has one run and a fresh one after it would extend a child's
  life past its work; and `list`/`cancel` are keyed on the strand that
  **created** a schedule rather than the one it fires onto, which is what
  makes a heartbeat onto a subagent cancellable at all once that
  subagent has finished. `Schedule.target` and `Created.target` are how
  a program tells the two apart, since one name may be in use on this
  strand and on a child's at once.
  Workspace seam only and not orchestration, asked and decided in issue
  #156. The bar for the one entry the two seams share is the bar
  `cap/report` meets: `report.emit` mints nothing durable and causes no
  later effect, it is only how a program says what it found. A `create`
  here mints a durable reserved cell that admits a turn onto a strand at
  a later time, with nobody present and possibly waking an idle strand,
  which is the ability to cause future execution and so is authority.
  The intersection of the two seams' allowlists *is* the confinement
  property, so widening it from one module to two would spend one rule
  read in two directions on a convenience nobody has asked for; nothing
  is unreachable, only indirect, since an orchestration program has the
  strand it runs on schedule a heartbeat through the `schedule_*` tools.
  The intersection test pinning `["cap/report"]` is the ruling's
  checkable form.
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
  `SetToken(token)` is the serving loop's alone: it installs the
  invocation's token before the answer starts and clears it after.
  `cap/actor` and `cap/task` spawn their own processes but exchange no
  package-level protocol.
- **Wire** — one AF_UNIX stream, length-prefixed msgpack, protocol version
  1, 16 MiB cap. Out: `cap_call` (carrying the token, the capability name,
  the marshalled args, and a deadline) and `cancel`. `strand.wait` is the
  one call that sets its own deadline — the join window plus
  `wait_margin_ms` — because the harness answers `Pending` at the window
  rather than hanging, and the channel must outlast that. In:
  `cap_result`, the answer to something this node asked, and `hook_call`,
  the one frame the harness asks *it* (`protocol-change/012`) — a
  single-shot node's reader drops the second, and both shapes drop every
  other well-formed kind and keep the channel open. Out, once per
  invocation on a serving node: `hook_result`, carrying the frame `id` of
  the `hook_call` it answers. Out, exactly once per execution on a
  single-shot node: the terminal `outcome` frame
  (`{v: 1, id: 0, kind: "outcome", body}`) carrying
  `report.to_msgpack(outcome)`. A serving node writes **no** `outcome`
  frame at all, because it ends no execution.
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
  slot. Under the single-shot shape that guard never fires, because every
  execution gets a fresh node; under the serving shape it is what would
  catch a host that started a second satellite for one extension without
  reaping the first, which is why `codemode/satellite` states the reaping
  obligation as *a host reaps its node before the session's next host for
  that extension starts*.
- **A serving node's authority belongs to the invocation, not to the
  node.** The token file `read_token` reads is deliberately not a working
  token for a serving satellite; it satisfies the boot sequence and
  nothing else. Every token that works arrives on a `hook_call`, is
  installed with `channel.set_token` before the worker starts, and is
  cleared to empty bytes after the answer ends — so a process the
  extension kept alive between invocations frames its `cap_call`s with
  bytes the harness has already revoked. **An extension may compute
  between invocations and may not act**, and the ordering is what makes
  that true: install, then spawn; answer, then clear.
- **One invocation at a time, and a crash is an answer.** A second
  `hook_call` arriving while one is open is answered `busy` on the spot
  and never queued — a queue would mean a second token installed under
  the first invocation's worker, and the harness serialises anyway, so a
  second is a fault to name rather than work to schedule. The invocation
  runs on a monitored child of the loop, so a `panic` in extension code
  becomes `crashed` on the wire and the loop goes on to the next
  invocation; that child is also what keeps the loop in its selector, so
  the `busy` answer is not stuck behind an invocation that may run for
  its whole deadline. The loop ends on a `cancel` frame or a closed
  channel, in both cases by returning.
- **Cancellation is real, not advisory.** The channel monitors the caller
  of every in-flight call. Killing a `race` loser therefore produces a
  `DOWN`, which emits a `cancel` frame for that call id, which makes the
  broker revoke the effect and kill its executor process group. No
  cooperation from the dying process is needed. The combinator signals every
  losing worker before it waits on the original monitors, then returns only
  after every Down has joined. This ordering prevents one slow exit from
  postponing cancellation of its siblings.
- **Fail-fast reports the failure which triggered cancellation.** Indices
  absent from the runner's completed-outcome map are tasks it killed after
  observing that failure. They do not become synthetic lower-indexed crashes,
  because doing so would make `both` and `parallel_map_fail_fast` depend on
  scheduler order and hide the error which actually stopped the group.
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
- **Filling the bounded queue to its bound costs O(bound), not
  O(bound²).** The internal queue is the two-list technique — push onto
  `back`, pop from `front`, reverse `back` onto `front` only when the
  latter runs dry — with its length tracked in a counter rather than
  recomputed, so `handle_admit`'s bound check and the push it gates are
  both O(1). Before issue #45 both were `list.length`/`list.append` over
  a single list, which made admitting a mailbox's worth of messages cost
  the square of the bound; the fix removed the factor rather than moving
  it, the same lesson `08cdbce` drew from `core/json`'s excerpt.
- **Four of the six calls carry a lifetime admission ceiling, and the
  numbers hold together.** `spawn` 32, `send` 128, `note` 256, `notes`
  64; `wait` and `roster` none, because a wait's cost is time and a
  roster's size is `session_strands`. The test a call has to meet is that
  it *mints something outliving the execution*. **`note` and `notes` are
  one decision**: a note/notes loop is quadratic in harness work and the
  quadratic needs both factors unbounded, so relaxing either alone puts
  it back. The ceilings are the host's (`codemode/satellite.CapCeiling`);
  this side only names what comes back.
- **A refusal keeps the harness's name, or arrives as itself.**
  `cap/strand.map_error` turns a broker code back into the variant of the
  same name, and the codes are `codemode/orchestration.refusal_code`'s
  plus the two ceiling codes.
  The two packages share no dependency — they are the ends of one wire,
  not peers — so each side pins its own half and the orchestration sample
  crosses the whole of it for real. A code neither side has learned yet
  comes back as `StrandRefused` carrying the code verbatim rather than
  being folded into a generic failure.
- **Nothing asked for is nothing, not an empty list.** A spawn with no
  declared result shape sends `nil`, not `[]`, so it is distinguishable
  from one that declared an empty shape — which is what keeps the
  harness's `NoResultAsked` verdict a separate fact from "the child
  answered nothing".
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
