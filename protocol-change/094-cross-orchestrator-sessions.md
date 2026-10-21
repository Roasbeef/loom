# protocol-change/094: a page starts and drives a top-level session on another orchestrator

**Status**: ACCEPTED 2026-10-21. The owner authorised the placement revamp end
to end, including the protocol changes it needs
([docs/design-notes/placement-revamp.md](../docs/design-notes/placement-revamp.md)).
Revised the same day after an independent review: the protocol is pull-only,
the create is reserved in one catalogue transaction, and the `owner` listing
and typed folders are left to a later change. Built in slices S2a and S2b of
that note.
**Affects**: the client control protocol (Part 1.6) by one web route,
`/ui/p/<key>/orchestrators/<name>/sessions/<id>` with its `/ws` socket, served
under the rules of [051](051-web-view-route.md) and
[052](052-web-view-remote-origin.md); no control command changes and
`sessions.list` stays unmerged. Not Part 1: the orchestrator port's closed
message type gains eight constructors, all sent from the laptop to the box;
`loom.toml` gains `[spawners.<name>.top_level]` and its `approval_ceiling`;
the catalogue gains `catalogue_relayed_sessions`.
**Raised by**: the owner's goal of starting "agent on box, code on exec" from
the laptop's page, and of using one page from a phone.
**Builds on**: [084](084-remote-subagents.md) (the spawner trust and the
port), [089](089-remote-approvals.md) (approvals decided on the other side
within a ceiling), [090](090-remote-observation.md) (bounded transcript
pages), [074](074-web-new-folder-sessions.md) (the folder checks and the
creation rate limit), and 078's `reserved` registration.
**Amends**: [085](085-distributed-admin-surface.md)'s rejection of "attach
the local daemon to a foreign session", for spawners whose owner opts in. The
rejection stands for every other case.

## Problem

A web page is bound to the daemon that serves it. The laptop's page creates
sessions only on the laptop, and lists the box's sessions under "Sessions on
other orchestrators" as information: "A row is information and not a door"
(`docs/architecture/web-view.md`, the section on other orchestrators). To start
a session whose agent runs on the box, the owner opens the box's page, which
has its own sign-in, its own list and its own approvals. On a phone that means
two bookmarks and two sign-ins, and there is no single list of what needs the
owner.

Remote subagents (084) already let a session on the laptop start a child on
the box, message it, approve its requests and read its transcript, over the
pinned TLS distribution link and under a `[spawners.laptop]` table on the box.
What is missing is a session with no parent: a top-level session, started by
the owner from a page, that lives on the box.

## What was considered

### A ticket minted by the box and handed through the laptop (rejected)

"Agent on box" would navigate the browser to the box's page with a one-use
ticket the box mints for the laptop to pass on. It needs no new port messages.
It was rejected because the phone must reach both daemons, the sidebar cannot
show the box's sessions with their state, and a ticket would travel through a
second daemon and the browser history, which 051 avoids by design.

### A control credential for the box held by the laptop (rejected)

The laptop could keep a token for the box's `/v2/control` and act as a control
client. Part 1.6 would not change. It was rejected for the reason 084 rejected
a scoped `delegate` principal: a second credential at rest, with the owner's
full power on the box and none of the spawner's caps.

### Embedding the box's page (rejected)

An iframe or a shared cookie breaks the Origin and Host rules of 051 and 052.

### A delegate session with no parent agent (rejected)

`Spawn` could be called with a synthetic parent. Every delegate rule assumes a
parent run: the ended fence, `within_ms` deadlines, depth, `retain_s` measured
from the spawner's last message. A top-level session has no deadline and is
kept until the owner archives it. Bending those rules would weaken 084's
checks for real children.

### The box pushes changes and requests (rejected)

The first draft had the box send `TopChanged` notices and `TopEscalation`
requests through its outbox, as 089 does for children. The laptop would file
requests in memory, so a laptop restart lost them, and the box would need a
new outbox row kind, its drainer, and a link back to the laptop. A page that
is open can read instead: the laptop asks when a page needs the answer, and a
pending request is read from the box each time, so nothing is lost when the
laptop restarts.

### Merging the box's sessions into `sessions.list` (rejected again)

078 and 085 rejected a merged control listing because it invites selecting a
row owned elsewhere. This change keeps that ruling. The merge happens only in
the laptop page's projection, which knows the row is relayed and draws it
with the box's name.

## Decision

