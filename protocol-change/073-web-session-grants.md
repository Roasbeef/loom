# protocol-change/073: allowing for the session from the page, and forgetting what it kept

**Status**: ACCEPTED 2026-10-06 · **Affects**: the session wire (two commands and
one snapshot), the reserved remembered-permissions fact
(`client/permission_grants`, `client/action_grants/<digest>`), the runtime's
reserved-fact API, the web view's operator page · **Raised by**: owner ruling of
2026-10-06, which lifts the exclusion in the operator addendum of
[051](051-web-view-route.md) · **Implemented**: `client/permissions`,
`client/gateway`, `client/protocol`, `runtime/api`, `session_view/remembered`,
`web_view/remembered`, `web_view/view/remembered`, `client/daemon/ui_socket`

## Problem

The operator page of 051 offers *allow once* and *deny*. *Allow for this
session*, which the terminal has had since [041](041-session-approval-dialog.md),
was left out on purpose: a remembered grant outlives the page that gave it, so a
page opened from a stolen cookie could leave authority behind that lasts after
the page closes and after the cookie is revoked. Two things followed. A person
who works on the web has to answer the same prompt every time the agent needs
the same directory or the network, which is the friction 041 removed for the
terminal. And the exclusion only moved the risk: nothing on the terminal or the
web could say what the session had already remembered, who allowed it, or take
it back. The remembered grants live in a session fact, so signing a browser out
(home "Sign out", Admin "Revoke sign-in") ends the cookie and leaves every grant
that browser made in force.

## Considered

**Offer it only on the fresh home's pages.** The stolen-cookie risk is real, and
a page opened from a `loom ui` exchange is the strongest evidence that the
person is at the keyboard. A bookmarked page, resumed from a cookie, would offer
allow once and deny only. Not taken. The owner's ruling is that every page of the
owner's may offer it, bookmarked ones included. The bookmarked page can already
allow once and run a command the owner never typed, and the thing it adds is a
grant that lasts, which Forget and the provenance below bound after the fact.
Restricting by origin would also give two answers to "may this page approve for
the session" that differ for the same principal and the same session, and a
person with a bookmarked tab would be sent to the terminal for what the terminal
does in one keystroke.

**Keep the exclusion and add only the list.** The list and Forget stand on
their own: they are needed for the terminal's grants too. But the friction is
the other half of the problem, and a list with no web path to create entries
would never be exercised by the people who read it.

**Offer it to members too.** A member operator may allow once and deny, and a
member who could also remember would add authority to the session that the
owner did not choose, would see the owner's provenance (principals and
credential fingerprints), and could forget the owner's grants. Not taken. The
owner's ruling is that remembering, the list and Forget are the owner's alone,
and a member keeps allow once and deny as before.

**Make a remembered grant end with the sign-in that made it.** It sounds like
the fix for the stolen cookie, and it is wrong for the people it would affect. A
grant is the session's authority, not the browser's: the terminal's grants would
need an owner that does not exist, a browser that signs out for an ordinary
reason would silently revoke what the work depends on, and the daemon would
need a second lifetime on every grant. Not taken. The grant keeps its lifetime
and the person is shown where it came from.

**Show the grants only in the terminal.** The terminal lists nothing today
either, and a person on the web has no terminal open. Not taken.

**Store provenance in a separate fact.** A second cell the approval transaction
must write beside the first, with a second sequence to guard and a state where
the grants exist and the record of who made them does not. Not taken. The
provenance is written in the same cell as the union it describes, in the same
transaction, so no state has one without the other.

## Decision

**Accepted.**

*Owner only.* `approve` with `scope: "session"`, `permissions` and
`permission_forget` are refused with `forbidden` to any authenticated attachment
whose principal is not the daemon's owner (`gateway.owner_only`,
`member_attached`), whatever role it holds, in addition to the observer refusal.
That is the gate. An attachment with no principal (the in-VM host fixture) is the
trusted sink and is not refused. The page derives owner-ness at open from the
authenticated principal (`Standing.reader`, the same principal kind the gateway
checks) and draws the session button, the list and Forget only for the owner;
`Transport.logins` is handed to the owner's page alone, and the page asks again
at the click (`component.may_remember`). A member's page draws allow once and
deny, no list, and never reads one.

*The page.* `component.Answer` gains `AllowForSession`. The card offers *Allow
bash for this session* after *Allow bash once*, only where `approval.rememberable`
holds for the displayed record, which is the terminal's rule. Deny stays first,
nothing takes focus, and cards stay keyed by sequence. The click goes through
`component.decide`, which finds the drawn record by identity and sequence
(`operator.drawn`), then asks `approval.rememberable` again inside
`operator.decision`; it echoes the displayed sequence, action digest and grants
exactly as allow once does, with `scope: "session"`, and the gateway refuses a
mismatch. The observer's socket admits no new path: the gateway treats
`permissions` and `permission_forget` as mutations, so an observer attachment is
refused both, and the observer's page draws neither.

