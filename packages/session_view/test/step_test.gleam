//// The shared step's entry point for a host with no surfaces of its own.
////
//// `step.update` composes the units the terminal's tick calls one at a time,
//// and the terminal does not call it, so nothing but a test keeps the two
//// compositions in one order. `a_tick_runs_the_terminals_units_in_its_order_test`
//// spells the terminal's tick over the shared record, in the order
//// `tui/tick.update_tick` and `settle_tick` call the units, and applies the
//// facts after each update as `inbound.settle_surfaces` does, then holds
//// `update` to the same record and the same queued effects.
////
//// That copy documents the order and holds the step to it, in a package that
//// cannot import the terminal. It does not prove the terminal still runs that
//// order: `the_terminals_real_tick_runs_the_shared_steps_order_test` in
//// `client`'s `web_view_parity_test` drives the real `tui/tick.update_tick`.

import core/codec
import core/json
import core/message
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/agent_roster
import session_view/attempt
import session_view/command
import session_view/connection_event
import session_view/context_view
import session_view/inbox
import session_view/lane_fold
import session_view/model.{type Shared, Shared} as session_model
import session_view/msg
import session_view/operator
import session_view/protocol
import session_view/session_channel
import session_view/snapshot
import session_view/step
import session_view/step_effect

// A session record holding an adopted lane whose subscribe is queued, and
// nothing else: the state a host is in the moment its transport opens.
fn attached() -> Shared(String, Nil, String, String) {
  let lane =
    session_channel.start(
      "socket",
      snapshot.Expected("session", "epoch", "incarnation"),
      now: 0,
    )
  let shared =
    step.new(
      "main",
      "session",
      msg.Stamp(0, 0),
      inbox.new("frames"),
      inbox.new("replay"),
    )
  Shared(
    ..session_model.hold_channel(shared, lane),
    peer: session_model.Attached,
  )
}

fn pushed(seq: Int) -> connection_event.Message {
  connection_event.Incoming(
    "{\"v\":2,\"event\":\"committed\",\"seq\":"
    <> int.to_string(seq)
    <> ",\"body\":{\"strand\":\"main\"}}",
  )
}

fn reply(id: Int, event: String, body: json.JsonValue) {
  connection_event.Incoming(
    json.to_string(
      json.Object([
        #("v", json.Int(2)),
        #("reply_to", json.Int(id)),
        #("event", json.String(event)),
        #("body", body),
      ]),
    ),
  )
}

// The three replies of one credited transfer for an operator's attachment,
// answering the lane's requests one, two and three: an empty session, so
// the capture lists no strand and reached no `todo` call.
fn transfer() -> List(connection_event.Message) {
  let metadata =
    json.to_string(
      json.Object([
        #("cells", json.Array([])),
        #("message_count", json.Int(0)),
        #(
          "usage",
          codec.encode_usage(message.Usage(
            0,
            0,
            0,
            0,
            None,
            None,
            0,
            message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
          )),
        ),
        #(
          "host_run_settings",
          json.Object([
            #("queue_mode", json.String("one_at_a_time")),
            #("tool_execution", json.String("parallel")),
            #("origin", json.Null),
          ]),
        ),
        #("peers", json.Array([])),
      ]),
    )
  [
    reply(
      1,
      "snapshot_begin",
      json.Object([
        #("snapshot_id", json.String("recent:1")),
        #("session_id", json.String("session")),
        #("epoch", json.String("epoch")),
        #("incarnation", json.String("incarnation")),
        #("connection_id", json.String("connection")),
        #(
          "origin",
          json.Object([
            #("principal", json.String("alice")),
            #("name", json.String("Alice")),
          ]),
        ),
        #("role", json.String("operator")),
        #("next_seq", json.Int(10)),
        #("oldest_seq", json.Null),
        #("window", json.String("recent")),
        #("complete_history", json.Bool(False)),
        #("record_bytes_limit", json.Int(snapshot.record_limit)),
        #("fragment_bytes_limit", json.Int(snapshot.piece_limit)),
      ]),
    ),
    reply(
      2,
      "snapshot_chunk",
      json.Object([
        #("snapshot_id", json.String("recent:1")),
        #("index", json.Int(0)),
        #("kind", json.String("metadata")),
        #("record_id", json.String("metadata")),
        #("record_seq", json.Null),
        #("total_bytes", json.Int(string.byte_size(metadata))),
        #("offset", json.Int(0)),
        #(
          "data",
          json.String(bit_array.base64_encode(
            bit_array.from_string(metadata),
            True,
          )),
        ),
      ]),
    ),
    reply(
      3,
      "snapshot_end",
      json.Object([
        #("snapshot_id", json.String("recent:1")),
        #("index", json.Int(1)),
        #("next_seq", json.Int(10)),
        #("more_after", json.Null),
      ]),
    ),
  ]
}

