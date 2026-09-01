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
│   ├── telemetry/   §3.4  structured logs, context, redaction (leaf)
│   ├── client/      WP-L  ClientGateway protocol + server; TUI
│   ├── ext/         WP-M  ExtensionZone, skill store, promotion
│   └── conformance/ WP-T  shared test suites, chaos & interleave harness
├── protocol/             frozen wire schemas (this doc, Part 1) as source of truth
└── scripts/              dev scripts, CI, fixture repos for sandbox tests
```

*(Layout as built. Two packages the sketch has no line for exist:
`prompt/` — the system-prompt pack, pure, whose home §3.4's own note
records as missing from the frozen contracts — and `lint/`, Loom's
house-rule lint over Gleam source, which depends on nothing in the
harness. `tui/` is its own Go package rather than a directory under
`client/`, per WP-L's "standalone Go binary". `ext/` does not exist:
WP-M is unstarted.)*

Package names are unprefixed: they are monorepo-internal and never
published, so the short names cannot collide on Hex, and each package still
namespaces its modules under its own directory (`core/entry`,
`runtime/strand`). If a package is ever published (the `cap` prelude is the
plausible candidate), it takes a `loom_`-prefixed name at that point.

Dependency DAG (→ = depends on):

```
A → (nothing)    Tel → A  (§3.4; E, K, L consume it)
B → A            C → A,B,D        D → A            T → A..(all, test-only)
E → A,B,C,D,F    F → A            G → A            H → G(protocol only)
I → G            J → G,I          K → A,B          L → A..K(thin over all)  M → E,G,J
N → E,I,J,L
```

**Parallelization**: after WP-A freezes, {B, D, F, G, H} proceed fully in parallel; {C} after B's behaviour and D's register codecs land; {E} after B+C+D+F; {I, J} after G's protocol section (Part 1.4) — which is frozen *here*, so they can start immediately against mocks. T grows continuously.

*(DAG as built, updated from the original sketch: C reads machine's
register codecs for typed access; E consumes provider's stream and
retry contracts for the effects seam; G's usage types turned out to
live in core, decoupling it from F; K never needed the session layer; L,
as the surface that serializes every other plane, legitimately reads
storage, machine, provider, and broker alongside runtime and events.)*

### 0.2 Conventions (all WPs)

- Gleam `>= 1.18`, Erlang/OTP `>= 29`. `gleam format` enforced; no warnings.
- Every public function documented; every ADT constructor's invariants stated in its doc comment.
- **Total decoders**: every durability/wire boundary uses `Decoder(t)` returning `Result(t, CorruptionReport)`. Partial decoding is a bug class, not a style choice.
- **No `panic`/`let assert` outside tests** except for documented invariant violations that must fault the process (mirrors pi's "failed admitted commit faults the harness").
- Erlang FFI: confined to `*/internal/ffi_*.gleam` modules; every `@external` carries a comment naming the OTP function and why no pure alternative exists. CI greps enforce confinement.
- Time: all timestamps Unix ms, from an injected `Clock` capability (testability). Ids: UUIDv7 from an injected generator; tool-result ids inherit the assistant id's 48-bit time prefix (pi §1.2 rules 1–3).
- **One clock per session**: one `Clock` — or at minimum one era — must be injected across runtime, tools, and broker. A budget deadline is computed on the tool side and checked on the broker side, so clocks whose eras disagree make the broker refuse every call as already past its deadline. A host that builds its clocks separately must still build them from one source.
- **Catch-up frontier**: a projection catch-up that reads more than one scan must bound every scan by a frontier sequence read before the first. Sequences are strictly increasing and rows are write-once, so the bounded range is immutable while the scans run and the batch is consistent. Unbounded, a commit landing between two scans advances the high-water past rows the earlier scan never saw, and they are lost for good.

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
pub opaque type SessionId  // UUIDv7; names a whole session (protocol-change/008)
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
                       Faulted(reason: String)
                       // the writer lease was stolen or cleared, so no
                       // reload and no retry can get past it
                       LeaseLost(held_by: Option(String)) }  // (protocol-change/005)
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
pub fn cancel(handle: StreamHandle) -> Nil
// events: Delta(TextDelta|ToolCallDelta|ThinkingDelta) | Settled(SettledAssistantMessage, Usage) | Failed(ProviderError)
// StreamHandle = {events: Subject(StreamEvent), cancel: fn() -> Nil,
//                 owner: Option(Pid)}
// ProviderError includes ProviderCancelled and CancellationUnconfirmed;
// both are terminal and never fall back.
pub fn resolve(gw, role: Role) -> Result(ResolvedModel, MissingIdentity)
// Role = Main | Subagent | Plan | Summarize | Vision | Custom(String)
```

Fallback chains resolve at dispatch; the durable state stores the resolved `{provider, model_id}`. Adapters must map provider stop reasons totally; unknown → `Failed(UnmappedStopReason)` (in-band), never a crash. Adapter-computable overflow (input+cache_read > context_window, negligible output) settles as `error` with the canonical overflow message pattern.

