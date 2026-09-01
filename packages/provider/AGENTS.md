# provider

## Purpose

The provider SDK: a typed registry of provider configurations and role
routes, a pure incremental server-sent-events parser, two wire adapters
(Anthropic Messages, OpenAI chat-completions), retry and overflow
classification, and the secret-injection seam. SSE parsing and adapter folds
are pure Gleam; the gateway custodian and native transport owner are the small
processful shell around that sans-io core. WP-F.

## Key Types

- `provider/gateway.Gateway` — opaque, built with the builder pattern
  (`new`, `add_provider`, `route`, `with_attempt_timeout`); exposes the
  frozen contract `resolve(gw, role)` and `request(gw, req)`. `prepare`
  additionally exposes the internal prepare-publish-begin seam: it returns a
  parked owner before route resolution, secret lookup, or network work starts.
  That owner is the request guard, a `weft/state_machine` over `Phase` and
  `Guard`; see **Traffic** for its states and its three state timeouts.
- `provider/model.{Role, ResolvedModel, ProviderRequest, RequestTarget,
  ToolSpec}` — the durable identity (`{provider, model_id}`) plus the
  static model facts an adapter needs: context window, output ceiling,
  thinking level. `RequestTarget` is `ForRole(role, thinking)` (resolve
  at dispatch and walk) or `ForResolved` (dispatch to exactly this
  identity). `ForRole.thinking` is the caller's reasoning-budget
  overlay (`protocol-change/009`): `None` leaves each walked entry's own
  declared level in force, `Some(level)` applies that level to **every**
  target the walk attempts.
- `provider/stream.StreamHandle` — the consumption contract WP-E relies
  on: zero or more `Delta` events, then exactly one terminal `Settled` or
  `Failed`, and nothing after it. Its cancel capability signals the one
  gateway owner that decides the cancellation/terminal race; its optional
  owner pid is a drain witness for every asynchronous descendant.
- `provider/stream.{DrainWitness, DrainOutcome}` — the original monitor and
  its reason-bearing result. Critical callers install the witness before
  `begin`; only `Drained` permits replacement work, while `TimedOut` leaves
  the monitor live and `ProofLost` preserves an abnormal owner exit.
- `provider/stream.PreparedStream` — a `StreamHandle` whose owner exists while
  work is parked, plus the idempotent begin permit. Composition layers publish
  the handle first and grant the permit only after adoption succeeds.
- `provider/stream.SseParser` — pure, bounded, incremental: bytes in,
  `SseEvent`s out, carry state threaded. Same bytes in any chunking yield
  the same events. A line and one event are each bounded to 4 MiB, one event
  may retain at most 4096 `data:` fields, and one attempt may feed at most
  16 MiB of response body.
- `provider/stream.ResponseMachine(state)` — a fold over `HttpEvent`s
  producing `StreamEvent`s; each adapter supplies one.
- `provider/http.{Transport, RunningRequest, HttpRequest, HttpEvent}` — the
  injected transport seam. A running request exposes a monitorable owner and
  cancel capability; normal owner exit acknowledges that native work has
  stopped, while abnormal exit loses that proof.
  `httpc_transport()` is the production wiring.
- `provider/secret.SecretStore` — an injected `fn(String) ->
  Result(String, Nil)`; backends are `env()`, `from_list`, `from_function`.
- `provider/retry.{RetryClass, RetryPolicy}` — `classify`, `backoff_ms`,
  `is_overflow_message`, `overflow_message`.
- `provider/internal/diagnostic` — the pure resource and redaction boundary for
  remote failures after transport delivery: a 64 KiB retained body budget,
  byte-bounded diagnostic fields, and exact scrubbing of the request key before
  an error leaves the gateway.

## Relationships

- **Depends on**: `core` (json, messages, corruption — for the durable
  message shapes and total JSON parsing), `gleam_erlang` (the stream pump
  runs on its own process), `weft` (the custodian is a witnessed run with
  a managed task; see `custodian.gleam`).
