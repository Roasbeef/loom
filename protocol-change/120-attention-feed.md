# protocol-change/120: the attention feed, the per-record read and the answer command

**Status**: PROPOSED 2026-11-18. The owner accepted autonomous protocol
changes for the attention inbox build on 2026-11-17. This is phase 1b of that
build.
**Affects**: four new v2 control commands (`sessions.attention`,
`attention.read`, `attention.answer`, `attention.close_find`); three new
commands on the session's peer endpoint (`AttentionFeed`, `AttentionRead`,
`AttentionSettle`); one new field on the home's thread send (the strand) and
one new refusal word; the new refusal code `not_resident`. No existing command,
frame, event, record or `loom.toml` key changes. No catalogue change: the
durable summary is [122](122-attention-catalogue-summary.md).
**Raised by**: phase 1 of the attention inbox
(`docs/design-notes/attention-inbox/README.md`, sections 4 and 5, and
`ranking.md`, section 7).
**Builds on**: [050](050-session-activity.md) (the read this one sits beside:
bounds, deadline, per-member filtering), [118](118-inbox-thread-send.md) (a
person's message to a session from Home) and
[119](119-attention-records.md) (the ask and find records this document reads
and settles).

## Problem

[119](119-attention-records.md) lets an agent record an ask or a find. It
defines no way to list them, to read one in full, or to answer one. Three
things are missing.

1. A list of what needs a person across the sessions a page holds, cheap
   enough to read every refresh. `sessions.activity` carries a state word and
   counts. It cannot name an ask.
2. A read of one record's full content, so the page can draw the questions and
   options, and so the answer can name the version of the record it was given.
3. A command that turns a person's answer into the prompt [119](119-attention-records.md)
   specifies, and settles the record. [118](118-inbox-thread-send.md) addresses
   only `main`, so an ask from a sub-agent cannot be answered.

This document defines the three reads and commands, the strand addressing that
[118](118-inbox-thread-send.md) lacks, and what they cost. It does not define a
push, and it does not let any command decide an approval.

## What was considered

### Decision content in the feed

The feed could carry each ask's questions and options, so a page needs no
second read. Rejected. Twenty-four sessions with up to 32 asks each would not
fit the 60,000-byte reply, and the content of a record a person is about to act
on should be read at the moment of the act, with the revision it was read at.
The feed carries identities and short heads. Content comes from
`attention.read`.

### Answering through plain thread send

The page could send the answer as free text through [118](118-inbox-thread-send.md)
and leave the record `open`. Rejected. Nothing would validate the answer
against the record, a stale answer to a changed record would be delivered, and
the record would never settle, so the same ask would stay in the feed after it
was answered.

### A command that asks the agent to fix a find

A command such as `attention.fix` could prompt the strand to fix a find.
Rejected. The page already can: it composes a thread-send prompt that quotes
the find's identifier, and the person sees and may edit the text before
sending. A command would add a second route to the same prompt and a place to
hide the words.

### Approvals in the feed

The feed could list pending approvals with their previews. Rejected, as
`ranking.md` section 7 rules: an approval is decided only from its own
session's page, from the card that page draws, so no queue row or feed head
carries a deciding control or the action text. `sessions.activity` already
reports the count of pending approvals (`approvals`), and that count is all the
feed repeats.

### An approval's raise time from its scope

`waiting_since` could use the mint time of the operation named in the
escalation's `scope` (`runtime/escalation.gleam`, `CallScope`), which is
recoverable with `ids.op_id_timestamp_ms`. Rejected. That is when the operation
started, and an operation can run for hours before it raises. Printing it as
the approval's age would print an age that is not the approval's.

### A pushed event

The feed could notify a client when a record changes, as `ProposalsChanged`
does ([086](086-memory-proposals.md)). Deferred, and not decided here. The
page polls. A doorbell is later work, and nothing in this document prevents
one.

## Decision

### The commands

All four are v2 control commands. Each takes the current daemon epoch and is
refused with `stale_epoch` when it is old, as `sessions.activity` is.

| Command | Reads or writes | Who is answered |
|---|---|---|
| `sessions.attention` | reads | the owner for every identity; a member for the identities it holds, at any role |
| `attention.read` | reads | the owner; a member that holds the session, at any role |
| `attention.answer` | writes | the owner; a member that holds the session as Operator |
| `attention.close_find` | writes | the owner; a member that holds the session as Operator |

Authority is read from the registry at the moment of each command with
`manager.session_authority`, which answers `Owner` or `Participant(role)` for
the credential's digest. It is never taken from the request, from a page's
list or from an earlier read, as the addendum to [050](050-session-activity.md)
requires. An observer member can read and can never write.

The home page reaches the same functions in process, as it reaches
`server.home_activity`, and as its principal. Its thread-send capability
([118](118-inbox-thread-send.md), "Who may send") gates its answer and close
controls: only the owner at an Operator ceiling is given them, and they are
derived again when the press is processed. A session page reaches them with the
authority of its own binding, capped at Operator. A member's home and an
observer's home draw no answer control.

A write is refused with `not_resident` when the session is saved, opening,
stopping, or has no gateway the daemon can reach. A read of a record is refused
the same way, because reading a record needs the session's store open, and
[050](050-session-activity.md) rules that the daemon never opens a saved
session for a read. The saved-session counts come from the durable summary in
[122](122-attention-catalogue-summary.md).

### The feed: `sessions.attention`

The request names between 1 and 24 distinct canonical session identities and
the current epoch:

```json
{"v":2,"id":1,"cmd":"sessions.attention","body":{"sessions":["<canonical-id>"],"epoch":"<current-epoch>"}}
```

Validation, authorization order, the registry resolution, the omission of a
session that is not running, the 2,000 ms deadline, the concurrent calls from
the control socket's process and the service during a drain are those of
[050](050-session-activity.md) and its member addendum, unchanged. A resident
that errors, crashes or misses the deadline yields a row with `state` `unknown`
and no other field. An identity a member does not hold is omitted exactly as an
identity that is not running is, so the reply never distinguishes them.

Each resident is asked through a new read-only `AttentionFeed` command on its
peer endpoint, answered by its Agency actor beside `Overview`
(`client/peer_mail.gleam`, `Command`). The reply body is
`{"attention":[row, ...]}`, with rows in request order. A row for a resident
that answered:

```json
{"session_id":"<canonical-id>","state":"ok","waiting_since":1763400000000,
 "asks":{"count":2,"items":[{"id":"ask-3f9c01a2b4","strand":"main","created_at":1763400000000,"head":"Which branch should the fix target?","questions":2}]},
 "finds":{"count":5,"items":[{"id":"find-77d0a1c9e2","strand":"sub:main/audit-1a2b","kind":"bug","created_at":1763401000000,"head":"The retry loop never backs off.","path":"src/retry.gleam","line":88}]},
 "stuck":{"count":1,"items":[{"strand":"sub:main/audit-1a2b","failed_at":1763402000000}]}}
```

| Field | Meaning |
|---|---|
| `session_id` | The canonical identity, as in [050](050-session-activity.md). |
| `state` | `ok` or `unknown`. A receiver MUST treat a value it does not recognize as `unknown`. |
| `waiting_since` | Unix milliseconds: the smallest `created_at` over the session's open asks routed to the owner. Absent when there is none. |
| `asks.count` | The number of open asks routed to the owner, all of them, whether or not they are in `items`. |
| `asks.items[]` | `id`, `strand` (the asking strand), `created_at`, `head`, `questions` (the number of questions). |
| `finds.count` | The number of open finds, all of them. |
| `finds.items[]` | `id`, `strand`, `kind` (`risk`, `idea`, `bug` or `question`), `created_at`, `head`, and `path` and `line` when the find has them. |
| `stuck.count` | The number of stuck strands, all of them. |
| `stuck.items[]` | `strand` and `failed_at`. |

`head` is the first question's `prompt` for an ask and the `text` for a find,
with whitespace collapsed and cut to at most 120 bytes on a grapheme boundary.
A row carries no other question, no option, no `why`, no answer and no
closure. An ask routed to a strand rather than the owner is not in the feed
and is not in `asks.count`: it is an agent's question to another agent, and no
person answers it here. `strand` is cut to 96 bytes, as the glance's is in
[050](050-session-activity.md). A command never takes a strand from a feed row
except thread send, which the gateway checks (see "Strand addressing"), so a cut
name cannot misdirect a write. `path` is cut to 160 bytes; a path longer than
that is omitted together with its `line`.

A strand is **stuck** when all of these hold:

- it is not `main` and not the advisor's strand (`client/advisor.gleam`,
  `primary` and `strand`);
