# Distributed runtime: typed APIs and delivery plan

Status: **note, not a work package.** Proposed contracts accompanying
[the journeys and architecture](distributed-runtime.md), pinned to
`ae1a319a48aa3feed92f5f65efd09034df635675`. Public signatures and dependency
choices need review before implementation. No new library has been published.

## 1. Correctness by construction

The public API must represent valid operations directly. A caller cannot
assemble an active ownership grant from a node name and integer, represent a
handoff as unrelated Boolean flags, or turn a timed-out command into proof
that it did not execute. Types remove those construction paths; runtime
checks handle races and untrusted bytes that types cannot eliminate.

| Boundary | Proposed representation | Invalid construction prevented |
|---|---|---|
| User input | Opaque `WorkspaceId`, `RelativePath`, bounded command and budget constructors | Arbitrary strings cannot stand in for validated identifiers or paths. |
| Ownership | Opaque `OwnerGrant` returned by the authority service | A routing observation cannot become mutation authority. |
| Handoff | Phase variants carrying the evidence each phase requires | An active target without a verified cut cannot be represented by the reducer. |
| Launch | Prepared request followed by admitted execution handle | A remote timeout cannot be returned as a definite pre-launch refusal. |
| Completion | Separate outcome and native-custody variants | A process exit cannot substitute for descendant retirement. |
| Database mutation | Applied, rejected, or indeterminate outcome | A transport error cannot imply non-commit. |

Gleam's opaque types do not provide linear consumption or security against
arbitrary Erlang code in the same trusted VM. Duplicated handles and stale
epochs remain possible values. Every authoritative mutation revalidates the
current epoch atomically. Decoders are total and bounded, with named error
variants and no public `Dynamic` escape hatch.

Keep orchestration reducers pure. Put process lifecycle in weft and external
effects behind the broker. The remote adapter must preserve the current
`broker/dispatch` contract or propose its change explicitly. Public examples
must compile in CI once these APIs exist.

## 2. A Gleam Khepri library