fn filed(
  shared: Shared(String, Nil, String, String),
  frames: List(connection_event.Message),
) -> Shared(String, Nil, String, String) {
  let arrivals = list.map(frames, msg.Frame("frames", _))
  step.update(shared, msg.Arrived(arrivals)).0
}

fn tick(at: Int) -> msg.Msg(String) {
  msg.Input(msg.Stamp(at, at), msg.Ticked)
}

// The terminal's tick over the shared record. Each update the drain and the
// lane's tick produce is applied on its own, and the facts it recorded are
// emptied before the next, where the terminal applies them.
fn as_the_terminal_ticks(
  shared: Shared(String, Nil, String, String),
  at: Int,
) -> #(
  Shared(String, Nil, String, String),
  List(step_effect.Effect(String, Nil)),
) {
  let started = Shared(..shared, stamp: msg.Stamp(at, at))
  let clocked = step.advance_activity_clocks(started)
  let #(roster, repaint) = agent_roster.tick(clocked.roster, at)
  let clocked = Shared(..clocked, roster:)
  let clocked = case repaint {
    agent_roster.Changed -> session_model.invalidate_frame(clocked)
    agent_roster.Unchanged -> clocked
  }
  let drained = drain(clocked, inbox.held(clocked.inbox))
  let read = step.service_reads(drained)
  let #(ticked, updates) = lane_fold.tick(read)
  let ticked =
    list.fold(updates, ticked, applied)
    |> lane_fold.service_history
  let settled = step.settle(started, ticked)
  #(Shared(..settled, outbox: []), list.reverse(settled.outbox))
}

fn drain(
  shared: Shared(String, Nil, String, String),
  remaining: Int,
) -> Shared(String, Nil, String, String) {
  case remaining <= 0 {
    True -> shared
    False -> {
      let #(taken, next) = inbox.take(shared.inbox)
      let shared = Shared(..shared, inbox: taken)
      case next, shared.channel {
        Ok(message), Some(channel) -> {
          let #(shared, updates) = lane_fold.receive(shared, channel, message)
          drain(list.fold(updates, shared, applied), remaining - 1)
        }
        Ok(_), None | Error(Nil), _ -> shared
      }
    }
  }
}

fn applied(
  shared: Shared(String, Nil, String, String),
  update: session_channel.Update,
) -> Shared(String, Nil, String, String) {
  lane_fold.apply_channel_update(shared, update, lane_fold.nothing_shown())
  |> step.forget_surfaces
}

// Two ticks over the same record. The first drains a burst of pushes and a
// transport fault, so the lane fails and the fold records the facts a host
// has no surface for. The second is late enough that the failed lane has
// nothing left to time out, which the drain and the lane's tick must both
// leave alone.
pub fn a_tick_runs_the_terminals_units_in_its_order_test() {
  let held =
    filed(attached(), [
      connection_event.Connected,
      pushed(11),
      pushed(12),
      connection_event.NetworkFault("boom"),
    ])
  assert inbox.held(held.inbox) == 4

  let #(by_step, effects) = step.update(held, tick(10))
  let #(by_terminal, terminal_effects) = as_the_terminal_ticks(held, 10)
  assert by_step == by_terminal
  assert effects == terminal_effects
  assert by_step.notices == 2 as "the two pushes reached the lane"
  assert by_step.peer == session_model.Disconnected
    as "the fault ended the lane"
  assert effects != [] as "the subscribe is queued ahead of the lane's close"

  let #(later, later_effects) = step.update(by_step, tick(10_000_000))
  let #(later_terminal, later_terminal_effects) =
    as_the_terminal_ticks(by_terminal, 10_000_000)
  assert later == later_terminal
  assert later_effects == later_terminal_effects
}

