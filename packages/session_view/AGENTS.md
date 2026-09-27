# session_view

## Purpose

The part of a Loom client that no host owns: the session lane that speaks
the v2 conversation protocol, the decoders for what the daemon sends, the
projection of a completed capture into a view, and the line builders that
turn that view into transcript lines. It was extracted from `packages/tui`
in phase 4 of issue #530 (ADR-013) so that a second host, the daemon's
read-only web view, can drive the same code the terminal does instead of a
copy of it.

"No host owns it" is literal. The package imports `core`, `machine` and
the standard library and nothing else, and lint R6 holds it there
(`packages/lint/src/lint/portable.gleam` says why it is on the list). A
socket, a recording file, a terminal, a clock and a mailbox all belong to
the host. Where the lane has to name one of them, it takes it as a type
parameter: `session_channel.Channel(socket, recorder)` carries the host's
handles to the outputs that act on them and never uses them itself.

The package holds no process and performs no effect. A host drains its own
inbox, hands each `connection_event.Message` to the lane with the time it
read, takes the lane's outputs and performs them.

## Key Types

- `session_channel.Channel(socket, recorder)` (opaque): one credited
  conversation lane. `start`, `start_recorded`, `start_resumed` and
  `replay` create one; `receive(channel, message, now:)`,
  `tick(channel, now:)`, `submit`, `close` and `retire` transition it and
  return `Update`s; `take_outputs` hands over the queued `Out`s oldest
  first. `socket` returns the host's handle for liveness checks.
- `session_channel.Out(socket, recorder)`: `Transmit(socket, frame)`,
  `Shut(socket)`, `Note(recorder, attempt.Event)`. The terminal performs
  these in `tui/terminal_lane.perform`.
- `session_channel.Update`: what a transition tells the host. `Captured(cut,
  view, trigger)` is the only update that replaces the visible projection;
  the others are submissions, history pages, lookups, refusals, pushed
  stream fragments and tool tails, commit notices, acknowledgements, lost
  replies and failure.
- `inbox.Inbox(source, a)` (opaque): what a host received from one
  source and has not reduced, oldest first, with the host's name for the
  source. `push` files behind the held messages and `take` returns the
  oldest; reading a mailbox stays with the host (`tui/buffered` over an
  Erlang subject). An adoption replaces the whole value, so a replaced
  source's held messages cannot reach a reducer.
- `connection_event.Message`: `Connected`, `Incoming(text)`,
  `Closed(reason)`, `NetworkFault(reason)`. The host's transport maps its
  own events into these.
- `attempt.Event`, `attempt.Request`, `attempt.Id` and
  `attempt.Trace(recorder)`: the recording vocabulary of one attachment
  attempt, and the recorder and identity a lane records under.
- `snapshot.Captured`, `snapshot.Window`, `snapshot.Item`,
  `snapshot.Attachment`, `snapshot.Expected`: one validated cut and the
  bounded window of records it holds. `snapshot.Transfer` (opaque) is a
  cut still being received.
- `snapshot_view.View`: the presentation decoded from a cut's metadata
  (`snapshot_view.decode`), and `snapshot_view.Branch`, one strand's
  records.
- `history_view.State`: the bounded, pageable window of a strand's
  ancestry; `capture` folds a cut in and `branch` gives its records.
- `protocol.Event`, `protocol.EntryRecord` and the board types, and
  `session_wire.Reply`: total decoders for the daemon's frames.
- `transcript_line.Line(speaker, text)` and `Speaker`, with the live
  observations that become lines: `Stream`, `ToolTail`, `CacheNotice`,
  `Submission`.
- `transcript_lines.Presentation`: everything the line builders read of a
  client's state. A host fills it; the terminal does so in
  `tui_model.presentation`.
- `transcript.project(cut, view, strand)`: one strand's lines from one
  capture, for a host that keeps no presentation state between cuts.
  `transcript.project_rows` gives the same lines as `Row(key, line)`, each
  keyed by the durable sequence it was drawn from
  (`transcript_lines.keyed_record_lines`), so a view that keys its list
  drops the rows a moving window loses instead of rewriting the rest.
- `operator`: what an operator's input becomes on the wire, shared by the
  terminal and the web view. `submit(lane, id, strand, text, Delivery,
  now)` sends a `Prompt` or a `Steer`; `decision` and `decide` encode an
  answer (`Choice`: `AllowOnce`, `AllowForSession`, `Deny`) that echoes
  the drawn escalation exactly; `drawn` finds a pending record only by its
  identity and the sequence it was drawn at; `drain(state, budget, take,
  handle)` is the bounded, oldest-first loop both hosts feed the lane
  with.
