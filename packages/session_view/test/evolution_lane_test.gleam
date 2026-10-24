//// The evolution surface over the lane: what the channel pairs with the
//// requests it issued, and what the shared record becomes as the replies fold
//// (protocol-change/099).
////
//// Every evolution action is the one wire command `evolution`, and every
//// action answers with the same snapshot, so the lane names a request by its
//// action and pairs the reply with that name. These tests drive a real
//// attached lane. A board reply folds into the record. A `status` reply moves
//// the one selection the lane polled and no other. A refusal drops a refused
//// selection and keeps a refused poll. A lost lane forgets the tracked
//// selections and the next board restores them.
////
//// The harness is the one `step_test` builds: an adopted lane, a credited
//// transfer that leaves it ready, and a reply builder that names the request
//// the lane has out.

import core/codec
import core/json
import core/message
import core/usage_evidence
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/attempt
import session_view/connection_event
import session_view/event_fold
import session_view/evolution
import session_view/evolution_pending as pending
import session_view/inbox
import session_view/lane_fold
import session_view/model.{type Shared, Shared} as session_model
import session_view/msg
import session_view/protocol
import session_view/session_channel
import session_view/shared_set
import session_view/snapshot
import session_view/step
import session_view/step_effect
import session_view/surfaces
import session_view/worktree_view

// --- the harness --------------------------------------------------------------

type Record =
  Shared(String, Nil, String, String)

