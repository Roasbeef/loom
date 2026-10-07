# protocol-change/077: peer links on the web page, and an opt-in default link

**Status**: ACCEPTED 2026-10-06. **Affects**: the `[peers]` table of the daemon
configuration (new), peer admission in `client/peer_mail` (a default link, a
denial record, three listings), the daemon's peer commands' output (a `default`
mark and a roster `running` field), the session registry (one read), the web
view's Session pane (one owner-only section and one transport capability), and
the page socket's admitted paths. No frame, command or event of Part 1 is added
or removed. **Raised by**: issue #906 and the owner's rulings of 2026-10-06.
**Builds on**: [048](048-async-collaboration.md) (directional peer links),
[073](073-web-session-grants.md) (an owner-only web control with a list and a
Forget), [051](051-web-view-route.md) (what a page may draw and ask), and
[067](067-session-subtitle.md) (the page's rename control, where the daemon re-derives the owner at the click).

## Problem

Peer links are the grants that let one session's strand put a message into
another's prompt. The terminal manages them (`/peers`) and so does `loomd peer`.
The web page cannot, so an owner who works on the web leaves the page to link two
sessions, and the A2 design's "Peer links" list in the People panel has nothing
behind it.

Separately, a model can message another session only after the owner has granted
that exact pair, in both directions if both should speak. An owner who runs
several sessions and trusts them equally has to make that grant for every pair
before a model's `peer_roster` shows anything. The owner asked for a way to say
once that the sessions the daemon's owner holds are linked.

## Considered

**Manage links from the page with a new daemon command.** The page would send a
new frame the daemon decodes. Not taken. `peers.inspect`, `peers.link` and
`peers.unlink` already do this work and the terminal already drives them, so a
second implementation would be a second place for the rules to drift. The page
asks by value through the transport, the way the invitation and rename controls
do, and the daemon runs the same functions.

**Show the list to members and observers.** A row names another session and what
it is called. A person who may not see that session should not learn it exists
from a link. Not taken: the list and the controls are the owner's, and a member's
or an observer's page reads nothing and draws nothing. The issue allowed "the
list, if anything"; this is the "nothing".

**Implement the default as links written to every pair.** Create a real grant
for each pair when the setting is on. Not taken. A grant is a durable record
that survives the setting being turned off, a new session would need a grant
from and to every other, and a session that later gains a member would keep its
grants. The default has to follow the setting and the session's standing, so it
is computed and never stored.

**Decide the default in the listings, or in the sender.** The sender's roster and
send path would decide that a pair is linked, and the recipient would trust it.
Not taken. The recipient's admission is the only authority for delivery
(`peer_mail`: the recipient's grant is what a message needs), so the default is
decided there. The listings the model and the owner read ask the same function,
so what they show is what delivery admits.

**Link every session, including those another person can read.** The rule would
be simply "all sessions on this daemon". Not taken, and argued under the trust
boundary below.

**Link every strand of every session.** Not taken. A session's other strands are
the model's own workers and branches. A default link joins `main` to `main` and
nothing else, so a model never gains a way to address another session's worker
without a grant that names it.

**Open a session when a message is sent to it.** With the default on, a send to
a closed session could resume it. Not taken, and recorded as a limit below.

## Decision

**Accepted.**

### Configuration

`loom.toml` gains an optional table, decoded strictly and totally with the
daemon's other settings (`client/peer_defaults`) and validated by the
catalogue parser as well as at startup:

```toml
[peers]
default_links = "off"        # "off" | "same_owner"
default_wake  = "busy_only"  # "busy_only" | "may_wake"
```

Both keys are optional and default as shown. An unknown key, a value of another
type and a word not listed are refused with the key's full name. The daemon reads
the table once at startup, like `[daemon]`, and never rereads it: a session's own
configuration cannot turn the default on. The default stays `off` in shipped
configurations and in the example file.

### The default link

Under `same_owner`, delivery from `main` of session S to `main` of session T is
admitted when no grant for the pair exists and all of these hold:

1. S and T are different sessions;
2. both sessions are among the sessions the daemon's owner holds alone (the
   trust boundary below);
3. the pair has no recorded denial;
4. the delivery is `main` to `main`.

The wake permission is `default_wake`. An explicit grant for the pair is the
whole decision when one exists, so its wake permission overrides the default's.
The decision is one function, `peer_mail.implicit_wake`, called by delivery, by
the recipient's roster (`Roster`), and by the two listings (`Links`, `Grants`).
There is no second authorization path: the sender's discovery only lists what the
recipient would admit, and the recipient decides again at delivery. A default
admission commits the receipt under the guard that no grant and no denial has
appeared, as an explicit admission commits it under the grant's sequence.

### Denials

An explicit unlink of a `main` to `main` pair records a denial in both sessions:
a reserved fact `client/peers/denial/<digest>` keyed by the digest of
`[source_session, source_strand, target_session, target_strand]`, holding those
four fields. The sender's copy decides what its roster and outgoing list show, and
the recipient's decides what it admits. `Revoke` (recipient) and `Unlink`
(sender) write the denial and remove the grant or link in one transaction;
`Allow` and `Link` remove the denial in the same transaction that writes the
grant or link, so granting a pair again lifts the denial. Unlinking a pair that
exists only as a default records the denial and nothing else to remove. Only a
`main` to `main` pair records one, since no other pair can be a default, so the
fact does not grow with unrelated links. Turning the setting off hides defaults
and leaves denials in place, which is the safe order if it is turned on again. The recipient's incoming list can show a default
row that the sender has denied while the recipient was not running, because the
denial is recorded only in sessions that are resident; delivery still refuses
it, since the sender's roster no longer lists the pair.

### Trust boundary

An implicit link lets a model in one session put text into another session's
prompt, as any link does, without the owner having chosen that pair. The default
is therefore limited to what the owner can already reach from both sides.

*Eligible sessions* are the sessions the daemon's owner holds alone: active
(not archived) sessions in the catalogue that have no membership row of either
role. The registry answers this on each call (`manager.unshared_sessions`), one
query of the membership table and the catalogue pages, bounded at 256 sessions, and
nothing is remembered. A session that has an invited member, an observer or any
other principal is not eligible, as sender or as recipient. Inviting a person
into a session therefore ends its default links at once, because the next
admission or listing asks again. A catalogue that cannot answer lists nothing,
which refuses the default and never widens it. An admission that has already read eligibility still commits, so inviting
someone ends default links from the next admission and not from one already
in flight.

The argument that this is safe is that a default link adds no reader and no
writer to either session. Both sessions are ones only the owner can open, the
owner could grant the same link from the terminal in one command, and the model
that gains the ability runs under the owner's own configuration and approvals in
a session the owner chose to run. A session with a member is different: the
member can read what a linked model writes and can read what arrives, so a default
link would carry text across a boundary the owner drew when it invited that
person. That needs a decision about that person, so it needs a grant.

Sessions in different workspaces are linked. Workspace similarity is not an
authority (048), and the owner's daemon holds one owner. An owner who wants
separation keeps `default_links = "off"` or isolates sessions with members.

The link is `main` to `main` only. Delivery into a session still follows the
recipient's own admission: a `busy_only` link adds to a running strand and does
nothing to an idle one, and `may_wake` starts a run on the recipient's `main`,
which is the permission an owner who sets `default_wake = "may_wake"` has chosen
for every eligible pair.

### What a send to a closed session does

A session is resident only between an explicit open and a stop, an archive or a
daemon restart. There is no idle timeout, and link and send need both ends
resident. With the default on, `peer_roster` lists every eligible session of the
owner, resident or not, and each roster row carries `running: true` or `false`.
A closed session's row has no exported strands. A send to a closed session is
refused with `that session is not running; the owner has to open it`.

This is a deliberate limit and no setting changes it. A model never causes a
session to open. Opening on a message would let one model start another session's
runtime, its schedules and its resumed operations, which is a larger grant than
adding a prompt to a session that is already running. The refusal is for every
send, explicit links included.

### The roster's bound

A strand holds at most 64 outgoing links (`peer_mail.outgoing_link_limit`). The
default entries share that bound with the explicit ones: explicit links are listed
first, then default entries in session-ID order until 64, and the rest are not
listed and cannot be addressed (the send path checks the same list). The tool
description says so. The owner sees the count in `loomd peer inspect`, and removing
a link or a session makes room. No frame grows.

### Wire and storage

* `peer_mail.Links(source_strand)` rows gain an optional `default: true` on a
  default link. `Grants(target)` rows gain it likewise. A recorded row carries no
  `default` field, so an older reader's rows are unchanged.
* The control command `peers.inspect` carries `default: true` on an outgoing or
  incoming row that is a default, and an outgoing row's `wake` for a default link
  is the policy's. `loomd peer inspect` prints the daemon's reply, so it shows the
  same mark.
* The peer roster rows (`peer.roster`, `peer_roster`) gain `running`, a boolean:
  whether the session is resident now.
* New reserved fact `client/peers/denial/<digest>`, described above. No other
  fact or the catalogue schema changes, and a daemon that predates the change
  ignores the cell: rollback loses the denial and nothing else.
* `Allow`, `Revoke`, `Link` and `Unlink` write through the writer's guarded
  multi-edit (`api.edit_reserved_facts`) so a grant and its denial change
  together.
* The registry gains one read, `manager.unshared_sessions`.
* `peers.unlink_session` is the one function the control command and the page
  call to remove a link by the recipient's identity.

### The page

The Session pane's seventh and last child, at `component.peers_path`, is the
owner's "Peer links" section (`view/peer_links`). It lists the focused strand's
links as `this › target` rows for links the strand sends along and `source ›
this` rows for links that reach it. A link that may wake its target carries
`may wake`, and a default link carries `default`. The page reads when it opens,
when focus moves to another strand, after its own change, and at most every 15
seconds otherwise.

*Link.* The owner opens the control, chooses a session from the page's own
sidebar list (only running sessions other than this one are offered), chooses
what the link allows (it starts as the narrowest, busy-only), optionally turns on
**Both directions**, types the strand in the other session (it starts as `main`)
and submits. The request is `Link(strand, session, target, wake, reverse)`; the
daemon grants `strand → session/target` and, for `BothWays`, `target → strand` with
the same permission, as two `peers.link` calls. If the second fails the answer
says the change was made on this side only and repeating the request is safe.

*Unlink.* Each row has Unlink. For a pair that links both ways the question
offers either direction or both; for one link it asks to confirm. The request is
`Unlink(strand, edges)`; each edge is removed with the same function the control
command uses. Removing an incoming link removes the link from the other session,
which must be running.

*Authority.* The page asks by value (`Transport.peers`, an `Option` that is `Some`
only on an owner's operating page) and a page never holds owner authority. The
daemon runs each request in a task (`ui_socket.peer_links_task`) after it checks,
afresh, that the page is still open, that its ceiling is operator, and that its
credential still authenticates as the owner (`peer_links_for`). The page's own
session comes from the attachment and never from a frame. The socket admits an
event at or beneath `peers_path` only for an owner's page (`owner_accepts`), so a
member's browser cannot reach it by forging a path, and `ui_peers` judges every
strand and session again. Choosing a session takes its name from the page's own
list, and an Unlink question opens only for a row the board holds.

*Rendering.* Every session name, identity and strand is a text node. None is an
attribute, a class, a key or a handler's message. A refusal is one of seven fixed
sentences (`peer_links.reason_words`); the daemon's own text never reaches the
page. No left-edge bars and no shadows: questions are a tinted block with a
hairline border. The browser's Back works, since nothing navigates.

## What it costs

The default is a grant the owner never made for each pair. An owner who sets
`same_owner` accepts that any model in any eligible session can write into any
other eligible session's prompt, and with `may_wake` can start its `main`. The
setting is off by default and the daemon's help and the example file say so. A
prompt injected into one session can now ask another to act, so the owner's
approvals in each session are the remaining defence, as they are for an explicit
link.

Eligibility is read at each admission and listing, so each costs one registry call
and a membership read per resident session, bounded by the daemon's capacity. A
registry that is slow for five seconds refuses default links for that call.

A strand with more than 64 eligible peers lists the first 64 and cannot address the
rest. An owner of that many sessions turns the default off or links explicitly.

The default's denial is two reserved facts per unlinked pair, which grow with
unlinking and not with sessions. A denial survives the setting being turned off
and on, so a pair the owner unlinked stays unlinked until the owner grants it.

A session that has a member is outside the default, so the people who most want
their sessions to talk, a team around one session, get nothing from this setting.
They link explicitly, which the page makes one press.

The page lists links for the focused strand only, reads over several session
calls, and refreshes on a 15 second cadence, so a link changed from a terminal
appears within that time. A member or observer sees nothing, which hides the
section from the people who might have asked what a link is.
