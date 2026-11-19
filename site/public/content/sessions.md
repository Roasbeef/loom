# Sessions

A Loom session is a conversation that survives having its process killed at any instant. This page explains what a session is on disk, how it is opened and stopped, and what recovery does after a crash. It is written for someone who uses Loom, and it points to the architecture documents in the repository for the mechanics.

## One session, one file

Each session is one SQLite file. The file holds three stores:

| Store | What it holds | How it changes |
|---|---|---|
| Entries | The conversation itself: messages, compaction checkpoints, branch summaries and custom records. | Written once, never modified. |
| Registers | Current state, as cells addressed by a namespace and a key. The one called `op.state` holds the complete state of the running operation. | A write replaces the old value. |
| Usage | A ledger of cost rows. | Append only. |

Because entries are never rewritten, a conversation is a tree and not a list. Two entries may share a parent, and that is what a fork is. A fork shares history with its parent up to the branch point, so trying another approach leaves the original conversation intact. A **branch** is the path from an entry back to the root.

A **strand** is a named line of work: the main conversation, a subagent, or a parallel attempt. Strands share the tree and each keeps its own cursor into it. A new subagent is a new strand whose cursor points at a place in the history.

Because the file is the session, deleting a session means removing a file, and corruption stays inside one session.

## One daemon, many sessions

One `loomd` process hosts your sessions across workspaces. Each open session has its own supervision tree, its own conversation database and its own sandbox helpers. Several terminals and browsers can attach to the same session, and one terminal can switch between sessions without stopping the work it leaves behind.

A **catalogue**, a small database of session metadata, lets the daemon list sessions without opening them. Discovery is not execution: listing a session never starts its runtime, and a daemon restart leaves every session closed until someone opens it. Opening runs the same recovery that a crash needs, so an operation that was in flight can resume. A schedule does not open a saved session either: an overdue one fires when someone opens the session.

Three kinds of stop differ in scope:

- Closing a client detaches one connection.
- Stopping a session drains its work and keeps its database. It does not abort the operation, so a later open can resume it.
- Shutting down the daemon drains every session.

The web home page marks a running session `idle`, `working` or `needs you` (or `running`, when it has not reported what it is doing), and a session on disk without a runtime `saved`. The terminal shows a session whose creation never finished as `reserved`, and only retrying the creation completes it.

The daemon holds 8 sessions at once by default, and `--capacity` changes that. A session that is opening, stopping or blocked in cleanup still counts.

A session's workspace is normally a directory on the daemon's machine. It can instead be a checkout on another machine, which the [distributed runtime page](#/docs/distributed-runtime) covers.

## Two commits around every tool call

An agent run is a state machine whose complete state is written to a register after every step. Around a tool call it commits twice. The first commit records the intent, with the arguments, a replay policy, and the ids that the result will use. The command then runs, and nothing durable happens while it does. The second commit writes the result, the usage row and the next state in one transaction.

::figure crash

## Replay policy

A tool declares whether its calls are safe to repeat. Recovery uses that declaration:

- `ReplaySafe` runs the call again with the stored arguments, under the same reserved result id. This applies only if the tool's current registration still declares it safe.
- `ReplayNever` never runs again. The runtime writes an interrupted result under the reserved id, with a warning that the outcome is unknown.

Nothing runs twice, every tool call ends with a result, and billing survives the crash. The one divergence is that a `ReplayNever` call interrupted mid-flight yields the interrupted result and not the real one.

Messages between agents follow the same rule. A message is committed before the recipient acts on it, and a process notification only wakes the recipient. Restarting a process does not erase its unread messages.

## After a hard kill

A hard kill runs no cleanup, so the next daemon finds state that an orderly shutdown would not leave.

- **The writer lease survives.** Each session file has a lease row that names its writer and expires. After a kill the replacement is refused until the lease expires, which takes up to 60 seconds. The refusal is deliberate, because stealing on a guess could put two writers on one conversation. The daemon records `lease_held` with the expiry time, and the refusal clears itself.
- **An unfinished creation survives.** The catalogue keeps the reserved identity, and a retry of the creation under its original request key finishes it.
- **A failed open is not a stale one.** If building a session fails, the poll that follows reports `start_failed`.

## Sharing a session

The owner can invite people to a session as operators, who can direct the work and answer approvals, or as observers, who can follow without changing anything. An invitation covers one session, not every session the daemon hosts. Prompts and steering carry their author's identity, and presence shows who is attached. The [terminal and web page](#/docs/terminal-and-web) covers the commands.

Only a shareable session can be shared. A session is private by default: it shares the workspace's notes, memory and history with your other sessions in that workspace, and an invitee would see that layer. A shareable session keeps its own. Tick **Shareable** when you create a session on the web, or stop an existing session and run `loomd access isolate SESSION_ID --share-existing-transcript`. That keeps the transcript the session already has, which may include things recalled from your private notes, so anyone you invite later sees it.

To let someone watch one session without an invitation, `loom ui --session SESSION_ID` prints a read-only link. It works once, within 60 seconds, and the page it opens lasts up to 8 hours.

## Compaction and memory

A compaction is itself an entry: a self-contained checkpoint that carries the retained part of the conversation. Context assembly never reads past a compaction, and the full history stays in the file. Loom can also search earlier sessions and keep workspace memory. The repository's `docs/architecture/compaction.md` and `docs/architecture/memory.md` describe both.

## Read more

- [`docs/architecture/durability.md`](https://github.com/Roasbeef/loom/blob/main/docs/architecture/durability.md): the three stores, transactions and the lease.
- [`docs/architecture/orchestration.md`](https://github.com/Roasbeef/loom/blob/main/docs/architecture/orchestration.md): the state machine, the effect sandwich and recovery.
- [`docs/architecture/sessions.md`](https://github.com/Roasbeef/loom/blob/main/docs/architecture/sessions.md): the daemon, the catalogue and opening a session.
- [`docs/guide/multiplayer.md`](https://github.com/Roasbeef/loom/blob/main/docs/guide/multiplayer.md): sharing a session, step by step.