- it has no current operation in its strand state; and
- its latest terminal result (`session.last_result`, the
  `StrandLastResult` register) is a `RunLastResult` whose outcome is
  `RunFailed`.

This is the rule `standing_from` applies to `main` (`client/peer_mail.gleam`),
applied to every other strand. "No retry since" holds by construction: the
register is overwritten by the next terminal result on that strand, so a run
that began, or a later compaction or navigation, removes the strand from the
set. The feed does not repeat `main`: a failed main run is already
`needs_you` in [050](050-session-activity.md).

`failed_at` is the mint time of the leaf entry in the failed result
(`ids.entry_id_timestamp_ms` over `RunLastResult.leaf`). `LastResult` carries
no clock reading of its own, so this is the time of the strand's last entry
before the run ended, and the run failed at or after it. The field is absent
when the result has no leaf. A page that prints it MUST NOT word it as the
time of the failure.

`waiting_since` is the age of an ask and says nothing of approvals. The
escalation record carries no raise time (`runtime/escalation.gleam`,
`Escalation`: it holds `asked`, a count, and no time), so a session whose only
pending item is an approval has no `waiting_since`, and no page prints an age
for an approval. Adding a raised time to the record is a separate change to the
record and is not made here.

The three lists are read with one listing of each reserved prefix and one
listing of the last-result register, so a row costs a fixed number of store
calls. `client/attention.gleam` already reads the ask and find prefixes
(`asks`, `finds`); the feed adds no new reads of the records.

