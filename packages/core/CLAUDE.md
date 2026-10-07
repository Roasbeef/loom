# core

## Workspace identity

`workspace` supplies the pure local-or-registered selection and binding types
for protocol 067. A registered scope contains the existing session ID, executor
and workspace labels, and both authority epochs. Smart constructors bound labels,
epochs, relative paths and external step names; they neither resolve a host nor
grant access. `WorkspaceKey` groups sessions by stable local path or registered selector,
while `Binding` retains both authority epochs. `decode_key` preserves local SQL
path spelling and validates the disjoint `registered:<executor>:<workspace>`
identity. The closed binding JSON codec admits neither unknown fields nor
invalid epochs. Local paths retain their existing semantics. Remote paths use
forward slashes, reject traversal and host-dependent separators, and name the
root explicitly with `.`. The executor checks filesystem containment and current
authority at use. `scope_from_fields` validates the executor identity module's
projected fields without adding an executor dependency or I/O to core.

## Purpose

The vocabulary every other package shares: opaque ids, the write-once
durable rows, the closed register-namespace set, the transaction types, and
the two total codecs (JSON and msgpack) that guard every durability and
wire boundary. WP-A, and the root of the dependency DAG — `core` depends on
`gleam_stdlib` and nothing else, not even `gleam_erlang`.

## Key Types

- `core/ids.{EntryId, UsageId, OpId, SessionId}` — distinct opaque UUIDv7
  wrappers, so an `EntryId` can never be passed where an `OpId` belongs.
  `Generator` mints them purely from an injected `Clock` plus a seeded
  SplitMix64 state; `mint_follower` reuses a parent's 48-bit time prefix
  with a fresh random tail. `SessionId` (`protocol-change/008`) names a
  whole session rather than a row in one — minted once at session
  creation, persisted by `session`, and what the event bus keys by.
- `core/entry.Entry` — the four write-once row shapes (`MessageEntry`,
  `CompactionEntry`, `BranchSummaryEntry`, `CustomEntry`), placement fields
  and payload together. `UsageRow` is the ledger row.
- `core/message.Origin` distinguishes human attribution from peer-agent
  attribution. `Origin(principal, name)` preserves the human identity admitted
  under protocol 016. `PeerOrigin(session, strand)` records the host-bound peer
  sender under protocol 048. `StrandOrigin(strand)` records a strand of the
  same session that sent the message through the Agency (protocol 059; the
  Agency writes it from the authenticated caller, in the same release that reads it). All
  carry attribution only, without credentials or authority. Historical
  unattributed turns remain `None`.
- `core/origin` owns validation, encoding, decoding and presentation of that
  field. Human records keep their legacy untagged encoding; peer records use
  `{kind: "peer", session, strand}` and strand records
  `{kind: "strand", strand}`, validated by `validate_strand` with the bounds
  of a peer's strand. A malformed present origin is corruption.
  `stable_identity` of a strand is `strand:` plus its id, which no human
  principal can equal. `project` adds an explicit human or peer-agent label at
  the provider boundary while preserving stored content, and leaves a strand
  message's content unchanged so the model sees only the Agency's framing.
  `display_label` gives existing client views
  an explicit peer label instead of treating a strand name as a human name.
- `core/todo_list.{Board, Phase, Task, Status}` — a strand's todo board,
  kept here because three readers on two sides of a wire need one shape:
  the `todo` tool writes it, the blackboard cell `agent/{strand}/todo`
  stores it, and the TUI decodes it from the tool result's `details` to
  draw the pinned panel. `decode` is total and answers a
  `CorruptionReport`; `validate` is the writer's check (bounds, blank text,
  unique phase names and unique task text across the board), and every
  stored board has passed it because the tool is the cell's only writer.
  `active`, `focus` and `count` answer the questions a renderer asks.
- `core/glance.Glance` — a strand's operator-facing title and one-line
  activity summary, written by the daemon's glance loop under the reserved
  `client/glance/{strand}` fact and read by the TUI's agent strip from each
  capture. It names the operation it describes, so a reader drops it once
  that operation is no longer current. `tokens` is the operation's
  current context size from its newest usage row, a replacement value and
  never a sum, so a reader may swap in a newer live figure. `decode` is
  total; `clip` is the writers' one-line, byte-bounded, grapheme-safe cut
  for model text.
