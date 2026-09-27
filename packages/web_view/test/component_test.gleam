//// The component keeps option C: an arriving frame is filed and changes
//// nothing on the page until a tick hands it to the lane. Driven with
//// Lustre's simulator, which runs `update` and `view` and performs no
//// effect, so the frames are the ones a gateway would send for one credited
//// transfer and nothing reaches a socket.

import core/codec
import core/json
import core/message
import gleam/bit_array
import gleam/option.{None}
import gleam/string
import lustre/dev/simulate
import lustre/effect
import lustre/element
import session_view/connection_event
import session_view/snapshot
import web_view/component

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

fn metadata() -> String {
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

// The three replies of one credited transfer: its begin, its one metadata
// fragment and its end, answering the lane's requests one, two and three.
fn transfer() -> List(connection_event.Message) {
  let data = metadata()
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
        #("role", json.String("observer")),
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

fn start() -> component.Start(Nil) {
  component.Start(
    session_id: "A",
    expected: snapshot.Expected("A", "epoch", "incarnation"),
    transport: component.Transport(
      connect: fn(_) { Ok(Nil) },
      transmit: fn(_, _) { Nil },
      shut: fn(_) { Nil },
      now: fn() { 0 },
    ),
  )
}

fn simulation() {
  simulate.application(
    init: fn(start) { #(component.new(start), effect.none()) },
    update: component.update,
    view: component.view,
  )
  |> simulate.start(start())
}

fn arrive(simulation, frames: List(connection_event.Message)) {
  case frames {
    [] -> simulation
    [frame, ..rest] ->
      arrive(simulate.message(simulation, component.Arrived(frame)), rest)
  }
}

pub fn arrivals_are_filed_and_reduced_only_at_a_tick_test() {
  let opened = simulate.message(simulation(), component.Opened(Nil, 0))
  let filed = arrive(opened, transfer())

  // Every frame of a complete transfer has arrived, and the page still says
  // it is connecting: nothing was reduced.
  assert component.status(simulate.model(filed)) == component.Connecting
  assert string.contains(element.to_string(simulate.view(filed)), "connecting")

  let ticked = simulate.message(filed, component.Ticked(0))
  assert component.status(simulate.model(ticked)) == component.Following
  assert string.contains(
    element.to_string(simulate.view(ticked)),
    "following · read-only",
  )
}

pub fn a_tick_before_the_transport_opens_keeps_what_was_filed_test() {
  // Frames filed before the transport reported open, and a tick that finds
  // no lane, must not lose them: the first tick with a lane reduces them.
  let early = arrive(simulation(), transfer())
  let idle = simulate.message(early, component.Ticked(0))
  assert component.status(simulate.model(idle)) == component.Connecting

  let opened = simulate.message(idle, component.Opened(Nil, 0))
  let ticked = simulate.message(opened, component.Ticked(0))
  assert component.status(simulate.model(ticked)) == component.Following
}

pub fn a_closed_connection_is_drawn_at_the_next_tick_test() {
  // The relay tells the component its connection ended before it tells the
  // page's socket, which closes two ticks later. The ended state is drawn
  // by the first of them.
  let ticked =
    simulate.message(simulation(), component.Opened(Nil, 0))
    |> arrive(transfer())
    |> simulate.message(component.Ticked(0))
  let closed =
    simulate.message(
      ticked,
      component.Arrived(connection_event.Closed("access was revoked")),
    )
  assert component.status(simulate.model(closed)) == component.Following

  let drawn = simulate.message(closed, component.Ticked(250))
  assert string.contains(
    element.to_string(simulate.view(drawn)),
    "disconnected",
  )
}
