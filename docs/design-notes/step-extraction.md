# Extracting the client step into `session_view`

Status: **accepted**; the owner ruled on questions 1 and 2 of section 6
on 2026-09-27 and approved starting S1. Design note for
[issue #569](https://github.com/Roasbeef/loom/issues/569) Part 1. Written
against `main` at `868dfedd8` on 2026-09-27. S1 has since split the
terminal's model; the line numbers below were re-pointed to the tree after
S1, and where S1 renamed a cited type the citation names its successor
(`State` is now `Model`, and the render caches' `View` is now `Caches`).
The field table still describes the record as it stood before the split.
S2 has since made the shared record's host handles type parameters; where
it departed from this note, the S2 entry in section 5 says how and why.
S3 was re-sliced on 2026-09-28, with the owner's approval, after a census
found that section 3's lists miss much of what the lane and event folds
reach; section 5's S3 entry gives the census and the new landings, and
S3a′, S3b′ and S3c′ have landed.

Issue #530 left the terminal and the web view sharing the session lane and
the transcript projection but not the step. The terminal reduces with
`tui.step` over a `Model` of 152 fields; the web view reduces with
`component.update` over a model of 22 fields and its own copy of the
capture, cache and approval folds. This note decides how the step moves
into `session_view`, the R6-portable package, so that the web view runs
the terminal's reducers instead of its own. It settles six things: which
fields of the terminal's model are session state and which are the
terminal's own, the signature of the shared step, how the reducers that
touch both kinds of state are cut, what the web view deletes, the order of
slices, and the questions that were left open, two of which the owner
has since ruled on.

The design points the issue records from the outside review are taken as
given and not re-argued: two records per host (`{shared, view}`), no new
package, the shells follow `operator_page`'s `Observed` and `effect.map`
template, the web shell reads `now()` once at the top of its `update`, and
`rearm` stays the web host's handler for `next_due`.

## Where the step is today

The terminal's whole update is `runtime.settle(step(runtime.message(event,
model), runtime.receive(model)))` (`packages/tui/src/tui.gleam:1745`
(`update`)). `step` takes `msg.Msg` (`tui/msg.gleam:48` (`Msg`)): an
`Input(at, event)` it reduces through `apply_input` and `settle_update`
(`packages/tui/src/tui.gleam:1842` (`apply_input`),
`packages/tui/src/tui.gleam:1922` (`settle_update`)), or an `Arrived`
that `admission.admit` only files (`tui/admission.gleam:68` (`admit`)).
Every reducer reads and writes one record, `State(view)`
(`tui/model.gleam:346` (`Model`)), whose `view` field already holds the
terminal's etui render caches (`tui/model.gleam:284` (`Caches`)). The lane's
outputs join the step's one outbox through `hold_channel`
(`tui/model.gleam:929` (`hold_channel`)), and `runtime.take` returns
them with the model (`tui/runtime.gleam:355` (`take`)).

The web view holds the lane, an inbox and what it derived from the last
capture (`web_view/component.gleam:287` (`Model`)). Its `update`
(`web_view/component.gleam:506` (`update`)) reduces on `Arrived` and
`Ticked`, folds the lane's updates in `apply`
(`web_view/component.gleam:639` (`apply`)), and re-implements the
capture fold (`captured`, `fresh`, `recaptured`), the usage and cache
fold (`used`, `settle_cache`, `settle_pushed`, `noted`) and the submission
fold (`settled`) that `tui/inbound` and `tui/outbound` already contain.
That is the drift the issue names.

```mermaid
flowchart LR
    subgraph today["today"]
        direction TB
        subgraph tui["packages/tui"]
            tmsg["msg.Msg"] --> tstep["tui.step<br/>admission, inbound, outbound,<br/>submit, surfaces, tick"]
            tstep --> tmodel[("State(View)<br/>152 fields")]
        end
        subgraph web["packages/web_view"]
            wmsg["component.Msg"] --> wupdate["component.update<br/>apply, captured, fresh,<br/>used, settle_cache, settled"]
            wupdate --> wmodel[("component.Model<br/>22 fields")]
        end
        subgraph sv["packages/session_view"]
            lane["session_channel"]
            op["operator"]
            proj["transcript, cache_watch,<br/>agent_view, approval"]
        end
        tstep --> sv
        wupdate --> sv
    end
