# Spec gaps and recorded interpretations

Running log of places where implementation forced an interpretation of the
spec or revealed a gap. Each entry says what was decided and where. Items
that would change a frozen Part 1 interface go through `protocol-change/`
instead and are only referenced here.

## Triage — where each item stands

Every item in this log is one of three things: a **settled
interpretation** (a decision recorded, nothing outstanding), **deferred
work with a home** (real work a milestone or a Part 5 follow-up track
already owns), or **deferred work with no home** (real work scheduled
nowhere). The two tables below name the second and third classes. The
rule for reading them: *an item named in neither table is settled* —
which is 110 of the 135 items. A recorded option nobody must exercise (a
"candidate for hoisting if the duplication grates") stays settled; only
work someone must do to meet a stated criterion is listed here.

Items are cited as section plus the number as written in the list
(`WP-J 14`, `M3 runtime wave 11`).

### Deferred work with a home (7)

| Item | The work | Scheduled at |
|---|---|---|
| WP-A 3 | somewhere to put pi's optional `details` payloads | Part 5 track 6 |
| WP-B/T 6 | the JSONL/format-4 import shim | Part 5 track 6 |
| M2 integration 3 | a provider surface for deferred polls | M5 — the structural-summaries half shipped in Stage C0 (`client/wiring.summary_provider_request`); polls remain unwired |
| M3 messaging 2 | cross-node broadcast fan-out | Part 5 track 4 |
| WP-J 5 | whether a `cap/strand` should exist — answered by `design-notes/orchestration-comparison.md`: yes, on a second seam carrying `cap/strand` + `cap/report` and nothing else | M4.5 / WP-N |
| M2 memory 8 | indexing `memory/*` rows so memory is reachable through `history_search`, with the by-type exclusion that would make it safe | memory stage M3, with the tokenizer upgrade |
| M2 memory 9 | the first-order erasure cascade over provenance: erase X → find the distillates naming X's entries → re-consolidate without them | issue #115 |

### Deferred work with no home (14)

Fourteen items, thirteen rows: the canonical session id is recorded
twice. Nothing in the right-hand column is scheduled — it is where the
work would sit if someone scheduled it, recorded so the choice is made
rather than drifted into. Part 5.1 of the spec says the same thing from
the other side.

