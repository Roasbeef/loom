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
which is 86 of the 114 items. A recorded option nobody must exercise (a
"candidate for hoisting if the duplication grates") stays settled; only
work someone must do to meet a stated criterion is listed here.

Items are cited as section plus the number as written in the list
(`WP-J 14`, `M3 runtime wave 11`).

### Deferred work with a home (8)

| Item | The work | Scheduled at |
|---|---|---|
| WP-A 3 | somewhere to put pi's optional `details` payloads | Part 5 track 6 |
| WP-B/T 6 | the JSONL/format-4 import shim | Part 5 track 6 |
| M2 integration 3 | a provider surface for deferred polls | M5 — the structural-summaries half shipped in Stage C0 (`client/wiring.summary_provider_request`); polls remain unwired |
| M3 runtime wave 11 | commit the role, or have recovery consult the chain in force at commit time, so the fallback chain is actually walked | M5, whose acceptance names the chain |
| M3 runtime wave 12 | dispatch on the `subagent`/`plan`/`summarize`/`vision` roles, not `main` alone | M5 |
| M3 messaging 2 | cross-node broadcast fan-out | Part 5 track 4 |
| WP-J 5 | whether a `cap/strand` should exist — answered by `design-notes/orchestration-comparison.md`: yes, on a second seam carrying `cap/strand` + `cap/report` and nothing else | M4.5 / WP-N |
| WP-J 14 | carry the satellite's enforcement report in the outcome (or report on the abort path) so a green run proves the jail engaged | M4.5 / WP-N, which sequences it before the seam |

### Deferred work with no home (20)

Twenty items, nineteen rows: the canonical session id is recorded
twice. Nothing in the right-hand column is scheduled — it is where the
work would sit if someone scheduled it, recorded so the choice is made
rather than drifted into. Part 5.1 of the spec says the same thing from
the other side.

| Item | The work | Proposed home |
|---|---|---|
| WP-L 1 | a production denial-raiser: nothing under `client/serve` raises an escalation at all, and the gateway raises through the unscoped legacy path whose approvals no clearance loads | M3 residue — reopen under M3's row |
| WP-J 15 | let an approved escalation widen a code-mode execution; every clearance the pipeline makes passes no grants, so approving one changes nothing | M4.5 / WP-N, with WP-L 1 |
| WP-J 16 | one threaded `ExecIdentity`, so one-ledger-per-execution is a property of the types rather than a convention the caller must honor | M4.5 / WP-N |
| WP-E 8 | the chaos tier of WP-E's own exit criteria — random kills under load, ten-minute soak. `make soak` is the deterministic-simulation seed soak, not a chaos runner | WP-T, and M1 recorded partial until it runs |
| WP-E 3 | root the session tree under an application supervisor: close is a controlled crash, and `client/serve` is now the long-lived host the entry said to wait for | a `serve` fix; no milestone |
| WP-G 9 | the MCP adapter — in WP-G's scope, deferred post-M2, integrated by no row since | a Part 5 track |
| WP-F 7 | the per-OS keychain backends WP-F's scope names; only the environment backend ships | a Part 5 track |
| WP-F 6 | pricing tables somewhere ledger-side, since the adapters zero every cost field and §3.4 calls the ledger the billing source of truth | the token-budget work `design-notes/orchestration-comparison.md` sequences after WP-N |
| WP-K 4, WP-C-full 3 | a canonical session id in `core`: the bus, the search service, and the schema's unwritten `parent_session_id` column all wait on one | §1.1 via a protocol-change; M5 |
| M2 integration 2 | a wire mapping for `stream_options`, or its removal — the runtime carries a bag the provider request cannot express and the wire drops | §1.5 via a protocol-change |
| WP-L 8 | per-identity model facts in the wiring seam, so a strand switched off its role's resolution stops doing overflow arithmetic against fallback numbers | M5 |
| M3 runtime wave 13 | decide a catalogue entry's `thinking`: the default a strand overrides, or refused like `headers` — today it is validated and discarded | M5 |
| WP-I 7 | decide whether the tool timeout ceiling is the tool-side clamp or session policy; the entry deferred it to runtime wiring, which has since landed | a §3 line; no milestone |
| M2 integration 1 | state in §0.2 that one clock — or one era — is injected across runtime, tools, and broker | amend §0.2 |
| WP-K 1 | promote the catch-up frontier rule from an entry here to a convention in §0.2 | amend §0.2 |
| WP-A 7 | restate WP-A's "≥95% branch coverage on decoders" in terms something can check; no Gleam coverage tooling exists | amend WP-A's exit criteria |
| WP-L 2 | `api.compact` and `api.navigate`, so the gateway and the conformance runner stop keeping two copies of acceptance-plan building | no milestone |
| WP-L 3 | an optional-brief `create_strand`, so protocol fork and create-strand stop seeding registers in the gateway | no milestone |
| WP-L 6 | address queued-versus-placed acks in the protocol document's reply table | `protocol/`; no milestone |

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
   decoders" is not machine-verified — no Gleam coverage tooling exists.
   Compensated with adversarial corpora (90+ inputs) and per-variant
   property tests. The criterion should be restated in testable terms.
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
7. **Timeout ceiling** is clamped tool-side (600 s max, 120 s default);
   if "policy ceiling" was meant to be session-policy-driven, revisit
   when wiring the runtime.
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