```

## 1. The field split

### The rule

A field is **session state (a)** when a second host would need the same
value to show or act on the session correctly: what the daemon said, what
this client has sent and not yet seen committed, and the bookkeeping the
lane's reads and reads-in-flight need. It is **terminal state (b)** when
only the terminal reads it, or when its type names etui, a terminal
surface, a daemon-control job or a pane reporter. It is a **host handle
(c)** when the shared step must carry it to name the target of an effect
and must never use it: those become type parameters, as the lane's
`socket` and `recorder` did in phase 4
(`session_view/session_channel.gleam:317` (`Channel`)).

Three fields are records that hold both kinds of state and are split
rather than placed. Four fields are counters that only the terminal reads
today but that shared reducers bump; they stay shared as presentation
revisions, because the alternative is comparing the whole record after
every event, which the code avoids on purpose (`tui/tick.gleam:388`
(`refresh_frame_cache`), the comment above it).

The daemon-control jobs, the reconnect, the provisional attachment and the
picker's activity poll are terminal state, not session state. The web
page's transport is a relay the daemon opens for it; it does not launch
daemons, relaunch them, switch attachments or page a catalogue. Keeping
that machinery in the terminal also keeps the P model unchanged: its
`Terminal` machine stands for `tui.step` followed by `runtime.perform`,
and its interleavings are the attachment worker's and the gateway's
(`protocol/models/terminal-attachment/README.md`).

### The terminal's `Model`

152 fields, in the record's own order as it stood before S1, which split
it into `Shared` (`tui/session_model.gleam:94`) and `View`
(`tui/model.gleam:379`). The counts: 80 shared, 65
terminal, 4 handles, 3 split.

| Field | Group | Reason |
|---|---|---|
| `quit` | a | Both hosts stop the loop on it; the web's `Ended` is this plus the reason line. |
| `width`, `height` | b | The terminal's size. |
| `palette` | b | Launch-time colour capability. |
| `input` | b | An etui `TextAreaState`; the web's editor is the browser's. |
| `strand_workspaces` | split | The parked `scrollback` per strand is the session's history window and moves to a shared `Dict(#(session, strand), history_view.State)`; the editor, its history, the offset, anchors and height stay terminal; the record is `StrandWorkspace` (`tui/model.gleam:245`). |
| `restored_workspace` | b | A viewport endpoint the next projection restores. |
| `attachments` | a | What the next submission carries, not editor state; `submit_with_images` sends them (`tui/submit.gleam:448` (`submit_with_images`)), and Part 2 adds images to the page's composer. |
| `history`, `history_index`, `history_draft` | b | The composer's command history. |
| `command_selected` | b | The palette's cursor. |
| `submission_mode` | b | Tab's choice for the next Enter; the web sends its delivery with each submit. The shared `Submit` command carries it. |
| `pending_submission` | a | Whether a mutation is locked behind the lane and whose draft it consumes on `Sent`, decided in `apply_submission` (`tui/outbound.gleam:112`). The web's `drafts` counter is derived from it. |
| `interrupt` | a | The held interrupt waiting for its operation to settle. |
| `submitting` | a | The strand whose prompt is on the way. |
| `queued` | a | Echoes of held prompts, retired by their committed entries. |
| `awaiting_outcome` | a | The one submission whose reply is out. |
| `transcript` | a | The banner, build, configuration, approval and error lines every host shows. |
| `records` | a | The active strand's records from the last cut. |
| `cache` | a | The prompt-cache ledger both hosts fold usage into. |
| `cache_notices` | a | Miss notices; the web files the same ones in `noted` (`web_view/component.gleam:853`). |
| `cache_outlook` | b | The terminal footer's label as of the last tick; the web keeps a label per chip. |
| `scrollback` | a | The bounded history window; history paging is Part 2's second item. |
| `notice` | a | The last line said to the operator; both hosts show one. |
| `queue_editor` | split | Of `queue_editor.State` (`tui/queue_editor.gleam:55`), `fetch`, `awaiting` and `request_id` correlate lane replies and move; `surface`, `selected`, `preview_scroll`, `draft` (an etui editor) and `message` stay. |
| `worktree` | a | A `session_view` state already. |
| `context` | a | A `session_view` state already. |
| `completion`, `completion_owner` | a | Operation boundaries the summary reads; `tui/completion_summary` imports nothing BEAM-only and moves. |
| `summary_surface`, `summary_scroll`, `summary_tab`, `summary_job_selected` | b | The summary panel's own state. |
| `jobs`, `jobs_observed_ms`, `jobs_refresh`, `jobs_awaiting`, `jobs_request`, `jobs_notice` | a | The live-jobs board and its one read in flight. |
| `nudges`, `nudges_refresh`, `nudges_awaiting`, `nudges_request` | a | The advisor's pending queue and its read; Part 2 draws it. |
| `summaries` | a | Summarizer labels and the reads still owed. |
| `goal`, `goal_refresh`, `goal_awaiting`, `goal_request`, `goal_report` | a | The goal board and its command slot. |
| `help_open`, `notes_open` | b | Terminal surfaces. |
| `diff_view`, `diff_scroll_offset`, `diff_row_count`, `diff_worktree_source` | b | The changes pane. |
| `note_board` | a | The last explicit notes read; a board is data. |
| `note_selected`, `note_mode`, `note_scroll` | b | The notes panel's cursor and mode. |
| `notes_requested` | a | The notes target waiting for the lane. |
| `overlay` | b | The modal surface with the keyboard; each variant is a terminal panel. |
| `models`, `skills`, `current_model` | a | What the daemon listed. |
| `workspace` | a | The session's path and branch; the page's header wants it. |
| `strands` | a | The captured strand list. |
| `agent_summary` | b | A string derived from `strands` by `tui/agents`, which imports etui; the terminal derives it at paint instead. |
| `reviewer_rows`, `agent_rows` | a | Both hosts observe them, the web in `fresh` (`web_view/component.gleam:743`). |
| `strip` | split | `roster` is `agent_roster.Roster` and moves; `focus` is the strip's keyboard cursor and stays (`tui/agent_strip.gleam:65` (`State`)). |
| `agent_messages` | a | Provenance-checked sends; the module imports nothing BEAM-only. |
| `advisor_history` | a | The advisor's captured board. |
| `todo_boards`, `todo_seed`, `todo_asked` | a | Each strand's board and the one seed read. |
| `active_strand` | a | The strand the composer addresses; the web's `strand` constant becomes this field. |
| `session`, `session_label` | a | Identity and catalogue name. |
| `local_options` | b | The launch's options, read by session creation. |
| `inbox` | c | `Inbox(source, Message)`; the source is the terminal's subject and the web's `Nil`. |
| `peer` | a | `Attached`, `Disconnected`, `Preview`, `Replaying`; reducers branch on it, and the type is `Peer` (`tui/session_model.gleam:412`). The web is always `Attached`. |
| `candidate` | b | The provisional attachment: a lane, a `Subject(Nil)` and an inbox inside a job slot, `attachment.Status` (`tui/attachment.gleam:92`). |
| `channel` | c | `Option(Channel(socket, recorder))`. |
| `captured` | a | The last cut and its view. |
| `last_capture`, `notices` | a | Live-delivery witnesses the fixtures read. |
| `daemon_host` | b | The control connection's key and build. |
| `control_request`, `activity_poll`, `reconnect`, `creation_key`, `configuring` | b | Daemon-control job slots; their replies are `weft.Pulled` values (`tui/job.gleam:395` (`ControlReply`)), which R6 keeps out of `session_view`. |
| `approvals` | a | Pending and settled reviews; both hosts project them. |
| `prompted_approvals`, `inspecting_approval` | b | Which questions the terminal's inspector has opened; the page draws every pending record as a card. |
| `unconfirmed` | a | The last mutation with a lost reply. |
| `next_attempt` | b | The next attachment attempt's identity. |
| `replay_state` | a | The two-slot replay of recorded lane updates; it holds lanes, so `attempt_replay.State` (`tui/attempt_replay.gleam:54`) becomes generic over the handles. |
| `replay_inbox` | c | `Inbox(source, attempt.Event)`. |
| `replay_error` | a | A malformed recording stops the shared drain. |
| `next_id` | a | The command counter both hosts encode with. |
| `usage` | a | The captured usage. |
| `generation_started_ms`, `output_rate_tps` | a | The generation clock and the rate it yields. |
| `agent_rail_visible` | b | A pane toggle. |
| `details_expanded` | a | The extent the shared line builders read through `presentation` (`tui/session_model.gleam:1002`), and `advance_generation_clock` checks it (`tui/tick.gleam:323`); a page will toggle it too. |
| `repaint_phase`, `activity_frame` | b | Frame-local paint state. |
| `activity_started_ms`, `activity_elapsed_s`, `generation_elapsed_s` | a | Elapsed readings the tick advances from the stamp; a chip shows the same figures. |
| `streams`, `tool_tails` | a | The live answer and tool tails. |
| `reading_lines` | b | Frozen transient rows while reading above the tail. |
| `scroll_offset` | b | The viewport. |
| `render_revision` | a | A presentation revision shared reducers bump (`tui/session_model.gleam:746` (`invalidate_transcript`)); the terminal compares it with `rendered_revision`, the web ignores it. |
| `rendered_revision`, `rendered_row_count`, `revealed_rows`, `rendered_anchors`, `rendered_gutters`, `record_gutters` | b | The row projection's outputs. |
| `compact_call_cache`, `compact_entry_cache` | a | Line caches keyed by `transcript_line.Line`, read by the shared line builders through `Presentation`. |
| `pending_records` | a | Legacy entries awaiting append. |
| `record_cache_valid` | a | Today a flag cleared at twelve write sites; it becomes a counter the terminal compares, in the shape of `record_cache_epoch`. |
| `record_cache_width`, `record_cache_strand`, `record_cache_details` | b | What the record rows were built for. |
| `frame_revision` | a | A presentation revision (`tui/session_model.gleam:765` (`invalidate_frame`)); every `append_system` bumps it. |
| `frame_debt` | b | Frame pacing. |
| `monotonic_time_ms`, `transport_time_ms` | b | The host's clocks; the shell reads them into the stamp. |
| `stamp` | a | The readings the step applies at. |
| `terminal` | b | This terminal's identity in a creation key. |
| `client_build` | a | The build the mismatch line compares; data, read once. |
| `last_frame_ms` | b | Frame pacing. |
| `activity_revision` | a | A revision `mark_activity` bumps from shared reducers (`tui/session_model.gleam:777` (`mark_activity`)); the terminal's quiet timer reads it. |
| `quiet_for_ms` | b | Idle pacing. |
| `connection_backlog` | a | Set by the shared drain from the inbox it holds (`tui/inbound.gleam:410` (`drain_connection`)); the terminal's poll reads it. |
| `recorder` | c | `Option(recorder)`. |
| `selection`, `selection_gutters`, `clipboard` | b | Mouse selection and where a copy goes. |
| `herdr_reporter`, `herdr_published` | b | The pane reporter, a host handle the terminal alone performs against; it stays in the terminal's record rather than becoming a type parameter because no shared reducer names it. |
| `outbox` | a | `List(Effect(socket, recorder))`; the terminal moves it into its own outbox at each call boundary, as `hold_channel` does for the lane. |
| `next_job`, `running` | b | Job keys and the runtime's table. |
| `record_cache_epoch` | a | Already the counter shape (`tui/session_model.gleam:386` (`record_cache_epoch`)). |
| `view` | b | The etui caches themselves. |

The shared record therefore holds no etui type, no `Subject`, no weft
type and no job slot. What it does hold from `tui/` today moves with it:
`completion_summary`, `agent_messages`, `attempt_replay` (made generic
over its lane's handles) and the `Peer`, `Interrupt`,
`UnconfirmedSubmission`, `SubmissionSource`, `GoalReport` and
`ConnectionBacklog` types from `tui/model`. `agents.summary`
(`tui/agents.gleam:816` (`summary`)) stays behind; the terminal derives
the footer string in its projection.

### The web view's `component.Model`

22 fields (`web_view/component.gleam:287` (`Model`)). Thirteen go away
because the shared record holds them; nine stay as the web's view or host
state.

| Field | Fate | Replaced by |
|---|---|---|
| `session_id` | goes | `shared.session`. |
| `expected` | stays (host) | Needed to start the lane at `Opened`. |
| `transport` | stays (host) | The relay and clock. |
| `lane` | goes | `shared.channel`. |
| `filed` | goes | `shared.inbox` with source `Nil`. |
| `shown` | goes | `shared.captured`. |
| `blocks`, `pieces` | stay (view) | Derived from the capture when `shared.render_revision` moves. |
| `agents`, `reviewers` | go | `shared.agent_rows`, `shared.reviewer_rows`. |
| `roster` | goes | `shared.roster`. |
| `cache`, `notices` | go | `shared.cache`, `shared.cache_notices`. |
| `strip` | stays (view) | Derived from the shared roster, rows and cache. |
| `approvals` | goes | `shared.approvals`. |
| `status` | stays (view) | Set from an edge: the first `Captured` and a `Failed` lane. |
| `clock` | goes | `shared.stamp`. |
| `timer`, `armed` | stay (host) | The deadline timer. |
| `notice` | goes | `shared.notice`. |
| `next_id` | goes | `shared.next_id`. |
| `drafts` | stays (view) | Bumped when `shared.pending_submission` clears on a `Sent`. |

## 2. The shared step's signature

No new package: the step lives in `session_view`, in modules named for
what they are today so the final slice is a rename, as phase 4's was
(`docs/adr/013-tui-effects-as-values.md`, the P4a addendum).
`session_view/model` holds the record and the helpers every reducer uses;
`session_view/msg` the message; `session_view/admission` the filing;
`session_view/inbound`, `session_view/outbound`, `session_view/surfaces`
and `session_view/commands` the reducers; and `session_view/step` the
three entry points.

### The message

```gleam
// session_view/msg
pub type Msg(source) {
  /// One event and the readings it is applied at; the step reduces it.
  Input(at: Stamp, event: Event)

  /// Traffic the host received, oldest first; the step files it and
  /// reduces nothing.
  Arrived(arrivals: List(Arrival(source)))
}

pub type Arrival(source) {
  Frame(source: source, message: connection_event.Message)
  Replayed(event: attempt.Event)
}

pub type Stamp {
  Stamp(now_ms: Int, transport_ms: Int)
}

pub type Event {
  /// The host's wake-up: the drains run, the lane ticks, the clocks advance.
  Ticked

  /// The operator acted, in the session's terms.
  Acted(command: Command)
}

pub type Command {
  Submit(text: String, attachments: List(composer.Attachment), delivery: operator.Delivery)
  Interrupt
  Stop(strand: String)
  Decide(id: String, seq: Int, choice: operator.Choice)
  Focus(strand: String)
  SelectModel(name: String)
  Clear
  OlderHistory
  RefreshWorktree
  Quit
}
```

What is a session message and what stays a host message follows from the
split above. `Arrived` and `Ticked` are session messages in both hosts.
The terminal's event variants (`Event`, `tui/msg.gleam:116`), which
are `KeyPressed`, `Pasted`, `Resized`, `Scrolled`, `Pressed`, `Dragged`,
`Released` and `Moved`, stay terminal messages: the key dispatch in
`tui/interaction` reads the overlay, the context surface, the queue
editor and the summary panel
before it decides what a key means (`tui/interaction.gleam:417`
(`update_key`)), and all four are terminal state. The terminal's key
handler therefore ends in one of three ways: it edits terminal state, it
opens or moves a terminal surface, or it produces a `Command` and hands
the shared step an `Acted`. The `JobReplied` arrival
(`tui/msg.gleam:83` (`JobReplied`)) stays terminal, because every slot
it is filed into does.

`Stamp` loses `wall_ms`. The one reader is the session creation key
(`tui/session_control.gleam:634` (`wall_ms`)), which stays in the
terminal, and the terminal's stamp gains it back beside the shared one. The web shell sets `now_ms` and `transport_ms` to the same
reading.

`Command` is the closed set of things an operator does to a session from
either host. The slash commands are not a variant of it. The shell parses
the draft with `command.parse_with_skills`, which is already in
`session_view`; a parse that names a terminal surface (`Help`, `Sessions`,
`Agents`, `Queue`, `Diff`, `Summary`, `Notes`, the context surfaces) is
acted on by the shell and never reaches the step, and every other parse is
wrapped as `Submit` with the raw text. The shared `submit_text` keeps its
arms for the session commands and answers a surface command with a
notice, which no shipped shell can trigger. Splitting `command.Command`
into a surface half and a session half would make that arm unrepresentable
and is a small follow-up (open question 7).

### The model, the effect and the entry points

```gleam
// session_view/model
pub type Model(socket, recorder, source) {
  Model(
    // the 80 shared fields, plus the shared halves of the three splits
    inbox: inbox.Inbox(source, connection_event.Message),
    replay_inbox: inbox.Inbox(source, attempt.Event),
    channel: Option(session_channel.Channel(socket, recorder)),
    recorder: Option(recorder),
    outbox: List(Effect(socket, recorder)),
    ..
  )
}

// session_view/step
pub type Effect(socket, recorder) {
  /// An output of the adopted lane: a frame, a close or a note.
  Lane(session_channel.Out(socket, recorder))

  /// A message that arrived with no lane to note it under.
  Recorded(recorder: recorder, message: connection_event.Message)
}

pub fn new(session: String, workspace: workspace.Context, inbox: Inbox(source, Message),
  replay_inbox: Inbox(source, attempt.Event), recorder: Option(recorder),
  client_build: build_identity.Identity, at: Stamp) -> Model(socket, recorder, source)

pub fn update(model: Model(socket, recorder, source), message: Msg(source))
  -> #(Model(socket, recorder, source), List(Effect(socket, recorder)))

pub fn attach(model: Model(socket, recorder, source),
  lane: session_channel.Channel(socket, recorder),
  inbox: Inbox(source, Message), at: Stamp) -> Model(socket, recorder, source)

pub fn next_due(model: Model(socket, recorder, source)) -> Option(Int)
```

Three type parameters rather than the two the lane has, because the inbox
is keyed by the subject a frame was read from and that subject is not the
socket (`tui/buffered.gleam:44` (`Inbox`)). The web passes `Nil` for
`recorder` and `source`, as it passes `Nil` for the lane's recorder today.

S2 found that one source parameter is not enough. The terminal reads the
connection inbox from a `Subject(connection_event.Message)` and the replay
inbox from a `Subject(attempt.Event)`, so the two sources have different
types, and the record takes a fourth parameter, `replay_source`, for the
replay inbox. The web passes `Nil` for it too. The shared record is
therefore `Shared(socket, recorder, source, replay_source)`, and the
entry points above gain the parameter with it.

`Effect` is two variants because those are the two effects the shared
reducers decide. Every `Channel` effect comes through `hold_channel`
(`tui/session_model.gleam:799` (`hold_channel`)), and the one `Record` a shared
reducer queues is the channelless arrival
(`tui/lane_fold.gleam:1040` (`receive_unlaned`), the arrival of a message with no lane). The input's own recording line is queued by `start_step` before
the reducer runs
(`tui/model.gleam:1102` (`start_step`)); the terminal's shell keeps
queuing it, ahead of the shared call, so the recording's order holds. The
terminal maps `Recorded(recorder, message)` to
`recording.append(recorder, recording.Arrived(message))`, which writes the
bytes it writes today.

`update` is `tui.step` with the terminal removed: an `Input` stores the
stamp, dispatches `Ticked` to the drains and `Acted` to the command arms,
runs the shared half of `settle_update` (the context, nudge and goal edges,
`surfaces.sync_context` and its siblings, which compare the model before
and after and read only shared fields; `tui/surfaces.gleam:850`
(`sync_context`)), and returns the outbox oldest first. An `Arrived`
files and returns nothing, as it does now. `attach` is the shared part of
adopting a lane: it stores the lane and inbox, resets the per-session
fields the adoption arm resets today (`tui/interaction.gleam:236`
(`candidate_outcome`), its `Adopted` arm), and marks the peer
`Attached`. `next_due` is
`option.then(model.channel, session_channel.next_due)`; a host that has
other reasons to wake, as the terminal does, combines it with its own
(`tui/tick.gleam:610` (`lane_wait`)).

### The shells

```mermaid
flowchart TB
    subgraph tshell["terminal shell: packages/tui"]
        tin(["etui event"]) --> tmsg["runtime.message<br/>stamp, keymap"]
        tmsg --> tstep["tui.step over TuiModel{shared, view}"]
        tstep -- "key edits a surface" --> tview[("view")]
        tstep -- "Acted(command) / Ticked / Arrived" --> supd["step.update(shared, msg)"]
        supd --> sm[("shared")]
        supd -- "List(step.Effect)" --> twrap["list.map(effect.Step)"]
        twrap --> tout["outbox: Step, Attachment,<br/>StartJob, Record, Herdr, ..."]
        tstep -- "before/after edges" --> tedge["reconnect on a failed lane,<br/>open the approval inspector,<br/>reset overlays on a new session"]
    end
    subgraph wshell["web shell: packages/web_view"]
        win(["Arrived / Ticked / Opened"]) --> wnow["at = transport.now()"]
        wnow --> wupd["step.update(shared, Arrived)<br/>then step.update(shared, Input(Ticked))"]
        wupd --> wperf["perform: one effect.from<br/>over Lane outputs"]
        wupd --> wrearm["rearm(step.next_due)"]
        wupd --> wderive["derive blocks, pieces, strip<br/>when render_revision moved"]
        op["operator_page: Observed(component.Msg)<br/>Submitted -> Acted(Submit)<br/>Decided -> Acted(Decide)"] -- "effect.map(Observed)" --> win
    end
```

The terminal keeps `tui.step(msg.Msg, TuiModel)`. `TuiModel` is
`TuiModel(shared: step.Model(Connection, Recorder, Subject(Message)),
view: View)`, where `View` absorbs the 65 terminal fields and the
terminal halves of the splits. A terminal reducer that calls into the
shared step stores the result through `hold_shared`, the same discipline
as `hold_channel`: the shared outbox is moved into the terminal's at the
point of the call, so a step that decides a lane close, then a terminal
`Discard`, then a lane write (`tui/interaction.gleam:333` (`Discard`))
still performs them in that order. The terminal's effect type gains one
variant, `Step(step.Effect(Connection, Recorder))`,
and `perform_io` gains two arms (`tui/runtime.gleam:433`
(`perform_io`)).

The web's `component.Model(socket)` becomes
`WebModel(shared: step.Model(socket, Nil, Nil), view: WebView)`.
`component.update` reads the clock once at its top,
`let at = model.view.transport.now()`, and builds the stamp from it; the
selector mappings that read `transport.now()` today, in `open`
(`web_view/component.gleam:362`) and `arm`
(`web_view/component.gleam:400`), stop carrying `at`, and the read in
`commanded` (`web_view/component.gleam:1392`) goes with them. This is the
terminal's `runtime.stamp` shape (`tui/runtime.gleam:80` (`stamp`)). An
`Arrived`
becomes two shared calls in one Lustre message, `Arrived` then
`Input(Ticked)`, which is the delivery ADR-014 describes for a host that
wakes on arrival and still one render per burst. `rearm` stays as it is,
reading `step.next_due` (`web_view/component.gleam:1469` (`rearm`)).
`operator_page` keeps its `Observed` and `effect.map` layering over the
component (`web_view/operator_page.gleam:99` (`update`)); its
`Submitted` and `Decided` become `Acted(Submit(..))` and
`Acted(Decide(..))` after the page's own checks on the draft's length and
emptiness, which are the page socket's limits and not the session's
(`web_view/component.gleam:1249` (`submit`)).

## 3. Admission and reducers

### Admission

`admission.admit` splits along its arms (`tui/admission.gleam:64`
(`admit_one`)). `Frame` and `Replayed` move: a frame whose source is the
shared inbox's is pushed, a replayed event is pushed, and a frame from any
other source is dropped, which is the S2 rule. `JobReplied` stays in the
terminal with the slots it fills. The terminal's `runtime.receive`
(`tui/runtime.gleam:123` (`receive`)) already admits the jobs first and
the frames after; it now routes the waiting attempt's frames to
`attachment.push_frame` itself and hands the rest to the shared step as
`Arrived`. The relative order of a candidate's frames and the adopted
inbox's frames does not matter, since they enter different buffers, and
each buffer keeps its own order. `admission_test`'s twenty generated runs
hold across the change because the reducers take from the same buffers at
the same points.

### Reducers that move whole

These read and write shared fields only, or read a terminal field that
the split turns into a shared one. The list is incomplete for the lane and
event folds and the tick; section 5's S3 entry lists the terminal state
they reach that it misses.

- The lane fold: `tick_channel`, `apply_channel_update`, `reconcile_cut`,
  `request_decisions`, `apply_cut` and `render_cut`
  (`tui/inbound.gleam:154` (`tick_channel`) through
  `tui/lane_fold.gleam:647` (`render_cut`)), less the four writes named
  below.
- The connection drain and the event fold: `drain_connection`,
  `handle_connection_message`, `handle_presentation_message`,
  `apply_event` and everything under it: streams, tool tails, usage, the
  cache watch, summaries, schedules, skills and models
  (`tui/inbound.gleam:394` (`drain_connection`),
  `tui/event_fold.gleam:80` (`apply_event`)).
- Submission bookkeeping: `send_frame` (`tui/outbound.gleam:52`),
  `send_via`, `apply_submission`, `discard_own_turn` and
  `mutation_refusal`, less the `clear_composer` call and the queue
  editor's `request_id`.
- The command arms: `interrupt_active` (`tui/submit.gleam:859`),
  `stop_strand`, `switch_active_strand` (`tui/submit.gleam:1060`),
  `select_model`, `decide` (`tui/inbound.gleam:366`), `send_prompt_to`,
  `cancel_pending` and `service_history`.
- The auxiliary reads and their edges: every `service_*_read` from
  `service_todo_seed` (`tui/surfaces.gleam:113`) onward, `sync_context`,
  `sync_advisor_nudges`, `sync_goal`, `receive_jobs`, `receive_goal` and
  `receive_advisor_nudges`, less `notes_target` and `notes_surface`.
- The tick's clocks: `advance_activity_indicator` (`tui/tick.gleam:265`)
  and `advance_generation_clock` read the stamp and shared fields;
  `drain_replay` (`tui/tick.gleam:226`) and `apply_replay_change`.
- `queue_owner`, `queue_namespace`, `active_strand_phase`,
  `append_system`, `append_error`, `append_notice`, `start_step`, `emit`,
  `record`, `hold_channel` and `presentation` from `tui/model`.

### Reducers that split, and the two shapes

A reducer that touches both kinds of state is cut in one of two ways, and
which way follows from which side decides.

**The shared side decides; the shell reacts to an edge.** The shared
reducer keeps its decision and drops the terminal write. The terminal
shell, after the shared call, compares `before.shared` with
`after.shared` and makes the terminal write itself. This is the shape
`surfaces.sync_context(before, after)` already has
(`tui/surfaces.gleam:1034` (`sync_context`)) and the shape
`refresh_render_cache(before, after)` has (`tui/projection.gleam:48`
(`refresh_render_cache`)); the shell gains one more before-and-after
pass beside them. It is right when the terminal write is a consequence of
a session fact.

**The shell decides; the shared step takes a command.** The terminal
reducer keeps its dispatch on terminal state and hands the shared step a
`Command` or a call for the session half. It is right when the terminal
knows something the session does not, such as which pane is open.

The worst cases in the code, and the cut for each:

1. **`render_cut`** (`tui/lane_fold.gleam:647` (`render_cut`)) writes 31
   fields; four touch terminal state. `strip: agent_strip.observe(..)`
   becomes `roster: agent_roster.observe(..)`, the strip's focus being
   untouched by a capture. `cache_outlook` is reset when the active
   strand's watch is gone; the shell's edge does the same on
   `before.shared.cache != after.shared.cache`. `strand_workspaces` is
   pruned of retired strands; the shared half prunes its history dict, and
   the shell prunes its editor dict on the same `strands` edge.
   `agent_summary` is dropped and derived at paint. The other 27 writes
   are shared and the function moves as it is.

2. **`select_workspace`** (`tui/event_fold.gleam:1482`
   (`select_workspace`)) parks the editor, the history window, the
   viewport and the anchors under one key and restores another's. It
   splits into `step.select_workspace`, which parks and restores
   `scrollback` and clears the per-session boards, and a terminal
   `park_editor` that parks `input`, `attachments`' editor half,
   `history`, `scroll_offset`, `rendered_anchors` and the viewport height
   under the same key. Both run on the same edge, `before.shared.session`
   and `active_strand` against `after`'s, so a switch from a strand key,
   the strip, a capture that renames the session or a replay's `Adopt`
   parks both halves. `restore_returned_draft`
   (`tui/event_fold.gleam:514` (`restore_returned_draft`)) is the one
   shared reducer that writes a parked editor: the returned text becomes a
   shared field, `returned_drafts: List(#(strand, text))`, and the shell
   appends it to the editor it owns.

3. **`apply_channel_update`'s `Failed` arm** (`tui/lane_fold.gleam:425`
   (`Failed`)) closes a `GoalInspector` overlay, fails the
   worktree navigator and starts the reconnect job (`tui/inbound.gleam:195`
   (`begin_reconnect`)). The shared arm keeps the peer transition, the
   cleared reads and the error line. The shell's edge on
   `before.shared.peer == Attached && after.shared.peer == Disconnected`
   closes the overlay and starts the job, which is a `StartJob` the
   terminal already owns. The same edge covers the arm of
   `handle_presentation_message` for `Closed` (`tui/lane_fold.gleam:1050` (`receive_unlaned`)).
   *As landed (S3d′):* recorded facts rather than a comparison of `peer`:
   `GoalReleased` and `ConnectionLost` on `Failed`, `ConnectionLost` on
   `Closed`, applied after the update.

4. **`apply_submission`** (`tui/outbound.gleam:112`
   (`apply_submission`)) writes `queue_editor.request_id` on a sent
   queue command and clears the composer on a sent prompt. The queue
   editor's lane correlation moves to the shared half of the split, so
   that write stays in the reducer. The composer clear becomes an edge:
   `pending_submission` goes from `Some(ComposerSubmission)` to `None`
   with a `Sent` disposition, and the shell clears its editor and
   remembers the text in the input history. The web's `drafts` counter is
   the same edge, so the two hosts empty their editors on the same fact.

5. **`submit_text`** (`tui/submit.gleam:147` (`submit_text`)) parses
   the draft and dispatches over `command.Command`, opening overlays for
   `Help`, `Models`, `Sessions` and the panels and sending frames for the
   rest. The shell parses first, as described under the message: surface
   commands are handled in the terminal, `Models` opens the selector and
   then hands the step a `Submit` so the `models` frame is still sent, and
   every other parse is a `Submit` the shared `submit_text` dispatches as
   it does today. `submit` itself (`tui/submit.gleam:66` (`submit`))
   stays in the terminal because it reads `model.input`, and its
   `pending_submission` marker moves into the shared `Submit` arm.

6. **`present_pending_approval` and `close_settled_approval`**
   (`tui/inbound.gleam:567` (`present_pending_approval`),
   `tui/lane_fold.gleam:594` (`close_settled_approval`)) open and close the
   approval inspector from the projected approvals. Both are terminal:
   the page has no inspector and draws every pending record. They become
   the shell's edge on `after.shared.approvals`, run after every shared
   call that can change it, which is where `apply_cut` and the `LookedUp`
   arm call them today. `prompted_approvals` moves to the view with them.
   `decide_captured_approval` (`tui/inbound.gleam:337`
   (`decide_captured_approval`)) becomes the inspector producing
   `Acted(Decide(id, seq, choice))`, with `AllowForSession` mapped through
   `operator.Choice`, which already has it. *As landed (S3d′):* the close
   is decided in the shared fold, from the approval the host passes in as
   `Surroundings.reviewing`, because the decision writes a transcript line
   that later lines of the same cut must follow; the dialog's close
   (`ApprovalSettled`), the presentation (`ApprovalsPresented`) and the
   lookup's inspector (`LookupAnswered`) are facts the terminal applies
   after the update.

7. **`settle_update`** (`packages/tui/src/tui.gleam:1922`
   (`settle_update`)) runs nine calls after every event. Three are
   shared and move into `step.update`'s own settle: `sync_context`,
   `sync_advisor_nudges`, `sync_goal`. Six are terminal and stay:
   `request_visible_worktree` on a diff pane appearing, which becomes
   `Acted(RefreshWorktree)` because only the shell knows the pane appeared
   (`tui/inbound.gleam:1037` (`request_visible_worktree`) reads
   `layout.diff_shown`); `request_history_for_view`, which becomes
   `Acted(OlderHistory)` for the same reason
   (`tui/interaction.gleam:1798` (`request_history_for_view`) reads the
   viewport); `publish_herdr`; `refresh_render_cache`; the viewport snap;
   and `refresh_frame_cache`. The compile-time boundary the comment above
   `apply_input` describes keeps its shape: the shared `update` applies
   its settle to a parameter, and the terminal's `settle_update` applies
   its remaining steps to `updated` as it does now
   (`packages/tui/src/tui.gleam:1842` (`apply_input`)).

8. **The tick** (`tui/tick.gleam:126` (`update_tick`)) is a fixed
   order of drains: replay, strip, activity, control, candidate,
   reconnect, activity poll, configuration, connection, then the settle
   chain. The order is kept by having the terminal's tick call the shared
   `Ticked` at the point where the connection drain sits today, after the
   terminal's job drains and the candidate's poll. `tick_strip`
   (`tui/inbound.gleam:1141` (`tick_strip`)) reads the strip's focus and
   stays; `advance_cache_outlook` (`tui/tick.gleam:357`
   (`advance_cache_outlook`)) writes the footer label and stays, reading
   `shared.cache` and the stamp. `settle_tick`'s quiet-time and backlog
   bookkeeping stays terminal (`tui/tick.gleam:156` (`settle_tick`)).

9. **Key dispatch** (`tui/interaction.gleam:1085`
   (`update_conversation_key`)) reads `help_open`, `notes_open`, the
   overlay and the editor, and calls both kinds of reducer. It stays a
   terminal function over `TuiModel`, and the calls it makes into shared
   reducers become `Acted` commands or direct calls through `hold_shared`.
   `update_ready_key`'s order, Escape before the drain
   (`tui/interaction.gleam:1446` (`update_ready_key`)), is kept because
   the shell decides when to call the shared drain, as it does today.

## 4. What the web view deletes

Once the component drives the shared step, its orchestration is the
shell's `update`, `perform` and `rearm`, and its view derivation. The
table maps each function in `web_view/component.gleam` to what replaces
it.

| Today | After | Where the logic lives |
|---|---|---|
| `update`'s `Opened` arm (`web_view/component.gleam:356` (`Opened`)) | `step.attach(shared, session_channel.start(socket, expected, now: at), inbox.new(Nil), stamp)`, then `Ticked` | `session_view/step` |
| `Refused` | view `status: Ended(reason)` | shell |
| `Arrived` (`web_view/component.gleam:367` (`Arrived`)) | `step.update(Arrived(frames))` then `step.update(Input(stamp, Ticked))` | `session_view/step` |
| `Ticked` | `step.update(Input(stamp, Ticked))`, then the strip's label check | `session_view/step`, shell |
| `reduce` (`web_view/component.gleam:542`), `drained`, `take_filed`, `received` | the shared `Ticked`: `drain_connection` then `tick_channel` | `session_view/inbound` |
| `apply` (`web_view/component.gleam:639`) | `apply_channel_update` | `session_view/inbound` |
| `captured` (`web_view/component.gleam:736`), `fresh`, `recaptured` | `reconcile_cut`, `apply_cut`, `render_cut` | `session_view/inbound` |
| `used` (`web_view/component.gleam:790`), `settle_cache`, `settle_pushed`, `noted` | `receive_usage` (`tui/event_fold.gleam:879`), `settle_usage`, `settle_pending_cache`, `note_cache_miss` | `session_view/inbound` |
| `relaned` (`web_view/component.gleam:957`), `restripped`, `strip_of`, `outlook`, `running_ms`, `strands` | `derive(before, after)`: rebuild blocks, pieces and the strip when `shared.render_revision` moved | shell, view state |
| `ticked` (`web_view/component.gleam:1192` (`ticked`)) | the same per-chip label comparison over `shared.cache` and `shared.stamp` | shell |
| `settled` (`web_view/component.gleam:1219` (`settled`)) | `apply_submission`; `drafts` bumps on the `pending_submission` edge | `session_view/outbound`, shell |
| `submit` (`web_view/component.gleam:1249` (`submit`)) | the page's empty and length checks, then `Acted(Submit(text, [], delivery))` | shell, `session_view/commands` |
| `decide` (`web_view/component.gleam:1289` (`decide`)) | `Acted(Decide(id, seq, choice))`; the drawn-sequence check is `operator.drawn` inside the shared arm | `session_view/commands` |
| `commanded` (`web_view/component.gleam:1392`), `flushed` | the shell's `update`: stamp, shared call, `perform`, `rearm` | shell |
| `perform` (`web_view/component.gleam:1431` (`perform`)) | unchanged, over `step.Effect(socket, Nil)`: `Lane(Transmit)`, `Lane(Shut)`; `Note` and `Recorded` are `Nil` | shell |
| `rearm` (`web_view/component.gleam:1467` (`rearm`)) | unchanged, reading `step.next_due(shared)` | shell |
| `open`, `arm`, `waiting`, `init`, `new` | unchanged, less the clock reads in the mappings | shell |
| `activity` (`web_view/component.gleam:1595` (`activity`)) | `model.active_strand_live(shared)` | `session_view/model` |
| `lines`, `rows`, `pieces`, `strip`, `addressed`, `status`, `pending`, `notice`, `drafts`, `attachment`, `lane`, `session_id` | accessors over `{shared, view}` | shell |
| `view`, `heading`, and the region modules `web_view/view/heading`, `strip` and `lane` | unchanged | view |

What the page gains without new code: strand focus (`Acted(Focus(strand))`
switches the column, which is Part 2's first item), history paging
(`OlderHistory`), the live answer and tool tails (`streams` and
`tool_tails` are shared and `transcript_lines` already draws them), the
notes, goal, jobs and nudge boards, and a build-mismatch line. Each still
needs its view.

## 5. Slicing

Six slices, each landing green on its own, in the way phase 2's S1 to S6
did (`docs/adr/013-tui-effects-as-values.md`, the phase 2 addenda). The
proofs named are the ones the issue requires plus the ones each slice
puts at risk.

**S1: the two records, no move.** `tui/model` gains `Shared` and
`TuiModel(shared, view)`; every reducer changes its field paths and
nothing else. `record_cache_valid` becomes a counter here, since it is a
field-shape change with no behaviour, and `agent_summary` becomes a
projection-time derivation. The three splits are made: `strand_workspaces`
into two dicts, `queue_editor` into its lane half and its editor half, and
`strip` into `roster` and `strip_focus`. `hold_shared` is introduced and
every terminal reducer that calls a shared one stores through it.
*Proves:* the whole `tui` suite; the replay snapshot `replay-transcript.txt`
and the golden recording (`packages/tui/test/recording_effects_test.gleam:53`
(`a_scripted_session_records_the_golden_bytes_test`)); `loom replay
--all --plain` byte-identical between the two builds;
`scripts/tui_perf.sh events` and `burst 500` within noise (the idle tick
was 7,478 reductions at the last measurement). The P model is untouched.
*Size:* about 40 modules and a few thousand changed lines, all field
paths; the largest mechanical slice.

**S2: the handles become type parameters.** `Shared` becomes
`Shared(socket, recorder, source)`; `channel`, `inbox`, `replay_inbox`
and `recorder` take the parameters; `attempt_replay.State` becomes
generic; the shared `Effect(socket, recorder)` with `Lane` and `Recorded`
is split out of `tui/effect.Effect`, which gains `Step(..)`. `Stamp`
loses `wall_ms` to the terminal. *Proves:* `effects_test`,
`recording_effects_test`, `session_channel_property_test` (unchanged by
construction: it drives the lane directly), and the P model's ten cases
at their current schedule count. *Size:* `tui/model`, `tui/effect`,
`tui/runtime`, `tui/attempt_replay`, `tui/terminal_lane`; a few hundred
lines.

*As landed:* three departures from the plan above. `Shared` takes four
parameters, `Shared(socket, recorder, source, replay_source)`, because the
terminal's two inboxes are read from subjects of different types (section
2); the terminal binds them in a `TerminalShared` alias, and `Model.shared`
has that type. The shared effect type is `tui/step_effect.Effect(socket,
recorder)`, a module that imports only `session_view`, so S4 moves it into
`session_view/step` unchanged. And the outbox moved from `Shared` to
`View` rather than taking the shared effect type: every reducer still
takes the whole model, the outbox is still the step's one queue of
terminal effects with the session effects wrapped as `effect.Step`, and a
single queue is what keeps their relative order. A shared outbox of step
effects comes back in S3, with `hold_shared`, when a reducer first runs
over `Shared` alone. `Stamp` lost `wall_ms` as planned: `msg.Input`
carries it beside the stamp and the step stores it as `View.wall_ms`.

**S3: the reducer cut.** The largest semantic slice. It was planned as
three landings, S3a to S3c, and re-sliced into five, S3a′ to S3e′, before
any code landed. The owner approved the re-slice on 2026-09-28.

*Why it was re-sliced.* The plan had S3a cut the lane fold and the event
fold down to `Shared`, with three terminal writes pulled out as edges
(`render_cut`, the `Failed` arm and `select_workspace`), and left the
submission bookkeeping to S3b and the auxiliary reads to S3c. The fold
cannot be cut first. `tick_channel`, `apply_channel_update` and
`apply_event` call each other, so everything they reach must take
`Shared` in the same landing, and a function over `Shared` cannot call a
function over the whole model. A census of what the fold reaches, taken
on `main` at `7e0e8be7c`, found two kinds of problem.

The first kind is calls into reducers the plan gave to later landings:

- `outbound.apply_submission`, `send_frame`, `send_via`,
  `discard_own_turn` and `mutation_refusal`, planned for S3b;
- `surfaces.receive_jobs`, `receive_goal`, `receive_advisor_nudges`,
  `retire_delivered_nudges`, `refuse_goal` and `service_worktree_read`,
  planned for S3c;
- `reconcile_cut` calls `request_visible_worktree`, which reads
  `layout.diff_shown`, and which the plan turned into an edge only in
  `settle_update`;
- `reconcile_cut`, `apply_cut` and the `LookedUp` arm call
  `close_settled_approval` and `present_pending_approval`, which the plan
  made edges in S3b.

The second kind is terminal state the fold reads or writes that section 3
does not list:

- the queue editor, written in `apply_channel_update` (the
  `edit_queued_input` acknowledgement, `UnknownOutcome` and `Failed`), in
  `apply_event`'s `QueuedInputSnapshot` arm, in `retain_queue_selection`,
  in `apply_request_refused` and in `apply_submission`. S1 was to split
  `queue_editor` and kept it whole in `View` instead;
- `agent_summary`, written in `render_cut` and in the `FullSnapshot`,
  `StrandsSnapshot` and `OperationChanged` arms. S1 was to derive it at
  paint time and kept it as a `View` field instead;
- overlay and panel state: the notes selection and scroll in the
  `NotesSnapshot` arm, through `render.selected_note`,
  `surfaces.notes_target` and `surfaces.notes_surface`; the model
  selector's list in `ModelsSnapshot`; `reconcile_agent_message_selection`;
  `inspect_looked_up`'s `inspecting_approval`; the goal inspector in
  `receive_goal` and `refuse_goal`; and `summary_job_selected` in
  `receive_jobs`;
- `View.daemon_host`, read by `render_cut` for the build-mismatch lines;
- the composer and `strand_workspaces`, written by
  `restore_returned_draft` (section 3 plans a shared `returned_drafts`);
- `local_options` and `reconnect`, read by `begin_reconnect`, which also
  starts a job (section 3 plans an edge);
- `quiet_for_ms`, written by `mark_activity` at six sites in the fold;
- `record_gutters` and `scroll_offset`, written by the `FullSnapshot` arm;
- in the tick, `drain_replay` calls `select_workspace`, `apply_cut` and
  `apply_channel_update` and writes `note_selected`, `prompted_approvals`,
  `inspecting_approval` and `scroll_offset`; and
  `advance_activity_indicator` writes `activity_frame`, which section 3
  says it does not.

So cutting the fold first would have brought most of S3b and S3c, and the
two record splits S1 left, into one pull request. The re-slice orders the
landings by what calls what, from the functions the fold calls up to the
fold and then the commands above it. It also picks up the S1 debt: the
`queue_editor` split and the `agent_summary` derivation land in S3b′.

*S3a′: `hold_shared` and the helpers over `Shared`.* The shared record
gets an outbox of step effects and `hold_shared`, the discipline that
drains it; the model helpers that touch only session state take
`Shared`; admission's frame and replay arms take `Shared`; and the tick's
session clocks take `Shared`.

*S3b′: the record shapes S1 left.* `queue_editor` splits into its lane
correlation (`fetch`, `awaiting`, `request_id`), which moves to `Shared`,
and its editor, which stays in `View`. `agent_summary` is derived at paint
time. `returned_drafts` becomes a shared field, and the daemon's build
becomes shared data rather than a read of `View.daemon_host`. These are
field-shape changes; no reducer changes its signature.

*S3c′: what the fold calls.* The submission bookkeeping (`send_frame`,
`send_via`, `apply_submission`, `discard_own_turn` and
`mutation_refusal`) takes `Shared`, with the composer clear as the edge
section 3 describes. The `surfaces` receivers (`receive_jobs`,
`receive_goal`, `receive_advisor_nudges`, `retire_delivered_nudges` and
`refuse_goal`) and the `service_*` reads take `Shared`, with the goal
inspector and the summary's job cursor as edges.

*S3d′: the fold.* The lane fold, the event fold and `drain_replay` take
and return `Shared`. Every terminal write listed in the census becomes an
edge in `settle_update`: the approval inspector's open and close and
`inspect_looked_up`; the notes, agent, model-selector and goal overlays;
`cache_outlook`; the workspace park and prune (`select_workspace`); the
reconnect on `Failed` and `Closed`; the visible-worktree refresh; and the
returned drafts.

*S3e′: the commands.* The `session_view`-shaped `Msg`, `Event` and
`Command` types land in `tui/msg`. The command arms (`interrupt_active`,
`stop_strand`, `switch_active_strand`, `select_model`, `decide`,
`send_prompt_to`, `cancel_pending` and `service_history`) take `Shared`.
`submit_text` splits into the shell's parse and the shared dispatch, with
`command.Command` split into surface and session variants (question 7).
`step.update`'s own settle is formed from `sync_context`,
`sync_advisor_nudges` and `sync_goal`.

*Proves:* after each landing, the `tui` suite, `admission_test`'s
generated runs, `poll_timeout_test`, `runtime_receive_test`,
`session_pushed_test`, the two replay checks, and `erlc +time` on `tui`,
`tui@inbound`, `tui@interaction` and `tui@submit` against the figures in
the phase 3 addendum. *Size:* S3a′ is a new module and a few hundred
changed lines. The later landings move two to three thousand lines
between functions in `inbound`, `outbound`, `submit`, `surfaces`, `tick`,
`interaction` and `tui.gleam`, and add few.

*S3a′ as landed.* `Shared` and the six types it names (`Peer`,
`Interrupt`, `SubmissionSource`, `UnconfirmedSubmission`,
`ConnectionBacklog` and `GoalReport`) moved from `tui/model` into a new
module, `tui/session_model`. The move was needed because a function over
`Shared` and the terminal's function of the same name over the whole
model cannot both live in `tui/model`, and the terminal's form cannot call
into a module that imports `tui/model`. `tui/session_model` imports
nothing of the terminal, and it is the module S4 renames to
`session_view/model`. `TerminalShared`, the terminal's binding of the four
handle parameters, stays in `tui/model`.

`Shared.outbox` holds the `step_effect.Effect` values a function over
`Shared` decides, newest first. `tui_model.hold_shared(model, shared)`
stores the result of every such call: it moves the queued effects into
`View.outbox`, wrapped as `effect.Step`, at the point of the call, and
empties `Shared.outbox`. A lane close, a terminal `Discard` and a lane
write therefore keep the order they were decided in. `hold_shared` also
resets `View.quiet_for_ms` when `activity_revision` moved, because the
shared `mark_activity` only bumps the revision.

The writers `append_system`, `append_error`, `append_notice`,
`invalidate_transcript`, `invalidate_frame`, `mark_activity`,
`hold_channel` and `record_arrival` are defined over `Shared` in
`tui/session_model`. Their forms in `tui/model` remain, each a
`hold_shared` of the shared call, because most reducers still take the
whole model. The readers `queue_owner`, `queue_namespace`,
`active_strand_live`, `active_strand_phase`, `active_interrupt`,
`is_known_strand` and `presentation` have no terminal form; their callers
pass `model.shared`. Admission's shared half is `admission.file_frame`
and `admission.file_replayed`; a frame the adopted inbox refuses is then
offered to the attempt, as before. The tick's shared half is
`advance_activity_clocks` and `advance_generation_clock`; the glyph's
animation frame stays in the terminal's `advance_activity_indicator`.

Two things the plan had in S3a are not in S3a′: the `session_view`-shaped
message types, which land with their first user in S3e′, and every
`settle_update` edge, which lands with S3d′.

One effect is visible in the counters and not on screen. Before, a tick
that moved both the glyph and the elapsed seconds bumped `frame_revision`
once; each half now bumps it for its own change, so such a tick bumps it
twice. The revision's only reader in the running client is
`tick.refresh_frame_cache`, which runs in `settle_update` after the whole
event and compares the revision for equality with the one it last
painted. The two tests that read it compare with `>` across a reducer
call, or with `==` across admission, which touches no clock. No reader
runs between the two bumps, so none can tell them from one. `main` already
bumped it twice in a tick that moved the generation clock under a shown
reasoning row and the indicator, so the count per tick was never fixed.

Nothing in the types stops a terminal reducer from storing a shared result
without `hold_shared`. The test driver `tui_test/stepping.step` therefore
asserts that `Shared.outbox` is empty after every step it drives, which
catches a result stored without `hold_shared` when it is the last shared
call of the step. When a later `hold_shared` in the same step follows it,
that call flushes the stranded effects, which are then performed late
rather than lost, and the check sees an empty outbox; the
effect-order tests in `effects_test` and `recording_effects_test` are what
cover that.

Measured against `main` at `7e0e8be7c`. The `tui` suite passes 960 tests
on both. Both committed recordings replay byte-identical with `--all
--plain`, and the three synthesized `tui_perf` replays end on identical
frames. The phase 3 admission mutation, "admission files a frame from any
subject", fails the same eight tests on `main`, when applied to
`file_frame`, and when applied to the terminal's routing of a refused
frame (question 9). `scripts/tui_perf.sh`, median of three alternating
runs: an idle tick costs 7,509 reductions and 9,411 words against 7,492
and 9,359 (+0.2% and +0.6%), a 64-frame tick 224,668 reductions against
223,884 (+0.35%), and a 500-frame burst 5,530 reductions per frame
against 5,502 (+0.5%). With `TUI_PERF_MIN_HEAP=4000000` the reductions
and words are the same to within 0.4%. `erlc +time` on `tui`,
`tui@inbound`, `tui@interaction` and `tui@submit` is unchanged at 0.41 s,
2.2 s, 2.5 s and 0.95 s, and `tui@model` fell from 0.25 s to 0.17 s; a
clean build of the `tui` package takes 2.7 to 3.0 s on both.

*S3b′ as landed.* The four record shapes, each with no change to what
the terminal sends or draws.

The queue editor is split. `fetch`, `awaiting` and `request_id` moved out
of `queue_editor.State` into a new module, `tui/queue_request`, whose
`State` is `Shared.queue_request`; the module imports no etui, and its
`Fetch` type moved with it. `receive` there is the check that a
queued-input document answers the read this client issued, and it settles
that read; `queue_editor.receive` then fills the editor, and runs only
when the check passes. `queue_editor.refused` now writes only the
editor's message and delivery lock, and each of its three callers (the
lane's `Failed`, a refusal that matches the request ID, and a frame the
lane did not send) also returns `Shared.queue_request` to
`queue_request.new()`, which is what `refused` did to the three fields
before. The acknowledged save resets both halves, `UnknownOutcome` writes
only the editor, and a sent queue command writes only the request ID. The
draft's `Delivery` lock (`Editable`, `Saving`, `Unknown`) stayed with the
draft in `View`, as section 1's table has it: it is part of the draft the
etui editor holds, and the fold's writes to it, on `UnknownOutcome` and
on a refusal, become edges in S3d′ with the rest of the editor's writes.