// The drain comes before the reads. A first capture, drained in a tick,
// makes the record want a read of the strand's notes, and the read goes out
// in the same tick, since the reads are serviced after the drain and the
// lane is free; a tick that serviced them first would send it a tick later.
// The terminal's tick has this order, and the two must agree on the record
// and on the effect the read is.
pub fn a_capture_drained_in_a_tick_is_read_in_that_tick_test() {
  let held = filed(attached(), transfer())
  let #(by_step, effects) = step.update(held, tick(10))
  let #(by_terminal, terminal_effects) = as_the_terminal_ticks(held, 10)
  assert by_step == by_terminal
  assert effects == terminal_effects
  assert by_step.captured != None as "the capture was drained"
  assert list.any(effects, fn(effect) {
    case effect {
      step_effect.Lane(session_channel.Transmit(frame:, ..)) ->
        string.contains(frame, "\"cmd\":\"notes\"")
      step_effect.Lane(session_channel.Shut(..))
      | step_effect.Lane(session_channel.Note(..))
      | step_effect.Recorded(..) -> False
    }
  })
    as "the notes read leaves in the tick that drained the capture"
}

// A deadline that passes in a tick fails the lane through the lane's own
// tick, after the drain, and the same order holds.
pub fn a_deadline_that_passes_fails_the_lane_in_the_same_order_test() {
  let started = attached()
  let #(by_step, effects) = step.update(started, tick(10_000_000))
  let #(by_terminal, terminal_effects) =
    as_the_terminal_ticks(started, 10_000_000)
  assert by_step == by_terminal
  assert effects == terminal_effects
  assert by_step.peer == session_model.Disconnected
}

// Filing reduces nothing: the frames wait in the buffer for an input, and
// the only effect returned is the subscribe the adoption queued.
pub fn arrived_traffic_is_filed_and_not_reduced_test() {
  let #(shared, effects) =
    step.update(
      attached(),
      msg.Arrived([
        msg.Frame("frames", pushed(11)),
        msg.Frame("frames", pushed(12)),
      ]),
    )
  assert inbox.held(shared.inbox) == 2
  assert shared.notices == 0
  assert list.length(effects) == 1
}

// A frame read from a socket the record no longer reads is dropped, and the
// buffer holds only what the adopted inbox's source sent.
pub fn a_frame_from_a_replaced_source_is_dropped_test() {
  let held = filed(attached(), [pushed(11)])
  let #(shared, _) =
    step.update(held, msg.Arrived([msg.Frame("old socket", pushed(12))]))
  assert inbox.held(shared.inbox) == 1
}

// A recorded attempt event goes to the replay buffer, whatever the peer.
pub fn a_replayed_event_is_filed_test() {
  let event = attempt.Received(attempt.Id(1), connection_event.Connected)
  let #(shared, _) = step.update(attached(), msg.Arrived([msg.Replayed(event)]))
  assert inbox.held(shared.replay_inbox) == 1
}

// With no adopted lane the tick drains nothing, so frames filed before the
// transport opens are kept for the lane that will read them.
pub fn a_tick_with_no_lane_keeps_the_frames_test() {
  let bare =
    step.new(
      "main",
      "session",
      msg.Stamp(0, 0),
      inbox.new("frames"),
      inbox.new("replay"),
    )
  let held = filed(bare, [pushed(11)])
  let #(ticked, effects) = step.update(held, tick(5))
  assert inbox.held(ticked.inbox) == 1
  assert effects == []
  assert ticked.stamp == msg.Stamp(5, 5)
}