- `core/register.{RegisterNs, RegisterValue}` — the closed namespace enum
  and the thin tagged JSON wrapper storage persists. The rich payload types
  each namespace forces live in `machine`; `core` understands only
  `StrandLeaf`'s `Option(EntryId)`.
- `core/tx.{Write, Tx, SeqExpectation, CommitResult, CommitError}` — the
  unit of durability: an ordered write list applied all-or-none under
  optimistic seq expectations. `CommitError` carries four refusals, and
  the fourth is newer than the frozen sketch: `LeaseLost(held_by:)` says
  the committer is no longer the session's writer, which is the one
  refusal no reload and no retry can get past
  (`protocol-change/005`). `tx.describe_lease_loss` is the single place
  it is worded for humans, so every layer that has to flatten one into
  prose says the same thing.
- `core/json.JsonValue` — a pattern-matchable JSON ADT with a total parser,
  defined here rather than borrowed so pure code can inspect the `Json`
  named in the frozen contracts. `ParseProfile(StandardJson | RegisteredLspJson)`
  and additive `parse_profile` share the same grammar. Ordinary `parse` retains
  Standard behavior; Registered input charges keys and values before allocation
  against a single 200,000-node ceiling, preserving depth 256. The transport
  caller supplies its byte ceiling (protocol 078).
- `core/msgpack.MsgPackValue` — the canonical msgpack subset the
  effect-plane framing protocol uses (ADR-003).
- `core/bounded_msgpack.decode` applies the fixed remote wire profile before
  `core/msgpack` allocates terms: 256 KiB total, depth 16, 2,048 total nodes,
  128 array elements/map entries, 8 KiB strings and 128 KiB binaries. Its
  shared node budget covers the complete tree, including map keys.
- `core/corruption.CorruptionReport` — the single error type every total
  decoder returns.
- `core/clock.Clock` — the injected time capability; reading returns
  `#(now_ms, successor_clock)`.

## Relationships

- **Depends on**: `gleam_stdlib` only. No `gleam_erlang`, no `gleam_otp`,
  no `simplifile` — the purity of this package is structural, not a
  convention.
- **Depended on by**: every other Gleam package (`storage`, `session`,
  `machine`, `runtime`, `provider`, `broker`, `tools`, `conformance`).
- **FFI**: none. There is no `internal/ffi_*` module here and there must
  not be one; `Clock` and `Generator` take injected functions instead, so
  impurity belongs to whoever constructed them. Nor is there an
  `@external` of any target, nor `gleam_erlang` or `gleam_otp` in
  `gleam.toml` — by rule, not by coincidence.
  Two properties rest on that, and one `@external` closes both: purity is
  what makes the state space property-testable without spawning processes,
  and the same discipline is what keeps this package compiling to the
  **JavaScript target**. Lint R6 gates on it at error level and its census
  must stay zero. Portable here means *decide but not act* — replay a
  conversation tree, validate a transcript with the server's own total
  decoders, run `next_action` over fetched state — and never the harness in
  a browser: `gleam_otp` has no JavaScript target, Rule Zero is
  kernel-enforced (in a browser the harness VM and the untrusted-code VM
  would be the same VM), and the two-channel doctrine needs processes on
  both sides. `docs/gleam-style.md` Part IV §5 argues it in full.

## Traffic

- **Actor messages**: none. `core` spawns nothing and imports no process
  primitives.
- **Commits**: defines the `Write` vocabulary (`InsertEntry`,
  `InsertUsage`, `SetRegister`, `DeleteRegister`) and `SeqExpectation`;
  performs none.
- **Registers**: defines the closed set — `strand.leaf`, `strand.config`,
  `strand.state`, `strand.last_result`, `op.meta`, `op.state`,
  `op.tool_args`, `op.preparation`, `pending.entry`, `fact.name`,
  `fact.label`, `fact.custom` — and their string forms via
  `ns_to_string` / `parse_ns`.