`agent_summary` had no reader. The footer already derived its agent count
at paint, from `agents.summary_rows(layout.displayed_agents(model))` in
`render`, so the field's seven writers were dead: at launch, in the
replay and live bases (`replay_steps`, `live_base`) and on `FullSnapshot`,
`StrandsSnapshot` and `OperationChanged` it was written from the strands
with the legacy `agents.summary`, and in `render_cut` from the agent rows
with `summary_rows`. The field and its writes are
removed. There is nothing to reproduce, so no choice between a derived
value and a shared field arose, and no output can change.

`Shared.returned_drafts` holds a held prompt the daemon returned, as a
`ReturnedDraft(session, strand, text)`, oldest first.
`restore_returned_draft` appends to it and appends the notice, both
shared writes, and then `inbound.restore_returned_drafts`, the terminal's
half, moves each entry into the composer or the strand's parked
workspace and empties the list. It is called in the same function, so
the text reaches the editor at the same point as before; S3d′ moves the
call into `settle_update`. The entry carries the session, which
section 3's `List(#(strand, text))` did not: once the terminal's half
runs after the shared write rather than inside it, the parked key has to
be the session the prompt came back in.

`Shared.daemon_build` is the build the daemon's `hello` named, as a
`build_identity.Identity`. `tui_model.adopt_daemon` writes it together
with `View.daemon_host`, and both places that adopt a control connection,
`runtime.adopt_control` and the reconnect's reply, go through it, so the
two fields describe the same daemon. `daemon_build_lines` takes the
identity, and `render_cut` no longer reads `View`.

