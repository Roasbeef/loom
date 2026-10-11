# Distributed runtime

A distributed Loom runs one session on two machines. The orchestrator keeps the conversation: the runtime, the session's SQLite store, approvals and provider keys. The executor keeps the checkout and runs the session's workspace tool calls beside it. A single machine that plays both roles is the ordinary local daemon.

> **In development.** The distributed runtime is not on `main` yet. It is documented on open pull requests: issue #697, PR #923 (tools on another machine), PR #937 (peer mail across orchestrators) and PR #938 (background code mode and MCP on a remote session). This page follows `docs/architecture/distributed.md` and `docs/distributed-setup.md` on those branches, and details may change before they merge.

## The two roles

| | Orchestrator | Executor |
|---|---|---|
| Runs | The agent loop, approvals, budgets | Tool calls, shell commands, language servers, code mode, background jobs |
| Holds | The conversation database, the session catalogue, approvals and grants, provider API keys, `~/.loom` and user-level hooks | The checkout, toolchains and caches, the sandbox, a ledger of tool calls in flight |
| Talks to | Clients, the model provider and the executor | The orchestrator only |
| Configured by | `[distribution]` and `[executors.<name>]` | `[distribution]` and `[workspaces.<name>]` |

Both roles are the same release, and a node's configuration decides which role it plays. The rule behind the table is that settings that name a path on a machine live on that machine. The orchestrator never interprets an executor path, and the executor never opens the conversation database.

## Where the machine boundary sits

Every tool effect already leaves the runtime through one function slot, `run` on `effects.ToolSurface`. It is called after the call's intent and arguments are committed. Both sides of that slot are plain data: no closure, port or local handle crosses it. The distributed runtime puts the machine boundary there, so a remote session sends whole tool calls to the executor and receives outcomes, one round trip per call and never one per file access.

The rest follows. The runtime already makes a call durable before the effect starts, so a remote call needs no second custody system. The executor runs the same workspace half of the session assembly that a local session runs in-process, so local and remote cannot drift apart. Code mode, the language-server manager, the jobs actor and the broker run beside the files they read.

Clearance and approvals stay on the orchestrator, which builds declarations for the workspace tools from a census the executor reports and clears every call before it is sent. When a tool on the executor needs the orchestrator, for an approval, a note or a child agent, it sends a message to a per-session owner port, and a failure becomes an in-band refusal.

## Trust and transport

Orchestrators and executors are mutually trusted and administered by one operator. A connected Erlang node can run code on the other, so compromising an executor's VM compromises the orchestrators it talks to. The design draws its boundary around who may connect.

- Nodes connect over TLS with pinned certificates. The leaf must match a configured SHA-256 pin and carry a single node-name SAN equal to that pin's node name.
- Nothing connects automatically. A send to a node that nobody connected to is dropped, and the connections that exist are the ones the orchestrator made.
- Nodes start hidden, and an allow list names between one and 32 configured peers.
- All nodes of a deployment share one cookie, which is a second check behind TLS and not the boundary.

Orchestrators dial and executors never do, so an executor needs two inbound ports: `epmd` and its fixed `listen_port`. Code-mode satellites, MCP servers and language servers boot with distribution disabled, and no credential, cookie or options file is mounted into a jail.

## Setting it up

`loom distribution` takes you from nothing to a trusted deployment without `openssl`:

```sh
loom distribution init plan.toml        # write an example plan
loom distribution provision plan.toml out   # mint certificates and one cookie
loom distribution show out              # print the deployment, with no secrets
loom distribution install box.loombundle    # on each machine, install its bundle
```

A plan lists each node, its role and its Erlang node name (`name@host`, with a dot in the host). An executor also lists its workspaces, each a short name and an absolute path on that machine. `provision` writes one bundle per node. A bundle holds the node's private key and the shared cookie, so copy each to its machine over a channel you trust. `install` puts the certificates in place and merges the role tables into `loom.toml`.

Then create a remote session from the orchestrator:

```sh
loom --executor box --workspace proj
```

A remote session shows its workspace as `box:proj`. With more than one executor, a pool lets the orchestrator choose: `loom --pool linux --workspace proj`. The pool tries executors in order and moves to the next only when the first could not hold the session. A session stays on the executor that it first landed on.

## One tool call, end to end

