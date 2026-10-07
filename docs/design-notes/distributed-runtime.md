# Distributed runtime: brains and hands on different machines

Status: **accepted direction, 2026-10-07.** This note is the design of record
for [issue #697](https://github.com/Roasbeef/loom/issues/697). It replaces the
design carried by draft [PR #819](https://github.com/Roasbeef/loom/pull/819),
which is kept as an archive. The wire and durable formats it introduces are
specified in [protocol-change/078](../../protocol-change/078-distributed-runtime.md).

## 1. Why this note exists

PR #819 spent about 220k lines and 300 commits building remote custody for
every kind of effect before an ordinary session had ever run against a remote
checkout. Each effect family (workspace operations, Compile, Launch, LSP,
reports) grew its own journal, wire format, service, completion codec and
recovery path. Measured over the executor package, the Compile and Launch
services match 90% line for line, and the same journal recovery routine
appears five times. Ordinary tools were rebuilt a second time as a typed RPC
with a canonical msgpack codec, while the real tools stayed local and refused
a remote workspace. When the work paused, `serve.resolve_managed` still
answered "registered workspace assembly is not available", and none of the
remote modules had a production caller.

Two choices drove that growth. Every effect, including retry-safe reads, was
treated as an at-most-once native execution with its own identity and
generation link. And trusted executor membership was adopted (executors join
TLS Erlang distribution) without using what that trust buys: a trusted peer
can run our existing code beside the checkout, so the network boundary does
not have to sit underneath every tool.

This note takes the other path. We move whole tool calls, not file
operations, and we reuse main's effect plane unchanged on the machine that
holds the checkout.

## 2. Topology

A deployment has two roles, both served by the same release:

```text
   clients (TUI, web, phone)
            |
            v
   +---------------------+   TLS Erlang distribution   +----------------------+
   | orchestrator        | <-------------------------> | executor             |
   | "brains"            |   ToolRun / ToolOutcome     | "hands"              |
   |                     |   owner callbacks           |                      |
   | runtime, SQLite,    |                             | checkout, broker,    |
   | approvals, budgets, |                             | helper pool + jail,  |
   | provider creds,     |                             | jobs, LSP, code mode,|
   | gateway, owner tools|                             | hook commands,       |
   +---------------------+                             | execution ledger     |
                                                       +----------------------+
```

Either machine can play either role. The demo runs the orchestrator on a
laptop with the executor on a Linux box, and then the reverse, on the same
candidate. A single machine running both roles is the ordinary local daemon,
and it keeps working exactly as it does today.

Orchestrators and executors are mutually trusted and administered by the same
operator. They connect over `inet_tls_dist` with PKIX verification, an exact
leaf SHA-256 pin and an exact node-name SAN in both directions, and no
automatic connection. A connected executor has the full privileges of an
Erlang peer, so compromising its VM compromises the orchestrators it talks to;
this is the trust decision issue #697's Rule 1 originally forbade and the
owner later accepted. Code-mode satellites, MCP servers, language servers and
every jailed payload stay outside distribution: satellites boot with
`-proto_dist none` exactly as on main, and no credential, cookie or option
file is ever mounted into a jail.

## 3. Where state lives

| Orchestrator (brains) | Executor (hands) |
|---|---|
| Session SQLite: conversation tree, registers, facts (per-strand working directory, `job/<id>` records), approvals, grants, budgets, notes | The checkout: files, `.git`, worktrees, uncommitted edits |
| Catalogue and session registrations, peer mail, memory and history index | `.blobs` (Bash overflow, code-mode reports), code-mode work directories, build seed, capability sockets |
| Provider credentials, MCP clients and their secrets | Toolchains, Go and Gleam caches, language servers and their caches |
| User configuration: `~/.loom`, user-level `~/.claude/settings.json` hooks, the hook trust record, skills | Helper pool and jail, background job processes, their staging and spill files |
| | Project hook files and guidance files, read here and sent to the orchestrator as text |
| | Machine configuration (toolchain paths, LSP profiles, mounts) and the execution ledger |

The rule behind the table: configuration that names paths on a machine lives
on that machine. The orchestrator never interprets an executor path, and the
executor never opens the conversation store.

## 4. The cut: `ToolSurface.run`

Every tool effect already leaves the runtime through one function slot,
`effects.ToolSurface.run: fn(ToolRun) -> ToolOutcome`
(`packages/runtime/src/runtime/effects.gleam:296`). The strand driver spawns
an effect process that calls it, after the call's intent and effective
arguments are already durable (`planner.dispatch_tool`, committed through
`commit_then`). `ToolRun` and `ToolOutcome` are plain data: operation id,
step, source index, strand, the call, its arguments, the persisted replay
policy and the consumed grants going out; a finished `AgentMessage` or a
failure reason coming back. No closure, port or local handle crosses.

`wiring.run_tool` (`client/wiring.gleam:1763`) is two functions in sequence.
`read_authority` reads the call's authority from SQLite (directory additions
and standing grants, no filesystem), then `run_workspace_tool` builds a
`tool.Ctx` and dispatches the tool. For a session whose workspace lives on an
executor those two halves split along the machine line. The orchestrator's `run` slot reads the authority
snapshot from its own store and sends it, with the `ToolRun`, to the session's
workspace host. The host validates the stored directory roots against its own
filesystem (the stat that `directories.revalidate` and `permissions.revalidate` do), builds the
`Ctx` with the executor's broker, pool and filesystem, and runs `tool.dispatch`.
Every tool body (`fs_read`, `fs_edit`, `bash`, `grep`, `working_directory`,
`code_mode`, the job tools) runs unchanged. One round trip per tool call,
never one per file access.

Tools that act on the conversation rather than the checkout (`agent_*`,
`history_search`, `remember`, `schedule_*`, `context`, `advise`, skills,
peers) keep running on the orchestrator. Clearance stays on the orchestrator
too. `wiring.clear` is pure over `tool.Declarations` (`wiring.gleam:1700`,
`tools/tool.gleam:573-589`), so the orchestrator builds declarations for the
workspace tools with the same registration code, fed by census facts instead
of local probes, and clears every call before it is sent.

### Callbacks from the executor

A few workspace-side operations need the orchestrator during a call. They
cross as plain request and reply messages to a per-session owner port on the
orchestrator:

1. **Approval.** A policy refusal becomes `escalate.Refused`, and the
   orchestrator returns the `Decision` exactly as `Escalations.refused` does
   today. The wait parks on the orchestrator, beside the durable escalation
   record.
2. **Owner facts.** The per-strand working directory and `job/<id>` records
   are reserved facts read and written through the existing `FactHandle`
   shape: get, compare-and-set, and a prefix listing the jobs actor uses at
   boot (`client/jobs.gleam:2781`). Only those reserved prefixes are served.
3. **Notices.** A finished background job tells its strand through
   `notice.deliver` (`client/jobs.gleam:2936`, `client/notice.gleam:162-174`),
   which writes to the conversation; the executor sends the notice text and
   the orchestrator delivers it.
4. **Output tails.** Live output hints are casts to the session's event bus.
   Losing one is legal; they never carried a guarantee.
5. **Owner-bound code-mode capabilities.** A satellite's `strand.*`, `notes.*`,
   `peers.*`, `schedule.*` and `mcp.*` requests go to the orchestrator. Its
   `fs.*`, `kv.*`, `report.*`, `proc.*`, `jobs.*` and `lsp.*` requests are
   served on the executor, beside the satellite.

Inside the executor the workspace plane receives these as an `OwnerServices`
record of functions. Locally they call straight through; for a remote session
they send to the owner port. The workspace code does not know which.

The workspace host monitors the owner port. If the port dies while a callback
is outstanding (an approval parked for its 600 s window, a fact swap), the
host settles that callback with an in-band failure, so the call reaches
`terminal` and the next orchestrator incarnation's recovery stages it instead
of waiting on a reply nobody will send.

### Non-tool callers

Hooks, goal checks, Git observation and the worktree diff run commands
through a `broker.Broker`, which is a `Subject(Msg)` plus a clock. For a
remote session the orchestrator holds a broker handle built from the
executor's broker subject, so `clear_call`, `cancel` and `abort` work as
today and output streams back to the caller's subject. Two details keep it
honest. A `CallSpec` built on the orchestrator carries an absolute deadline
on the orchestrator's clock (`broker/budget.gleam:32-40`), so the remote
handle sends the remaining duration and the executor rebases it on its own
clock. And these callers put the workspace path into the spec
(`client/hookrunner.gleam:298`, `CLAUDE_PROJECT_DIR` at :319); for a remote
session that path comes from the census as an opaque string the orchestrator
carries and never interprets. Beyond that, `broker` needs one public
constructor.

## 5. One workspace plane, two placements

Most of the work is splitting `serve.assemble_in` into the conversation half
and the workspace half. The workspace half builds the broker, helper pool,
executor service, the workspace tool registry and `wiring` configuration,
jobs, the LSP manager and the code-mode host, from a `WorkspaceSpec` (root,
machine configuration, base policy inputs, owner services). It returns a
`WorkspacePlane`: a `run` function over `ToolRun` and an authority snapshot,
the broker, the startup census, and `close`.

A local session calls the workspace half in-process and uses the returned
`WorkspacePlane` directly. A remote session asks the executor to build the
same plane inside a supervised workspace host; the orchestrator keeps the
workspace tools' declarations for clearance and a remote `run` that sends
messages. Both placements run the same assembly code, so local and remote
cannot drift apart. That property is the point of the cut, and it is what
PR #819's parallel reimplementation lost.

### Startup census

When a workspace host starts it returns what the orchestrator needs to build
the prompt and the tool table: platform and enforcement level, the toolchain
probe, available language servers, helper degradation, the shell, the Git
program (`host_git.program`, `serve.gleam:4090`, probes the host it runs on),
the workspace root as an opaque string, the guidance files' text, the project
hook files' bytes and the base policy summary. The orchestrator renders and
pins the prompt from it, exactly as it pins guidance today, and checks the
project hook files against its own trust record before any hook can run.

### Not in phase 1

Two features read orchestrator-side state that has no executor counterpart
yet, and a remote session refuses them with a clear error rather than half
working. Extension tools are installed under the orchestrator's HOME
(`serve.gleam:2798`) but run as jailed satellites, which on a remote session
would have to run beside the checkout; executor-side installs as machine
configuration can follow. Operator-added directories
(`directories.admin_with_facts`, `client/directories.gleam:225-255`) are
validated against the orchestrator's filesystem when added; a remote
validation message can follow if anyone needs it.

Two code-mode features are also left local-only for now. Background code mode
(`async_codemode`, `async_runs`) holds the whole runtime handle, and a remote
session registers `code_mode` without it. MCP façades need the orchestrator's
MCP clients and secrets inside the executor's hermetic build; a remote
session's `code_mode` omits them until the MCP layer is split into the data an
executor needs and the clients that stay on the orchestrator.

The remaining placement questions follow the rule in section 3. The `[tools]
env` table is resolved on the executor from its own configuration and secret
store, so no credential crosses the wire. Installed LSP profiles are
discovered on the executor. Guidance splits in two: the user's global guidance
is read on the orchestrator, the workspace's guidance files arrive as census
text. Which tools run where is a name table with a test asserting every
registered tool is placed exactly once, and a remote session refuses an
unplaced tool rather than running it on the orchestrator.

### What stops reading the local disk

For a remote session the orchestrator must not touch the workspace path. The
known places that do today, and where each goes:

| Today | Remote session |
|---|---|
| `server.create_session` canonicalizes the workspace path | Validated by the executor at attach |
| `ui_project.locate` reads `.git` every 30 s for web lists | Taken from the census, refreshed on attach |
| `session_base` reads `.git`, `gitdir`, `commondir` and manifests to widen roots | Built on the executor |
| `codemode_wiring.discover`, toolchain and seed probes | Census |
| `prepare_directories` creates `.blobs`, work and tmp directories, writes `.gitignore` | Executor |
| `system_prompt` reads guidance on first render | Census text |
| `hookserve.locations` reads project hook files | Census bytes; trust check stays on the orchestrator |
| `directories.read` re-validates stored roots on every call | Orchestrator reads the stored roots, executor validates them |
| Jail policy masks owner SQLite and state paths | Rebuilt per machine; the executor masks its own ledger and state |

A remote failure never falls back to a local path. A remote session's
orchestrator has no workspace path to fall back to.

## 6. Durability and failure

### What already exists

The runtime commits a tool call's intent, effective arguments and reserved
result entry before the effect starts, and stages the result durably when it
arrives. `ReplayPolicy` already separates calls that may re-run after a crash
(`fs_read`, `grep`) from calls that must not (`bash`, `code_mode`,
`working_directory`). An orphaned call whose policy is `Never` is staged as
"the external outcome is unknown" (`planner.recover_tool`). The broker
already reports `ExecutionLost` as "may have run, outcome unknown" and never
invites replay. Distribution adds lost replies, partitions and restarts on
either side, and nothing in that list needs a second custody system.

### The execution ledger

The executor keeps one SQLite ledger, opened by a node-level actor that lives
as long as the executor VM. Its rows are keyed by session, so one file serves
every scope on the machine:

```text
scope(session, workspace, incarnation, state, close_outcome, attach_token)
call(session, op, step, source_index, incarnation, tool, state, outcome, ...)
  state: admitted | terminal | unknown
```

A call row is keyed by `(session, op, step, source_index)`, the identity the
orchestrator's planner already uses. The host commits `admitted` before the
tool starts and `terminal` with the encoded `ToolOutcome` before replying.
A second request with the same key never starts a second run: it waits on the
live run or returns the stored outcome. When the executor VM restarts, every
`admitted` row becomes `unknown`; nothing is relaunched. After the orchestrator
durably stages a result it sends `ack`, which deletes the row (an `unknown`
row too, so executor restarts do not leak them). A lost `ack` would otherwise
leak a row forever (the call is no longer orphaned, so nobody queries it), so
every `Attach` reply lists the scope's unacked terminal and unknown keys and
the orchestrator acks the ones its store already holds.

System work (hooks, goal checks, Git observation, LSP observations) keeps
main's semantics: it is not durable and never replayed, and the next event
triggers it again. It runs inside the scope's current incarnation, so a
closed scope's broker is gone and late system work has nowhere to land.

### Incarnations, close and reopen

Each scope has one monotonic `incarnation`, bumped only by a reopen. Every
request carries the incarnation it was sent under, and the host refuses any
other value inside the same transaction that admits the call. A request from
a closed incarnation and a delayed first request after a close both fail
that check.

Close is a ledger transition. The host sets `closing` (this commit is the
fence), cancels live calls and jobs, stops the LSP manager, code-mode host and
broker, then closes the helper pool and waits for its retirement result
(`exec.close_pool`, `broker/exec.gleam:3290-3310`; job runners, language
servers and satellites are all helper children, so pool retirement covers
them). It removes the scope's sockets and work directories. Then it sets
`closed` with `close_outcome = all_retired` or `unknown(count)`. A monitor
DOWN, a timeout or a lost reply never counts as a witness; missing evidence
leaves the scope `closing` or `unknown`. Reopen is allowed only from
`closed, all_retired`, and it bumps the incarnation. Archive closes; restore
reopens. A scope with unknown cleanup gets no automatic successor; an operator
override is explicit and recorded.

Result recovery uses the same ledger. A query by call key works in any scope
state and for any incarnation, because the rows never move. So the property
the PR's protocol 079 called "exact-generation historical read" is a column
read here, with no separate history lane.

The executor admits at most 16 scopes that are not cleanly closed (open,
closing, or closed with unknown cleanup) and refuses the seventeenth. Clean
closes free their slot immediately, so more than sixteen sequential sessions
work. The ledger carries a byte budget; terminal rows the orchestrator has not
acked count against it, and admission refuses when the next call's maximum
result would not fit.

### Runtime restarts and the attach token

A session's runtime can restart without its VM restarting (the session tree
is rest-for-one), and the effect processes of the dead runtime are killed. A
`Run` one of them sent may still be in flight. Erlang orders messages only per
sender pair, and the dead effect process and the new runtime are different
senders, so the new runtime cannot assume its own messages arrive after the
old one's.