**Accepted: a pull relay over the spawner trust.** The laptop's daemon asks
the box's orchestrator port, over the pinned link and dialling on demand, to
list placements, create a session, page its sessions with their state and
pending requests, page a transcript, deliver a message, stop a run, archive,
and resolve a request. The box judges every request against a
`[spawners.laptop.top_level]` table. The box sends nothing on its own. The
browser talks only to the laptop; the box never sees it.

### Configuration, on the box

```toml
[spawners.laptop]
node = "laptop@100.64.0.5"
directory = "/home/exedev/scratch"    # 084's placement for children, unchanged
# ... the 084 keys for children ...

[spawners.laptop.top_level]
executors = ["exec"]                  # executors whose workspaces the page may pick
pools = ["linux"]                     # pools the page may pick
folders = "recent"                    # "none" or "recent"
profiles = ["default", "codex"]       # absent means every [profiles.<name>]
max_sessions = 8                      # relayed sessions not archived
max_per_hour = 10                     # creations, counted on the box

[spawners.laptop.top_level.approval_ceiling]
writable_roots = ["/home/exedev"]
network = "allow"
```

| Key | Meaning |
|---|---|
| (table present) | The spawner may create top-level sessions. Absent means every message below is refused with `TopLevelOff`. |
| `executors`, `pools` | The executors and pools whose registered workspaces the page may choose. Each must be a key of the box's `[executors.<name>]` or `[pools.<name>]`. Default empty. |
| `folders` | `none`: no folder on the box. `recent`: only the box's remembered folders (`catalogue_recent_folders`), each judged again by the box's folder check from 074 at create. Default `recent`. |
| `profiles` | The profiles a relayed session may start with. Default every profile. Models are the box's catalogue. |
| `max_sessions` | Relayed sessions of this spawner that are not archived, 1 to 64, default 8. |
| `max_per_hour` | Creations per rolling hour, default 10, the web page's own rate. |
| `approval_ceiling` | The grants a decision from the laptop's page may make, in the shape of 089. Absent means the page shows a relayed session's requests and cannot decide them. |

The decoder refuses an unknown executor, pool or profile, a `folders` value
other than the two above, a `max_sessions` out of range, and the table under a
spawner whose `node` is not a distribution peer. Ledger mode never derives it,
as for the rest of `[spawners]`.

On the laptop nothing new is configured. Each time a page opens the composer,
the laptop asks every `[orchestrators.<name>]` row for its `Placements`,
dialling on demand; only those that answer appear in the Agent chip, and a
peer that refuses with `TopLevelOff` or does not answer within the deadline is
shown disabled with the reason.

### The orchestrator port (`client/remote/orchestrator_port.Message`)

Every message goes from the laptop to the box. Each is judged against the
spawner table that the sender's node resolves to, taken from the process that
asked, as in 084, and runs in a task linked to the port. All are idempotent.
Calls use 084's sending end: connect if not connected, send, wait under a
deadline (30 s for `TopCreate`, 7 s otherwise).

- `Placements(reply)`. Answers `{folders, executors, pools, profiles,
  models}` as the box would draw them for its own page: folder labels, each
  executor's health and workspaces with their mode (095), each pool's ready
  count. Filtered by the table. At most 256 entries.
- `TopCreate(request_id, placement, profile, model, reply)`. `request_id` is a
  UUIDv7 the laptop mints per submit. `placement` is `Folder(path)`,
  `Workspace(executor, name)` or `Pooled(pool, name)`. The box checks the
  placement against the table and its own configuration, the profile against
  `profiles`, and for a folder the 074 checks; then it reserves the session as
  described under Records and answers `Created(session_id)`. A repeat of
  `request_id` answers the same session. The create carries no prompt: the
  page sends the first message with `TopSend`, under its own `message_id`, as
  soon as `Created` arrives.
- `TopSessions(after, limit, reply)`. One page of this spawner's relayed
  sessions, newest first: `{session_id, request_id, name, placement, activity,
  updated_at, requests, children}`. `activity` is `NeedsYou`, `Working`,
  `Idle` or `Archived`. `requests` are the session's pending escalation
  records, in 089's record shape with `placement` and `admitted`: the 8
  oldest by `seq`, with `more: n` counting the rest. `children` are the
  session's own child stubs. At most 64 rows and 64 KiB per page, cut at the
  byte bound as in 090; a row's `requests` is never split across pages, so a
  row is either whole on a page or absent from it. `request_id` lets the
  laptop reconcile a create whose answer it never received.