fn attached() -> Record {
  let lane =
    session_channel.start(
      "socket",
      snapshot.Expected("session", "epoch", "incarnation"),
      now: 0,
    )
  let shared =
    step.new(
      "main",
      "0198c0de-0000",
      msg.Stamp(0, 0),
      inbox.new("frames"),
      inbox.new("replay"),
    )
  Shared(
    ..session_model.hold_channel(shared, lane),
    peer: session_model.Attached,
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

fn transfer(role: String) -> List(connection_event.Message) {
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
            usage_evidence.none(),
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
        #("role", json.String(role)),
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

fn applied(shared: Record, update: session_channel.Update) -> Record {
  lane_fold.apply_channel_update(shared, update, lane_fold.nothing_shown())
  |> step.forget_surfaces
}

fn drain(shared: Record, remaining: Int) -> Record {
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

// A lane that has finished its first capture and may mutate, over a roster
// holding the strand the mutation guard looks for.
fn ready() -> Record {
  ready_as("operator")
}

// The same lane for an attachment whose role is `role`, which the first
// capture carries and which decides whether the lane may mutate.
fn ready_as(role: String) -> Record {
  let arrivals = list.map(transfer(role), msg.Frame("frames", _))
  let filed = step.update(attached(), msg.Arrived(arrivals)).0
  shared_set.strands(drain(filed, 3), [
    protocol.Strand(id: "main", name: Some("main"), live_phase: None),
  ])
}

// The two evolution services a tick runs, in the order `step.service_reads`
// runs them, at the instant `at`, and the frames they wrote. A whole tick would
// first send the reads a fresh capture owes (the notes, the queue), each of
// which holds the lane's one slot until it is answered; these tests are about
// the evolution reads, so they call the evolution services.
fn reads(
  shared: Record,
  at: Int,
) -> #(Record, List(step_effect.Effect(String, Nil))) {
  let stamped = Shared(..shared, stamp: msg.Stamp(at, at), outbox: [])
  let serviced =
    stamped
    |> surfaces.service_evolution_status
    |> surfaces.service_evolution_read
  #(Shared(..serviced, outbox: []), list.reverse(serviced.outbox))
}

fn acted(at: Int, command: msg.Command) -> msg.Msg(String) {
  msg.Input(msg.Stamp(at, at), msg.Acted(command))
}

type Sent {
  Sent(id: Int, body: json.JsonValue)
}

// The commands the effects write on the socket, oldest first.
fn written(effects: List(step_effect.Effect(String, Nil))) -> List(Sent) {
  list.filter_map(effects, fn(effect) {
    case effect {
      step_effect.Lane(session_channel.Transmit(frame:, ..)) -> {
        let assert Ok(json.Object(fields)) = json.parse(frame)
        let assert Ok(json.Int(id)) = list.key_find(fields, "id")
        let assert Ok(body) = list.key_find(fields, "body")
        let assert Ok(json.String(name)) = list.key_find(fields, "cmd")
        case name {
          "evolution" -> Ok(Sent(id, body))
          _ -> Error(Nil)
        }
      }
      step_effect.Lane(session_channel.Shut(..))
      | step_effect.Lane(session_channel.Note(..))
      | step_effect.Recorded(..) -> Error(Nil)
    }
  })
}

fn field(value: json.JsonValue, name: String) -> json.JsonValue {
  let assert json.Object(fields) = value
  let assert Ok(found) = list.key_find(fields, name)
  found
}

fn snapshot_of(body: json.JsonValue) -> json.JsonValue {
  json.Object([#("mode", json.String("evolution")), #("board", body)])
}

// The daemon's answer to the command with this wire identity.
fn answered(shared: Record, id: Int, body: json.JsonValue) -> Record {
  let assert Some(channel) = shared.channel
  let #(shared, updates) =
    lane_fold.receive(shared, channel, reply(id, "snapshot", snapshot_of(body)))
  list.fold(updates, shared, applied)
}

fn text(value: String) -> json.JsonValue {
  json.String(value)
}

fn selecting(candidate: String, generation: Int) -> msg.Command {
  msg.Evolve(evolution.Select(candidate, "fmt_check", "e1", generation, "go"))
}

// The one selection the lane just sent, with its wire identity.
fn begun(shared: Record, at: Int, candidate: String) -> #(Record, Sent) {
  let #(next, effects) = step.update(shared, acted(at, selecting(candidate, 3)))
  let assert [sent] = written(effects)
  #(next, sent)
}

fn queued(id: String) -> json.JsonValue {
  json.Object([#("state", text("queued")), #("request_id", text(id))])
}

fn request_ids(shared: Record) -> List(String) {
  list.map(shared.evolution_pending.requests, fn(row) { row.request_id })
}

fn stage_of(shared: Record, candidate: String) -> pending.Stage {
  let assert Some(tracked) =
    pending.for_candidate(shared.evolution_pending, candidate)
  tracked.stage
}

// --- the board ------------------------------------------------------------------

fn a_board() -> json.JsonValue {
  json.Object([
    #("version", json.Int(1)),
    #("session", text("0198c0de-0000")),
    #("candidates", json.Array([])),
    #(
      "pending",
      json.Array([
        json.Object([
          #("request_id", text("ui-held")),
          #("state", text("running")),
          #("candidate_id", text("cand-held")),
          #("expires_at_ms", json.Int(1)),
        ]),
      ]),
    ),
  ])
}

pub fn a_board_is_read_when_one_is_owed_and_folds_on_its_reply_test() {
  let owed = shared_set.evolution_refresh(ready(), worktree_view.Requested)
  let #(sent, effects) = reads(owed, 100)
  let assert [Sent(id, body)] = written(effects)
  assert field(body, "action") == text("board")
  assert field(body, "arguments") == json.Object([])
  assert sent.evolution_refresh == worktree_view.Settled
  assert sent.evolution_read_ms == Some(100)
  assert sent.evolution == None

  let folded = answered(sent, id, a_board())
  let assert Some(board) = folded.evolution
  assert board.session == "0198c0de-0000"
  assert folded.notice == sent.notice
    as "the board is the surface's own news, never the footer's"
  let assert Some(channel) = folded.channel
  assert session_channel.ready_for_read(channel)
}

pub fn nothing_is_read_while_the_surface_is_closed_test() {
  let #(_, effects) = reads(ready(), 10_000_000)
  assert written(effects) == []
}

pub fn an_open_surface_reads_again_once_the_board_is_stale_test() {
  let watching =
    shared_set.evolution_watch(ready(), session_model.WatchingEvolution)
  let #(first, effects) = reads(watching, 100)
  let assert [Sent(id, _)] = written(effects)
  assert first.evolution_read_ms == Some(100)
    as "a watched surface with no read yet is owed one"
  let idle = answered(first, id, json.Object([#("version", json.Int(1))]))
  let #(_, early) = reads(idle, 100 + evolution.backstop_ms - 1)
  assert written(early) == []
  let #(_, late) = reads(idle, 100 + evolution.backstop_ms)
  let assert [Sent(_, body)] = written(late)
  assert field(body, "action") == text("board")
}

pub fn the_push_owes_a_read_and_changes_nothing_else_test() {
  let shared = ready()
  let assert Some(channel) = shared.channel
  let #(shared, updates) =
    lane_fold.receive(
      shared,
      channel,
      connection_event.Incoming(
        "{\"v\":2,\"event\":\"evolution_changed\",\"body\":{}}",
      ),
    )
  let pushed = list.fold(updates, shared, applied)
  assert pushed.evolution_refresh == worktree_view.Requested
  assert pushed.evolution == None
}

// --- a selection through the lane ---------------------------------------------------

pub fn a_selection_is_sent_with_the_drawn_generation_and_an_identity_test() {
  let #(shared, sent) = begun(ready(), 1000, "candA")
  assert field(sent.body, "action") == text("select")
  let args = field(sent.body, "arguments")
  assert field(args, "candidate_id") == text("candA")
  assert field(args, "expected_generation") == json.Int(3)
  assert field(args, "deadline_ms") == json.Int(pending.window_ms)
  let assert [id] = request_ids(shared)
  assert field(args, "request_id") == text(id)
  assert string.starts_with(id, "ui-0198c0de-")
  assert shared.evolution_pending.awaiting == Some(id)
  assert stage_of(shared, "candA") == pending.Submitted
  assert shared.notice == ready().notice
    as "the footer says nothing about an evolution request"
}

pub fn a_queued_reply_is_polled_by_the_lane_until_it_settles_test() {
  let #(shared, sent) = begun(ready(), 1000, "candA")
  let assert [id] = request_ids(shared)
  let staged = answered(shared, sent.id, queued(id))
  assert stage_of(staged, "candA") == pending.Staging(evolution.Queued)
  assert staged.evolution_pending.awaiting == None

  // Too early, then due: the poll names the request and the daemon's own
  // identity for it, never anything the person typed.
  let #(_, early) = reads(staged, 1000 + pending.poll_ms - 1)
  assert written(early) == []
  let #(polled, effects) = reads(staged, 1000 + pending.poll_ms + 100)
  let assert [Sent(poll_id, body)] = written(effects)
  assert field(body, "action") == text("status")
  assert field(body, "arguments") == json.Object([#("request_id", text(id))])

  let done =
    answered(
      polled,
      poll_id,
      json.Object([
        #("state", text("completed")),
        #("committed", json.Object([#("generation", json.Int(4))])),
      ]),
    )
  assert stage_of(done, "candA") == pending.Landed(Some(4))
  assert string.contains(done.evolution_notice, "generation 4 is live")
  assert done.evolution_refresh == worktree_view.Requested
    as "the board is read again to show the new generation"
}

pub fn a_status_reply_updates_only_its_own_request_test() {
  let #(shared, first) = begun(ready(), 1000, "candA")
  let assert [a_id] = request_ids(shared)
  let shared = answered(shared, first.id, queued(a_id))
  let #(shared, second) = begun(shared, 1500, "candB")
  let assert [_, b_id] = request_ids(shared)
  let shared = answered(shared, second.id, queued(b_id))

  // The poll that goes out is for the first request in line.
  let #(polled, effects) = reads(shared, 1000 + pending.poll_ms + 10)
  let assert [Sent(poll_id, body)] = written(effects)
  assert field(field(body, "arguments"), "request_id") == text(a_id)
  let settled =
    answered(
      polled,
      poll_id,
      json.Object([#("state", text("failed")), #("reason", text("boom"))]),
    )
  assert stage_of(settled, "candA") == pending.Refused("boom")
  assert stage_of(settled, "candB") == pending.Staging(evolution.Queued)
  assert string.contains(settled.evolution_notice, "boom")
}

pub fn a_status_nobody_polled_changes_nothing_test() {
  let #(shared, sent) = begun(ready(), 1000, "candA")
  let assert [id] = request_ids(shared)
  let staged = answered(shared, sent.id, queued(id))
  let stray =
    event_fold.apply_event(
      staged,
      protocol.EvolutionAnswered(
        "status",
        json.Object([#("state", text("completed"))]),
      ),
    )
  assert stray.evolution_pending == staged.evolution_pending
  assert stray.evolution_notice == staged.evolution_notice
}

pub fn a_wait_that_runs_out_reads_the_board_once_more_test() {
  let #(shared, sent) = begun(ready(), 1000, "candA")
  let assert [id] = request_ids(shared)
  let staged = answered(shared, sent.id, queued(id))
  let #(late, effects) = reads(staged, 1000 + pending.window_ms)
  assert stage_of(late, "candA") == pending.TimedOut
  assert late.evolution_notice == pending.timeout_words

  // The board read the expiry owed leaves in the same tick.
  let assert [Sent(_, body)] = written(effects)
  assert field(body, "action") == text("board")
  assert late.evolution_refresh == worktree_view.Settled
}

pub fn a_refused_selection_is_dropped_and_the_board_read_again_test() {
  let #(shared, sent) = begun(ready(), 1000, "candA")
  let refused =
    applied(
      shared,
      session_channel.RequestRefused(
        "evolution:select",
        sent.id,
        "bad_request",
        "selection changed",
      ),
    )
  assert refused.evolution_pending.requests == []
  assert string.contains(refused.evolution_notice, "selection changed")
  assert refused.evolution_refresh == worktree_view.Requested
  assert refused.notice == shared.notice
    as "the refusal is the surface's own news"
}

pub fn a_refused_poll_keeps_the_request_moving_test() {
  let #(shared, sent) = begun(ready(), 1000, "candA")
  let assert [id] = request_ids(shared)
  let staged = answered(shared, sent.id, queued(id))
  let #(polled, effects) = reads(staged, 5000)
  let assert [Sent(poll_id, _)] = written(effects)
  let refused =
    applied(
      polled,
      session_channel.RequestRefused(
        "evolution:status",
        poll_id,
        "bad_request",
        "busy",
      ),
    )
  assert stage_of(refused, "candA") == pending.Staging(evolution.Queued)
  assert refused.evolution_pending.awaiting == None
  assert refused.evolution_refresh == worktree_view.Settled
}

pub fn a_refused_board_read_does_not_ask_again_test() {
  let refused =
    applied(
      ready(),
      session_channel.RequestRefused(
        "evolution:board",
        3,
        "bad_request",
        "runtime evolution is unavailable for this session",
      ),
    )
  assert refused.evolution_notice
    == "Evolution is not available for this session."
  assert refused.evolution_refresh == worktree_view.Settled
}

pub fn only_one_change_may_be_out_at_a_time_test() {
  let #(shared, _) = begun(ready(), 1000, "candA")
  let #(again, effects) =
    step.update(shared, acted(1100, selecting("candB", 3)))
  assert written(effects) == []
  assert request_ids(again) == request_ids(shared)
  assert string.contains(again.evolution_notice, "busy")
    || string.contains(again.evolution_notice, "slot")
}

pub fn an_approval_is_a_change_and_its_reply_asks_for_the_board_test() {
  let #(shared, effects) =
    step.update(
      ready(),
      acted(1000, msg.Evolve(evolution.Approve("candA", "e1"))),
    )
  let assert [Sent(id, body)] = written(effects)
  assert field(body, "action") == text("approve")
  let folded = answered(shared, id, json.Object([#("approved", text("candA"))]))
  assert folded.evolution_refresh == worktree_view.Requested
  assert string.contains(folded.evolution_notice, "Approved")
  assert folded.evolution_pending.requests == []
}

pub fn an_inspected_envelope_is_kept_for_the_reader_test() {
  let #(shared, effects) =
    step.update(ready(), acted(1000, msg.Evolve(evolution.Inspect("candA"))))
  let assert [Sent(id, _)] = written(effects)
  let envelope = json.Object([#("name", text("fmt_check"))])
  let folded = answered(shared, id, envelope)
  assert folded.evolution_open
    == Some(evolution.Opened("inspect", evolution.Whole(envelope)))
}

// --- a lost lane ------------------------------------------------------------------

pub fn a_lost_lane_forgets_the_selections_and_the_next_board_restores_them_test() {
  let #(shared, sent) = begun(ready(), 1000, "candA")
  let assert [id] = request_ids(shared)
  let staged = answered(shared, sent.id, queued(id))
  let lost = applied(staged, session_channel.Failed("boom"))
  assert lost.evolution_pending.requests == []
  assert lost.evolution_pending.awaiting == None
  assert lost.evolution_pending.minted == 1
    as "an identity is never minted twice by one lane"
  assert lost.evolution_read_ms == None

  let restored =
    event_fold.apply_event(lost, protocol.EvolutionAnswered("board", a_board()))
  assert request_ids(restored) == ["ui-held"]
  assert stage_of(restored, "cand-held") == pending.Staging(evolution.Running)
}

// --- what the channel pairs ----------------------------------------------------------

pub fn a_reply_that_is_not_the_requests_answer_closes_the_lane_test() {
  let #(shared, sent) = begun(ready(), 1000, "candA")
  let assert Some(channel) = shared.channel
  let #(_, updates) =
    lane_fold.receive(
      shared,
      channel,
      reply(
        sent.id,
        "snapshot",
        json.Object([#("mode", text("memory")), #("board", json.Object([]))]),
      ),
    )
  assert list.any(updates, fn(update) {
    case update {
      session_channel.Failed(..) -> True
      _ -> False
    }
  })
}

pub fn a_refusal_names_the_action_that_was_issued_test() {
  let shared = shared_set.evolution_refresh(ready(), worktree_view.Requested)
  let #(sent, effects) = reads(shared, 100)
  let assert [Sent(id, _)] = written(effects)
  let assert Some(channel) = sent.channel
  let #(_, updates) =
    lane_fold.receive(
      sent,
      channel,
      reply(
        id,
        "error",
        json.Object([#("code", text("bad_request")), #("message", text("no"))]),
      ),
    )
  assert updates
    == [
      session_channel.RequestRefused("evolution:board", id, "bad_request", "no"),
    ]
}

pub fn reads_and_changes_are_told_apart_by_their_action_test() {
  assert session_channel.is_read("evolution:board")
  assert session_channel.is_read("evolution:status")
  assert !session_channel.is_read("evolution:approve")
  assert !session_channel.is_read("evolution:select")
  assert !session_channel.is_read("evolution")
}

pub fn an_observer_may_read_and_may_not_change_test() {
  let observer = ready_as("observer")
  let #(_, change) =
    step.update(
      observer,
      acted(100, msg.Evolve(evolution.Approve("candA", "e1"))),
    )
  assert written(change) == []
  let #(_, read) =
    reads(shared_set.evolution_refresh(observer, worktree_view.Requested), 100)
  assert list.length(written(read)) == 1
}

// --- the wire forms ---------------------------------------------------------------------

pub fn a_recorded_evolution_request_decodes_and_an_unknown_one_does_not_test() {
  let issued = fn(kind) {
    json.Object(
      attempt.encode(attempt.Issued(
        attempt.Id(1),
        attempt.Request(2, kind, attempt.NoSelection),
      )),
    )
  }
  assert attempt.decode(issued("evolution:board"))
    == Ok(attempt.Issued(
      attempt.Id(1),
      attempt.Request(2, "evolution:board", attempt.NoSelection),
    ))
  assert attempt.decode(issued("evolution:core_upgrade"))
    |> is_error
  assert attempt.decode(issued("evolution:")) |> is_error
}

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}

pub fn the_command_is_one_wire_command_named_by_its_action_test() {
  let frame = protocol.evolution(9, "board", json.Object([]))
  assert frame
    == "{\"v\":2,\"id\":9,\"cmd\":\"evolution\",\"body\":{\"action\":\"board\",\"arguments\":{}}}"
  assert int.to_string(9) == "9"
}

pub fn the_push_decodes_and_carries_nothing_test() {
  let assert Ok(protocol.EvolutionChanged) =
    protocol.decode_v2_pushed(
      "{\"v\":2,\"event\":\"evolution_changed\",\"body\":{}}",
    )
  assert protocol.decode_v2_pushed(
      "{\"v\":2,\"event\":\"evolution_changed\",\"body\":3}",
    )
    |> is_error
}

pub fn the_wires_snapshot_is_kept_unread_until_the_lane_labels_it_test() {
  let assert Ok(protocol.EvolutionSnapshot(body)) =
    protocol.decode_v2_presentation(
      json.to_string(
        json.Object([
          #("v", json.Int(2)),
          #("reply_to", json.Int(4)),
          #("event", text("snapshot")),
          #("body", snapshot_of(json.Object([#("x", json.Int(1))]))),
        ]),
      ),
    )
  assert body == json.Object([#("x", json.Int(1))])
}