## From WP-E (`runtime`, `session`)

1. **Crash semantics of the harness.** The interleave scheduler's kill
   point is "commit durable, committer unobserved" (kill before the
   writer's reply); an effect whose intent commit is the boundary never
   started, so mid-flight interruption is exercised by dedicated
   kill-the-tree tests (the crash-mid-tool reproduction and abort).
2. **Boot seeding bypasses the writer** — strand seeding commits through
   the session handle before the tree exists, CAS-guarded; every
   post-boot commit flows through the writer.
3. **Close is a controlled crash.** The otp static supervisor offers no
   graceful external shutdown, so close kills the tree (commits are
   atomic, so durable state stops at a commit boundary) and releases the
   lease. Trees should root under an application supervisor when a
   long-lived host exists.
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
   §0.2's time-injection rule should state that one clock (or one era)
   must be injected across runtime, tools, and broker.
2. **`stream_options` has no wire mapping.** The runtime carries an
   opaque options bag the provider request shape cannot express; it is
   dropped at the wire. Extend §1.5 or define the mapping.
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

1. **The catch-up frontier rule** (load-bearing, promote to convention):
   a projection catch-up that reads more than one scan must bound every
   scan by a frontier sequence read before the first one. Without it, a
   commit landing between two scans advances the high-water past rows
   the earlier scan never saw, losing them permanently. Sequences are
   strictly increasing and rows write-once, so the bounded window is
   immutable and the batch consistent.
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
4. **Session identity on the bus and in search is a caller-supplied
   string** — core defines no session-id type. Revisit when the gateway
   needs a canonical id.
5. **Search indexes** message text and compaction/branch summaries;
   thinking blocks and tool-call arguments are deliberately not indexed.
   pi's metadata-filtering question stays open, as in pi.

## From WP-C-full (`session`, `storage`)

1. **Branch-fork configuration source.** pi does not say which strand's
   configuration seeds a branch-scoped fork's main strand; the fork
   request names it explicitly, and an unconfigured source forks to an
   unconfigured main.
2. **Fork re-stamps placement.** The destination assigns fresh seqs and
   timestamps; ids and order are preserved. pi is silent on placement in
   the copy.
3. **No parent-session record.** Loom has no session-id concept yet, so
   the schema's parent-session column stays unwritten; revisit with the
   gateway's canonical id (also WP-K gap 4).
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

11. **The fallback chain is never walked by the session server.** The
    catalogue lets an operator write an ordered chain per role, and the
    gateway implements the walk — but `client/wiring.request_target`
    always returns `ForResolved`, never `ForRole`, and the module doc
    gives the reason at the call site: recovery must re-dispatch exactly
    what was committed, and a fallback walk would let it come back on a
    different model than the durable record names. Durable exactness won.
    The consequence is that a retryably-failing request retries the same
    identity through the machine's retry ladder; the chain tail is parsed,
    validated, and inert. This is a real tension, not an oversight, but
    `effects.md`, the design doc, and the comment in
    `docs/examples/loom.toml` all still read as though the chain engages.
    Resolving it properly means either committing the *role* rather than
    the resolved identity, or having recovery consult the chain that was
    in force at commit time. Deferred, recorded so it is decided.

12. **Only the `main` role is dispatched on.** `client/serve` builds one
    wiring config with `role: Main` for the whole session, so the
    `subagent`, `plan`, `summarize`, and `vision` rows are parsed,
    validated, registered, and listed while selecting nothing. Consistent
    with role routing being an M5 concern; stated here because nothing
    else says it as an as-built fact.

13. **A catalogue entry's `thinking` never reaches the wire.**
    `request_target` overwrites it with the strand's per-turn thinking
    level on both branches, so the field is validated and then discarded.
    Either the entry's value should be the default the strand overrides,
    or the field should be refused like `headers` is.

## From the planner navigability pass (`machine`, `conformance`)

1. **The simulation drops a steer when the writer lease is stolen.**
   `conformance/simulation/surface.apply` calls `api.steer_quietly` and
   discards the `Result`, while `runtime/api.enqueue` retries only
   `tx.StaleExpectation`. A stolen lease returns `CommitFailed`, the steer
   is silently dropped, and the faulted transcript diverges by one turn —
   surfacing as a `convergence/projection` failure, or downstream as
   `convergence/ledger`. Reproduced on seed 264 against the *pre-refactor*
   planner, so it is a harness fault rather than a planner one: the steer
   never reaches the machine. Any fault schedule pairing `steer@turnN`
   with `leasetheft` can hit it, which makes it a rare red in an otherwise
   deterministic suite — the worst kind, because it trains a reader to
   re-run rather than look. Fix belongs in the simulation surface: honor
   the result, or retry `CommitFailed` in `enqueue` the way
   `StaleExpectation` is retried.

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

14. **The satellite's enforcement report is usually lost.** `satellite`
    reports enforcement only on `CallExited`, but `destroy` aborts the
    operation as soon as the outcome arrives, so a healthy run reports the
    build's layers and nothing for the node — observed live while wiring
    the code-mode tool. The tool therefore says a stage that made no
    report is not a claim it was confined, which is honest but weaker than
    it should be. Carrying the report in `Ran`, or reporting on the abort
    path, would make honest reporting structural rather than a racing
    side-channel. Worth fixing before anyone leans on the sandbox line.

15. **Approved escalations never widen a code-mode execution.** Every
    clearance the pipeline makes passes `grants: []`, so an operator who
    approves a denial for a program's benefit changes nothing. It fails
    closed, which is the right direction, but the design documents do not
    say it. This compounds with the finding that no production path raises
    an escalation at all (see WP-L below): a code-mode program cannot
    request a widening, and could not use one if it were granted.

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

1. **Escalation records now carry call attribution** (the M3 fix wave):
   `runtime/escalation.CallScope` records the exact
   `{operation, strand, step, source index, call id}` a denial was
   raised for, and only that call's clearance can spend the approval.
   The gateway still surfaces records without their scope and raises
   through the unscoped legacy path (`api.raise_escalation`), whose
   approvals no clearance will ever load — a production denial-raiser
   should move to `api.raise_escalation_for` and the protocol body can
   now attribute exactly rather than best-effort.
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
   entry broadcasts on consumption. The protocol document's reply table
   does not address the distinction.
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