*Provenance.* The general fact keeps `grants`, the union dispatch reads and
every earlier daemon wrote, and gains `version: 2` and a `remembered` array.
Each row is `{grant, provenance}` where a provenance is
`{by, via, at_ms}`: `by` is the authenticated principal as the gateway holds it
(identity and display name at the time), `via` is `{kind: "login"|"device"|"none",
fingerprint}` and `at_ms` is the commit time. The kind comes from the credential
digest's kind (a browser login or a bearer), the fingerprint is its first
sixteen digits, and neither is read from anything a client sent. A permission
approved again takes the new approval's provenance, since the latest approver
has just affirmed it. The exact-action consent cells gain `version`, `tool`,
`strand`, a preview of at most 200 characters and the same `provenance`, so the
list can say which command a consent covers. The decoder is total:
`grants` is the only authority, a row that is absent, malformed, or names a
grant the fact does not hold reads as `Unknown`, and a fact with no `version` is
a version 1 fact whose permissions are all `Unknown` and all still honoured.
Rollback to a daemon that predates this change reads the same cell, because the
fields it reads have not moved.

*Forgetting.* `permission_forget` carries a target and the sequence the operator
saw. A target is one grant (in the protocol's grant vocabulary, as the list
carried it), one exact-action consent (by the cell's name, which must be
lower-case hexadecimal so a wire value cannot name another reserved cell), or
everything. The edit is one transaction through the session's writer
(`api.edit_reserved_facts`): the general fact is rewritten, never deleted, so
its sequence keeps guarding the next approval, and consent cells are removed,
each guarded by the sequence it was read at. A cell that moved, or a target that
is already gone, loses the whole transaction as `conflict` and writes nothing
(forgetting everything when nothing is remembered is not a target that is gone
and succeeds with the empty list);
the server never retries a stale answer, as 041 requires. The reply is the
fresh `permissions` snapshot, so one reply redraws the list. The gateway checks
what it checks for an approval: a subscribed attachment, not an observer, and
not while the session is draining.

*Listing.* `permissions` answers `{seq, grants, actions}` with each row's
provenance, bounded at 100 of each. It is refused to an observer, because the
list names principals and credentials.

*The list.* The Session pane gains a sixth child, `Remembered permissions`, at
`component.remembered_path`. Each row names what it permits (`Read /repo`,
`Write /repo/out`, `Network access`, or the tool, strand and command a consent
covers), who allowed it, from which browser sign-in or terminal, and when in UTC.
Each has a Forget button that asks its question in place, and *Forget all* sits
under the list. The question is the request as the list looked when its button
was drawn, with the sequence that list carried, and the second press sends
exactly that. Every path, command, tool, strand and name is drawn as a text node.
The page reads the list when it opens, after it answers an approval for the
session, after a forget that lost its guard, and every 30 seconds.

*Revoked sign-ins.* Revoking a browser ends its cookie, and the grants it made
survive; that is the cost of keeping a grant's lifetime the session's. So the
list marks a permission whose sign-in has since ended and says to forget it if
unrecognised. The daemon, not the page, judges: `Transport.logins` asks the
registry for the principal's active sign-ins, which the owner may read for any
principal. A login is marked ended only when the
registry answered for that principal and the whole list, which must fit one page,
did not hold it. Anything the daemon could not judge draws no note.

*The terminal.* The terminal does not list or forget in this change. Its
approvals already record provenance, and the wire carries the commands, so a
`/permissions` command is a later addition to `session_view` with no protocol
change.

## What it costs

A permission can still be left behind by a stolen cookie. The page now offers the
choice on every page that can approve, so the first line of defence moves from
"the page cannot do it" to "the owner can see it and undo it": the grant is
listed with the sign-in that made it, a revoked sign-in is called out, and one
press forgets it. A person who never opens the Session pane does not see the
note. Revocation still does not undo grants, by design, and a browser signed out
after it granted something leaves a note that depends on the registry answering.

The reserved fact grows by a row per remembered permission, bounded in practice
by the handful a session accumulates, and the reply by 100 of each kind. The
approval transaction does the same two guarded writes as before. A forget is one
more guarded transaction. The gateway gains two commands and the session wire a
snapshot, with no change to a command that exists, so the protocol version stays
2 and an older client ignores the snapshot it never asks for.

Two limits are deliberate. A forget of everything does not stop a call that is
already running with the authority it snapshotted, as 041 says of every
remembered grant: dispatch snapshots the fact once, and running executions keep
their own authority. And an exact-action consent made before provenance was
recorded lists with no tool, strand or command text, because it did not store
any; it can be forgotten by its identity and nothing else.
