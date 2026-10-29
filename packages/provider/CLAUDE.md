# provider

## Responses disconnect diagnostics

`provider/adapter/responses` adds bounded structural context to
`StreamDisconnected` and `TransportFailed`: HTTP status (zero before status),
last complete allowlisted event and sequence, cumulative delivered body bytes,
a fixed media category, and a validated upstream `x-request-id`. Only
`req_` followed by exactly 32 lowercase hexadecimal bytes is retained; missing
and unfamiliar IDs become `absent` and `invalid`. Other headers and arbitrary
transport error strings never enter this context. Media values are reduced to
`sse`, `json`, `html`, `other` or `absent`, with bounded parsing.

Partial SSE chunks preserve the last complete event's structural witness.
Both Responses dialects use the same state and diagnostics. This changes no
terminal proof, usage accounting, retry classification, byte budget or deadline.
An HTTP 200 end without a verified terminal remains retryable failure; the
context can distinguish a proxy media type and correlate provider support logs,
but does not establish a capacity cause. The gateway's existing 400-byte error
scrubber remains authoritative.

## Responses keepalive control

`provider/adapter/responses` consumes the fixed `keepalive` control frame after
its existing JSON, SSE-name and sequence checks. The frame emits no content or
settlement and changes no item, part, usage or final-response witness. The
outer response byte budget and gateway attempt deadline remain authoritative;
keepalive cannot replace a missing terminal or excuse unknown semantic events.
The diagnostic event allowlist includes the fixed literal without reflecting
arbitrary remote strings. Both public and subscription Responses machines share
this fold.

## Responses metadata control

Subscription inference now sends `response.metadata` between content events.
The observed payload contains `response_id` and moderation metadata, but no
content, item closure or terminal witness. The adapter requires its response ID
to match the established stream identity, then advances the checked sequence
without changing items, usage or settlement. The provider's terminal remains
the authority for the outcome; metadata alone cannot finish a response.

## Responses service tier

`client/catalog.CatalogModel.service_tier` is an optional typed
`provider/model.ResponsesServiceTier`. Only `openai-responses` and
`codex-subscription` accept `[models.<name>].service_tier`, with `fast` or
`default`. Catalogue installation attaches the selection through
`provider/gateway.with_service_tier`, whose opaque per-provider map preserves
the frozen resolved-model and request contracts. Every attempt, including a
fallback, encodes its own entry's selection in the Responses request body.
An absent selection omits the field. Fast mode encodes the documented
`priority` wire alias for compatibility with native subscription inference.
Requesting Fast mode neither grants
eligibility nor proves the served tier, and does not change reasoning or
cybersecurity access. Operator pricing remains an estimate.

## Responses cybersecurity access

`client/catalog.CatalogModel.cyber_access` holds an optional typed
`provider/model.CyberAccessProgram` selected by `[models.<name>].cyber_access`.
Only `openai-responses` and `codex-subscription` accept the key. The catalogue
attaches it through `provider/gateway.with_cyber_access`; the opaque gateway
indexes selections by provider name, and each actual attempt passes that
entry's option into the Responses request encoder. API-key requests send an
explicit bounded `access_programs.cyber` value or omit the field when unset.
Subscription requests always omit it, including for existing configured entries:
the private endpoint can downgrade explicit selections to standard access, so
its entitlement-aware default owns selection. A 403 denial remains terminal;
retryable fallback uses the target entry's dialect and options. The frozen
resolved identity and request types keep their existing shape.

## Responses argument snapshots and access observations

`adapter/responses.arguments` accepts a function-argument done snapshot only
when it extends the bytes already streamed. It emits the missing suffix once,
including the full argument string when no deltas arrived, then records the
text closure. Item identity, canonical item closure and terminal output still
must agree before settlement. Conflicting or shortened snapshots still fail
with `arguments_done_witness`.

A settled message keeps the requested alias in `model` and the served model
in `response_model`. Nonempty `openai-model` headers of at most 256 bytes take
precedence over the response envelope's model, which remains the identity
witness. HTTP headers seed the observation; subsequent event headers update it,
with response-local headers preferred over top-level ones in the same event.