- `text_hygiene.multiline` and `single_line`: the terminal-safety pass
  every untrusted string goes through. `unchanged_prefix` is how many
  leading bytes the pass leaves as they are, with the guarantee that the
  pass over the whole is that prefix followed by the pass over the rest;
  the terminal's live tail uses it to sanitize a growing answer once
  rather than on every frame.

- `turns.pieces(blocks, strands, latest)`: one strand's lane as turns for a
  host that draws more than rows (the web view): `Plain` blocks, one `Work`
  divider per turn (`Folded`, or `Open` while the strand runs or waits on an
  approval; its `Worked` figures come from the records), `Spawned` and
  `Returned` rows for sub-agents, `Nudged` for a delivered advisor frame,
  `Peer` for another session's message, `Missed` for a cache notice and
  `Commentary` for the advisor's board. It reads
  `transcript_lines.keyed_record_blocks` (`transcript.blocks`), which tags
  each block with its `Source`. `turns.hue` is a strand's colour from its
  position, never its name.
- `agent_view.Row`, `agent_activity` and `reviewer_status`: each strand's
  status, task, activity and approvals from one capture, shared by the
  terminal's agent rail and strip and the web view's chips.
  `agent_roster.{Roster, Line, Chips}` is which strands a strip lists, in
  what order, with elapsed time and context size (`lines`, `chips`,
  `started_at`, `context`).
- `cache_miss` (a miss reconstructed from two usage rows, and the TTL
  outlook the rows prove) and `cache_watch.Ledger` (which rows may be
  compared: `admit`, `settle`, `capture`, `observe`, `forget`, and `shown`,
  which suppresses the outlook while a strand runs): the prompt-cache rules
  both hosts draw.

The remaining modules are the pieces those decode or fold through:
`approval` (exact escalation decisions), `advisor_history` and
`advisor_pending`, `block_summary` (summarizer labels), `command` and
`skills`, `composer` (the rules for showing pasted text, and the composer's
attachment list), `context_view`, `file_read_view`, `goal_view`,
`live_jobs`, `notes_view`, `pasted_image`, `queued_input`,
`stream_identity`, `text_hygiene`, `todo_board` and `tool_activity`, and
`worktree_view`.

## Relationships

- **Depends on**: `core` (json, codec, entries, messages, ids, todo_list),
  `machine` (`codec`, `operation`, `strand` for decoding register cells),
  `gleam_stdlib`. Nothing else, by R6.
- **Depended on by**: `tui`, the terminal host, and `web_view`, the web
  host. `client` takes it as a dev dependency because its tests drive the
  terminal's lane.
- **No module here imports `tui`**, and none may: the package is below the
  terminal in the dependency graph.

## Traffic

None of its own. The package defines no actor, message or register. It
decodes the ClientGateway protocol (spec Part 1.6, `docs/client-protocol.md`)
frames a host hands it, and the frames it asks the host to write are
`subscribe`, `snapshot_next`, `catch_up`, `history`, `escalations_get` and,
through `submit`, the session's mutations. A read-only host never calls
`submit`; the web view's operator page submits only through `operator`.

## Invariants

- **No host in the package.** No `@external`, no `gleam_erlang`, no
  `gleam_otp`, no transport, file or terminal. R6 gates it at error level.
- **Every output names the handle it acts on.** A frame decided against
  one socket is written to that socket even if the host has replaced the
  lane since; a note goes to the recorder it was decided under (ADR-013,
  phase 1 and phase 2 S3).
- **The lane reads no clock.** Every transition that sets or checks a
  deadline takes `now` from its caller.
- **One request owns the wire.** A mutation is issued at most once and a
  lost reply becomes `UnknownOutcome`, never a retry (the protocol model in
  `protocol/models/terminal-attachment/` checks this).
- **`Captured` is the only update that replaces the projection.** A host
  that draws anything else from a partial transfer is drawing a cut that
  was never validated.
- **The line builders read a `Presentation`, never a host's model.** A
  new input to a line builder is a new field on `Presentation`, filled by
  every host.

## Deep Docs

- `docs/adr/013-tui-effects-as-values.md`: why the lane's effects are
  values; its phase 3 addendum, "What phase 4 extracts", set this
  package's scope.
- `docs/architecture/terminal.md`: the terminal host that drives it.
- `docs/client-protocol.md`: the protocol the lane speaks.
- `protocol/models/terminal-attachment/`: the P model of the lane, the
  attachment worker and the gateway.