So every runtime incarnation attaches afresh. `Attach` carries a fresh random
token, and the host stores it as the scope's only valid token. Every `Run`
carries the token of the runtime that sent it, and admission compares it for
equality with the stored one in the same transaction that inserts the row. A
`Run` from the dead runtime, arriving after the new attach, is refused by
content, whatever order the network delivered it in. Recovery then runs in a
fixed order: attach, then query each orphaned call key.

| Ledger answer | Recovery |
|---|---|
| `terminal` | Stage the stored outcome. Nothing re-runs. |
| `admitted` | The run is still live; keep querying until it settles. |
| `unknown` | Stage "the outcome is unknown", exactly as today. |
| no row | The call never reached the executor and, after the attach, never can. A `ReplaySafe` call takes the planner's existing replay arm (`machine/planner.gleam:2020-2037`); any other call is staged as "the call did not start". |

Recovery is an effect like `run`, not a function the driver calls inline:
the driver must not block, and `KeyWait` only waits on something in its live
set (`runtime/strand_runtime.gleam:1549-1570`). The runtime spawns a recovery
effect for an orphaned call when the surface offers one, and that effect
reports through the same `ToolDone` path as a fresh run. `ToolSurface` gains
one `recover` slot and the planner one recovered observation. A local
session's surface offers no recovery, so it keeps today's orphan rule
unchanged.

