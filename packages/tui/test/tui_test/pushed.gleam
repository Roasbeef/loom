//// Pushed v2 frames and a synchronised lane, for fixtures that need one.
////
//// A test which measures what the terminal keeps has to feed it the bytes a
//// gateway would, not a decoded term: retention of a sub-binary is a property
//// of the frame the decoder was handed, and a fixture that constructed
//// `protocol.StreamDelta` directly would measure a different program. So the
//// helpers here build real wire text and hand it over as
//// `connection.Incoming`, which is the only shape the shipped reducer accepts.

import core/codec
import core/json
import core/message
import gleam/list
import gleam/option.{None, Some}
import tui
import tui/attempt
import tui/connection
import tui/session_channel
import tui/snapshot
import tui/workspace

import gleam/bit_array
import gleam/string

/// The one metadata fragment a minimal transfer carries.
///
/// ## Examples
///
/// ```gleam
/// let body = pushed.metadata()
/// ```
pub fn metadata() -> String {
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

/// One credited reply to an outstanding request.
///
/// ## Examples
///
/// ```gleam
/// let frame = pushed.reply(1, "snapshot_end", json.Object([]))
/// ```
pub fn reply(
  id: Int,
  event: String,
  body: json.JsonValue,
) -> connection.Message {
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

/// One unsolicited frame, which answers no request the client made.
///
/// ## Examples
///
/// ```gleam
/// let frame = pushed.push([#("event", json.String("committed"))])
/// ```
pub fn push(fields: List(#(String, json.JsonValue))) -> connection.Message {
  connection.Incoming(
    json.to_string(json.Object([#("v", json.Int(2)), ..fields])),
  )
}

/// A commit notice for one strand at one sequence.
///
/// ## Examples
///
/// ```gleam
/// let frame = pushed.notice("main", 10)
/// ```
pub fn notice(strand: String, seq: Int) -> connection.Message {
  push([
    #("event", json.String("committed")),
    #("seq", json.Int(seq)),
    #("body", json.Object([#("strand", json.String(strand))])),
  ])
}

/// One provider fragment of a live answer.
///
/// ## Examples
///
/// ```gleam
/// let frame = pushed.delta("main", "op-1", "Hel")
/// ```
pub fn delta(
  strand: String,
  operation: String,
  text: String,
) -> connection.Message {
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

fn begin(id: Int, transfer_id: String, window: String, next_seq: Int) {
  reply(
    id,
    "snapshot_begin",
    json.Object([
      #("snapshot_id", json.String(transfer_id)),
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

fn piece(id: Int, transfer_id: String, data: String) {
  reply(
    id,
    "snapshot_chunk",
    json.Object([
      #("snapshot_id", json.String(transfer_id)),
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

fn finish(id: Int, transfer_id: String, next_seq: Int) {
  reply(
    id,
    "snapshot_end",
    json.Object([
      #("snapshot_id", json.String(transfer_id)),
      #("index", json.Int(1)),
      #("next_seq", json.Int(next_seq)),
      #("more_after", json.Null),
    ]),
  )
}

/// One completed transfer: its begin, its single metadata fragment, its end.
///
/// Request identities are consecutive because the lane allocates the next one
/// for each credit it spends.
///
/// ## Examples
///
/// ```gleam
/// let frames = pushed.transfer(1, "1:1", "recent", 10)
/// ```
pub fn transfer(
  first: Int,
  transfer_id: String,
  window: String,
  next_seq: Int,
) -> List(connection.Message) {
  transfer_with_metadata(first, transfer_id, window, next_seq, metadata())
}

/// A real credited transfer carrying the supplied bounded metadata object.
///
/// ## Examples
///
/// ```gleam
/// let frames = pushed.transfer_with_metadata(1, "1:1", "recent", 10, data)
/// ```
pub fn transfer_with_metadata(
  first: Int,
  transfer_id: String,
  window: String,
  next_seq: Int,
  data: String,
) -> List(connection.Message) {
  [
    begin(first, transfer_id, window, next_seq),
    piece(first + 1, transfer_id, data),
    finish(first + 2, transfer_id, next_seq),
  ]
}

/// A model whose lane has completed its initial capture at sequence ten.
///
/// The peer is `Replaying` so nothing this model does can write to a socket;
/// what is under test is only what it keeps.
///
/// ## Examples
///
/// ```gleam
/// let model = pushed.attached()
/// ```
pub fn attached() -> tui.Model {
  // The trace sink discards: a subject here would deliver the lane's own
  // events into the holder's mailbox, and a fixture that measures a mailbox
  // must not be the thing filling it.
  let trace = attempt.Trace(attempt.Id(1), fn(_event) { Nil })
  let channel =
    session_channel.replay_traced(
      snapshot.Expected("A", "epoch", "incarnation"),
      fn() { 0 },
      trace,
    )
  let #(ready, _) =
    list.fold(transfer(1, "1:1", "recent", 10), #(channel, []), fn(acc, frame) {
      let #(channel, updates) = session_channel.receive(acc.0, frame)
      #(channel, list.append(acc.1, updates))
    })
  tui.Model(
    ..tui.new_model(connection.new_inbox(), workspace.Context("test", None)),
    peer: tui.Replaying,
    channel: Some(ready),
  )
}
