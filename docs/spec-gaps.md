# Spec gaps and recorded interpretations

Running log of places where implementation forced an interpretation of the
spec or revealed a gap. Each entry says what was decided and where. Items
that would change a frozen Part 1 interface go through `protocol-change/`
instead and are only referenced here.

## From WP-A (`core`)

1. **Id minting signature.** Part 1.1's comment reads `mint(Clock)`, but
   purity requires entropy injection too. Implemented as an opaque
   `Generator` threading a `Clock` and a seeded SplitMix64 state through
   every mint. This *is* §0.2's "injected UUIDv7 generator"; the literal
   signature in the contract comment is looser than the implementation.
2. **`BranchSummaryEntry.from_id` nullability.** pi allows `fromId: null`
   (summary sourced at the root); our contract says `from_id: EntryId`.
   Implemented per our contract, which makes a root-sourced branch summary
   unrepresentable. Raised as `protocol-change/001`.
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
7. **The wiring adapter lives in conformance source**, giving the
   "test-only" package production-shaped dependencies, because only it
   may depend on every layer. Bless this or promote the adapter into a
   host package when one exists.
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
2. **Checkpoints persist state and high-water together.** The spec says
   "persisted high-water seq"; for a stateful in-memory projection a
   high-water without its matching state is meaningless. Search persists
   cursor-only because its state is the database itself.
3. **Operation-transition events carry a display string**, not a machine
   type — keeping events off a machine dependency per the DAG; the
   register remains the truth.
4. **Session identity on the bus and in search is a caller-supplied
   string** — core defines no session-id type. Revisit when the gateway
   needs a canonical id.
5. **Search indexes** message text and compaction/branch summaries;
   thinking blocks and tool-call arguments are deliberately not indexed.
   pi's metadata-filtering question stays open, as in pi.