**Recommendation: specify a narrow reusable binding, then evaluate reuse
before creating a repository.** An existing package,
[Capri](https://hex.pm/packages/capri), describes typed atomic Khepri bindings.
Its listed license is AGPL-3.0-or-later. We have not audited its implementation
or adopted it. Evaluate its API, dependencies and licensing fit explicitly;
the existence of a wrapper does not establish Loom's ownership semantics.

If a separate wrapper is justified, it must remain generic. Session ownership,
workspace epochs, user authorization and execution recovery belong in Loom.
The wrapper's job is bounded typed access to Khepri, including honest uncertain
outcomes. Model-authored code receives no direct cluster database capability.

The initial surface needs typed collection handles, exact keys, versioned
payload codecs, bounded reads and conditional mutations. Bind each collection
to its store, prefix and codec. Bind a read observation to its exact key and
revision; a conditional replacement accepts that observation rather than
independent caller-supplied version fields. Store identity mismatches still
require runtime validation because Gleam does not create a fresh type for
every store opened at runtime.

Use binary key components. Never intern user-controlled atoms. Provision
store identities from a bounded administrative configuration. Decode all FFI
responses into explicit domain errors, including incompatible responses and
corrupt data; cap the diagnostic details retained with an error.

### Proposed mutation flow

The following is API notation, not a compilable module or a shipped signature:

```text
read(collection, key) -> Result(Observation(value), ReadError)
prepare_replace(observation, replacement) -> Result(PreparedMutation, InputError)
submit(prepared_mutation) -> MutationOutcome
reconcile(pending_mutation) -> MutationOutcome

MutationOutcome =
    Applied(CommitReceipt)
  | Rejected(Rejection)
  | Indeterminate(PendingMutation)
```

An observation permits preparing an attempt; it does not promise the value is
still current. The committed conditional mutation decides that question.
The wrapper must not label a local read "linearizable" without establishing
that guarantee against the pinned Khepri API.

Prepare a stable operation ID and digest before submission. Persist the
operation receipt atomically with the mutation, or use a proven equivalent
upstream mechanism with the same retention contract. A timeout returns the
same pending operation, and reconciliation must never invent a fresh ID.
A not-yet-visible receipt is not proof that an in-flight command was refused.
Bound receipt storage and reject new admission when retention cannot be met.

Do not expose an arbitrary Gleam closure as a distributed transaction. Start
with closed declarative conditions and mutations, executed by a fixed,
deterministic adapter. Khepri transactions constrain calls and side effects;
the [transaction API](https://rabbitmq.github.io/khepri/khepri_tx.html) explains
why replicated execution requires these restrictions. An upstream transaction
bridge must be tested with the actual compiled Gleam/Erlang representation.

Avoid version-only ABA checks: deleting and recreating a key must not make an
old observation valid again. A wrapper envelope needs a non-reused creation
identity and revision, or an equivalent complete-value comparison. Loom's
authority records additionally retain monotonically advancing epochs and
must not be reset by ordinary record deletion.

The required FFI belongs in `internal/ffi_*.gleam`, with the smallest Erlang
adapter that the upstream API requires. Document why standard Gleam libraries
cannot express each external call. Do not add a second actor framework or
expose raw Erlang transaction terms for convenience.

### Style and lint are part of the library bootstrap

Copy Loom's `docs/gleam-style.md` and `packages/lint` with their provenance,
source commit and license notices into any new repository we own for this
work. Keep a short standalone addendum identifying which Loom-specific paths
and package names require adaptation. The copy must not silently weaken the
language, type or literate-code rules.

The lint package already uses public Gleam dependencies. Its repository
adapter needs inspection: package classification, qualified-domain imports,
portable packages and doc paths must recognize the standalone layout. Retain
all nineteen rules and the current error/warning tiers. Test rule violations
against the new layout so a passing command cannot mean it scanned no code.

Public functions need purpose, invariants and compiling examples. Public
types, variants and fields need documentation. Comments use complete sentences
and blank lines before stanzas. Preserve qualified domain calls, explicit
state transitions, no naked Boolean parameters/fields, total decoders and
the minimal-FFI policy. Provide architecture docs and mirrored package
`AGENTS.md`/`CLAUDE.md` files before calling the bootstrap complete.

## 3. Formal methods and the implementation bridge

Use each tool for a distinct question. None of the models proves that an
unmodeled operating system, network stack or database implementation behaves
correctly.

| Tool | Model boundary | Properties and deliberate limits |
|---|---|---|
| PlusCal/TLA+ | Session/workspace authority and controlled handoff | One effective owner across epochs; no target activation before verified freeze and cut; stale routes cannot grant ownership. Abstract metadata commits atomically. |
| P | Remote adapter, executor, helper and reconnect protocol | No duplicate launch on retry; uncertainty survives lost acknowledgements; stale cancel cannot hit a reused helper; durable terminal receipt precedes garbage collection. Model bounded queues and native retirement separately. |
| Lean | Small pure reducers after their contracts settle | Prove transition preservation and identity/epoch checks where worthwhile. Tie proofs to the production reducer through extraction or a pinned differential bridge. |

TLC explores the configured finite model; record the state bounds and fairness
assumptions. P explores controlled schedules under its configured bounds.
A Lean proof about a separately written model is not a proof of Gleam code.
The existing `protocol/models/terminal-attachment` documentation provides a
pattern for mapping abstract events to source and recording omissions.

Every model needs reachable happy paths, crash/partition counterexamples,
and mutations that demonstrably break its monitors. Replay representative
counterexamples against the real protocol tests. Keep the model-to-code
mapping versioned with the implementation, so a renamed state or changed
transition cannot leave a stale proof attached to new code.

Safety must hold during unbounded delay. Liveness requires explicit conditions:
eventual communication, an available metadata quorum when needed, enough
durable capacity and eventual native cleanup. A blocked handoff or unknown
outcome can be the correct safe result. Models must not assume a partitioned
executor has stopped merely because its supervisor is unreachable.

## 4. Dependency-ordered work packages

These are proposed ownership boundaries for Sol 6.1 workers after the design
review. Freeze the shared contracts first; avoid assigning two workers the
same integration module. Each substantive slice receives independent review
and real failure-path tests before integration.

| Work package | Owned responsibility | Prerequisites | Acceptance evidence |
|---|---|---|---|
| D0: protocol proposals | Identities, workspace operations, execution custody, budgets and result contracts | Reviewed design | Numbered proposals identify affected frozen interfaces and exact negative cases. |
| D1: authority model | PlusCal model and handoff reducer specification | D0 authority contract | Checked cross-epoch exclusivity, interrupted freeze and lost commit replies, with mutation witnesses. |
| D2: executor protocol model | P model and remote execution traces | D0 execution contract | Lost admission/result/cancel, restart, bounded queues and cleanup schedules. |
| D3: metadata spike | Khepri compatibility and wrapper decision | D0 authority operations | Three-member partition/restart/CAS/unknown-commit tests on supported OTP; resource measurements and upgrade behavior. |
| E1: workspace service | Executor-side filesystem/tool locality and local adapter | D0 workspace contract | Read/edit/Git/LSP/code mode observe one checkout; stale epoch and symlink escapes refused. |
| E2: remote transport | Explicit trusted executor enrollment, TLS BEAM and bounded streams | D0 wire contract; #703 stream bound | Wrong certificate/plaintext refusal, slow peer, aggregate bounds, satellite credential exclusion and cleanup independence tested with real helpers. |
| E3: durable custody | Executor ledger, admission, reconcile and receipt compaction | D0; D2 traces | Crash at each launch/receipt boundary produces correct outcome and no duplicate mutation. |
| E4: remote integration | Dispatcher and remote code-mode capability forwarding | E1, E2, E3 | Ordinary tools and code mode complete on another host; disconnect/cancel never fabricate cleanup. |
| E5: executor pools | Placement, capacity reservations, affinity and fair bounded admission | E4 | Linux/macOS compatibility and enforcement filtering; stale capacity, saturation and queued cancellation; no fallback to a different mutable checkout. |
| C1: ownership service | Typed wrapper if needed, registration and directory | D1, D3; style/lint bootstrap | Concurrent conditional transfers, unknown commits and restart fencing pass. |
| C2: trusted routing | TLS BEAM membership, ingress proxy and user checks | C1 | Entry through either node reaches one owner; stale routes and revoked users cannot mutate. |
| C3: messaging | Durable sender outbox, recipient dedup and event catch-up | C2 | Lost receipts/repeated delivery/owner movement preserve one logical admission. |
| M1: planned mobility | Verified state transfer and inactive target boot | E4, C1, C2; formal authority checks | Faults at every handoff phase preserve writer and native-custody invariants. |

D1, D2 and D3 can run independently after their contracts are settled. E1,
E2 and E3 can then proceed on disjoint modules. E4 is an integration task,
not another parallel rewrite of their modules. C1 does not gate the first
single-orchestrator remote executor. Automatic failover and workspace snapshot
migration remain separate later designs.

E5 permits one orchestrator to manage registered executors and place independent
sessions on their respective workspaces. A single session that runs a GPU step
and then consumes its output on a Mac needs an additional target and artifact
contract, tracked in [#825](https://github.com/Roasbeef/loom/issues/825). That
contract must name the exact secondary workspace and input manifest before
execution, preserve the admitted target across recovery, and transfer bounded,
verified artifacts. Multiple connected nodes alone do not provide those semantics.

Protocol proposals must cover the remote dispatcher/wire, workspace identity
and operations, capability forwarding, client routing/command reconciliation,
and clustered ownership transitions. Reuse existing interfaces where their
semantics suffice. Assign proposal numbers against the current tree when
filing them, rather than reserving numbers in this note.

## 5. Decisions to validate before implementation

The recommended first product is an authenticated client controlling an
executor-resident workspace through one orchestrator. The cluster extension
adds conditional ownership metadata and controlled handoff, while session
content stays in SQLite. The wrapper spike must establish Khepri's fit before
we create or adopt another public API.

The design gate is an independent review of these contracts, including the
phone/remote-workspace journeys. The implementation gate is stronger: current
head checks, real remote-host execution, failure injection and model-to-code
evidence. A design review alone grants no claim that the distributed runtime
has been built or formally verified.

## 6. Design review record

An independent adversarial review on 2026-10-04 assessed the working-tree
proposal against the pinned source and issue #697. It found no material
defect in the proposed freeze/activation ordering, delayed-request fencing,
uncertain-launch handling or receipt retention contracts. It also confirmed
that the document distinguishes existing multiplayer from executor placement
and states the limits of type safety and formal proofs.

The review identified one plan-coverage gap: multiple-executor scheduling had
no assigned work package. Comparing the table with #697 Part C and Phase 2
confirmed the omission. E5 now owns placement compatibility, capacity
reservation, bounded fair admission and queued cancellation. The architecture
note also states those invariants. This is proposal review only; implementation
and formal verification remain unperformed.