### Partitions, aborts and lost replies

The orchestrator's effect process waits on the host's reply and monitors the
executor node. On a disconnect it reconnects and queries the call key, and
keeps doing so until the executor answers or the user aborts; it has no
timer of its own, because the call's deadline lives on the executor. The
session shows the executor as unavailable meanwhile.

The host monitors the effect process that sent each `Run`. Abort today is a
kill of that process (`runtime/strand_runtime.gleam:2181-2185`), so a DOWN
with any reason except `noconnection` cancels the run, exactly as a local
caller's death cancels it through the broker's caller watch. A `noconnection`
DOWN means the orchestrator is unreachable, not that anyone asked to stop, so
the run continues to completion or to its own local deadline and its outcome
waits in the ledger. That deadline is built and enforced on the executor's
clock (the broker budget and tool timeouts are constructed there for tool
calls), so clock skew between machines never decides a timeout. An abort
issued while partitioned arrives only as `noconnection`, so that call reports
"cancellation unconfirmed" rather than pretending it stopped.

| Event | Interpretation | Replay |
|---|---|---|
| Refused before send | Not started | A new call may run |
| Disconnected after send, row `terminal` on reconnect | Completed | No |
| Executor VM restarted mid-run | Unknown | No |
| Abort while connected | Cancelled through the broker | No |
| Abort while partitioned | Cancellation unconfirmed; outcome recovered later | No |
| Orchestrator or runtime restarted, row `terminal` | Completed, outcome recovered | No |

