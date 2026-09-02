# ext

## Purpose

The extension prelude: the vocabulary an out-of-tree extension author
writes their tools against, and the satellite runtime that runs them. It
is `cap`'s sibling — a second small package vendored into every code-mode
build root, published on its own, and running *inside* the jailed
satellite node rather than in the harness VM.

The split from `cap` is deliberate. `cap` is the capability language: what
a jailed program may *reach*. `ext` is the behaviour contract: what shape
a jailed program must *be* to serve a tool call. A code-mode program is a
`fn() -> report.Outcome` the harness already knows the arguments of; an
extension is compiled once at install and run many times, so the call is
what varies, and something has to fetch it, dispatch on it, and marshal
the reply. That something is `ext/runtime.serve`, the one line a generated
entry module contains.

Phases 1 and 3 of `docs/design-notes/extension-architecture.md`
(Decision 1, tier J; Decision 3 for hooks). Nothing here reaches the
harness: an extension's whole effect
surface is `cap/*`, judged per call by the broker exactly as a code-mode
program's is.

## Key Types

- `ext.{Ctx, Content, Terminate, Outcome, Refusal, Tool}` — the whole
  author-facing vocabulary. `Tool = fn(dynamic.Dynamic, Ctx) ->
  Result(Outcome, Refusal)`: arguments in as a `Dynamic` (their shape is
  the manifest's `parameters` JSON schema, which the harness knows and
  this package does not), the call's `Ctx` beside them, an outcome or a
  refusal out. A refusal is a *value* because it is text the model reads
  and repairs; a crash is a fault the harness reports and the model can do
  nothing with.
- `ext.Terminate` — `ContinueRun | TerminateRun`, the tool reply's
  `terminate` (`core/entry`) as a named type rather than a bare `Bool`, so
  a call site says which it means.
- `ext.Content` — `Text(String) | Json(json.Json)`. A JSON block travels
  to the harness as its serialization, because the capability channel
  speaks msgpack and a round trip through two structured encodings is a
  place for the two sides to disagree about numbers.
- `ext.Ctx` — `strand`, `deadline_ms`, and `report: fn(String) -> Nil`.
  `report` is a function value rather than a capability import so an
  author can exercise a tool in their own tests with no channel; in the
  satellite it is `cap/report.emit`, best-effort, so a partial that could
  not be emitted never fails the call it was narrating.
- `ext/hook.{Hook, Verdict, Call, RunStart, event, answer}` — phase 3's
  half of the hook surface. `Hook` is one variant per event
  (`OnSessionStart`, `OnBeforeAgentStart`, `OnContext`, `OnToolCall`,
  `OnToolResult`, `OnAgentEnd`, `OnAgentSettled`), so an entry that
  answers the wrong event is a compile error rather than a shape mismatch
  on the wire. `event` is the manifest name a hook answers; `answer` runs
  one against the harness's `args` document and renders the
  `hook_result` value. Both documents are JSON text, because the
  extension seam admits `gleam/json` and no msgpack decoder. A
  conversation message arrives as `Dynamic` and leaves as `Json`: `core`
  is not on the seam, so this package cannot hold the message type, and
  the harness re-decodes what comes back with `core/codec`'s own total
  decoder.
- `ext/runtime.{serve, answer, dispatch}` — `serve` is the generated
  entry's one call; `answer` is the program `serve` hands to
  `cap/runtime.run`, separated so the round trip is drivable over an
  injected transport; `dispatch` is pure but for the tool it invokes, so
  an author can test their own table without a channel at all.

## Relationships

- **Depends on**: `cap` (path — `cap/ext` for the call, `cap/report` for
  the outcome and partials, `cap/runtime` for the boot), `gleam_json`, and
  the standard library. `gleam_erlang`, `gleam_otp` and `core` are
  dev-only, for the faked-channel test.
- **Deliberately reuses `cap/runtime.boot`/`run` rather than
  reimplementing them.** The token file, the socket, the exclusive channel
  slot and the terminal `outcome` frame stay in one place; this package
  never names a token and could not read one.
- **Depended on by**: nothing in the harness. `packages/client`'s install
  pipeline *vendors* it (`compile.ext_path` = `vendor/ext`) and writes a
  generated `loom_satellite` that imports `ext/runtime`; linking it into
  the harness VM would break Rule Zero.
- **FFI**: none, of any target.

## Traffic

- **Wire, out** — one `cap_call` for `ext.call` with the empty argument
  map, at boot, before anything else happens. Its result is
  `{tool: String, args: String, strand: String, deadline_ms: Int}`, with
  `args` as **JSON text** rather than a msgpack value: an `ext.Tool` takes
  a `Dynamic`, and `gleam_json`'s parser is the only total route to one
  that the extension seam's allowlist admits.
- **Wire, out** — zero or more `report.emit` calls, one per `Ctx.report`.
- **Wire, out, exactly once** — the terminal `outcome` frame
  `cap/runtime` already writes, carrying
  `{ok: true, value: {content: [block…], terminate: Bool}}` or
  `{ok: false, message, details: {tool}}`, where a block is
  `{type: "text", text}` or `{type: "json", json}`.
- **Commits / registers**: none. This package cannot touch durable
  storage.

## Invariants

- **One satellite serves exactly one call.** `serve` fetches a call,
  dispatches it, and returns; `cap/runtime` writes one `outcome` frame and
  the node exits. A second `ext.call` would be a second admission against
  the same token, so there is no loop here to make one.
- **An unknown tool name names what is served.** The manifest and the
  artifact were written by the same install, so a name mismatch is a
  broken install rather than a bad model call. The error outcome carries
  both sides — the name asked for and the sorted list served — because an
  operator reading it needs the disagreement, not half of it.
- **Nothing here refuses a capability.** Like `cap/net`, this package
  marshals and labels. Deny-by-default is the broker's property; an
  extension's net policy is composed from its manifest at dispatch (phase
  2), never checked in the jail.
- **A tool's crash is still an outcome.** `cap/runtime` runs the program
  in a monitored child, so a `panic` or a failed `let assert` inside an
  extension's tool becomes an `Errored` outcome rather than a dead
  satellite the host has to time out.
- **Arguments that are not JSON never reach a tool.** They were schema
  checked on the harness side, so unparseable text is a harness bug; the
  satellite reports it naming the tool rather than guessing past it.
- **`decode_args` names the field.** Every decode failure `decode.run`
  found is rendered, because the model reads the refusal and retries, and
  "expected String at .city" is a repair instruction while "bad arguments"
  is a dead end.

## Deep Docs

- [docs/design-notes/extension-architecture.md](../../docs/design-notes/extension-architecture.md)
  — the ruling: two tiers, brokered egress, the manifest, the phases.
- [docs/adr/007-extension-tiers-and-brokered-egress.md](../../docs/adr/007-extension-tiers-and-brokered-egress.md)
  — the two decisions that outlive one change.
- [packages/cap/CLAUDE.md](../cap/CLAUDE.md) — the capability prelude this
  one sits beside, and the boot runtime it reuses.
- [packages/client/CLAUDE.md](../client/CLAUDE.md) — the harness side:
  the manifest decoder, the install pipeline, and `loom ext`.
- [docs/architecture/code-mode.md](../../docs/architecture/code-mode.md) —
  the three seams and what each confines.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.
