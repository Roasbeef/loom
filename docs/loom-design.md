# Loom — a BEAM-native coding agent harness in Gleam

*High-level design document, v0.2*
*(v0.1 → v0.2: added code-mode concurrency & actors (§6.5), inter-agent communication doctrine (§4.6), register ownership & concurrency model (§3.7), remote execution & the two-channel doctrine (§5.6), thin clients & session mobility (§8.5); OTP building-block glossary (App. A))*

---

## 0. Vision

Loom is a next-generation coding agent harness built in **Gleam on the BEAM**. It synthesizes three lineages:

- **pi's durable harness** (earendil-works/pi, dev branch): write-once conversation trees, a durable program counter, atomic transitions, the effect sandwich, lanes (our *strands*), and crash-anywhere recovery.
- **Codex CLI's security model**: kernel-enforced, deny-by-default OS sandboxing (Seatbelt / Landlock+seccomp / bwrap), network-off defaults, and escalation-by-approval rather than approval fatigue.
- **omp's tool-surface wisdom**: hash-anchored edits, LSP/DAP as first-class semantic tools, subagents, role-based model routing, and context-frugal rule injection.

And it adds what none of them have, because none of them run on the BEAM:

- **Native actor-model orchestration**: sessions as supervision trees, strands as processes, subagents as cheap spawns, crash recovery by supervisor + durable state rather than defensive coding.
- **Code mode with real concurrency**: agent-written Gleam programs that fan out, race, pipeline, and hold stateful actors — on a runtime built for it.
- **A staged self-improvement loop**: the agent writes Gleam, compiles it, proves it in a sandbox, and — behind an explicit trust gate — hot-loads `.beam` modules into its own extension zone without restarting.

Design priorities, in order: **security & isolation, correctness, robustness, performance, capability.**

---

## 1. Why Gleam/BEAM — and the honest caveats

### 1.1 What the BEAM buys us

| Property | What it means for a harness |
|---|---|
| Preemptive lightweight processes | Every strand, subagent, tool execution, LSP client, and stream parser is its own process. Millions are cheap. No async coloring, no event-loop starvation. |
| Supervision trees | Crash recovery is *structural*. A dying tool executor is restarted by its supervisor; durable operation state says where to resume. |
| Fault isolation | A panicking decoder in one strand cannot corrupt another strand's heap. Per-process GC; no global pauses. |
| `gen_statem` heritage | pi's operation state machine is literally the shape of this OTP behaviour. |
| Hot code loading | The self-improvement loop is a native VM feature. |
| Distribution | Trusted harness nodes can cluster; location transparency makes remote executors a driver, not an architecture change (§5.6). |

### 1.2 What Gleam adds on top

- **Sound static types with exhaustiveness checking.** The operation state machine, transition table, and classification order become total functions over ADTs. Whole categories of pi's race catalog become unrepresentable.
- **No reflection, no dynamic dispatch, no macros.** A security feature (§6): a Gleam module's capabilities are visible in its imports and `@external` declarations. Static analysis of Gleam source is tractable in a way it is not for Python, JS, or Erlang.
- **Compiles to both Erlang and JavaScript.** Harness core targets Erlang; wire-protocol types and thin-client UI code (§8.5) share source with a JS-target frontend.

### 1.3 The caveats we design around (not away)

**BEAM processes are fault isolation, NOT security isolation.** Any process in the VM can call `os:cmd/1`, open any file the OS user can, spawn ports, and dial the network. There is no intra-VM capability model. Therefore:

> **Rule Zero: model-influenced execution never runs in the harness VM.** The BEAM node is the *orchestrator*. Untrusted work — shell commands, agent-written code, MCP servers — runs in OS-sandboxed external processes (§5) or in disposable, jailed *satellite* BEAM nodes (§6). The actor model gives us orchestration wins; the kernel gives us security. We never confuse the two.

**Erlang distribution has no security model worth the name.** The cookie is a one-time handshake secret; a connected node is *fully trusted* — it can run code, load modules, and read state on any peer. Hence the two-channel doctrine (§5.6): native distribution never crosses a trust boundary.

**Erlang FFI is the escape hatch that must be guarded.** Gleam's purity holds only for pure Gleam; `@external(erlang, ...)` reaches anything. The capability story (§6.3) includes a source-level vetting pass that rejects or allowlists FFI.

**Ecosystem gaps.** Gleam's library surface is young. We accept writing our own SQLite glue (or `sqlight`), our own provider SDK, and thin Erlang shims where OTP features lack wrappers. Priced into the roadmap.