Background jobs belong to the scope, not to the call that started them, so
they keep running across an orchestrator disconnect under their existing
bounded policy, and close waits for their retirement.

## 7. Code mode, LSP and jobs

All three run entirely on the executor, which is why the cut sits above them.
A code-mode satellite is jailed beside the checkout and can only reach a Unix
socket on its own machine, so the satellite host, its listener and its token
file stay there; only the owner-bound capabilities in section 4 cross. The
LSP manager, its per-server keepers, its query door and the post-write
diagnostics observer all run beside the files they read, so no LSP byte
crosses the network and no new helper wire is needed. The jobs actor runs on
the executor and reaches its `job/<id>` records through the owner facts
callback.

Main's local behavior for code mode, LSP and the helper wire is unchanged by
this design. Changes PR #819 made there (the helper protocol v4 credit
frames, the 64 MiB LSP stdout cap, the charged launch channel) are not
carried over. Two owner decisions about code-mode semantics from that work
are independent of distribution and can land on their own: a Compile is the
original attempt plus at most one `UnusedImportRewrite` under the original
authority and deadline (071), and each Launch retires its borrowed helper.

## 8. Phases

Each phase ends with something observable. We do not start a phase's design
work before the previous one runs.

1. **One orchestrator, one executor.** Distribution bootstrap and the executor
   role; the workspace plane split; the remote `run` and `recover` slots,
   owner port and remote broker handle; registered workspace selection with
   no orchestrator filesystem access; the ledger, attach fence and incarnation
   fence; close, reopen, archive and restore. Exit: a real session on two VMs
   on one host does fs, Bash (foreground and background), working-directory
   selection, jobs, hooks, goal checks, Git and guidance, Compile and Launch,
   LSP queries, rename and diagnostics, with the checkout absent from the
   orchestrator. Then the same candidate passes laptop to Linux box and Linux
   box to laptop.
