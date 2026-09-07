//// A pushed frame is accepted in every open phase and never owns the wire.
////
//// These fixtures drive `tui/session_channel` through real v2 bodies and the
//// credited transfer decoder, so what they prove about a notice — that it
//// moves a catch-up earlier and changes nothing else — is proved against the
//// same code path a live socket takes. The trace records what a socketless
//// lane would have written, which is how a test sees which request a
//// transition issued rather than only its outcome.

import core/codec
import core/json
import core/message
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/attempt
import tui/connection
import tui/protocol
import tui/session_channel
import tui/snapshot
import tui/workspace

import gleam/bit_array

fn metadata() {
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
}

fn reply(id, event, body) {
  connection.Incoming(
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

fn push(fields) {
  connection.Incoming(
    json.to_string(json.Object([#("v", json.Int(2)), ..fields])),
  )
}

fn notice(strand, seq) {
  push([
    #("event", json.String("committed")),
    #("seq", json.Int(seq)),
    #("body", json.Object([#("strand", json.String(strand))])),
  ])
}

fn delta(strand, operation, text) {
  push([
    #("event", json.String("stream_delta")),
    #(
      "body",
      json.Object([
        #("strand", json.String(strand)),
        #("op", json.String(operation)),
        #("kind", json.String("text")),
        #("text", json.String(text)),
      ]),
    ),
  ])
}

fn begin(id, transfer, window, next_seq) {
  reply(
    id,
    "snapshot_begin",
    json.Object([
      #("snapshot_id", json.String(transfer)),
      #("session_id", json.String("A")),
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
      #("next_seq", json.Int(next_seq)),
      #("oldest_seq", json.Null),
      #("window", json.String(window)),
      #("complete_history", json.Bool(False)),
      #("record_bytes_limit", json.Int(snapshot.record_limit)),
      #("fragment_bytes_limit", json.Int(snapshot.piece_limit)),
    ]),
  )
}

fn piece(id, transfer) {
  let data = metadata()
  reply(
    id,
    "snapshot_chunk",
    json.Object([
      #("snapshot_id", json.String(transfer)),
      #("index", json.Int(0)),
      #("kind", json.String("metadata")),
      #("record_id", json.String("metadata")),
      #("record_seq", json.Null),
      #("total_bytes", json.Int(string.byte_size(data))),
      #("offset", json.Int(0)),
      #(
        "data",
        json.String(bit_array.base64_encode(bit_array.from_string(data), True)),
      ),
    ]),
  )
}

fn end(id, transfer, next_seq) {
  reply(
    id,
    "snapshot_end",
    json.Object([
      #("snapshot_id", json.String(transfer)),
      #("index", json.Int(1)),
      #("next_seq", json.Int(next_seq)),
      #("more_after", json.Null),
    ]),
  )
}

// One completed transfer: the begin, its one metadata fragment and the end.
// Request identities are consecutive because the lane allocates the next one
// for each credit it spends.
fn transfer(first, id, window, next_seq) {
  [
    begin(first, id, window, next_seq),
    piece(first + 1, id),
    end(first + 2, id, next_seq),
  ]
}

// What a fixture reads off a capture to tell live delivery from the fallback.
fn provenance(update) {
  case update {
    session_channel.Captured(trigger:, ..) -> Ok(trigger)
    _other -> Error(Nil)
  }
}

fn feed(channel, messages) {
  list.fold(messages, #(channel, []), fn(acc, message) {
    let #(channel, updates) = session_channel.receive(acc.0, message)
    #(channel, list.append(acc.1, updates))
  })
}

// A lane which has completed its initial capture at sequence ten, plus the
// recorder that saw every request it issued.
fn synchronized() {
  let issued = process.new_subject()
  let trace =
    attempt.Trace(attempt.Id(1), fn(event) { process.send(issued, event) })
  let channel =
    session_channel.replay_traced(
      snapshot.Expected("A", "epoch", "incarnation"),
      fn() { 0 },
      trace,
    )
  let #(ready, updates) = feed(channel, transfer(1, "1:1", "recent", 10))
  let assert [session_channel.Captured(..)] = updates
    as "the initial capture completes before any push is delivered"
  #(ready, issued)
}

// The requests the lane wrote, newest last. Received and lifecycle events are
// dropped: only what went out identifies the transition under test.
fn requests(issued) {
  drain(issued, [])
}

fn drain(issued, collected) {
  case process.receive(issued, 0) {
    Error(Nil) -> list.reverse(collected)
    Ok(attempt.Issued(_, request)) -> drain(issued, [request, ..collected])
    Ok(_) -> drain(issued, collected)
  }
}

pub fn a_notice_in_ready_issues_its_catch_up_before_the_idle_refresh_test() {
  let #(ready, issued) = synchronized()
  let assert [attempt.Request(2, "snapshot_next", _), ..] = requests(issued)
    as "the initial capture spends its credits and leaves the lane ready"

  let #(notified, updates) = session_channel.receive(ready, notice("main", 10))
  assert updates == [] as "a notice is not itself a visible change"
  assert session_channel.in_flight(notified)
    as "the catch-up goes out on the notice, not at the next idle refresh"
  assert requests(issued)
    == [attempt.Request(4, "catch_up", attempt.Cursor(10))]
    as "the catch-up asks from the cursor the completed cut left"

  // Nothing about the notice changes what the reply has to be: the lane is in
  // an ordinary catch-up transfer and completes it in the ordinary way.
  let #(_, updates) = feed(notified, transfer(4, "1:2", "catch_up", 12))
  assert list.map(updates, provenance) == [Ok(session_channel.Notified)]
    as "the capture that paints the answer is the notice's, not a refresh's"
}

pub fn a_notice_for_a_held_sequence_or_before_any_cut_changes_nothing_test() {
  let #(ready, issued) = synchronized()
  let _ = requests(issued)

  let #(same, updates) = session_channel.receive(ready, notice("main", 9))
  assert updates == []
  assert !session_channel.in_flight(same)
    as "a sequence the lane already holds asks for nothing"
  assert requests(issued) == []

  // Before the first cut there is no cursor to catch up from, and the initial
  // capture is already fetching everything the notice could describe.
  let fresh =
    session_channel.replay_with_clock(
      snapshot.Expected("A", "epoch", "incarnation"),
      fn() { 0 },
    )
  let #(_, updates) = session_channel.receive(fresh, notice("main", 3))
  assert updates == []
}

pub fn a_notice_in_flight_is_spent_at_the_next_ready_transition_test() {
  let #(ready, issued) = synchronized()
  let _ = requests(issued)

  // One notice opens a transfer, and a second lands in the middle of it.
  let #(capturing, _) = session_channel.receive(ready, notice("main", 10))
  let #(capturing, updates) = feed(capturing, [begin(4, "1:2", "catch_up", 12)])
  assert updates == []
  let #(deferred, updates) =
    session_channel.receive(capturing, notice("main", 12))
  assert updates == [] as "a notice mid-transfer defers rather than failing"
  let _ = requests(issued)

  // The lane's own clock has not reached its refresh instant, so the capture
  // that goes out here is the deferred notice being spent and nothing else.
  let #(spent, updates) = feed(deferred, [piece(5, "1:2"), end(6, "1:2", 12)])
  assert list.map(updates, provenance) == [Ok(session_channel.Notified)]
  assert session_channel.in_flight(spent)
    as "the deferred notice captures at the ready transition, not at +250ms"
  let assert [
    attempt.Request(6, "snapshot_next", _),
    attempt.Request(7, "catch_up", attempt.Cursor(12)),
  ] = requests(issued)
    as "the transfer's last credit, then the deferred notice's catch-up"

  // And it is spent exactly once: the second capture leaves nothing owed, so
  // the lane goes back to waiting for its refresh instant.
  let #(settled, _) = feed(spent, transfer(7, "1:3", "catch_up", 12))
  assert !session_channel.in_flight(settled)
  let _ = requests(issued)
  let #(_, updates) = session_channel.tick(settled)
  assert updates == []
  assert requests(issued) == []
    as "a spent notice does not keep issuing catch-ups of its own"
}

pub fn a_stream_delta_is_read_in_every_open_phase_without_moving_it_test() {
  let #(ready, issued) = synchronized()
  let _ = requests(issued)
  let streamed = [
    session_channel.Streamed(
      strand: "main",
      operation: "op-1",
      kind: "text",
      text: "hel",
    ),
  ]

  let #(after_ready, updates) =
    session_channel.receive(ready, delta("main", "op-1", "hel"))
  assert updates == streamed
  assert !session_channel.in_flight(after_ready)
    as "a fragment in Ready starts no request"
  assert requests(issued) == []

  // The three in-flight phases: awaiting a begin, mid-transfer, and awaiting
  // an auxiliary reply. A fragment leaves each of them exactly where it was.
  let #(awaiting, _) = session_channel.receive(after_ready, notice("main", 10))
  let #(awaiting, updates) =
    session_channel.receive(awaiting, delta("main", "op-1", "hel"))
  assert updates == streamed

  let #(receiving, _) = feed(awaiting, [begin(4, "1:2", "catch_up", 12)])
  let #(receiving, updates) =
    session_channel.receive(receiving, delta("main", "op-1", "hel"))
  assert updates == streamed

  // The transfer continues from the credit it held, which is the proof the
  // fragment consumed none of it.
  let #(captured, updates) =
    feed(receiving, [piece(5, "1:2"), end(6, "1:2", 12)])
  let assert [session_channel.Captured(..)] = updates
    as "a fragment mid-transfer neither spends credit nor fails the lane"

  let #(replying, _) = session_channel.submit(captured, protocol.models(1))
  let #(replying, updates) =
    session_channel.receive(replying, delta("main", "op-1", "hel"))
  assert updates == streamed
  assert session_channel.in_flight(replying)
    as "a fragment while a command is outstanding leaves it outstanding"
}

pub fn a_pushed_error_is_an_auxiliary_refusal_and_leaves_the_socket_open_test() {
  let #(ready, _) = synchronized()
  let #(open, updates) =
    session_channel.receive(
      ready,
      push([
        #("event", json.String("error")),
        #(
          "body",
          json.Object([
            #("code", json.String("code_conflict")),
            #("message", json.String("held prompt could not start")),
          ]),
        ),
      ]),
    )
  assert updates
    == [
      session_channel.Auxiliary(protocol.ServerError(
        code: "code_conflict",
        message: "held prompt could not start",
      )),
    ]

  // Still usable: the lane is ready and takes the next notice as it would
  // have before the refusal, which a closed lane could not do.
  let #(capturing, _) = session_channel.receive(open, notice("main", 10))
  assert session_channel.in_flight(capturing)
    as "a failed drain on the daemon does not retire this terminal's lane"
}

pub fn an_unknown_push_is_dropped_and_a_mismatched_reply_still_fails_test() {
  let #(ready, issued) = synchronized()
  let _ = requests(issued)
  let #(same, updates) =
    session_channel.receive(
      ready,
      push([
        #("event", json.String("weather")),
        #("body", json.Object([])),
      ]),
    )
  assert updates == [] as "a daemon ahead of this terminal cannot close it"
  assert !session_channel.in_flight(same)

  // A correlated frame in `Ready` names a request that has already finished,
  // and that is still a protocol violation.
  let #(_, updates) =
    session_channel.receive(
      same,
      reply(
        3,
        "mutation_outcome",
        json.Object([#("status", json.String("admitted"))]),
      ),
    )
  let assert [session_channel.Failed(_)] = updates
    as "an unsolicited correlated reply still closes the socket"
}

pub fn a_queued_prompt_is_an_acknowledged_submission_not_a_conflict_test() {
  let #(ready, _) = synchronized()
  let #(sent, disposition) =
    session_channel.submit(ready, protocol.prompt(1, "main", "next turn"))
  let assert session_channel.Sent("prompt", id) = disposition
    as "an operator lane admits a prompt once its cut exists"

  let #(_, updates) =
    session_channel.receive(
      sent,
      reply(
        id,
        "mutation_outcome",
        json.Object([#("status", json.String("queued"))]),
      ),
    )
  assert updates == [session_channel.Acknowledged("prompt", "queued")]
}

// The terminal's own model, holding a synchronized lane, so that a pushed
// frame can be followed all the way to what a reader would see.
fn attached() {
  let #(ready, _) = synchronized()
  tui.Model(
    ..tui.new_model(connection.new_inbox(), workspace.Context("test", None)),
    peer: tui.Replaying,
    channel: Some(ready),
  )
}

pub fn pushed_deltas_render_as_one_continuous_answer_per_operation_test() {
  let model =
    list.fold(
      [delta("main", "op-1", "Hel"), delta("main", "op-1", "lo")],
      attached(),
      tui.accept_connection_message,
    )
  assert model.streams == [tui.Stream("main", "op-1", "text", ["lo", "Hel"])]
    as "fragments of one operation accumulate rather than replacing each other"

  // The next operation is a different answer, so it starts the region over
  // instead of appending to the one that has finished.
  let next = tui.accept_connection_message(model, delta("main", "op-2", "New"))
  assert next.streams == [tui.Stream("main", "op-2", "text", ["New"])]
}

pub fn a_queued_prompt_reads_as_a_booked_turn_rather_than_a_refusal_test() {
  let model = attached()
  let assert Some(channel) = model.channel as "the fixture lane is attached"
  let #(sent, disposition) =
    session_channel.submit(channel, protocol.prompt(1, "main", "next turn"))
  let assert session_channel.Sent("prompt", id) = disposition
    as "an operator lane admits a prompt once its cut exists"

  let queued =
    tui.accept_connection_message(
      tui.Model(..model, channel: Some(sent), submitting: Some("main")),
      reply(
        id,
        "mutation_outcome",
        json.Object([#("status", json.String("queued"))]),
      ),
    )
  assert queued.submitting == None
    as "nothing is running here yet; the daemon holds the prompt"
  assert string.contains(queued.notice, "queued")
    as "the operator is told the turn is booked, not that it was refused"
}
