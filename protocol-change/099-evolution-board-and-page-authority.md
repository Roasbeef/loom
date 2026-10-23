# protocol-change/099: the evolution board, its change push, and the owner page's authority

**Status**: PROPOSED 2026-10-23. The five rulings listed under Decision were made
by the owner's delegate when the operator UI for governed evolution was
planned; the owner has not ruled on them, and the first (owner authority on the
owner's page) is the one the owner should confirm. Nothing here changes the
protocol version. · **Affects**: the session wire (one `evolution` action and
one push event), the evolution operator door's authority argument, the
evolution catalogue's audit text, the event bus (one data-free event) ·
**Raised by**: the evolution operator UI plan (five PRs; this is the first, the
client side) · **Implemented**: `client/evolution/board`, `client/evolution/store`,
`client/evolution/queue`, `client/evolution/control`, `client/gateway`,
`client/protocol`, `client/serve`, `events/bus`

## Problem

The wire already carries the operator surface. `protocol.Evolution(action,
arguments)` is a session command, every action answers with one
`SnapshotEvent(EvolutionSnapshot(board))`, and the gateway hands the
connection's authenticated authority and principal to the host's evolution
door. A browser page and the terminal can therefore send it. Three things stop
either from drawing a useful panel.

*The reads are too thin.* `catalogue` returns a candidate's id, name and
description, eight to a page. A panel must also know each candidate's kind,
scope, approval, evidence and selection, and the history of decisions. With the
existing actions that is a catalogue page per eight candidates plus an
`inspect` (up to 1 MiB) per candidate.

*Nothing pushes.* A mutation commits and replies to its sender. A second
attachment, or a page that sent the command and then reconnected, learns of it
only by asking again. A queued selection completes minutes later, and its
completion reaches nobody.

*A page cannot do what the owner can.* A page never attaches as `Owner`: the
relay caps it at `Operator` (051). The evolution door maps `Participant(Operator)`
to the store's session operator, and the store refuses that authority three
things: approving or selecting a workspace program or an exact-model prompt,
reading exact-model candidates at all, and every `core_*` action. The owner's own
page could approve only this session's own extensions. 073 met the same wall for
`approve scope:"session"` and `permissions`, and ruled that the gateway gates
those by the principal's kind and not by the capped role. The evolution door
has no such derivation.

## Considered

**Call the evolution door from the web component.** It would put session logic
in `web_view` and bypass the binding the gateway derives authority from. The
terminal would get nothing. Not taken. The command is already admitted to a
page, so a second door to the same seam would need its own authority
derivation kept in step with the first.

**Page the existing reads instead of adding one.** Sixteen catalogue pages and
one `inspect` per candidate for a panel that is open all session, repeated after
every change. Not taken.

**Pass owner authority to every evolution action from an owner's page,
including `core_upgrade` and `core_downgrade`.** This is the plain application
of 073, and it is not taken. A reviewed harness upgrade replaces the running
daemon's core for the session, and the page's cookie, key and nonce are worth
less than the terminal's bearer. The owner's page may read `core_status`. The
upgrade stays on the terminal and the `loom evolution` command.

**Let a member operator act on global rows.** A member's authority comes from
a session membership, and a global approval binds other sessions. Not taken. A
member keeps the store's own confinement: this session's rows only.

**Offer `admit_tasks` and `mark_outcome` from a page.** Their arguments are
large envelopes (an independent task set can be tens of kilobytes) that a form
cannot sensibly author. They stay on the command line. Nothing here stops a
later page from offering them.

**Record where a decision came from in a new register.** The audit journal
already carries every approval, revocation and selection as an entry, and a
second cell would be a second place for the same fact to disagree with the
first. Not taken. The surface goes into the audit text.

**Publish the push from the gateway.** The gateway sees a mutation's reply and
not its commit. A queued selection commits minutes after its reply, inside the
transition queue. Not taken. The publishers are the places that know a commit
is durable: the door's wrapper, and the queue.

## Decision

**Proposed.** Five rulings, all applied as written.

1. *Owner authority on the owner's page, derived from the principal's kind.*
   `control.for_principal(authority, kind, action)` is the one place the rule
   lives, and the gateway calls it in `evolution_command`. A `Participant(Operator)`
   attachment whose principal is `OwnerPrincipal` is handed to the door as
   `Owner`, for every action except `core_upgrade` and `core_downgrade`. A
   member principal, an observer of either kind and an attachment that is
   already `Owner` pass through unchanged. The page still cannot attach as
   `Owner`, the relay's cap and `read_only` are unchanged, and no other command
   sees the derived authority.

2. *Core upgrade and downgrade are not offered from a page.* The derivation
   above leaves them at the capped authority, and the core door refuses
   anything that is not `Owner` ("reviewed harness upgrades require the native
   owner"). A page may read `core_status`, which the owner's derived authority
   admits.

3. *Member operators act on session rows.* The store's confinement is the gate
   and is unchanged: a session operator may approve, revoke and select this
   session's own extensions, and is refused workspace and exact-model rows.
   A page may offer the controls to a member as a convenience. The daemon
   refuses what the page should not have offered.

4. *Large envelopes stay on the command line.* `admit_tasks` and
   `mark_outcome` are unchanged.

5. *The surface is recorded in the audit text.* See Audit text below.

*The `board` action.* `board` is a read action with no required arguments. It
joins `catalogue`, `inspect`, `evidence` and `status` in the fixed action list
and in the gateway's `read_only` classification, so an observer may read it and
is refused every other evolution action as before. It answers one object:

```json
{
  "version": 1,
  "session": "<session id>",
  "candidates": [
    {
      "candidate_id": "<sha256>", "name": "fmt_check",
      "kind": "extension|program|prompt",
      "scope": {"kind": "session", "session": "<id>"}
        /* or {"kind":"workspace","workspace":"<path>"}
           or {"kind":"model","provider":"..","model":"..","api":".."} */,
      "description": "...",
      "parent": "<sha256>" | null,
      "origin": {"session": "<id>", "strand": "main"},
      "identity_current": true,
      "approval": {"evidence_id": "<sha256>", "by": "<principal>", "via": "cli|web|terminal|"} | null,
      "evidence": [
        {"evidence_id": "<sha256>", "purpose": "author_tests|independent_rollout",
         "verdict": "passed|failed|inconclusive", "reason": "...",
         "at_ms": 0, "identity_current": true}
      ],
      "selected": {"generation": 3, "evidence_id": "<sha256>"} | null
    }
  ],
  "selections": [
    {"scope": {...}, "name": "fmt_check", "candidate_id": "<sha256>",
     "evidence_id": "<sha256>", "generation": 3, "published": true}
  ],
  "published": {"candidate_id": "<sha256>", "name": "fmt_check", "generation": 3,
                "inventory": {...}} | null,
  "pending": [
    {"request_id": "...", "state": "queued|running", "candidate_id": "<sha256>",
     "expires_at_ms": 0}
  ],
  "history": [
    {"seq": 41, "at_ms": 0, "event": "approved|revoked|selected",
     "candidate_id": "<sha256>", "name": "...", "generation": 3 | null,
     "principal": "...", "via": "cli|web|terminal|", "reason": "...",
     "request_id": "..."}
  ],
  "omitted": {"candidates": 0, "history": 0}
}
```

A reader keeps a row of a kind, scope, purpose, verdict or event it does not
recognise and draws it as written. It never refuses the board for one.

Three things differ from the sketch in the plan, each for a reason in the
code. A candidate envelope is content addressed and carries no creation time,
so there is no `created_ms`; the time an observation was made is the evidence
row's `at_ms`. `scope` is the catalogue's own encoding (`session`, `workspace`,
`model`), which the store already writes into every register, so a reader
decodes one shape. `via` is empty for an entry written before surfaces were
recorded.

*What the board holds, and what bounds it.* Visibility is the store's. The
catalogue read filters candidates by the capability's authority, so an
observer's board holds this session's candidates and the owner's holds all of
them. The audit journal is daemon-wide, so history is filtered the same way
before it is counted: an entry shows only when its scope is one the capability
may read, and `omitted.history` never counts an entry of a scope the reader
cannot see. An entry whose text does not parse has no scope and is the owner's.
Evidence rows are those the candidate has retained, newest first, with
`observation` left out because one can be 64 KiB. Candidates are the store's 128
at most; history is the newest 64 entries; `pending` is the queue's accepted and
unfinished transitions, which the queue runs one at a time. `published` is the
live generation `status` already reports.

The whole reply is bounded at 48 KiB, the same figure as a command's arguments.
When the encoded board would exceed it, the board drops the oldest history
first, then the oldest candidates, and `omitted` counts both. A selection leaves
the board with its candidate. The board is a snapshot of a bounded window and not
a ledger, as the proposals board is.

*The `evolution_changed` push.* A data-free event, `{"event":"evolution_changed",
"body":{}}`, sent to every subscribed attachment as `proposals_changed` is. A
subscriber reads the board again. An older client ignores an event it does not
know and never asks for the board.

The bus carries `EvolutionChanged` on the `Outputs` topic under the session's
own key. The catalogue is daemon-wide, but the generation and the queue the
board draws are this session's. It is published, in this order of
responsibility:

- by the door's wrapper after `approve`, `revoke`, `select` or `rollback` has
  returned `Ok`. A mutation answers `Ok` only after its commit is durable, so the
  hint cannot overtake the write. A selection staged through the queue answers
  `queued` before it commits;
- by the transition queue when its job ends, completed or failed, after the
  commit and after the receipt has moved to its terminal status. A reader woken by
  the hint finds the outcome.

The push is a hint, and the board is read under the same bounds whether or not
the hint arrived. Two cases are left to a reader's own refresh and are not
announced: a generation that publishes late through the live owner's retry of
retirement, and a session restart. A page reads the board when it opens and
should read it again on a long interval.

*Audit text.* Each approval, revocation and selection already appends a custom
audit entry whose data is text. This proposal adds `via` (`cli`, `web` or
`terminal`) to the approval and revocation objects and to the approval register.
It changes the selection entry from `<reason>: <selection json>` to an object
`{"selection", "principal", "via", "reason", "request_id"}`, because the old text
named no principal and could not be split back apart when the reason held a
colon. The reader of the board reads both: an entry in the old shape yields a row
with a reason, a candidate, a name and a generation, and an empty principal,
surface and request identity. Nothing but the board reads these entries. The
surface is not part of a selection request's signature, so retrying a request
from another surface still finds its receipt.

The gateway derives the surface from the connection. A page is known by the
browser sign-in the binding carries, or by a browser credential, and records
`web`. Every other attachment holds a bearer, and a terminal and the `loom
evolution` command hold the same kind, so a terminal may name itself with an
optional `via: "terminal"` argument. The claim can only name `terminal` or `cli`,
never `web`, it is audit text, and nothing reads it for authority.

## What it costs

A holder of an owner page's cookie, key and nonce can now approve and select a
workspace program or an exact-model prompt, which bind *other* sessions, and can
read exact-model candidates. They cannot submit a core upgrade. 073 accepted the
same shape of cost for remembered grants, on the ground that a page can already run
commands the owner never typed, and bounded it by making the act visible and
reversible. The history list, with the principal and surface of each decision,
and `revoke` and `rollback` are that visibility and reversal here. The owner should
confirm this ruling before the page that uses it ships; this change adds the
authority and no page.

The board's catalogue read is one lease and decodes every retained evidence row
to find its candidate's, at most 256 rows. It runs on a page open, a push and a
slow interval, never in a tight loop, and the lease is the same fenced one every
catalogue operation takes.

## Compatibility

The protocol version stays 2. The change is an added action, an added event and an
added argument that is optional, and every existing action keeps its reply.
`protocol.Evolution` accepts `board`; an older daemon refuses it as an unsupported
action, which a client draws as a sentence. The door's `command` function takes
the surface as a new argument, so an embedding that builds its own door changes in
step; the in-tree doors are the catalogue door, the reviewed-upgrade door and the
wrappers in `client/serve`. A catalogue written before this change is read without
migration. A daemon rolled back to an earlier build reads the approval register's
extra `via` field as it reads any unknown field of a JSON object, and shows the new
selection entries to nobody, since only this board read them.
