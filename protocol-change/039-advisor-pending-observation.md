# Advisor pending-nudge observation

Status: proposed read-only observation of the advisor's undelivered nudge
queue. Extends the optional read surface in Part 1.6, following protocols
026 and 030.

## Problem

A nudge the advisor queues is not an entry. It waits in the `pending` field
of the emission guard cell (`fact.custom` at `advisor/guard`) until the
primary's next run start drains it into that run's first message. Nothing
carries it to an operator in the meantime: the gateway's snapshot plan reads
`fact.custom` only under the client prefix and the escalation prefix, and no
frame is written to any branch.

The queue is therefore invisible at exactly the moment it matters. The
primary is idle, the advisor has finished a review and written advice, and
the operator is deciding what to ask for next — which is the decision the
advice was meant to inform. An operator who cannot see it either re-asks a
question the advisor already answered or starts a run that carries advice
they have not read.

## Decision

Add read-only `advisor_pending`. A subscribed attachment may request it with
ordinary session-read authority, the way `live_jobs` and `context` are
requested. The body is `{}`. A session has one advisor and one primary it
advises, so there is nothing to scope: a strand argument could only repeat
the answer or contradict it.

The gateway reads the guard cell itself, through the bounded storage reader,
with one exact-key `fact.custom` selection for `advisor/guard` and the guard
module's own total decoder. It does not speak to the advisor actor. The reply
is a `snapshot` with `mode: "advisor_pending"` and board:

```text
{strand, observed_at_ms, pending: [string], total}
```

`pending` is the queue oldest first, exactly as queued. `strand` is the
primary the queue drains into, named by the server. `observed_at_ms` is the
server's wall clock at the read. `total` is how many nudges were waiting and
never falls below the number of rows sent.

The board carries no `omitted` field, unlike protocol 026's roster. It does
not need one: the guard admits at most `pending_cap` nudges totalling
`pending_bytes` — eight and four kilobytes as shipped — so the whole queue
fits inside the response bound and the board can never be a truncated view of
itself. A future cap large enough to need omission would raise `total` above
the rows sent, which is the shape clients already validate.

Three refusals are distinguished. A missing cell is an empty board: a session
whose advisor never ran, or never queued anything, genuinely has nothing
pending. A store that will not answer is `unavailable`, never an empty
success, which is the rule protocol 026 states for the same reason. A cell
that is present and fails the guard's decoder is also `unavailable`, because
an empty board is the positive claim that the advisor has nothing waiting and
an unreadable cell is not evidence for it. The advisor actor's own fallback
differs — it carries on from the empty guard — because it must keep reviewing
whatever it finds under that key; an observer may say that it cannot tell.

The read never drains. `take_pending` belongs to the primary's run-start
hook, and an observation that consumed the queue would show the operator
advice the model would then never be given. No ordinary transcript snapshot
or metadata capture invokes this read.

The terminal issues the read itself, with no operator keystroke, on three
transitions and no others: the primary's operation settling, a review
settling while the primary is already idle, and an attachment reaching a
session whose primary is idle. It draws the queue as a compact panel above
the composer, headed `advisor nudges pending (N)`, and clears it when the
primary leaves idle — that run start drained it — or when the board comes
back empty. The panel is deliberately not a transcript row: drawing
undelivered advice where delivered messages go would tell the operator the
model had already read it. An older gateway refuses the optional command with
`unsupported` and the panel simply never appears.

## Alternatives and cost

Writing each queued nudge as an entry on the primary's branch would make the
existing transcript carry it and need no new command. It is the wrong answer
twice over. It races the drain: the run start folds the queue into the
prompt, so a frame written at queue time and a drain a moment later describe
the same advice twice, and the ordering between the branch write and the
`take_pending` swap is not one the queue has any reason to guarantee. And it
misrepresents the thing itself. An entry is a message the model was given;
these are texts the model has not seen and may never see, since a drain that
misses its admission drops them. Recording them as delivered is a claim the
harness cannot support.

Pushing the queue to attached clients whenever it changes would save the
round trip. It also obliges the server to say something on every verdict —
including the ones delivered rather than queued — and to track which
attachments care, for a board that is interesting only on an idle edge the
terminal already observes. A pull on that edge costs one request per settled
operation and leaves the server's push vocabulary alone.

Reading the queue through the advisor actor would reuse the actor's cached
guard rather than a storage cut. That puts a terminal read on the same
mailbox the primary's run start waits on, behind a review that may be
scanning a branch, and puts a drain-shaped call one refactor away from an
observation. The exact-key read borrows nothing and can take nothing.
