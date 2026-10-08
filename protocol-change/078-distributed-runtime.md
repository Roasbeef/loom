# protocol-change/078: remote workspaces over trusted distribution

**Status**: ACCEPTED 2026-10-07 (direction approved by the owner). Field
spellings below are provisional until phase 1 lands; this document is updated
to the implemented spellings before the change merges.
**Affects**: the control command `sessions.create` and session records (one
optional field each, and a second pair for pools, see the addendum), the
catalogue schema (version 10, one column; version 11, one more),
`loom.toml` (a `[distribution]` table and `[executors.*]` rows on an
orchestrator, `[pools.*]` tables beside them, `[workspaces.*]` rows on an
executor), `effects.ToolSurface`
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

#### Addendum: the first-party clients

Both clients now send `executor`; the control protocol gains nothing for it.

The terminal takes `loom --executor <name> --workspace <registered name>`. With
an executor `--workspace` is a name, never a path: it is kept apart from the
launcher's canonicalized `Options.workspace`, validated against the shapes above
before a request is built, and refused together with `--session`, which names a
session that exists. The picker's `n` then sends `sessions.create` with
`workspace` set to the name and `executor` set. The terminal words
`executor_unknown` and an `executor_unavailable:` start failure as such, and
shows a session row's optional `executor` member (`box:proj` in listings, `PROJ
on box` as a picker group, since two executors may register the same name).

The web home learns the executor names in process and not over the wire: the
daemon hands them to the owner's page that holds the creation capability when the
page opens (`server.HomeAttachment.executors`, the startup capture of
`[executors.<name>]`), as it hands it the model profile names. The new-session
section then offers a form with an executor select, a typed registered name and
an optional session name. An executor travels as a position in the list the page
was given and is turned back into the name by the form's decoder, so a browser
can choose among the executors the page drew and name no other. The daemon's
creation (`ui_socket.create_for`) judges only the name's shape and the
executor's presence in the configuration, and makes the session session-only
whatever the form said. A session list entry carries the optional executor, and a
remote group is headed `executor:name` and offers no directory-style "New
session" button.

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
names a `root` (absolute, an existing directory, and nothing else for now),
and the machine's own toolchain, LSP, `[tools]`, `[workspace]` and `[jobs]`
tables apply. A daemon with at least one row starts the host. A daemon with no `[distribution]` table never starts distribution.
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
| `Attach(version, session, workspace, incarnation, token, owner_port, reply)` | Sent each time the orchestrator opens the session. `version` is `protocol.version` (1); any other value is refused with `VersionMismatch`. Start or adopt the scope at this incarnation and make `token` its only valid attach token. The plane is built asynchronously and the reply, the census and the scope's unacked terminal keys or a refusal, is sent when the build lands. While it builds, a second `Attach`, a `Run` and a `Close` for the session are refused with `PlaneBuilding`. |
| `Run(key, incarnation, token, run, authority, reply)` | Run one tool call. Idempotent by `key`. Admitted only if `incarnation` and `token` equal the scope's. The host monitors the sender: a DOWN other than `noconnection` cancels the run. |
| `Query(key, reply)` | Return the ledger state and outcome for `key`, in any scope state or incarnation. |
| `QueryOrFence(key, incarnation, reply)` | Like `Query`, but when no row exists, atomically insert a terminal "did not start" row so a stale `Run` for that key can never start. Used to recover an orphaned call that is not replay-safe. |
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

### Addendum: executor pools

A session can be created in a pool of executors instead of on a named one, and
the orchestrator picks the executor when the session first opens. This is
phase 2 of the design note.

#### Wire and catalogue

`sessions.create` gains an optional `pool` string, which has the grammar of an
executor name and is exclusive with `executor`: a request that carries both is
`bad_request`. With a `pool`, `workspace` is a registered workspace name exactly
as it is with an `executor`, and the domain scope defaults to `session_only` and
refuses `workspace_private`, for the same reason. One refusal code is added,
`pool_unknown`, for a pool this orchestrator has not configured. A session record
gains an optional `pool` member. A session in a pool has no `executor` member
until its first open chooses one; from then on the record carries both.

The catalogue is at version 11. `Registration` gains `pool: String`, empty for a
session created without one, and the migration from version 10 adds the column
with an empty default. The pool is part of the immutable creation request, so a
retry compares it. The executor of a pooled session is the first open's choice
and not part of the request, so a retry compares the pool only, and a retry after
the choice still finds its reservation. The executor column is written once, by
`seed_executor`, and only for a registration that has a pool and no executor.

#### Configuration

`[pools.<name>]` lists `executors`, which must each be a configured
`[executors.<name>]`, in the order they are tried. An `[executors.<name>]` row
may also declare `platform`, `enforcement` and `toolchains`, and a pool may
require the same three. The declarations are what the operator says the machine
provides. They are not discovered, and nothing is added to the node vocabulary to
ask. A pool's candidates are the listed executors whose declarations satisfy its
requirements, in the listed order, computed from configuration alone. An executor
that declared nothing cannot satisfy a requirement. After a successful attach the
census is compared with the declaration; a contradiction closes the scope, which
returns its slot, and fails the open with a reason that names the declared and the
reported value. The environment variable `LOOM_EXECUTOR_MAX_SCOPES` lowers the
number of scopes an executor admits from the ledger's default of 16.

#### Placement

The orchestrator's scope record (`client/remote/scope`) gains the executor that
holds the scope, and the record is written after the connection succeeds and
before the `Attach` is sent. That makes an attach whose reply was lost
recoverable: the next open finds the record, goes to the same executor, and the
ledger's rebind makes the retry converge. A record that names an executor is the
only candidate its session ever has, so a reopen never chooses again, and a record
from before this addendum, which names none, takes the executor of the
registration.

A first open, which has no record, tries the candidates in order and goes to the
next one only while no executor can hold a scope for the session. That is the rule
in ledger terms: the connection to a candidate failed before the attach was sent,
or the candidate answered `CapacityExhausted`. The ledger checks capacity inside
the attach transaction, before it inserts the scope and before the host builds a
plane, so the refusal proves that nothing was created and the checkout was not
touched. The record is withdrawn after such a refusal, so the next open chooses
from the whole pool again. These are the only two cases. An attach that got no
answer may have created the scope, so it is retried against the same executor and
never against the next. A scope that was created but whose plane failed to build
is the session's, and the open fails with the record naming it. A
`CapacityExhausted` on a later open is `executor_unavailable:` and never a reason
to move, because the checkout exists only where the record says. This does not
conflict with "no fallback to a different mutable checkout": the rule forbids a
second checkout for a session that already has a scope, and the first open of a
session has none.

The balance is order and not load. Sixteen scopes per executor and a few
executors do not need a least-loaded choice; spreading sessions later means
rotating where the candidate list starts, which adds no message.

#### What it costs

An open into a pool whose first executors are unreachable is slow, because it
connects to each candidate in turn. A declaration can be wrong, and a wrong one is
found when a session attaches and not before: the first open into a pool whose
first executor mis-declared fails once and names the mismatch, and the record
then binds the session to that executor until the file is fixed. And the choice is
never revisited, so a session cannot move to a machine with more room; moving a
session is the controlled movement of phase 5.

#### First-party clients

The terminal takes `loom --pool <name> --workspace <registered name>`, exclusive
with `--executor`, and sends `sessions.create` with `pool`. It words `pool_unknown`
as it words `executor_unknown`. The web home does not offer pools yet.

## Impact

- `client`: the workspace plane is split out of `serve.assemble_in`; new
  executor role, workspace host, owner port and remote surface. Local sessions
  run the same assembly in-process.
- `runtime` and `machine`: one `ToolSurface` slot and one recovered tool
  observation. The machine stays pure.
- `broker`: a public constructor for a `Broker` over a remote subject.
- `storage`: catalogue versions 10 and 11; the ledger's generated SQL.
- New Erlang FFI: the TLS distribution verify function and boot checks
  (about 185 lines), the only thing `gleam_erlang` cannot express. It lives in
  an `internal/ffi_*` module with the reason recorded.
- Formal models: the TLA+ directory and handoff specs and a P model of the
  ledger states, gated by `make model-check`.

Local sessions see no behavior change. A daemon without `[distribution]`
never starts `net_kernel`, and its sessions never consult the ledger.
