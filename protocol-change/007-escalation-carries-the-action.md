# protocol-change/007 — carry the action into the approval prompt

**Status**: ACCEPTED 2026-08-27 · **Affects**: Part 1.6 `approve`,
`escalation` · **Raised by**: issue #83 (stage 2 of #65), folding in #67
and #72 · **Implemented**: client + tui

## Problem

Stage 1 of #65 (`79f6e84`) bound an approval to the action it was
granted for: the record gained the tool, a digest of the call's
effective arguments, and a bounded preview of them, and a claim or a
spend that names a different action no longer inherits the grant. That
closed the capability leak. It did nothing for the other half of the
same bug, which is that **the person answering cannot see what they are
answering about.**

The approval overlay renders exactly this:

```
sandbox escalation on main
tool requirements exceed the session policy
wants: <grant>
```

`Denial.reason` for a policy refusal is a fixed string
(`broker/broker.gleam:499`) and `protocol.EscalationRecord` carries no
tool and no arguments, so consent is given at the granularity of
"something on this strand wants network". The record has held `tool`,
`action` and `preview` since stage 1; nothing on the wire reads them.

Two further findings sit on the same three fields and are folded in
here rather than landing as separate wire changes:

- **#67 — the gateway guesses the strand.** `escalation_attribution`
  infers `#(op, strand)` from the hub's live map: with exactly one live
  operation it returns that pair for *every* record regardless of which
  strand raised it, and with zero or several it returns two empty
  strings. In a two-strand session with one operation open on `main`, a
  refusal raised by `sub:1` is presented as `main`'s. That strand name
  is currently the *only* identifying information the approver gets, so
  naming the wrong one is a consent problem, not a display bug. The
  record has carried the exact `CallScope` since `78324a9`.
- **#72 — `grants: None` resolves at commit time.** `dedup_key` drops a
  limit grant's magnitude on purpose (the anti-fatigue defence of
  #45/#50), and `escalation.claimed`'s pending branch refreshes the
  stored denial from whichever call currently holds the claim. So a
  human looking at `wants: wall_s 60` could commit `wants: wall_s 600`
  if a retry carrying a larger model-supplied timeout refreshed the
  record between the render and the answer. What bounds this today is
  `bash`'s own 600 s clamp — incidental, and gone the day any tool
  derives a second limit from an argument.

Stated as a chain, this is the last unverified link in stage 1's:

```
rendered → ??? → approved record {grants, action}
        → claim: an Approved record moves only to a same-action claimant
        → spend: scope + action guard, consume CAS at the checked seq
        → one execution of exactly the rendered action
```

A spend-time check binds execution to what the record held *at
approval*. Nothing yet binds the record at approval to what the human
was **shown**.

## Proposal

### `escalation` gains the action

```
escalation := {escalation_id, op, strand, status,
               tool?, action?, preview?, asked?, denial?}
```

Version stays `v: 1`. All four fields are additive and each is omitted
when it says nothing, so a record raised through a door that names no
action encodes byte-identically to one written before the fields
existed. Readers treat an absent `tool`/`action`/`preview` as the empty
string and an absent `asked` as `0`; such a record must still render and
must still be approvable. A field that is *present* and of the wrong
type stays a malformed body — tolerance of absence is not tolerance of
nonsense.

`op` and `strand` are now read off the record's own `CallScope` and are
empty together exactly when the record names no call. The guess is
deleted, as is the claim at `client/protocol.gleam:212` that the durable
record does not store them, which `78324a9` made false.

### `approve` echoes what was rendered

```
approve := {escalation_id, grants: [Grant], action: string}
```

Both are **required**. They are the client's echo of what it actually
put in front of a person: the policy diff it drew and the digest of the
action it drew beside it. The gateway checks the pair against the record
it is about to commit and refuses a mismatch with a new error code,
`stale_approval`, whose `details` carry the record as it now stands
under an `escalation` key — an `escalation` event body verbatim — so the
client re-renders and asks again. The refused command has no effect.
`grants` may still be a subset of `wanted` (narrowing is legal) and may
never exceed it.

**The echo check and the `Approved` commit share one read.** The gateway
reads the record's *cell* — the record plus the seq of the write that
put it there — checks the echo against that value, and commits the
approval CAS-guarded at that same seq. This is the mechanism, not
tidiness: a claim is exactly the event that changes what a record wants,
it bumps the register seq when it lands, and a claim landing between the
check and the commit therefore loses the commit instead of passing
unseen. Read twice and the check would be about a record the commit
never touched. The gateway consequently builds this transaction itself
rather than calling `api.approve_escalation`, which reads again for
itself and retries.

### Rendering rules, normative in the protocol document