2. **Executor pools.** Several registered executors; placement filters by
   authorization, platform, toolchain and enforcement before capacity; a full
   executor refuses at attach; no fallback to a different mutable checkout.
3. **Two orchestrators.** A session directory on a designated orchestrator,
   backed by SQLite, with conditional transitions keyed by an operation id so
   a committed transition whose reply was lost can be reconciled. Clients may
   connect to any orchestrator and are redirected to the owner. `pg` carries
   only presence and fanout hints. The directory sits behind an interface
   shaped for Khepri, which replaces it later for availability.
4. **Cross-node messaging.** Peer mail already deduplicates on the recipient
   by message id (`peer_mail` admission); we add a directory-aware endpoint and
   a durable sender outbox. Event catch-up is already by commit sequence.
5. **Controlled movement.** Drain, close the scope cleanly, cut a consistent
   SQLite backup, transfer and verify, then activate the target with
   `incarnation + 1` through the directory. The target's attach replaces the
   scope's attach token, so the executor refuses anything the old
   orchestrator still sends. Faults are injected at every step.
6. **Acceptance.** The evidence table, full repository gates, both placements,
   the failure matrix, the formal models, an independent review of the
   assembled system, and hosted CI once publication is authorized.

Automatic failover and workspace snapshot migration stay deferred. The
filesystem and cache policy is inherited from the executor's configuration,
with no aggregate disk quota claimed.

