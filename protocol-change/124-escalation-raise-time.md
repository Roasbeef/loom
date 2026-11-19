# protocol-change/124: the escalation's raise time

**Status**: PROPOSED 2026-11-19. The owner accepted autonomous protocol
changes for the attention inbox build on 2026-11-17. This is part of the data
layer for the approved final mockup of the inbox.
**Affects**: one new optional field, `raised_at`, in the durable escalation
record (`fact.custom`, key `escalation/{id}`); the same optional field in the
session page's decoder (`session_view/approval.Review`) and in each item of
`approval.read`. The signatures of `runtime/escalation.raised` and
`runtime/escalation.claimed` gain an argument. No command, frame, event or
`loom.toml` key changes, and no stored record is rewritten.
**Raised by**: the attention inbox's approval thread, which must say when a
question was put to a person
(`docs/design-notes/attention-inbox/README.md`, sections 2.1 and 4).
**Builds on**: [016](016-record-human-origin.md) (the precedent for adding an
optional field to this record), [120](120-attention-feed.md) (which rejected
an age taken from the record's scope and said a time is "a separate change to
the record") and its addendum on approval evidence.

## Problem

An approval thread should say how long it has waited. The escalation record
holds no time. [120](120-attention-feed.md) rejected the only candidate that
was recoverable, the mint time of the operation named in `scope`, because an
operation can run for hours before it raises, so that time is the start of a
call and not the age of a question. Until the record carries its own time, no
page words an age for an approval.

## What was considered

### The scope's operation time

Rejected, for the reason above. It is also wrong on a re-opened record, whose
scope moves to the new claimant.

### A time in the broker's event

`bus.Escalation` is published when a denial is raised, so a subscriber could
note the time. Rejected: the event is not durable, a page that opens later
would have no time, and the record is the one place every reader already
reads.

### A required field

Every raise site would then have a time, and a record from before it could not
be decoded. Rejected: a decoder that refuses old rows loses every pending
approval in a session saved before the change. The field is optional on the
wire and in the type, and an absent time means the page draws none.

## Decision

The record gains `raised_at`, Unix milliseconds, the time the question that is
now pending was put to a person. It is stamped from the runtime's clock at
every site that raises or re-opens:

| Site | `raised_at` |
|---|---|
| `raise_escalation`, `raise_escalation_for` | the time of the raise |
| `claim_escalation` on no record | the time of the claim |
| `claim_escalation` on a rejected or consumed record, or an approved record bound to another action | the time of the claim, because the record re-opens as a new question |
| `claim_escalation` on a pending record, or an approved one bound to the same action | unchanged: the question has not changed |

The stored key is `raised_at`, an integer or `null`. A record written before
this change has no key and decodes with `raised_at` absent. A value that is
neither absent, `null` nor an integer is corruption, as every other typed field
of the record is. `session_view/approval.Review` gains `raised_at:
Option(Int)`, decoded the same way (a negative value is refused), and it is
`None` for a child's request on another orchestrator, whose record carries none.
Each `approval.read` item carries `raised_at` when the record has one and omits
it otherwise.

Times are on the wire as milliseconds since the epoch. The page formats them;
the daemon does not.

## What it costs

One integer in each record, written with the record. `escalation.raised` and
`escalation.claimed` take the time as an argument, so a caller cannot forget
it: the purely functional record transitions stay clock-free. A claim reads the
clock once for each attempt of its retry loop. A record raised by a daemon that
predates this change and re-opened by one that has it is stamped at the
re-opening. A record that was pending before the upgrade shows no age until a
person decides it, which is the cost of not guessing.

## Verification

`runtime/test/runtime/escalation_test.gleam` pins an old record decoding with
`raised_at` absent, `null` as absent, a wrong type as corruption, a claim
keeping the time of a pending record, and a re-opening stamping a new one.
`session_view/test/approval_raised_at_test.gleam` pins the page decoder.
`client/test/client/peer_mail_attention_test.gleam` pins the stamped time in an
`approval.read` item.