---

## 2. Architecture overview

```
┌────────────────────────────────────────────────────────────────────┐
│  HARNESS NODE (trusted BEAM VM, one OS process)                    │
│                                                                    │
│  SessionSupervisor (one per open session)                          │
│   ├── StorageWriter      gen_server; THE single writer; owns       │
│   │                      the commit queue + SQLite handle          │
│   ├── StrandSupervisor                                               │
│   │    ├── Strand "main"   gen_statem-shaped; drives the op machine  │
│   │    ├── Strand "sub:1"  subagent strand (same code, own cursor)     │
│   │    └── ...                                                     │
│   ├── EventBus           pg-based pub/sub of harness events        │
│   └── ProjectionSup      rebuildable read models (search, stats)   │
│                                                                    │
│  ToolBroker              the ONLY door to the outside world        │
│   ├── ExecPool           supervised sandboxed OS executors         │
│   ├── LspSup             LSP clients (ports to language servers)   │
│   ├── DapSup             DAP clients                               │
│   └── SatelliteSup       jailed satellite BEAM nodes (code mode)   │
│                                                                    │
│  ProviderGateway         typed LLM provider clients + routing      │
│  ClientGateway           websocket/SSE surface for thin clients    │
│  ExtensionZone           hot-loadable vetted agent-written modules │
└────────────────────────────────────────────────────────────────────┘
          │ kernel-enforced boundary (Landlock/Seatbelt/bwrap)
          ▼
   sandboxed executors · satellite nodes · language servers · MCP srvs
   (local, or remote over tunneled data-plane channels — §5.6)
```

Three planes, strictly layered:

1. **Durability plane** — storage, the three stores, the conversation tree. Knows nothing about agents. (§3)
2. **Orchestration plane** — strands, operations, queues, the state machine, events, hooks, inter-agent messaging. Pure Gleam over the durability plane. (§4)
3. **Effect plane** — everything that touches the world: providers, tools, sandboxes, code mode, remote executors. All effects flow through typed brokers with capability tokens. (§5–6)

---

## 3. Durability plane

We adopt pi's storage model with conviction, noting where the BEAM changes the implementation, not the model.

### 3.1 The three stores

```
entries     the conversation tree — write-once, append-only
registers   current mutable state — namespaced typed cells
usage       append-only cost ledger
```

Every durable payload lives in exactly one. Projections (branch index, FTS, stats) are rebuildable and carry no authority.

### 3.2 The durable program counter

After every step, one register — `op.state/{operation_id}` — is overwritten with the **complete, total** current state of the operation. Recovery reads that register and switches on it. No journal replay, no inference from absence. The terminal transaction deletes the operation's registers and records `strand.last_result`. A finished session holds exactly: conversation, ledger, a handful of strand/fact registers.

```gleam
pub type OperationState {
  RunState(control: Control, settings: RunSettings, phase: RunPhase,
           inbox: Inbox, latest_assistant: Option(EntryId))
  CompactionState(control: Control, structural: StructuralDecision)
  NavigationState(control: Control, nav: Navigation)
}
```

Every transition is a pure function `fn next_action(OperationState, PlannerInputs) -> Action` — exhaustive by construction, property-testable in isolation; the commit is performed by the StorageWriter. "Compute the next total state in memory, then atomically commit everything that makes it true" is the entire concurrency doctrine.

### 3.3 The effect sandwich

```
commit:  intent   — "about to do X; output will use reserved ids R, U"
         do X     — the only non-durable window
commit:  settle   — output + usage + next state, atomically
```

Tools declare `replay: Never | Safe`. On recovery, an effect-pending `Never` call gets a synthetic error result under its pre-reserved id; a `Safe` call re-executes with persisted arguments. Nothing runs twice, every call has a result, billing survives everything.

### 3.4 Backends

- **Primary: SQLite, one file per session.** WAL, `BEGIN IMMEDIATE` on every commit, fenced writer lease (cross-OS-process defense in depth), the private segmented branch index — as pi specifies. One file per session confines corruption, makes deletion `rm`, and makes fork/precise-rewrite file operations.
- **Memory backend** for tests, same conformance suite.
- **BEAM-native option (later): `disk_log` + ETS** — pi's JSONL backend with a battle-tested log engine underneath (framing, torn-write repair built in) and ETS as the live maps. For embedded/edge; not primary because indexed branch scans matter at scale.
- **Explicit non-choices**: no Mnesia (replication rides raw distribution — trust problem; netsplit story; schema/topology coupling), no DETS (2GB limit, slow repair; SQLite dominates). We take OTP's process model, not its database.