- `TopHistory(session, cursor, limit, reply)`. A transcript page, as
  `ChildHistory` in 090, for a relayed session of this spawner.
- `TopSend(session, message_id, text, reply)`. Delivers `text` to the
  session's main strand, with a receipt stored under `message_id`, as
  `ChildSend` in 084. Admitting the first message opens the session.
- `TopStop(session, reply)`. Stops the main strand's current run.
- `TopArchive(session, reply)`. Archives the session. There is no delete:
  deleting is done on the box's own page.
- `TopResolve(session, escalation_id, decision, expected_seq, decided_by,
  reply)`. Judged on the box in the session hub's turn, as
  `client/remote_decision` judges 089's `Resolve`: against
  `[spawners.laptop.top_level.approval_ceiling]`, against the stored `wanted`
  list, and with the same seq compare-and-set. The descendant check is
  replaced by "the session is relayed for this spawner". A relayed session
  with a pending record may be saved rather than resident; `TopResolve` on a
  saved session opens it the way `TopSend` does, then is judged in the hub's
  turn. A decision on a call that already settled in band is remembered and
  applies at the next run, as a local operator's decision is; it does not
  start a run.

Every message other than `Placements` and `TopCreate` refuses a session that
is not in `catalogue_relayed_sessions` for this spawner with `NotRelayed`.

`TopResolve` is a new constructor rather than a new use of `Resolve`, so that
089's descendant check is not weakened for children.

### Records

On the box, in the catalogue, at the next catalogue version:
`catalogue_relayed_sessions(spawner, request_id, session_id, created_at)`,
with `request_id` unique, `session_id` unique and referencing
`catalogue_sessions`.

A create runs one immediate catalogue transaction that does all of the
following or none of it:

1. Look up `request_id`. A row answers its session, and nothing else is
   done in the transaction; after it, a `reserved` registration whose store
   was never made is finished as below.
2. Count this spawner's relayed sessions that are not archived, by a join
   against the catalogue's own session state, against `max_sessions`, and its
   rows created in the last hour against `max_per_hour`. Either cap
   answers `CapReached(key, limit)` and writes nothing.
3. Insert the session's registration in 078's `reserved` state.
4. Insert the relayed row naming it.

Because the caps are counted inside the transaction that inserts, two
concurrent creates cannot both pass them, and because the registration and the
row are inserted together, a crash leaves either both or neither. The
session's store is created after the transaction, by the same path that turns
a `reserved` registration into a session today; a crash there leaves a
reserved session that a resent `TopCreate` finds by `request_id` and finishes.
No boot sweep drops a `reserved` registration today: one that is never
finished stays listed with the `Reserved` status of `client/daemon/manager`.
A relayed one is finished by the laptop's resend of its `request_id`, which
the laptop keeps for the 30 s retry window. One the laptop never resends stays
`Reserved` on the box's page and in the laptop's listing, and still counts
against `max_sessions`; deleting it on the box's page removes the
registration and its relayed row together. Adding a sweep is left to #1056,
which tracks the same shape in the 084 path.

The same shape is wrong in today's 084 path: a delegate session is registered
(`reserve`) before `claim_delegate` (`catalogue.gleam:1719`) inserts its
delegate row in a second transaction, so a box crash between the two leaves a
registered session with no delegate row, and a resent `Spawn` creates a second
one. This change does not fix it; it is tracked as #1056.

Archiving changes only the session's own state and keeps the row; deleting the session on the box's
page removes the row with the session.

On the laptop: nothing durable. A relay worker (a weft managed task) per
orchestrator holds the last `TopSessions` page for pages that are open. A
laptop restart loses nothing, because the next page reads the box again.
The session exists in one catalogue, the box's, so no identity is listed by
two catalogues and `sessions.elsewhere` keeps its invariant.

### Visibility and reading

085's `Sessions` constructor already lets a pinned peer list the box owner's
sessions; the laptop's "Sessions on other orchestrators" group is drawn from
it. This change does not alter who can see that a session exists. What
`catalogue_relayed_sessions` governs is reading and driving: only a relayed
session's transcript, requests, messages, stop and archive are served to the
spawner. A later protocol change may widen that to the owner's unshared
sessions; this one does not.

### The page

