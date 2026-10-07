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
import core/ids
import core/json
import core/message
import core/register
import gleam/bit_array
import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import lustre/effect.{type Effect}
import session_view/connection_event
import session_view/snapshot
import session_view/snapshot_view
import web_view/component
import web_view/sessions

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

// One register cell in the form a capture's metadata carries it.
fn cell(
  namespace: register.RegisterNs,
  key: String,
  seq: Int,
  value: json.JsonValue,
) -> json.JsonValue {
  json.Object([
    #("namespace", json.String(register.ns_to_string(namespace))),
    #("key", json.String(key)),
    #("seq", json.Int(seq)),
    #("value", value),
  ])
}

// The three cells that list `main` as a strand: its configuration, its leaf
// and its state, in the forms `machine/codec` writes. A capture that lists no
// strand has no recipient, and the engine refuses a command to it.
fn main_cells() -> List(json.JsonValue) {
  [
    cell(
      register.StrandConfig,
      "main",
      1,
      json.Object([
        #(
          "model",
          json.Object([
            #("provider", json.String("test")),
            #("modelId", json.String("test")),
          ]),
        ),
        #("thinkingLevel", json.String("off")),
        #("activeToolNames", json.Array([])),
      ]),
    ),
    cell(register.StrandLeaf, "main", 2, json.Null),
    cell(
      register.StrandState,
      "main",
      3,
      json.Object([
        #("currentOperationId", json.Null),
        #("pendingNextRun", json.Array([])),
      ]),
    ),
  ]
}

