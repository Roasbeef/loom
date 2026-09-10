//// Local attempt custody is independent of equal per-socket transport IDs.
//// These fixtures use actual v2 bodies and the live channel/transfer decoder;
//// no synthesized presentation snapshots bypass the credited protocol.

import core/clock
import core/codec
import core/entry
import core/ids
import core/json
import core/message
import etui/backend
import etui/widgets/textarea
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import machine/codec as machine_codec
import machine/strand
import tui
import tui/attachment
import tui/attempt
import tui/attempt_replay
import tui/composer
import tui/connection
import tui/frame
import tui/protocol
import tui/recording
import tui/session_channel
import tui/snapshot
import tui/virtual_backend
import tui/workspace

fn metadata() {
  metadata_with_peers([])
}

fn metadata_with_peers(peers) {
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
      #("peers", json.Array(peers)),
    ]),
  )
}

fn frame(id, event, body) {
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

fn events(number, session) {
  events_with_identity(number, session, metadata(), "Alice", "operator")
}

fn events_with_identity(number, session, data, name, role) {
  let id = attempt.Id(number)
  [
    attempt.Started(id, snapshot.Expected(session, "epoch", "incarnation")),
    attempt.Issued(id, attempt.Request(1, "subscribe", attempt.NoSelection)),
    attempt.Received(
      id,
      frame(
        1,
        "snapshot_begin",
        json.Object([
          #("snapshot_id", json.String("1:1")),
          #("session_id", json.String(session)),
          #("epoch", json.String("epoch")),
          #("incarnation", json.String("incarnation")),
          #("connection_id", json.String("connection")),
          #(
            "origin",
            json.Object([
              #("principal", json.String("alice")),
              #("name", json.String(name)),
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
    ),
    attempt.Issued(
      id,
      attempt.Request(2, "snapshot_next", attempt.Credit("1:1", 0)),
    ),
    attempt.Received(
      id,
      frame(
        2,
        "snapshot_chunk",
        json.Object([
          #("snapshot_id", json.String("1:1")),
          #("index", json.Int(0)),
          #("kind", json.String("metadata")),
          #("record_id", json.String("metadata")),
          #("record_seq", json.Null),
          #("total_bytes", json.Int(string.byte_size(data))),
          #("offset", json.Int(0)),
          #(
            "data",
            json.String(bit_array.base64_encode(
              bit_array.from_string(data),
              True,
            )),
          ),
        ]),
      ),
    ),
    attempt.Issued(
      id,
      attempt.Request(3, "snapshot_next", attempt.Credit("1:1", 1)),
    ),
    attempt.Received(
      id,
      frame(
        3,
        "snapshot_end",
        json.Object([
          #("snapshot_id", json.String("1:1")),
          #("index", json.Int(1)),
          #("next_seq", json.Int(10)),
          #("more_after", json.Null),
        ]),
      ),
    ),
  ]
}

fn run(state, events) {
  list.try_fold(events, #(state, []), fn(acc, event) {
    use #(state, changes) <- result.map(attempt_replay.apply(acc.0, event))
    #(state, list.append(acc.1, changes))
  })
}

pub fn owner_banner_tracks_solo_and_multiplayer_presence_test() {
  let peer = fn(connection) {
    json.Object([
      #("connection_id", json.String(connection)),
      #(
        "origin",
        json.Object([
          #("principal", json.String("alice")),
          #("name", json.String("Owner")),
        ]),
      ),
      #("role", json.String("owner")),
    ])
  }
  let run = fn(peers) {
    replay_run(
      list.append(
        events_with_identity(
          1,
          "A",
          metadata_with_peers(peers),
          "Owner",
          "owner",
        ),
        [attempt.Adopted(attempt.Id(1))],
      ),
    )
  }

  // These cuts go through the real credited channel and adoption reducer,
  // rather than constructing the banner or its presence predicate in a test.
  let solo = run([peer("connection")])
  assert solo.final.replay_error == None
  assert solo.final.notice == "1 present"
  assert list.any(solo.final.transcript, fn(line) {
    line.text == "Attached · 1 present"
  })
  assert !list.any(solo.final.transcript, fn(line) {
    string.contains(line.text, "Owner")
  })
  let multiplayer = run([peer("connection"), peer("other-tab")])
  assert multiplayer.final.replay_error == None
  assert multiplayer.final.notice == "Owner · owner · 2 present"
  assert list.any(multiplayer.final.transcript, fn(line) {
    line.text == "Attached as: Owner · owner · 2 present"
  })
}

pub fn attempt_replay_equal_transport_ids_never_adopt_a_failed_candidate_test() {
  let assert Ok(#(a, [])) = run(attempt_replay.new(), events(1, "A"))
    as "a complete candidate is still invisible without adoption"
  let assert Ok(#(a, [attempt_replay.Adopt(cut, _)])) =
    attempt_replay.apply(a, attempt.Adopted(attempt.Id(1)))
    as "the first visible cut follows terminal adoption"
  assert cut.attachment.expected.session == "A"
  let assert Ok(#(failed, [])) =
    run(
      a,
      list.append(list.take(events(2, "B"), 3), [attempt.Closed(attempt.Id(2))]),
    )
    as "failed B releases partial reassembly without changing A"
  let assert Ok(#(candidate, [])) = run(failed, events(3, "B"))
    as "a new B attempt may reuse all server-local IDs"
  let assert Ok(#(b, [attempt_replay.Adopt(cut, _)])) =
    attempt_replay.apply(candidate, attempt.Adopted(attempt.Id(3)))
    as "only the completed replacement is adopted"
  assert cut.attachment.expected.session == "B"
  let assert Ok(#(unchanged, [])) =
    attempt_replay.apply(
      b,
      attempt.Received(attempt.Id(1), frame(1, "snapshot_end", json.Object([]))),
    )
    as "late old-A traffic retains its identity and is ignored after B adoption"
  assert unchanged == b
}

pub fn attempt_replay_requires_request_credit_and_rejects_overlapping_candidates_test() {
  let source = events(1, "A")
  let without_credit =
    list.filter(source, fn(event) {
      case event {
        attempt.Issued(_, attempt.Request(2, _, _)) -> False
        _ -> True
      }
    })
  let assert Error(_) = run(attempt_replay.new(), without_credit)
    as "structural chunk continuity does not prove a request was sent"
  let assert Ok(#(pending, _)) = run(attempt_replay.new(), list.take(source, 3))
    as "one transfer has begun"
  let assert Error(_) =
    attempt_replay.apply(pending, attempt.Adopted(attempt.Id(1)))
    as "a begin frame cannot authorize adoption"
  let assert Error(_) =
    attempt_replay.apply(
      pending,
      attempt.Started(
        attempt.Id(2),
        snapshot.Expected("B", "epoch", "incarnation"),
      ),
    )
    as "a second candidate cannot grow an unbounded attempt map"
  let assert Error(_) =
    attempt_replay.apply(
      pending,
      attempt.Issued(
        attempt.Id(1),
        attempt.Request(2, "snapshot_next", attempt.Credit("1:1", 4)),
      ),
    )
    as "the exact next index must match the live decoder's credit"
}

pub fn attempt_recording_round_trips_bounded_selectors_and_refuses_mixed_formats_test() {
  let moments = [
    recording.Moment(0, recording.LocalFormatTwo),
    ..list.index_map(events(1, "A"), fn(event, index) {
      recording.Moment(index + 1, recording.Attempt(event))
    })
  ]
  let text = moments |> list.map(recording.encode_line) |> string.join("\n")
  assert recording.decode_text(text) == Ok(moments)
  let assert Error(_) =
    recording.decode_text(
      text
      <> "\n"
      <> recording.encode_line(recording.Moment(
        20,
        recording.Arrived(connection.Connected),
      )),
    )
    as "untagged legacy traffic cannot enter a format-two replay"
  let assert Error(_) =
    recording.decode_text(
      list.drop(moments, 1)
      |> list.map(recording.encode_line)
      |> string.join("\n"),
    )
    as "attempt traffic requires the explicit local version header"
  let request =
    attempt.Issued(
      attempt.Id(1),
      attempt.Request(5, "escalations_get", attempt.Decisions(["a", "b"])),
    )
  assert attempt.decode(json.Object(attempt.encode(request))) == Ok(request)
}

pub fn attempt_replay_failed_selection_and_closed_live_lane_release_buffers_test() {
  let assert Ok(#(state, _)) =
    run(
      attempt_replay.new(),
      list.append(events(1, "A"), [attempt.Adopted(attempt.Id(1))]),
    )
    as "one visible attachment exists"
  let assert Ok(#(failed, [attempt_replay.Rejected("selection timed out")])) =
    attempt_replay.apply(
      state,
      attempt.Failed(attempt.Id(2), "selection timed out"),
    )
    as "failure before Prepared has no target or frames, but retains its diagnosis"
  let assert Ok(#(next, [])) = run(failed, events(3, "B"))
    as "failed selection leaves the one candidate slot reusable"
  let assert Ok(#(next, _)) =
    attempt_replay.apply(next, attempt.Adopted(attempt.Id(3)))
    as "the successful replacement is adopted"
  let assert Ok(#(closed, [])) =
    attempt_replay.apply(next, attempt.Closed(attempt.Id(3)))
    as "a terminal quit releases the replay's live protocol buffer"
  let assert Ok(#(same, [])) =
    attempt_replay.apply(
      closed,
      attempt.Received(attempt.Id(3), connection.Closed("late close")),
    )
    as "late closed-owner mail cannot restore a retired lane"
  assert same == closed
  let failure =
    recording.Moment(
      4,
      recording.Attempt(attempt.Failed(attempt.Id(2), "failure")),
    )
  assert recording.decode_line(recording.encode_line(failure)) == Ok(failure)
}

pub fn attempt_replay_last_unconfirmed_submission_survives_adopting_another_session_test() {
  let source =
    list.flatten([
      events(1, "A"),
      [
        attempt.Adopted(attempt.Id(1)),
        attempt.Issued(
          attempt.Id(1),
          attempt.Request(4, "prompt", attempt.NoSelection),
        ),
        attempt.Received(attempt.Id(1), connection.Closed("reply lost")),
        attempt.Closed(attempt.Id(1)),
      ],
      events(2, "B"),
      [attempt.Adopted(attempt.Id(2))],
    ])
  let inbox = connection.new_inbox()
  let model =
    tui.Model(
      ..tui.new_model(inbox, workspace.Context("replay", None)),
      peer: tui.Replaying,
    )
  let script =
    virtual_backend.script(
      backend.TerminalSize(110, 30),
      list.map(source, virtual_backend.Attempt),
      inbox,
    )
    |> virtual_backend.with_attempts(model.replay_inbox)
  let assert Ok(run) = tui.run_script(model, script)
    as "the same reducer renders the recorded lost-response path without a socket"
  assert run.final.session == "B"
  assert run.final.channel == None
  assert run.final.unconfirmed
    == Some(tui.UnconfirmedSubmission("A", "prompt", 4))
  assert list.any(run.final.transcript, fn(line) {
    string.contains(line.text, "Last unconfirmed submission: session A")
  })
    as "adoption does not imply the earlier mutation was resolved"
}

// The initial empty cut is already painted before this catch-up arrives. No
// live operation or key event can invalidate the frame on the cut's behalf.
pub fn credited_idle_cut_repaints_settled_answer_without_keyboard_input_test() {
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(1000), 987))
  let answer = "Settled answer painted without a key"
  let row =
    entry.MessageEntry(
      id,
      None,
      10,
      1000,
      message.AssistantMessage(
        [message.AssistantText(answer, None)],
        "test",
        "test",
        "test",
        None,
        None,
        None,
        message.Usage(
          0,
          0,
          0,
          0,
          None,
          None,
          0,
          message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
        ),
        message.Stop,
        None,
        None,
        None,
        Some(True),
        1000,
      ),
      False,
    )
  let source =
    list.flatten([
      events(1, "A"),
      [attempt.Adopted(attempt.Id(1))],
      settled_catch_up(row, 4),
    ])
  let inbox = connection.new_inbox()
  let model =
    tui.Model(
      ..tui.new_model_with_clock(inbox, workspace.Context("replay", None), fn() {
        -1000
      }),
      peer: tui.Replaying,
    )
  let script =
    virtual_backend.script(
      backend.TerminalSize(110, 30),
      list.map(source, virtual_backend.Attempt),
      inbox,
    )
    |> virtual_backend.with_attempts(model.replay_inbox)
  let assert Ok(run) = tui.run_script(model, script)
    as "credited traffic and idle ticks alone drive the real buffered loop"
  assert run.final.replay_error == None
  assert list.map(run.final.records, fn(record) { record.entry.id }) == [id]
  let assert Ok(last) = list.last(run.frames)
    as "the backend captured its final painted buffer"
  assert string.contains(frame.buffer_to_text(last), answer)
    as "settlement must invalidate the frame, not only the transcript row cache"
  assert list.any(run.frames, fn(painted) {
    let text = frame.buffer_to_text(painted)
    string.contains(text, "Attached as: Alice")
    && !string.contains(text, answer)
  })
    as "an earlier adopted frame was painted before the answer arrived"
}

// A replay used to send cuts straight to `apply_cut`, which always
// invalidates the transcript and restarts the activity indicator. The live
// client sends them to `reconcile_cut`, whose whole point is that a cut with
// the same `next_seq` and metadata as the last one changes nothing on screen.
// A replay that repaints frames the live client did not is not reproducing the
// session, so both paths now use the same reducer; the outbound half of it,
// `request_decisions`, is inert while the peer is `Replaying`.
pub fn a_replay_leaves_an_unchanged_cut_alone_test() {
  let row = settled_row("Answer that arrives once")
  let attached =
    list.flatten([events(1, "A"), [attempt.Adopted(attempt.Id(1))]])
  let once = replay_run(list.flatten([attached, settled_catch_up(row, 4)]))

  // The second catch-up carries the same entry, the same metadata and the
  // same `next_seq`; only its request and transfer identities differ, which
  // is exactly the reconciliation the adopted channel runs every 250 ms.
  let twice =
    replay_run(
      list.flatten([
        attached,
        settled_catch_up(row, 4),
        idle_catch_up(row, 8),
      ]),
    )
  assert once.final.replay_error == None
  assert twice.final.replay_error == None
  assert twice.final.render_revision == once.final.render_revision
    as "an equal cut must not invalidate the replayed transcript"
  assert list.map(twice.final.records, fn(record) { record.entry.id })
    == list.map(once.final.records, fn(record) { record.entry.id })
  assert !list.any(twice.final.transcript, fn(line) {
    string.contains(line.text, "conversation is not attached")
  })
    as "a replay asks for no decision lookup, so it reports no lost one"
}

// One durable assistant turn, settled, at seq 10.
fn settled_row(answer: String) -> entry.Entry {
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(1000), 987))
  entry.MessageEntry(
    id,
    None,
    10,
    1000,
    message.AssistantMessage(
      [message.AssistantText(answer, None)],
      "test",
      "test",
      "test",
      None,
      None,
      None,
      message.Usage(
        0,
        0,
        0,
        0,
        None,
        None,
        0,
        message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
      ),
      message.Stop,
      None,
      None,
      None,
      Some(True),
      1000,
    ),
    False,
  )
}

// Drives one scripted attempt stream through the shipped loop under the
// virtual backend, with nothing attached and nothing sent.
fn replay_run(source: List(attempt.Event)) {
  let inbox = connection.new_inbox()
  let model =
    tui.Model(
      ..tui.new_model_with_clock(inbox, workspace.Context("replay", None), fn() {
        -1000
      }),
      peer: tui.Replaying,
    )
  let script =
    virtual_backend.script(
      backend.TerminalSize(110, 30),
      list.map(source, virtual_backend.Attempt),
      inbox,
    )
    |> virtual_backend.with_attempts(model.replay_inbox)
  let assert Ok(run) = tui.run_script(model, script)
    as "the shipped reducer replays credited traffic without a socket"
  run
}

// The metadata cut both catch-ups carry: identical bytes, so a second
// delivery of it is an equal cut by `reconcile_cut`'s own test.
fn catch_up_metadata(row: entry.Entry) -> String {
  let cell = fn(namespace, value) {
    json.Object([
      #("namespace", json.String(namespace)),
      #("key", json.String("main")),
      #("seq", json.Int(10)),
      #("value", value),
    ])
  }
  let assert Ok(json.Object(fields)) = json.parse(metadata())
    as "fixture metadata is valid JSON"
  let data =
    json.to_string(
      json.Object([
        #(
          "cells",
          json.Array([
            cell("strand.leaf", json.String(ids.entry_id_to_string(row.id))),
            cell(
              "strand.state",
              machine_codec.encode_strand_state(strand.StrandState(None, [])),
            ),
            cell(
              "strand.config",
              machine_codec.encode_configuration(
                strand.StrandConfiguration(
                  strand.ModelIdentity("test", "test"),
                  strand.ThinkingOff,
                  [],
                ),
              ),
            ),
          ]),
        ),
        ..list.filter(fields, fn(field) { field.0 != "cells" })
      ]),
    )
  data
}

// A reconciliation that finds nothing new: the cursor has caught up, the
// cut's `next_seq` is unchanged and the metadata is byte-identical to the
// last one. This is what the adopted channel's 250 ms `catch_up` produces on
// an idle session, and what `reconcile_cut`'s fast path exists for.
fn idle_catch_up(row: entry.Entry, first_request: Int) {
  let id = attempt.Id(1)
  let transfer = "1:" <> int.to_string(first_request)
  let data = catch_up_metadata(row)
  list.flatten([
    [
      attempt.Issued(
        id,
        attempt.Request(first_request, "catch_up", attempt.Cursor(11)),
      ),
      attempt.Received(
        id,
        frame(
          first_request,
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
            #("next_seq", json.Int(11)),
            #("oldest_seq", json.Int(11)),
            #("window", json.String("catch_up")),
            #("complete_history", json.Bool(False)),
            #("record_bytes_limit", json.Int(snapshot.record_limit)),
            #("fragment_bytes_limit", json.Int(snapshot.piece_limit)),
          ]),
        ),
      ),
    ],
    credited_piece(
      first_request + 1,
      transfer,
      0,
      "metadata",
      "metadata",
      json.Null,
      data,
    ),
    [
      attempt.Issued(
        id,
        attempt.Request(
          first_request + 2,
          "snapshot_next",
          attempt.Credit(transfer, 1),
        ),
      ),
      attempt.Received(
        id,
        frame(
          first_request + 2,
          "snapshot_end",
          json.Object([
            #("snapshot_id", json.String(transfer)),
            #("index", json.Int(1)),
            #("next_seq", json.Int(11)),
            #("more_after", json.Null),
          ]),
        ),
      ),
    ],
  ])
}

fn settled_catch_up(row: entry.Entry, first_request: Int) {
  let id = attempt.Id(1)
  let transfer = "1:" <> int.to_string(first_request)
  let data = catch_up_metadata(row)
  [
    attempt.Issued(
      id,
      attempt.Request(first_request, "catch_up", attempt.Cursor(10)),
    ),
    attempt.Received(
      id,
      frame(
        first_request,
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
          #("next_seq", json.Int(11)),
          #("oldest_seq", json.Int(10)),
          #("window", json.String("catch_up")),
          #("complete_history", json.Bool(False)),
          #("record_bytes_limit", json.Int(snapshot.record_limit)),
          #("fragment_bytes_limit", json.Int(snapshot.piece_limit)),
        ]),
      ),
    ),
    ..list.flatten([
      credited_piece(
        first_request + 1,
        transfer,
        0,
        "metadata",
        "metadata",
        json.Null,
        data,
      ),
      credited_piece(
        first_request + 2,
        transfer,
        1,
        "entry",
        ids.entry_id_to_string(row.id),
        json.Int(10),
        json.to_string(codec.encode_entry(row)),
      ),
      [
        attempt.Issued(
          id,
          attempt.Request(
            first_request + 3,
            "snapshot_next",
            attempt.Credit(transfer, 2),
          ),
        ),
        attempt.Received(
          id,
          frame(
            first_request + 3,
            "snapshot_end",
            json.Object([
              #("snapshot_id", json.String(transfer)),
              #("index", json.Int(2)),
              #("next_seq", json.Int(11)),
              #("more_after", json.Null),
            ]),
          ),
        ),
      ],
    ])
  ]
}

fn credited_piece(
  request_id,
  transfer,
  index,
  kind,
  record_id,
  sequence,
  data,
) {
  let id = attempt.Id(1)
  [
    attempt.Issued(
      id,
      attempt.Request(
        request_id,
        "snapshot_next",
        attempt.Credit(transfer, index),
      ),
    ),
    attempt.Received(
      id,
      frame(
        request_id,
        "snapshot_chunk",
        json.Object([
          #("snapshot_id", json.String(transfer)),
          #("index", json.Int(index)),
          #("kind", json.String(kind)),
          #("record_id", json.String(record_id)),
          #("record_seq", sequence),
          #("total_bytes", json.Int(string.byte_size(data))),
          #("offset", json.Int(0)),
          #(
            "data",
            json.String(bit_array.base64_encode(
              bit_array.from_string(data),
              True,
            )),
          ),
        ]),
      ),
    ),
  ]
}

fn read_channel(channel, source) {
  list.fold(source, #(channel, []), fn(acc, event) {
    case event {
      attempt.Started(..) -> acc
      attempt.Issued(_, request) -> {
        let assert Ok(next) = session_channel.replay_issued(acc.0, request)
          as "retaining an unsent mutation cannot consume a snapshot credit ID"
        #(next, acc.1)
      }
      attempt.Received(_, incoming) -> {
        let #(next, updates) = session_channel.receive(acc.0, incoming)
        #(next, list.append(acc.1, updates))
      }
      _ -> panic as "fixture contains only request and response traffic"
    }
  })
}

fn waiting_capture(clock) {
  let channel =
    session_channel.replay_with_clock(
      snapshot.Expected("A", "epoch", "incarnation"),
      clock,
    )
  let #(ready, _) = read_channel(channel, events(1, "A"))
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(1000), 654))
  let row =
    entry.MessageEntry(
      id,
      None,
      10,
      1000,
      message.UserMessage([message.UserText("prior turn", None)], 1000, None),
      False,
    )
  let source = settled_catch_up(row, 4)
  let #(capturing, _) = read_channel(ready, list.take(source, 2))
  #(capturing, list.drop(source, 2))
}

pub fn unsent_command_waits_for_valid_end_and_never_retries_sent_mutation_test() {
  let #(capturing, remaining) = waiting_capture(fn() { 0 })
  let #(waiting, admission) =
    session_channel.submit(
      capturing,
      protocol.prompt(900, "main", "immutable original"),
    )
  assert admission == session_channel.Waiting("prompt")
  assert session_channel.has_unsent(waiting)
  let #(same, second) =
    session_channel.submit(
      waiting,
      protocol.prompt(901, "main", "must not replace"),
    )
  let assert session_channel.DefinitelyNotSent(_) = second
    as "one local slot cannot be overwritten"
  assert same == waiting
  let #(before_end, updates) =
    read_channel(waiting, list.take(remaining, list.length(remaining) - 1))
  assert updates == []
    as "no mutation is sent while any credited record is incomplete"
  let #(sent, updates) =
    read_channel(before_end, list.drop(remaining, list.length(remaining) - 1))
  let assert [
    session_channel.Captured(_, _, session_channel.Refreshed),
    session_channel.Submission(session_channel.Sent("prompt", 8)),
  ] = updates
    as "valid End alone allocates exactly the next unused wire ID"
  assert !session_channel.has_unsent(sent)
  let #(same, rejected) =
    session_channel.submit(sent, protocol.prompt(1, "main", "second mutation"))
  let assert session_channel.DefinitelyNotSent(_) = rejected
    as "no mutation queues behind a sent mutation"
  assert same == sent
  let #(closed, updates) =
    session_channel.receive(sent, connection.Closed("lost reply"))
  assert updates
    == [
      session_channel.UnknownOutcome("prompt", 8),
      session_channel.Failed("lost reply"),
    ]
  let #(_, repeated) =
    session_channel.receive(closed, connection.Closed("already closed"))
  assert !list.any(repeated, fn(update) {
    case update {
      session_channel.UnknownOutcome(..) -> True
      _ -> False
    }
  })
}

pub fn unsent_command_failure_timeout_and_initial_capture_never_claim_unknown_test() {
  let initial =
    session_channel.replay(snapshot.Expected("A", "epoch", "incarnation"))
  let #(same, refusal) =
    session_channel.submit(initial, protocol.prompt(1, "main", "too early"))
  assert same == initial
  let assert session_channel.DefinitelyNotSent(_) = refusal
    as "initial synchronization cannot retain user intent"
  let clock_values = process.new_subject()
  let #(capturing, _) =
    waiting_capture(fn() {
      process.receive(clock_values, 0) |> result.unwrap(0)
    })
  let #(waiting, _) =
    session_channel.submit(capturing, protocol.prompt(1, "main", "unsent"))
  list.each(
    [connection.NetworkFault("revoked"), connection.Incoming("invalid capture")],
    fn(failure) {
      let #(closed, updates) = session_channel.receive(waiting, failure)
      let assert [
        session_channel.Submission(session_channel.DefinitelyNotSent(_)),
        session_channel.Failed(_),
      ] = updates
        as "failed or revoked unsent work has a definite non-send outcome"
      assert !session_channel.has_unsent(closed)
    },
  )
  process.send(clock_values, 30_001)
  let #(closed, updates) = session_channel.tick(waiting)
  assert updates
    == [
      session_channel.Submission(session_channel.DefinitelyNotSent(
        "conversation request timed out",
      )),
      session_channel.Failed("conversation request timed out"),
    ]
  assert !session_channel.has_unsent(closed)
}

fn waiting_model(source) {
  let #(channel, remaining) = waiting_capture(fn() { 0 })
  let #(channel, _) =
    session_channel.submit(channel, protocol.prompt(1, "main", "visible draft"))
  let model =
    tui.Model(
      ..tui.new_model(connection.new_inbox(), workspace.Context("test", None)),
      peer: tui.Replaying,
      channel: Some(channel),
      pending_submission: Some(source),
      input: textarea.state_from_string("visible draft"),
      attachments: [composer.Attachment("unchanged attachment", 5)],
      submission_mode: tui.SteerNow,
    )
  #(model, remaining)
}

fn finish_model(model, remaining) {
  list.fold(remaining, model, fn(model, event) {
    case event {
      attempt.Received(_, incoming) ->
        tui.accept_connection_message(model, incoming)
      attempt.Issued(..) -> model
      _ -> panic as "fixture contains only credited traffic"
    }
  })
}

pub fn unsent_composer_locks_then_cancels_without_abort_or_draft_copy_test() {
  let #(model, remaining) = waiting_model(tui.ComposerSubmission)
  let unchanged =
    list.fold(
      [
        backend.KeyPress("enter"),
        backend.KeyPress("x"),
        backend.KeyPress("backspace"),
        backend.Paste("replacement"),
        backend.KeyPress("tab"),
      ],
      model,
      fn(model, event) { tui.update(event, model) },
    )
  assert textarea.value(unchanged.input) == "visible draft"
  assert unchanged.submission_mode == tui.SteerNow
  assert unchanged.attachments == model.attachments
  assert unchanged.next_id == model.next_id
  let cancelled = tui.update(backend.KeyPress("esc"), unchanged)
  assert cancelled.pending_submission == None
  assert textarea.value(cancelled.input) == "visible draft"
  assert cancelled.submission_mode == tui.SteerNow
  assert cancelled.attachments == model.attachments
  assert cancelled.next_id == model.next_id
    as "Escape cancels unsent intent without emitting abort"
  let ended = finish_model(cancelled, remaining)
  assert ended.next_id == model.next_id
    as "later End cannot resurrect cancelled intent"
  assert textarea.value(ended.input) == "visible draft"
  let quit = tui.update(backend.KeyPress("ctrl+c"), model)
  assert quit.quit as "locking a draft must not disable terminal shutdown"
  assert quit.next_id == model.next_id
}

pub fn unsent_composer_clears_only_on_send_and_overlay_preserves_unrelated_text_test() {
  let #(model, remaining) = waiting_model(tui.ComposerSubmission)
  let sent = finish_model(model, remaining)
  assert sent.pending_submission == None
  assert textarea.value(sent.input) == ""
  assert sent.attachments == []
  assert sent.next_id == model.next_id + 1
  let #(overlay, remaining) = waiting_model(tui.OverlaySubmission)
  let sent = finish_model(overlay, remaining)
  assert textarea.value(sent.input) == "visible draft"
  assert sent.submission_mode == tui.SteerNow
  assert sent.attachments == overlay.attachments
  assert sent.pending_submission == None
  let #(model, _) = waiting_model(tui.ComposerSubmission)
  let failed =
    tui.accept_connection_message(model, connection.NetworkFault("revoked"))
  assert failed.pending_submission == None
  assert textarea.value(failed.input) == "visible draft"
  assert failed.attachments == model.attachments
  assert failed.unconfirmed == None
}

pub fn unsent_command_never_migrates_on_successful_or_failed_replacement_test() {
  let #(model, _) = waiting_model(tui.ComposerSubmission)
  let model = tui.Model(..model, session: "A")
  let failed =
    tui.candidate_outcome(
      model,
      attachment.idle(),
      Some(attachment.Failed("replacement refused")),
    )
  assert failed.pending_submission == None
  assert textarea.value(failed.input) == "visible draft"
  assert failed.session == "A"
  let assert Some(previous) = failed.channel
    as "failed replacement keeps the original channel"
  assert !session_channel.has_unsent(previous)

  let #(replacement, updates) =
    read_channel(
      session_channel.replay(snapshot.Expected("B", "epoch", "incarnation")),
      events(2, "B"),
    )
  let assert [session_channel.Captured(cut, view, _)] = updates
    as "replacement first cut was fully validated"
  let adopted =
    tui.candidate_outcome(
      model,
      attachment.idle(),
      Some(attachment.Adopted(
        replacement,
        cut,
        view,
        connection.new_inbox(),
        workspace.Context("B", None),
        None,
      )),
    )
  assert adopted.session == "B"
  assert adopted.pending_submission == None
  assert textarea.value(adopted.input) == "visible draft"
  let assert Some(channel) = adopted.channel
    as "the terminal adopted B's own channel"
  assert !session_channel.has_unsent(channel)
  assert adopted.unconfirmed == None
    as "cancellation of unsent work is not uncertain delivery"
  // Exactly one notice, and it is the one issued after the cut.
  // `cancel_pending` appends its own "Not sent" line first, but `render_cut`
  // replaces the whole transcript with the adopted session's, so only the
  // line written after adoption reaches the operator. A review read this as
  // a duplicate; it is not, and dropping the later line loses the notice.
  let notices =
    list.filter(adopted.transcript, fn(line) {
      string.contains(line.text, "target change") && line.speaker == tui.System
    })
  let assert [notice] = notices as "the unsent draft is reported once"
  assert notice.text == "Not sent: target changed from A; draft retained"
}

pub fn explicit_retirement_preserves_original_sent_identity_live_and_recorded_test() {
  let #(ready, _) =
    read_channel(
      session_channel.replay(snapshot.Expected("A", "epoch", "incarnation")),
      events(1, "A"),
    )
  let #(sent, disposition) =
    session_channel.submit(ready, protocol.prompt(900, "main", "sent once"))
  assert disposition == session_channel.Sent("prompt", 4)
  let #(closed, updates) = session_channel.retire(sent, "attachment replaced")
  assert updates == [session_channel.UnknownOutcome("prompt", 4)]
  assert session_channel.retire(closed, "again") == #(closed, [])
  let model =
    tui.Model(
      ..tui.new_model(connection.new_inbox(), workspace.Context("A", None)),
      session: "A",
      peer: tui.Replaying,
      channel: Some(sent),
    )
  let #(replacement, updates) =
    read_channel(
      session_channel.replay(snapshot.Expected("B", "epoch", "incarnation")),
      events(2, "B"),
    )
  let assert [session_channel.Captured(cut, view, _)] = updates
    as "B has a validated first cut"
  let adopted =
    tui.candidate_outcome(
      model,
      attachment.idle(),
      Some(attachment.Adopted(
        replacement,
        cut,
        view,
        connection.new_inbox(),
        workspace.Context("B", None),
        None,
      )),
    )
  assert adopted.session == "B"
  assert adopted.unconfirmed
    == Some(tui.UnconfirmedSubmission("A", "prompt", 4))

  // Existing Closed records carry the same outcome. Candidate-only closure
  // remains invisible, and a preceding Received close must not report twice.
  let source =
    list.flatten([
      events(1, "A"),
      [
        attempt.Adopted(attempt.Id(1)),
        attempt.Issued(
          attempt.Id(1),
          attempt.Request(4, "prompt", attempt.NoSelection),
        ),
        attempt.Closed(attempt.Id(1)),
      ],
      events(2, "B"),
      [attempt.Adopted(attempt.Id(2))],
    ])
  let moments = [
    recording.Moment(0, recording.LocalFormatTwo),
    ..list.index_map(source, fn(event, index) {
      recording.Moment(index + 1, recording.Attempt(event))
    })
  ]
  let encoded = list.map(moments, recording.encode_line) |> string.join("\n")
  let assert Ok(decoded) = recording.decode_text(encoded)
    as "the unchanged local format round-trips retirement"
  let assert Ok(frames) =
    tui.replay_steps(recording.to_steps(decoded), backend.TerminalSize(110, 30))
    as "recorded local close replays without a synthetic network frame"
  let assert Ok(last) = list.last(frames)
    as "replay paints its final attachment"
  assert string.contains(
    frame.buffer_to_text(last),
    "Last unconfirmed submission: session A",
  )
  let prefix = list.take(source, list.length(events(1, "A")) + 2)
  let assert Ok(#(state, _)) = run(attempt_replay.new(), prefix)
    as "the replay lane has one sent mutation"
  let assert Ok(#(state, first)) =
    attempt_replay.apply(
      state,
      attempt.Received(attempt.Id(1), connection.Closed("network loss")),
    )
    as "network loss publishes one unknown outcome"
  assert list.any(first, fn(change) {
    case change {
      attempt_replay.Update(session_channel.UnknownOutcome("prompt", 4)) -> True
      _ -> False
    }
  })
  let assert Ok(#(_, [])) =
    attempt_replay.apply(state, attempt.Closed(attempt.Id(1)))
    as "subsequent recorded local cleanup cannot publish uncertainty twice"
}

pub fn auxiliary_and_queued_edit_descriptors_round_trip_without_command_bodies_test() {
  let kinds = [
    "queued_input", "edit_queued_input", "worktree_diff", "live_jobs", "notes",
  ]
  list.each(kinds, fn(kind) {
    let request =
      attempt.Issued(
        attempt.Id(1),
        attempt.Request(4, kind, attempt.NoSelection),
      )
    let fields = attempt.encode(request)
    assert attempt.decode(json.Object(fields)) == Ok(request)

    // Queue text, replacement revision, job arguments, and repository paths
    // are not selectors. Ordinary commands retain only their kind and IDs.
    assert list.map(fields, fn(field) { field.0 })
      == ["t", "attempt", "id", "kind"]
    let moments = [
      recording.Moment(0, recording.LocalFormatTwo),
      recording.Moment(1, recording.Attempt(request)),
    ]
    let encoded =
      moments |> list.map(recording.encode_line) |> string.join("\n")
    assert recording.decode_text(encoded) == Ok(moments)
  })

  let unknown =
    attempt.Issued(
      attempt.Id(1),
      attempt.Request(4, "unrecognized_command", attempt.NoSelection),
    )
  assert attempt.decode(json.Object(attempt.encode(unknown)))
    == Error("unknown recorded command kind")
}

pub fn recorded_auxiliary_refusals_replay_in_their_original_command_slots_test() {
  let kinds = [
    "queued_input", "edit_queued_input", "worktree_diff", "live_jobs", "notes",
  ]
  let commands =
    list.index_map(kinds, fn(kind, index) {
      let id = index + 4
      [
        attempt.Issued(
          attempt.Id(1),
          attempt.Request(id, kind, attempt.NoSelection),
        ),
        attempt.Received(
          attempt.Id(1),
          frame(
            id,
            "error",
            json.Object([
              #("code", json.String("unavailable")),
              #(
                "message",
                json.String("observation unavailable in this recording"),
              ),
            ]),
          ),
        ),
      ]
    })
    |> list.flatten
  let source =
    list.append(events(1, "A"), [attempt.Adopted(attempt.Id(1)), ..commands])
  let moments = [
    recording.Moment(0, recording.LocalFormatTwo),
    ..list.index_map(source, fn(event, index) {
      recording.Moment(index + 1, recording.Attempt(event))
    })
  ]
  let assert Ok(decoded) =
    recording.decode_text(
      moments |> list.map(recording.encode_line) |> string.join("\n"),
    )
    as "a complete format-two recording accepts every issued descriptor"
  let decoded_events =
    list.filter_map(decoded, fn(moment) {
      case moment.event {
        recording.Attempt(event) -> Ok(event)
        _ -> Error(Nil)
      }
    })
  let assert Ok(#(_, changes)) = run(attempt_replay.new(), decoded_events)
    as "recorded reads and edits consume the same reply slots as live commands"
  let outcomes =
    list.filter_map(changes, fn(change) {
      case change {
        attempt_replay.Update(session_channel.RequestRefused(
          kind,
          id,
          "unavailable",
          _,
        )) -> Ok(#(kind, id))
        _ -> Error(Nil)
      }
    })
  assert outcomes
    == list.index_map(kinds, fn(kind, index) { #(kind, index + 4) })
  assert !list.any(changes, fn(change) {
    case change {
      attempt_replay.Update(session_channel.UnknownOutcome(..))
      | attempt_replay.Update(session_channel.Failed(_)) -> True
      _ -> False
    }
  })
}