- **Wire**: `core/codec` is the JSON durability codec for every durable
  core type, using pi's exact field vocabulary (`parentId`, `cacheRead`,
  `stopReason`, `retainedTail`) per ADR-001 so a format-4 import is a
  mechanical decode-and-re-mint. Its public `encode_user_block` and
  `decode_user_block` functions let ClientGateway carry that same block shape
  without reimplementing it. `core/msgpack` is the effect-plane framing codec,
  golden-pinned under `protocol/msgpack-fixtures/`. `core/bounded_msgpack` is
  the stricter pure raw preflight shared by remote wire codecs; it rejects
  trailing or malformed raw data before delegating semantic decoding.

## Invariants

- **Decoding is total everywhere.** Every decoder returns
  `Result(t, CorruptionReport)`; wrong shapes and wrong types are reports,
  never crashes. Partial decoding is a bug class, not a style choice
  (spec §0.2).
- **Adversarial input is bounded at both codecs.** JSON and msgpack
  containers nest at most `max_depth` (256) levels; `CorruptionReport`
  truncates its context excerpt to `max_context_length` (256) graphemes;
  msgpack rejects non-byte-aligned bit arrays and trailing bytes.
- **Duplicate keys are corruption, in both codecs.** Decoders disagree on
  first- versus last-occurrence precedence, so a document or frame
  carrying duplicates has no single meaning; rejecting is the only rule
  with one interpretation.
- **JSON string runs preserve byte boundaries.** `json.clean_run` and
  `json.escape_runs` advance four safe bytes together; each byte is checked
  for quote, backslash and C0 controls. An exceptional chunk resumes the
  single-byte step, and slices are still UTF-8 validated. Independent
  codepoint-oracle and raw-input refusal tests cover every escape/control
  byte at varied ASCII and multibyte offsets.
- **msgpack encoding is canonical** — smallest encoding that fits — so
  equal values always produce identical bytes. The Go helper's strict
  decoder and the golden fixtures both depend on this.
- **Non-finite floats are corruption**, in JSON and msgpack alike: the
  BEAM cannot represent NaN or infinity. JSON ints are arbitrary
  precision; msgpack ints outside `[-2^63, 2^64-1]` are encode errors.