A remote call takes four steps. The session open attaches once. Each call is sent as a `Run` and admitted by key into the executor's ledger. The outcome is committed before any reply. The orchestrator later acknowledges it.

- **Attach, once per open.** The attach carries a fresh 32-byte token and an incarnation. The ledger makes that token the scope's only valid one, which fences any earlier open: a late `Run` from a dead orchestrator is refused by value, whatever order the network delivered it in.
- **Run, keyed by the planner's identity.** A call's key is the session, operation, step and source index. A second `Run` for the same key never starts a second run. It joins the live run, receives the stored outcome, or is told the outcome is lost.
- **Reconnect.** If the connection drops, the orchestrator reconnects with a pause that doubles from 50 ms to 2 s and re-sends the same `Run`. Admission treats it idempotently by key.
- **Acknowledge.** When the orchestrator has durably staged the outcome, it acknowledges, and the executor deletes the row and writes a tombstone so that key can never start again in that incarnation.

Time works the same way. The orchestrator and the executor do not share a clock, so tool deadlines are built and enforced on the executor.

## Moving a session between orchestrators

An owner can hand a session that lives on an executor to another orchestrator:

```sh
loom sessions move <id> --to <orchestrator>
```

The conversation file moves. The checkout and the executor stay where they are. A local session cannot move, because its checkout is a directory on the source.

Ownership is two catalogue rows ordered by a write-ahead intent. The source's row goes `resident`, then `moving(op, to)`, then `moved(to)`. The receiver's goes from absent to `imported(op, from)`. Each transition is a compare-and-set in one immediate transaction, keyed by the move's `op`.

::figure migration

### The rules

Three rules carry the protocol's safety. A TLA+ model checks the first two, each with a mutation, and the third concerns a second move that the model leaves out.

- **Only an answer abandons a move.** The source returns to `resident` only on an unproven cleanup, a refused close, a corrupt or oversized file, or the receiver's refusal. Silence, an unanswered close and an expired deadline are stalls, because an unreachable receiver may have activated the session and lost the reply.
- **A committed activation is always accepted.** Once the receiver has committed `imported`, every `Activate` for that operation is answered `Accepted`, whatever else is now true.
- **An imported session holds move-on and delete until its origin has retired.** `sessions.move` refuses with `not_movable`, and `sessions.delete` refuses with `busy`, until the origin answers `Moved`.

## What a failure looks like

Some of the cases that the architecture page lists, in the words of what you see:

| Failure | What the system does |
|---|---|
| The orchestrator crashes during a call | The call keeps running on the executor. On reopen the orchestrator attaches at the same incarnation with a new token, and the model receives the stored outcome. The tool ran once. |
| The network drops during a call | The orchestrator reconnects and re-sends the same `Run`. The call completes once. |
| The executor restarts | Every in-flight call becomes unknown, and the model is told the call may have run. A session that stays open fails new calls until it is closed and reopened, and the reopen needs `loomd executor release`. |
| The source crashes during a move | The `moving` row survives. The restarted daemon resumes the mover, which asks the receiver how far the move got. The shipped test halts the source after each of the six steps. |
| The receiver is unreachable during a move | The mover stalls and retries every five seconds. It never abandons on silence. |
| An executor is full | The attach is refused before anything is built. A first open in a pool moves on to the next executor. |

No state in this design is replicated or decided by a vote. Each fact has exactly one writer: a session's conversation is in its owner's store, a call's state is in its executor's ledger, and ownership is in the two catalogue rows. Losing a node makes that node's facts unavailable until it returns, and it never changes who owns anything. Automatic failover would need a replicated store and is deferred.

## Limits

- There is no failover, and no moving a session between executors. A session keeps the executor that its first open chose.
- A remote session refuses extension tools and operator-added directories.
- A running background code-mode execution does not survive an orchestrator restart. Only one that had already finished keeps its result.
- A move does not carry running processes, the memory domain, memberships or claims, and it does not appear in the web view.
- Certificate provisioning is one-shot. Rotating a certificate or adding a node means provisioning again and reinstalling every bundle.

## Read more

On the distributed-runtime branches of the repository:

- `docs/architecture/distributed.md`: the design and its failure table.
- `docs/distributed-setup.md`: setup in the order you would do it, with a note on how much each step has been run.
- `protocol-change/078-distributed-runtime.md`: the wire and durable formats.
