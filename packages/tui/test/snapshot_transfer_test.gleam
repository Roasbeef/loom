//// Credit, identity and payload bounds are independent of terminal rendering.
//// Tests feed raw pieces, including split UTF-8, without a fake transport that
//// could accidentally skip the reassembly checks the real socket must pass.

import core/clock
import core/codec
import core/entry
import core/ids
import core/json
import core/message
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui/snapshot

fn expected() {
  snapshot.Expected("session", "epoch", "incarnation")
}

fn begin_body() {
  json.Object([
    #("snapshot_id", json.String("transfer")),
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
    #("oldest_seq", json.Int(1)),
    #("window", json.String("recent")),
    #("complete_history", json.Bool(False)),
    #("record_bytes_limit", json.Int(snapshot.record_limit)),
    #("fragment_bytes_limit", json.Int(snapshot.piece_limit)),
  ])
}

fn begin(window) {
  let assert Ok(transfer) =
    snapshot.begin(begin_body(), expected(), None, window, 0)
    as "selected attachment and declared limits are validated before credit"
  transfer
}

pub fn snapshot_transfer_emitted_roles_and_regular_windows_are_exact_test() {
  let assert json.Object(fields) = begin_body()
    as "the fixture mirrors gateway captured_transfer's begin object"
  list.each(["owner", "operator", "observer"], fn(role) {
    list.each(["recent", "catch_up", "history"], fn(window) {
      let body =
        json.Object(list.key_set(
          list.key_set(fields, "role", json.String(role)),
          "window",
          json.String(window),
        ))
      let assert Ok(_) =
        snapshot.begin(body, expected(), None, snapshot.empty(), 0)
        as "all emitted regular transfer roles and windows are recognized"
    })
  })
  list.each([#("role", "administrator"), #("window", "reconcile")], fn(pair) {
    let #(key, value) = pair
    let body = json.Object(list.key_set(fields, key, json.String(value)))
    let assert Error(_) =
      snapshot.begin(body, expected(), None, snapshot.empty(), 0)
      as "nearby names are not accepted as protocol aliases"
  })
}

pub fn snapshot_transfer_lookup_is_not_a_regular_conversation_cut_test() {
  let assert json.Object(fields) = begin_body() as "the fixture is an object"
  let body =
    json.Object(list.key_set(fields, "window", json.String("escalations")))
  let assert Error(_) =
    snapshot.begin(body, expected(), None, snapshot.empty(), 0)
    as "normal conversation state cannot adopt an exact lookup as a full cut"
  let assert Ok(_) = snapshot.begin_lookup(body, expected(), None, 0)
    as "the explicit lookup lane accepts the actual emitted window tag"
  let assert Error(_) = snapshot.begin_lookup(begin_body(), expected(), None, 0)
    as "lookup credit cannot accidentally consume a regular snapshot"
}

fn piece(transfer, kind, id, seq, total, offset, bytes) {
  let #(identity, index) = snapshot.credit(transfer)
  json.Object([
    #("snapshot_id", json.String(identity)),
    #("index", json.Int(index)),
    #("kind", json.String(kind)),
    #("record_id", json.String(id)),
    #("record_seq", case seq {
      None -> json.Null
      Some(seq) -> json.Int(seq)
    }),
    #("total_bytes", json.Int(total)),
    #("offset", json.Int(offset)),
    #("data", json.String(bit_array.base64_encode(bytes, True))),
  ])
}

fn feed(transfer, kind, id, seq, bytes) {
  feed_at(transfer, kind, id, seq, bytes, 0)
}

fn feed_at(transfer, kind, id, seq, bytes, offset) {
  let total = bit_array.byte_size(bytes)
  case offset == total {
    True -> transfer
    False -> {
      let size = int.min(snapshot.piece_limit, total - offset)
      let assert Ok(fragment) = bit_array.slice(bytes, offset, size)
        as "test fragment remains inside its raw record"
      let assert Ok(next) =
        snapshot.chunk(
          transfer,
          piece(transfer, kind, id, seq, total, offset, fragment),
        )
        as "every valid credited piece advances exactly once"
      feed_at(next, kind, id, seq, bytes, offset + size)
    }
  }
}

fn metadata(transfer) {
  feed(transfer, "metadata", "metadata", None, <<123, 125>>)
}

fn finished(transfer) {
  let #(id, index) = snapshot.credit(transfer)
  snapshot.finish(
    transfer,
    json.Object([
      #("snapshot_id", json.String(id)),
      #("index", json.Int(index)),
      #("next_seq", json.Int(10)),
      #("more_after", json.Null),
    ]),
  )
}

fn record(sequence) {
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(1000), sequence))
  entry.MessageEntry(
    id,
    None,
    sequence,
    1000,
    message.UserMessage([message.UserText("hello", None)], 1000, None),
    False,
  )
}

