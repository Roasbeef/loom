# protocol-change/012 — the operator's schedule surface

**Status**: ACCEPTED 2026-09-02 · **Affects**: Part 1.6 client command
set, `snapshot` event modes · **Raised by**: the scheduling plane review —
a session could hold clocks nobody could see ·
**Implemented**: `client/protocol`, `client/scheduleadmin`,
`client/gateway`, `client/serve`, `tui`

## Problem

Loom grew two ways to create a schedule and no way to look at one. An
operator writes `[[schedule]]` tables in `loom.toml`; a strand creates
its own through `tools/schedule` or the `schedule.*` code-mode
capabilities, under a policy the operator set and a ceiling the host
enforces. Both fire. Neither is visible over the client protocol.

The consequences are not symmetric, and that is what made this worth a
proposal rather than a knob. The operator's own tables they can at least
read back out of the file they wrote. What a *model* created is durable
state inside a session, holding one of a small number of ceiling slots,
firing text into a strand on a clock — and the only place it appeared at
all was the log. An operator watching a session could not answer "what
is scheduled here", and could not stop a heartbeat a model had asked for
without editing nothing, restarting nothing, and hoping the expiry
arrived. The model's own door can cancel it; the human's could not.

Comparable harnesses expose both halves: a command that lists every job
the host holds, a command that deletes one, and a slash command in the
terminal for the recurring kind. Loom had the durable store, the
scanner, the ownership ledger, and no surface.

## Proposal

Two commands and one `snapshot` mode.

```text
c→s: {v:1, id, cmd: ... |"schedules"|"schedule_cancel", body}

schedules       {}
schedule_cancel {target: string, name: string}
```

Both are answered with the same reply:

```text
s→c: snapshot {mode: "schedules", schedules: [Row]}

Row = {name:   string,
       target: string,
       owner:  string,      // "operator", or the owning strand's name
       when:   string,      // the host's rendering of the timing
       wake:   boolean,     // may a fire start a run on an idle strand
       fired:  int,         // occurrences already spent
       body:   string}      // the text one fire injects
```

The laws:

- **`schedules` lists everything.** Every operator `[[schedule]]` from
  the gateway's configured list first, then every live model-created
  cell, in that order. The order is part of the answer: standing
  configuration above what this session grew.
- **`owner` is a string, and it is what a client renders.** `"operator"`
  for a table, otherwise the name of the strand that created the
  schedule — the strand that could cancel it through the model's own
  door. It is not a discriminated type on the wire: the host decides
  which of the two a row is, and a client that had to tell "operator"
  from a strand called `operator` would be deciding something it cannot
  see.
- **`when` is an open string.** It is `scheduleseam.describe_timing`'s
  rendering, the same words the model's `schedule_list` gets, so an
  operator and a strand describe one clock identically. Clients print it
  verbatim and never parse it.
- **`schedule_cancel` retires exactly one model-created schedule**,
  named by `{target, name}` — the pair that *is* a schedule's identity
  in every durable key it owns. On success the reply is the `schedules`
  snapshot **as it stands after the cancel**, so one round trip both
  acts and re-renders.
- **Naming an operator table is `conflict`**, with a message saying that
  operator schedules are edited in the configuration file and take
  effect on restart. There is nothing to delete: a table has no durable
  cell, and a surface that appeared to delete one would either lie or
  begin writing durable overrides of a file the operator edits by hand.
- **Naming nothing live is `bad_request`.** A name never used and a name
  already cancelled are the same absence, because the store keeps no
  tombstone (`scheduleseam`, "why the writes are plain cells").
- **A host with no scheduling plane** answers `schedules` with an empty
  listing — the `models` posture, "there is nothing to pick from" — and
  `schedule_cancel` with `unsupported`. A cancellation that cancelled
  nothing must not read as one that worked.
- **Cancellation goes through `scheduleseam.retire`**, then
  `schedulescan.poke`, exactly as the model's door does: fired-marks,
  then the observation instant, then last the config cell. One deletion
  order for both doors, because the order *is* the crash story — a fault
  partway through must leave the schedule live and the caller told, never
  a success over a clock still ticking under a reusable name.

`wake` is a JSON boolean, which is the shape the model-facing tool
result already puts on the same question. In Gleam it is a two-variant
type (`protocol.ScheduleWake`) with the boolean confined to the codec.
The "frozen contract" escape in `docs/gleam-style.md` Part III ("No
naked `Bool`") would have permitted a `Bool` field here — a Part-1 field
costs a proposal rather than an edit — and this proposal declines it
while the field is still being minted, which is the one moment the
choice is free rather than a future protocol change.

## What this deliberately does not add

- **No creation over the protocol.** The two creation paths that exist
  are the operator's file and the model's door, each with its own
  bounds; a third would need its own policy story and its own place in
  the ceiling.
- **No live editing of operator tables**, and no pause. A `[[schedule]]`
  is configuration, like a `[[rule]]`: the file is the record and a
  restart is how a change to it lands. `client/rulescan` takes the same
  posture for the same reason.
- **No "run now".** Firing on demand is an injection with no occurrence,
  and every fired-mark in the store is keyed by occurrence.

## Impact

- `client/protocol` gains two additive command constructors, one
  `Snapshot` variant, and total codecs for both — all inside v1.
- `client/scheduleadmin` is new: the operator's door over the same
  `scheduleseam.Wiring` the model's door is built from, so a listing
  cannot disagree with what actually fires.
- `client/gateway` gains `with_schedules` and two command arms;
  `client/serve` builds the admin from the same wiring it already
  computes and applies it.
- Three golden fixtures pin the bytes (`cmd_schedules.json`,
  `cmd_schedule_cancel.json`, `event_snapshot_schedules.json`).
- `tui` gains `/schedules` and `/unschedule <name> [target]`.
- Nothing durable changes: no new key shape, no change to the schedule
  store, the seam, the scanner, or the model-facing tools.
- An older client keeps working, since it simply never sends either
  command; an older *gateway* answers both with the frozen `unsupported`
  error, so a newer client learns the surface is absent rather than
  believing an empty listing is the truth.

## Decision

**Accepted.** The alternative shapes were considered and dismissed.

*One command with a mode field* — `schedules {action: "list"|"cancel"}` —
collapses a read-only query and a durable delete into one name, which is
the same overloading `protocol-change/003` refused for the catalogue and
`set_config`. A command's name is the smallest place a reader can see
whether it commits anything.

*Cancel answering `{ok: true}`* rather than the listing would leave every
client to follow a success with a second `schedules`, and a client that
forgot would render a table with a dead row in it. The listing after the
act is one frame and cannot be stale.

*Letting the surface cancel operator tables* by writing a durable
suppression cell was the tempting one, because it is what an operator
first asks for. It fails on ownership: the file would no longer say what
the session runs, two records would disagree, and the next `loom.toml`
edit would be made against a state its author could not see. Refusing
with a message that names the file is the smaller and more honest thing,
and it is the posture the project rules already take.