Measured against `main` at `1b5946eda`. The `tui` suite passes 960 tests
on both; the queue editor tests assert on `Shared.queue_request` where
they asserted on the editor's three fields, and two existing tests gained
an assertion each, on `daemon_build` and on an emptied `returned_drafts`.
Both committed recordings replay byte-identical with `--all --plain`, and
the synthesized `tui_perf` replays of 64, 512 and 4,096 frames end on
identical frames. The P model's ten cases find no bug at 30,000
schedules each. `scripts/tui_perf.sh`, median of three alternating runs:
an idle tick costs 7,509 reductions on both and 9,423 words against
9,411 (+0.13%), a 64-frame tick 226,149 reductions against 226,153, and a
500-frame burst 5,513 reductions per frame against 5,530 (−0.3%). With
`TUI_PERF_MIN_HEAP=4000000` the reductions are identical and the words
within 0.21%. The shipped fixtures, the two `tui_shipped_*` suites and
the seven `daemon_shipped_*` ones, pass against each build's `bin/loomd`
with `HOME` pointed at an empty directory. `erlc` on the generated
modules, median of three alternating runs of wall time: `tui` 0.42 s
against 0.45 s, `tui@inbound` 1.84 s against 1.74 s, `tui@interaction`
2.05 s against 1.93 s, `tui@submit` 0.88 s against 0.85 s, and
`tui@outbound`, `tui@surfaces`, `tui@model` and `tui@session_model` each
within 0.05 s. The rises of about 6% in `inbound` and `interaction` follow
the queue editor's writes, which now update two records where they
updated one; no settle chain was added. Lint finds the same census on
both, with no error-tier finding.