`preview` is model-controlled untrusted display data shown inside the
one prompt whose purpose is to be answered truthfully. `protocol.md`'s
`escalation` section now states four rules that bind **any** client:
neutralise C0/C1/DEL and the bidirectional formatting characters into a
visible form rather than stripping them; fence the preview away from the
client's own words; bound it on screen; and always print the tool name
and say that the preview is a window on a possibly much larger action.

They are stated in the protocol document rather than only in the TUI
because a third-party client that ignores them recreates the whole risk
— a `bash` command line carrying ANSI sequences can clear the screen and
repaint a forged question above the approve/deny. The protocol can
document this and cannot enforce it, which is exactly why it is written
down. Issue #80 is the TUI-wide sanitiser sweep; this change implements
the overlay path and leaves the rest.

## Impact

- **`client/protocol.gleam`** — `Command.Approve` becomes
  `(escalation_id, grants: List(Grant), action: String)`;
  `EscalationRecord` gains `tool`, `action`, `preview`, `asked`; encoder
  and decoder for both, plus `code_stale_approval` and
  `stale_approval_details`.
- **`client/gateway.gleam`** — `escalation_attribution` reads the
  record's scope; a single `escalation_view` bridges the durable record
  to the wire shape for the event, the snapshot, and the refusal
  details; `approve` is rewritten around one `api.escalation_cell` read
  with the echo checks and a CAS-guarded commit at that seq; the module
  doc's best-effort-attribution bullet goes.
- **`client/demo.gleam`** — one call site: the demo's `approve` names
  its grants and echoes the empty action of an unscoped record.
- **`tui/internal/proto`** — `ApproveBody` gains `Action` and loses
  `omitempty` on `Grants`; `EscalationBody` gains `Tool`/`Action`/
  `Preview`/`Asked`; `ErrStaleApproval`; a new `SanitizePreview`.
- **`tui/internal/ui/model.go`** — the overlay names the tool, fences
  the sanitised preview, bounds it, and always prints the window
  footer; the approve send echoes the rendered action; a
  `stale_approval` refusal re-opens the prompt from the record it
  hands back.
- **`tui/internal/fake`** — the fake refuses a missing `grants` and a
  mismatched `action` the way the gateway does, since it is the
  substrate the TUI's own tests run on; the demo script raises a record
  carrying a tool, a digest and a preview with a live ESC sequence in
  it.
- **Conformance fixtures** — `cmd_approve.json`, `cmd_approve_all.json`,
  `event_escalation_pending.json`, `event_escalation_approved.json`. The
  corpus count is unchanged at 35 and no fixture is added or removed.
- **Tests** — `client/gateway_test`, `client/protocol_test` (new),
  `tui/internal/ui/model_test`, `tui/internal/fake/fake_test`. The
  jailed end-to-end (`client/tui_e2e_test`) exercises the whole path
  unchanged, since it drives the real TUI through a real socket.

**Old clients fail loudly, and never silently.** An `approve` without
`grants` or without `action` is a refused frame — `error`
(`bad_request`) naming the missing field — and the escalation stays
pending. A client that sends the fields but echoes something the record
no longer holds gets `stale_approval` and the fresh record. There is no
path on which a v1-shaped `approve` from an older client is accepted and
interpreted as "everything currently wanted"; that behaviour is gone,
not defaulted. This is a semantic break inside `v: 1` rather than a
version bump, which is acceptable pre-release with one client in the
tree that ships from the same commit — but it is worth saying out loud
rather than leaving a reader to infer it from the required fields.

No durable format changes: `runtime/escalation`'s record already carries
all four values, and this change only lets them reach a screen.

## Decision

**Accepted.** Two alternatives were considered and dismissed.

*Show the action without requiring the echo.* This is the cheaper half
and it leaves #72 exactly where it was: the prompt would name the
action, and the approval would still commit whatever the record wanted
at commit time. Rendering more and checking nothing binds nothing —
what makes the display load-bearing is that the answer has to quote it.

*Version the protocol to `v: 2` for the `approve` break.* The wire has
one client, it ships from this tree, and both ends of the change land
together. A version bump would buy compatibility with a client that does
not exist, at the cost of a second envelope version to carry forever;
the honest alternative is a loud refusal, which is what a required field
already produces.

Three properties this deliberately does **not** buy, restated from #65's
ruling so no reader infers them:

1. The human consents to a 2 KB window of a possibly larger action. The
   digest covers every byte; the reader saw the head. → #81.
2. Consent binds to argument bytes, not to effects. `bash "./build.sh"`
   approved once spends on a retry even if the script changed in
   between; the widened *policy*, not the approval, remains the real
   boundary.
3. The rendering rules are normative and unenforced. A client that
   ignores them recreates the forgery surface, and the protocol has no
   way to tell. → #80 for this TUI.