pub fn snapshot_transfer_split_utf8_and_exact_credits_test() {
  let transfer = begin(snapshot.empty())
  let bytes = bit_array.from_string("{\"note\":\"🪡\"}")
  let assert Ok(first) = bit_array.slice(bytes, 0, 10)
    as "the first piece ends inside a UTF-8 codepoint"
  let assert Ok(rest) =
    bit_array.slice(bytes, 10, bit_array.byte_size(bytes) - 10)
    as "the second piece completes that codepoint"
  let first_body =
    piece(
      transfer,
      "metadata",
      "metadata",
      None,
      bit_array.byte_size(bytes),
      0,
      first,
    )
  let assert Ok(next) = snapshot.chunk(transfer, first_body)
    as "a piece need not itself be UTF-8"
  let assert Error(_) = snapshot.chunk(next, first_body)
    as "a duplicate credit cannot advance the transfer"
  let assert Error(_) = finished(next)
    as "the incomplete metadata cannot be adopted"
  let assert Ok(next) =
    snapshot.chunk(
      next,
      piece(
        next,
        "metadata",
        "metadata",
        None,
        bit_array.byte_size(bytes),
        10,
        rest,
      ),
    )
    as "the completed raw document is decoded once"
  let assert Ok(cut) = finished(next) as "only end exposes the coherent cut"
  assert cut.metadata == json.Object([#("note", json.String("🪡"))])
}

pub fn snapshot_transfer_rejects_identity_offsets_and_declared_overflow_test() {
  let assert Error(_) =
    snapshot.begin(
      begin_body(),
      snapshot.Expected("other", "epoch", "incarnation"),
      None,
      snapshot.empty(),
      0,
    )
    as "a different selected session cannot adopt this cut"
  let transfer = begin(snapshot.empty())
  list.each(
    [
      piece(transfer, "metadata", "metadata", None, 2, 1, <<123, 125>>),
      piece(
        transfer,
        "metadata",
        "metadata",
        None,
        snapshot.metadata_limit + 1,
        0,
        <<123>>,
      ),
      piece(transfer, "metadata", "metadata", Some(1), 2, 0, <<123, 125>>),
    ],
    fn(body) {
      let assert Error(_) = snapshot.chunk(transfer, body)
        as "invalid extent or metadata descriptor fails before reassembly"
    },
  )
  let value = record(1)
  let transfer = metadata(transfer)
  let body =
    piece(
      transfer,
      "entry",
      ids.entry_id_to_string(value.id),
      Some(1),
      snapshot.record_limit + 1,
      0,
      <<32>>,
    )
  let assert Error(_) = snapshot.chunk(transfer, body)
    as "even unloaded records cannot exceed the protocol raw-byte limit"
}

pub fn snapshot_transfer_payload_must_match_immutable_descriptor_test() {
  let transfer = metadata(begin(snapshot.empty()))
  let value = record(1)
  let bytes =
    codec.encode_entry(value) |> json.to_string |> bit_array.from_string
  let body =
    piece(
      transfer,
      "entry",
      ids.entry_id_to_string(value.id),
      Some(2),
      bit_array.byte_size(bytes),
      0,
      bytes,
    )
  let assert Error(_) = snapshot.chunk(transfer, body)
    as "raw entry sequence must equal its independently carried descriptor"
}

pub fn snapshot_transfer_large_record_is_explicitly_unloaded_test() {
  let transfer = metadata(begin(snapshot.empty()))
  let value = record(1)
  let id = ids.entry_id_to_string(value.id)
  let total = snapshot.presentation_limit + 1
  let transfer = drain_large(transfer, id, total, 0)
  let assert Ok(cut) = finished(transfer)
    as "a drained record retains its position without pretending to decode it"
  assert cut.window.items == [snapshot.Unloaded(id, 1, total)]
  assert cut.window.bytes == 0
}

pub fn snapshot_transfer_exact_presentation_limit_still_decodes_test() {
  let value = record(1)
  let encoded = codec.encode_entry(value) |> json.to_string
  let padded =
    encoded
    <> string.repeat(
      " ",
      snapshot.presentation_limit - string.byte_size(encoded),
    )
  let transfer = metadata(begin(snapshot.empty()))
  let transfer =
    feed(
      transfer,
      "entry",
      ids.entry_id_to_string(value.id),
      Some(1),
      bit_array.from_string(padded),
    )
  let assert Ok(cut) = finished(transfer)
    as "a record exactly at the presentation boundary remains fully decoded"
  assert cut.window.items
    == [snapshot.Loaded(value, snapshot.presentation_limit)]
  assert cut.window.bytes == snapshot.presentation_limit
}

fn drain_large(transfer, id, total, offset) {
  case offset == total {
    True -> transfer
    False -> {
      let size = int.min(snapshot.piece_limit, total - offset)
      let bytes = bit_array.from_string(string.repeat(" ", size))
      let assert Ok(next) =
        snapshot.chunk(
          transfer,
          piece(transfer, "entry", id, Some(1), total, offset, bytes),
        )
        as "large presentation records validate pieces without collecting them"
      drain_large(next, id, total, offset + size)
    }
  }
}

pub fn snapshot_transfer_exact_window_budget_evicts_oldest_not_newest_test() {
  let first = record(1)
  let second = record(2)
  let third = record(3)
  let prior =
    snapshot.Window(
      [
        snapshot.Loaded(second, snapshot.presentation_limit),
        snapshot.Loaded(first, snapshot.presentation_limit),
      ],
      snapshot.window_limit,
      None,
    )
  let bytes =
    codec.encode_entry(third) |> json.to_string |> bit_array.from_string
  let transfer = metadata(begin(prior))
  let transfer =
    feed(transfer, "entry", ids.entry_id_to_string(third.id), Some(3), bytes)
  let assert Ok(cut) = finished(transfer)
    as "window bounds apply when an entry completes"
  assert cut.window.items
    == [
      snapshot.Loaded(third, bit_array.byte_size(bytes)),
      snapshot.Loaded(second, snapshot.presentation_limit),
    ]
  assert cut.window.evicted_through == Some(1)
  assert cut.window.bytes
    == snapshot.presentation_limit + bit_array.byte_size(bytes)
}
