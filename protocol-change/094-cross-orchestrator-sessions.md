# protocol-change/094: a page starts and drives a top-level session on another orchestrator

**Status**: ACCEPTED 2026-10-21. The owner authorised the placement revamp end
to end, including the protocol changes it needs
([docs/design-notes/placement-revamp.md](../docs/design-notes/placement-revamp.md)).
Built in slices S2a and S2b of that note.
**Affects**: the client control protocol (Part 1.6) by one web route,
`/ui/peers/<orchestrator>/sessions/<id>`, served under the rules of
[051](051-web-view-route.md) and [052](052-web-view-remote-origin.md); no
control command changes and `sessions.list` stays unmerged. Not Part 1: the
orchestrator port's closed message type gains ten constructors;
`loom.toml` gains `[spawners.<name>.top_level]` and its
`approval_ceiling`; the catalogue gains `catalogue_relayed_sessions`.
**Raised by**: the owner's goal of starting "agent on box, code on exec" from
the laptop's page, and of using one page from a phone.
**Builds on**: [084](084-remote-subagents.md) (the spawner trust, the port,
the box's outbox, the link keeper of S9), [089](089-remote-approvals.md)
(approvals decided on the other side within a ceiling), [090](090-remote-observation.md)
(bounded transcript pages and pushed summaries), [074](074-web-new-folder-sessions.md)
(the folder checks and the creation rate limit).
**Amends**: the rulings of [078](078-distributed-runtime.md) ("nothing
follows a redirect") and [085](085-distributed-admin-surface.md) ("attach the
local daemon to a foreign session", rejected), for spawners whose owner opts
in. Both rulings stand for every other case.

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

### Merging the box's sessions into `sessions.list` (rejected again)

078 and 085 rejected a merged control listing because it invites selecting a
row owned elsewhere. This change keeps that ruling. The merge happens only in
the laptop page's projection, which knows the row is relayed and draws it
with the box's name.

## Decision

**Accepted: a relay over the spawner trust.** The laptop's daemon asks the
box's orchestrator port, over the pinned link, to list placements, create a
session, page its sessions with their state, page a transcript, deliver a
message, stop a run, archive, and resolve an approval. The box judges every
request against a `[spawners.laptop.top_level]` table. The browser talks only
to the laptop; the box never sees it.

### Configuration, on the box

```toml
[spawners.laptop]
node = "laptop@100.64.0.5"
directory = "/home/exedev/scratch"    # 084's placement for children, unchanged
# ... the 084 keys for children ...

[spawners.laptop.top_level]
executors = ["exec"]                  # executors whose workspaces the page may pick
pools = ["linux"]                     # pools the page may pick
folders = "recent"                    # "none", "recent" or "typed"
profiles = ["default", "codex"]       # absent means every [profiles.<name>]
max_open = 8                          # relayed sessions resident at once
max_per_hour = 10                     # creations, counted on the box
list = "relayed"                      # "relayed" or "owner"

[spawners.laptop.top_level.approval_ceiling]
writable_roots = ["/home/exedev"]
network = "allow"
```

| Key | Meaning |
|---|---|
| (table present) | The spawner may create top-level sessions. Absent means every message below is refused with `TopLevelOff`. |
| `executors`, `pools` | The executors and pools whose registered workspaces the page may choose. Each must be a key of the box's `[executors.<name>]` or `[pools.<name>]`. Default empty. |
| `folders` | `none`: no folder on the box. `recent`: only the box's remembered folders (`catalogue_recent_folders`). `typed`: also a typed path, judged by the box's own folder check from 074. Default `recent`. |
| `profiles` | The profiles a relayed session may start with. Default every profile. Models are the box's catalogue. |
| `max_open` | Relayed sessions of this spawner that may be resident at once, 1 to 64, default 8. A create or a message that would open one more is refused `CapReached`. |
| `max_per_hour` | Creations per rolling hour, default 10, the web page's own rate. |
| `list` | `relayed`: the page sees only sessions it created. `owner`: also every session the box's owner holds alone (`manager.unshared_sessions`). Default `relayed`. |
| `approval_ceiling` | The grants a decision from the laptop's page may make, in the shape of 089. Absent means the page shows a relayed session's requests and cannot decide them. |

The decoder refuses an unknown executor, pool or profile, a `max_open` out of
range, and the table under a spawner whose `node` is not a distribution peer.
Ledger mode never derives it, as for the rest of `[spawners]`.

On the laptop nothing new is configured: every `[orchestrators.<name>]` row is
asked once whether it admits top-level sessions, and only those that answer
appear in the Agent chip.

### The orchestrator port (`client/remote/orchestrator_port.Message`)

Every message is judged against the spawner table that the sender's node
resolves to, taken from the process that asked, as in 084. Each runs in a task
linked to the port. All are idempotent.

Laptop to box:

- `Placements(reply)`. Answers `{folders, executors, pools, profiles,
  models}` as the box would draw them for its own page: folder labels, each
  executor's health and workspaces with their mode (095), each pool's ready
  count. Filtered by the table. At most 256 entries.
- `TopCreate(request_id, placement, profile, model, text, reply)`.
  `request_id` is a UUIDv7 the laptop mints per submit. `placement` is
  `Folder(path)`, `Workspace(executor, name)` or `Pooled(pool, name)`. The box
  checks the placement against the table and its own configuration, the
  profile against `profiles`, the caps, and for a folder the 074 checks. It
  creates the session through `manager.create_scoped` with the `SessionOnly`
  domain, records the row below, sends `text` as the first message, and
  answers `Created(session_id)`. A repeat of `request_id` answers the same
  session.
- `TopSessions(after, limit, reply)`. One page of the sessions `list` admits,
  newest first: `{session_id, name, placement, activity, reason, updated_at,
  children}`. `activity` is `NeedsYou`, `Working`, `Idle` or `Archived`;
  `reason` is a fixed-word summary of a pending request ("approve bash");
  `children` are the session's own remote and local child stubs. At most 64
  rows and 64 KiB per page, the bound of 090.
- `TopHistory(session, cursor, limit, reply)`. A transcript page, as
  `ChildHistory` in 090, for a session `list` admits.
- `TopSend(session, message_id, text, reply)`. Delivers `text` to the
  session's main strand, with a receipt stored under `message_id`, as
  `ChildSend` in 084.
- `TopStop(session, reply)`. Stops the main strand's current run.
- `TopArchive(session, reply)`. Archives the session. There is no delete:
  deleting is done on the box's own page.
- `TopResolve(session, escalation_id, decision, expected_seq, decided_by,
  reply)`. Judged as 089's `Resolve`, against
  `[spawners.laptop.top_level.approval_ceiling]`, with the same seq
  compare-and-set. The descendant check is replaced by "the session is
  relayed or admitted by `list`".

Box to laptop:

- `TopChanged(session)`, a data-free notice sent when a relayed session's
  activity changes. The laptop answers by asking for the page again. Lost
  notices are not resent; the laptop also re-pages every 5 s while a page
  that shows relayed rows is open.
- `TopEscalation(session, record, reply)`, sent through the box's existing
  outbox and drainer (084 S9, 089) when a relayed session parks on a request.
  The laptop files it as `remote-escalation/{orchestrator}/{id}` in memory for
  the page; it is not written to a laptop session store, since the laptop
  holds no session for it.

`TopEscalation` and `TopResolve` are new constructors rather than new uses of
`ChildEscalation` and `Resolve`, so that 089's descendant check is not
weakened for children.

### Records

On the box, in the catalogue, at the next catalogue version:
`catalogue_relayed_sessions(spawner, session_id, request_id, created_at,
last_contact_ms)`, with `session_id` unique and referencing
`catalogue_sessions` and `request_id` unique. It answers "may this spawner see
this session" and makes `TopCreate` idempotent. Archiving keeps the row;
deleting the session on the box's page removes it with the session.

On the laptop: nothing durable. A relay worker (a weft managed task) per
admitting orchestrator holds the last page and the open requests in memory.
The session exists in one catalogue, the box's, so no identity is listed by
two catalogues and `sessions.elsewhere` keeps its invariant.

### The page

The laptop's page draws the relayed rows in its sidebar, merged by state with
its own rows, each tagged with the box's name. The session page for a relayed
session is served at `/ui/peers/<orchestrator>/sessions/<id>`, where
`<orchestrator>` is a configured `[orchestrators.<name>]` key and `<id>` is a
UUID that appears in the relay's last page. Neither is untrusted text: the
first is the operator's configuration and the second is validated as a
UUIDv7. Session names, folder paths and reasons from the box are drawn only as
text nodes.

What the laptop page may do with a relayed session: create it, list it, read
it, send to its main strand, stop its run, archive it, and decide its requests
inside the ceiling. What it may not do: delete it, share it or invite anyone,
move it, change its profile or model, fork it, open any strand but main, or
read a session `list` does not admit.

Admission on the laptop:

- Only the owner's page at the Operator ceiling draws relayed rows, the
  Agent chip's other orchestrators, or the relayed session page. Any other
  page draws none of them and its socket refuses their paths.
- Every chip value is a position in a list the server drew from the last
  `Placements` answer. A submit whose position is not in that list is refused.
- A relayed create counts against the laptop page's own ten-an-hour allowance
  and against the box's `max_per_hour`.

### When the link drops

- The relayed session keeps running on the box. Nothing in its run waits on
  the laptop.
- The laptop's sidebar keeps the last page, greyed, with "box not reachable,
  seen 2m ago". The Agent chip shows the box disabled with the same reason.
- A create while the link is down is refused at once with that reason; it is
  not queued. A create whose answer was lost is resent with the same
  `request_id` for up to 30 s, with 084's doubling pause; after that the page
  says the outcome is unknown, and the next `TopSessions` page shows the
  session if it was made.
- A message whose answer was lost is resent with the same `message_id` within
  the same window. The composer keeps the text until a receipt arrives.
- A request card stays drawn. A decision while the link is down is refused
  with the reason. The box keeps the request in its outbox for 089's answer
  window, and it can always be decided on the box's own page; the first
  decision wins through the seq compare-and-set.
- The link keeper of 084 S9 reconnects every two seconds while the laptop
  holds a page with relayed rows open or holds an undecided request.
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
  created, or for the owner's unshared sessions when `list = "owner"` is set,
  and only on the box owner's word. The vocabulary stays closed: ten named
  constructors, each with a fixed answer type.
- **089.** A decision from the laptop is judged on the box, inside the
  ceiling, with the stored `wanted` list and the seq compare-and-set. The box's
  own page keeps full authority over the same request.
- **The widening, stated.** A stolen laptop owner cookie now also reaches
  relayed sessions on the box, within the top-level table and its ceiling.
  Before this change it reached only the laptop. The owner accepts this as the
  price of one page; `approval_ceiling` absent and `list = "relayed"` are the
  defaults so the widening is no larger than the owner configures.

## What it costs

- Ten port constructors that both ends must know, under 078's same-build
  rule.
- One catalogue table and a version step on the box.
- One web route, a relay worker per admitting orchestrator, and new admission
  paths in `ui_socket`, each pinned by `ui_socket_test`.
- A laptop page that shows state it does not own: its view of the box can be
  up to one re-page (5 s) stale, and stale for as long as the link is down.
- A second place to decide a request, resolved by the existing seq
  compare-and-set rather than by a new lock.
- The terminal client gets none of this; it is a web-only path until a
  control command is proposed.