## 9. What carries over from PR #819

Kept, adapted to this design: the TLS distribution bootstrap and its verify
function (`executor/remote/distribution.gleam` and its 185-line Erlang FFI),
the strict deployment TOML reader cut down to nodes, pins, credential paths
and workspace rows, the typed workspace selection in `core/workspace`, the
operator launch script and setup guide, and the two-node test fixture. The
formal models that describe properties this design still has are adapted: the
TLA+ ownership, directory, ingress and channel specs for phases 3 to 5, and the
P remote-execution model rewritten against the ledger states above. The launch
channel model and the Lean admission bridge go with the code they described.

Not carried: the four executor journals, the generation registry and scope
plan, the credited BEAM endpoint, the owner custody database and custodian,
the typed workspace RPC and its codecs, the per-effect Compile, Launch and LSP
services, the history lane, registered hook-source acquisition, and the
pending weft Detached selector API, which none of this needs.

## 10. What this design gives up

The ledger is one SQLite file per executor rather than sealed storage per
generation, so corruption of that file affects every scope's history on that
machine. We use full sync and a digest over each stored outcome. Ledger writes
serialize through one node-level actor, two short transactions per tool call,
which is fine at the scale of a few concurrent calls per scope and sixteen
scopes. System work stays non-durable, as on main; a hook interrupted by a
partition is simply run again by the next event. And trusting executors as
Erlang peers is a real security cost that the operator accepts when enrolling
a machine.