// The facts a tick records are dropped at its end, so a host that never
// applies them does not grow them for the life of the session. A refused
// queue save leaves a notice for the queue editor, which the failed lane
// records too.
pub fn a_tick_drops_the_facts_a_host_has_no_surface_for_test() {
  let held = filed(attached(), [connection_event.NetworkFault("boom")])
  let #(ticked, _) = step.update(held, tick(1))
  assert ticked.surface_facts == []
  assert ticked.queue_notices == []
  assert ticked.goal_observations == []
}

// An acted command runs and settles, and leaves the facts it recorded for
// the host that acted: `/clear` consumes the draft as a command, which is
// how a host knows to empty its composer.
pub fn an_acted_command_leaves_its_facts_for_the_host_test() {
  let act =
    msg.Input(
      msg.Stamp(3, 3),
      msg.Acted(msg.Submit(
        draft: "/clear",
        command: command.Clear,
        delivery: operator.Prompt,
      )),
    )
  let #(acted, effects) = step.update(attached(), act)
  assert acted.stamp == msg.Stamp(3, 3)
  assert acted.notice == "local view cleared"
  assert list.contains(
    acted.surface_facts,
    session_model.DraftTaken(session_model.TakenByCommand),
  )
  assert effects != [] as "the lane's queued subscribe is returned"
  assert step.forget_surfaces(acted).surface_facts == []
}

// A control's command has no draft. `/clear` typed in a composer consumes
// the draft and records `DraftTaken`, which a host answers by emptying its
// editor; the same command chosen by a control records no such fact and
// moves no draft count, so the text an operator is typing survives it.
pub fn a_control_takes_no_draft_test() {
  let typed =
    msg.Input(
      msg.Stamp(3, 3),
      msg.Acted(msg.Submit(
        draft: "/clear",
        command: command.Clear,
        delivery: operator.Prompt,
      )),
    )
  let #(submitted, _) = step.update(attached(), typed)
  assert list.contains(
    submitted.surface_facts,
    session_model.DraftTaken(session_model.TakenByCommand),
  )

  let chosen =
    msg.Input(msg.Stamp(3, 3), msg.Acted(msg.Control(command: command.Clear)))
  let #(acted, _) = step.update(attached(), chosen)
  assert acted.notice == "local view cleared" as "the command ran"
  assert acted.surface_facts == [session_model.TranscriptCleared]
  assert acted.drafts_sent == 0
  assert acted.pending_submission == None
}

// The refusal for an attachment that cannot mutate is the same one: a
// control is not a way around it.
pub fn a_control_the_lane_cannot_take_is_refused_test() {
  let chosen =
    msg.Input(
      msg.Stamp(3, 3),
      msg.Acted(msg.Control(command: command.GoalClear)),
    )
  let #(acted, _) = step.update(attached(), chosen)
  assert acted.notice
    == "attachment is read-only or its command slot is busy; draft retained"
}

// A mutation an unsynchronized lane cannot take is refused before it is
// encoded, so nothing is written for it and the reason is the notice.
pub fn an_acted_prompt_the_lane_cannot_take_is_refused_test() {
  let act =
    msg.Input(
      msg.Stamp(3, 3),
      msg.Acted(msg.Submit(
        draft: "hello",
        command: command.Prompt("hello"),
        delivery: operator.Prompt,
      )),
    )
  let #(acted, _) = step.update(attached(), act)
  assert acted.notice
    == "attachment is read-only or its command slot is busy; draft retained"
  assert acted.pending_submission == None
}

// A reply to a command is kept as the command's answer, apart from the
// notice that any later event writes over. A refusal of one of the host's own
// automatic reads is no command's answer, and neither is a refusal whose arm
// says nothing, so a host that draws only answers is not spoken over by them.
pub fn a_reply_is_kept_as_the_answer_and_a_read_refusal_is_not_test() {
  let shared = attached()
  assert shared.answer == ""

  let acknowledged =
    applied(shared, session_channel.Acknowledged("prompt", "admitted"))
  assert acknowledged.answer == "Sent"

  let streamed =
    applied(
      acknowledged,
      session_channel.Streamed("main", "op-1", "gen-1", "text", "hello"),
    )
  assert streamed.notice == "streaming text"
  assert streamed.answer == "Sent"

  let read_refused =
    applied(
      streamed,
      session_channel.RequestRefused("advisor_pending", 4, "unsupported", "no"),
    )
  assert read_refused.answer == "Sent"

  let refused =
    applied(
      streamed,
      session_channel.RequestRefused("steer", 5, "conflict", "busy"),
    )
  assert refused.answer == "conflict: busy"
}