### 3.5 The one writer, made structural

pi enforces single-writer with a lease because a TS process can't own anything. Here **the StorageWriter gen_server *is* the serialization point**: all commits are calls into one process; ordering is the mailbox. "Transactions on one session are serialized" is free; intra-node races are gone by construction and pi's race catalog shrinks structurally.

### 3.6 Event stream

Every commit publishes typed events (`entry_added`, `op_transition`, `usage`, ...) on the session's EventBus (`pg` scope). Projections, UIs, and telemetry subscribe; all are catch-up-capable via `scan_*` with a persisted high-water `seq`. **Events are hints; pulls are truth.**

### 3.7 Registers: ownership, sharing, and concurrency

Registers are session-scoped storage, but *ownership is baked into the key structure* — almost none are shared cells:

- `strand.*` keys are keyed by strand name: disjoint per strand; no strand writes another's keys (the Session API simply offers no cross-strand writes).
- `op.*` keys are keyed by operation id: owned by exactly one strand at a time; created at acceptance, deleted by the terminal transaction.
- `pending.entry/{id}` is owned by whichever queue list references the id.
- **`fact.*` is the one genuinely shared namespace** — the multi-agent blackboard (§4.6).

Concurrency safety comes from three layers, not locks:

1. **Total write ordering** — all commits flow through the StorageWriter; no concurrent writers exist.
2. **Atomic transactions** — all-or-none with strictly increasing seqs; no reader ever observes half a commit.
3. **Seq-conditional commits (optimistic CAS)** — each register carries the seq of its last write; a transition commit asserts the expected seqs (`op.state`, `strand.state`, config when snapshotting). Stale expectation → commit refused → the strand reloads and replans. Transactions rewriting `strand.state` re-read the latest value and change only their own fields, so terminal cleanup coexists with a concurrently enqueued `next_run` without clobbering.

Registers are durable state, **not a communication medium**: there is no watch/notify on a cell. Change notification is the EventBus (hints) plus doorbells (§4.6); registers are what you read at decision points and what recovery reads after a crash — five point-lookups per strand and you know exactly where you were.

---

## 4. Orchestration plane

### 4.1 Sessions as supervision trees

Opening a session boots a `SessionSupervisor` (rest-for-one): StorageWriter first, then StrandSupervisor, EventBus, projections. Killing the OS process, killing any child, or `close()` converge on one path: reboot the tree; each Strand reads its registers, validates the entries/registers they name (bounded checks as total decoders: parse fully or report corruption), and resumes. **Crash recovery and cold start are the same code.**

### 4.2 Strands as processes

A strand runs the driver loop: load planner inputs (bounded, exact-id reads) → `next_action` (pure) → perform (`transition` commit / `dispatch` effect / `await` / `wait` / `finish`). Live effects are monitored children; a strand crash mid-effect *is* the crash-recovery path — one recovery story, not two.

Subagents are strands: same code, own cursor into the shared tree, own model config, spawned under the same supervisor. Forks, parallel approaches over shared history, and thread-style fan-out are all "spawn a strand at entry X."

### 4.3 Queues, steering, abort (adopted from pi)

`steer` / `follow_up` / `next_run` with pending-entry registers, drain modes, `skip_inbox_once`, abort as drain-then-reconcile, terminal transactions as the only cleanup — adopted unchanged. Orchestration semantics orthogonal to runtime; pi got them right.

### 4.4 Model routing (from omp)

`ProviderGateway` holds a typed registry with **role-based routing and fallback chains**: `main`, `subagent`, `plan`, `summarize`, `vision` roles map to (provider, model, thinking-level) with ordered fallbacks so a rate limit never kills a session. Durable state stores resolved `{provider, model_id}`; resolve at dispatch, fail in-band if missing.

### 4.5 Hooks and extensions

Hook points (`before_run`, `before_request`, `before_tool`, `after_tool`, `transform_context`, `before_run_end`, structural decisions) are behaviour-shaped callbacks. First-party hooks are ordinary Gleam. Agent-written hooks live in the ExtensionZone (§7) under supervised, time-boxed, killable wrappers — a misbehaving extension is killed and reported in-band, never able to wedge a strand.

### 4.6 Inter-agent communication: durable payloads, ephemeral doorbells