*S3c′ as landed.* The functions the fold calls take `Shared` alone. In
`tui/outbound` these are `send_frame`, `send_via`, `apply_submission`,
`discard_own_turn`, `mutation_refusal`, and the two helpers beside them,
`waiting_notice` and `mutating_submission`. In `tui/surfaces` they are the
receivers `receive_jobs`, `receive_goal`, `receive_advisor_nudges`,
`retire_delivered_nudges` and `refuse_goal`, and every `service_*` read
from `service_todo_seed` onward: the todo seed, notes, queue, worktree,
jobs, advisor nudges, block summaries, goal and context reads. The
functions in `surfaces` that open a surface or read its target
(`refresh_notes`, `select_note`, `open_summary`, `open_context`,
`request_goal_status`, `notes_target` and `notes_surface`) read the
terminal's overlay and panels and still take the whole model, as do the
`sync_*` edges, which S3e′ forms into `step.update`'s settle.

Six of the moved functions wrote terminal state, in five ways
(`apply_submission` in two of them): a sent composer draft
cleared the editor and pushed its text onto the input history; a frame
the lane did not send unlocked and labelled the queue editor; a dropped
queued-input read labelled it; a goal board, a goal refusal and a goal
read with no attachment updated the open goal inspector; and a live-jobs
board moved the summary's job cursor. The first four are now session
facts that the shared function records and the terminal applies:

