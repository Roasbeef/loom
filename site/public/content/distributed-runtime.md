# Distributed runtime

A distributed Loom runs one session on two machines. The orchestrator keeps the conversation: the runtime, the session's SQLite store, approvals and provider keys. The executor keeps the checkout and runs the session's workspace tool calls beside it. A single machine that plays both roles is the ordinary local daemon.

This page describes the distributed runtime as it is on the `main` branch. It follows [the architecture page](https://github.com/Roasbeef/loom/blob/main/docs/architecture/distributed.md) and [the setup guide](https://github.com/Roasbeef/loom/blob/main/docs/distributed-setup.md).

## The two roles

| | Orchestrator | Executor |
|---|---|---|
| Runs | The agent loop, approvals, budgets | Workspace tool calls (shell commands, file tools, search), language servers, code mode, background jobs |
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
- Nothing connects automatically. A send to a node that nobody connected to is dropped, and the connections that exist are the ones the orchestrator made. Members of a session directory are the exception: each keeps a connection to every other member.
- Nodes start hidden, and an allow list names the configured peers. A deployment provisioned with `--static` lists between one and 32 of them. With the default membership ledger the pins come from the ledger, and that cap does not apply.
- All nodes of a deployment share one cookie, which is a second check behind TLS and not the boundary.

Orchestrators dial and executors never do, so an executor needs two inbound ports: `epmd` and its fixed `listen_port`. Code-mode satellites, MCP servers and language servers boot with distribution disabled, and no credential, cookie or options file is mounted into a jail.

All of that is the trusted mode, which is the default. An executor whose `[executors.<name>]` row says `trust = "untrusted"` is never a distribution peer. The orchestrator dials it over TLS 1.3 with a pinned certificate on each side, carries the same messages as JSON frames, and decodes and checks everything the executor sends back. Project hooks, goal checks, Git observation and the worktree diff are refused on an untrusted executor.

## Setting it up

`loom distribution` takes you from nothing to a trusted deployment without `openssl`:

```sh
loom distribution init plan.toml        # write an example plan
loom distribution provision plan.toml out --passphrase-file <file>   # mint certificates and one cookie
loom distribution show out              # print the deployment, with no secrets
loom distribution install box.loombundle    # on each machine, install its bundle
```

`install` prints the command that starts the daemon with `LOOM_DISTRIBUTION_OPTFILE` set, and a plain `loomd` does not start distribution. A daemon that `loom` starts gets the variable and the options file without any step from you. The orchestrator also needs `[models]` and `[roles]` as for any session. A plan lists each node, its role and its Erlang node name (`name@host`, with a dot in the host). An executor also lists its workspaces, each a short name and an absolute path on that machine. `provision` writes one bundle per node. A bundle holds the node's private key and the shared cookie, so copy each to its machine over a channel you trust. `install` puts the certificates in place and merges the role tables into `loom.toml`.

By default `provision` signs a membership ledger and keeps the authority's key, sealed under the passphrase in `--passphrase-file`. With the key kept, `loom distribution enroll`, `renew` and `revoke` add a node, replace a certificate and remove a node on a running deployment without provisioning again. A member that is off learns the change when it next connects to a node that has it. `provision --static` is the older mode: each bundle lists its peers' pins, the key is discarded, and any change means provisioning again and reinstalling every bundle.

A workspace is shared by default: every session on it works in the same checkout. Add `mode = "worktree"` to a `[workspaces.<name>]` table and each session gets its own linked Git worktree and its own branch, `loom/<session id>`. This protects against accidents and not against a hostile model, because the repository's `.git` stays writable from each tree.

Then create a remote session from the orchestrator:

```sh
loom --executor box --workspace proj
```

A remote session shows its workspace as `box:proj`. With more than one executor, a pool lets the orchestrator choose: `loom --pool linux --workspace proj`. The pool tries first the executor on which this orchestrator has the fewest sessions, with the listed order breaking ties, and moves to the next only when the connection to the first fails or the first reports that it is full. A session stays on the executor that it first landed on.

`loom deployment status` on the orchestrator connects to every configured executor and orchestrator and prints each as `ok`, `degraded` or `down` with a reason, before any session exists. A first connection can read `down` because the TLS handshake outlasts the one second the daemon waits, so run it again.

## Pools, and two orchestrators

A pool is a list of executors. An executor can declare its platform, its enforcement level and its toolchains, and a pool can require them. The declarations are the operator's claims. The balance is this orchestrator's own count of sessions on each executor, not load, and it says nothing of what other orchestrators hold on the same machines.

A deployment can also run two orchestrators, each with its own catalogue. A session belongs to the orchestrator that created it. To find a session that another orchestrator owns, the daemon asks each configured peer at once, under a two-second deadline, and answers `not_owner` with the owner's name when a peer holds it. Nothing follows the redirect for you: the terminal prints the launch line for the owning orchestrator. Peer mail between sessions on different orchestrators goes through a durable outbox on the sender, which retries for up to an hour: every five seconds while the owner does not answer, and with a wait that doubles from five seconds to five minutes while the recipient is saved and not open.

A deployment can instead keep one authoritative record of each remote session's owner in a session directory, a Khepri cluster of three, five or seven members drawn from the orchestrators and executors. It commits a write only while a majority of members is up. With it, a lookup does not wait on a peer that is down, and a move can be abandoned when the receiver goes silent.

A model on one orchestrator can also start child agents on another. The receiving orchestrator lists each orchestrator that may spawn on it in a `[spawners.<name>]` table, with a placement, a tool ceiling and caps on depth, sessions and run time. A spawn can carry the parent's workspace, and the commits the child makes come back as one ref in the parent's repository. Uncommitted edits the child leaves do not come back, and a session whose own workspace is on an executor can't send its workspace this way.

The setup guide marks what has been run by hand. Provisioning and sessions on one executor have been run on real hosts. `loom sessions move` has been run by hand for a session that works in a directory, with three daemons on one machine. The shipped tests cover pools and moves over the control protocol, but the `--pool` flag has not been run by hand against real daemons, and `enroll`, `renew` and `revoke` have not been run on two machines.

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

The conversation file moves. The checkout and the executor stay where they are. `loom sessions move <id>` with no `--to` prints which orchestrators can take the session and why the others cannot.

A session that works in a directory on the source moves only when the source's `[orchestrators.<name>]` row for the destination names a `checkout_executor` and a `checkout_workspace`, a workspace that executor serves in `worktree` mode. The source captures the directory, uncommitted edits and untracked files included, sends it to that executor and has it checked out for the session, and the move then goes on as for any session on an executor. The directory on the source is left as it was. Without those two keys the move is refused with `not_movable`. A session moved off a laptop directory this way can't be moved back to it yet.

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
| The orchestrator crashes during a call | The call keeps running on the executor. On reopen the orchestrator attaches at the same incarnation with a new token, and after the dead daemon's writer lease lapses (up to 60 seconds) the model receives the stored outcome. The tool ran once. |
| The network drops during a call | The orchestrator reconnects and re-sends the same `Run`. The call completes once. |
| The executor restarts | Every in-flight call becomes unknown, and the model is told the call may have run. A session that stays open attaches again under the same token on its next call and carries on, with no step from the operator. A session that is closed before it makes another call records an unproven cleanup, and its reopen needs the operator to release the old scope with `loomd executor release SESSION` on the stopped executor. |
| The source crashes during a move | The `moving` row survives. The restarted daemon resumes the mover, which asks the receiver how far the move got. The shipped test halts the source after each of the six steps. |
| The receiver is unreachable during a move | The mover stalls and retries every five seconds. It never abandons on silence. |
| An executor is full | The attach is refused before anything is built. A first open in a pool moves on to the next executor. |

No state in this design is replicated or decided by a vote. Each fact has exactly one writer: a session's conversation is in its owner's store, a call's state is in its executor's ledger, and ownership is in the two catalogue rows. Losing a node makes that node's facts unavailable until it returns, and it never changes who owns anything. Automatic failover would need a replicated store and is deferred.

## Limits

- There is no failover, and no moving a session between executors. A session keeps the executor that its first open chose.
- A remote session refuses extension tools and operator-added directories. Foreground and background code mode work, and so do MCP façades in code mode.
- Background code mode on a remote session answers the model's `check`, `send` and `cancel` through the executor, so they wait for a dropped connection like any other tool call. A program still running when the orchestrator restarts is reported lost, and only one that had already finished keeps its result.
- An MCP server for a remote session runs on the orchestrator unless its `[mcp.<name>]` table says `runs_on = "executor"`. It is never restarted or jailed on either machine, and an edit to its table takes effect when the session is next stopped and opened.
- A move does not carry running processes, the memory domain, memberships or claims. The terminal, the web home and the Admin drawer draw a moving session with its destination and leave a moved one out. The receiver lists it.
- An imported session whose origin orchestrator is gone can never move on, and there is no override yet.
- After an executor restarts, a session that was closed before its next call needs the operator's release before it reopens. A job that was running on the executor is gone.
- Upgrade the nodes of a deployment together. A different protocol version is refused at attach, so stop the remote sessions, upgrade the executors and the orchestrators, and open the sessions again.
- Membership changes are eventual. A deployment that must change its authority or its cookie is provisioned again, and so is every change to a `--static` deployment.

## Read more

In the repository, on `main`:

- [`docs/architecture/distributed.md`](https://github.com/Roasbeef/loom/blob/main/docs/architecture/distributed.md): the design and its failure table.
- [`docs/distributed-setup.md`](https://github.com/Roasbeef/loom/blob/main/docs/distributed-setup.md): setup in the order you would do it, with a note on how much each step has been run.
- [`protocol-change/078-distributed-runtime.md`](https://github.com/Roasbeef/loom/blob/main/protocol-change/078-distributed-runtime.md): the wire and durable formats.