- **Depended on by**: `runtime` (`effects.ProviderSurface` is
  type-compatible with `StreamHandle`, and `settle_failure` bridges
  `retry.classify` into the machine's retryability convention),
  `conformance` (wiring and the e2e).
- **FFI**: `provider/internal/ffi_httpc` — prepares, begins, and cancels one OTP
  `httpc` owner in asynchronous streaming mode. That owner selects its own raw
  messages and waits for the dedicated request handler to exit after
  cancellation.
  Gleam cannot selectively receive raw `httpc` tuples, and OTP exposes
  cancellation as an asynchronous cast rather than a socket-drain
  acknowledgement. The shim therefore forces a non-reused, non-queued handler
  and disables handler migration through redirects and automatic retries. OTP
  29 publishes the exact request-ID-to-handler row before successful admission
  returns. The response callback remains inside the handler until the owner
  acknowledges that its monitor is installed, so a fast terminal cannot erase
  that row first. One O(1) protected-table read is the normal capture path. Any
  lookup miss enters a deadline-bounded recovery scan which asks only
  `httpc_handler` processes for their current request and never turns a missing
  or inconclusive answer into drain. A later OTP with unfamiliar private
  shapes falls back to the callback's exact producer identity; if no callback
  arrives, the request deadline ends the owner abnormally rather than claiming
  drain. The internal OTP dependency is
  confined to callback receipt, exact capture, and direct cancel. All
  ownership, fallback, deadline, and terminal state machines stay in typed
  Gleam. `provider/internal/ffi_env` — `os:getenv` for
  the environment secret store. These two are the package's complete inventory
  of impurity.

## Traffic

- **Actor messages**: `gateway.prepare` first publishes a minimal custodian;
  its begin permit then releases a guard and private pump for the whole
  fallback walk. The custodian is a weft *witnessed run* (`weft.managed`
  task, `weft.start_witnessed`): the guard is adopted as a leaf owner whose
  cancel capability is its typed stop message, every child the guard
  discovers is published through the run's `weft.Ledger`, and the scope's
  pid, rather than a crashable worker, is the public drain witness. The
  guard's exit and the consumer's exit are both `weft.cancel_when_exits`
  causes, so either fans cancellation out to every adopted child. The
  guard monitors the direct consumer and retains each active transport
  capability the pump publishes.

  The guard itself is a `weft/state_machine`. Its state ADT is
  `gateway.Phase` — `Parked`, `Starting`, `Requesting`, `Cancelling`,
  `Settling(terminal)`, `Reaping(cause)`, `ClosingPump`, `Abandoning`,
  `ClosingActive` — and everything per-request (the custodian, the pump,
  the active attempt and its monitor, the consumer monitor) is the `Guard`
  data record beside it. All three of its deadlines are **state timeouts**:
  the pump's ready handshake on `Starting`, the fixed cancellation grace on
  `Cancelling`, and the same grace again on `Reaping` when the pump died
  without authoring a terminal. Each therefore dies with the state that
  armed it, so no handler re-establishes its own relevance and the
  stale-fire arms the hand-rolled loop needed are gone. The machine is
  started unlinked through a `spawn_unlinked` trampoline: a crashing guard
  is observed by the custodian's worker adoption, never by a link into the
  consumer. A cancel or a consumer death that arrives while the pump is
  still parked is **postponed**, and weft replays it the instant
  `Requesting` is entered — where the hand-rolled guard used to find it
  still queued in its mailbox. The pump selects active-transport Down,
  absolute attempt deadline, cumulative response budget, and private
  per-attempt HTTP events. Together they deliver
  `StreamEvent`s to the caller's subject:
  `Delta(...)` zero or more times, then exactly one `Settled(settled,
  usage, ...)` or `Failed(error)`. `provider/http.HttpEvent` messages flow
  from the transport into that pump. Cancellation expiry closes the public
  response window but not the pump's ownership frontier: `ClosingPump`
  continues adopting and rejecting late attempt registrations until the pump
  exits, and `ClosingActive` waits for the last transport owner after it.
- **Commits / registers**: none. This package persists nothing; the
  durable identity it resolves is stored by `machine` and committed by
  `runtime`.
- **Wire**:
  - Anthropic Messages SSE events — `message_start`,
    `content_block_start`, `content_block_delta`, `content_block_stop`,
    `message_delta`, `message_stop`, `error`, `ping`.
  - OpenAI chat-completions SSE — unnamed events whose `data:` is a chunk
    document, terminated by the literal `[DONE]`; tool calls arrive as
    `choices[0].delta.tool_calls` fragments carrying a provider-side index.
  - Anthropic requests carry four `cache_control` breakpoints — one-hour
    on the last tool definition and on the system block, five-minute on
    the last block of each of the final two user turns. The system prompt
    therefore goes out as a one-element block array, not a bare string.
  - `api_name` constants pin the two dialects: `"anthropic-messages"`,
    `"openai-completions"`.

## Invariants

- **Ownership documentation states the proof carried by each PID.** Public
  stream, custodian, and transport APIs document why the owner exists, how
  cancellation reaches it, and what its Down acknowledges. A comment that
  only says a function "starts a process" is incomplete here: callers need to
  know whether that process does work or survives work as its drain witness.
  Only normal exit proves drain; abnormal exit means the witness was lost.
- **Secrets exist only in request memory.** A key is read from the
  `SecretStore` at dispatch, copied into one outbound header, and appears
  nowhere else locally — not in the gateway value, not in an accumulator, and
  not in a locally constructed error or persisted structure. `ProviderError`
  carries secret *names* only (spec §3.3 invariant 4). Because a remote endpoint
  can reflect the key it received, the gateway scrubs that exact value from
  terminal errors before retry classification or delivery. Successful streamed
  content is provider-controlled and is not credential-redacted across fragment
  boundaries; callers must not treat it as a secret-filtering boundary.
  Diagnostic strings are byte-bounded in the same pass. Issue #148 owns the
  stateful response-redaction work.
- **Exactly one terminal event per stream.** Deltas are ephemeral display
  data and never prove anything about settlement; nothing follows the
  terminal. The gateway owner is the sole terminal sender. Response activity
  does not renew the attempt deadline, and the cumulative 16 MiB response cap
  includes every chunk rather than only bytes retained by the SSE parser.
- **Cancellation reaches native work.** Explicit cancel and direct-consumer
  death cancel and drain the active transport before ending the route walk.
  The production native owner retains the exact OTP request id, receives the
  raw `httpc` callbacks itself, calls `httpc_handler:cancel/2`, and waits for
  the dedicated request handler's Down before exiting. An
  owner that misses the fixed grace is not killed from above: the guard emits
  `CancellationUnconfirmed` but stays alive until the owner drains, preserving
  the acknowledgement chain. A transport which finishes preparation after
  expiry is still published to that chain and receives a rejection permit, so
  neither the pump nor its parked owner can escape drain. `ProviderCancelled`,
  `CancellationUnconfirmed`, and `DrainProofLost` are terminal and never walk
  to a fallback. Raw
  OTP errors are collapsed to constant diagnostics before crossing the FFI so
  request headers and credentials cannot appear in a durable provider error.
- **Only the original monitor adjudicates drain.** The custodian records every
  child before begin. A leaf owns no descendants, so its own Down completes its
  lifetime; a transitive child requires `Normal`. An unexpected killed or
  abnormal transitive `Down` poisons the custodian even after cancellation has
  begun and propagates failure after the remaining known frontier is cancelled
  — as weft's `weft_drain_proof_lost` exit reason, which every judgement in
  this tree treats exactly like a kill. Cancel capabilities must stay
  idempotent: the witness asks every adopted owner to stop the moment
  teardown begins, and the pump cancels its active transport as well, so an
  owner may hear its cancel twice (protocol-change/010 permits it).
  A waiter which attaches after exit cannot recover this fact because Erlang
  reports `noproc`; critical callers retain a `DrainWitness` across `begin`.
- **Stop reasons map totally.** A stop or finish reason an adapter does not
  know settles the stream as `Failed(UnmappedStopReason)` in-band, never a
  crash.
- **The fallback chain walks only on retryable failures.** A terminal
  error, or an exhausted chain, delivers the failure in-band as `Failed`
  preserving retryability. A *settled* response never falls back, and
  `ForResolved` never falls back at all — that is the exact-identity
  path, which `client/wiring` takes for every deferred poll and for any
  strand whose captured identity heads no configured role.
- **A walk's reasoning budget is decided once, before the first
  attempt.** `ForRole.thinking` is overlaid onto the whole usable chain
  in `dispatch_role`, not per attempt, so a fallback is asked for the
  budget the *caller* asked for and cannot quietly differ from the head.
  A session-server generation carries `Some(the strand's per-turn
  level)`; a structural summary carries `None`, leaving the
  summarization entry's own declared level standing.
  `protocol-change/009` argues why the field is optional rather than
  required.
- **Overflow is checked before retry.** The machine's classification order
  puts overflow ahead of retryable error (an oversized request must
  compact, not retry unchanged), which is why the overflow patterns live
  beside the retry classifier. Adapter-computable overflow — input plus
  cache-read exceeding the context window with negligible output (≤ 64
  tokens) — settles as stop reason `error` with `retry.overflow_message`,
  preserving the raw stop reason.
- **Remote buffering is bounded.** The SSE carry buffer never exceeds
  `max_line_bytes` (4 MiB), and the completed `data:` lines waiting for one
  blank-line dispatch never exceed `max_event_bytes` (4 MiB). Every byte is
  scanned exactly once, so both a terminator-less line and an endless sequence
  of terminated data lines fail in-band instead of growing parser state. A
  delivered non-success HTTP body has a separate 64 KiB retained budget and
  fails immediately if the next chunk would cross it. OTP `httpc` buffers
  non-200/206 bodies before delivery, so this does not bound native error-body
  memory; issue #147 owns transport replacement or isolation.
- **Wire leniency is deliberate and asymmetric.** SSE `data:` payloads must
  parse as JSON (malformed data fails the stream in-band as
  `MalformedStream`), but *fields* are read leniently — absent usage
  counters read as zero, unknown event and delta types are ignored per the
  Messages API versioning policy. The total-decoder doctrine governs *our*
  durability boundaries, not foreign wire vocabularies.
- **Usage counters are clamped, not trusted.** `wire.count_field_or` /
  `optional_count_field` clamp into `[0, max_usage_count]` (1e12) at the
  read, so no count an untrusted proxy reports can reach a settled message
  the durable planes cannot encode (`core/msgpack` rejects integers outside
  `[-2^63, 2^64-1]`). Saturation is itself the record of the lie. Counters
  steer accounting and overflow classification only — never a security
  decision — so a lying proxy can at worst waste a compact-and-retry cycle.
- **Usage costs are zeroed**; token extraction only. Pricing tables are a
  ledger-side concern, not an adapter's.
- **Cache breakpoint placement is deterministic and adapter-local.** No
  caching knob crosses the package boundary: the four positions are a
  function of the request's own contents, so two builds of the same
  `ProviderRequest` are byte-identical and a cache hit is possible at all.
  The head (tools, system) takes the one-hour lifetime because it is read
  every turn of a session and must survive a human pause; the rolling tail
  takes the five-minute default because each entry is read about once. The
  final two *user* turns are marked, never assistant turns: a `thinking`
  block is not cacheable, and the alternation means consecutive requests
  re-mark a shared position instead of relying on the API's 20-block
  backwards search. One-hour breakpoints must precede five-minute ones,
  which head-before-tail satisfies by construction.
- **A rewritten prefix is a cost, never a correctness problem.** The cache
  key is the prompt bytes, so a precise rewrite or a compaction cannot
  serve stale content — breakpoints at or after the changed position
  simply miss and are written again. Nothing invalidates anything.
- **Overflow counts the whole prompt.** Spec §1.5 words the comparison as
  `input + cache_read`, from before either adapter reported a cache
  *write*; both now add `cache_write`, which is the same quantity the spec
  names and collapses to its two terms when nothing is cached. Leaving it
  out would shrink the apparent request by exactly what caching wrote.
- **The OpenAI dialect declares no breakpoints on purpose.** Its caching
  is automatic and prefix-matched server-side; the adapter owes it only a
  stable prefix (system message first, fixed field order). The optional
  `prompt_cache_key` routing hint is not sent — it needs a stable session
  identifier no `ProviderRequest` field supplies.

## Deep Docs

- [docs/architecture/effects.md](../../docs/architecture/effects.md) —
  "Providers", and the plane this package sits in.
- [docs/spec-gaps.md](../../docs/spec-gaps.md) — "From WP-F (`provider`)":
  the settled-message home, fallback semantics, the quantified "negligible
  output", wire leniency, deferred keychain backends.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.