The request owner arbitrates settlement against cancellation. Calling
`cancel` is idempotent, stops the active transport, prevents any later
fallback attempt, and produces `Failed(ProviderCancelled)` when the consumer
is still alive and the owner acknowledges cancellation. An ownership boundary
whose inner owner does not acknowledge or die within its fixed grace produces
the terminal `Failed(CancellationUnconfirmed)`; uncertainty never permits a
retry or fallback. Consumer death has the same teardown effect without a
public terminal. `owner = Some(pid)` is a transitive drain witness and `None`
means there is no asynchronous work. Every transport returns a monitorable
owner plus a cancellation capability; production retains the exact OTP request
id, calls `httpc_handler:cancel/2` on that request's dedicated handler, and
waits for the handler's `Down` before its custodian retires. The public
`httpc:cancel_request/1` route is only a conservative fallback while handler
identity is still being recovered. A caller timeout alone is not cancellation. Protocol
change 010 records the full ownership and race law.

**The request vocabulary is closed.** `ProviderRequest` carries what the block above names and nothing else, and no options bag crosses the gateway seam. Dialect-specific per-request options — streaming flags, cache breakpoints — are the adapter's, derived from the request's own contents: the OpenAI adapter sets the wire's `stream_options.include_usage` itself, and the Anthropic adapter places its own cache breakpoints, so nothing above the seam learns either dialect. A harness-side options value the request shape cannot express therefore stops at the seam by rule; dropping it is conformance, not loss. Widening the shape to carry one is a protocol change.

### 1.6 Client protocol (WP-L; thin clients)

Websocket, JSON (client-friendliness beats msgpack here), versioned:

```
c→s: {v:1, id, cmd: "prompt"|"prompt_content"|"steer"|"follow_up"|"abort"|"approve"|"deny"
              |"fork"|"navigate"|"compact"|"create_strand"|"set_config"
              |"subscribe"|"catch_up"|"models", body}
s→c: {v:1, reply_to?, event: "snapshot"|"entry"|"op_transition"|"stream_delta"
              |"usage"|"escalation"|"strand_result"|"error", seq?, body}
```