- **A tool call's arguments are always a JSON object, even when the model
  did not send one.** Argument text the streaming adapters could not parse
  settles as `message.malformed_arguments`, an object under the reserved
  `malformed_arguments_field` carrying the raw text and the parser's
  complaint. That keeps the durable value replayable — the Anthropic and
  Gemini dialects refuse a tool call whose input is not an object — and
  gives `machine/planner` something to recognize and refuse in-band
  (issue #189). The raw excerpt is bounded at the constructor, as
  `corruption.report`'s context is, because it is unparsed model output
  that a durable entry replays on every later turn.
- **Minting is pure and reproducible.** The same `Generator` value always
  mints the same ids; the runtime seeds it from real entropy, tests from a
  constant. Production wiring must supply seeds that never repeat within a
  session lifetime or re-minted ids could collide with committed ones
  (spec-gaps WP-E item 6).
- **Tool-result ids inherit the assistant id's time prefix**
  (`mint_follower`), so a call-and-results group stays time-cohesive under
  id order even across a midnight boundary (pi §1.2 rule 2).
- **Entries are write-once.** The types carry no update path; writing under
  an existing id is corruption at the storage layer, not an update.
- **A present but malformed origin is corruption, never an anonymous
  fallback.** `origin.decode_field` reads an absent field and an explicit
  `null` as `Ok(None)`, but a present object that fails `validate` is an
  `Error`. Degrading it to `None` instead would erase an author the
  transcript does say it had, and would make a truncated or forged record
  indistinguishable from a genuinely unattributed turn
  (`protocol-change/016`).

## Deep Docs

- [docs/architecture/durability.md](../../docs/architecture/durability.md) —
  the durability plane: stores, identity, transactions, expectations.
- [docs/adr/001-agent-message-fidelity.md](../../docs/adr/001-agent-message-fidelity.md)
  — why the message family mirrors pi's shapes field for field.
- [docs/adr/003-msgpack.md](../../docs/adr/003-msgpack.md) — why the
  msgpack codec is self-contained pure Gleam.
- [docs/spec-gaps.md](../../docs/spec-gaps.md) — "From WP-A (`core`)":
  the mint signature, `RegisterValue` representation, numeric edges.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.

## Code-mode utilities

`core/json_wire` converts the shared JSON and msgpack value types. It refuses
binary data, non-text or duplicate object keys, and excessive nesting on the
msgpack-to-JSON path. The satellite report helpers and host note/orchestration
routers share this pure conversion.

## Remote tool identity (protocols 067 and 071)

`core/remote_tool.ToolKey` is opaque and contains the session, operation,
step, source index, canonical effective-argument SHA-256 digest and reserved
result-entry identity. Its logical address excludes the digest and result ID
so a changed immutable identity finds the existing fence and conflicts. The
owner computes the hash with an existing effect-layer facility; this module
adds no I/O, FFI or BEAM dependency. Names, digest spelling and indices are
bounded before construction. `ChildOrigin` distinguishes Original Compile, rewritten Compile, Launch,
capability ordinal and explicit system service origins; connection generation
is absent from both tool and child identity.

`child_fields` projects complete checked Tool or System coordinates without
parsing a logical address. `encode_child` and `decode_child` carry every original
parent field and closed role in a versioned, canonical MessagePack value, bounded
to 8192 bytes and scanned before term allocation. The nested value codec serves
LSP headers and generation links. These codecs leave existing addresses unchanged
and grant no live admission authority.

`core/generation` defines the shared immutable GenerationKey and association for
protocol 079. A key includes the full workspace Scope, descriptor digest and
positive signed-32-bit generation. Its association retains the enrollment digest,
original owner-use UUID and closed FirstGeneration or predecessor-digest pair.
Canonical frames are bounded to 1024 bytes. `checked_successor` requires g+1,
unchanged scope/descriptor/enrollment, a distinct owner-use UUID and both exact
predecessor digests. These are pure identity checks; the executor registry and
owner companion still own durable evidence, authentication and live claims.

Parent tool steps validate with `core/workspace.step` and its 1024-byte UTF-8
bound; explicit system service names retain their independent 128-byte bound.
`remote_tool.operation` and `remote_tool.step` expose original parent coordinates
for broker clearance without deriving them from physical child operation names.

The Workspace ordinal is a separate ChildRole beside Compile, CompileRewrite,
Launch and Capability. Its encoded address cannot alias those roles. `provenance` and
`child_role` expose validated identity to the owner binding without granting
effect authority or deriving fresh operation coordinates.

The ChildRole variants `remote_tool.CompileCommand`, `CompileRewriteCommand` and
`SatelliteCommand` distinguish concrete native origins from their Compile, CompileRewrite and Launch
service origins. `AdmittedCapability` carries
its trusted capability name, ordinal and `CapabilityPurpose` (SemanticWorkspace
or NativeCommand); every field participates in the child address. The address
encoding bounds and escapes each component so names and delimiters cannot
alias another role. This adds no dynamic admission authority and leaves the
original 64-row ceiling unchanged.



## Workspace command child identity (protocol 079)

`workspace_command_child` wraps only a direct `Workspace(n)` or actual direct
`SystemChild` with one closed `WorkspaceCommandPhase`. `WorkspaceCommandFields`
projects that complete parent and phase. Nesting and unrelated roles refuse;
the complete canonical frame still fits 8192 bytes. The new tag and escaped
address leave all existing encodings and addresses unchanged. `child_parent`
projects the original quota group, so the wrapper cannot obtain another group.
The existing admitted `SemanticWorkspace`/`NativeCommand` pair keeps its original
representation. Identity construction grants no admission or execution authority.

The fixed phase vocabulary covers the declared Git operations and explicitly
names `WorkspaceInitialize`. The owner binding refuses Initialize until a real
bounded recipe exists. `lsp_command` explicitly refuses the new child family at
both direct parent checks; it does not reinterpret the wrapper as a system child.


## Registered LSP identity (protocol 078)

`lsp_command` retains complete original child and parent-control references.
`LspServiceKey` owns the separate startup lease family; `FiniteCapture` keeps
the original semantic input, enrollment and parent before timing exists.
`verify_parent_control` compares the actual complete parent before a
`FiniteTimingProposal` can join that capture. Ordinary finite captures require
ToolOrigin; the system LSP origin is restricted to AfterWrite with its complete
PostWriteControl. Startup and Search commands cannot exchange parent families.

The private scanner has separate fixed LSP header, request and result profiles.
Value decoders recover bounded immutable data, never a live claim, consumed
nonce or physical authority. The executor adapter owns canonical hashing;
the future custody writer must authenticate the original parent, clock era,
nonce and enrollment before admitting an effect. Core remains free of I/O and
FFI, including for these timing values.

## Physical service and command identity (protocols 067 and 071)

`core/command.ServiceKey` retains the original managed ToolKey, closed
CompileService/LaunchService purpose, full registered scope, parent's operation,
explicit physical step, original outer request UUID and exact input/enrollment/
contract digests. `CommandRef` pairs CompileService with CompileCommand or
LaunchService with SatelliteCommand. Its deterministic address excludes content;
changed input reaches the original fence rather than another row. The native
origin remains disjoint from its outer service. No offer UUID is allocated.

Original Compile retains the exact version-1 key encoding and addresses.
`rewrite_service_key` creates the only second attempt from an exact Original
predecessor and a distinct UUID; parent, operation, step, enrollment and contract
remain unchanged. Version 2 embeds that complete version-1 predecessor, and its
total decoder refuses recursive Rewrite lineage. `compile_predecessor` exposes
the checked relation. The CommandRole purpose remains CompileCommand for both
builds; the checked key selects the distinct ChildRole CompileRewriteCommand
native origin. These constructors do not validate compiler diagnostics or
grant clearance. See [remote Compile attempts](../../docs/architecture/remote-compile-attempts.md).

Smart constructors reject different parent session/operation, invalid digest
spelling and crossed role pairs. Closed versioned JSON decoders return bounded
CorruptionReport values and reconstruct through the same constructors. These
values express identity only; hashing, policy acceptance, broker clearance,
retention and actual execution remain outside this pure package. System/LSP and
capability command identity are deliberately absent from this fixed-role slice.

## Complete code-mode reports (protocol 067)

`core/report_value` separates a terminal `Outcome` from its trusted `Metadata`.
Opaque `CompleteReport` values contain a checked canonical terminal value,
original `sha256-` artifact fingerprint, enforcement observations and bounded
call log. The metadata validator preserves the compiler spelling; the report URI
instead carries a bare lowercase digest of the complete bundle. The raw scanner
checks shared byte, node, container and nesting budgets before MessagePack
allocation. Term constructors apply the same budgets before encoding; JavaScript
nonfinite floats are refused explicitly. The fixed `LOOMRV01` bundle carries
independently bounded terminal and metadata segments. The native wire profile
in `bounded_msgpack` keeps its existing smaller limits.

`ReportRef` names a session, reserved result entry, digest and byte length. Its
constructor validates canonical shape only. Storage and the authenticated owner
router must establish existence, association, digest and read authority. No
reference opens a path or grants a capability by itself. Core performs no hash,
SQL, process or filesystem operation.

The core gate runs both the Erlang tests and a small Node regression for values
that BEAM cannot represent. The supplemental JavaScript build retains existing
unsafe-u64 warnings; it does not establish exact u64 custody on JavaScript's
Number representation. The Erlang build remains warning-free. The complete
retention and read path is described in
[distributed-final-results.md](../../docs/design-notes/distributed-final-results.md).

## Raw transport scanning

`internal/msgpack_scan` can locate an encoded transport value without building
its MessagePack tree. The broker uses this scan to preserve the original body
bytes while validating the small envelope header. Terminal report validation
then applies its own shared node and depth budgets before generic allocation.
Transport scanning preserves field order and nonminimal header encodings; it
does not certify body UTF-8, duplicate keys or terminal semantics.

The scanner's sibling loop uses direct tail recursion on JavaScript. This does
not repair the separate generic MessagePack decoder's large-sibling stack limit
on that target, nor does it establish exact JavaScript u64 representation.

## Registered JSON target boundary

The Registered LSP profile is consumed by the BEAM-only LSP actor. Erlang tests
admit exactly 200,000 aggregate keys/values and refuse the next node. JavaScript
compilation and existing finite-report/command controls pass. An additional
199,999-null array probe raised `RangeError: Maximum call stack size exceeded`
with both Standard and Registered profiles: the pre-existing generic JSON sibling
parser recurses under result callbacks. This additive profile does not restructure
that parser, and these gates do not establish exact-limit JSON runtime success on
JavaScript. Ordinary syntax/number/string/error semantics remain shared.