Strands are processes, so raw `Process.send` between subagents is *possible* — and forbidden as a transport, because a BEAM mailbox evaporates on crash. An unread "found the bug at auth.gleam:42" is simply gone after a supervisor restart: never in the transcript, invisible to recovery, believed delivered. That is exactly the ghost-state the durability plane exists to kill.

> **Doctrine: payloads travel durably; process messages are only doorbells.** Sending a message to another strand = a `steer`/`follow_up` enqueue onto that strand (one commit writing its `pending.entry` register), plus an ephemeral nudge so the target wakes immediately instead of at its next checkpoint poll. A lost nudge costs latency, never data.

Patterns, all from existing machinery:

- **Request/reply** — parent spawns a subagent strand with a task-brief entry; the subagent's terminal result is an entry the parent's checkpoint consumes.
- **Peer-to-peer** — mutual steer-enqueues; two strands genuinely converse, every turn durable.
- **Blackboard** — `fact.custom` registers: shared, transactional session state ("reviewer posts findings; implementer reads them").
- **Broadcast** — EventBus for ephemeral awareness ("strand 3 finished tests"); anything actionable is also written durably.

Consequences: every inter-agent exchange is *in the tree* — replayable, forkable, compactable; a stuck agent's inbox is inspectable durable state, not an opaque mailbox. Multi-agent debugging becomes a read of the transcript.

Scope notes: this is a **correctness** rule, not security — subagent strands are trusted harness code (the model influences their *content*, not their code). Raw ephemeral messages remain legitimate for advisory signals where loss is harmless: progress ticks, heartbeats, cancellation hints ahead of the durable abort. The line: **if the recipient would act differently having received it, it goes through a commit; if it only affects pacing or display, a plain message is fine.**

---

## 5. The effect plane: sandboxing & security

### 5.1 Threat model

Defended, in increasing difficulty: (1) **accidents** — wrong-directory deletion, force-pushes, `.env` in a commit; (2) **prompt injection** — hostile repo/web/tool content steering the model into exfiltration or destruction; (3) **malicious generated code** — code-mode programs or extension candidates attempting escape, exfiltration, persistence; (4) **compromised third-party tools** — malicious MCP servers or language-server binaries.

Non-goals: a hostile *user* on their own machine; kernel 0-days (we reduce surface; VM-grade isolation only in the microVM tier).

### 5.2 Enforcement, not etiquette

All security properties are **enforced below the model** — kernel primitives and broker-side checks. Prompts are UX, never a control.

