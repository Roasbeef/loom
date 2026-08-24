# Loom — implementation specification v0.1

*Companion to `loom-design.md` v0.2. This document decomposes the design into **work packages (WPs)** suitable for parallel implementation by coding agents. Each WP states its scope, the interfaces it consumes and exposes, its exit criteria, and what it must NOT do. Interface contracts in Part 1 are frozen first; everything else parallelizes against them.*

**Normative language**: *must / must not* are requirements; everything else is guidance. Where this doc conflicts with the design doc, this doc wins for mechanics, the design doc wins for intent.

---

## Part 0 — Repository layout, conventions, agent protocol

### 0.1 Monorepo layout

```
loom/
├── packages/
│   ├── core/        WP-A  ids, entries, registers, tx, codecs  (pure)
│   ├── storage/     WP-B  Storage behaviour, Memory, SQLite, lease
│   ├── session/     WP-C  Session/Repo, tree views, branch index, forks
│   ├── machine/     WP-D  operation ADTs, next_action, classification (pure)
│   ├── runtime/     WP-E  StorageWriter, StrandSup, driver loop, recovery
│   ├── provider/    WP-F  provider SDK, streaming, routing, retries
│   ├── broker/      WP-G  ToolBroker, tokens, policies, exec protocol
│   ├── sandbox/     WP-H  helper binary (Go) + platform drivers
│   ├── tools/       WP-I  bash, fs+hashline, grep; later lsp, dap
│   ├── codemode/    WP-J  vet lint, prelude, satellite proto, compile svc
│   ├── cap/         WP-J  the cap/* prelude (separate build target)
│   ├── events/      WP-K  EventBus, projections, search service
│   ├── client/      WP-L  ClientGateway protocol + server; TUI
│   ├── ext/         WP-M  ExtensionZone, skill store, promotion
│   └── conformance/ WP-T  shared test suites, chaos & interleave harness
├── protocol/             frozen wire schemas (this doc, Part 1) as source of truth
└── scripts/              dev scripts, CI, fixture repos for sandbox tests
```

Package names are unprefixed: they are monorepo-internal and never
published, so the short names cannot collide on Hex, and each package still
namespaces its modules under its own directory (`core/entry`,
`runtime/strand`). If a package is ever published (the `cap` prelude is the
plausible candidate), it takes a `loom_`-prefixed name at that point.

Dependency DAG (→ = depends on):

```
A → (nothing)
B → A            C → A,B,D        D → A            T → A..(all, test-only)
E → A,B,C,D,F    F → A            G → A            H → G(protocol only)
I → G            J → G,I          K → A,B          L → A..K(thin over all)  M → E,G,J
```

**Parallelization**: after WP-A freezes, {B, D, F, G, H} proceed fully in parallel; {C} after B's behaviour and D's register codecs land; {E} after B+C+D+F; {I, J} after G's protocol section (Part 1.4) — which is frozen *here*, so they can start immediately against mocks. T grows continuously.

*(DAG as built, updated from the original sketch: C reads machine's
register codecs for typed access; E consumes provider's stream and
retry contracts for the effects seam; G's usage types turned out to
live in core, decoupling it from F; K never needed the session layer; L,
as the surface that serializes every other plane, legitimately reads
storage, machine, provider, and broker alongside runtime and events.)*

### 0.2 Conventions (all WPs)