Its existing diagnostics namespace,
`loom.openai-responses.v1`, optionally includes terminal `access_programs.cyber`.
Only nonempty identifiers of at most 64 ASCII lowercase letters, digits,
underscores or hyphens are retained. Unknown identifiers in that alphabet are
observable; absent or invalid optional metadata is omitted. These are remote
observations, not access grants, and the request encoder never replays them.
Failed streams have no settled-message observation. No frozen interface changes.

## Exact-model evolution profiles

`provider/profile.Profile` is an immutable provider/model/API-specific overlay
of system prose, task prefix and tool descriptions. `gateway.attempt_one`
composes it only after fallback, vision and child routing resolve the actual
attempt. Every retry starts from the unchanged base request; a profile cannot
accumulate across attempts or alter a tool's name, input schema or execution
policy. Native attempt observation fingerprints the resulting composition even
when the attempt fails. A request guard runs before credentials and transport,
so an independent rollout can enforce exact targeting and conservative
aggregate budgets on every actual dispatch. `gateway.with_attempt_settled`
installs the observer that closes that loop: it is told once per attempt the
request guard admitted, in the pump's process, after the attempt's terminal
is priced and before the terminal is delivered, with the target, the API
dialect, the walk ordinal, the priced usage the ledger row will carry and
whether a response settled (`AttemptSettled`, `AttemptEnding`). An attempt
the guard refused is never reported, which is what lets the governed
rollout's guard credit a worst-case reservation back without ever crediting
one it never debited. See
[the evolution architecture](../../docs/architecture/evolution.md).

## Purpose

The provider SDK: a typed registry of provider configurations and role
routes, a pure incremental server-sent-events parser, four wire adapters
(Anthropic Messages, OpenAI chat-completions, Gemini generateContent, and
OpenAI Responses for public API and subscription transports), retry and overflow
classification, and the secret-injection seam. SSE parsing and adapter folds
are pure Gleam; the gateway custodian and native transport owner are the small
processful shell around that sans-io core. WP-F.

Tool-result images survive all three adapters. Anthropic retains image blocks
inside tool results; Gemini and OpenAI emit a user image turn after the complete
tool-result batch. OpenAI keeps the text tool messages and their call IDs before
that image turn, so parallel calls are all answered before a user message is
inserted. Captions identify each producing call; custom transcript entries do
not split the batch. These are transient wire projections.

## Key Types

- A terminal parsed from an HTTP chunk, including OpenAI `[DONE]`, requests
  native transport retirement and waits on the original owner monitor. It uses
  the same unbounded proof wait as `ResponseEnd`; the explicit-cancellation
  reporting grace cannot replace a completed provider result. Abnormal owner
  exit still loses proof, and explicit cancellation, request expiry, and
  response-budget refusal retain their bounded cancellation paths.

- `ProviderError.WithContext` carries the protocol 028 diagnostic envelope.
- `StreamError` carries optional structured `retry_after_ms` advice through
  scrubbing and retry classification (protocol 104). Responses reads nested
  direct errors and failed-response errors, retaining flat compatibility.
  Unclassified `responses_error` uses the existing three-generation ceiling
  and immediate gateway forwarding. Known permanent labels beat conflicting
  transient labels, statuses and throttle prose. Error messages and arbitrary
  remote labels never enter Responses diagnostics; only fixed descriptions,
  allowlisted labels and checked stream context survive.
- Responses unclosed-part corruption uses `RecoverableStreamCorruption` and
  `RetryableWithin` with three total attempts; the gateway forwards it without
  fallback. Other malformed witnesses remain terminal. Structural diagnostics
  retain only allowlisted labels and counts, not response content or IDs.
  `FailureObservation` names one of four local boundaries, the initiating
  event, known request/attempt identity, and configured time bounds. The
  envelope normalizes to at most one observation per boundary; oversized
  request identities are omitted, and the gateway scrubs retained strings.
  Classification and cancellation-sensitive routing inspect `underlying_error`.
  Context never substitutes for a drain witness or changes a deadline.

