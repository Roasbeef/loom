# protocol-change/078: remote workspaces over trusted distribution

**Status**: ACCEPTED 2026-10-07 (direction approved by the owner). Field
spellings below are provisional until phase 1 lands; this document is updated
to the implemented spellings before the change merges.
**Affects**: the control command `sessions.create` and session records (one
optional field each), the catalogue schema (version 10, one column),
`loom.toml` (a `[distribution]` table and `[executors.*]` rows on an
orchestrator, `[workspaces.*]` rows on an executor), `effects.ToolSurface`
(one slot), and two new formats that are not Part 1 interfaces: the closed
message vocabulary between orchestrator and executor nodes, and the
executor's execution ledger. The helper wire (Part 1.4) is unchanged.
**Raised by**: issue #697 and the owner's takeover ruling of 2026-10-07.
**Design**: [docs/design-notes/distributed-runtime.md](../docs/design-notes/distributed-runtime.md).
**Supersedes**: the unmerged drafts carried by PR #819 under the numbers 066,
067, 071, 078 and 079 (remote workspace services, registered LSP, registered
generations and their October addenda). None reached main, so no frozen
interface is withdrawn; their numbers also collided with main's own 066, 067
and 071.

## Problem

A session's checkout, toolchains and native effects must be able to live on a
different machine from its conversation store, approvals and provider
credentials, with the checkout absent from the orchestrator. Today the daemon
assumes the workspace path is local in three places a client can see: the
`workspace` argument of `sessions.create` is canonicalized on the daemon's
filesystem, the catalogue stores it as a local path, and every tool runs
against it in the daemon's VM.

## What was considered

### A typed RPC per filesystem and process operation

PR #819's approach. Each operation (read, write, anchored edit, list, search,
stat, Git, Compile, Launch, LSP request) became a remote request with its own
codec, journal and custody record, and ordinary tools were reimplemented over
it. Rejected: it duplicates every tool's semantics behind a second interface,
it needs at-most-once custody for reads that are safe to repeat, and after
about 220k lines it had no production caller.

### A remote broker dispatcher or helper transport

Moving only the jailed command path (`broker/dispatch.Dispatcher` or the
helper port) to the executor. Rejected as the primary cut: harness-side tools
(`fs_*`, search, blobs, working-directory validation, the LSP door) would
still read the orchestrator's disk, and a code-mode satellite could not reach
its capability socket. It is kept in one narrow form, a remote `Broker`
handle, for non-tool callers.

### Whole tool calls at `ToolSurface.run`

Chosen. `ToolRun` and `ToolOutcome` are plain data, the runtime already makes
the call's intent durable before the effect, and the executor can run main's
unchanged workspace plane beside the checkout.

## Proposal

### Client protocol (Part 1.6)

`sessions.create` gains an optional `executor` string. When present,
`workspace` is the name of a workspace registered on that executor, not a
path, and the daemon never canonicalizes it locally; the executor validates
it when the scope attaches. When absent, behavior is exactly today's. A
session record gains an optional `executor` member that a client which does
not know it ignores. One refusal code is added, `executor_unknown`, for an
executor name this orchestrator has not configured. A configured executor
that cannot attach the scope is not a separate wire code: the opening fails
the way an unavailable workspace fails today, and `operations.get` reports
`start_failed` with a reason beginning `executor_unavailable:`. The
registration stays reserved, so a retry under the same creation key tries
again.

A registered workspace name is 1 to 128 bytes with no `/` and no NUL, so it
can never be mistaken for a local path, which always starts with `/`. A
session created with an `executor` defaults to the `session_only` domain
scope and refuses `workspace_private`, because the workspace aggregate is
keyed by path and two executors may register the same name. For the same
reason a registered session can never be a workspace default.

### Catalogue (version 10)

`Registration` gains `executor: String`, empty for a local session. The
migration from version 9 adds the column with an empty default. A
registration with a non-empty `executor` stores the registered workspace name
in `workspace`, never a path on the orchestrator.

### Configuration

On both roles, `[distribution]` names the local node, the TLS credential
files (CA, certificate, key, cookie, all private to the operator) and the
pinned peers (node name and leaf SHA-256). On an orchestrator,
`[executors.<name>]` names a peer node. On an executor, `[workspaces.<name>]`
names a root and its access, and the machine's own toolchain and LSP tables
apply. A daemon with no `[distribution]` table never starts distribution.
Every key is documented in `docs/configuration.md` and gated by
`make doc-check`.

The VM must boot with `-proto_dist inet_tls` and an `-ssl_dist_optfile`
before `net_kernel` starts; the release's launcher passes them when, and only
when, `[distribution]` is present.

### `ToolSurface.recover`

`effects.ToolSurface` gains `recover: Option(fn(ToolRun) -> Recovery)`. When it
is `Some`, the runtime recovers an orphaned tool call by spawning an effect
that calls it, exactly as it spawns `run`, and the effect reports through the
same `ToolDone` path. The function may block: it attaches if needed, then
queries the call key until the ledger settles.