- Gleam `>= 1.11`, Erlang/OTP `>= 27`. `gleam format` enforced; no warnings.
- Every public function documented; every ADT constructor's invariants stated in its doc comment.
- **Total decoders**: every durability/wire boundary uses `Decoder(t)` returning `Result(t, CorruptionReport)`. Partial decoding is a bug class, not a style choice.
- **No `panic`/`let assert` outside tests** except for documented invariant violations that must fault the process (mirrors pi's "failed admitted commit faults the harness").
- Erlang FFI: confined to `*/internal/ffi_*.gleam` modules; every `@external` carries a comment naming the OTP function and why no pure alternative exists. CI greps enforce confinement.
- Time: all timestamps Unix ms, from an injected `Clock` capability (testability). Ids: UUIDv7 from an injected generator; tool-result ids inherit the assistant id's 48-bit time prefix (pi §1.2 rules 1–3).

### 0.3 Agent working protocol (for the implementing agents)

- One WP = one long-lived branch; land via PRs cut at exit-criteria boundaries.
- **Interfaces in Part 1 are frozen.** A WP needing an interface change files a `protocol-change/NNN.md` proposal; no silent drift. Mock implementations of every Part-1 interface live in `conformance` and are the substitute until the real WP lands.
- Every WP ships its own tests + registers into the conformance suite where applicable. A WP is done when its exit criteria pass in CI on Linux and macOS (Windows: WP-H phase 3 only).

---

## Part 1 — Frozen interface contracts

### 1.1 Core types (WP-A exposes; everyone consumes)

```gleam
// core/ids
pub opaque type EntryId    // UUIDv7; constructors: mint(Clock), mint_follower(EntryId)
pub opaque type UsageId
pub opaque type OpId
pub type Seq = Int         // storage-assigned, strictly increasing per session

// core/entry
pub type Entry {
  MessageEntry(id: EntryId, parent: Option(EntryId), seq: Seq, ts: Int,
               message: AgentMessage, terminate: Bool)
  CompactionEntry(id: EntryId, parent: Option(EntryId), seq: Seq, ts: Int,
                  summary: String, retained_tail: List(AgentMessage),
                  tokens_before: Int, from_hook: Bool, usage: Option(Usage))
  BranchSummaryEntry(id: EntryId, parent: Option(EntryId), seq: Seq, ts: Int,
                     from_id: Option(EntryId),   // None = summarized from root
                     summary: String, from_hook: Bool,   // (protocol-change/001)
                     usage: Option(Usage))
  CustomEntry(id: EntryId, parent: Option(EntryId), seq: Seq, ts: Int,
              custom_type: String, data: Option(Json))
}

// core/register — closed namespace enum; the value type is forced by it
pub type RegisterNs {
  StrandLeaf      // key: strand name        → Option(EntryId)
  StrandConfig    // key: strand name        → StrandConfiguration
  StrandState     // key: strand name        → StrandState
  StrandLastResult
  OpMeta        // key: op id            → Operation      (write-once)
  OpState       // key: op id            → OperationState (the PC)
  OpToolArgs    // key: op:step:idx      → Json           (write-once)
  OpPreparation // key: op:task          → StructuralPreparation (write-once)
  PendingEntry  // key: reserved EntryId → PendingEntry
  FactName | FactLabel | FactCustom
}

// core/tx
pub type Write {
  InsertEntry(Entry)                  // seq/ts assigned by storage at commit
  InsertUsage(UsageRow)
  SetRegister(ns: RegisterNs, key: String, value: RegisterValue)
  DeleteRegister(ns: RegisterNs, key: String)
}
pub type Tx { Tx(writes: List(Write),
               expected: List(SeqExpectation)) }   // optimistic CAS (§1.2 rule 4)
pub type SeqExpectation { Expect(ns: RegisterNs, key: String, seq: Option(Seq)) }
pub type CommitResult { CommitResult(first_seq: Seq, seqs: List(Seq), ts: Int) }
pub type CommitError { StaleExpectation(failed: SeqExpectation)
                       Corruption(report: CorruptionReport)
                       Faulted(reason: String) }
```

### 1.2 Storage behaviour (WP-B implements; C/E consume)

```gleam
pub type Storage(handle)
pub fn commit(h, tx: Tx) -> Result(CommitResult, CommitError)
pub fn get_entries(h, ids: List(EntryId)) -> Result(Dict(EntryId, Entry), StorageError)
pub fn get_register(h, ns: RegisterNs, key: String) -> Result(Option(Register), StorageError)
pub fn list_registers(h, ns: RegisterNs, key_prefix: Option(String)) -> ...
pub fn scan_branch(h, q: BranchScan) -> Result(List(Entry), StorageError)
pub fn scan_entries(h, q: EntryScan) -> ...
pub fn scan_usage(h, q: UsageScan) -> ...
pub fn stats(h) -> Result(SessionStats, StorageError)
pub fn close(h) -> Result(Nil, StorageError)
```

Rules (normative, from pi Part 1, unchanged unless noted):
1. All-or-none commits; strictly increasing seqs, gaps legal; writes apply in order within a tx.
2. Writing an entry/usage under an existing id is corruption, not update.
3. Register set replaces; delete removes; delete-absent is a no-op; no history.
4. **Loom addition — CAS**: before applying writes, evaluate `expected`: each names the register seq the committer computed against (`None` = must not exist). Any mismatch → `StaleExpectation`, nothing applied. This subsumes pi's "conditional transitions identify state by register seq."
5. SQLite: `BEGIN IMMEDIATE` always; writer lease table with fenced ownership; one DB file per session; branch index per pi §2.6 with asserted query plans (`CROSS JOIN` driving from `branch_entries`; any `TEMP B-TREE FOR ORDER BY` is a CI-failing regression).

### 1.3 Operation machine (WP-D pure; WP-E drives)

WP-D ports pi Part 3 wholesale into ADTs. The full state space (RunPhase incl. checkpoint/assistant/tools/compaction/deferred/failure_drain; Generation ready/effect_pending/retry_wait; ToolBatch with per-call planned/effect_pending/completed; Inbox; Control; structural decisions) is a direct transcription — WP-D's job is fidelity, not invention. Key signatures:

```gleam
pub fn next_action(op: Operation, state: OperationState, in: PlannerInputs) -> Action
pub fn classify(settled: SettledAssistantMessage, ctx: ClassifyCtx) -> Classification
pub fn accept_prompt(...) -> Result(AcceptancePlan, RejectReason)
// Action = Transition(next, tx) | Dispatch(intent, next, tx)
//        | AwaitEffect(key) | Wait(until) | Finish(result, tx)
//        | Fault(report)                       // (protocol-change/002)
// tx carries the writes plus the CAS expectations that guard them; a pure
// total planner surfaces corrupt input as Fault rather than crashing.
```

Normative order of `classify` (first match wins): cancelled-control → overflow (adapter-reported | message-pattern | length-below-intended) → deferred-valid-handle → retryable-error → tool-use → stop/genuine-length. Overflow-classified responses commit normalized to `error` (context projection then drops them by the standard error rule). Aborted stop reason with running control is corruption.

### 1.4 Effect-plane wire protocol (WP-G owns; H, I, J implement against; **frozen now**)

All data-plane channels (executors, satellites, LSP/DAP adapters, remote pools) use one framing:

```
frame    := u32_be length ++ msgpack(map)
map keys := "v":1, "id":u64, "kind":str, "body":map
kinds    : hello, exec_start, exec_stdin, exec_out, exec_exit,
           cap_call, cap_result, cancel, heartbeat, error
```

- `hello` carries `{proto: 1, peer: "exec-helper"|"satellite"|..., features: [..]}`; version mismatch → close.
- `exec_start.body`: `{argv, env, cwd, policy: SandboxPolicyV1, token, limits}`. `exec_out` streams chunked stdout/stderr with per-stream byte counters; helper truncates at `limits.output_bytes` and reports truncation.
- `cap_call.body`: `{token, cap: "fs.read"|..., args: msgpack, deadline_ms}`; `cap_result`: `{ok|err, value|error, usage?}`.
- `cancel` is idempotent; receiver must kill its pgroup within 2s or the broker escalates to SIGKILL of the whole helper.
- **Tokens** are 32-byte random values minted by the broker, valid for one `{op_id, step_id}`, transmitted only over the channel they authorize, checked on every `cap_call`. Revocation list is broker-local.

`SandboxPolicyV1` (msgpack map, versioned):

```
{ v:1, writable_roots:[path], readable_roots:[path], protected:[path],
  network: {mode:"off"} | {mode:"proxy", allow:[host_glob], proxy:addr}
          | {mode:"full"},
  limits: {cpu_s, wall_s, mem_bytes, pids, fsize_bytes, output_bytes},
  env_allow:[name], scratch:"tmpfs"|path }
```

### 1.5 Provider gateway (WP-F)

```gleam
pub fn request(gw, req: ProviderRequest) -> StreamHandle
// events: Delta(TextDelta|ToolCallDelta|ThinkingDelta) | Settled(SettledAssistantMessage, Usage) | Failed(ProviderError)
pub fn resolve(gw, role: Role) -> Result(ResolvedModel, MissingIdentity)
// Role = Main | Subagent | Plan | Summarize | Vision | Custom(String)
```

Fallback chains resolve at dispatch; the durable state stores the resolved `{provider, model_id}`. Adapters must map provider stop reasons totally; unknown → `Failed(UnmappedStopReason)` (in-band), never a crash. Adapter-computable overflow (input+cache_read > context_window, negligible output) settles as `error` with the canonical overflow message pattern.

### 1.6 Client protocol (WP-L; thin clients)

Websocket, JSON (client-friendliness beats msgpack here), versioned:

```
c→s: {v:1, id, cmd: "prompt"|"steer"|"follow_up"|"abort"|"approve"|"deny"
              |"fork"|"navigate"|"compact"|"create_strand"|"set_config"
              |"subscribe"|"catch_up", body}
s→c: {v:1, reply_to?, event: "snapshot"|"entry"|"op_transition"|"stream_delta"
              |"usage"|"escalation"|"strand_result"|"error", seq?, body}
```

`subscribe{session, from_seq}` → `snapshot` (strands, leaves, open ops, recent entries) then live events; reconnect = `catch_up{from_seq}` (events are rebuildable from `scan_*`). Stream deltas are ephemeral (never persisted; pi's non-goal preserved) and flagged `ephemeral:true`.

---

## Part 2 — Work packages

### WP-A `core` — types & codecs *(no deps; freeze first)*

**Scope**: everything in §1.1; `AgentMessage` model (user/assistant/tool-result + custom roles with registered runtime schemas); msgpack + JSON codecs; UUIDv7 generator (follower minting); `CorruptionReport`.
**Must not**: perform I/O; import anything but stdlib.
**Exit**: property tests — codec roundtrip for every type (incl. adversarial junk → decode error, never crash); UUIDv7 ordering & follower-prefix laws; ≥95% branch coverage on decoders.

### WP-B `storage` — backends

**Scope**: Storage behaviour; Memory backend (maps + children index); SQLite backend (schema below); writer lease; JSONL import shim for pi format-4 (read-only, re-mints ids — see Follow-ups).
**SQLite schema** (from pi §1.7, plus CAS support is free since seqs are stored):

```sql
entries(id TEXT PK, parent_id TEXT, seq INT, type TEXT, custom_type TEXT,
        ts INT, payload BLOB) WITHOUT ROWID;
CREATE INDEX ix_entry_parent ON entries(parent_id);
CREATE INDEX ix_entry_seq ON entries(seq, type);
registers(ns TEXT, key TEXT, seq INT, value BLOB, PRIMARY KEY(ns,key));
usage_ledger(id TEXT PK, seq INT, entry_id TEXT, adjustment INT,
             usage BLOB, details BLOB) WITHOUT ROWID;
branch_entries(branch_id TEXT, entry_id TEXT, entry_seq INT, entry_type TEXT,
               PRIMARY KEY(branch_id, entry_id)) WITHOUT ROWID;
CREATE INDEX ix_be_seq  ON branch_entries(branch_id, entry_seq, entry_id, entry_type);
CREATE INDEX ix_be_type ON branch_entries(branch_id, entry_type, entry_seq, entry_id);
branch_meta(branch_id TEXT PK, tip_entry_id TEXT, tip_seq INT,
            base_branch_id TEXT, base_seq INT);
CREATE UNIQUE INDEX ix_bm_tip ON branch_meta(tip_entry_id);
session(created_at, parent_session_id, storage_version, metadata,
        message_count, usage_payload, next_seq);
writer_lease(owner_id TEXT, fence INT, expires_at_ms INT);
```

**Exit**: both backends pass the WP-T storage conformance suite (atomicity, seq monotonicity, CAS, placement invariant, branch-index invariants incl. the two mandatory correctness rules from pi §2.6, lease fencing under simulated dueling writers); `EXPLAIN QUERY PLAN` assertions in CI; stats projection equals ledger sum after every commit.

### WP-C `session` — session layer, repo, forks

**Scope**: `Session`/`SessionRepo` (create/open/list/delete/fork); typed tree views per strand; context projection (scan → reverse → drop errors/aborted/deferred → project customs → transform hook seam); fork (branch/tree scopes, fresh StrandState, ledger zeroed, orphan-call healing at request construction); precise-rewrite as a repo-level admin op (VACUUM-INTO copy + swap); migrate-on-open version chain.
**Exit**: fork/projection property tests (append-only context invariant: across a strand's successive projections, the prior projection is a prefix except across a compaction); precise rewrite passes an "erase X" audit test incl. retained-tail copies; v-mismatch open refusal.

### WP-D `machine` — the pure state machine

**Scope**: full transcription of pi Part 3 into ADTs + `next_action`/`classify`/acceptance/checkpoint-procedure/terminal-result computation; the transition table as exhaustive cases; queue drain modes; `skip_inbox_once`; abort drain; overflow one-shot flag; threshold dedup by trigger id.
**Must not**: import storage or runtime; everything is `State × Inputs → Action`.
**Exit**: the WP-T *machine suite* — a scenario DSL replaying pi's worked examples (§0.4 Slack thread, §0.5 crash-mid-tool, §3.9 overflow) transaction-for-transaction; property tests for the invariants ("every tool call has a result", "no state after terminal", "cancelled + running-aborted-response unreachable"); 100% constructor coverage on `OperationState`.

### WP-E `runtime` — OTP assembly

**Scope**: SessionSupervisor (rest-for-one), StorageWriter gen_server (commit queue; publishes events post-commit), StrandSupervisor + Strand driver (monitors as DriveState; dispatch/await/settle; retry timers), recovery/restore (register point-lookups + bounded validation from pi §3.3 as decoders), abort, close, inter-strand messaging (durable enqueue + doorbell `Nudge(strand)` message; doorbell loss must be harmless by construction — the checkpoint poll must find the item).
**Exit**: the **interleaving harness** (WP-T) green: for a library of scenarios, kill/restart between *every* adjacent commit pair and assert convergence to the same terminal state and ledger; chaos tier (random process kills under load, 10-min soak) with invariants asserted; doorbell-dropped tests.

### WP-F `provider`

**Scope**: streaming HTTP client (Erlang `httpc`/`gun` shim), SSE + provider-specific stream parsing on dedicated processes, Anthropic + OpenAI-compatible adapters first, usage extraction, retry policy normalization, role routing + fallback chains, secret injection from OS keychain (FFI: macOS `security`, Linux secret-service; env fallback), canonical overflow detection.
**Exit**: recorded-fixture tests per adapter (happy, tool-calls, overflow, 429-retry, mid-stream disconnect → `Failed`, unknown stop reason → in-band); fallback-chain tests; secrets never appear in any logged/persisted structure (grep-based leak test over a full session fixture).

### WP-G `broker` — ToolBroker

**Scope**: token mint/check/revoke; policy composition (session base ⊕ tool requirements ⊕ escalation grants, most-restrictive-wins except explicit grants); the framing protocol (Part 1.4) client+server; ExecPool supervision (helper lifecycle, pgroup/cgroup ownership, heartbeats, 2s-cancel-escalation); per-execution pooled budgets (outstanding-effect cap, shared cgroup, wall deadline); escalation objects (structured denial → approval → single re-execution, all durable via WP-E callbacks); MCP adapter (spawn-in-sandbox, schema validation, provenance tagging).
**Exit**: protocol fuzz tests (malformed frames never crash the broker; connection drops → in-band effect failure); token property tests (wrong/expired/revoked token always refused); budget tests (10k-parallel-read amplification capped); escalation lifecycle tests.

### WP-H `sandbox` — helper binary + drivers *(Go; parallel from day one)*

**Scope**: one static `loom-exec` binary: parse `SandboxPolicyV1` from fd 3, apply platform restrictions to self, exec target; speak the framing protocol on stdio.

Go implementation constraints (load-bearing): **bwrap owns all namespace and
filesystem-view construction** — the Go helper never calls `unshare`/`fork`,
which the multithreaded Go runtime cannot do safely (the runc `nsexec.c`
problem). The helper only stacks restrictions on itself and execs: Landlock
via `go-landlock`, seccomp via a pure-Go BPF filter installed with
`SECCOMP_FILTER_FLAG_TSYNC` (so it binds every runtime thread), cgroup v2
writes, rlimits, pgroup setup. Both Landlock rulesets and seccomp filters
persist across `execve`, so restrict-then-exec composes. If a future phase
needs the helper to own namespaces itself (e.g. dropping the bwrap
dependency), that piece becomes a pre-runtime C constructor or a small
native shim — record it in an ADR at that point, do not bend the Go rule.
- **Phase 1 Linux**: bwrap filesystem view + Landlock rules + seccomp network filter; cgroup v2 limits; pgroup management.
- **Phase 2 macOS**: generated Seatbelt profiles (deny-default; parameterized writable roots; network by policy); rlimits.
- **Phase 3 Windows**: restricted tokens + ACLs + firewall (follow-up milestone).
- Egress proxy sidecar for `Proxy(allowlist)` (CONNECT-only, host-glob allowlist, per-execution logs).
**Exit**: the **sandbox regression suite** (WP-T, runs in CI on real kernels): write-outside-roots, protected-path write, direct socket under Off, non-allowlisted host under Proxy, env leakage, setsid escape, fork-bomb vs pids limit, output-flood truncation, orphaned-grandchild reaping — all must fail closed on both platforms. `loom-exec --self-test` runs the suite locally.

### WP-I `tools` — core tool set

**Scope**: tool behaviour (`name, schema, replay: Never|Safe, execution_mode, requirements → run(ctx, args)`); `bash` (via broker exec), `fs_read` (hashline anchors: per-line `xxh3(content)[:8]`; large files: windowed reads), `fs_edit` (anchor-checked replace/insert/delete; multi-hunk; stale-anchor → structured rejection listing fresh anchors), `fs_write`, `grep` (rg via exec). Later in M5: `lsp_*` (client over stdio port, per-project supervised, sandboxed), `dap_*`.
**Exit**: hashline property tests (edit after concurrent modification always rejected; applied edits byte-exact); tool results conform to schema; `replay` honored in interleave scenarios (a `Never` bash mid-crash yields synthetic interrupted result — the pi §0.5 scenario verbatim).

### WP-J `codemode` + `cap`

**Scope**:
- **Vetting lint**: parse submitted Gleam (reuse `glance` or the compiler's parser via shim); reject any `@external`, any import outside allowlist, any dependency not the pinned prelude. Output: pass | structured rejection (fed to the model in-band).
- **Compile service**: hermetic `gleam build` inside an executor jail (no network; vendored prelude + stdlib); artifact = `.beam` set + manifest hash.
- **Satellite runtime**: `erl` launched in-jail, `-proto_dist` disabled/no epmd, framing channel on stdio; boot module loads artifacts, runs `main`, marshals `report.Outcome`; per-process `max_heap_size`; kept-alive mode for cells (recycled after N calls or any vetting warning).
- **`cap` prelude**: `cap/fs, proc, git, lsp, report, task, actor, kv` — RPC stubs over `cap_call`. `cap/task`: `parallel_map(order-preserving, max_concurrency, fail_fast opt-in)`, `race` (real cancellation → broker revoke), `both/all`. `cap/actor`: `spawn(init, handler) -> Address(msg)`, `send`, `call(timeout)`, `get`; bounded mailboxes; all under one program-root supervisor, all-for-one.
**Exit**: vetting corpus tests (50+ adversarial programs: hidden FFI via nested deps, unicode-lookalike imports, prelude shadowing — all rejected); end-to-end: the migration sample program from the design discussion runs against a fixture repo; concurrency semantics tests (order preservation, real cancellation kills executor pgroups, budget cap under 1000-way fanout); escaped-satellite tabletop: a hand-written malicious `.beam` loaded directly (bypassing vetting) can reach *nothing* but token-checked RPCs and is killed at deadline.

### WP-K `events` — bus, projections, search

**Scope**: `pg`-based EventBus (typed topics per session); projection behaviour (persisted high-water seq, catch-up via scans, rebuildable); stats projection; FTS search service (standalone SQLite FTS5 DB over repo; pull-based sync, notify-as-hint, generation counter for precise-rewrite invalidation — pi's search section verbatim).
**Exit**: lost-event tests (drop every Nth event; projections converge via catch-up); rebuild-from-zero equals incremental state.

### WP-L `client` — gateway + TUI

**Scope**: ClientGateway (Part 1.6) over websocket; auth (local: unix-socket peer creds; remote: bearer tokens); snapshot/catch-up; escalation approval flow UI contract. TUI: a standalone Go binary on the bubbletea/lipgloss stack (bubbles components; glamour for markdown rendering), coupled to the harness *only* through the Part 1.6 websocket protocol — protocol events map onto bubbletea messages, commands onto websocket sends. It hand-writes the protocol types (small, versioned JSON; the Gleam-JS shared wire types serve web clients instead). Features: stream rendering, strand switcher, approval prompts, diff viewer, transcript browser.
**Exit**: protocol conformance tests both directions (golden transcripts); reconnect/catch-up fuzz; a scripted end-to-end demo session driven purely through the public protocol (this doubles as the acceptance test for M3).

### WP-M `ext` — skills & extension zone

**Scope**: L1 skill store (named code-mode programs as entries; invoke-by-name re-vets + re-compiles from source); L2 candidate pipeline (extension prelude allowlist; test-in-jail runner attaching results durably); L3: extension behaviours (`ExtTool`, `ExtHook`, `ExtProjection`), harness-side compile, `code:load_binary` under `ext_{name}_{vsn}` names, supervised time-boxed invocation wrappers, unload/rollback, durable load/unload events, org policy for auto-approval of signed sources.
**Exit**: promotion-ladder integration test (agent-authored fixture tool goes L0→L3 and serves a live tool call; rollback restores prior version mid-session); a hostile L2 candidate (attempts FFI, oversleeps, leaks) is rejected/killed at each defense layer; TCB freeze test — extension API cannot reach StorageWriter/broker internals (compile-time visibility + runtime name checks).

### WP-T `conformance` — the shared suites *(continuous)*

Storage suite · machine scenario DSL + suites · **interleaving harness** (instrumented StorageWriter decorator: enumerate commit boundaries, script kills, assert convergence — pi Part 9's order-assertion decorator, upgraded into a crash scheduler) · chaos runner · sandbox regression suite · protocol fuzzers · fixture repos (a small polyglot repo with tests, for tool/code-mode/e2e suites) · golden end-to-end transcripts.

---

## Part 3 — Cross-cutting specifications

### 3.1 Recovery procedure (normative, WP-E)

On strand start: read `strand.state`, `strand.leaf`, `strand.config`, and if an op is named, `op.meta` + `op.state`; batch-fetch every entry/register the state names; run the bounded validation checks (pi §3.3 list, as decoders); then enter the driver loop — `next_action` on a restored state must be indistinguishable from live operation. Crash-position policy: assistant/deferred `effect_pending` with running control → abandon reserved ids, fresh intent (unknown-outcome attempt); tool `effect_pending` → replay policy; cancelled control → synthetic settlements under existing reserved ids. `strand.last_result` is never a recovery input.

### 3.2 Context projection & budget (WP-C + WP-E)

Projection per pi §2.5 (stop at compaction inclusive; drop error/aborted/deferred responses; project customs; transform hook; provider mapping). Token budgeting: threshold compaction at checkpoints only, once per trigger id; reserve/keep-recent settings validated at set time. Large tool outputs: > 64 KiB streams to a session-adjacent blob dir (content-addressed), entry stores `{ref, size, head_excerpt, tail_excerpt}`; projection includes excerpts + a note the ref is readable via `fs_read`.

### 3.3 Security invariants (tested, not asserted)

1. No model-influenced code executes in the harness VM (extension loads only via WP-M's compile-from-vetted-source path).
2. Every external effect carries a policy and a token; every effect's policy is durably attached to its intent.
3. Network-off is default; any widening is a durable, user-visible event.
4. Secrets appear only in ProviderGateway request memory; never in envs, transcripts, logs, or satellite-reachable state.
5. Distribution listeners: none by default; control-plane clustering is opt-in config with mTLS required.
6. Satellite/executor channels validate every inbound frame; a malformed frame closes the channel and settles the effect as an in-band error.

### 3.4 Telemetry

Structured logs (Erlang `logger`, JSON handler) with `{session, strand, op, step}` context everywhere; OpenTelemetry export optional; usage events mirrored to the ledger are the billing source of truth (telemetry is observability only).

---

## Part 4 — Milestone acceptance (cut points for integration)

| Milestone | Integrates | Acceptance |
|---|---|---|
| M0 | A,B,(C-min),T | conformance green both backends; 10k-entry session: branch scan p50 < 5 ms |
| M1 | +D,E | interleave harness green over scenario library; cold-open of a 30-turn crashed session resumes correctly |
| M2 | +F,G,H(Linux),I | jailed end-to-end: prompt → tool calls → sandboxed bash/edits → answer; sandbox suite green; pi §0.5 crash scenario reproduced live |
| M3 | +C-full,K,L,H(macOS) | multi-strand demo: parent + 2 subagents collaborating via durable messaging; TUI thin client drives everything via protocol; fork + compact live |
| M4 | +J | code-mode migration sample runs; concurrency suite green; hostile-satellite tabletop passes |
| M5 | +I(lsp,dap), routing, TTSR, memory | semantic rename across fixture repo via LSP; DAP breakpoint session; fallback chain survives injected 429 storm |
| M6 | +M | promotion-ladder integration test; rollback live |
| M7 | follow-ups below | per-feature |

## Part 5 — Follow-up tracks (post-M6, each spec'd on entry)

1. **Remote executor pools** — the framing protocol over SSH tunnel/mTLS; pool registration, health, affinity (route by workspace); policy translation for remote roots. *(Design §5.6; mostly WP-G/H work.)*
2. **Windows sandbox** — WP-H phase 3: restricted tokens, ACLs, firewall, job objects; port the regression suite.
3. **MicroVM tier** — Firecracker driver for ExecPool; same policy language; snapshot-boot for warm pools.
4. **Control-plane clustering** — libcluster + `inet_tls_dist`; session routing by id; `pg` event fan-out across nodes; lease semantics unchanged (one node owns a session file).
5. **Record/replay evals** — instrumented gateway/broker record settlements keyed by intent; replay mode simulates providers/tools from a recorded session; drift report. Unlocks regression evals for prompts, models, and machine changes.
6. **pi format-4 import** — full Appendix-B-style normalization (id re-minting, aggregate usage adjustment row, unconfigured-main seeding).
7. **`disk_log` backend** — alternate BEAM-native storage for embedded targets; must pass the same conformance suite.
8. **Hindsight memory v2 / TTSR** — stream-scanner processes, rule store, relevance surfacing; promotion path memory→L1 skill.
9. **Mobile/web thin clients** — Gleam-JS shared wire types; read-only first, then approvals and steering.
10. **Egress proxy hardening** — TLS SNI pinning, per-domain byte quotas, request logging surfaced in transcript.

## Part 6 — Bootstrap order (do these before spawning parallel agents)

The DAG says *what can* parallelize; this says *what must happen first*:

1. **Settle the Part-7 ADRs that sit under frozen interfaces** — specifically the SQLite binding strategy (under the Storage behaviour) and the msgpack library shared by the Gleam and Go sides (under the framing protocol). Deciding these after WPs are in flight causes churn inside otherwise-frozen contracts; deciding them first costs a day.
2. **Decide `AgentMessage` fidelity to pi's provider-message shapes** (WP-A). Mirroring pi's `AgentMessage`/`ToolResultMessage` structure closely makes the format-4 import (Follow-up 6) mostly mechanical decode-and-re-mint; diverging makes it a semantic mapping project. Recommendation: mirror the shapes, diverge only in representation (ADTs over tagged unions). Record the decision as ADR-001.
3. **Bootstrap `core` (WP-A) and the WP-T scenario DSL together, before everything else.** WP-A is the frozen vocabulary; the scenario DSL is how every other WP proves itself. All other packages key off these two — mocks for every Part-1 interface live in `conformance` from day one so {B, D, F, H} can start against them immediately.
4. **Stand up CI with the conformance suites as the integration mechanism** before the second WP branch exists. Agents integrate by making shared suites green, not by coordinating with each other; that only works if the suites are the first thing that runs.

## Part 7 — Open implementation questions (owners decide, document in ADRs)

- **ADR-001 (bootstrap-blocking)**: `AgentMessage` fidelity to pi shapes — see Part 6 item 2.
- **ADR-002 (bootstrap-blocking)**: `sqlight` vs custom NIF for SQLite (need: BLOB params, `EXPLAIN` access, busy-handler control).
- **ADR-003 (bootstrap-blocking)**: msgpack library choice / vendoring for the framing protocol on both Gleam and Go sides.
- Satellite boot time target: measure `erl -noshell` cold start with preloaded prelude; decide pool-warm default.
- Hashline anchor length (8 hex vs 12) vs collision odds on pathological files; whether anchors include line number salt.
- ~~TUI implementation substrate~~ — settled: Go sidecar (bubbletea) over the client protocol; the protocol keeps this swappable if a BEAM-native TUI ever becomes viable.
