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
extension is compiled once at install and run many times, so the
invocation is what varies, and something has to dispatch on it and marshal
the reply. That something is `ext/runtime.serving`, the one call a
generated entry module contains.

**A satellite is launched once per session and answers many invocations**
(`protocol-change/012`, ADR-007 Decision 3). Phase 1 launched a node per
call and had it *pull* its work with a single `cap/ext.call`; phase 3
deleted the capability and the pull with it, because a node that lives
past its first answer has nothing left to pull against and no token for a
second call. The harness now *tells* the satellite what to answer, on a
`hook_call`, and `cap/runtime.serve` is the loop that waits for one.

Decision 1 (tier J) of `docs/design-notes/extension-architecture.md`, with
Decision 3 of ADR-007 for the satellite's lifetime. Nothing here reaches
the harness: an extension's whole effect surface is `cap/*`, judged per
call by the broker exactly as a code-mode program's is — and judged only
*while an invocation is open*, because the token every `cap_call` presents
is the one the harness minted for that invocation.

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
- `ext/runtime.{serve, serving, answer, Handler}` — `serving(tools:,
  events:)` is what a generated entry calls and it does not return until
  the harness cancels the satellite or the channel closes; `serve(tools)`
  is `serving` with an empty event table, which is what an extension that
  declares no `[[hook]]` gets. Two functions rather than one with an
  optional argument, because the generated entry writes whichever call the
  manifest asked for and the common one should read as the common one.
  `answer(tools, events, asked)` is the whole dispatch as a pure-but-for-
  the-tool function over a `cap/runtime.Asked`, so the round trip is
  drivable with no channel and no socket — which is how this package's own
  tests run it, and how an author tests their own table.
- `ext/runtime.Handler` — `fn(cap/report.Value) -> Result(Value, String)`,
  one hook event handler. Deliberately untyped in the payload: wave B of
  the extension work fixes what each event carries, in one place at each
  end, and until then this module carries whatever the harness sends
  without claiming to know its shape. `Value` is `cap/report`'s, so a
  handler builds its answer with the same `report.object`/`report.string`
  vocabulary a tool builds a JSON block with.
- `ext/runtime.{refused_code, unknown_tool_code, unhandled_code,
  bad_arguments_code}` — `"refused"`, `"unknown_tool"`, `"unhandled"`,
  `"bad_arguments"`. Four codes rather than one because they are four
  different facts about an install: a refusal is the extension working as
  written, an unknown tool is a manifest and an artifact that disagree,
  an unhandled event is an extension that does not care about this moment,
  and bad arguments are a harness that sent something the schema check
  should have caught. `cap/runtime`'s own `bad_kind`, `busy` and `crashed`
  are minted a layer below and never here.

## Relationships

- **Depends on**: `cap` (path — `cap/report` for the answer's value and
  for partials, `cap/runtime` for the boot and the serving loop),
  `gleam_json`, and the standard library. `gleam_erlang`, `gleam_otp` and
  `core` are dev-only, for the faked-channel test.
- **Deliberately reuses `cap/runtime.serve` rather than reimplementing
  it.** The token file, the socket, the exclusive channel slot, the
  per-invocation token install and clear, the one-at-a-time rule and the
  crash-into-an-answer handling all stay in one place; this package never
  names a token and could not read one.
- **Depended on by**: nothing in the harness. `packages/client`'s install
  pipeline *vendors* it (`compile.ext_path` = `vendor/ext`) and writes a
  generated `loom_satellite` that imports `ext/runtime`; linking it into
  the harness VM would break Rule Zero.
- **FFI**: none, of any target.

## Traffic

- **Wire, in** — a `hook_call` per invocation, which `cap/runtime` hands
  over as an `Asked`. A tool invocation's arguments are
  `{args: String, strand: String}`, with `args` as **JSON text** rather
  than a structured value: an `ext.Tool` takes a `Dynamic`, and
  `gleam_json`'s parser is the only total route to one that the extension
  seam's allowlist admits, and carrying text means the harness hands over
  exactly the bytes the model's tool call carried with no re-encoding in
  between to disagree about. An event invocation's arguments are that
  event's own row, handed to its handler unread.
- **Wire, out, one per invocation** — the `hook_result` `cap/runtime`
  writes from the `Answer` this module returns:
  `{ok: true, value: {content: [block…], terminate: Bool}}`, where a block
  is `{type: "text", text}` or `{type: "json", json}`, or
  `{ok: false, error: {code, msg}}` under one of the four codes above.
  Nothing here writes a frame itself.
- **Wire, out** — zero or more `report.emit` calls, one per `Ctx.report`,
  and whatever `cap/*` calls the tool itself makes. All of them travel
  under the invocation's token and are refused outside an open invocation.
- **Wire** — **no `outcome` frame, ever.** A serving node ends no
  execution, so the terminal frame the single-shot shape writes has no
  counterpart here.
- **Commits / registers**: none. This package cannot touch durable
  storage.

## Invariants

- **One satellite serves many invocations, and pulls none of them.**
  `serving` hands `cap/runtime.serve` an answering function and never
  returns until the channel closes or the harness cancels. There is
  nothing here that asks for work, and there could not be: a node that
  outlives its first answer holds no token of its own, so a pull would be
  a `cap_call` the harness refuses. Serialisation, the per-invocation
  token, `busy` and `crashed` are all `cap/runtime`'s; this module sees
  one `Asked` at a time and answers it.
- **An extension may compute between invocations and may not act.** A
  tool that keeps an actor or a client alive across calls is the whole
  point of a persistent satellite; a tool that reaches a capability from
  one *between* invocations is refused, because the token its `cap_call`
  is framed with was revoked when the last answer went out. Nothing in
  this package enforces that and nothing in it can — state it here so the
  next author reads it before writing a background poller.
- **An event with no handler is an answer, not a fault.** The harness
  offers every installed extension every moment on its timeline and most
  extensions care about none of them, so a missing handler is `unhandled`
  and the bus reads the code and moves on. That is the one code whose
  ordinary meaning is "nothing happened".
- **An unknown tool name names what is served.** The manifest and the
  artifact were written by the same install, so a name mismatch is a
  broken install rather than a bad model call. The error outcome carries
  both sides — the name asked for and the sorted list served — because an
  operator reading it needs the disagreement, not half of it.
- **Nothing here refuses a capability.** Like `cap/net`, this package
  marshals and labels. Deny-by-default is the broker's property; an
  extension's net policy is composed from its manifest at dispatch (phase
  2), never checked in the jail.
- **A tool's crash is still an answer, and the satellite survives it.**
  `cap/runtime` runs each invocation in a monitored child of its loop, so
  a `panic` or a failed `let assert` inside an extension's tool becomes a
  `crashed` `hook_result` and the loop goes on to the next invocation.
  One bad invocation must not cost the session its satellite.
- **Arguments that are not JSON never reach a tool.** They were schema
  checked on the harness side, so unparseable text — or an envelope with
  no `args` field, or one whose `args` is not text — is a harness bug; the
  satellite answers `bad_arguments` naming the tool rather than guessing
  past it. A missing `strand`, by contrast, is the empty string rather
  than a refusal: attribution is what it is for, and an invocation with no
  strand is still one a tool can serve.
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