```gleam
pub type Recovery {
  /// The executor holds the call's finished outcome; stage it.
  Recovered(outcome: ToolOutcome)
  /// The executor restarted mid-run; stage the unknown-outcome result.
  OutcomeUnknown
  /// The call never reached the executor and, after the attach, cannot.
  /// A `ReplaySafe` call takes the planner's existing replay arm; any other
  /// call is staged as not started.
  NotStarted
}
```

A local session's surface sets `recover: None`, so its recovery is unchanged.

### Node vocabulary

All messages between nodes are values of closed custom types holding only
strings, integers, bit arrays, lists, the existing plain-data runtime types
(`ToolRun`, `ToolOutcome`, `AgentMessage`, `escalate.Refused` and `Decision`)
and `Subject`s. No function, port, reference to node-local storage or atom
built from a peer's input crosses. Every receiver decodes with total
decoders and bounds each message's size.

Orchestrator to executor:

| Message | Meaning |
|---|---|
| `Attach(session, workspace, incarnation, token, owner_port, reply)` | Sent each time the orchestrator opens the session. Start or adopt the scope at this incarnation and make `token` its only valid attach token. Replies with the census and the scope's unacked terminal keys, or a refusal. |
| `Run(key, incarnation, token, run, authority, reply)` | Run one tool call. Idempotent by `key`. Admitted only if `incarnation` and `token` equal the scope's. The host monitors the sender: a DOWN other than `noconnection` cancels the run. |
| `Query(key, reply)` | Return the ledger state and outcome for `key`, in any scope state or incarnation. |
| `QueryOrFence(key, reply)` | Like `Query`, but when no row exists, atomically insert a terminal "did not start" row so a stale `Run` for that key can never start. Used to recover an orphaned call that is not replay-safe. |
| `ListUnacked(session, reply)` | List the scope's terminal and unknown keys without attaching, for the orchestrator's acknowledgement reconciler. |
| `Ack(key)` | The orchestrator has durably staged this outcome. |
| `Close(session, workspace, incarnation, reply)` | Close the scope and report `all_retired` or `unknown(count)`. |

There is no cancel message. Abort kills the orchestrator's effect process,
and the host's monitor on it turns that into a cancel.

Executor to orchestrator, to the session's owner port:

| Message | Meaning |
|---|---|
| `Escalate(refused, reply)` | Ask for an approval decision. |
| `FactGet(key, reply)`, `FactSwap(key, expected, new, reply)`, `FactList(prefix, reply)` | Read, compare-and-set or list a reserved owner fact (`client/working_directory/*`, `job/*`). |
| `Notify(strand, text, reply)` | Deliver a background job's completion notice to its strand. |
| `Tail(...)` | A live output hint; may be dropped. |
| `OwnerCapability(request, reply)` | A satellite's owner-bound capability call. |

The host monitors the owner port. A DOWN while a callback is outstanding
settles that callback with an in-band failure, so the call reaches
`terminal` instead of waiting on a reply nobody will send.

The remote broker handle uses `broker.Msg` unchanged, except that a
`CallSpec`'s absolute deadline is sent as the remaining duration and rebased
on the executor's clock, and the workspace path in the spec comes from the
census as an opaque string.

A remote session refuses extension tools and operator-added directories in
this change; both read orchestrator-side state that has no executor
counterpart yet.

### Execution ledger

One SQLite file under the executor's state root, owned by one node-level
actor; rows are keyed by session:

```sql
CREATE TABLE scope (
  session TEXT NOT NULL,
  workspace TEXT NOT NULL,
  incarnation INTEGER NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('open', 'closing', 'closed')),
  close_outcome TEXT,          -- 'all_retired' | 'unknown:<n>'
  attach_token BLOB NOT NULL,
  PRIMARY KEY (session, workspace)
);

CREATE TABLE call (
  session TEXT NOT NULL,
  op TEXT NOT NULL,
  step TEXT NOT NULL,
  source_index INTEGER NOT NULL,
  incarnation INTEGER NOT NULL,
  tool TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('admitted', 'terminal', 'unknown')),
  outcome BLOB,
  outcome_digest BLOB,
  outcome_bytes INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (session, op, step, source_index)
);
```

Admission inserts `admitted` in the same transaction that checks
`scope.state = 'open'` and compares the request's incarnation and attach token
for equality. A recovered
`admitted` row becomes `unknown` at startup and is never relaunched. An
executor admits at most 16 scopes that are not `closed` with
`all_retired`, and a byte budget bounds unacked outcomes. Reopen requires
`closed` with `all_retired` and increments `incarnation`.

## Impact

- `client`: the workspace plane is split out of `serve.assemble_in`; new
  executor role, workspace host, owner port and remote surface. Local sessions
  run the same assembly in-process.
- `runtime` and `machine`: one `ToolSurface` slot and one recovered tool
  observation. The machine stays pure.
- `broker`: a public constructor for a `Broker` over a remote subject.
- `storage`: catalogue version 10; the ledger's generated SQL.
- New Erlang FFI: the TLS distribution verify function and boot checks
  (about 185 lines), the only thing `gleam_erlang` cannot express. It lives in
  an `internal/ffi_*` module with the reason recorded.
- Formal models: the TLA+ directory and handoff specs and a P model of the
  ledger states, gated by `make model-check`.

Local sessions see no behavior change. A daemon without `[distribution]`
never starts `net_kernel`, and its sessions never consult the ledger.