- `Shared.drafts_sent` counts the composer drafts the lane has sent.
  `apply_submission` bumps it, and empties `attachments`, when a frame
  marked `ComposerSubmission` is sent. A host empties its editor when the
  count moves; the web's `drafts` counter in section 4 is the same count.
- `Shared.queue_notices` holds `queue_request.Notice` values, oldest
  first: `Refused(reason)` for a frame the lane did not send, which
  `queue_editor.show` turns into `queue_editor.refused`, and
  `Dropped(message)` for a read dropped before it was sent.
- `Shared.goal_observations` holds `GoalObserved(board)` and
  `GoalUnavailable(reason)` entries, oldest first, which the terminal
  applies to the goal inspector through `focused_goal_panel.observe` and
  `unavailable` when the inspector is open, and drops otherwise.

This departs from the note in two ways. Section 3 describes the composer
clear as an edge found by comparing the model before and after:
`pending_submission` going from `Some(ComposerSubmission)` to `None` with
a `Sent` disposition. The disposition is not in the state, and
`pending_submission` also goes to `None` when a frame is refused, so the
fact is recorded as a counter instead, and the queue editor's and goal
inspector's writes as lists, which the note did not plan. And the note
puts the edges in `settle_update`. They run in `tui_model.hold_shared`
instead, at the point of each call into a shared function. Any
function that sends a frame can produce the first two, and the tick's
goal read the third, from inside other reducers and the tick's own
chain, and each used to write the editor at that point. Applying them in
the hold keeps every terminal write where it was, so the frames and the
effect order do not change, and it needs no before-and-after comparison
that could confuse two sends in one event, such as a composer draft
refused and another frame sent. `hold_shared` already applied one such
edge, the idle timer's reset, for the same reason. The counter and the
two lists are records of facts rather than comparisons, so S3d′ can move
the calls that apply them into `settle_update` if the fold's order allows
it. `tui_test/stepping.step` asserts that both lists are empty after
every step, beside its outbox check.

The job cursor is not recorded that way, because it follows the job it
pointed at in the board being replaced, and which job that was is the
terminal's to know. `inbound.receive_jobs` calls the shared receiver and,
when `jobs_awaiting` shows the board was taken, moves the cursor with
`summary_panel.follow_selected_job`, which is the old selection code as a
pure function.

The reducers that still take the whole model reach the moved functions
through terminal forms in `tui/model` (`send_frame`, `send_via` and
`apply_submission`) and through `tui_model.run_shared(model, reducer)`,
which is `hold_shared(model, reducer(model.shared))`. `clear_composer` and
`clear_composer_text` are the terminal's and moved into `tui/model` with
the edge that calls them. The tick runs its first eight reads as one chain
over `Shared`, `service_reads`, held once before the activity poll: one
hold per read cost the idle tick about 0.8% in reductions, and none of the
eight reads the editors a hold writes.

One test gained an assertion. Before this slice no test observed the
queue editor's message after a refused frame, so the Escape test in
`attempt_replay_test` now checks that a cancelled prompt's reason reaches
the editor; it passes on `main` and fails when the notice is not shown.
The `Dropped` path has no test on either tree.

Measured against `main` at `d337e4a24`, whose tree is the one #599
merged. The `tui` suite passes 961 tests on both. Both committed
recordings replay byte-identical with `--all --plain`, and the
synthesized `tui_perf` replays of 64, 512 and 4,096 frames end on
identical frames. The P model's ten cases find no bug at 30,000 schedules
each. The shipped fixtures, the two `tui_shipped_*` suites and the seven
`daemon_shipped_*` ones, pass against each build's `bin/loomd` with `HOME`
pointed at an empty directory. `scripts/tui_perf.sh`, median of three
alternating runs: an idle tick costs 7,525 reductions against 7,509
(+0.21%) and 9,449 words against 9,423 (+0.28%), a 64-frame tick 227,364
reductions against 226,314 (+0.46%), a key 100,972 against 100,966, and a
500-frame burst 5,536 reductions per frame against 5,514 (+0.40%). With
`TUI_PERF_MIN_HEAP=4000000` the rises are the same to within 0.1%. The
remaining cost is the extra comparisons in `hold_shared` and the terminal
forms' calls; nothing new runs per frame. `erlc` on the generated
modules, median of three alternating runs of wall time: `tui` 0.41 s on
both, `tui@inbound` 1.88 s against 1.86 s, `tui@interaction` 2.02 s
against 2.01 s, `tui@submit` 0.88 s against 0.84 s, `tui@model` 0.38 s
against 0.28 s (it gained the terminal forms and the edges),
`tui@surfaces` 0.62 s against 0.77 s and `tui@outbound` 0.46 s against
0.50 s; `tui@tick`, `tui@session_model`, `tui@queue_editor` and
`tui@summary_panel` are unchanged. No settle chain was added; the tick's
chain keeps its parameter boundary. Lint finds no error-tier finding on
either; the `tui` package's census falls from 100 to 98 warnings (R3,
catch-all patterns, from 52 to 50) and R8, R11 and R12 are unchanged.

*S3d′ as landed, first half: the event fold.* S3d′ was to cut the lane
fold, the event fold and `drain_replay` to `Shared` in one landing. It
landed in two, and this is the first. The event fold went first, alone,
because it sits below the lane fold in the call graph and every terminal
write in it can be recorded and applied without changing behaviour. The
lane fold cannot, as the end of this entry explains, and it waits for a
ruling.

`apply_event` and everything it reaches moved into a new module,
`tui/event_fold`, over `Shared` alone: streams, tool tails, entries,
phases, usage and the cache watch, the side-surface replies, schedules,
skills and models, the returned draft, the interrupt's held prompt, the
own-turn bookkeeping (`send_prompt_to`, `expect_own_turn`,
`settle_own_turn`, `abandon_interjections`), `select_model`,
`settle_pending_cache`, and the session half of `select_workspace`. The
module reads no terminal state. It calls `outbound`'s and `surfaces`'
functions over `Shared` and no other function of either. The lane fold
(`apply_channel_update`, `reconcile_cut`, `render_cut`, the approval
presentation, `drain_connection`, `tick_channel`, `cancel_pending`,
`receive_history`) and the tick's `drain_replay` and
`advance_activity_indicator` stay in the terminal over the whole model. The
lane fold calls the event fold once per event through `inbound.run_event`.

Where an event wrote terminal state, the fold now records a
`session_model.SurfaceFact` in `Shared.surface_facts`, oldest first:

- `WorkspaceSwitched(departing, arriving, previous_session)`, recorded by
  `event_fold.select_workspace`, which parks and restores the history
  window and releases the session's boards (`leave_session`). The terminal
  parks the editor, the attachments and the viewport under `departing`,
  restores `arriving`'s, closes a goal inspector and resets the strip's
  focus on a change of session. This is section 3's `park_editor`.