fn metadata(cells: List(json.JsonValue)) -> String {
  json.to_string(
    json.Object([
      #("cells", json.Array(list.append(main_cells(), cells))),
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
  replies(1, "recent", 10, role, cells, [])
}

/// The replies to a `history` read the lane sent as request `id` for the
/// sequences below `before`, carrying the records of `window`, for an
/// attachment with `role`. The lane credits one fragment per request, so
/// the replies answer `id` and the requests after it, one each.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.history(4, "operator", window, 301)
/// ```
pub fn history(
  id: Int,
  role: String,
  window: snapshot.Window,
  before: Int,
) -> List(connection_event.Message) {
  replies(id, "history", before, role, [], list.reverse(window.items))
}

/// The lineage reads among the frames the page wrote since the last look.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.lineage_reads(wire)
/// ```
pub fn lineage_reads(wire: Wire) -> List(String) {
  sent(wire)
  |> list.filter(fn(frame) {
    string.contains(frame, "\"cmd\":\"history_lineage\"")
  })
}

/// The entry a lineage read starts at, as text.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.lineage_from(frame)
/// ```
pub fn lineage_from(frame: String) -> String {
  case json.parse(frame) {
    Ok(json.Object(fields)) ->
      case list.key_find(fields, "body") {
        Ok(json.Object(body)) ->
          case list.key_find(body, "from") {
            Ok(json.String(from)) -> from
            _ -> ""
          }
        _ -> ""
      }
    _ -> ""
  }
}

/// The replies to a `history_lineage` read the lane sent as request `id`,
/// carrying the records of `window` (newest first, as the lane holds a page) for
/// an attachment with `role`. `next_seq` is the high-water the daemon captured,
/// above every record's sequence.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.lineage(4, "operator", window, 301)
/// ```
pub fn lineage(
  id: Int,
  role: String,
  window: snapshot.Window,
  next_seq: Int,
) -> List(connection_event.Message) {
  replies(id, "lineage", next_seq, role, [], list.reverse(window.items))
}

/// The replies to the catch-up the lane sent as request `id`, for an
/// attachment with `role`: a transfer that brings no record, as the
/// session `transfer` describes has none.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.catch_up(7, "operator")
/// ```
pub fn catch_up(id: Int, role: String) -> List(connection_event.Message) {
  replies(id, "catch_up", 10, role, [], [])
}

/// The request identity a frame the page wrote carries.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.request_id("{\"v\":2,\"id\":4,\"cmd\":\"history\"}")
/// ```
pub fn request_id(frame: String) -> Int {
  case json.parse(frame) {
    Ok(json.Object(fields)) ->
      case list.key_find(fields, "id") {
        Ok(json.Int(id)) -> id
        _ -> 0
      }
    _ -> 0
  }
}

// A credited transfer answering request `first` and the credits after it:
// the begin, the metadata, one fragment per item in sequence order, and the
// end. `next_seq` is the cursor the begin and the end both carry, above
// every item's sequence.
fn replies(
  first: Int,
  mode: String,
  next_seq: Int,
  role: String,
  cells: List(json.JsonValue),
  items: List(snapshot.Item),
) -> List(connection_event.Message) {
  let id = mode <> ":" <> int.to_string(first)
  let begin =
    reply(
      first,
      "snapshot_begin",
      json.Object([
        #("snapshot_id", json.String(id)),
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
        #("next_seq", json.Int(next_seq)),
        #("oldest_seq", json.Null),
        #("window", json.String(mode)),
        #("complete_history", json.Bool(False)),
        #("record_bytes_limit", json.Int(snapshot.record_limit)),
        #("fragment_bytes_limit", json.Int(snapshot.piece_limit)),
      ]),
    )
  let pieces = [
    #("metadata", "metadata", json.Null, metadata(cells)),
    ..list.filter_map(items, fn(item) {
      case item {
        snapshot.Loaded(entry:, ..) ->
          Ok(#(
            "entry",
            ids.entry_id_to_string(entry.id),
            json.Int(entry.seq),
            json.to_string(codec.encode_entry(entry)),
          ))
        snapshot.Unloaded(..) -> Error(Nil)
      }
    })
  ]
  let chunks =
    list.index_map(pieces, fn(piece, index) {
      let #(kind, record, seq, data) = piece
      reply(
        first + 1 + index,
        "snapshot_chunk",
        json.Object([
          #("snapshot_id", json.String(id)),
          #("index", json.Int(index)),
          #("kind", json.String(kind)),
          #("record_id", json.String(record)),
          #("record_seq", seq),
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
      )
    })
  let count = list.length(pieces)
  let end =
    reply(
      first + 1 + count,
      "snapshot_end",
      json.Object([
        #("snapshot_id", json.String(id)),
        #("index", json.Int(count)),
        #("next_seq", json.Int(next_seq)),
        #("more_after", json.Null),
      ]),
    )
  [begin, ..list.append(chunks, [end])]
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
/// is the test's subject and whose clock reads zero.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.start()
/// ```
pub fn start() -> component.Start(Wire) {
  started(fn() { 0 })
}

/// A page's clock that a test sets, for a test that needs the transport to
/// read a later time than the last message did. The component reads it once
/// at the top of each message, so a test sets it before sending one.
pub opaque type Clock {
  Clock(cell: Subject(ClockMessage))
}

type ClockMessage {
  Set(ms: Int)
  Read(reply: Subject(Int))
}

/// A clock reading zero.
///
/// ## Examples
///
/// ```gleam
/// let clock = page_fixture.clock()
/// ```
pub fn clock() -> Clock {
  let started = process.new_subject()
  process.spawn(fn() {
    let cell = process.new_subject()
    process.send(started, cell)
    serve(cell, 0)
  })
  let assert Ok(cell) = process.receive(started, 1000)
    as "the clock process started"
  Clock(cell)
}

fn serve(cell: Subject(ClockMessage), ms: Int) -> Nil {
  case process.receive_forever(cell) {
    Set(ms:) -> serve(cell, ms)
    Read(reply:) -> {
      process.send(reply, ms)
      serve(cell, ms)
    }
  }
}

/// Sets what `clock` reads.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.set(clock, 60_000)
/// ```
pub fn set(clock: Clock, ms: Int) -> Nil {
  process.send(clock.cell, Set(ms))
}

/// What a page is started with, as `start` does, whose transport reads
/// `clock`.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.start_with(clock)
/// ```
pub fn start_with(clock: Clock) -> component.Start(Wire) {
  started(fn() {
    let reply = process.new_subject()
    process.send(clock.cell, Read(reply))
    let assert Ok(ms) = process.receive(reply, 1000) as "the clock answered"
    ms
  })
}

fn started(now: fn() -> Int) -> component.Start(Wire) {
  component.Start(
    session_id: "A",
    label: None,
    workspace_digest: "",
    expected: snapshot.Expected("A", "epoch", "incarnation"),
    standing: component.unplaced,
    transport: component.Transport(
      connect: fn(_, _) { Nil },
      transmit: fn(wire, frame) { process.send(wire, frame) },
      shut: fn(_) { Nil },
      now:,
      sessions: fn(deliver) { deliver([]) },
      activity: fn(_, _) { Nil },
      open: fn(_) { sessions.Declined(sessions.NotHeld) },
      resume: fn(_, _) { Nil },
      invite: None,
      home: None,
      rename: None,
      shareable: None,
      peers: None,
      worktree: None,
      logins: None,
      manage: None,
    ),
  )
}

/// The daemon's answer to the `block_summaries` read the lane sent as
/// request `id`: the stored labels it found, each an entry's text, a content
/// index and the label.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.block_summaries(9, [#("0198c0de-0000-7000-8000-000000000006", 0, "Reads.")])
/// ```
pub fn block_summaries(
  id: Int,
  found: List(#(String, Int, String)),
) -> connection_event.Message {
  reply(
    id,
    "snapshot",
    json.Object([
      #("mode", json.String("block_summaries")),
      #(
        "board",
        json.Object([
          #(
            "summaries",
            json.Array(
              list.map(found, fn(label) {
                json.Object([
                  #("entry", json.String(label.0)),
                  #("block", json.Int(label.1)),
                  #("text", json.String(label.2)),
                ])
              }),
            ),
          ),
        ]),
      ),
    ]),
  )
}

/// The daemon's refusal of the read the lane sent as request `id`.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.refusal(4)
/// ```
pub fn refusal(id: Int) -> connection_event.Message {
  connection_event.Incoming(
    "{\"v\":2,\"reply_to\":"
    <> int.to_string(id)
    <> ",\"event\":\"error\",\"body\":{\"code\":\"unavailable\",\"message\":\"busy\"}}",
  )
}

/// The refusals of the four reads a first capture starts, one after the
/// other, as a test that cannot read the wire delivers them: the lane's
/// requests one to three are the transfer's, and the reads of the strand's
/// notes, the session's context, the advisor's pending nudges and the
/// session goal take the next four, each sent when the one before is
/// answered.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.first_reads_refused()
/// ```
pub fn first_reads_refused() -> List(connection_event.Message) {
  [refusal(4), refusal(5), refusal(6), refusal(7)]
}

/// The refusal of the read of the session's decided approvals, which the
/// page asks in the message that frees the lane after the four reads of
/// `first_reads_refused`, so it is request eight and arrives in a message of
/// its own.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.decided_read_refused()
/// ```
pub fn decided_read_refused() -> List(connection_event.Message) {
  [refusal(8)]
}

/// A page for `role` whose lane has completed its first transfer and every
/// read the transfer's capture set going, so it is following and has no
/// request out, writing to `wire`. The frames of the transfer and of those
/// reads are taken off the wire, so what a test reads there next is what the
/// page sent after them.
///
/// A first capture makes the shared step read the strand's notes, to seed a
/// todo board, and the session's context, and each read holds the lane's one
/// command slot until it is answered. What these tests are about is not the
/// answers, so each is refused.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.ready(process.new_subject(), "operator")
/// ```
pub fn ready(wire: Wire, role: String) -> component.Model(Wire) {
  run(component.new(start()), component.update, [
    component.Opened(wire),
    component.Arrived(transfer(role, [])),
  ])
  |> refuse_reads(component.update, wire, component.Arrived)
}

/// Refuses every read the page has written to `wire`, and the reads its
/// refusals release, until the wire holds none, and takes the frames it
/// found off the wire. `arrived` wraps the refusals as the message the
/// page's own `update` takes for traffic from its transport.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.refuse_reads(page, component.update, wire, component.Arrived)
/// ```
pub fn refuse_reads(
  page: model,
  update: fn(model, message) -> #(model, Effect(message)),
  wire: Wire,
  arrived: fn(List(connection_event.Message)) -> message,
) -> model {
  refusing(page, update, wire, arrived, 8)
}

// One round: the reads on the wire are refused, and the round repeats for
// the reads that frees, until the wire holds none or `rounds` are spent.
fn refusing(
  page: model,
  update: fn(model, message) -> #(model, Effect(message)),
  wire: Wire,
  arrived: fn(List(connection_event.Message)) -> message,
  rounds: Int,
) -> model {
  let reads =
    list.filter(sent(wire), fn(frame) {
      !string.contains(frame, "\"cmd\":\"snapshot")
      && !string.contains(frame, "\"cmd\":\"subscribe\"")
    })
  case reads, rounds {
    [], _ | _, 0 -> page
    _, _ ->
      run(page, update, [
        arrived(list.map(reads, fn(frame) { refusal(request_id(frame)) })),
      ])
      |> refusing(update, wire, arrived, rounds - 1)
  }
}

/// Folds `messages` through `update` from `model`, performing every effect
/// as Lustre would. A message an effect dispatches is not fed back: the
/// pages dispatch only from their subscriptions, which a test drives by
/// hand.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.run(model, component.update, [component.Ticked])
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

/// A pending escalation as a capture's metadata cell, naming the strand
/// whose call raised it, as the harness stores one.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.pending_cell("esc-9", 12, "bash", "main")
/// ```
pub fn pending_cell(
  id: String,
  seq: Int,
  tool: String,
  strand: String,
) -> snapshot_view.Cell {
  snapshot_view.Cell(
    register.FactCustom,
    "escalation/" <> id,
    seq,
    json.Object([
      #("id", json.String(id)),
      #("status", json.String("pending")),
      #("tool", json.String(tool)),
      #("preview", json.String("printf hi")),
      #("scope", json.Object([#("strand", json.String(strand))])),
    ]),
  )
}

/// A pending escalation record that names the strand it was raised on.
///
/// ## Examples
///
/// ```gleam
/// page_fixture.waiting("esc-1", 7, "bash", "main")
/// ```
pub fn waiting(
  id: String,
  seq: Int,
  tool: String,
  strand: String,
) -> json.JsonValue {
  case escalation(id, seq, tool, "{\"command\":\"ls\"}") {
    json.Object(cell) ->
      json.Object(
        list.map(cell, fn(field) {
          case field {
            #("value", json.Object(value)) -> #(
              "value",
              json.Object([
                #("scope", json.Object([#("strand", json.String(strand))])),
                ..value
              ]),
            )
            other -> other
          }
        }),
      )
    other -> other
  }
}