// The decided-approvals read a page makes on opening is no command of the
// operator's. An older daemon refuses it as unknown and an over-budget
// session as failed, and the record keeps its notice and its transcript:
// a refusal that reached the shared error path would put a failure row and a
// notice in front of a reader on every page open.
pub fn a_refused_decided_read_changes_nothing_the_reader_sees_test() {
  let before = attached()
  list.each(
    [
      #("unsupported", "unknown command: escalations_decided"),
      #("snapshot_failed", "bounded snapshot read refused"),
    ],
    fn(refusal) {
      let after =
        applied(
          before,
          session_channel.RequestRefused(
            "escalations_decided",
            4,
            refusal.0,
            refusal.1,
          ),
        )
      assert after.notice == before.notice
      assert after.transcript == before.transcript
      assert after.answer == before.answer
    },
  )
}

// A strand with nothing to cut refuses `compact` as a conflict. That is not a
// failure the reader needs a row for: the footer says it once in plain words,
// the context panel keeps the sentence until the next press, and the daemon's
// code and reason never reach the reader. A refusal for any other reason is
// still the raw one.
pub fn a_compact_with_nothing_to_cut_is_said_plainly_and_kept_test() {
  let before = attached()
  let after =
    applied(
      before,
      session_channel.RequestRefused(
        "compact",
        4,
        "conflict",
        protocol.nothing_to_compact_message,
      ),
    )
  assert after.notice == "Nothing to compact yet."
  assert after.transcript == before.transcript
  assert after.context.compaction == context_view.NothingToCompact

  // A press asks again, and the next answer is the one that stands.
  let asked = context_view.compact_asked(after.context)
  assert asked.compaction == context_view.Unrefused

  let busy =
    applied(
      before,
      session_channel.RequestRefused(
        "compact",
        5,
        "conflict",
        "the strand already has a live operation",
      ),
    )
  assert busy.notice == "conflict: the strand already has a live operation"
  assert busy.context.compaction == context_view.Unrefused
}

// A prompt the daemon hands back is the prompt's last copy, so forgetting the
// surfaces a host has none for leaves it in the record for the host to take.
pub fn forgetting_surfaces_keeps_a_returned_prompt_test() {
  let returned =
    applied(
      attached(),
      session_channel.Auxiliary(protocol.HeldInputReturned(
        strand: "main",
        id: "h1",
        kind: "queue",
        text: "deploy when green",
        attachment_count: 0,
      )),
    )
  assert returned.returned_drafts
    == [session_model.ReturnedDraft("session", "main", "deploy when green")]
  assert step.forget_surfaces(returned).returned_drafts
    == returned.returned_drafts
}

// The session lists `main` and the advisor, for a change of strand to name.
fn listing() -> Shared(String, Nil, String, String) {
  Shared(..attached(), strands: [
    protocol.Strand("main", None, None),
    protocol.Strand("advisor", None, None),
  ])
}

// A change of strand moves the record to the strand and leaves nothing for a
// surface the host lacks. With no cut captured yet, the strand's
// configuration is asked for, and the lane's frames come back as effects.
pub fn focusing_a_strand_moves_the_record_and_drops_the_facts_test() {
  let #(focused, effects) = step.focus(listing(), "advisor", msg.Stamp(5, 5))
  assert focused.active_strand == "advisor"
  assert focused.stamp == msg.Stamp(5, 5)
  assert focused.surface_facts == []
  assert focused.outbox == []
  assert effects != [] as "the lane's queued frames are returned"
}

// The change cancels the lane's unsent frames, so a prompt queued for the
// strand being left cannot reach the strand being entered.
pub fn focusing_a_strand_leaves_no_unsent_prompt_behind_test() {
  let #(focused, _) = step.focus(listing(), "advisor", msg.Stamp(5, 5))
  assert focused.pending_submission == None
  assert focused.queued == []
}
