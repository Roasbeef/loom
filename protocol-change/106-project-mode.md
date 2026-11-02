# protocol-change/106: projects, tickets and the trigger origin

**Status**: PROPOSED 2026-11-01. The owner accepted the design's five decisions
([docs/design-notes/project-mode.md](../docs/design-notes/project-mode.md)); this
proposal's formats aren't yet accepted, and nothing is built.
**Affects**: the core `Origin` type (Part 1.1) by one variant; the client control
protocol (Part 1.6) by new `projects.*` commands; `loom.toml` by
`[project]`; the catalogue by `catalogue_projects`; a new per-project ledger file.
**Raised by**: the owner's request for a default project mode.
**Builds on**: [048](048-async-collaboration.md) (peer origin and receipts),
[059](059-strand-message-origin.md) as the strand origin's precedent,
[094](094-cross-orchestrator-sessions.md) (top-level sessions with no parent),
[095](095-worktree-workspaces.md) (a worktree per session).

## Problem

A project needs three things no interface offers today. External text has to reach a
worker with an attribution no model can forge. Clients need a board without
reimplementing ticket state. And a session's standing, router or worker, has to
change how the registry treats it.

## What was considered

### Delivering external text as harness text (rejected)

Completion notices and schedules arrive as harness text in a user-role entry, which
needs no format change. It was rejected because the text in this case is hostile by
assumption, and it would read in the harness's voice in the transcript and in provider
rendering.

### Reading external text only through a tool result (rejected)

A worker could get IDs and read everything through `project_read`, and a tool result
is already understood to be untrusted. It avoids the Part 1 change. It was rejected
because a follow-up has to steer a running worker at its next checkpoint, and a steer
is a message. An ID alone costs the worker a read for every comment.

### A new session kind in the catalogue (rejected)

A `kind` column would name what's special about a router. It was rejected because a
typed projection over the project row gives the same exhaustive matching with no
change to session records, and delegates show a row can be the marker. The note's
"typed standing" section has the argument.

### A change doorbell now (deferred)

A contentless `projects.changed` event would spare clients a poll, and it would be the
first event on the control socket after `hello`. We start pull-only with a revision and
add the event if polling shows a cost.

## Decision

### The trigger origin

`core/message.Origin` gains one variant:

```gleam
TriggerOrigin(source: String, trigger: String, actor: String)
```

It encodes with its own tag, and a malformed one fails decoding as corruption, as
`PeerOrigin` does. Only the project engine's actor writes it, from the stored trigger
and never from tool arguments. Provider rendering fences the body and labels it with
the source and actor. Attribution isn't authority: no code reads this origin to grant,
widen or skip a check, the same rule that holds for `StrandOrigin`.

An owner's turn typed into a worker keeps its human `Origin`, and the ledger records it
by entry ID.

### Control commands

All are owner-only in the first version. Reads are classified by `read_only`.

| Command | Read | Meaning |
|---|---|---|
| `projects.create` | no | Create a project for a workspace, with its router session |
| `projects.list` | yes | The owner's projects, with their counts by stage |
| `projects.board` | yes | A page of tickets, needs-a-person first, with `revision` |
| `projects.ticket` | yes | One ticket with its Mandate, assignments, inputs and session ID |
| `projects.post` | no | Add an explicit trigger from the composer, keyed by a request ID |
| `projects.answer` | no | Answer a question, echoing its `seq` |
| `projects.stop` | no | A person's stop, which withdraws the Mandate |
| `projects.retry` | no | A new assignment for a stalled ticket |
| `projects.publish` | no | Publish past a failing check; recorded with the principal |
| `projects.requeue` | no | Queue a stored trigger for a fresh Eval |
| `projects.set_mode` | no | `off`, `observe` or `auto` for one source and rule; `auto` is refused without a current verdict |

### A ticket on the wire

```json
{
  "id": "t_01",
  "project": "p_01",
  "title": "Fix the flaky snapshot test",
  "stage": "person/review",
  "session": "s_01",
  "mandate": {
    "strength": "explicit",
    "via": "addressed",
    "source": "github",
    "actor": "roasbeef",
    "policy_version": "v7"
  },
  "check": {"commit": "abc123", "outcome": "passed"},
  "question": null,
  "pull_request": "https://github.com/owner/repo/pull/1",
  "ended": null
}
```

`stage` is one of `person/delivery`, `person/answer`, `person/review`, `person/blocked`,
`person/failed`, `queued`, `idle`, `working`, or `ended/<outcome>`. Clients display it and
never derive it. `question` is null or `{seq, text, options}`, and the answer echoes `seq`.
Unknown fields follow the forward-compatibility rule of `docs/client-protocol.md` section 1.5.
Each record is added to that document and checked against live frames before the slice lands.

### Configuration

```toml
[project]
check = "make check"
protected_paths = ["Makefile", ".github/**"]
max_workers = 4
token_ceiling = 5000000

[[project.source]]
kind = "github"
allow = ["roasbeef"]
bots = []
```

Every key is optional, and a project with no table has the composer as its only source and
inferred work `off`. `[roles].router` is added beside `advisor`, falling back to `subagent`
then `main`.

### Durable state

`catalogue_projects` holds the project's ID, workspace, router session, ledger path and state,
and the catalogue version moves by one. The ledger is one SQLite file per project with one writer:
triggers, threads, decisions, tickets, assignments, effect rows and the outbox's receipts. It is
never replicated. A worker's request key derives from `(ticket, assignment_seq)`. Durable decoders are total. The `project` package holds no I/O and is added to
the R6 list.

## What it costs

A Part 1 origin variant means a client that predates it fails a whole session that holds one, so
older clients must be stopped first, as with 059. That's the reason to land the reader before any
writer. Every new standing is one more arm at each registry site, on purpose. A second SQLite file
per project adds a store to back up and retain, and a state that crosses it and a session's store
can't commit atomically, so effects carry derived keys and the human-turn ledger is rebuilt from the
log. Reopening at boot narrows "discovery is not execution" for owner-written rows, and each router
adds a resident session's memory for as long as its project lives.