- `provider/gateway.Gateway` — opaque, built with the builder pattern
  (`new`, `add_provider`, `route`, `price`, `with_attempt_timeout`,
  `with_image_limit`, `with_codex_transport`); exposes the
  frozen contract `resolve(gw, role)` and `request(gw, req)`. `prepare`
  additionally exposes the internal prepare-publish-begin seam: it returns a
  parked owner before route resolution, secret lookup, or network work starts.
  That owner is the request guard, a `weft/state_machine` over `Phase` and
  `Guard`; see **Traffic** for its states and its three state timeouts.
- `gateway.CodexSubscriptionProvider(name, profile)` carries only a profile
  name. `gateway.CodexTransport.prepare_streaming` is an optional, separately
  injected bridge from that profile and an uncredentialed relative
  `/responses` request to a parked, monitorable `http.PreparedRequest`. With no
  bridge, subscription dispatch fails locally before network work. The public
  Responses provider still uses the API-key `http.Transport` and secret store.
- `provider/image_budget.{count, project, default_max_images}` bounds the total
  `UserImage` and `ToolResultImage` blocks in one request. Each actual gateway
  attempt uses its own endpoint/model limit (default eight), always starting
  from the original request so a larger fallback can retain more history.
  Oldest historical images become explicit text placeholders; text, message
  metadata and durable history are preserved. An active turn above the limit
  fails locally with terminal `StreamError("image_limit", ...)` before secret
  lookup or HTTP. `gateway.with_protected_images` makes a request-scoped copy
  carrying the caller's active-run image count for held prompt batches. The
  inferred current turn is also protected, and counts are capped to pixels
  actually present after context projection. These settings live on the opaque
  gateway; the frozen `ResolvedModel` and `ProviderRequest` shapes are unchanged.
- `provider/pricing.{Pricing, price, free}` — the costing layer. `Pricing`
  is one model's rate card in US dollars per million tokens, the unit
  providers publish; `price` is the pure function turning a `Usage` into a
  costed one. The four rates match `core/message.Usage`'s four disjoint
  token buckets, so cost is a weighted sum with nothing double-charged.
  Cards reach the gateway from `client/catalog`'s
  `[models.<name>.pricing]` tables, keyed by provider name; `card_for`
  reads one back out of the opaque registry.
- `provider/model.{Role, ResolvedModel, ProviderRequest, RequestTarget,
  ToolSpec}` — the durable identity (`{provider, model_id}`) plus the
  static model facts an adapter needs: context window, output ceiling,
  thinking level. `RequestTarget` is `ForRole(role, thinking)` (resolve
  at dispatch and walk) or `ForResolved` (dispatch to exactly this
  identity). `ForRole.thinking` is the caller's reasoning-budget
  overlay (`protocol-change/009`): `None` leaves each walked entry's own
  declared level in force, `Some(level)` applies that level to **every**
  target the walk attempts. Responses encodes xhigh and max verbatim; the
  other adapters map both to their existing high setting.
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
  The harness layers its own on top: `client/secrets.store` lays the
  `[secrets]` table's boot-resolved values over `env()` through
  `from_function`, so a name obtained from a host command and a name the
  operator exported are indistinguishable here — by design, since this
  package must not learn where a value came from.
- `provider/retry.{RetryClass, RetryPolicy}` — `classify`, `backoff_ms`,
  `is_overflow_message`, `overflow_message`. Permanent labels are checked
  before status and prose heuristics. An ordinary HTTP 429 bypasses overflow
  text matching because throttle prose can mention tokens; other statuses
  retain the overflow check. Streamed throttling prose is retryable only
  after excluding known permanent labels. Generic Responses failures use
  `RetryableWithin`; named transient failures keep the configured policy.