#### Bounds

The recipient bounds its row to 2,300 encoded bytes and the server checks each
complete row again against 2,400 bytes, replacing an oversized row with an
`unknown` row, as [050](050-session-activity.md) does. 24 rows of at most 2,401
bytes fit the 60,000-byte reply, and the server asserts that budget on the
encoded reply and refuses with `metadata_too_large` if it is exceeded.

When a row is over 2,300 bytes the recipient removes items until it fits:
`finds.items` first, then `stuck.items`, then `asks.items`, and within a list
the oldest item first (the smallest `created_at` or `failed_at`). A count is
never reduced, so a row whose `items` is shorter than its `count` says how many
were left out. The fixed part of a row, with every list empty, is under 400
bytes, so every row can be made to fit.

Each reply is one fresh observation. The daemon does not cache the feed, poll
for it or push it.

### The per-record read: `attention.read`

```json
{"v":2,"id":2,"cmd":"attention.read","body":{"session":"<canonical-id>","id":"ask-3f9c01a2b4","epoch":"<current-epoch>"}}
```

The reply carries the full record and its revision, read in one call to the
session's Agency actor (`AttentionRead`). The **revision** is the sequence
number of the record's register cell at the read (`api.FactCell.seq`), an
integer. A later write to the cell, including the settling write, gives it a
higher one. The identity is checked against `core/attention.is_ask_id` and
`is_find_id`; anything else is `bad_request`. An identity with no decodable
record is `not_found`, and the reply for a record that a prune removed is the
same.

An ask:

| Field | Meaning |
|---|---|
| `kind` | `ask`. |
| `id`, `revision`, `status` | The identifier, the revision, and `open` or `answered`. |
| `strand`, `routing`, `created_at` | The asking strand, `owner` or a strand name, and the creation time. |
| `anchor` | `{operation, step_id, source_index}`, so the page can resolve a transcript position. |
| `why` | The ask's reason, or absent. |
| `questions[]` | For each: `key`, `prompt`, `kind`, and `options[]` (`label`, `note`, `recommended`), `min` and `max`, `format` where the kind has them. |
| `answer` | Present when answered: the answer object in the form of "The answer" below, with `by` and `at`. |
| `may_answer` | `true` only when the caller may answer: the owner, or an Operator, and `status` is `open` and `routing` is `owner`. |

A find carries `kind` `find`, `id`, `revision`, `status` (`open` or `closed`),
`strand`, `created_at`, `anchor`, `find_kind`, `text`, `path`, `line`, the
closure (`outcome`, `at`, `by`) when closed, and `may_close`, true only when
the caller may close it and it is open.

The strings are the record's own, which [119](119-attention-records.md)
bounds (the largest ask is under 10,000 bytes before an answer, and an answer
holds at most four values of at most 4,000 bytes). The reply is checked against
the 60,000-byte frame and refused with `metadata_too_large` if it is over, which
the record bounds make unreachable. A question's text and an option's label are
model-written and are drawn as text only, never as markup, a path or an
attribute, as [051](051-web-view-route.md) requires of session-derived text.

An observer receives the record with `may_answer` and `may_close` false, and the
page draws no control.

### The answer: `attention.answer`

```json
{"v":2,"id":3,"cmd":"attention.answer","body":{"session":"<canonical-id>","ask":"ask-3f9c01a2b4","revision":41,
 "answer":{"answers":{"q1":true,"q2":"Retry","q3":["a.gleam"],"q4":null},"other":{"q4":"Do it in a branch."}},"epoch":"<current-epoch>"}}
```

`answer` has the shape of the object in [119](119-attention-records.md), "The
answer", without the `ask` key, which the daemon adds. This document does not
change that object.

The daemon performs these steps in order, and stops at the first refusal.

1. Authority. The caller holds the session as the owner or an Operator
   (`forbidden` otherwise, so an observer is refused here), and the session is
   resident (`not_resident`).
2. Read the record and its revision through `AttentionRead`. No record is
   `not_found`. A record that is not an ask, or whose routing is a strand, is
   `bad_request`.
3. State. An ask that is `answered` is refused with `conflict`.
4. Revision. A `revision` that is not the one just read is refused with
   `conflict`. The page then reads the record again and shows the person what
   changed.
5. Validation against the stored record. Every rule below is checked, and a
   failure is `bad_request` carrying the first failing key, with nothing sent.