The laptop's page draws the relayed rows in its sidebar, merged by state with
its own rows, each tagged with the box's name. The session page for a relayed
session is served at `/ui/p/<key>/orchestrators/<name>/sessions/<id>`, with
its socket at the same path plus `/ws`, under the page key of 051. `<name>` is
a configured `[orchestrators.<name>]` key and `<id>` is a UUID that appears in
the relay's last page; neither is untrusted text. The path does not use
"peers", which already means 077's peer links. Session names, folder paths,
request summaries, and on a relayed page every image and tool result, are
drawn as text nodes; a relayed page draws no image and no rendered result
from the box.

What the laptop page may do with a relayed session: create it, list it, read
it, send to its main strand, stop its run, archive it, and decide its requests
inside the ceiling. What it may not do: delete it, share it or invite anyone,
move it, change its profile or model, fork it, open any strand but main, or
read a session that is not relayed for its spawner.

Admission on the laptop:

- Only the owner's page at the Operator ceiling draws relayed rows, the
  Agent chip's other orchestrators, or the relayed session page. Any other
  page draws none of them and its socket refuses their paths.
- Every chip value is a position in a list the server drew from the
  `Placements` answer read when the composer opened. A submit whose position
  is not in that list is refused.
- A relayed create counts against the laptop page's own ten-an-hour allowance
  and against the box's `max_per_hour`.

### When the link drops

- The relayed session keeps running on the box. Nothing in its run waits on
  the laptop.
- The laptop's sidebar keeps the last page, greyed, with "box not reachable,
  seen 2m ago". The Agent chip shows the box disabled with the same reason.
- A create while the link is down is refused at once with that reason; it is
  not queued. A create whose answer was lost is resent with the same
  `request_id` for up to 30 s, with 084's doubling pause. After that the page
  says the outcome is unknown, and the next `TopSessions` page that carries
  the `request_id` names the session if it was made; the page then sends the
  first message it still holds.
- A message whose answer was lost is resent with the same `message_id` within
  the same window. The composer keeps the text until a receipt arrives.
- A request card stays drawn from the last page. A decision while the link is
  down is refused with the reason. The request stays pending on the box, is
  read again on the next page, and can always be decided on the box's own
  page; the first decision wins through the seq compare-and-set.
- The laptop holds no link open on its own. While a page with relayed rows is
  open it re-reads `TopSessions` every 5 s, which dials when needed.
- Both ends must run the same build, as 078 requires. A port without the new
  constructors stops on them, which the laptop reports as "box runs an older
  Loom".

### Security argument

- **051 and 052.** The browser holds a ticket and cookie for the laptop only.
  The box has no browser-facing change. The page role is still min(membership,
  ceiling, Operator), and only the owner's Operator page reaches relayed
  sessions. No URL, class, attribute or key is built from box text.
- **084.** The trust is the pinned TLS distribution peer. A pinned peer is
  already fully trusted in both directions (it can move sessions with
  `Import` and `Activate`); the spawner table bounds an honest peer's mistakes,
  not a hostile peer. The box's owner opts in per peer with the `top_level`
  table, and caps the placements, profiles, counts and rate.
- **085's rejection.** 085 rejected attaching a local daemon to a foreign
  session because the port's closed vocabulary keeps a peer from reading a
  conversation. This change reverses that only for sessions the spawner
  created, and only on the box owner's word. The vocabulary stays closed:
  eight named constructors, each with a fixed answer type.
- **089.** A decision from the laptop is judged on the box, in the session
  hub's turn, inside the ceiling, with the stored `wanted` list and the seq
  compare-and-set. The box's own page keeps full authority over the same
  request.
- **The widening, stated.** A stolen laptop owner cookie can now read, send
  into, stop, and approve within `approval_ceiling` every relayed session of
  the laptop's spawner on the box, and start new agents there within the
  `top_level` table's placements, profiles and caps. Before this change it
  reached only the laptop. The owner accepts this as the price of one page.
  With `approval_ceiling` absent the stolen cookie cannot approve.

## What it costs

- Eight port constructors that both ends must know, under 078's same-build
  rule.
- One catalogue table, one catalogue function with its transaction, and a
  version step on the box.
- One web route, a relay worker per orchestrator, and new admission paths in
  `ui_socket`, each pinned by `ui_socket_test`.
- A laptop page that shows state it does not own: its view of the box can be
  up to one re-read (5 s) stale, and stale for as long as the link is down.
- A second place to decide a request, resolved by the existing seq
  compare-and-set rather than by a new lock.
- A page that reads where the first draft pushed: a pending request is seen up
  to 5 s late.
- The terminal client gets none of this; it is a web-only path until a
  control command is proposed.
