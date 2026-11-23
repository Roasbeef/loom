# protocol-change/131: dismissing a stuck strand from the attention inbox

**Status**: ACCEPTED 2026-11-23. The owner asked for the feature ("no way to
dismiss stuff like this?") and has accepted protocol changes for the attention
inbox work.
**Affects**: one new reserved `fact.custom` prefix in the session store
(`attention/stuck/`); one new field of a stuck item in the feed row (`operation`);
one new peer command (`StuckDismiss`); one new control command
(`attention.dismiss_stuck`); one new in-process act on the owner's home and on a
session page's live rail (`dismiss_stuck`); one new button beside Retry on a
stuck strand's thread and card. No frame, event, catalogue table or `loom.toml`
key changes, and no existing command changes.
**Raised by**: the owner, looking at two stuck "pi402 bug fixes" threads on Home,
one of them a sub-agent they did not care about.
**Builds on**: [119](119-attention-records.md) (reserved `attention/` prefixes and
the harness-only writer), [120](120-attention-feed.md) (the feed's stuck items
and the addendum on them, and the door's admission of the owner and an Operator)
and [051](051-web-view-route.md) (the live rail's actions and what an observer's
socket admits).

## Problem

A strand is stuck when its last terminal result is a failed run, it has no
current operation, and it is not `main` or the advisor's strand
([120](120-attention-feed.md), "Stuck"). The feed lists it, Home lifts it as
"Needs you", and the session page pins it in the live rail. Three things clear
it: the strand runs again, a compaction, or a navigation, because each overwrites
the last-result register.

A person who has read the failure and decided to leave it has none of those. The
only control on the thread is Retry, which runs the strand again. A sub-agent
whose work the owner no longer wants therefore stays in "Needs you" and in the
count of what waits on them, indefinitely, and the owner has no way to say "I
have seen this".

Nothing in the daemon records that the owner has seen and set a failure aside,
so no read can leave it out.

## What was considered

### Stopping or closing the strand

Dismissing could stop or close the strand, so that it has no failed result to
lift. Rejected. The failure is a fact of the strand's history, and the harness
has no operation that erases a last result: only a later terminal result
replaces it. A strand that is stopped, or whose result is overwritten by a
synthetic compaction, has been changed to hide a notice about it. The owner asked
to stop being told, not to change the strand, and a parent that later waits on
the child would find it altered for a reason that had nothing to do with its
work.

### A page-local hide

Each page could keep a set of dismissed strands in its own state, or in the
browser's storage. Rejected. The feed row is a daemon read, so two pages of the
same owner, a refresh, a second device and the control socket would each show
the strand again, and the count the owner reads on Home would not drop. A hide
that holds only until the page is reloaded is the same as no feature, and the
daemon would still report the strand as one that needs a person.

### A durable acknowledgement keyed by the strand alone

The daemon could record "strand X is dismissed" and stop listing X from then on.
Rejected. A strand that was dismissed, run again by its parent and then failed
for a different reason would stay hidden, which hides exactly the failure the
owner has not seen. The acknowledgement has to name the failure it covers.

## Decision

### The record

A **dismissal** is one reserved `fact.custom` cell in the session store, as the
asks and finds of [119](119-attention-records.md) are:

| Prefix | Key | Content |
|---|---|---|
| `attention/stuck/` | `attention/stuck/<strand>` | one dismissal |

The key is the strand's own name, so a strand has at most one dismissal and a
later one replaces it. The prefix MUST be added to `api.reserved_fact_key`
(`runtime/api.gleam`, `reserved_fact_key`), so that `put_fact` refuses it and
only host code writes it, and `api.attention_stuck_fact_prefix` is the one name
of it. The record is:

```json
{"strand":"sub:main/audit-1a2b","operation":"0194f7b2-...","at":1763402500000,"by":"<principal id>"}
```

| Field | Meaning |
|---|---|
| `strand` | The strand, repeated so a scan needs no key parsing. |
| `operation` | The operation identifier of the failed run that was dismissed: `RunLastResult.operation` of the strand's last result, in canonical UUID text. This is the identity of the failure. |
| `at` | Unix milliseconds, read from the daemon's clock when the dismissal was written. |
| `by` | The principal the registry resolved for the caller, as an answer's `by` is. |

The decoder is total: a cell that is not an object with these four fields of
these types is left out of every read, as a damaged ask is.

### What it covers

A dismissal covers a strand's failure when the strand's name and the operation of
its current last result are both equal to the record's. A run that fails again is
a new operation and so a new failure: the strand is stuck again and is listed
again, with no change to the record. A strand that runs, finishes and is later
dismissed again overwrites its cell. A cell whose operation is no longer the
strand's last result covers nothing and is harmless. The prefix holds at most one
cell per strand the session has ever had, and its cells are removed with the
session. No pruning is added, because a strand's cell is a few hundred bytes and
the number of strands is already bounded by the session's agency limits
([113](113-session-agency-limits.md)).

### The feed

`client/attention_feed.stuck_strands` takes the session's dismissals and leaves
out each strand whose failure one of them covers. The row's `stuck.count` and
`stuck.items` are then the strands that are stuck and not dismissed, so the count
the owner reads on Home, in the rail and in `sessions.attention` falls by one when
a dismissal is written. The dismissals are listed once per feed read, as the
last-result register is.

Each stuck item gains one member:

| Member | Meaning |
|---|---|
| `operation` | The operation identifier of the failed run the item stands for, in canonical UUID text. A page names it when it dismisses, so the daemon can tell the failure the owner saw from one that happened since. |

`web_view/attention_feed` reads it as optional, so a row from an older daemon
decodes with none, and a page that has none for a strand offers no Dismiss.

The catalogue summary of [122](122-attention-catalogue-summary.md) counts
approvals, asks and finds and has no column for stuck strands, so a saved
session's summary is unchanged by a dismissal. Home reads a stuck strand from the
feed row of a resident session only, as before.

### The command

The control socket gains `attention.dismiss_stuck`:

```json
{"v":2,"id":5,"cmd":"attention.dismiss_stuck","body":{"session":"<canonical-id>","strand":"sub:main/audit-1a2b","operation":"0194f7b2-...","epoch":"<current-epoch>"}}
```

The decoder is total: `session` is a canonical session identity, `strand` a
string of at most 128 bytes, `operation` a string of at most 64 bytes and `epoch`
a string of at most 256 bytes. A member of the wrong type, or a missing one, is
`bad_request` before any registry call. The reply is
`{"strand":"<name>","operation":"<id>"}`. The command is a mutation, so it is
refused while the daemon drains.

The daemon walks `attention_door.dismiss_stuck`, the same function the owner's
home and a session's page call, in this order and stopping at the first refusal:

1. **Authority.** The registry is asked for the caller's authority over the
   session at the command. The owner and a member that holds the session as an
   Operator are admitted, which are the principals that may retry the strand. An
   observer is `forbidden`. A session the caller does not hold is `not_found`, as
   an unknown one is.
2. **Residency.** The session must be resident, because the strand's last result
   is read from its store. A saved session is `not_resident`.
3. **The failure.** The session's Agency reads the strand's state and last result
   in one call (`StuckDismiss`). The strand must be stuck by the rule of
   [120](120-attention-feed.md) and the operation of its failed run must be the
   one the command names. A strand with no failed result, one that is `main` or
   the advisor's, and one that does not exist are `not_found`. A strand that has
   run since, or failed again with a different operation, is `conflict`.
4. **The write.** The dismissal is written to the strand's cell, guarded by the
   cell's sequence number as it was read. A dismissal of a failure that is already
   dismissed succeeds and changes nothing. A write that lost a race is `conflict`.

Refusals, each leaving the strand as it was:

| Code | Cause |
|---|---|
| `stale_epoch` | The epoch is not the daemon's current one. |
| `bad_request` | The envelope is malformed. |
| `forbidden` | The caller holds the session as an Observer. |
| `not_found` | The session is not held by the credential, or the strand has no failed result to dismiss. |
| `not_resident` | The session is saved, opening, stopping or has no endpoint. |
| `conflict` | The strand ran, or failed again, since the caller read it, or the write lost a race. |
| `unavailable` | The store could not be read or written. |

### The web view

The owner's home and a session page's live rail each gain a `dismiss_stuck` act
beside the existing retry, and each draws one button, **Dismiss**, beside Retry on
a stuck strand's thread (Home's reading pane) and on its card (the rail).

The act's arguments are the strand and the operation the page read from its feed
row for that strand. Home's act also names the session. The page draws the button
only when the page is handed the capability and the row's item has an `operation`,
and a press while another action is out, for a strand the row no longer holds
stuck, or after the page ended, asks nothing. A success is followed by a fresh
read of the feed row, as a find's close is, so the strand leaves the list at
once.

The capability is handed on the same rule as retry's: an operator's page, which is
a member operator or the owner, and not an observer's. The daemon reads authority
again whenever the act runs, whatever the page was handed.

[051](051-web-view-route.md)'s addendum on the live rail's actions says that an
observer's socket admits exactly the paths it lists and that a retry or a close is
an operator's alone. The Dismiss button is a second button in the actions of a
stuck card, at the path `component.rail_dismiss` names, which is the place beside
Retry's (`...\t2\t1`). Neither addendum nor socket changes: an observer's page
draws no button, and its socket admits no event at that path, so a forged event
there is dropped as a retry's is. The test `ui_socket_test` pins that the observer
socket refuses the path and the operator's admits it.

## What it costs

- One reserved prefix, and the twenty-first corner of the namespace
  `api.reserved_fact_key` guards. A model cannot write it.
- One cell per strand that has been dismissed, which stays after the failure it
  covers has been replaced. It covers nothing then and is never read as covering
  anything.
- One more listing of a prefix per feed read, which is empty for a session that has
  dismissed nothing.
- One more peer command, and so one more arm in each exhaustive match over
  `peer_mail.Command` (the remote peer, the orchestrator port and two tests).
- A dismissed failure is not shown in any later read, and nothing in the inbox
  shows that it was dismissed, by whom or when. The cell holds that for a future
  reader, and this document adds none.
- A person who dismisses a strand has said they saw its failure. If the strand's
  parent is waiting on it, the parent still waits. Dismissal is not a way to
  unblock a parent, and the thread says nothing that suggests it is.
- The window between a page reading its row and pressing Dismiss is the case the
  operation covers: a failure that happened in between is `conflict`, not
  dismissed.

## Verification

- `core/test/core/attention_dismissal_test`: the record's encoding round-trips,
  the decoder is total over an object missing each field, one of the wrong type
  and a non-object, and a dismissal covers a failure of the same strand and
  operation and nothing else.
- `runtime/test/runtime/api_test`: the prefix is reserved and `put_fact` refuses
  it.
- `client/test/client/peer_mail_attention_test`: a dismissed failure is out of the
  row and its count, a new failure of the same strand is listed again, another
  strand is unaffected, a stale operation and an unknown strand are refused, a
  repeat dismissal succeeds, and an old row decodes with no `operation`.
- `client/test/client/daemon_attention_test`: the command over a real control
  socket: the owner and an Operator member dismiss, an observer is `forbidden`, a
  bystander is `not_found`, a stale epoch is refused, and the feed no longer lists
  the strand afterwards.
- `web_view/test/attention_feed_stuck_test`: the decoder reads `operation` and
  an older row decodes without it.
- `web_view/test/rail_actions_test` and `attention_threads_test`: the button is
  drawn for an acting page and absent for an observer's, at the paths
  `rail_dismiss` names, and a press asks the daemon with the strand and the
  operation the row held.
- `client/test/client/ui_socket_test`: the observer socket drops an event at the
  Dismiss path, and an operator's admits it.

## As built

The decision above was built as written, with these differences, each forced by
what the code does.

- **The classifier is the feed's, not `session_view`'s.** The strands that are
  stuck are decided by `client/attention_feed.stuck_strands`, which reads the
  last-result register. `session_view/attention` only words the records its host
  hands it from the feed row (`StuckRecord`), and it is held to no process or
  external. The rule that a dismissal covers a failure is `core/attention_dismissal.covers`,
  applied inside `stuck_strands`, so the daemon's row, the control socket and the
  rail all read one decision and `session_view` needed no change of code.
- **The cell is written by the Agency, not the door.** `attention_door.dismiss_stuck`
  sends `peer_mail.StuckDismiss` to the session's endpoint, as a settlement is sent,
  because the strand's last result is read from the session's own store in the same
  call that writes the cell. The write is `client/attention.record_dismissal`.
- **A strand name over 96 bytes** is cut in the feed row, as every item's is, so a
  dismissal that names the cut name finds no strand and is `not_found`.
- **The home's button is the owner's.** The home's `Act` is handed only to the
  owner's operating page, as its close and answer are, so a member's home draws no
  Dismiss. A member Operator dismisses from a session page's rail and over the
  control socket.