| Item | The work | Proposed home |
|---|---|---|
| WP-J 15 | let an approved escalation widen a code-mode execution; every clearance the pipeline makes passes no grants, so approving one changes nothing | M4.5 / WP-N (issue #24), on the seam WP-L 1 now provides |
| WP-J 16 | one threaded `ExecIdentity`, so one-ledger-per-execution is a property of the types rather than a convention the caller must honor | M4.5 / WP-N |
| WP-E 8 | the chaos tier of WP-E's own exit criteria — random kills under load, ten-minute soak. `make soak` is the deterministic-simulation seed soak, not a chaos runner | WP-T, and M1 recorded partial until it runs |
| WP-G 9 | the MCP adapter — in WP-G's scope, deferred post-M2, integrated by no row since | a Part 5 track |
| WP-F 7 | the per-OS keychain backends WP-F's scope names; only the environment backend ships | a Part 5 track |
| WP-F 6 | pricing tables somewhere ledger-side, since the adapters zero every cost field and §3.4 calls the ledger the billing source of truth | the token-budget work `design-notes/orchestration-comparison.md` sequences after WP-N |
| WP-L 8 | per-identity model facts in the wiring seam, so a strand switched off its role's resolution stops doing overflow arithmetic against fallback numbers | M5 |
| M3 runtime wave 13 | decide a catalogue entry's `thinking`: the default a strand overrides, or refused like `headers` — today it is validated and discarded | M5 |
| WP-L 2 | `api.compact` and `api.navigate`, so the gateway and the conformance runner stop keeping two copies of acceptance-plan building | no milestone |
| WP-L 3 | an optional-brief `create_strand`, so protocol fork and create-strand stop seeding registers in the gateway | no milestone |
| §3.4 6 | an OpenTelemetry exporter behind the `log.Sink` seam; §3.4 marks the export optional and nothing about the path is built or tested | a Part 5 track, alongside WP-F 7 |
| §3.4 8 | the rest of "context everywhere": `broker`, `provider`, `tools`, `codemode`, `cap` and `session` still log nothing | whichever milestone next touches those packages, one injected `Logger` at a time |

## From WP-A (`core`)

1. **Id minting signature.** Part 1.1's comment reads `mint(Clock)`, but
   purity requires entropy injection too. Implemented as an opaque
   `Generator` threading a `Clock` and a seeded SplitMix64 state through
   every mint. This *is* §0.2's "injected UUIDv7 generator"; the literal
   signature in the contract comment is looser than the implementation.
2. **`BranchSummaryEntry.from_id` nullability.** pi allows `fromId: null`
   (summary sourced at the root); the original contract said
   `from_id: EntryId`. Raised as `protocol-change/001`, since ACCEPTED
   and implemented: the field is `Option(EntryId)` on the wire while
   acceptance still rejects summarize-from-root, so `Some` remains the
   only value the harness writes.
3. **`details` payloads.** pi §2.1 carries optional `details` on compaction
   and branch-summary entries; Part 1.1 omits it. Followed Part 1.1. The
   format-4 import will need somewhere to put these — revisit with
   follow-up track 6.
4. **`UsageRow`.** Referenced by `InsertUsage(UsageRow)` in Part 1.1 but
   never defined there. Transcribed from pi §1.1 into `core/entry`.
5. **Custom messages.** pi's open `CustomAgentMessages` interface became
   `CustomMessage(schema, payload)`; unknown roles are decode corruption.
   The import shim maps pi's application roles into this form.
6. **`RegisterValue` representation.** Part 1.1 says the namespace forces
   the value type, but those types (StrandConfiguration, OperationState,
   …) belong to WP-D. Core carries payloads as tagged JSON; machine owns
   the rich codecs. Documented in `core/register`'s module doc.
7. **Decoder coverage criterion.** WP-A's "≥95% branch coverage on
   decoders" was never machine-verified — no Gleam coverage tooling
   exists to measure a branch percentage. Restated in the spec's own
   exit criteria as what the suite already does and a reviewer can
   check: a roundtrip case per constructor of every decoded type, and an
   adversarial corpus at each codec boundary (msgpack bytes, JSON
   values, the entry/message codecs) whose every input decodes to a
   `CorruptionReport`.
8. **Numeric edges.** JSON floats beyond IEEE 754 double range decode as
   corruption (the BEAM has no Inf/NaN); JSON ints are arbitrary
   precision; msgpack ints outside `[-2^63, 2^64-1]` are encode errors.

## From WP-H (`sandbox`)

1. **Policy source.** Part 1.4 lists `policy` inside `exec_start` while
   WP-H says "parse SandboxPolicyV1 from fd 3". Resolution: fd 3 is
   required and is the default policy; a policy in `exec_start` overrides
   per-exec; the restrict-and-exec inner stage always reads fd 3
   literally.
2. **`exec_start.limits`.** The spec lists `limits` beside `policy`
   although the policy already contains limits. The helper accepts and
   ignores the outer field (policy governs); reserved for per-exec
   overrides.
3. **`output_bytes`** is enforced per stream (stdout and stderr each get
   the cap); after truncation the helper drains and discards so the child
   never blocks on a full pipe.
4. **Hello ordering.** The spec does not say who speaks first. The helper
   sends its hello first so the broker learns features before committing
   work, and requires the broker's hello before any other frame.
5. **One execution at a time** per helper; a second `exec_start` gets a
   `busy` error. Concurrency lives in the broker's ExecPool, which keeps
   "kill the pgroup" unambiguous.
6. **Network-off filtering** blocks inet/netlink/packet `socket` creation
   by domain (seccomp cannot inspect sockaddr); AF_UNIX stays usable and
   is confined by the filesystem layers; bwrap's network unshare is the
   independent second layer.
7. **Degraded mode.** When bwrap/Landlock/cgroup are unavailable (as in
   the development container) the helper enforces what it can, reports
   the truth in `hello.features` and per-exec `enforcement`, and the
   broker is expected to refuse degraded helpers by policy where the
   policy demands full enforcement. Protected paths inside writable roots
   are unenforceable without bwrap — reported, not hidden.
8. **Unknown input policy.** Unknown policy/body keys are rejected
   (fail-closed); unknown frame kinds get an in-band error without
   closing (forward compatibility); malformed frames close the channel
   per §3.3 invariant 6.

## From WP-G (`broker`)

1. **fd-3 delivery through ports.** Erlang ports cannot map arbitrary
   file descriptors, but the helper requires its base policy on fd 3.
   Resolution: the broker writes the policy to a mode-0600 file inside
   a mode-0700 directory and spawns the helper via
   `/bin/sh -c 'exec 3<"$2" "$1"' loom-exec <helper> <policy-file>`;
   the file is unlinked the moment the helper's hello proves it was
   read. Per-exec `exec_start.policy` remains the authoritative policy
   for each execution. (`broker/exec` module doc.)
2. **Port ownership.** Port messages are delivered to the opening
   process, so the helper port is opened inside the helper actor's
   initialiser; the public `Transport` is a spawn spec, not an open
   port.
3. **`step_id` type.** Part 1.4 says tokens are valid for one
   `{op_id, step_id}` but never defines a step-id type; `op_id` is
   `core/ids.OpId`, `step_id` is a caller-chosen `String` until WP-D's
   step identity lands.
4. **`cap_result` shape.** Part 1.4 writes `{ok|err, value|error,
   usage?}`; transcribed as `{ok: bool, value (when ok) | error:
   {code, msg} (when err), usage?}`. The helper never sends it; WP-J's
   satellite implements against this reading.
5. **Nil-vs-empty arrays.** The Go helper's msgpack encoder writes nil
   slices as msgpack `nil`; broker decoders accept `nil` for arrays,
   binaries, and maps as empty, while always emitting real values.
6. **Degraded refusal semantics.** "Policy demands full enforcement" is
   broker-side data (`EnforcementDemand`), not a SandboxPolicyV1 field
   (frozen shape). `FullEnforcement` refuses degraded helpers at
   dispatch (hello features) and additionally fails executions whose
   `exec_exit` reports `degraded` — the ground-truth check.
7. **Escalation grant bounds.** Approving an escalation only accepts
   grants drawn from the denial's wanted diff (subset allowed); wider
   grants are a separate explicit policy decision, and session-policy
   widening is the caller applying approved grants to the session base
   explicitly (design §5.3's "never silently").
8. **Root composition is prefix-aware, exact-string sets otherwise.**
   Requirement roots are granted when covered by a base root
   (`/work` covers `/work/sub`); env/allowlist composition is exact
   string intersection; proxy-vs-proxy network meets intersect
   allowlists and always keep the base's (harness-owned) proxy address.
9. **MCP adapter deferred.** WP-G's MCP adapter (spawn-in-sandbox,
   schema validation, provenance tagging) is post-M2 work layered on
   the same `clear_call` path; noted in `broker/broker`'s module doc.

## From WP-F (`provider`)

1. **`SettledAssistantMessage` home.** The frozen contract uses the type
   in both §1.3 (machine) and §1.5 (provider), but core does not define
   it. Provider defines it (opaque, non-pending wrapper over core's
   assistant message). The machine package, which cannot depend on
   provider, needs its own settled shape; the runtime bridges them.
   Candidate for hoisting into core via a protocol-change if the
   duplication grates.
2. **Fallback semantics.** The chain walks only on retryably-classified
   failures; terminal errors surface immediately; an exhausted chain
   emits the last real error, preserving retryability; re-dispatch with a
   resolved identity never falls back (recovery semantics).
3. **"Negligible output"** in the adapter overflow rule is quantified as
   ≤ 64 tokens (documented constant) — the spec leaves it open.
4. **Overflow message matching** uses substring heuristics with
   throttling exclusions; Gleam has no stdlib regex, so pi's regex
   vocabulary is distilled rather than transcribed.
5. **Wire leniency.** Provider frames must parse as JSON (else in-band
   corruption failure) but fields are read leniently — absent counters
   default, unknown enums are ignored — matching pi's adapters, since
   strict total decoding of third-party wire breaks real proxies. The
   total-decoder doctrine applies to *our* durability boundaries, not to
   foreign wire vocabularies.
6. **Costing.** Usage cost fields are zeroed; token extraction only.
   Pricing tables belong to a ledger-side concern, not the adapters.
7. **Keychain backends** are deferred behind the secret-store seam; the
   environment backend ships now, per-OS keychain FFI later.
8. **Overflow counts cache writes too.** §1.5 words the adapter's overflow
   comparison as `input + cache_read > context_window`, written before
   either adapter declared a prompt-cache breakpoint and so before either
   could report a cache *write*. Both adapters compare
   `input + cache_read + cache_write`, which is the quantity the spec
   names — the whole prompt — and collapses to the spec's two terms when
   nothing is cached. Without the third term, caching would shrink the
   apparent request by exactly the tokens it just wrote, and an oversized
   request would retry unchanged instead of compacting.
9. **Cache breakpoint placement is adapter-local and unconfigurable.** The
   Anthropic adapter spends all four of the API's breakpoints on every
   request — one-hour on the last tool definition and on the system block,
   five-minute on the last block of each of the final two user turns —
   derived purely from the request's contents, so no caching knob reaches
   `ProviderRequest` and no package above the adapter seam learns the
   dialect's cache vocabulary. The system prompt is consequently rendered
   as a one-element block array rather than a bare string; `system` stays
   `Option(String)`, so no frozen interface moves. The OpenAI dialect
   declares nothing, its caching being automatic and prefix-matched
   server-side.

## From WP-I (`tools`)

1. **Anchor hash.** Shipped a 64-bit FNV-1a truncated to 8 hex chars,
   versioned and package-internal, reading the spec's "xxh3" as intent
   (fast 64-bit) rather than a wire contract: anchors never outlive one
   read-edit round trip. This also answers the Part-7 open question — 8
   hex, no line-number salt; line numbers travel beside anchors in refs.
   Collision-sensitive blob addressing uses SHA-256 through the package's
   single FFI.
2. **`execution_mode`** is undefined by the spec; interpreted as a
   scheduling constraint (`Exclusive` for bash/write/edit, `Concurrent`
   for read/grep), mirroring pi's batch modes per tool.
3. **Requirements are workspace-relative** — a function from workspace
   root to policy, since roots are unknowable statically. Bash requests a
   readable root of `/` (interpreters live outside the workspace); the
   session base decides whether to grant it.
4. **`fs_read` is exempt from the §3.2 blob overflow** — windowed reads
   are its bounding mechanism, and anchors inside an elided blob would
   defeat hashline editing. Bash and grep output do overflow to the
   content-addressed store.
5. **Filesystem tools run harness-side**, not through the broker; their
   lexical path discipline is defense in depth under Rule Zero, and their
   declared requirements exist for uniform policy audit.
6. **Blob refs "readable via fs_read"** requires the runtime to place the
   blob root under a readable workspace path; tools only record the ref.
7. **Timeout ceiling** is clamped tool-side (600 s max, 120 s default),
   and the wiring has since decided it: the clamp *is* the ceiling, now
   §3.5. Session policy narrows and cannot widen past it —
   `client/serve.base_policy` gives the session a `wall_s` of 600 and
   `broker/policy.compose` meets the limits, while the tool derives its
   own `wall_s` requirement from the already-clamped timeout. An
   approved `wall_s` grant joins upward inside the jail, but the tool's
   budget deadline and receive window were fixed at the clamped value,
   so no grant lengthens a call. `grep` takes no timeout argument at
   all: a fixed 60 s.
8. **Ripgrep-missing detection** keys on the helper's spawn-failed error
   plus exit 127; the framing spec does not enumerate helper error codes.

## From WP-B/T (`storage`, `conformance`)

1. **Two indexes beyond the spec's schema block**, both from the pi
   source it abridges: `ix_be_entry ON branch_entries(entry_id)` (without
   it, covering-segment resolution is a table scan) and
   `ix_usage_seq ON usage_ledger(seq)` (without it, ledger scans
   temp-sort). Treat the spec's "the exact indexes" as a floor, not a
   ceiling; the query-plan assertions are the real contract.
2. **Both backends are actors** — one writer, one mailbox — designed for
   a single owning StorageWriter; reads use a distinct `StorageError`
   while commits keep the frozen `CommitError`.
3. **Close is idempotent** (pi §1.5): a sealed handle answers
   handle-closed on reads and faulted on commits rather than crashing.
4. **CAS-only commits are legal** (empty writes with expectations);
   register deletes consume a sequence number like any write; failed
   commits consume nothing.
5. **Parent-must-exist** is enforced at commit; in-transaction parents
   work because writes apply in order.
6. **The JSONL/format-4 import shim** named in WP-B's scope is deferred
   to follow-up track 6; nothing before M7 depends on it.

## From WP-D (`machine`)

1. **`Fault` action variant.** A pure total planner cannot crash, so
   corrupt inputs surface as a sixth Action variant carrying a corruption
   report. Extends frozen §1.3 — raised as `protocol-change/002`, which
   also records that `Transition`/`Finish` carry a full `Tx` rather than
   bare expectations.
2. **No list store.** pi persists streamed assistant frames, tool output
   checkpoints, and tool memos in list stores; Loom's frozen Tx has no
   list writes, so those are unrepresentable durably. Streamed partials
   and checkpoints instead reach recovery as observations
   (`ObservedAssistantOrphaned`, `ObservedToolOrphaned`). If frame-level
   persistence is ever wanted, it needs a runtime-side mechanism or a
   protocol change.
3. **Adapter retryability convention.** No field on the settled message
   carries the adapter's retryable judgment; the planner derives it from
   `raw_stop_reason == "retryable"` and `ClassifyCtx.error_retryable`
   carries it. The runtime must bridge provider's `retry.classify` into
   this convention — reconcile when wiring WP-E.
4. **Prefix scans.** Terminal cleanup deletes tool-args and preparation
   registers from caller-supplied key lists, since the pure machine
   cannot scan; delete-absent being a no-op keeps this as over-approximate
   as pi's defensive scan.
5. **Entry labels** are written to `fact.label` keyed by entry id; Loom
   has no dedicated entry-label namespace.
6. **Faithful-but-surprising transcriptions**, kept deliberately: a
   completed tool batch sets skip-inbox-once (steer waits one turn, per
   pi §3.12's sentence); the threshold check also runs at may-finish
   checkpoints; backoff is base times two to the attempt, saturating at
   exponent twenty; overflow during a deferred poll drains as failure
   (pi's poll table has no compaction path); summary usage rows carry no
   entry id because they commit before the result entry exists.
7. **A failed threshold compaction does not drain the run** (issue #34).
   pi's structural-failure row is uniform: any in-run summary that fails
   past its retry ladder ends the run. Loom reads the `CompactionReason`
   there, the same way the decline row already did. A *threshold*
   compaction is the harness's own clamp, so failing to apply it against
   an unavailable summarizer restores the resume checkpoint and the run
   carries on; an *overflow* compaction still drains, because the
   provider has already refused the context. Two things bound the
   divergence. An error whose subject is the context rather than the
   summarizer (`context_overflow`) drains from either path, and
   abandoning a threshold compaction clears `enabled` in the run's
   captured `CompactionSettings`, so the threshold cannot re-fire into
   the same dead route on every later boundary of that run. Settings are
   captured per operation, so the next run asks the summarizer again.
   `docs/architecture/compaction.md` carries the reasoning.

## From WP-E (`runtime`, `session`)

1. **Crash semantics of the harness.** The interleave scheduler's kill
   point is "commit durable, committer unobserved" (kill before the
   writer's reply); an effect whose intent commit is the boundary never
   started, so mid-flight interruption is exercised by dedicated
   kill-the-tree tests (the crash-mid-tool reproduction and abort).
2. **Boot seeding bypasses the writer** — strand seeding commits through
   the session handle before the tree exists, CAS-guarded; every
   post-boot commit flows through the writer.
3. **Close is an orderly shutdown** (was: a controlled crash; closed by
   issue #8). `gleam/otp/static_supervisor` wraps no graceful external
   stop, so `api.close` reaches OTP's own — `sys:terminate/3`, the one
   external stop a `supervisor` offers — through the runtime's single
   FFI. Children terminate in reverse start order with reason
   `shutdown`, so every strand driver is gone before the writer it
   commits through, and a close that was asked for is no longer
   indistinguishable from a fault. A tree that will not stop inside the
   grace is still killed: a session locked out for a whole lease TTL is
   the worse failure. `client/serve` roots the whole stack on an
   exit-trapping host process (`client/host`) rather than an OTP
   application — the boot threads values, not names, through steps that
   a static supervisor's pre-built child list cannot express — and its
   restartable pieces sit under a supervisor of their own.
4. **Abort is strand-routed** so its marker commit serializes with the
   strand's own transitions; a pre-commit crash loses the request exactly
   as pi's no-live-task case does — callers re-request.
5. **Effect-worker death settles in-band** (transport failure or
   synthetic tool error) rather than faulting the strand, extending the
   in-band failure doctrine to the runtime's own workers.
6. **Entropy is injected, not FFI'd** — production wiring must supply an
   entropy source whose seeds never repeat within a session lifetime, or
   re-minted ids could collide with committed ones.
7. **Compaction and branch summaries project as user messages** in the
   minimal projection; the provider mapping is left open by pi §2.5, and
   custom projectors are third-milestone work.
8. **The chaos soak** (random kills under load for ten minutes) is
   deferred to the conformance chaos runner; the deterministic interleave
   harness covers the enumerable core.
9. **Writer events are minimal** (committed ordinal, seqs, timestamp);
   typed per-write events belong to the event bus work package.

## From the M2 integration (`conformance/wiring`)

1. **Shared clock requirement (found live).** Budget deadlines are
   computed on the tool-side clock and checked against the broker-side
   clock; nothing required the injected clocks to share an era, and
   misaligned eras made the broker refuse every call as past deadline.
   §0.2 now carries the rule as a convention — one clock, or at minimum
   one era, across runtime, tools, and broker — and `client/serve.boot`
   builds a single clock function for session, broker, tools, and
   provider.
2. **`stream_options` gets no wire mapping.** The runtime threads an
   opaque options bag from `runtime/api.Options` through the durable
   generation intent to `client/wiring`, which drops it because
   `ProviderRequest` has no field for it. Decided against mapping, and
   §1.5 now says why: the request vocabulary is closed, and
   dialect-specific per-request options belong to the adapter, which
   derives them from the request's own contents. The OpenAI adapter
   already writes the wire's own `stream_options.include_usage` itself,
   so a bag threaded from above would collide with the field the adapter
   owns; the Anthropic adapter places its cache breakpoints on the same
   terms (WP-F item 9). Dropping the bag is conformance, not loss.
   Nothing writes it either: production seeds `json.Object([])` and the
   admission hook passes it through untouched, so the field is inert and
   its removal is cleanup nobody must do. Carrying it would need a
   protocol-change against §1.5; not carrying it needs none.
3. **No provider surface for deferred polls or structural summaries.**
   The provider request type cannot express a continuation fetch; wiring
   settles both in-band as transport failures, unreachable under default
   hooks. Third and fifth milestones must extend WP-F.
4. **Model facts vs durable identity.** The machine's model identity
   lacks the context window and output ceiling the resolved model
   carries; the adapter re-derives them by role resolution with config
   fallbacks. Candidate for hoisting facts into the durable identity,
   paired with the settled-message hoist from the WP-F section.
5. **Thinking scale collapse.** The machine's seven levels map onto the
   provider's four; the mapping is documented in the wiring module.
6. **Clearance semantics.** Unspecified by the spec; interpreted as a
   registry gate (unknown or inactive tool refuses in-band), with policy
   composition deferred to the broker inside the tool's own call, and
   arguments passed through unrewritten until a rewrite hook exists.
7. **The wiring adapter lives in conformance source** — *resolved*: a
   host package now exists, and the adapter was promoted to
   `client/wiring` when `client/serve` (the server entry point) became
   its production consumer. Conformance depends on `client` (legal — T
   depends on all) and its wiring/e2e suites prove the promoted module
   in place.
8. **The system prompt has no home in the frozen contracts**; wiring
   treats it as session-level configuration.
9. **Lease expiry runs on injected time** — a crashed process holds the
   lease until the TTL elapses in that clock's era; correct in
   production, surprising under deterministic test fixtures.

## From WP-K (`events`)

1. **The catch-up frontier rule**, load-bearing and now a §0.2
   convention: a projection catch-up that reads more than one scan must
   bound every scan by a frontier sequence read before the first one.
   Without it, a commit landing between two scans advances the
   high-water past rows the earlier scan never saw, losing them
   permanently. Sequences are strictly increasing and rows write-once,
   so the bounded window is immutable and the batch consistent.
2. **Checkpoints persist state, high-water, and rewrite generation
   together.** The spec says "persisted high-water seq"; for a stateful
   in-memory projection a high-water without its matching state is
   meaningless, and both are void after a rewrite renumbers seqs — so the
   checkpoint is a `#(state, high_water, generation)` triple, and a driver
   whose recorded generation no longer matches the store's restarts the
   fold from `initial` at seq zero. Search persists cursor-and-generation
   only, because its state is the database itself.
3. **Operation-transition events carry a display string**, not a machine
   type — keeping events off a machine dependency per the DAG; the
   register remains the truth.
4. **Session identity on the bus is a `bus.SessionKey`**
   (`protocol-change/008`): `key(of: SessionId)` for an identified
   session, `unidentified_key(name:)` for a publisher that has none, with
   disjoint `id:`/`name:` renderings so the two can never collide.
   `events/search` takes the `SessionId` outright and has no unidentified
   form. The gateway now subscribes under `key(of: api.session_id(runtime))`
   too (issue #28); the protocol's client-facing `session` field stays a
   display name. `client/serve` supplies no bus, so that subscription is
   correct-but-unexercised — it is for a host whose hint sources are not
   all its own writer.
5. **Search indexes** message text and compaction/branch summaries;
   thinking blocks and tool-call arguments are deliberately not indexed.
   pi's metadata-filtering question stays open, as in pi.
6. **Recall has no backfill, and that is stated rather than hidden**
   (issue #28, memory stage M1). A session's rows enter the index while it
   runs, and the holder syncs once at start — so reopening a session
   written before search was wired indexes its whole file, while a session
   that is never reopened stays unfindable. Nothing sweeps the
   repository's session files. The remedy, if it is ever wanted, is a
   startup sweep over the session catalog rather than a change to `sync`.
7. **An injected digest is indexed like any other message.** The `agent/`
   notes digest `client/notes` injects at run start is an ordinary user
   message, so search indexes it alongside everything else — a small
   feedback loop, bounded by the digest's own 4096-byte cap and by the
   fact that it quotes cells already durable elsewhere. The structural
   anti-feedback exclusion (and the question of whether `CustomEntry`
   should index to something) belongs to memory stage M2 and is
   deliberately not pulled forward.
8. **The digest also accumulates: one capped copy per run.** `run_start`
   messages are born-placed durable entries and the leaf moves onto
   them, so a strand with stable notes carries one near-identical digest
   per operation in its projection tail until compaction evicts them —
   and each copy is separately indexed (item 7's loop, multiplied by
   turn count). The per-injection bound is real; an in-context total
   bound is not, and saying otherwise anywhere is a doc bug. A
   skip-if-unchanged check is the obvious remedy if the cost shows up;
   it is deliberately not built until it does.
9. **`history_search`'s own results are re-indexed.** Tool results are
   durable entries and `entry_text` indexes their text, so every snippet
   a session recalls — fence markers and all — becomes indexed content
   in that session's file, and a later repository-wide search for the
   same term returns the original plus every session that ever quoted
   it. Unbounded by any cap, unlike item 8, and created by the tool
   itself. Ranking degradation is the cost today; the structural
   exclusion that would close it (skip tool-result blocks whose tool is
   `history_search`, or M2's by-type exclusion) is follow-up work,
   weighed there rather than bolted on here.

## From WP-C-full (`session`, `storage`)

1. **Branch-fork configuration source.** pi does not say which strand's
   configuration seeds a branch-scoped fork's main strand; the fork
   request names it explicitly, and an unconfigured source forks to an
   unconfigured main.
2. **Fork re-stamps placement.** The destination assigns fresh seqs and
   timestamps; ids and order are preserved. pi is silent on placement in
   the copy.
3. **The parent-session record is a projection.** `core/ids.SessionId`
   (`protocol-change/008`) is minted once at session creation and lives in
   the reserved `session/id` cell, with a fork's source recorded in
   `session/parent`; the SQLite catalog's `parent_session_id` column and
   its metadata `session_id` field are the lease-free copy an outside
   lister reads. `session/repo.fork` is the only path that writes one:
   protocol `fork` and Agency children are strands of the same session.
4. **Fact semantics across forks**: names copy in both scopes, labels
   copy with their entries, custom facts never copy — pi's
   application-value rule read strictly.
5. **Healing placement.** Orphaned-call healing happens at projection
   (request construction), inserting the synthetic unknown-outcome
   result directly after its assistant message, before the transform
   hook. Forks copy verbatim.
6. **Rewrite scope** covers entry payloads, every register payload, and
   usage-ledger details — every store a needle can hide in (widened from
   entry-payloads-only by the M3 review fix; the audit test plants the
   needle in each store). The memory backend has no persisted generation
   — a rebuilt handle is its invalidation.
7. **Erase leaves object keys alone**; a needle colliding with
   structural vocabulary aborts as corruption rather than corrupting.

## From the M3 runtime wave (`runtime`, `machine`)

1. **Additive machine fields.** Admission gained the resolved adapter
   api, captured durably with the generation intent, so classification
   validates deferred handles against the request's api rather than the
   response's claim. Outside the frozen Part 1 surfaces; production
   admission hooks must supply it.
2. **Acceptance now expects the leaf.** The acceptance transaction
   carries an expectation on the strand leaf at its read sequence — live
   now that forks and idle tree-writes exist.
3. **Escalations are registers, not entries**: mutable current state
   with point lookups on the clearance path, never moving a leaf or
   entering projection. An approval is attributed to the exact call its
   denial was raised for (`CallScope`) and consumed by CAS *before* the
   clearance uses its grants — a lost consume race drops the grants and
   the call clears under base policy, and a crash after consumption
   spends the grant without execution: both directions fail safe.
3a. **Terminal results are recorded twice, atomically**: the latest-wins
   `strand.last_result` (pi §3.13) and an operation-keyed copy under the
   reserved `fact.custom/operation-result/{op}` prefix, which is what
   `api.await_strand_result` keys on — a child's second run can no
   longer make its first result unobservable.
4. **Grant JSON crosses the runtime opaquely**; decoding it back to
   broker policy grants for the widened re-execution is gateway-wave
   wiring.
5. **Abort-marker race exhaustion re-delivers with pacing** instead of
   halting the strand — idempotent, converging, no silent loss.
6. **Parallel dispatch adds per-tool exclusivity only**; the broker's
   pooled budget remains the concurrency ceiling underneath.

11. **The fallback chain is walked — on route (issue #14, closed).** The
    tension recorded here was between durable exactness and a chain that
    was parsed, validated and inert. It is resolved by narrowing what
    exactness has to mean. Recovery never re-dispatches a request that is
    still in flight: it orphans it, settles it synthetically, and
    re-attempts from the checkpoint — so what must agree across a crash is
    the *decision*, not the socket. `client/wiring.request_target` makes
    that decision a pure function of durable state and boot config: an
    identity that **heads** a routable role's chain dispatches
    `ForRole(role, …)` and the gateway walks the chain inside the attempt;
    an identity no role heads dispatches `ForResolved` to exactly what was
    captured. Deferred polls stay `ForResolved` unconditionally, because a
    handle belongs to the identity that minted it (ORCH-L4). The one
    accepted cost — a deferred handle settled by a fallback target fails
    its identity check and drains as failure — is written down in
    `protocol-change/009`, and nothing settles `Deferred` today.

12. **`plan` and `vision` are reserved vocabulary.** `main` and
    `subagent` are dispatched on (the derivation in
    `wiring.request_target`, plus the child seeding in `client/agency`),
    and `summarize` is dispatched on by every structural summary. `plan`
    and `vision` are parsed, validated, registered and listed while
    selecting nothing — and deliberately so: the harness has no
    plan-generation step and no image-bearing request path, so wiring a
    dispatch site would mean inventing the caller as well as the route.
    They stay routable in the catalogue because an operator declaring
    intent early costs nothing and the rows become live the day a caller
    exists. Stated here as an as-built fact, not as pending work.

13. **A catalogue entry's `thinking` seeds a strand rather than reaching
    the wire (closed).** The field is not an override at dispatch — the
    per-turn level is absolute there, because a turn that raised its
    budget must reach the provider with exactly that budget. It is the
    *seed*: `client/wiring.strand_thinking_level` lifts it onto the
    machine's scale at all three strand-creation points (`client/serve`'s
    `main`, the hub's `fork`/`create_strand`, and an Agency's child).
    `set_config model_name` deliberately does not disturb it.

## From the planner navigability pass (`machine`, `conformance`)

1. **The simulation drops a steer when the writer lease is stolen.**
   *Closed (issue #6).* `conformance/simulation/surface.apply` discarded
   the `Result` of `api.steer_quietly`, so a steer that never landed was
   indistinguishable from one that did and the faulted transcript
   diverged by one turn — surfacing as a `convergence/projection`
   failure, or downstream as `convergence/ledger`. Reproduced on seed 264
   against the *pre-refactor* planner, so it was a harness fault rather
   than a planner one: the steer never reached the machine.

   `apply` now honors the result. A refused steer or follow-up whose
   trigger fires from inside a live effect — where a run is open by
   construction, so refusal cannot be legitimate — is recorded through
   `control.note`, which the runner collects into `Report.violations` and
   fails the seed on, naming the refusal instead of letting it resurface
   one check later as an unexplained divergence. Nothing about the fault
   schedule changed, so the seed corpus keeps its meaning. Two cases are
   deliberately *not* violations: an `AtTerminalCommit` steer, where
   refusal is the documented outcome (the run it would attach to is
   already closed), and an admission the harness's own 2 s window did not
   observe, which is not evidence the commit failed — both are marked for
   coverage instead.

   The `enqueue` half is closed too, and differently from how this entry
   proposed. Retrying `CommitFailed` the way `StaleExpectation` is
   retried would spin a bounded ladder against a fence that refuses every
   attempt and then report `RaceLost`, naming the wrong cause. Instead
   `core/tx.CommitError` gained `LeaseLost(held_by:)`
   (`protocol-change/005`), the SQLite backend raises it where it used to
   flatten the condition into a `Faulted` reason string, and
   `runtime/api` maps it to `ApiError.SessionStolen(held_by:)` and
   finishes the admission at once. A caller can now tell "someone else
   took the session" from "the disk is full", which are not the same
   problem and do not have the same fix.

2. **A long checkout path breaks the code-mode tests.** The cap socket is
   an AF_UNIX path, capped at 108 bytes by `sun_path`. In an agent
   worktree the test's path measured 119 and every code-mode test failed
   with `einval`; in the ordinary checkout the same path is 77. The
   production launcher already names execution directories by a short
   digest and refuses an oversized path in band, but the test harness does
   not, so the failure reads as a code fault rather than an environment
   one. Give the tests the same digest-naming, or have them refuse with
   the launcher's worded reason.

3. **`settle_poll`'s `expected_api` looks like the mistake ORCH-L4 warns
   about, and is not.** It passes the response's self-reported api, which
   the invariant forbids trusting — but a poll has no captured api to
   check against, and the guarantee is upheld one step later by
   `resuspend_on_poll_handle`'s full handle equality against the source,
   which inducts back to the assistant response's validated api. The
   reasoning lived two functions away with nothing at the site; a
   cross-reference now sits there. Recorded because the next reader will
   have the same doubt.

## From WP-J (`codemode`, `cap`) — decided at M4 kickoff

1. **Canonical cap module set.** Design §6.2 lists `cap/net` + `cap/report`
   but omits `cap/kv`; the WP-J spec lists `cap/kv` but omits `cap/net`.
   Resolved as the union, since the vetting allowlist IS this set and the
   two must not diverge:
   `cap/{fs, proc, net, git, lsp, report, task, actor, kv}`.
   `cap/net` ships as a real module whose calls deny by default (network
   is off by default; a policy escalation is the only path to egress),
   so the design's canonical "a program that never imports `cap/net`
   cannot open a socket, and importing it still yields nothing without an
   approved policy" story stays literally true. §6.2's list is stale on
   `cap/kv`; the WP-J list is stale on `cap/net`.

2. **The `cancel` frame is correlated to a cap_call's frame `id`.** Part
   1.4 sketches `cancel` from the exec-helper's single-execution view,
   where an execution is the unit; but the satellite channel multiplexes
   many concurrent `cap_call`s over one port, so a `cancel` must name
   *which* in-flight call to revoke. Resolved: `cancel` carries the same
   frame `id` as the `cap_call` it cancels. A killed satellite process is
   one the channel actor monitors; its `DOWN` emits a `cancel` for that
   process's outstanding call id, and the broker revokes + kills the
   pgroup for exactly that capability invocation.

3. **cap_result value shape and the encode/decode split.** The inbound
   `cap_result` value shape matches WP-G broker item 4
   (`{ok, value | error{code, msg}, usage?}`). Ownership of the wire:
   `cap` owns *outbound* `cap_call`/`cancel` byte encoding (over
   `core/msgpack`, with no `broker` dependency — the satellite must not
   link the broker), while J3's satellite runtime owns *inbound*
   deframing and feeds decoded outcomes to `channel.deliver`. This keeps
   the trust boundary clean: the untrusted satellite serializes requests,
   the trusted runtime parses replies.

4. **J3 boot-module init contract (cap → satellite runtime).** Before
   `main`: `channel.start(token, send)` once (`send: fn(BitArray) -> Nil`
   is the framed port write), then
   `dispatch.install(channel.to_channel(handle))`. Then run the read
   loop: deframe inbound `cap_result` frames and call
   `channel.deliver(handle, frame_id, CapOk | CapErr)`, mapping
   `broker/framing.CapOutcome` → `channel.CapOutcome`. Marshal `main`'s
   `report.Outcome` back with `report.to_msgpack`; `channel.stop(handle)`
   on teardown. `channel.subject(handle)` is available if a forwarding
   loop is wanted. A kept-alive cell re-`start`s + re-`install`s per
   invocation with the fresh token. These shapes (`VetPolicy`,
   `VetResult`, `Vetted`, the channel/dispatch API) are agent-designed,
   not frozen Part-1 interfaces; a different contract J3 needs is a
   coordination point, not a protocol-change.

5. **Code mode is not the agent-to-agent transport.** The two planes are
   separate by design, and the separation is a trust boundary, not an
   oversight. Agent-to-agent *is* the messaging plane: subagents are
   strands (design §182), and they communicate through durable commits —
   request/reply, peer-to-peer, blackboard, broadcast — because a BEAM
   mailbox evaporates on crash (§198). Code mode runs *within* one
   strand's operation, and `cap/actor` is explicitly program-scoped: its
   actors live and die inside the satellite. None of the canonical nine
   cap modules can reach another strand, so a code-mode program cannot
   message one at all.

   Whether a `cap/strand` should exist is a genuine open question, not a
   missing feature to fill in. The messaging plane's rule is a
   *correctness* rule about durability (§211: if the recipient would act
   differently having received it, it goes through a commit), and it was
   designed assuming **trusted** participants — §211 is explicit that
   subagent strands are trusted harness code, the model influencing their
   content but not their code. A code-mode program is the opposite: it is
   untrusted model-written code. Giving it a messaging capability would
   import an untrusted writer into a plane built for trusted ones, which
   needs a policy and attribution story before it needs an API. Deferred,
   and recorded here so it is decided rather than drifted into.

14. **The satellite's enforcement report was usually lost — fixed**
    (issue #5). `satellite` reported enforcement only on `CallExited`,
    on a `fn(entries, degraded)` side channel, and `destroy` aborted the
    operation as soon as the outcome arrived — so a healthy run reported
    the build's layers and nothing for the node, observed live while
    wiring the code-mode tool. Both candidate fixes were taken, because
    each answers half of it. The report is now **carried in the
    outcome**: `compile.Compiled` carries the build's, `satellite.Run`
    carries the node's, and `codemode.Execution` carries both as a
    two-field record, so no outcome can exist without them. And it is
    **collected on the abort path**: `CapConnection.destroy` returns the
    report, the host tears the node down before it reports its outcome,
    and the launcher's holder cancels the node's clearance whichever way
    teardown and clearance race — a cancelled execution still answers
    with `exec_exit`, which is what makes the report reachable rather
    than lost. A stage that genuinely made no report says why
    (`enforcement.Unreported`), which is not the same value as one that
    reported nothing. `make e2e-codemode` asserts both stages report on
    the happy path and on the deadline kill.

15. **Approved escalations never widen a code-mode execution.** Every
    clearance the pipeline makes passes `grants: []`, so an operator who
    approves a denial for a program's benefit changes nothing. It fails
    closed, which is the right direction, but the design documents do not
    say it. The workspace-tool half of this is now built (WP-L 1 below):
    a policy refusal there raises, parks, and resumes. Code mode has the
    same severed channel one seam over — `client/codemode` composes its
    own policies and passes no grants — and applying the same mechanism
    there is issue #24.

16. **Identity and budget are specified three times.** `ExecConfig` makes
    a caller build `BuildConfig` and `SatelliteConfig` + `ExecId`
    separately, each carrying its own operation, step, and budget, and
    nothing structurally stops three different identities reaching the
    broker. The pooling invariant — one ledger per execution — is
    therefore a convention the caller must honor rather than a property of
    the types, and `make e2e-codemode` itself does not: it builds under
    `step_id <> "-build"`, opening a second ledger. One threaded
    `ExecIdentity` would make it unbreakable.

## From M3 messaging (design §4.6 reconciliation)

1. **Request/reply is explicit-poll, not auto-enqueue.** §4.6 says a
   subagent's terminal result "is an entry the parent's checkpoint
   consumes," implying it flows into the parent's run automatically. The
   runtime does not do this: the parent calls `await_strand_result`,
   which reads the child's terminal result from durable state
   (`operation-result/{op}`, falling back to `strand.last_result`); the
   result never auto-enqueues, and the parent's checkpoint plays no part.
   To pull a child's result into the parent's own conversation, the
   parent `send_to_strand`s it. The code is the intended shape; §4.6's
   phrasing was aspirational.
2. **Broadcast is read-side only.** §4.6 lists the EventBus as a
   strand-to-strand pattern. As built, the bus is the durability plane's
   read side: content-free hints over `pg` for UIs, projections, and the
   gateway. No strand-facing broadcast-send exists and strands do not
   subscribe; a strand wanting a sibling to act writes a durable fact or
   sends directly. Cross-node fan-out is follow-up.

## From WP-L (`client`)

1. **The escalation loop is closed end to end** (issue #4, on decision
   D1 in issue #11). Three seams had to line up and did, in this order:

   - **The grants channel is threaded.** `runtime/effects.ToolRun` grew a
     `grants` field, the driver carries what its clearance consumed onto
     the dispatch that clearance authorized, and `client/wiring`
     decodes them there onto the tool `Ctx.grants` — which `bash`
     already passed into its `CallSpec`. `wiring.Config` no longer has a
     session-wide `grants` list at all: an approval that cannot be
     attributed to the call in hand widens nothing, which is the whole
     point of `CallScope`.
   - **A policy refusal parks.** `client/escalate` raises a durable,
     call-scoped record for every `broker.PolicyRefused`, and — when the
     host says someone is attached — holds the call open on its own
     effect process until the record is decided, the window closes, or
     the client goes away. An approval is consumed by CAS and the *same*
     call is re-cleared once under the widened policy. Parking is what
     makes a scoped approval spendable at all: a model that read the
     in-band refusal and retried would arrive under a new call id the
     approval could never match.
   - **The raise policy is "always, deduplicated".** The record id is a
     digest of `{strand, tool, wanted diff}`, so a retry loop lands on
     the record already pending instead of one row per attempt, and the
     in-band error stands alongside the record. Which records interrupt
     a person is a client-surface decision: the gateway already emits
     escalation events and lists pending ones in its snapshot.

   The **interactive flag is a runtime concern again**, and it decides
   *parking only* — never whether a record is written. `client/serve`
   answers it with `gateway.attached(...) > 0`, so a headless session
   records refusals and settles them rather than holding a call open for
   a decision nobody is there to make.

   **The loop is now driven by a real client over the real protocol**
   (issue #7). Until then every approval in every test was an in-process
   `api.approve_escalation` and every parking test injected `interactive`
   as a constant, so nothing had ever watched a decision travel from a
   keystroke into a call that was waiting for it — and `gateway.attached`
   itself, the value the whole behaviour now turns on, had no test at
   all. `client/tui_e2e_test` closes both: it counts the hub's
   connections going 0 → 1 → 0 as the real `loom-tui` attaches and
   quits, and it asserts a parked refusal reaches `Consumed`, which only
   `client/escalate`'s park loop writes — `Approved` alone would mean the
   frame arrived and nothing was waiting for it.

   Reaching that needed a seam: the session base policy is a
   `serve.Settings` field rather than a `base_policy(workspace)` call
   inside `boot`. Under the shipped base no tool can provoke a refusal —
   it grants read of `/`, writes to the workspace, and the four
   environment names `bash` passes, which is every requirement any
   shipped tool has — so a real server could not be booted into a state
   where anything parks. The field is also an honest posture knob: a
   cautious operator may serve a narrower base and let escalations widen
   it per call, which is what the escalation plane is for.

   Two bounds on a park, both load-bearing: the configured window, and
   the call's own budget deadline — the broker's ledger refuses a
   reservation past `deadline_ms`, so holding a call past it would trade
   an honest "policy refused" for a confusing "deadline passed".

   `make e2e`'s `escalation_round_trip_test` is the proof: a jailed
   session whose base policy is narrower than `bash` needs, a refusal, an
   approval of exactly the stored wanted diff, and the file the resumed
   command writes inside the jail.

   Still open here: the code-mode half is issue #24 / WP-J 15. The
   gateway's attribution gap is closed — `protocol-change/007` reads
   `op`/`strand` off the record's own `CallScope`, carries the tool,
   action digest and argument preview into the `escalation` body, and
   makes `approve` echo the diff and the action it rendered.
2. **No api entry points for compaction or navigation** — the gateway,
   like the conformance runner, builds acceptance plans itself and
   commits through the writer. Two copies of that pattern argue for
   api.compact and api.navigate.
3. **Strand creation always takes a task brief**; protocol fork and
   create-strand need idle strands, so the gateway seeds registers
   itself. An optional-brief variant would close this.
4. **Protocol fork forks in place** (own strand, shared tree); forking
   into a new session file is unreachable through protocol v1, whose
   snapshot cannot name a second session. Documented at the type.
5. **Fixture-vs-codec drift** (tool-call nesting, an always-present
   redacted flag, float text): adapted wire-side both directions; if
   the corpus is ever regenerated from the core codec, this needs a
   protocol-change note.
6. **Queued versus placed acks**: steer and follow-up acks describe the
   durably queued item with a reserved id and no sequence; the placed
   entry broadcasts on consumption under that same id, and an item still
   queued at the run's terminal boundary is deleted rather than placed,
   so some acks are never followed by anything. The protocol document's
   reply table now marks both rows queued and states the rule beneath
   it, including what a client must do with an ack it may never see
   placed.
7. **Provider deltas tee through a wrapper** around the provider
   surface — the documented seam; the runtime needed no change.
8. **Off-route model facts fall back.** A strand switched by
   `set_config` `model_name` to a catalogue entry that is not what the
   configured role resolves to dispatches `ForResolved` with the
   wiring config's fallback context-window/output facts, not the
   entry's own — `client/wiring.Config` has no per-identity fact
   lookup. Dispatch (dialect, base URL, key) is exact; only overflow
   arithmetic is approximate. Fix belongs in the wiring seam.
9. **Per-model headers are refused, not carried.** The provider
   registry's `ProviderConfig` has no header slot, so the catalogue
   parser rejects a `headers` key with a worded message rather than
   ignoring it. Baseten's OpenAI-compatible endpoints need none (the
   bearer key suffices); revisit if a dialect genuinely requires one.
10. **Role chains are boot-time only.** The catalogue's `[roles]`
    routing is baked into the gateway registry the wiring closures
    capture at boot; `model_name` switches strand identities, and a
    session-scoped switch (no `strand`) rewrites every strand's
    durable configuration — but re-routing a *role's* fallback chain
    at runtime would need a mutable registry or a reboot.

## From §3.4 (`telemetry`)

Spec §3.4 is one normative sentence with no acceptance row behind it,
which is why nothing implemented it until issue #35. It asks for four
things — Erlang `logger` with a JSON handler, `{session, strand, op,
step}` everywhere, optional OpenTelemetry export, and telemetry as
observability only. It names no severity ladder, no propagation
mechanism, and no rule about what a line may carry. Those are the
interpretations, recorded here so they are decided rather than drifted
into.

1. **Context travels as a value, not as logger metadata or the process
   dictionary.** §3.4 says "context everywhere" and leaves the
   mechanism open. Erlang `logger`'s process metadata is *not*
   inherited across `spawn`, and the effect sandwich runs every
   provider request, tool run and parked call on a process the strand
   driver just spawned — so a metadata-only design would drop the
   context precisely where interleaved strands make it matter, and drop
   it silently (the lines still appear, merely uncorrelated). The
   process dictionary has the same non-inheritance plus invisibility to
   the type system. So the context rides in the `telemetry/log.Logger`
   the spawn closure captures, and the compiler enforces the capture.
   `log.adopt` additionally stamps the same slots into `logger`
   metadata at the top of a spawned body, for the benefit of lines the
   harness did not author (OTP crash reports); that is a fallback for
   foreign output, never the mechanism.
2. **Four levels, not OTP's eight,** with a stated policy
   (`telemetry/level`'s module doc): `error` = no automatic recovery
   remains; `warning` = degraded but progressing; `info` = one line per
   durable state change; `debug` = per-step effect traffic, off by
   default. `emergency`/`alert`/`critical`/`notice` draw distinctions a
   single-session harness has no use for, and an unused rung is a rung
   people guess at.
3. **The secret rule is enforced, not asked for.** §3.3.4 says secrets
   never appear in logs; §3.4 provides no mechanism. `telemetry/field`
   applies two independent rules to every field — a key denylist and a
   value-shape scan — because either alone has a known hole, and the
   Erlang formatter calls back into the same Gleam function for lines
   the harness did not author. The shape rule's threshold (32 unbroken
   credential-alphabet characters) is chosen against what this tree
   actually holds: the broker's clearance token and the cap channel
   token are both 32 random bytes. Its exemption is typed — `Ident` —
   so every waiver is a deliberate, greppable act.
4. **A record carries no timestamp.** §0.2 makes time an injected
   `Clock`, and `core`'s clock is threaded: a log call that read it
   would consume steps and shift the ids minted afterwards, so a line
   written for observation would change what the system durably
   records. The handler stamps `logger`'s own time instead.
5. **"JSON handler" is the stock `default` handler with our
   formatter.** OTP ships no JSON handler, so the choice was a custom
   handler or a custom formatter on the supervised one. The formatter
   keeps `logger`'s overload protection and back-pressure, and the JSON
   itself is built in Gleam (`telemetry/record.render`) so redaction
   happens in pure, tested code rather than in the shim.
6. **OpenTelemetry is left as a seam.** §3.4 marks it optional.
   `log.Sink` is `fn(Record) -> Nil` and `log.tee` composes two, so an
   exporter attaches without changing the package; nothing about an
   export path is built, and no configuration surface pretends
   otherwise. Deferred work with no home — the proposed home is a Part
   5 track, alongside WP-F 7's keychain backends.
7. **Not every `io.println` became a log line.** The startup banner
   (`client/serve.announce`), the demo narrative (`client/demo`) and
   the seed's ready marker (`codemode/seed`) are the *output* of the
   programs that print them, read by a human or a script; a usage error
   is a message to whoever mistyped a flag, before there is a session
   to correlate to. Those stay on stdout/stderr. Everything about a
   *running* system — boot failure, SIGTERM, a fatal child, an absent
   code-mode toolchain, prompt-pack warnings, projection pull faults —
   is now a log line.
8. **Coverage is the seam plus three call sites, not the whole tree.**
   The drive loop, the server entry point, and the projection driver
   log; `broker`, `provider`, `tools`, `codemode`, `cap` and `session`
   still log nothing. §3.4 says "everywhere" and this is not yet
   everywhere. Deferred work with no home; the proposed home is
   whichever milestone next touches those packages, one injected
   `Logger` at a time — the seam is the part that had to be decided
   once.

## From triggered rules (`client`, `runtime`) — issue #27

Spec Part 4's M5 row names TTSR and states no acceptance criterion for
it; Part 5 track 8's entry is the post-M6 memory→skill promotion half,
which this work does not touch. So the acceptance is the issue's own
Done list, and the interpretations below are recorded here because the
spec supplies none.

1. **The scanner is fed by the durable commit stream, not the delta
   stream.** Design §8 says "fed by the streaming parse". Measurement
   says that mechanism fights the tree: deltas are ephemeral by
   contract, the runtime's effect process discards them, and the
   simulation provider emits none at all — so a delta-fed scanner is
   untestable by the very harness the issue demands a scenario from. It
   would also decide from bytes that exist nowhere durable, which is the
   one thing "hooks decide from durable state" forbids. And it would buy
   nothing: an injection reaches the model at the next checkpoint, and
   the settled assistant entry commits *before* that checkpoint. The
   design's intent — dormant at zero cost, injected mid-run, off the hot
   path — is preserved exactly; its mechanism clause is corrected.
2. **Injection is the queue machinery, not the hook registry.** The
   issue said "through the existing hook registry". The registry's only
   injection points are `run_start` (fires once, before a run's first
   request — so a rule tripped mid-run would wait for the *next* run,
   possibly forever) and `run_end`. The mid-run door that already exists
   is the inbox, so a fire is a durable steer-shaped admission drained
   by the machinery every steer uses. Nothing in `runtime/effects.Hooks`
   changed shape.
3. **The reserved `rule/` prefix needed no `protocol-change/`.** The
   frozen Part 1 contracts fix `RegisterNs` — the namespace *enum* — and
   say nothing about which `fact.custom` key prefixes the runtime
   reserves; `lineage/` was added the same way and is recorded under
   "Delivered outside the table" rather than as a protocol change. The
   reservation is a `runtime/api` property (`reserved_fact_key`,
   `put_reserved_fact`, `reserved_facts`), and adding the sixth corner
   changes no interface anyone else implements.
4. **A rule fires at most once per strand per session, and there is no
   re-arm.** The fired-mark is write-once and nothing clears it. An
   unconditional re-fire would turn "zero cost when dormant" into
   "unbounded cost once tripped", which is the property the feature
   exists to have; a `re_arm` field costs nothing to add later if a real
   want for one appears.
5. **A rule tripped on an idle strand is held, not dropped and not
   started.** Starting a run would let project configuration wake a
   session nobody is talking to and issue a provider request no operator
   asked for. Dropping would spend the rule silently, leaving an
   operator with a configured rule that never fires and nothing saying
   why. Holding is expressed by not advancing the scan cursor, so the
   next run finds the same entry — no extra state records the hold.
6. **The durable scan cursor is a checkpoint, not a position of
   record.** Correctness rests on the fired-marks, so the cursor is
   written lazily (`rulescan.default_checkpoint_every`) rather than on
   every pass. Checkpointing each entry would put an extra commit behind
   every assistant message for a feature that usually never fires.
   A restart that resumes behind the checkpoint re-judges a bounded
   overhang, which the marks make harmless.
7. **Only assistant output the projection keeps is scanned.** Errored,
   aborted and deferred responses are excluded — the same set
   `session.project_entries` drops. A rule may only fire on text the
   model will still see, and an `error` response carries the harness's
   own failure prose rather than model output.
8. **A fire is at-most-once, and the one losing corner is an abort.**
   The injection and the fired-mark are one transaction, so nothing can
   inject twice — but a queued steer only becomes conversation when a
   checkpoint drains it, and an abort landing between the fire and that
   checkpoint destroys the queued injection while the write-once mark
   stands. The rule is then spent on text the model never saw. Admission
   time cannot see an abort coming, and a mark that could be un-written
   would reopen the injection loop the write-once shape closes, so the
   corner is recorded rather than defended: the mark still says what
   fired, which is more than a dropped rule would leave behind.
9. **A newly configured rule can fire on old text.** The first boot
   after a rule is added starts its scan cursor at zero, so the scan
   covers the strand's whole still-projected history — a trigger the
   model tripped weeks ago, if it is still in the window the model sees,
   fires the rule on the next commit. Coherent with item 7 (the rule
   fires only on text the model still sees) but worth stating: adding a
   rule to a live workspace is not prospective-only.
10. **A hold on a strand that will never run again is permanent.** A
   trigger matched in a finished subagent strand's history holds —
   correctly, since starting a run is the thing a rule must never do —
   and nothing ever opens a run there, so the hold is retried on every
   later pass. The transition into holding is logged once
   (`rule.holding`), and the per-pass cost is bounded by `scan_limit`;
   a terminal state for provably-dead strands is follow-up work, filed
   on the issue tracker rather than solved with a lineage read here.

## From memory stage M2 (`client`, `tools`) — issue #29

Spec Part 5 track 8 names the memory→skill promotion path and nothing
about the memory session itself; the design note
(`docs/design-notes/compaction-and-memory.md`, Part 3 and Part 5 stage
M2) is the design of record, and the issue's rulings are its
interpretation. Recorded here because the spec supplies none.

1. **The fold is the session directory, not the workspace.** The note
   says "a dedicated memory session per workspace". `--workspace`
   defaults to the working directory and can differ per invocation while
   the session directory is stable, so folding on it would make one
   repository two memories the first time somebody started a server from
   a subdirectory — the omp lowercased-basename lesson the note itself
   warns about. `loom-memory.db` therefore lives beside
   `loom-search.db`, on the fold memory stage M1 already established.
2. **"Leased" is the ordinary writer lease, and the pipeline is a
   command rather than a resident.** `gleam run -m client/distill` opens
   the memory session under `owner: "loom-distill"` and holds it for the
   run; a second concurrent run loses `LeaseHeld`, which is precisely
   the single-writer consolidation semantics omp bought with a
   lease-and-heartbeat. No new lease type, no heartbeat, and no
   background writer inside `loom-server` — which never opens the memory
   session at all.
3. **`LeaseHeld` on a source *is* the live-session skip rule.** The note
   says "skip sessions younger than a few idle hours". A live server
   holds its session's writer lease, so the pipeline's open fails and
   that file is skipped: the same intent, structurally, with no clock
   arithmetic and no second read path. The other half of the note's
   heuristic — skipping sessions older than ~30 days — is deliberately
   not implemented: the per-source cursor makes an old session cost one
   open and no model turn.
4. **The anti-feedback exclusion is `client/distill.extractable`, and it
   is a rule about types.** Extraction takes settled assistant text
   (`client/rules.scannable_text`, shared with the triggered-rule
   scanner) plus compaction and branch summaries. A user turn
   contributes nothing, which excludes an injected memory digest by
   *role*; a `CustomEntry` contributes nothing, which excludes `memory/*`
   rows planted in a source session by *type*. The memory file is never
   opened as a source, so the exclusion holds twice over.
   **The honest limit:** once a summarizer has paraphrased a digest into
   a compaction summary, no type survives to exclude it. Dilution
   through summaries reaches the same first-derivation boundary erasure
   does (item 9), and is stated rather than defended. What a preference
   stated in a user turn loses to this rule, the `remember` door
   supplies — that is what it is for.
5. **The digest crosses to the server as a sidecar file, and the file
   holds the body only.** Consolidation renders the head into
   `loom-memory.digest`; the server reads it once at boot, takes no
   lease and holds no handle, and injects it at every run start. The
   fence and the attribution are built at injection time
   (`client/memory.wrapped`) rather than stored, so a digest file
   somebody managed to write cannot forge its own provenance — claim to
   be operator text, or close the fence and speak outside it. The file
   is also protected in the base policy, conditionally, where a writable
   root reaches its directory (`client/serve.protecting_memory`); the
   condition is the missing-file-under-a-read-only-parent hazard the
   index family's own list was narrowed for, not a convenience.
   "Memory updates land at session boundaries" is then a property of the
   arrangement rather than a check: the bytes are fixed at boot.
6. **The memory session's registers need no reserved prefix.**
   `runtime/api` reserves `fact.custom` prefixes because a model can
   reach `put_fact`. Nothing model-influenced can reach a register in
   the memory file: it is never opened through `runtime/api`, and the
   only model-reachable door into it is `remember`, which appends one
   entry under a type the host chooses and can name neither a register
   nor its own entry type. So `distill/head`,
   `distill/cursor/<session-id>`, `distill/notes` and `remember/count`
   are plain cells, and the six reserved corners were not extended.
7. **Disjoint entry types are pinned by a test, not by a registry.** The
   pipeline writes `memory/fact`, `memory/lesson` and
   `memory/preference`; `remember` writes `memory/note`. Both lists are
   exported constants and a test asserts the intersection empty. There
   are exactly two writers, both harness-side, and a model never chooses
   a type string — `client/distill.parse_candidates` maps model output
   through `client/memory.type_named`, which does not accept `note` — so
   a registry would be machinery with no threat to answer.
8. **`CustomEntry` stays unindexed, and `events` is untouched by this
   stage.** The note's "memory becomes searchable through
   `history_search`" is deferred with the tokenizer to memory stage M3:
   indexing `memory/*` opens exactly the loop the anti-feedback rule
   exists to shut, and recall of memory in M2 *is* the injected digest.
   WP-K item 9's `history_search`-echo loop stays open for the same
   reason — its closure belongs with M3's indexing decision, where the
   by-type machinery would pay for both.
9. **Erasure stops at the first derivation, and the cascade is filed
   rather than built.** Every distillate carries provenance — the source
   session ids and entry ids it was distilled from, and the memory entry
   ids it supersedes — which makes the design possible: erase X, find
   the distillates naming X's entries, re-consolidate without them.
   Issue #115 carries that implementation. What provenance cannot buy is
   stated here: a consolidation of a consolidation carries its
   predecessor's id and not its predecessor's whole source list, so the
   guarantee ends at the first derivation unless every derivation keeps
   full source lists. The compaction analogue is already recorded (the
   spec's erase-X audit includes retained-tail copies), and the
   summary-dilution twin is item 4.
10. **The per-run digest re-injection is the accumulation item already
   recorded, not a new one.** A `run_start` message is a born-placed
   durable entry, so a session accumulates one capped digest copy per
   run until compaction evicts them — exactly WP-K item 8, now with a
   second digest riding it. The per-injection bound is real; an
   in-context total bound is not. Skip-if-unchanged remains the named
   remedy, and remains unbuilt until the cost shows.
11. **The deterministic simulation stays single-session, so the crash
   points are integration tests.** "Conformance scenarios for the
   pipeline's crash points" is met by the `memory_recall_test` shape —
   real session files, a real memory session, a scripted provider, the
   kill driven by running the consolidation's phases and stopping
   between them. The simulation runner models one session's operation
   state space; a pipeline that walks a *directory* of session files has
   no place in it, and giving it one would be a large change to the
   thing whose determinism everything else rests on.
12. **`--config` is required for `client/distill`.** A run dispatches
   two model turns, so it needs a catalogue; unlike `loom-server` there
   is no zero-config posture worth preserving, because a distillation
   run nobody scheduled is not a thing that happens. The environment
   fallback `client/serve` keeps is deliberately not duplicated.
13. **A consolidation that produces nothing usable refuses the run.** The
   head is replaced wholesale, so a model answer with no parseable lines
   would otherwise erase memory and advance every cursor past the
   sources that fed it — one malformed turn, and the repository forgets.
   The run fails instead, leaving the head, the cursors and the sidecar
   where they were, and the next run retries over the same input.