**Executor sandbox, per platform** (Codex's proven stack):

- **Linux**: `bwrap` constructs the filesystem view (read-only `/`, tmpfs scratch, bind-mounted writable roots); **Landlock** as a second file-access layer; **seccomp** filters syscalls and blocks socket creation under network-off. The executor is a small static helper (Go; bwrap owns namespace construction, keeping the helper clear of the fork-in-a-multithreaded-runtime problem) that parses a serialized policy, applies restrictions to itself, then `exec`s the target.
- **macOS**: `sandbox-exec` with dynamically generated Seatbelt profiles; deny-by-default, parameterized writable roots.
- **Windows**: restricted tokens + ACLs + firewall rules (later milestone).
- **Hard tier**: the entire executor pool inside a microVM (Firecracker) or container for hosted/multi-tenant deployments — same policy language, different driver.

**Sandbox policy is a typed, versioned value stored durably with each execution intent** — the transcript shows exactly what jail every command ran in:

```gleam
pub type SandboxPolicy {
  SandboxPolicy(
    writable_roots: List(Path), readable_roots: List(Path),
    network: NetworkPolicy,            // Off | Proxy(allowlist) | Full
    protected_paths: List(Path),       // .git internals, .env — never writable
    limits: Limits,                    // cpu, wall, mem, pids, fsize, output bytes
  )
}
```

**Memory and pid ceilings are the operator's grant, not the kernel's gift.** `mem_bytes` and `pids` need a cgroup — `RLIMIT_AS` is per-process and escaped by forking, `RLIMIT_NPROC` is per-user — and cgroup v2 will not enable controllers for the children of a cgroup that has member processes. The helper's own cgroup always contains the helper, so it can only serve as a base in the true root cgroup. Any *delegated, process-empty* cgroup works, which is exactly what systemd's `Delegate=yes` (with `DelegateSubgroup=` on v254+) produces; the operator names one in `LOOM_CGROUP_BASE` or `--cgroup-base` and the helper enables `memory` and `pids` for its children. Absent that grant the two ceilings are **not** applied, and the per-execution enforcement report says so with a `skip:cgroup-v2` entry — which fails a full-enforcement demand rather than passing one with the ceilings quietly missing.

**Defaults**: workspace-write, network **off**, `.git/`, `~/.ssh`, credential paths protected. Secrets are injected into provider calls by the ProviderGateway from the OS keychain — never in tool environments, never in transcripts; executor environments are allowlist-constructed, not inherited. `Proxy(allowlist)` egress runs through a harness-owned proxy; the sandbox blocks direct sockets, making the allowlist enforceable and loggable.

### 5.3 The ToolBroker: one door, capability tokens

Every effect flows through the ToolBroker. Clearing a tool call mints a **capability token**: an unforgeable ref binding `{operation_id, step_id, policy, deadline}`. Executors, LSP calls, and satellite nodes accept work only with a live token; abort revokes tokens, and revocation kills the OS process *group* (executors run in their own pgroup/cgroup — cleanup is `SIGKILL` to the group; no orphaned `npm install`).

**Approval escalation, Codex-style**: a sandbox denial (or pre-declared need) produces an in-band structured escalation → surfaced with the exact policy diff ("wants: network to registry.npmjs.org") → on approval, *one* re-execution under the widened policy, recorded durably. "Approve similar for this session" widens the session policy explicitly, never silently.

### 5.4 Filesystem tools with correctness teeth (from omp)

- **Hashline edits**: reads return content-hash-anchored lines; edits reference anchors. Stale anchors reject the patch *before* corruption — a correctness win independent of model quality, and a TOCTOU defense between read and write.
- **LSP as a first-class tool**: rename/references/diagnostics through the project's language server (supervised port). Semantic refactors, not regex surgery; post-edit diagnostics close the loop.
- **DAP as a first-class tool**: breakpoints, stepping, inspection — the agent debugs by *running into* the failure.
- Language servers and debug adapters are third-party binaries ⇒ they run **inside the executor sandbox** (read-mostly policy).

### 5.5 MCP, contained

MCP is supported for reach: servers spawn inside sandbox policies like any executor; schemas validated at the broker; output is **data, never instructions** — results carry provenance tags through context projection so injection-bearing output can be flagged/transformed by hooks. Prefer code mode over MCP round-trips where possible.

### 5.6 Remote execution and the two-channel doctrine

Erlang distribution is location-transparent (`send`, monitors, spawn across machines; full mesh; epmd discovery) and **fully trusting after handshake** — a connected node can run anything on any peer. Hence:

> **Two channel types, never confused.**
> **Data plane** — framed RPC (length-prefixed msgpack) over stdio / Unix sockets / SSH tunnels / mTLS — to everything untrusted or semi-trusted: executors, satellites, language servers, MCP servers, *and their remote equivalents*. Every message is parsed and validated as data.
> **Control plane** — TLS-wrapped native distribution (`inet_tls_dist`, cookie + mTLS, libcluster discovery) strictly between orchestrator nodes *you operate*, for session routing and event fan-out. Native distribution never crosses a trust boundary.

What can live on another machine, all via the data plane:

- **Remote executor pools** — the same sandbox helper + policy on a build server, GPU box, or customer VM, tunneled. The strand's state machine is unchanged: the effect sandwich already assumes effects are uncertain and remote; a partition mid-command is just the recovery path. This is Codex-cloud-style remote execution nearly for free.
- **Remote satellite nodes** — code-mode programs near the repo or the compute.
- **Session mobility** — a session is one SQLite file + a supervision tree booted from it: close, copy, open elsewhere (§8.5).

BEAM location transparency then does something subtle for the codebase: the ToolBroker genuinely does not care whether an executor answers from `/usr/lib/loom/exec-helper` or a datacenter — same monitors, same timeouts, same recovery. **Remote execution is a driver, not an architecture change.**

---

## 6. Code mode: Gleam as the tool language

### 6.1 The idea

Instead of N round-trips of `tool_call → result`, the model writes a **program** composing tools locally — loops, conditionals, intermediate values, concurrency — and the harness executes it, returning a structured result. Fewer round-trips, radically less context on intermediate payloads, and multi-tool workflows become durable, debuggable artifacts. The code-mode language is **Gleam itself**.

### 6.2 Why Gleam is an unusually good sandbox language

Pure Gleam cannot do I/O; every effect enters through an import that ultimately declares `@external`. No reflection, no eval, no dynamic module lookup, no macros. Therefore:

> **A Gleam program's maximal capability set is computable from its source: the transitive closure of its imports plus its own `@external` declarations.**

The vetting pass is a compiler-adjacent lint, not a heuristic: (a) pin dependencies to the harness capability prelude; (b) reject `@external` in submitted source; (c) reject imports outside the allowlist. **The prelude *is* the capability system**: `cap/fs`, `cap/proc`, `cap/net`, `cap/lsp`, `cap/git`, `cap/task`, `cap/actor`, `cap/report` — typed modules whose implementations are RPC stubs to the ToolBroker carrying the execution's token. The type checker becomes the tool-argument validator: malformed tool use fails at compile time, a cheaper loop than runtime tool errors.

### 6.3 Defense in depth: satellite nodes

Vetting is strong; we don't bet the farm on it. Programs execute in a **satellite node**: a disposable `erl` OS process launched *inside the executor sandbox* (network off except the UDS/stdio channel to the broker), with distribution disabled (no epmd, no inet dist — framed channel only), per-process `max_heap_size`, cgroup memory/CPU, a wall-clock deadline, and killable as a unit. A hostile `.beam` that slipped vetting sits in a jail whose only reachable effects are token-checked broker RPCs. Escape requires a vetting bypass *and* a kernel escape.

```
model emits Gleam → vet (imports/@external lint)      [harness, pure]
                  → gleam build vs pinned prelude     [sandboxed executor]
                  → run in fresh satellite node       [sandboxed satellite]
                  → cap calls RPC to ToolBroker       [token + policy checked]
                  → result marshalled back; node destroyed
```

Source and artifacts are stored as entries — every executed program is auditable history and a promotion candidate (§7).

### 6.4 Cells and escape hatches

A satellite kept alive across invocations = omp-style persistent cells; killing it is state reset. Bash remains a plain executor tool when a one-liner beats a program.

### 6.5 Concurrency and actors in code mode

The satellite runs a full BEAM, so agent programs get real concurrency — through curated capabilities, never the raw process API (which would allow unbounded spawns and messages to arbitrary registered names, including the broker channel).

**`cap/task` — structured concurrency only.** Every task is a child of the program root; results are awaited or the tree dies together; killing the satellite reaps everything. No detached processes.

```gleam
task.parallel_map(sites, max_concurrency: 8, fn(site) { ... })  // order-preserving
task.race([strategy_a, strategy_b])   // losers *actually* cancelled: their
                                      // capability calls revoke → pgroups killed
task.both(run_lint, run_tests)        // pipeline while a long job runs
```

Semantics pinned: `parallel_map` preserves input order regardless of completion order; failures aggregate by default with `fail_fast: True` opt-in; cancellation is real, not advisory.

**Broker-side limits are pooled per execution, not per call**: one token backs many in-flight RPCs, so the budget is aggregate — max outstanding effects, one cgroup for all fanned-out executors (aggregate CPU/mem/pids), one wall-clock deadline. This closes the amplification hole (10,000 polite parallel reads; 50 spawned test runs). Each `proc.run` still gets its own jail; they share a budget.

**`cap/actor` — typed, program-scoped actors** (a constrained gen_server): spawn with initial state + typed handler; get an unforgeable typed address; send/call. Guardrails mirror `cap/task`: actors live under the program root and die with it; no global registration; bounded mailboxes (backpressure, not OOM). Earn their keep for ongoing state + async input: watching a build's output stream and reacting to the first error, a DAP stepping coordinator, work-stealing queues where items generate items.

**Persistent actors** (Tier 2): in a kept-alive satellite, actors persist across code-mode calls — the model builds itself a stateful service mid-session (spawn an indexer in call 1, query it in calls 2–10). Nothing MCP-shaped can express this. Satellite state is *ephemeral by design*: anything worth keeping exits via `report` artifacts or a `cap/kv` scratch store; programs must tolerate a vanished actor.

**Tier 3 is the punchline**: an L3 extension (§7) is literally an OTP actor — a supervised process implementing a typed behaviour. The agent prototypes a stateful helper as a jailed actor, proves it, and promotion turns the same actor-shaped code into a durable, supervised citizen of the harness. Same programming model at every trust level.

Deliberately **not** exposed in code mode: links/monitors with custom trap-exit logic or self-defined supervision strategies. Policy is fixed (all-for-one under the program root); crashes propagate up; the program fails as a unit; the strand sees a structured error. Exotic OTP surface is for L3, where a human approved it.

---

## 7. Self-improvement: the staged trust pipeline

Hot loading makes runtime self-improvement native — and it is the most dangerous feature here. The design is a **promotion ladder**, each rung enforced by the harness:

```
L0  code-mode program     ephemeral, satellite-jailed, dies with the call
L1  session skill         L0 saved as a durable, named, reusable entry;
                          executes at L0 privileges
L2  extension candidate   compiled against the extension API (wider but still
                          capability-stubbed prelude); runs its test suite +
                          property tests in the sandbox; results attached
L3  installed extension   after explicit user approval (or signed org policy):
                          hot-loaded into the harness ExtensionZone
L4  core change           a PR to Loom itself; ordinary review + release;
                          never runtime-loaded
```

Hard rules:

- **L3 is the only rung touching the harness VM**, and the ExtensionZone is confined: typed behaviours (tools, hooks, projections), supervised time-boxed wrappers, harness-controlled module names. Vetting runs on **source** (same `@external`/import lint against the extension allowlist) and the harness compiles the source itself — **we never load a `.beam` we didn't compile.**
- **Nothing self-promotes.** The agent proposes; L2→L3 requires a human decision (or pre-declared policy), recorded durably.
- **Every rung is revocable and observable**: versions, unload/rollback (`code:purge` + reload previous), durable load/unload events.
- **The trusted computing base is not runtime-extensible.** Storage, state machine, broker, sandbox drivers never change at runtime. Self-improvement grows the tool and hook surface only. This line is what makes the idea shippable.

Payoff: the agent hits a workflow gap, writes the tool, proves it against tests in a jail, and — with one approval — the *running session* gains it. With hindsight-memory skills at L1, capability compounds per-user without a release cycle.

---

## 8. Context & conversation intelligence

- **Tree + strands** (pi's lanes): branching, forking, parallel exploration over shared history; compaction as self-contained checkpoints (summary + retained tail; context never reads past a compaction); append-only context tail preserving provider KV caches; one-shot overflow compact-and-retry.
- **Triggered rules** (omp's TTSR, adapted): project rules dormant at zero context cost; a per-strand stream-scanner process injects a rule when its trigger fires in model output. Cheap, killable, off the hot path.
- **Hindsight memory**: session-end reflection distills per-workspace lessons (facts/entries in a memory session), surfaced by relevance; promoting a lesson to an L1 skill is one step.
- **Subagent context discipline**: scoped context (branch + task brief) in, structured results out; full transcripts stay in the tree for audit without polluting the parent's context.

### 8.5 Thin clients and session mobility

Because a session is one file plus a tree booted from it, the UI is **always a thin client**: the TUI, editor plugins, and web/mobile surfaces speak one ClientGateway protocol — subscribe to the event stream (snapshot + live events with catch-up-by-seq), send commands (`prompt`, `steer`, `abort`, `approve`, `fork`, strand ops). The local TUI talking to a local harness and a phone talking to a cloud harness are the same protocol; Gleam's JS target lets the wire types be shared source. Session mobility = close, copy the file, open elsewhere; a fleet of orchestrator nodes (control-plane clustered, §5.6) routes clients by session id.

---

## 9. Correctness & robustness strategy

- **Types first.** Transition tables, classification order, queue semantics, and the placement invariant ("at every commit boundary a queued id has register XOR entry XOR neither") encoded so illegal states don't construct. Total decoders at every durability boundary: parse fully or report corruption; never partially trust.
- **pi's conformance suite, ported.** One suite over all backends; invariants + race catalog as property-based tests; plus a **deterministic interleaving harness**: because commits serialize through the StorageWriter and effects are messages, "crash between TX_n and TX_{n+1}" is scriptable for *every* adjacent pair — crash-testing is a for-loop, not an ops exercise.
- **Chaos tier**: randomly kill strands, executors, satellites, and the whole node under load; assert store invariants and that no `replay: Never` effect ran twice.
- **Sandbox regression suite**: known-escape probes (dial-out, writes outside roots, protected paths, env leakage, pgroup orphaning) against every policy tier, every platform, in CI. The sandbox is tested like a product.
- **In-band failure doctrine**: unknown tools, missing providers, vetting rejections, compile errors, policy denials all settle as structured error results the model can react to; the harness never wedges.

## 10. Performance notes

- Hot path per turn: a few register upserts + entry inserts into per-session SQLite (WAL, single writer) — sub-ms commits; provider latency dominates by orders of magnitude.
- Streaming parse, event fan-out, TTSR scanning, telemetry each on scheduler-preempted processes: an expensive projection can never delay a settlement.
- Branch reads via the segmented index with asserted query plans; ETS paths for tests/small sessions.
- Subagent fan-out costs a process spawn (~µs, ~kB): "try 3 approaches in parallel" is a default strategy.
- Off-heap refcounted binaries: large tool outputs stream to disk past a threshold and enter context as typed references + excerpts.

## 11. Build order

1. **M0 — Durability plane.** Storage ADTs, Memory + SQLite backends, conformance suite, branch index.
2. **M1 — State machine.** Operation ADTs, pure `next_action`, StorageWriter, single-strand drive loop, crash-anywhere harness.
3. **M2 — Effects.** ProviderGateway, effect sandwich, broker skeleton, bash/read/write/hashline tools **with the Linux sandbox from day one**.
4. **M3 — Strands & subagents.** Multi-strand sessions, queues/steering/abort, inter-agent messaging, forks, compaction, events. macOS Seatbelt.
5. **M4 — Code mode.** Capability prelude (incl. `cap/task`, `cap/actor`), vetting lint, sandboxed compile, satellite nodes, cells.
6. **M5 — Semantic tools.** LSP, DAP, role routing, TTSR, hindsight memory. ClientGateway + TUI thin client.
7. **M6 — Self-improvement.** Skill store (L1), extension API + test-in-jail (L2), approval + hot-load + rollback (L3).
8. **M7 — Hardening & scale.** Remote executor pools, Windows sandbox, microVM tier, control-plane clustering, multi-tenant serving, precise rewrite tooling, record/replay evals.

## 12. Open questions

- **pi wire compatibility**: adopt format-4 JSONL as an import path so users can migrate transcripts?
- **Prelude versioning for L1 skills**: recompile-on-load from source (preferred) vs pinned prelude versions.
- **Satellite pooling vs per-call spawn**: cold `erl` start ~100–300 ms; pooled-and-recycled (after N executions or any vetting warning) is the leaning.
- **Record/replay evals**: intents + settlements look sufficient to simulate providers and tools from a recorded session — a killer testing feature if so.
- **`cap/kv` scratch-store semantics**: session-scoped durable scratch for code mode — how much structure before it becomes a second registers system?

---

## 13. Summary of inheritances

| Source | What we take | What we change |
|---|---|---|
| **pi harness spec** | Three stores; write-once tree; durable total-state PC; effect sandwich; lanes (renamed strands); queues; compaction; terminal transactions; conformance discipline | Single writer becomes a gen_server (structural, not leased); recovery = supervisor restart; TS type gymnastics become ADTs; inter-agent messaging built on the queue machinery |
| **Codex CLI** | Kernel-enforced deny-by-default sandbox; network-off default; escalation-by-approval; sandbox-the-tools-not-the-harness; policy as data | Policies as durable typed transcript values; capability tokens; pooled per-execution budgets; egress proxy; satellite tier; remote pools over data-plane channels |
| **omp** | Hashline edits; LSP/DAP as tools; subagents; role routing + fallbacks; TTSR; hindsight memory; cells | Subagents become strands over the shared durable tree; cells become satellite nodes; rules as stream-scanner processes |
| **BEAM/Gleam** | Supervision, processes, hot loading, distribution, `pg`, `disk_log`; sound types; no-reflection capability analysis | Rule Zero (kernel isolates threats, BEAM isolates faults); two-channel doctrine (distribution never crosses trust boundaries); curated concurrency capabilities in code mode |

---

## Appendix A — OTP building blocks referenced

- **`gen_statem`** — OTP state-machine behaviour (`handle_event(State, Event) -> {Next, Actions}`); the native idiom for the operation machine, with durable state in `op.state` and the process as its disposable interpreter.
- **ETS** — in-memory term storage; microsecond lookups; dies with its owner. Cache tier only.
- **`disk_log`** — append-only log engine with framing, torn-write detection/repair, wrap logs. Engine for the alternate BEAM-native backend.
- **`pg`** — process groups: distributed name→pids registry, local-speed lookups. The EventBus; transparently spans trusted clusters.
- **DETS / Mnesia** — considered and rejected (limits; trust-model and topology coupling).
- **epmd / distribution / `inet_tls_dist`** — node discovery and clustering; TLS-wrapped and confined to the control plane.
- **libcluster** — node-discovery strategies (K8s, EC2, gossip, static) for the orchestrator fleet only; adds discovery, not security.
