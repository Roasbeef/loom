# protocol-change/125: the session brief, a bounded read of a session's recent work

**Status**: PROPOSED 2026-11-19. The owner accepted autonomous protocol
changes for the attention inbox build on 2026-11-17. This is part of the data
layer for the approved final mockup of the inbox.
**Affects**: one new v2 control command (`session.brief`); one new command on
the session's peer endpoint (`SessionBrief`); one new in-process read for the
home page (`server.home_brief`, `home.Attention.brief`); one new per-credential
allowance (`ui_sessions.BriefReads`); one new typed module shared by the page
and a control client (`web_view/session_brief`). No existing command, frame,
event, record or `loom.toml` key changes.
**Raised by**: the attention inbox's thread panes
(`docs/design-notes/attention-inbox/README.md`, sections 2.1 and 2.2: "what the
session is doing now, its last few steps", "whatever has happened in that
session since it asked").
**Builds on**: [050](050-session-activity.md) (the activity row this read sits
beside), [120](120-attention-feed.md) (the authority walk and the door shape
it repeats) and [123](123-review-hunks.md) (the allowance it is limited by).

## Problem

Home draws what a session is doing, what it last said, and what has happened in
it since an approval was raised. The activity row carries two clipped strings
and a count. The feed carries identities. No read answers: what is the session
saying now, even mid-turn; which steps did it take last; which of its strands
are going and since when; how much of its goal's budget has it spent; which peer
messages arrived since a given time; what was the last command and how did it
end.

## What was considered

### Fattening the activity row

Rejected. The row is read for up to 24 sessions every refresh and bounded at
2,300 bytes. Steps, a roster and peer messages for every listed session would
not fit, and most of them are never opened. A thread asks for one session's
brief when the thread is shown.

### Reading the transcript through the gateway

A page could attach to the session and read its lane. Rejected: that is the
session page, with its own permit and relay, and Home reads in process without
attaching to anything.

### Words for the last command

The brief could word a command as "the check", as the mockup's agent does.
Rejected. A command that exited 0 is not a claim that anything passed. The brief
carries the command and the exit status as facts, and the page words them as
"last command: X, exit N".

## Decision

### The command

`session.brief` is a v2 control command that takes the session's canonical
identity, an optional `since` (Unix milliseconds, a non-negative integer,
default 0) and the current epoch. It is refused with `stale_epoch` when the
epoch is old and with `bad_request` for a malformed request.

```json
{"v":2,"id":1,"cmd":"session.brief","body":{"session":"<canonical-id>","since":1763400000000,"epoch":"<current-epoch>"}}
```

The reply is `{"brief": {...}}`. Every time is Unix milliseconds, and the daemon
formats none. Absent sections are omitted.

| Member | Meaning |
|---|---|
| `assistant` | `{"text", "trust": "untrusted", "at"}`: the latest assistant message of the main strand that has text, even when its turn is still running, cut to 600 bytes, with the `ts` of its entry. Model text. |
| `steps[]` | At most 4 recent tool calls, newest first: `{"at", "tool", "words", "trust": "untrusted", "outcome"}`. `tool` is the name the model gave the call, cut to 64 bytes, and is model text like `words`. `words` is the line the session's own page uses (`session_view/step_words`: `Ran make check-core`, `Edit calc.py +3 −1`), in the present tense for a call with no result, cut to 120 bytes. `outcome` is `running`, `succeeded` or `failed`, which is what the result envelope reported and no claim about the command's meaning. |
| `strands[]` | At most 12 strands, working ones first and then by name: `{"name", "state", "since"}`. `state` is `working`, `idle` or `stopped` (the last run failed). `since` is the mint time of the open operation for a working strand and the time of the last entry of the last run for another, and is omitted when there is none. |
| `goal` | `{"objective", "status", "tokens_used", "token_budget"}` when the session has a goal: the objective cut to 200 bytes, `active`, `paused`, `limited` or `complete`, and the accounted total against the pinned budget. |
| `peers[]` | At most 3 peer messages recorded after `since`, newest first: `{"session", "strand", "at", "text", "trust": "untrusted"}`, the text cut to 280 bytes. A peer message is a user message whose admitted author is a peer agent, so a message a person typed or a strand of the same session sent is not one. |
| `command` | `{"command", "trust": "untrusted", "exit", "at"}`: the newest `bash` call of main whose result carried an exit status, the command cut to 200 bytes. |

Text and steps, peers and the command come from a window of the main strand's
last 80 message entries, read newest first from its leaf. A strand's other
history is not read.

### What is model text

The assistant's words, a step's tool name and words, a peer's message and the
command are written by a model or another session. They carry `"trust": "untrusted"` on the
wire, and the decoder (`web_view/session_brief`) wraps each in an opaque
`Untrusted` type that is read only through `untrusted_text`, so a page cannot
draw one without saying so. A page draws them as text nodes under a label that
says whose words they are. The goal's objective (the operator's) and a strand's name are
bounded plain text, not `Untrusted`: a strand's name is minted by the harness from
a spawn's purpose, and the page draws both as text nodes only.

### Bounds

Every text and list is cut as above on a grapheme boundary. JSON escaping can
grow a cut string several times, so the encoded brief is measured against
12,000 bytes and shed until it fits: strands first, then peers, then steps, each
from the end of its list, and last the assistant's words. The reply is also
checked against the 60,000-byte frame. The fixed part of a brief is far under
the bound.

### Who may read, and how often

Authority is read from the registry at the call (`attention_door.held`): the
owner and a member at any role, which is the rule `attention.read` follows and
no wider. A session the credential does not hold is `not_found`, a saved
session is `not_resident` (the daemon never opens one for a read), and a
bystander learns nothing. A member's Home and an observer's follow the same
rule, because the brief shows what the session's own page shows an observer.

A read spends one of the credential's brief reads, six in four seconds counted
across all its pages (`ui_sessions.reserve_brief_read`), as review scans spend
workspace reads (`reserve_worktree_read`). A refusal is `unavailable` with fixed
words. A daemon with no web view has no table to count in, and its control
sockets are the owner's and its members' alone. The read is a handful of register
reads in the session's Agency actor, which runs no tool, opens nothing and
writes nothing.

### The home page

`home.Attention` gains `brief`, which the daemon fills with `server.home_brief`.
Home asks for the shown running session's brief when a thread is shown or a read
settles, with `since` set to the raise time of the oldest pending approval it
holds for that session, or 0, and keeps the answer by session as
`Model.briefs`, replaced by each read.

## What it costs

A thread selection costs one read, which delays the session's other peer
commands by the time its reads take: one branch scan of up to 80 entries, two
register listings, a batch read of up to 12 entries and the goal cell. Home
reads at most one session's brief at a time. The reply is bounded at 12,000
bytes. The command is in the drain's read set and in no write set.

## Threat model

Everything in [120](120-attention-feed.md) stands. A compromised Home page can
read the brief of any session its credential holds, at the allowance's rate, and
learns what the session's own page would show it. It cannot write, decide an
approval, or read a saved session. The model's text reaches the page as text
that is marked untrusted twice, in the JSON and in the type, and that no view
can read without `untrusted_text`.

## Verification

`web_view/test/session_brief_test.gleam` pins the codec as a qcheck property on a
fixed seed and the untrusted mark on the wire. `client/test/client/session_brief_test.gleam`
pins each rule over synthetic entries, the bounds and the shedding order, and
reads a real runtime's brief back. `client/test/client/daemon_attention_test.gleam`
pins the door: an observer reads, a bystander is `not_found`, an exhausted
allowance and a saved session are refused, and the control command's epoch and
reply.