- `SessionSynchronized`, recorded by a full snapshot. The terminal drops
  `record_gutters` and returns `scroll_offset` to the tail.
- `ModelsListed(models, current)`. An open model selector takes the list.
- `OutlookCleared`, recorded when a model change forgets the active
  strand's cache watch. The terminal empties `cache_outlook`.
- `NotesArrived(board)`, recorded after the board seeds the todo panel.
  The terminal decides whether a notes surface shows the board's strand,
  through `surfaces.notes_target`, and if so writes `note_board`, the
  notice, the selection and the scroll, as the arm did.
- `JobsReplaced(previous, board)`, recorded when a jobs board answers
  this attachment's read. The summary's cursor follows its job from
  `previous` to `board`.

A queued-input reply appends `queue_request.Received(owner, namespace,
document)` to `queue_notices`, which `queue_editor.show` turns into
`queue_editor.receive`, and a returned draft stays in `returned_drafts`.
`inbound.settle_surfaces(before, held)` applies the facts in order and
then moves the returned drafts into the editors. It runs after every call
into the fold: in `run_event`, and in the terminal forms
`inbound.select_workspace` and `inbound.select_model`, which the
command arms and `drain_replay` call. `tui_test/stepping.step` asserts
that `surface_facts` is empty after every step.

This departs from the note in three ways.

1. The edges run in `settle_surfaces`, after each event, not in
   `settle_update`. One step applies many events, and a later event reads
   or overwrites what an earlier one wrote. A stream fragment after a
   notes board replaces the notice the board set; applied at the end of
   the step, the board's notice would win. A returned draft has to be in
   the composer before a later switch in the same drain parks it. As in
   S3c′, applying each fact at the call that recorded it keeps every
   terminal write in the same order relative to the shared writes around
   it, so nothing the fold writes afterwards can see a difference.
2. The edges are recorded facts rather than comparisons of the model
   before and after, for the same reason S3c′ gave, and because no single
   comparison reproduces the rules. `render_cut` empties the outlook when
   the active strand has no watch after a capture; `forget_cache` empties
   it when the forgotten strand is the active one. An edge on
   `before.shared.cache != after.shared.cache` would also fire after a
   strand switch that leaves a stale label for the next tick to replace,
   and would repaint a frame earlier than today.
3. The switch's viewport height is measured on the model from before the
   call, with the session's boards and a goal inspector released. Layout
   reads both, the old `select_workspace` measured after releasing them
   and before anything else moved, and the full snapshot changes the
   strands, records and active strand after the switch within the same
   event.

The census above missed two terminal accesses. In the event fold,
`forget_cache`, reached from the `ConfigSnapshot` arm through
`select_model`, writes `cache_outlook`. In the lane fold,
`apply_request_refused` reads `surfaces.notes_surface` to decide whether a
refused notes read writes an error line. The census also lists
`close_settled_approval` as a write only; it reads the overlay first, and
what it reads decides whether it appends a transcript line.

Breaking each fact's application in turn failed tests for six of the
eight (the six facts, the queue editor's `Received` and the returned
drafts): 8, 11, 15, 3, 1 and 1 tests for the workspace switch, the queue
reply, the notes board, the returned drafts, the jobs cursor and the
outlook. The snapshot's viewport reset and the selector refresh had no
test on either tree, so `surface_facts_test` adds one for each; both pass
on `main` and each fails when its fact is not applied.

Measured against `main` at `431d3e4c6`, whose tree is the one #600 merged.
The `tui` suite passes 961 tests on `main` and 963 here, the two new
ones; `session_view` passes 112, `web_view` 81 and `client` 2,292 on
both. Both committed recordings replay
byte-identical with `--all --plain`, and the synthesized `tui_perf`
replays of 64, 512 and 4,096 frames end on identical frames. The P
model's ten cases find no bug at 30,000 schedules each. The shipped
fixtures (the fifteen tests matching `_shipped_`, the `tui_shipped_*` and
`daemon_shipped_*` suites among them) pass against each build's
`bin/loomd` with `HOME` pointed at an empty directory.
`scripts/tui_perf.sh`, median of three alternating runs: an idle tick
costs 7,525 reductions on both and 9,455 words against 9,449 (+0.06%,
the new field on the shared record), a 64-frame tick 226,652 reductions
against 226,897 (−0.11%), a key 100,972 on both, and a 500-frame burst
5,529 reductions per frame against 5,536 (−0.13%) and 11,848 words per
frame against 11,850. With `TUI_PERF_MIN_HEAP=4000000` the idle tick is
7,525 on both, the 64-frame tick 216,942 against 217,453 (−0.23%) and the
burst 5,385 per frame against 5,393. The event fold now copies one record
per write where it copied two. `erlc` through the compile review's
`profile_module.py`, median of three alternating runs, wall time and
`core_inline_module`: `tui@inbound` 1.35 s against 2.09 s (inlining 0.061 s
against 0.099 s), the new `tui@event_fold` 0.91 s (0.041 s), `tui` 0.63 s
against 0.62 s, `tui@interaction` 2.34 s against 2.32 s, `tui@submit`
1.41 s against 1.24 s, `tui@tick` 0.90 s against 1.11 s and `tui@model`
0.72 s against 1.06 s. The machine's load average was between five and
seven, so the wall times move by a few tenths between runs; the inlining
times do not. Lint finds no error-tier finding on either; the `tui`
census falls from 98 to 97 warnings (R3 from 50 to 49).

*Why the lane fold waits.* The lane fold makes three decisions over
terminal state that a later update in the same drain depends on.
`close_settled_approval` reads the open inspector and appends "Approval …
was settled elsewhere" to the transcript; `present_pending_approval` opens
the inspector, which the next cut's `close_settled_approval` reads; and
`apply_request_refused` reads whether a notes surface is open. A drain
takes up to a batch of messages, each of which can produce several
updates. If the lane fold became one call over `Shared` per drain and
these ran after it, a drain holding two cuts would differ from today's:
a question presented by the first cut and settled by another client in
the second is today presented, closed and reported with a line that
survives until the next cut, and after the change would be neither
presented nor reported. The visible-worktree refresh does not have this
problem: `layout.diff_shown` reads only `diff_view` and the width, which
no update changes. Section 6, question 11, has the options.

*S3d′ as landed, second half: the lane fold.* The owner ruled on question
11 on 2026-09-28 for option (a), and the lane fold moved under it.
`apply_channel_update` and its arms (`reconcile_cut`, `render_cut`,
`receive_history`, the approval lookup, the refusals through
`apply_request_refused`, the acknowledgements, `Noticed`, the lost lane),
the preview peer's channelless messages (`receive_unlaned`, formerly
`handle_presentation_message`) and a replay's changes
(`apply_replay_change`, formerly the body of `tick.drain_replay`) moved into
a new module, `tui/lane_fold`, over `Shared` alone. The module reads no
terminal state; it calls `event_fold`, and `outbound`'s and `surfaces`'
functions over `Shared`.

The host keeps the loop. `lane_fold.tick`, `receive` and `cancel_unsent`
hold the lane and return its updates, and `take_replayed` takes a replay's
event and returns its changes. `tui/inbound` applies each update through
`inbound.apply_channel_update`, and `tui/tick` each change through its own
`apply_replay_change`, as one shared call followed by
`inbound.settle_surfaces`. `drain_connection`'s loop over messages,
`tick_channel`'s and `cancel_pending`'s folds over updates and the
connection backlog stay terminal, as the ruling has it.

Three decisions inside one update read terminal state, and the fold takes
each from a `lane_fold.Surroundings` value the host reads before the
update (`inbound.surroundings`):

- `worktree`, whether captured edits are on screen, decides whether a new
  cut asks for a fresh worktree. `layout.diff_shown` reads only `diff_view`
  and the width, which no update writes.
- `notes`, whether a notes surface is open, decides whether a refused
  notes read is reported. The refusal is the first thing its update does.
