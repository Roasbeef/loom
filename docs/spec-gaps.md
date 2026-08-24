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
