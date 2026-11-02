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

## Addendum: the owner's board on the web view (2026-11-01)

**Affects**: the home page's server component (`web_view/home`) and its socket
(`client/daemon/ui_socket`) by one capability, one admitted click region and two page
reads; `docs/client-protocol.md` section 3.32 by four commands. No new HTTP route, no
new WebSocket route, no content security policy change, no new event class and no new
daemon command beyond the four named below.

**The commands.** `projects.ticket` (a read), `projects.answer`, `projects.retry` and
`projects.requeue` finish the set the first version listed. `projects.answer` echoes the
question's `seq`, and an answer whose `seq` is not the ticket's open question is refused
`conflict` and records nothing. The board record gains `opened_ms`, the arrival time of the
ticket's opening message, or null; a client shows an age only from it.

**The page.** The owner's home draws a Projects section above its centre, and a ticket
opens as a pane of the centre. Both are part of the home's existing socket, so they add
no route. Their authority is the creation capability's own, stated here because each new
reach needs it written down:

| Reach | Who | How it is admitted | Checked again by |
| --- | --- | --- | --- |
| The section is drawn and the board is read | The daemon's owner, on a page minted to operate | `Start.projects` is `Some` only through `ui_socket.home_projects_capability` | `projects_for`, which repeats the owner check before it asks a project's actor |
| A click on a ticket's button | The same page | A `click` beneath `home.projects_path` (`0\t2\t0`) is admitted by the `Submitting` and `Administering` rights and not by `Browsing` (`home_event`) | The component honours the press only for a project and ticket in the boards it holds |
| A ticket is read | The same page | The press above | `ticket_read_for`, the owner check again |
| An answer is sent | The same page | A `submit` beneath `home.table_path`, which the owner's socket already admits for its other forms | `answer_for`: the owner check, then the project's actor, which compares the echoed `seq` with the open question |

An observer-ceiling page, a member's page and a page on a daemon with no project table get
no capability, draw no section and ignore the messages. A forged frame at the region is
dropped by the socket before it costs a render, and a forged message that survives it is
ignored by the component. The browser supplies one value, the answer's text, from a form
with exactly one field. Every ticket string is external text, passed through
`text_hygiene` once by `session_view/project_board` and drawn as a text node: no class,
attribute, key or address is built from one. The feed hands the page the daemon's JSON
untouched (`client/daemon/ui_projects`), so the page and the control command read one
body.

**Not built.** The change doorbell, `set_mode` and `publish` controls and the verdict view
stay out of the page; the ticket page has no control for them. (The host check, the pull
requests and the answer's relay were built later; see the addendum below.)

## Addendum: done means verified (2026-11-01)

**Affects**: `docs/client-protocol.md` section 3.32 by one command, three ticket fields and
one board field; `[project]` by three keys; the project ledger by two engine events and the
host records they need. No change to the jail, to any worker tool, or to the session wire.

**The commands and records.** `projects.publish` (owner only, recorded with the principal)
publishes a ticket's current commit past a failing or missing check, and is refused while
`publish` is off. A ticket gains `check` (`{commit, outcome}` once the host's check has judged
the head) and `review` (the host's sentence for why a ticket waits for a person). The board
gains `unrouted` on page zero: messages the router was offered three times and decided nothing
about, each with the text a person needs and a `projects.requeue` to offer it again. Nothing is
dropped on the way: an explicit message that ends there is that record.

**The configuration.** `check`, `protected_paths` and `publish` join `[project]` (see
`docs/configuration.md`). All three default to doing nothing outward.

**The events.** `HeadObserved` carries the host's reading of an idle worker's branch, with its
verdict on the protected paths, and `ReviewRequested` carries the host's reason for asking a
person. Both are written by the host and neither can be built from a model's output. The
engine asks for the first with the `ObserveHead` effect when a worker reports idle with no
open question; protected paths are decided before the check, so a head that touches one has
no check requested. `OpenPullRequest` is renamed `PublishBranch`, and a later commit asks for
it again so the branch and the pull request show the new head. `RelayAnswer` is gone: an
answer is delivered as a trigger by the same path as any input.

**What reaches the outside.** The host pushes `<commit>:refs/heads/project/<ticket>` to the
`origin` remote with the daemon's own credentials, without force and without the repository's
hooks, and speaks to GitHub only through `gh api` on the REST interface. A ticket's title is
the one model text in a pull request, and it is capped, stripped of anything that could
mention, link or reorder text, and prefixed with the ticket's id. The body is built from ledger
facts: the ticket, the commit, the check command's digest and the ledger entry of the run. The
host looks for an open pull request from the branch before it creates one.

**What it costs.** The repository's `.git/config` is a file a worker's sandbox may be able to
write, because a worktree shares its repository's configuration. The remote's URL, a credential
helper or an SSH command set there would be trusted by the host's push. Hooks are turned off for
the push; pinning the remote when the project is created would close the rest and is left for
the slice that gives workers other machines. A check runs with the network off, and a toolchain
that needs the network to build fails its check until that is given a reason to be otherwise.