- `provider/internal/error_code` shares the fixed permanent-code vocabulary
  between Responses normalization and retry policy, so safe diagnostic labels
  cannot accidentally override an identified denial.
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
  data record beside it. The gateway, request and dispatch timestamp belong
  only to the `Parked` phase. Beginning transfers them to the private pump;
  the active guard keeps control and accounting without a second request
  inventory. All three of its deadlines are **state timeouts**:
  the pump's ready handshake on `Starting`, the fixed cancellation grace on
  `Cancelling`, and the same grace again on `Reaping` when the pump died
  without authoring a terminal. Each therefore dies with the state that
  armed it, so no handler re-establishes its own relevance and the
  stale-fire arms the hand-rolled loop needed are gone. The machine is
  started unlinked (weft's `unlinked` builder setting): a crashing guard
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
  - OpenAI Responses SSE — named item/part lifecycle events, indexed text
    and argument deltas, then a terminal response object. Completion
    records must agree with the deltas and final output. Requests post to
    `/responses` with flat function definitions, each carrying
    `strict: false` (the server defaults to strict, which would make every
    property required), `store: false`, and caller-owned input history. API-key authentication uses the existing
    HTTP transport owner. The subscription variant uses the same semantic
    fold and replay projection, but sends a relative, uncredentialed request
    through `CodexTransport`. Its body omits the public output ceiling and
    public-only tool controls. It groups functions in the `loom` namespace
    and admits `response.completed` as its terminal event when accumulated
    content passes the same witness checks; legacy `response.done` is rejected.
    Only this variant sends `namespace` on replayed function calls; the
    API-key request removes it from history recorded by either route.
  - Anthropic requests carry four `cache_control` breakpoints — one-hour
    on the last tool definition and on the system block, five-minute on
    the last block of each of the final two user turns. The system prompt
    therefore goes out as a one-element block array, not a bare string.
  - Gemini generateContent SSE — unnamed events whose `data:` is a whole
    `GenerateContentResponse`, with no terminator sentinel; parts arrive
    complete (`text`, `text` with `thought: true`, `functionCall` with
    parsed `args`), and any part may carry a `thoughtSignature` that must
    be replayed with its block. Requests carry `systemInstruction`,
    `functionDeclarations` with `parametersJsonSchema`, and a
    `thinkingConfig` whose knob follows the model generation
    (`thinkingLevel` for Gemini 3, `thinkingBudget` for 2.5). The key
    travels in `x-goog-api-key`.
  - `api_name` constants pin the five dialect identities: `"anthropic-messages"`,
    `"openai-completions"`, `"gemini-generate-content"`,
    `"openai-responses"`, `"codex-subscription"`.

## Invariants

- **Ownership documentation states the proof carried by each PID.** Public
  stream, custodian, and transport APIs document why the owner exists, how
  cancellation reaches it, and what its Down acknowledges. A comment that
  only says a function "starts a process" is incomplete here: callers need to
  know whether that process does work or survives work as its drain witness.
  Only normal exit proves drain; abnormal exit means the witness was lost.
- **Adapters never price a response, and the gateway always does.** Every
  adapter writes `UsageCost(0.0, ...)`, because an adapter knows the wire
  dialect and not the commercial arrangement behind the endpoint — the same
  dialect is spoken by a first-party host, a reseller and a local proxy at
  three different prices. `gateway.attempt_one` prices each returned attempt's
  report before fallback aggregation, including failed attempts. Settlement
  also prices the final message's own usage. Missing rates leave numeric
  zeros with unavailable estimate evidence; an explicit zero card is priced.
  The terminal report covers the request, while the message usage covers its
  final attempt. Subscription prices remain labelled API reference estimates.
- **Local refusals prove no inference dispatch.** Only the trusted local
  admission path emits `http.RequestRefused`. The stream decodes its redacted
  error and waits for the original owner to drain before publishing an empty
  report. A remote error or missing usage retains unknown consumption.
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
  crash. Gemini has no tool-use finish reason — a calling turn ends with
  `STOP` — so its settlement promotes `STOP` to `ToolUse` when the
  response carried a function call. A prompt the API refuses outright
  arrives with no candidates and a `promptFeedback.blockReason`; that
  settles as an errored turn (raw stop `BLOCKED_<reason>`), never as the
  retryable disconnect a candidate-less close would otherwise read as.
- **Gemini thought signatures are replayed or substituted, never dropped.**
  The signature stays on the block it arrived with (`text_signature`,
  `thought_signature`), an empty signed text part signs the block in
  progress, and a replayed function call with no signature carries the
  `skip_thought_signature_validator` sentinel, because the API refuses an
  unsigned call outright. An unsigned thought summary is not replayed; a
  signed one goes back as a `thought` part with its signature.
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
- **Wire leniency does not authorize content loss.** SSE `data:` payloads must
  parse as JSON (malformed data fails the stream in-band as
  `MalformedStream`), but *fields* are read leniently — absent usage
  counters read as zero, and unknown fields are ignored. The older adapters
  retain their existing unknown-event conventions. Responses rejects
  unknown content-bearing events and item kinds while explicitly accepting
  known lifecycle markers; otherwise a new output variant could disappear
  from a successful settled message. Replayed metadata passes through the
  same allowlisted item decoder rather than becoming arbitrary request JSON.
- **A tool call the model got wrong is not a malformed stream** (issue
  #189). The Anthropic, OpenAI Chat Completions, and Responses dialects
  accumulate a call's arguments as
  text and parse it at settlement; a parse failure there used to fail the
  whole stream as `MalformedStream`, which `retry.classify` marks terminal,
  killing a turn whose other blocks were fine. `wire.tool_arguments` now
  settles that one call carrying `core/message.malformed_arguments` — the
  raw text and the parser's complaint — and `machine/planner` turns it into
  an in-band `is_error` result the model can correct. `MalformedStream`
  keeps its narrower meaning: bytes the *provider* produced that were not
  the protocol. Gemini needs none of this; its `args` arrive already parsed
  inside the response document.
- **Responses failures identify the rejected check without remote content.**
  `adapter/responses.malformed` attaches a fixed local reason code, an
  allowlisted event name, bounded numeric positions, last accepted sequence
  and cumulative bytes to the existing corruption report. Unknown names and
  malformed or oversized numeric fields become fixed markers. The subject
  fits the gateway's 128-byte label bound and context fits core's 256-character
  bound. Runtime retains the report in the durable assistant error message;
  the error vocabulary, retry policy and validation predicates are unchanged.
  `README.md` documents the reason families and their stability convention.
- **Responses has one local conversation owner.** The request carries
  reconstructed history, never `conversation` or `previous_response_id`.
  Encrypted reasoning is opaque replay data, not an authentication token.
  The subscription variant keeps the same Loom-owned history and semantic
  fold. Its credential owner and fixed host sit behind the injected transport,
  so neither a token nor an account-routing header enters this package. The
  private backend remains experimental under ADR-012's support gate.
- **Subscription terminal output may be empty after item closure.** Live plan
  streams close their output items before a terminal envelope with `output: []`.
  Only the subscription dialect may use those canonical closing witnesses in
  place of that empty array. Every item and part must have closed, indices must
  be contiguous, response identity and terminal status must agree, and a populated
  terminal array must still match exactly. The initial item status may already
  be `completed`; that metadata never substitutes for streamed closure.
- **Responses replay is bounded metadata plus durable content.** The
  namespaced hint retains item IDs, statuses, message phases, part boundaries, annotations,
  and the permutation between provider order and delta block order. It does
  not duplicate answer text. A hint larger than 64 KiB fails settlement;
  missing or invalid stored metadata cannot authorize a reasoning item
  without its required ID. Ordinary text and calls have a metadata-free
  projection. A foreign dialect's signature is never interpreted as
  Responses encrypted content.
- **A reasoning item's ciphertext is stored once.** Its first canonical
  thinking block carries the signature; later summary or reasoning-text
  blocks carry `None`. Replay reconstructs the one provider item. Copying a
  large signature onto every short summary part would multiply durable
  encoding size despite the transport's byte budget.
- **Usage counters are clamped, not trusted.** `wire.count_field_or` /
  `optional_count_field` clamp into `[0, max_usage_count]` (1e12) at the
  read, so no count an untrusted proxy reports can reach a settled message
  the durable planes cannot encode (`core/msgpack` rejects integers outside
  `[-2^63, 2^64-1]`). Saturation is itself the record of the lie. Counters
  steer accounting and overflow classification only — never a security
  decision — so a lying proxy can at worst waste a compact-and-retry cycle.
- **Usage costs are zeroed**; token extraction only. Pricing tables are a
  ledger-side concern, not an adapter's.
- **Human attribution is projected here and nowhere else.** All four
  adapters encode a `UserMessage` through `core/origin.project`
  (`adapter/anthropic.gleam:255`, `adapter/openai.gleam:213`,
  `adapter/gemini.gleam:331`), which prepends one JSON-quoted author label
  to the *transient* content list it builds for the wire. The stored blocks
  are unchanged, so a message keeps one durable form no matter how many
  dialects render it, and the label reaches the model as data inside the
  user turn rather than as a role or a system instruction
  (`protocol-change/016`). One pure helper serves all four dialects
  because the label's wording is part of the durable contract, not an
  adapter's taste.
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

- [docs/architecture/codex-subscription.md](../../docs/architecture/codex-subscription.md)
  — the experimental helper transport, account-bound credentials, and
  remaining interoperability and support gates.
- [docs/adr/012-responses-and-subscription-boundaries.md](../../docs/adr/012-responses-and-subscription-boundaries.md)
  — public API inference, the deferred subscription support gate, and the
  distinction between model argument mistakes and provider corruption.
- [docs/architecture/effects.md](../../docs/architecture/effects.md) —
  "Providers", and the plane this package sits in.
- [docs/spec-gaps.md](../../docs/spec-gaps.md) — "From WP-F (`provider`)":
  the settled-message home, fallback semantics, the quantified "negligible
  output", wire leniency, deferred keychain backends.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.

## Retained consumption (protocol 081)

`stream.Settled(message, accounting)` and `stream.Failed(error, accounting)`
carry a request report independently of final-response context usage. Each
adapter's `ResponseMachine.usage` reads its latest snapshot; the snapshot
is replaced on new wire evidence rather than added repeatedly. A terminal
can therefore retain usage when semantic validation, a remote failure, or
a disconnect prevents a successful response. Missing cache partitions keep
partial evidence, so a numeric prompt total cannot certify its allocation.

The gateway prices each attempt under its actual target before folding a
fallback report. Its surviving guard receives the completed prefix before
the next attempt begins; owner loss adds an unknown observation to the
retained prefix. Local refusals before dispatch return an empty report.
An absent rate card leaves pricing unavailable, and a subscription card
provides an API reference estimate, never measured ChatGPT credit usage.
The settled assistant retains only final-attempt usage.

## Selected response identity ownership

The OpenAI-compatible SSE adapter keeps `id` and `model` after dropping each
JSON event document. `retained_identity` materializes single selected values of
65–256 bytes when the event is at least eight times larger, preventing a small
identity from retaining a large ignored event payload on OTP 29. Fields up to
64 bytes already materialize on that runtime. Larger identities keep sharing;
values, missing-field fallback and settlement timing are unchanged. The pure
standard-library copy adds no FFI or dependency. Generic JSON decoding keeps its
existing ownership to avoid copying every field in documents retained whole.
`scripts/json_retention_perf.sh` exercises the actual response machine alongside
selected-field, whole-document and source-owned controls in disposable workers.


## Frozen side-query cache endpoints (protocol 087)

`gateway.with_cache_prefix` adds a request-scoped message-count hint without
changing frozen ProviderRequest or ResolvedModel fields. Anthropic's
`build_request_with_prefix` spends its two tail breakpoints on the frozen base's
last user block and the side suffix's newest user block. It marks each region
before merging adjacent user turns, preserving a cached endpoint when a side
question is asked during a parent response. Tools and system retain the two
existing one-hour markers; the total remains four. Ordinary requests retain
their rolling two-user policy. OpenAI-compatible and Responses encoders retain
their ordinary message boundaries and settings.

`resolve_identity` reads actual fallback model settings from the immutable role
registry. A side request pins that identity rather than walking the fallback
chain. Tool definitions remain prefix material; the side service has no executor.
The adapter fixture verifies frozen endpoint placement, four-marker accounting,
and identical tool definitions. It does not establish a live cache hit.