`subscribe{session, from_seq}` → `snapshot` (strands, leaves, open ops, recent entries) then live events; reconnect = `catch_up{from_seq}` (events are rebuildable from `scan_*`). Stream deltas are ephemeral (never persisted; pi's non-goal preserved) and flagged `ephemeral:true`.

---

## Part 2 — Work packages

### WP-A `core` — types & codecs *(no deps; freeze first)*

**Scope**: everything in §1.1; `AgentMessage` model (user/assistant/tool-result + custom roles with registered runtime schemas); msgpack + JSON codecs; UUIDv7 generator (follower minting); `CorruptionReport`.
**Must not**: perform I/O; import anything but stdlib.
**Exit**: property tests — codec roundtrip for every type (incl. adversarial junk → decode error, never crash); UUIDv7 ordering & follower-prefix laws; decoder totality shown by construction rather than by a coverage percentage, since no Gleam coverage tool exists to measure one. Concretely: every constructor of every decoded type carries a roundtrip case, and each codec boundary — msgpack bytes, JSON values, the entry/message codecs — carries an adversarial corpus whose every input decodes to a `CorruptionReport`. A decoder that no corpus entry is aimed at fails the criterion.

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
-- parent_session_id, and metadata's "session_id" field, are the lease-free
-- projection of the session's own `session/id` / `session/parent` register
-- cells, which are the truth (protocol-change/008).
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
**Exit**: the **sandbox regression suite** (WP-T, runs in CI on real kernels): write-outside-roots, protected-path write, direct socket under Off, non-allowlisted host under Proxy, env leakage, setsid escape, fork-bomb vs pids limit, output-flood truncation, orphaned-grandchild reaping. `loom-exec --self-test` runs the suite locally. Filesystem and network probes must fail closed on both platforms. Resource and lifecycle probes must either prove the named kernel mechanism or report the missing layer; `FullEnforcement` refuses either a skip or a missing layer. ADR-006 records why sampled descendant cleanup and account-wide `RLIMIT_NPROC` are observations rather than macOS equivalents of PID namespaces and cgroups.

Production uses `PlatformEnforcement`: it is equivalent to `FullEnforcement`
on Linux, while Darwin may accept only ADR-006's three explicitly reported
resource and lifecycle gaps. Missing Seatbelt layers, unexpected skips, and
silent reports still fail the demand. Callers that require cross-platform
Linux equivalence select `FullEnforcement` explicitly.

### WP-I `tools` — core tool set

**Scope**: tool behaviour (`name, schema, replay: Never|Safe, execution_mode, requirements → run(ctx, args)`); `bash` (via broker exec), `fs_read` (hashline anchors: per-line `xxh3(content)[:8]`; large files: windowed reads), `fs_edit` (anchor-checked replace/insert/delete; multi-hunk; stale-anchor → structured rejection listing fresh anchors), `fs_write`, `grep` (rg via exec). Later in M5: `lsp_*` (client over stdio port, per-project supervised, sandboxed), `dap_*`.
**Exit**: hashline property tests (edit after concurrent modification always rejected; applied edits byte-exact); tool results conform to schema; `replay` honored in interleave scenarios (a `Never` bash mid-crash yields synthetic interrupted result — the pi §0.5 scenario verbatim).

### WP-J `codemode` + `cap`

**Scope**:
- **Vetting lint**: parse submitted Gleam (reuse `glance` or the compiler's parser via shim); reject any `@external`, any import outside allowlist, any dependency not the pinned prelude. Output: pass | structured rejection (fed to the model in-band).
- **Compile service**: hermetic `gleam build` inside an executor jail (no network; vendored prelude + stdlib); artifact = `.beam` set + manifest hash.
- **Satellite runtime**: `erl` launched in-jail, `-proto_dist` disabled/no epmd, framing channel on stdio; boot module loads artifacts, runs `main`, marshals `report.Outcome`; per-process `max_heap_size`; kept-alive mode for cells (recycled after N calls or any vetting warning).
- **`cap` prelude**: `cap/fs, proc, net, git, lsp, report, task, actor, kv` — RPC stubs over `cap_call`. `cap/task`: `parallel_map(order-preserving, max_concurrency, fail_fast opt-in)`, `race` (real cancellation → broker revoke), `both/all`. `cap/actor`: `spawn(init, handler) -> Address(msg)`, `send`, `call(timeout)`, `get`; bounded mailboxes; all under one program-root supervisor, all-for-one.
**Exit**: vetting corpus tests (50+ adversarial programs: hidden FFI via nested deps, unicode-lookalike imports, prelude shadowing — all rejected); end-to-end: the migration sample program from the design discussion runs against a fixture repo; concurrency semantics tests (order preservation, real cancellation kills executor pgroups, budget cap under 1000-way fanout); escaped-satellite tabletop: a hand-written malicious `.beam` loaded directly (bypassing vetting) can reach *nothing* but token-checked RPCs and is killed at deadline.

### WP-K `events` — bus, projections, search

**Scope**: `pg`-based EventBus (typed topics per session); projection behaviour (persisted high-water seq, catch-up via scans, rebuildable); stats projection; FTS search service (standalone SQLite FTS5 DB over repo; pull-based sync, notify-as-hint, generation counter for precise-rewrite invalidation — pi's search section verbatim).
**Exit**: lost-event tests (drop every Nth event; projections converge via catch-up); rebuild-from-zero equals incremental state.

### WP-L `client` — gateway + TUI

**Scope**: ClientGateway (Part 1.6) over websocket; bearer-token auth; snapshot/catch-up; escalation approval flow UI contract. TUI: a native Gleam shipment over etui, coupled to the harness through the Part 1.6 websocket protocol — protocol events reduce an immutable presentation model and commands become websocket sends. It hand-writes the protocol envelope and event union while reusing `core` only for total durable-entry decoding. Features: stream rendering, strand and model selectors, agent inspection, structured tool and markdown views, prompt attachments, transcript scrollback, and usage reporting. Pending escalations are visible, but exact action-and-grant approval and automatic reconnect/catch-up remain follow-up work.
**Exit**: protocol conformance tests both directions (golden transcripts); reconnect/catch-up fuzz; a scripted end-to-end demo session driven purely through the public protocol (this doubles as the acceptance test for M3).

### WP-M `ext` — skills & extension zone

**Scope**: L1 skill store (named code-mode programs as entries; invoke-by-name re-vets + re-compiles from source); L2 candidate pipeline (extension prelude allowlist; test-in-jail runner attaching results durably); L3: extension behaviours (`ExtTool`, `ExtHook`, `ExtProjection`), harness-side compile, `code:load_binary` under `ext_{name}_{vsn}` names, supervised time-boxed invocation wrappers, unload/rollback, durable load/unload events, org policy for auto-approval of signed sources.
**Exit**: promotion-ladder integration test (agent-authored fixture tool goes L0→L3 and serves a live tool call; rollback restores prior version mid-session); a hostile L2 candidate (attempts FFI, oversleeps, leaks) is rejected/killed at each defense layer; TCB freeze test — extension API cannot reach StorageWriter/broker internals (compile-time visibility + runtime name checks).

### WP-N `cap/strand` — the orchestration seam *(after J; independent of I's lsp/dap and of M)*

**Scope**: a **second** code-mode seam, so that a program can orchestrate
subagents. A submission is vetted against one of two allowlists — the
existing *workspace* seam (`cap/{fs, proc, net, git, lsp, report, task,
actor, kv}`) or the new *orchestration* seam (`cap/strand` + `cap/report`,
nothing else). One pipeline, two allowlists: `codemode`'s vetting policy
is already parameterized per submission, so this is a configuration of
machinery that exists. Content and ordering come from
`docs/design-notes/orchestration-comparison.md`, which argues the verdict
and deliberately does not put the interesting part first.
- **Structured results, first.** An optional `result_schema` on the spawn
  request, carried into the child's brief and its terminal validation; a
  typed result beside `Waited.Ready`'s prose `report`. `tools/agent` and
  `client/agency` are the only modules that change, and the `agent_*`
  tools gain it too. Deterministic orchestration over a `String` result
  is a script that regexes prose, so nothing downstream is worth building
  first.
- **Honest enforcement reporting, second** (spec-gaps WP-J 14). The
  satellite reports enforcement only on `CallExited`, which the abort
  that settles the outcome usually beats, so a green run does not prove
  the jail engaged. An orchestration seam is the first thing anyone runs
  unattended; "we could not confirm the jail applied" is not an
  acceptable answer for that case.
- **The seam, third.** `cap/strand`: `spawn`, `wait` (a list of handles
  against one deadline), `send`, `note`/`notes`, `roster` — RPC stubs
  over `cap_call`, serviced by the same `client/agency` closures the
  `agent_*` tools call and judged against the same `Caller`. The
  authorization model is reused, not invented: `NotADescendant`,
  `DepthCapReached`, `FanOutCapReached`, `UnknownTool`, `ParentRunEnded`
  are already total.
- **Its own caps.** A hard ceiling on spawn admissions per execution —
  `agent_spawn` is throttled by turn cost and a loop pays nothing — plus
  the existing rule that a program may address only the lineage its own
  strand roots.

**Must not**: put `cap/fs`, `cap/proc`, `cap/net` or `cap/git` on the
orchestration seam (which capabilities travel together is the whole
point: an orchestrator that can also write files is a materially worse
thing to hand a model than one that cannot); run any part of the
orchestrator in the harness VM (Rule Zero closes the trusted-interpreter
route, which is why the seam exists at all); raise `depth_cap`,
`fan_out`, or `session_strands`; build a model-readable token budget or
verification-pattern primitives — the design note sequences both *after*
this milestone, and a verification pattern built before the loop that
runs it is a pattern the model must remember to follow.

**Exit**: an orchestration sample — a documented program submitted
verbatim by its test, as WP-J's migration sample is — fans out over the
fixture repo, joins on one deadline, and returns one structured result;
a child whose terminal result does not match its `result_schema` fails
naming the schema, and a matching one comes back as typed JSON, not
prose; **seam confinement**: an orchestration-seam program importing
`cap/fs` or `cap/proc` is rejected by vetting, and a workspace-seam
program importing `cap/strand` is rejected, both as the structured
rejection the model reads; a program looping past the spawn-admission
ceiling is refused in band *at* the ceiling and the refusal names it;
spawning or messaging outside the program's own lineage is refused under
the existing refusal names; and every code-mode outcome — happy path
included — carries the satellite's enforcement report, asserted by
`make e2e-codemode`.

**Proposed, not in scope**: spec-gaps WP-J 15 and 16 — an approved
escalation that widens nothing in code mode, and identity plus budget
specified in three places — are the plumbing this seam leans on hardest.
The `spec-gaps.md` triage proposes them here; they are in scope only if
the owner puts them there.

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

*As built (issue #35): `packages/telemetry` — a leaf package over `core`, so every impure package may depend on it. The correlation context travels as a **value** carried by an injected `telemetry/log.Logger`, because `logger`'s process metadata does not survive a `spawn` and the effect sandwich is nothing but spawns; metadata is stamped additionally (`log.adopt`) so lines the harness did not author land correlated. Four levels with a stated policy (`telemetry/level`'s module doc). Two enforced redaction rules keep tokens, keys and capability tokens off every line (`telemetry/field`), tested by planting secrets and grepping the rendered bytes. OpenTelemetry is left as a `Sink` seam, unbuilt. Wired at `client/serve` (boot and the entry point), `runtime/strand_runtime` (the drive loop and every effect it spawns), and `events/projection` (pull faults); the remaining packages log nothing yet — `docs/spec-gaps.md` §3.4 items 6 and 8 carry both gaps.*

### 3.5 Tool timeout ceiling (WP-I + WP-G)

The ceiling on a tool call's wall clock is the tool's own clamp, not session policy: each tool declares its default and maximum timeout, clamps any caller-supplied value to that maximum, and derives the sandbox `wall_s` requirement from the clamped result. Session policy narrows further — composition meets the limits — but cannot widen past the clamp, so an approved `wall_s` grant raises the jail's limit while the tool still stops waiting at its own deadline. As built: `bash` clamps to 600 s over a 120 s default; `grep` runs a fixed 60 s and takes no timeout argument.

---

## Part 4 — Milestone acceptance (cut points for integration)

Status is read against the acceptance column and nothing else. **Done**
means every criterion in the row has been demonstrated by a test or a
live run; **partial** means at least one has not, and the note below
says which. A criterion demonstrated only under test-supplied hooks, or
only on a host that could not enforce what it claims, is not
demonstrated.

| Milestone | Integrates | Acceptance | Status |
|---|---|---|---|
| M0 | A,B,(C-min),T | conformance green both backends; 10k-entry session: branch scan p50 < 5 ms | done |
| M1 | +D,E | interleave harness green over scenario library; cold-open of a 30-turn crashed session resumes correctly | partial |
| M2 | +F,G,H(Linux),I | jailed end-to-end: prompt → tool calls → sandboxed bash/edits → answer; sandbox suite green; pi §0.5 crash scenario reproduced live | partial |
| M3 | +C-full,K,L,H(macOS) | multi-strand demo: parent + 2 subagents collaborating via durable messaging; TUI thin client drives everything via protocol; fork + compact live | partial (compaction live as of Stage C0; the real TUI drives the real server; `H(macOS)` now runs under Seatbelt) |
| M4 | +J | code-mode migration sample runs; concurrency suite green; hostile-satellite tabletop passes | partial |
| M4.5 | +N | orchestration sample fans out over the fixture repo and joins on one deadline, returning one structured result; seam-confinement suite green in both directions; a loop past the spawn-admission ceiling refused in band; every code-mode outcome carries the enforcement report | partial (three of the four demonstrated end to end; the sample's fan-out reaches a scripted Agency rather than live child strands) |
| M5 | +I(lsp,dap), routing, TTSR, memory | semantic rename across fixture repo via LSP; DAP breakpoint session; fallback chain survives injected 429 storm | not started |
| M6 | +M | promotion-ladder integration test; rollback live | not started |
| M7 | follow-ups below | per-feature | not started |

**Why M4.5 and not M8.** The orchestration seam depends on M4 and on the
`agent_*` tools (delivered, below), and on nothing in M5 or M6, so it
belongs between M4 and M5. Those three are cited by number elsewhere —
WP-I's own scope line, `spec-gaps.md`, `loom-design.md` §11,
`deps-eval.md`, the notebook — so renumbering them to open a slot would
silently invalidate every one; and M7 is a terminal catch-all, so an M8
would read as *after the follow-ups*, which is wrong.

**Where the design doc disagrees.** `loom-design.md` §11's build order
puts the ClientGateway and the TUI in M5 and macOS Seatbelt in M3.
Where the two conflict this document wins on mechanics (front matter),
and the table above is what happened: the gateway and TUI landed with M3,
and Seatbelt subsequently completed its macOS half.

**One caveat over every row.** §0.3 says a WP is done when its exit
criteria pass in CI on Linux and macOS. There is now a CI configuration in
the tree — `.github/workflows/ci.yml` carries a Linux gate, a macOS gate,
a `jail-linux` job that installs bubblewrap, lifts the runner's
unprivileged-user-namespace restriction and delegates a cgroup v2 base
before running the self-test and both end-to-ends, and a short soak;
`nightly.yml` carries the long soak and a cold, cacheless gate. **No run
of it has ever completed.** Every run to date fails at job startup with no
job logs, so nothing in the table has been demonstrated by CI, on either
platform. Every status above still means green under `make check` on one
Linux development container.

### What the rows still owe

- **M0** — done. The SQLite perf smoke test now *asserts* its p50, not
  just prints it (issue #6), but against a 15 ms ceiling rather than the
  5 ms target: the development container measures a p50 near 3 ms and has
  produced a max above 5 ms in the same twenty runs, so a bound at the
  target would flake on shared CI. What the gate therefore holds is that
  the newest-50 branch scan over a 10k-entry chain stays single-digit
  milliseconds — dropping `ix_be_seq` measures 21 ms and fails it. The
  5 ms target itself is still unverified; that needs a benchmark on known
  hardware, and the `EXPLAIN QUERY PLAN` assertions remain the precise
  guard on which index the scan uses.
- **M1** — the interleave harness and the 30-turn cold open are green.
  WP-E's chaos tier (random process kills under load, ten-minute soak) is
  unbuilt: `make soak` is the deterministic-simulation seed soak, and
  WP-T's chaos runner does not exist (spec-gaps WP-E 8).
- **M2** — the jailed end-to-end and the crash rider run against the real
  `loom-exec`, but under `BestEffort`: no machine the suite has run on
  has had bubblewrap, Landlock, or a delegated cgroup v2 hierarchy, so
  `make selftest` on such a machine reports every kernel-dependent probe
  SKIPPED and *nothing there proves a kernel confined anything*. The suite
  is now nine probes, and the CI `jail-linux` job is *written* to be the
  machine that has the layers: it installs bubblewrap, lifts Ubuntu's
  AppArmor restriction on unprivileged user namespaces, and delegates a
  cgroup v2 base, and `.github/enforcement-expectations` declares probe by
  probe which layers that run must actually have applied, failing the job
  in either direction. That job has never completed a run (see the caveat
  above), so what it declares is a reviewed intention rather than an
  observation. One layer is unobserved even in intention: **Landlock has
  never executed in any environment this repository has run in** (issue
  #62) — every container and runner so far answers ENOSYS, so the branch
  that applies a ruleset has never been taken, and every claim about what
  Landlock does here is read from its documentation. That is most
  uncomfortable in degraded mode, where Landlock is promoted from second
  filesystem layer to the only one. One probe WP-H's exit list names
  still has no implementation at all: a non-allowlisted host under `Proxy`,
  because the egress sidecar is unbuilt and proxy mode fails closed as
  network-off. The setsid escape probe and the hostile-`.beam` probe, which
  that list also names, are both built and both `required`. Escalation now
  has a production path: `client/escalate` raises a call-scoped record for
  every broker policy refusal, parks the call when a client is attached,
  and resumes it under the widened policy on approval — proved jailed by
  `make e2e`'s `escalation_round_trip_test` (spec-gaps WP-L 1). Code mode
  is still outside it (spec-gaps WP-J 15).
- **M3** — the multi-strand demo, fork, navigate, catch-up and the
  escalation round trip all run through the public protocol in
  `make check-client`, and the parent-plus-two-subagents kill/reboot
  variant runs at runtime level. *Compaction is live* as of Stage C0
  (`docs/design-notes/compaction-and-memory.md`): `client/serve` builds
  its hooks through `runtime/hooks`, a `SummaryRequest` becomes a real
  gateway request under the summarization pack, and the demo installs
  those same hooks — it has no compaction hooks of its own, so the
  `CompactionEntry` it asserts on carries text the provider produced.
  *The native TUI leg is closed for its implemented surface* (issue #7):
  `client/tui_e2e_test` exports the real `tui` shipment, runs it in a
  terminal under `tmux` against a real `client/serve.boot`, and drives a turn,
  a fork, and clean detach through keystrokes alone — only the model is
  scripted. The older Go-client version of this test also found sparse-seq and
  oversized-frame bugs and proved an approval reached `Consumed`; that client
  has been retired. Approval is no longer claimed by the native terminal test
  until it implements protocol-change/007's exact action-and-grant echo.
  The former `H(macOS)` filesystem and network gap is now delivered: Darwin
  generates a parameterized deny-default Seatbelt profile, proves it against
  the live kernel with all nine sandbox probes, and runs both real jailed
  end-to-ends. The observed `setsid` probe does not prove that sampled process
  tracking catches a rapid daemonizing double-fork; every Darwin execution
  reports that lifecycle gap and `FullEnforcement` rejects it. A bounded output
  drain also prevents a missed descendant from holding the result open forever.
  Its resource report stays platform-honest: finite `RLIMIT_AS` is skipped
  when Darwin rejects it, and the per-user process rlimit is skipped when the
  account's existing process floor does not leave the concurrency reserve below
  the requested ceiling. Sampling still races unrelated same-user forks.
- **M4** — the migration sample is real:
  `docs/examples/stale_symbol_sweep.gleam` is submitted verbatim by its
  test through real vetting, a real offline `gleam build`, and a real
  jailed satellite, and the test asserts the
  race's loser is killed rather than left running. The concurrency suite
  and the in-process tabletop are green, and the tabletop's kernel half is
  no longer reasoning: the `unvetted beam denied host write, secret, and
  network` self-test probe loads a hand-written, never-vetted Erlang module
  into a jailed node, and it is `required` of the jail CI job. What that
  probe claims is narrower than the row's wording — an unvetted `.beam`
  cannot write outside its writable roots, cannot see into a protected
  path, and cannot reach the network, but an *unprotected* host path is
  still readable, because the base view ro-binds the whole filesystem
  (`protocol-change/004-sandbox-policy-explicit-mounts.md`). "Cannot see
  into" is the contents, and the mechanism differs by inode type: a
  protected directory is an empty read-only tmpfs, so its entries are
  `enoent`; a protected file is an empty read-only device mask, so the
  path is there and cannot be opened at all (EACCES). The file half used
  to be a read-only bind of the file onto itself and was therefore
  readable (#55); the probe still exercises only the directory half.
  Two things the row was accepted without have since closed: the
  satellite's enforcement report used to be lost to the abort that raced
  it, so a green run did not prove the jail engaged (spec-gaps WP-J 14),
  and every `Execution` now carries both stages' reports whatever the
  outcome; and an approved escalation, which widened nothing here, now
  composes onto the run phase and only the run phase (issue #24).
  Outstanding: of the nine cap modules vetting admits, the shipped router
  services exactly one, `proc.run` — the rest vet, compile, and refuse in
  band with `unsupported_cap` (issue #16), which is a routing table still
  being filled in rather than a security property; and nothing mints the
  escalation code mode can now spend (issue #97).

- **M4.5** — three of the four criteria are demonstrated end to end, and
  the fourth is demonstrated with the children substituted.
  `docs/examples/fan_out_review.gleam` is read verbatim by
  `codemode/orchestration_sample_test`, vetted against the real
  orchestration allowlist, built offline in a network-off jail, run in a
  real `erl` satellite over a real AF_UNIX channel through the real
  `codemode/orchestration` router, and asserted on three properties the
  outcome line would pass without: three *distinct* children minted, one
  `wait` carrying all three handles rather than three waits carrying one
  each, and counts arriving as integers in the order the program listed
  its packages. Seam confinement is pinned in both directions and the
  disjointness of the two allowlists is a test rather than a convention;
  a loop past the spawn-admission ceiling is refused at the ceiling and
  the refusal names it; every `Execution` carries both stages'
  enforcement reports and the widening beside them.

  What keeps the row *partial* is the sample's Agency: `codemode` cannot
  see a live runtime, so the children are played by a fake that reads the
  real fixture off disk. Everything between the program and that fake is
  real — the vetting, the compile, the jail, the wire, the router, the
  caller derivation, the result-contract carriage — but no single run has
  put a model-written program in front of *live* child strands, and by
  §0's own rule a criterion met with a test-supplied substitute is not
  met. The authorization model the sample therefore does not claim is
  proved separately on `client`'s side, against a live runtime in
  `agency_test` and through this very router in `client/codemode_test`,
  where a real Agency refuses a spawn and a send outside the program's own
  lineage.

  One dependency of the seam is also still half open, and no row names it.
  Grants thread onto a code-mode run phase and only the run phase, proved
  by `make e2e-codemode`, but code mode clears through the broker directly
  rather than through `Ctx.clear_call`, so a policy refusal inside it
  raises no escalation record and nothing can mint the approval it is now
  able to spend (issue #97).

### Delivered outside the table

Work that shipped, is tested, and no row claims. Listed here rather than
folded into the rows above, because the rows are historical cut points
and rewriting their acceptance would erase what was actually accepted.

| Delivered | Where | Relation to the table |
|---|---|---|
| Six `agent_*` tools — spawn, wait over a list against one deadline, send, note/notes, roster — over a seam `tools` names without depending on `runtime` | `tools/agent`, `client/agency` | the model-facing half of M3's durable messaging; M3's row predates it |
| The durable lineage ledger: one cell per child naming its parent, minting operation, and an *absolute* deadline, under a reserved prefix with its own read door | `runtime/api`, `runtime/lineage` | what makes the descendant-only rule enforceable across restarts |
| A system-prompt pack — named sections, total decoder, rendered against an environment, no clock in its dependency graph — assembled at boot and pinned durably with its enforcement demand; the pin wins on a same-demand resume and is replaced once when the demand changes | `packages/prompt`, `client/serve` | no row named a system prompt; spec-gaps M2 integration 8 recorded that it had no home in the frozen contracts |
| Anthropic prompt caching at four breakpoints, and cache writes counted toward the overflow comparison | `provider/adapter/anthropic` | no row; spec-gaps WP-F 8, 9 |
| The `code_mode` tool and its wiring behind a discovered build seed — a host without one registers no tool rather than one that always refuses | `tools/codemode`, `client/codemode` | M4 integrated WP-J but no row required a door to it |
| The macOS Seatbelt jail and live regression gate | `packages/sandbox`, `.github/workflows/ci.yml` | the delivered M3 `H(macOS)` half, with exact resource-limit skips surfaced |
| An approval bound to the **action** it was granted for: the record carries the tool, a digest of the call's effective arguments and a bounded preview, and the claim and spend both guard on it. The native client renders pending records but does not yet send the exact echo. | `client/escalate`, `client/wiring`, `protocol-change/007` | no row named consent granularity; M2's escalation row predates it |
| The `code_mode` description carrying the prelude's public signatures — generated from `packages/cap` through the compiler's own `package-interface`, filtered by each seam's allowlist, and digest-gated inside `make check` | `tools/prelude`, `scripts/gen-prelude.{sh,py}` | M4 required a door to code mode, not an oracle behind it |
| `packages/lint` and `make lint`: seven house rules over Gleam source, four of them (R0, R2, R4, R6) gating `make check` at error level on a census that is zero and argued | `packages/lint`, `scripts/lint.sh` | no row; the conventions in §0.2 asserted rules nothing checked |
| A CI configuration: a Linux gate, a macOS gate, a jail job that installs the kernel layers and checks the self-test against `.github/enforcement-expectations` probe by probe, and a nightly soak | `.github/workflows/` | §0.3's definition of done; see the caveat above for what it has actually run |

## Part 5 — Follow-up tracks (post-M6, each spec'd on entry)

1. **Remote executor pools** — the framing protocol over SSH tunnel/mTLS; pool registration, health, affinity (route by workspace); policy translation for remote roots. *(Design §5.6; mostly WP-G/H work.)*
2. **Windows sandbox** — WP-H phase 3: restricted tokens, ACLs, firewall, job objects; port the regression suite.
3. **MicroVM tier** — Firecracker driver for ExecPool; same policy language; snapshot-boot for warm pools. *(`docs/design-notes/microvm-executor-tier.md` tests "same policy language, different driver" against the tree: the transport half holds, the enforcement-report half does not, and four things block a driver that reports honestly.)*
4. **Control-plane clustering** — libcluster + `inet_tls_dist`; session routing by id; `pg` event fan-out across nodes; lease semantics unchanged (one node owns a session file). *(Absorbs spec-gaps M3 messaging 2: cross-node broadcast fan-out. The bus is read-side only today — no strand-facing broadcast-send exists.)*
5. **Record/replay evals** — instrumented gateway/broker record settlements keyed by intent; replay mode simulates providers/tools from a recorded session; drift report. Unlocks regression evals for prompts, models, and machine changes.
6. **pi format-4 import** — full Appendix-B-style normalization (id re-minting, aggregate usage adjustment row, unconfigured-main seeding). *(Absorbs spec-gaps WP-A 3 — somewhere to put pi's optional `details` payloads — and WP-B/T 6, the JSONL import shim WP-B's scope names.)*
7. **`disk_log` backend** — alternate BEAM-native storage for embedded targets; must pass the same conformance suite.
8. **Hindsight memory v2 / TTSR** — stream-scanner processes, rule store, relevance surfacing; promotion path memory→L1 skill.
9. **Mobile/web thin clients** — Gleam-JS shared wire types; read-only first, then approvals and steering.
10. **Egress proxy hardening** — TLS SNI pinning, per-domain byte quotas, request logging surfaced in transcript. *(This track hardens a sidecar that does not exist: WP-H phase 1 shipped none, so `Proxy(allowlist)` fails closed — jailed exactly as network-off, with a skipped `network-proxy` entry in the enforcement report saying the allowlist was not enforced. Building it comes first, and is unscheduled — §5.1.)*

### 5.1 Recorded work with no home

`docs/spec-gaps.md` now classifies all 114 of its items. Ninety-two are
settled interpretations; eight name a milestone or a track above;
**thirteen name work scheduled nowhere at all**, and its triage table
lists each with a proposed home. A proposal there is not a schedule:
nothing is committed until it appears in Part 2 or Part 4.

Three bodies of unscheduled work are larger than any single item, and are
named here so no row above implies otherwise:

- **The egress proxy sidecar.** Track 10 above.
- **The rest of the hook registry.** Stage C0 wired the compaction
  slots: `client/wiring.compaction_hooks` builds real admission from the
  gateway's model facts, the usage-aware threshold and the overflow
  preparation over the strand's durable projection, generation as the
  structural verdict, and the summary-progress hook. What is still
  inert: `run_start` and `run_end` inject nothing (`client/agency`
  composes a reap onto `run_end` and nothing else), branch summaries
  have the seams but no production caller through the navigation host,
  and `FileOperations` on a preparation is always empty — Stage C1.
- **The chaos runner.** WP-T's chaos tier and WP-E's ten-minute soak
  (spec-gaps WP-E 8), which M1 was accepted without.
- **A kernel that runs Landlock.** Issue #62: the second filesystem layer
  is unit-tested as data and has never executed. Closing it needs a runner
  on Landlock ABI ≥ 3 with `bwrap` absent from `PATH`, so the mount layer
  cannot mask the answer — which is a CI machine nobody has, not a piece of
  code nobody has written.

## Part 6 — Bootstrap order (do these before spawning parallel agents)

The DAG says *what can* parallelize; this says *what must happen first*:

1. **Settle the Part-7 ADRs that sit under frozen interfaces** — specifically the SQLite binding strategy (under the Storage behaviour) and the msgpack library shared by the Gleam and Go sides (under the framing protocol). Deciding these after WPs are in flight causes churn inside otherwise-frozen contracts; deciding them first costs a day.
2. **Decide `AgentMessage` fidelity to pi's provider-message shapes** (WP-A). Mirroring pi's `AgentMessage`/`ToolResultMessage` structure closely makes the format-4 import (Follow-up 6) mostly mechanical decode-and-re-mint; diverging makes it a semantic mapping project. Recommendation: mirror the shapes, diverge only in representation (ADTs over tagged unions). Record the decision as ADR-001.
3. **Bootstrap `core` (WP-A) and the WP-T scenario DSL together, before everything else.** WP-A is the frozen vocabulary; the scenario DSL is how every other WP proves itself. All other packages key off these two — mocks for every Part-1 interface live in `conformance` from day one so {B, D, F, H} can start against them immediately.
4. **Stand up CI with the conformance suites as the integration mechanism** before the second WP branch exists. Agents integrate by making shared suites green, not by coordinating with each other; that only works if the suites are the first thing that runs.

## Part 7 — Open implementation questions (owners decide, document in ADRs)

- ~~**ADR-001 (bootstrap-blocking)**: `AgentMessage` fidelity to pi shapes~~ — accepted, `docs/adr/001-agent-message-fidelity.md`: mirror pi's shapes, diverge only in representation.
- ~~**ADR-002 (bootstrap-blocking)**: `sqlight` vs custom NIF for SQLite~~ — accepted with a verification gate, `docs/adr/002-sqlite-binding.md`: `sqlight`.
- ~~**ADR-003 (bootstrap-blocking)**: msgpack library choice / vendoring~~ — accepted, `docs/adr/003-msgpack.md`: our own codec in `core/msgpack` on the Gleam side, a pinned library on the Go side, both held to the golden frames in `protocol/msgpack-fixtures/`.
- Satellite boot time target: measure `erl -noshell` cold start with preloaded prelude; decide pool-warm default.
- ~~Hashline anchor length; whether anchors include line-number salt~~ — settled by WP-I as built (spec-gaps WP-I 1): 8 hex of a package-internal 64-bit hash, no salt, line numbers travelling beside anchors in refs, because an anchor never outlives one read-edit round trip.
- ~~TUI implementation substrate~~ — amended by the issue #114 evaluation: native Gleam over etui, shipped as a separate Erlang shipment over the unchanged client protocol. The client archive requires compatible OTP 29 because it does not carry a second ERTS.