- `reviewing`, the approval the inspector shows, and `wanted`, the
  approval `/approvals <id>` waits for, decide whether a cut or a lookup
  closes the dialog with "Approval … was settled elsewhere". The fold
  writes that line where it always did, before the lines the same update
  writes after it ("decision lookup not sent", "Additional resolutions are
  not loaded", "Decisions not available"). In a lookup's update the
  inspector can open before the close; the fold computes the record it
  opens on from `wanted` and the lookup's records, as `inspect_looked_up`
  does.

Recording these as facts after the update would have moved the line after
those later lines and changed the notice the update leaves, which is the
difference the ruling was meant to avoid. Passing the three values in is
not option (b) of question 11: nothing about the inspector is stored in
`Shared`, and a host with no inspector, such as the web view, passes
`lane_fold.nothing_shown()`.

The terminal writes became facts, applied after each update in the order
recorded: `LookupAnswered(records, missing)` runs `inspect_looked_up`;
`ApprovalSettled` closes the dialog; `ApprovalsPresented` runs
`present_pending_approval`, after every close, as before;
`QueueRowsCaptured(previous, rows)` moves the queue editor's selection
(`follow_queue_selection`, formerly `retain_queue_selection`);
`HistoryReleased(session, strands)` prunes the parked editors' reading
positions; `AgentMessagesCaptured` runs
`reconcile_agent_message_selection`; `OutlookCleared` empties the outlook
when a cut leaves the active strand without a watch; `GoalReleased`
closes a goal inspector on a lost lane; `ConnectionLost` runs
`begin_reconnect` on a lost lane or a closed channelless connection;
`ReplayAdopted(SameSession | NewSession)` clears the note selection, the
prompted approvals and the pending lookup and resets the viewport on a new
session. The activity glyph is not a fact: it already advanced in the
terminal after the hold of the shared clocks, reading
`active_strand_live`, and a fact recorded and cleared on every tick of a
live strand cost two copies of the shared record, 190 more words on the
idle tick of a live strand (from 9,455 to 9,675), which is over question
5's two percent. The queue editor's acknowledged save and unknown outcome
are the notices `queue_request.Saved` and `Unknown`, and its refusals the
existing `Refused`. `mark_activity`'s quiet time was already an edge in
`hold_shared`.

Two departures from the plan. The queue preview's height, which bounds
the preview's scroll when the selected row survives a cut, is measured on
the shared record from before the update with the terminal state as the
earlier facts left it. The old code measured inside `render_cut`, after
`observe_completion` and before the cut wrote anything layout reads
(`observe_completion` writes the completion, the worktree and the jobs,
none of which the queue preview's layout reads), and for a replay's adoption the old rows are
empty, so the height is never read. And `drain_replay`'s view resets are
one fact, `ReplayAdopted`, rather than edges on the session.

The census in the S3 entry holds for the lane fold, with the two
corrections the first half's entry made. The terminal forms that remain
in `tui/inbound` for the command arms and the tests are
`apply_channel_update`, `apply_cut`, `request_decisions`,
`service_history`, `cancel_pending`, `request_visible_worktree` and
`refresh_worktree`.

Removing each fact's application, and each queue notice, in turn failed
2, 3, 6, 1, 4 and 1 tests for the lookup's inspector, the dialog's close,
the presentation, the queue selection, the reconnect and the unknown
save. Removing the rest failed none: the pruned reading positions, the
agent inspector's selection, the goal inspector's close, the replay
adoption's resets, the activity glyph, the acknowledged save, and two of
the three `Surroundings` reads (the notes surface and the shown diff).
None of these behaviours is new, and nothing observed them on either
tree, so the slice adds a test for each, in `surface_facts_test`,
`agent_workspace_test` and `history_view_test`; each passes on `main`,
except the replay adoption's, which drives `tick.apply_replay_change`, a
function `main` keeps private, and each fails when its application is
removed. Removing the third read, the approval under review, failed four
tests, one of them new: `snapshot_view_test`'s check that the "settled
elsewhere" line comes before the lookup's "Decisions not available" line,
which is the notice the update leaves.

Measured against `main` at `ddd88a690`, whose tree is the one #601 merged.
The `tui` suite passes 963 tests on `main` and 971 here, the eight new
ones; `session_view` passes 112, `web_view` 81 and `client` 2,292 on
both. Both committed recordings replay byte-identical with `--all
--plain`, and the synthesized `tui_perf` replays of 64, 512 and 4,096
frames end on identical frames. The P model's ten cases find no bug at
30,000 schedules each. The shipped fixtures, the fifteen tests matching
`_shipped_`, pass against each build's `bin/loomd` with `HOME` pointed at
an empty directory. `scripts/tui_perf.sh`, median of three alternating
runs: an idle tick costs 7,532 reductions against 7,525 (+0.09%) and
9,458 words against 9,455 (+0.03%), a 64-frame tick 225,491 reductions
against 226,017 (−0.23%), a key 100,972 on both, and a 500-frame burst
5,526 reductions per frame against 5,529 and 11,844 words against
11,848. With `TUI_PERF_MIN_HEAP=4000000` the idle tick is 7,532 against
7,525, the 64-frame tick 216,497 against 216,942 and the burst 5,377 per
frame against 5,384. `erlc` through `profile_module.py`, median of three
alternating runs, wall time and `core_inline_module`: `tui@inbound`
0.64 s against 1.22 s (inlining 0.026 s against 0.061 s), the new
`tui@lane_fold` 0.74 s (0.039 s), `tui@tick` 0.36 s against 0.43 s
(0.013 s against 0.018 s), and `tui` 0.47 s, `tui@event_fold` 0.78 s,
`tui@interaction` 2.10 s, `tui@submit` 0.95 s, `tui@model` 0.42 s and
`tui@session_model` 0.30 s, each within 0.03 s of `main`. Lint finds no
error-tier finding on either; the `tui` census falls from 97 to 96
warnings (R11 from 4 to 3, `render_cut` no longer one undivided block).
A report-only review from `ddd88a690` found no behaviour change; its
three notes were comments, now corrected.

**S4: the move.** `tui/model`'s shared record and helpers,
`tui/msg`, the frame and replay admission, `tui/inbound`, `tui/outbound`,
`tui/surfaces`, the shared half of `tui/submit`, `tui/completion_summary`,
`tui/agent_messages`, `tui/attempt_replay` and `tui/step_effect` move to
`session_view`
under the names in section 2, and `step.update`, `attach`, `new` and
`next_due` are written as the entry points `tui.step` calls. *Proves:*
`make lint-session_view` passes R6 at error level, `gleam export
package-interface` shows no BEAM type in the new modules, the `tui` suite
passes with only import lines changed, and the replay is byte-identical.
*Size:* renames of about seven thousand lines plus `step.gleam`, under
two hundred lines new.

**S5: the web view drives the step.** `component.Model` becomes
`{shared, view}`; `update` reads the clock at its top; `Opened`,
`Arrived` and `Ticked` call the step; `submit` and `decide` wrap
commands; the functions in section 4's table are deleted; `derive`
rebuilds blocks, pieces and the strip on the revision edge. *Proves:*
`component_test` (with `at` supplied by the fixture's transport clock
rather than in messages), `delivery_test`'s render counts per burst (one
and three), `operator_page_test`, `page_test`, the client's `ui_*` tests,
`web_view_parity_test`, and a hand check in a browser of the operator
page, the observer page and a session with a running strand. *Size:*
`component.gleam` loses about 450 lines and gains about 150;
`operator_page.gleam` changes its two command arms; `client/daemon/ui_socket`
is untouched.

**S6: the record.** ADR-014 gains an addendum saying the four blockers
are closed and how; `packages/session_view/CLAUDE.md`,
`packages/tui/CLAUDE.md` and `packages/web_view/CLAUDE.md` with their
mirrors; `docs/architecture/client.md`'s layering section, `terminal.md`'s
loop section, `web-view.md`'s "Time" paragraph and `delivery.md`'s web
steps; `docs/next.md`. *Proves:* `make doc-check`.

S1 can start now. S5 must wait for S4, and S3's landings for S2; nothing
else is ordered. The first pull request is S1 alone, so that its size is
reviewed as the mechanical change it is.

## 6. Rulings, risks and open questions

The first two were decided by the owner on 2026-09-27, as recommended.
The rest are open, for the implementer to settle in the slice that meets
them.

1. **Decided (owner, 2026-09-27): commands, not a shared key
   vocabulary.** ADR-014's second blocker proposed engine-owned key and
   pointer types so that the key handlers could move. That path is not
   taken: the handlers read four terminal surfaces before they decide,
   and moving them would move the surfaces. Keys stay in the terminal
   shell, and both shells emit the same closed `Command` set; the web
   maps DOM events to it, which is what it does today for its two
   handlers. `tui/interaction` stays in the terminal at its current
   size. S6 records the ruling in an ADR-014 addendum amending blocker 2.

2. **Decided (owner, 2026-09-27): daemon control, reconnect and the
   attachment jobs stay terminal-only.** The catalogue, the relaunch and
   the provisional attempt live in the terminal shell and the page does
   not reuse them. Part 2's session sidebar mounts one component per
   session, as ADR-014's direction section already says; the daemon side
   lists sessions from its own registry rather than through the control
   protocol the terminal speaks.

3. **Presentation revisions in the shared record.** `render_revision`,
   `frame_revision`, `activity_revision`, `record_cache_epoch` and the
   counter that replaces `record_cache_valid` are bumped by shared
   reducers and read only by the terminal. They are in the shared record
   because a reducer that changes a transcript line has to say so, and
   the alternative, comparing the whole record after every event, is
   what the frame cache's design refuses. *Recommendation:* keep them,
   document them in `session_view/model` as revisions a host may compare
   and may ignore, and have the web's `derive` compare `render_revision`
   so it stops re-projecting on a capture that changed nothing, which is
   an invariant its `CLAUDE.md` already states.

4. **Compile time.** The step's settle chains are the two places the
   Erlang inliner has cost a minute before (the comment above
   `packages/tui/src/tui.gleam:1842` (`apply_input`)). S3 creates a third
   chain, the shell's edges. *Recommendation:* every S3 landing measures
   `erlc +time` on the generated modules and keeps the parameter boundary
   in each of the three chains; the `beam-compile-review` skill has the
   procedure. *Measured in S3a′:* unchanged; section 5's S3a′ entry has
   the figures. S3a′ adds no settle chain, so the third one is S3d′'s to
   measure. *Measured in S3c′:* no module that holds a settle chain moved
   by more than 0.04 s; `tui@model` rose by 0.1 s with the terminal forms
   and the edges it gained. Section 5's S3c′ entry has the figures.
   *Measured in the first half of S3d′:* the edges run in
   `inbound.settle_surfaces`, a fold over the recorded facts called once
   per event, not in a chain of local steps, so no third settle chain was
   formed yet. `core_inline_module` on `tui@inbound` fell from 0.099 s to
   0.061 s, and on the new `tui@event_fold` it is 0.041 s; `tui` and
   `tui@tick` are unchanged. The lane fold's half is where the chain would
   form, if its edges move to `settle_update`. *Measured in the second
   half:* the edges stayed in `settle_surfaces` under the ruling on
   question 11, so no third chain was formed. `core_inline_module` on `tui@inbound` fell
   from 0.061 s to 0.026 s, and on the new `tui@lane_fold` it is 0.039 s;
   `tui@tick` fell from 0.018 s to 0.013 s, and `tui`, `tui@event_fold`,
   `tui@interaction` and `tui@submit` are unchanged.

5. **Allocation per event.** Today one event copies one 152-field record
   per field write. After S1 a shared write copies an 80-field record and
   the two-field outer; a terminal write copies a 65-field record and the
   outer; a reducer that writes both copies both. The idle tick should get
   cheaper and a `render_cut` about the same. *Recommendation:* S1's
   proof includes `tui_perf.sh events`, `burst 500` and `growth 4096`,
   alternating before and after; a rise over two percent on the idle tick
   is a finding.

6. **The notice's level.** The web draws `Warned` differently from `Said`
   (`web_view/component.gleam:229` (`Notice`)); the shared `notice` is a
   string, and the terminal writes it at about 120 sites.
   *Recommendation:* keep the string in S1 through S5 and draw every
   shared notice as `Said`; type it afterwards if the page needs the
   distinction, since a typed notice changes no terminal frame.

7. **Slash commands mix surfaces and session commands.**
   `command.Command` has both, so the shared `submit_text` keeps arms it
   can only answer with a notice. *Recommendation:* in S3b split
   `session_view/command` into `Surface` and `Session` variants under one
   parse, so the shell's routing is a `case` on the outer variant and the
   shared dispatch is exhaustive over the inner one.

8. **The web reads its clock in `update`.** This reverses the sentence in
   `docs/architecture/web-view.md` that `update` reads no clock, and
   `component_test` builds `Arrived([frame], 0)` with its own readings.
   *Recommendation:* the fixture's `Transport` gains a settable clock and
   the tests set it where they passed `at`; the paragraph is rewritten in
   S6.

9. **The candidate's frames and the shared inbox.** The adopted inbox's
   source and the attempt's frames subject are compared by admission
   today in one function. After the split the comparison is in two
   places, the terminal's routing and the shared filing. The S2 swap
   regression in `runtime_receive_test` must still fail when either place
   is wrong, and the phase 3 mutation "admission files a frame from any
   subject", which failed eight tests, must fail as many when applied to
   either. *Recommendation:* re-run the phase 3 mutation table's admission
   rows in S3a and record the result in the ADR-014 addendum. *Measured in
   S3a′:* the mutation fails the same eight tests on `main`, applied to
   `admission.file_frame`, and applied to the terminal's routing of a
   refused frame; S6 carries the result into the addendum.

10. **`details_expanded` as shared state.** It is a terminal toggle
    today, placed in the shared record because the shared projection and
    the generation clock read it. A page that never toggles it holds a
    field it never writes. *Recommendation:* accept; the page will toggle
    it when Part 2 adds a details control, and a shared `extent` is what
    keeps `presentation` a function of the shared record alone.

11. **The lane fold's reads of terminal state.** Found in S3d′ (section
    5, the first half's entry). The approval inspector's close and
    presentation and a refused notes read decide shared writes from
    terminal state, and a later update in the same drain reads the
    result. Three ways to keep behaviour: *(a)* keep the loop over a
    drain's updates in the host, make one update the shared unit, and
    apply the recorded facts between updates, which is the shape the event
    fold took; *(b)* move the approval under review into `Shared`, which
    section 3 ruled terminal because the page has no inspector; *(c)*
    accept the difference for two cuts in one drain and record it.
    *Recommendation:* (a). It keeps every frame and line as it is, and the
    web view, which has no inspector, runs the same loop with no facts to
    apply. It needs the owner's ruling, because it changes the shape of
    `step.update`'s `Ticked` from one call into a host-driven loop.
    *Ruled 2026-09-28: (a).* The host keeps the loop over a drain's
    updates, one update is the shared unit, and the recorded facts are
    applied between updates. Section 5's "S3d′ as landed, second half"
    entry says how it landed: the three reads inside an update come from a
    `Surroundings` value the host passes in.