6. Delivery. One prompt is delivered to the asking strand (see "Strand
   addressing") under a binding whose principal is the caller. It is a
   `Prompt`, never a `Steer`: an ask ends its run, so the strand is idle, and a
   busy strand holds the prompt behind its turn. The gateway's answer is
   `admitted` or `queued`, or a refusal that is returned unchanged in kind
   (`QueueFull`, `NotAccepted`, `Unanswered` of [118](118-inbox-thread-send.md)).
   Any refusal leaves the ask `open`.
7. Settle. The record is rewritten as `answered` with the answer, the answerer
   and `settled_at`, by `AttentionSettle`, guarded by the revision (the write
   expects the cell's sequence number to be unchanged). The settling commit also
   removes the settled records that `core/attention.retired` names, as the
   insertion in `client/attention.gleam` does.

The reply is `{"ask":"<id>","delivery":"admitted"|"queued","revision":<new>}`.

The order of steps 6 and 7 is fixed. If the prompt were recorded as answered
first and then refused, the ask would leave the feed while the agent never saw
the answer. Delivering first gives the other failure, which is the weaker one: a
prompt is delivered and the record stays `open`.

That failure has three causes. The gateway answered `Unanswered`, so the prompt
may have arrived. The daemon stopped between steps 6 and 7. Or the settle write
lost to another write in between, in which case the reply is the error
`conflict` with the words "delivered; the record changed", and the record is
left as the other write made it. In each case the prompt in the strand's
transcript is the authoritative copy, and a second answer to a record that
is still `open` is accepted, the later one standing, as
[119](119-attention-records.md) states.

#### Validation

| Rule | Check |
|---|---|
| keys | `answers` has exactly one key for each question of the ask, `q1` to `qN`, and no other. `other` has a key only for a question answered by Other, and that key is also in `answers`. |
| `confirm` | the value is `true` or `false`. |
| `choice` | the value is a string equal to one option's `label`. |
| `multiple` | the value is a list of distinct option labels, with `min` at most its length and its length at most `max`. |
| `checklist` | the value is a list of distinct option labels, possibly empty. |
| `fill` | the value is a string that satisfies the question's `format` (below). |
| Other | the value is `null`, `other` holds the person's text, and the text is not empty after trimming and is at most 1,000 bytes. |
| whole prompt | the prompt text built in step 6 is at most `composer.prompt_limit`, 16,384 bytes. |

A `fill` value is at most 4,000 bytes for `long_text` and at most 1,000 bytes
for every other format, and is not empty after trimming. `text` and `long_text`
accept any UTF-8 text without NUL. `path` accepts a single line of at most
1,024 bytes and no NUL; the daemon does not check it against any filesystem.
`number` accepts the decimal form `-?[0-9]+(\.[0-9]+)?` and is carried as the
string typed, as [119](119-attention-records.md) says. `url` accepts an absolute
`http` or `https` URL with no whitespace. No format names a secret, and the
page draws no password field.

#### The prompt

The text of the delivered prompt is fixed words naming the ask, then the fenced
object:

````text
Answer to ask-3f9c01a2b4:

```json
{"ask":"ask-3f9c01a2b4","answers":{"q1":true,"q2":"Retry","q3":["a.gleam"],"q4":null},"other":{"q4":"Do it in a branch."}}
```
````

The words never include the ask's prompt, its `why` or any text a session wrote.
The object is encoded with the daemon's JSON encoder, so the person's text is a
string inside it and cannot close the fence or name another object. The message
is the person's own prompt, attributed in the transcript as one typed on the
session's page ([118](118-inbox-thread-send.md), "What is sent").

### Closing a find: `attention.close_find`

```json
{"v":2,"id":4,"cmd":"attention.close_find","body":{"session":"<canonical-id>","find":"find-77d0a1c9e2","revision":52,"outcome":"filed","epoch":"<current-epoch>"}}
```

`outcome` is `dismissed`, `fixed` or `filed`; any other value is `bad_request`.
`fixed` and `filed` are the person's statement that the work was done or the
issue was filed. Loom does not check either, files nothing itself and creates no
issue. The command delivers nothing to any strand.

The steps are those of `attention.answer` without validation or delivery:
authority and residency, read, state (a find that is already `closed` is
`conflict`), revision (`conflict` when stale), then `AttentionSettle`, which
writes the closure with the closer and `settled_at` guarded by the revision and
removes retired records as above. The reply is `{"find":"<id>","revision":<new>}`.

"Ask the agent to fix it" is not a command. The page composes a thread-send
prompt whose text quotes the find's identifier, shows it to the person, and
sends it only when the person presses Send, through
[118](118-inbox-thread-send.md). That prompt does not close the find.

### Strand addressing

[118](118-inbox-thread-send.md) sends to `main` only, and its "What is sent"
table says other strands are not addressable in phase 0. This document adds a
`strand` to the home's thread send. `message_to` and `send_message` in
`client/daemon/ui_socket.gleam` take it in place of the literal `"main"` and put
it in the `Prompt` or `Steer` the gateway receives. A page that names no strand
sends to `main`, so the first-message path is unchanged.

The gateway already refuses a prompt, steer or follow-up for a strand that does
not exist in the session: `known_strand` replies with the error code
`unknown_strand` (`client/gateway.gleam`, `strand_exists` and `known_strand`).
`answer_of` in `ui_socket.gleam` maps that code to a new refusal,
`thread_send.UnknownStrand`, drawn as "Not sent: that strand no longer exists".
Without it the refusal would be `NotAccepted` and would read as the session
declining.

The sender's authority is checked as for `main`: the principal holds the
session, the session is resident, and the binding's authority is the held
authority capped at Operator. The strand adds no check of its own beyond the
gateway's. In particular a stuck delegate's "Retry the last step." is a
`Prompt` with the strand taken from its row in `stuck.items`, and a
cut or stale name is refused as above.

Strand addressing also lets a page prompt a strand that is not an agent's
delegate, such as the advisor's. The gateway does not restrict it. This document
adds no restriction and states the residual risk in the threat model.

### What stays outside

- **Approvals.** No command here lists, reads or previews an approval, and none carries a decision.
  An approval is decided from the dock of its own session's page, echoing the
  action text, the grants and the seq ([051](051-web-view-route.md)). The feed's
  only mention of one is the existing `approvals` count in
  `sessions.activity`.
- **Push.** The page polls `sessions.attention` with `sessions.activity`: Home's
  list refresh (`home.refresh_ms`, 30 seconds) and an immediate read after a
  send, an answer or a close. A page whose refresh has not run shows what it last
  read, and says when it read it.

### Admission by page

The answer and close controls are submits and clicks beneath the home's table
region and follow the admission rules of [118](118-inbox-thread-send.md): the
owner's operating home admits them, a member's home and an observer's home admit
none, and each is derived again when it is processed. This document adds no new
admitted path outside that region.

## Differences from 119

[119](119-attention-records.md) says that "A member and an observer can be shown
asks and finds by the feed and can answer nothing", and that answering is
admitted to the principals [118](118-inbox-thread-send.md) admits, which is the
owner at the Operator ceiling. This document widens the first half only: a
member that holds a session as Operator may answer and close from that session's
page, with the authority of its own binding. The feed and the home remain the
owner's for writing. An observer still answers nothing.

[119](119-attention-records.md) leaves an ask routed to a strand without a
defined answerer. This document defines it: no person answers it through these
commands, and it is not in the feed.

## Rulings that hold

These restate `ranking.md` section 7 as they bind this document.

- **Every count says what it read.** A row's `count` is the number of records it
  read, and `items` may be shorter. A session with no row was not read, and a
  `state` `unknown` row was not read either. A page MUST word a headline with
  what it read ("in 6 running sessions") and MUST NOT print "Nothing needs you"
  without stating how many listed sessions were not read. The saved-session
  count is [122](122-attention-catalogue-summary.md).
- **Ages.** A page prints an age only from `created_at` or `waiting_since`, and
  prints none for an approval. `failed_at` is a lower bound and is worded as one.
- **Text the page may not write.** A head, a question, a label and a find's text
  are drawn as escaped text and labelled as the agent's. The page does not claim
  a find is relevant or an ask unanswered beyond the record's `status`.
- **Identities and heads only.** The feed never carries a question, an option, a
  `why`, an answer or an approval's content.

## Threat model

Everything in [051](051-web-view-route.md) and [118](118-inbox-thread-send.md)
stands.

**What a compromised owner Home page can do.** Read the feed and any record of a
resident session the owner holds. Answer an open ask with any value that
validates against the stored record, which delivers one prompt to the asking
strand as the owner. Close a find. Send a `Prompt` or `Steer` to any strand of a
resident session, as [118](118-inbox-thread-send.md) allows for `main`, and now
for any strand the gateway knows. The answer prompt's text is fixed words and an
encoded object, so a page cannot use the command to send free text of its own
beyond the answer's own fields (up to 1,000 or 4,000 bytes each).

**What it cannot do.** Decide an approval. Read a saved session's records. Answer
as a principal other than its own. Settle a record whose revision has moved
since the page read it. Make a model's text act: every field a session wrote
is text. Send a strand's name that the gateway does not know.

**A member.** A member holding a session as Operator can answer its asks and close
its finds; a member holding it as an observer reads only; a member sees the
feed rows of the sessions it holds and nothing else.

**Residual risk.** An answer is an at-least-once prompt, and an ambiguous
delivery can leave an answered ask `open` until read again. A compromised owner
page can prompt every strand of every resident session the owner holds. The
gateway's bounds of four prompts and four steers for each strand limit how much
a page can queue ([022](022-human-input-priority.md)).

## What it costs

- One read per page refresh, for at most 24 sessions: up to 24 registry
  lookups, up to 24 concurrent Agency calls, and the registry's membership check
  for a member. Each Agency call reads the strand-state listing, the last-result
  listing, and the two reserved prefixes (at most 232 and 328 cells,
  [119](119-attention-records.md), "What it costs"). Those reads run inside the
  Agency actor and delay its other peer commands by the time they take. The
  reserved records already exist and no new store write is added by a read.
- `attention.read` is one Agency call and one register read.
- `attention.answer` and `attention.close_find` are one read, one gateway
  delivery for an answer, and one guarded write.
- The terminal gains no command. The web page gains the four controls above, a
  total decoder for the feed row and the record, and the `UnknownStrand` words.
- A feed row can be shorter than its count. A long-waiting find or ask can be left
  out of `items` for a session with many open records, and is still counted. The
  shedding order keeps asks last, but an oldest ask can be the one removed when
  a session has more asks than a row holds. The session's own page lists them
  all.
- Phase 1b implements the feed before the durable summary, so until
  [122](122-attention-catalogue-summary.md) lands a page counts resident
  sessions only and says so.

## Verification

Each item is a test over the real function and the real store.

- A new `client/test/client/peer_mail_attention_test`: `AttentionFeed` over a session with open and answered asks, open and
  closed finds, a stuck strand and a strand that failed and was retried; head
  cutting on a grapheme boundary; an ask routed to a strand absent from the feed
  and its count; `waiting_since` absent for a session whose only pending item is
  an approval; the shedding order and that counts are never reduced; a row under
  2,300 bytes whatever the session holds; the leafless result giving no
  `failed_at`.
- `client/test/client/daemon_server_test`: `sessions.attention` for the owner and
  a member (held ids only, an unheld id omitted exactly as an unknown one is), the
  1 to 24 distinct canonical rule, `stale_epoch`, an `unknown` row for a resident
  that misses the deadline, the 60,000-byte assertion, and service during a
  drain.
- `attention.read`: the revision rises after a write; an observer receives
  `may_answer` false; a saved session is `not_resident`; a pruned record is
  `not_found`.
- `attention.answer`, each against a real session: every validation row and its
  first failing key; a stale revision is `conflict`; a record already answered is
  `conflict`; a gateway refusal leaves the ask `open`; a delivered prompt that
  lost the settle write answers `conflict` with the delivery words; the prompt
  text for each kind round trips through `core/attention`'s decoder and carries
  the fenced object; the prompt is attributed to the caller's principal; an ask
  of a sub-agent is delivered to its strand; an ask routed to a strand is
  `bad_request`; settlement removes retired records.
- `attention.close_find`: the three outcomes, a closed find is `conflict`, the
  closure records the closer, nothing is sent to a strand.
- `client/test/client/ui_socket_test`: thread send to a named strand; an unknown
  strand is `UnknownStrand` and not `NotAccepted`; a page that names no strand
  sends to `main`; the capability is re-derived at the press; a member's and an
  observer's home admit no answer or close control.
- `web_view/test`: the outbox words for `UnknownStrand`; the feed row and record
  decoders are total over a damaged body; no session text is used as a path, an
  attribute or markup.
- `docs/client-protocol.md` gains a section for each command, and `make
  doc-check` passes.

## Decisions for the owner

None are open. The owner accepted autonomous protocol changes for this build on
2026-11-17.
