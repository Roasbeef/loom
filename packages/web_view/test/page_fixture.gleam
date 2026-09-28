//// The frames a gateway sends a page, and a driver that runs a page's
//// `update` and performs its effects, so a test can read exactly what the
//// page wrote to its transport.
////
//// Lustre's simulator runs `update` and `view` and drops every effect,
//// which suits a test about what a page draws. A test about what a page
//// sends needs the effects performed, so `run` folds messages through an
//// application's `update` and performs each effect with Lustre's own
//// interpreter. The transport's socket is a subject the test owns, and
//// every frame the page transmits is a message on it, in the order the
//// lane decided them.

import core/codec
import core/json
import core/message
import gleam/bit_array
import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/string
import lustre/effect.{type Effect}
import session_view/connection_event
import session_view/snapshot
import web_view/component

/// The socket a test page writes to: every transmitted frame arrives on it.
pub type Wire =
  Subject(String)

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

fn metadata(cells: List(json.JsonValue)) -> String {
  json.to_string(
    json.Object([
      #("cells", json.Array(cells)),
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

/// The three replies of one credited transfer, for an attachment with
/// `role`, whose metadata holds `cells`: its begin, its one metadata
/// fragment and its end, answering the lane's requests one, two and three.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.transfer("operator", [])
/// ```
pub fn transfer(
  role: String,
  cells: List(json.JsonValue),
) -> List(connection_event.Message) {
  let data = metadata(cells)
  [
    reply(
      1,
      "snapshot_begin",
      json.Object([
        #("snapshot_id", json.String("1:1")),
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
        #("snapshot_id", json.String("1:1")),
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
    ),
    reply(
      3,
      "snapshot_end",
      json.Object([
        #("snapshot_id", json.String("1:1")),
        #("index", json.Int(1)),
        #("next_seq", json.Int(10)),
        #("more_after", json.Null),
      ]),
    ),
  ]
}

/// A pending escalation cell for `tool`, captured at `seq`, whose whole
/// authority is one writable root, so it can be allowed as well as denied.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.escalation("esc-1", 7, "fs_write", "write the file")
/// ```
pub fn escalation(
  id: String,
  seq: Int,
  tool: String,
  preview: String,
) -> json.JsonValue {
  json.Object([
    #("namespace", json.String("fact.custom")),
    #("key", json.String("escalation/" <> id)),
    #("seq", json.Int(seq)),
    #(
      "value",
      json.Object([
        #("id", json.String(id)),
        #("status", json.String("pending")),
        #("tool", json.String(tool)),
        #("preview", json.String(preview)),
        #("action", json.String("captured-action")),
        #("origin", json.Null),
        #(
          "denial",
          json.Object([
            #(
              "wanted",
              json.Array([
                json.Object([
                  #("grant", json.String("writable_root")),
                  #("path", json.String("/shared/output")),
                ]),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  ])
}

/// What a page is started with: session `A`, and a transport whose socket
/// is the test's subject.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.start()
/// ```
pub fn start() -> component.Start(Wire) {
  component.Start(
    session_id: "A",
    label: None,
    expected: snapshot.Expected("A", "epoch", "incarnation"),
    transport: component.Transport(
      connect: fn(_, _) { Nil },
      transmit: fn(wire, frame) { process.send(wire, frame) },
      shut: fn(_) { Nil },
      now: fn() { 0 },
    ),
  )
}

/// Folds `messages` through `update` from `model`, performing every effect
/// as Lustre would. A message an effect dispatches is not fed back: the
/// pages dispatch only from their subscriptions, which a test drives by
/// hand.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.run(model, component.update, [component.Ticked(0)])
/// ```
pub fn run(
  model: model,
  update: fn(model, message) -> #(model, Effect(message)),
  messages: List(message),
) -> model {
  list.fold(messages, model, fn(model, message) {
    let #(model, effects) = update(model, message)
    effect.perform(
      effects,
      fn(_) { Nil },
      fn(_, _) { Nil },
      fn(_) { Nil },
      fn() { dynamic.nil() },
      fn(_, _) { Nil },
      fn(_, _) { Nil },
      fn(_) { Nil },
    )
    model
  })
}

/// Every frame written to `wire` so far, oldest first.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.sent(wire)
/// ```
pub fn sent(wire: Wire) -> List(String) {
  case process.receive(wire, 0) {
    Ok(frame) -> [frame, ..sent(wire)]
    Error(Nil) -> []
  }
}

/// The frames of `sent` that are commands rather than the lane's own
/// snapshot requests.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.commands(page_fixture.sent(wire))
/// ```
pub fn commands(frames: List(String)) -> List(String) {
  list.filter(frames, fn(frame) {
    !string.contains(frame, "\"cmd\":\"snapshot")
  })
}
