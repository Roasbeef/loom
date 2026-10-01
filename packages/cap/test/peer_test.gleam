//// Typed inspection distinguishes absence, malformed envelopes and host failures.

import cap/internal/channel
import cap/internal/dispatch
import cap/internal/wire
import cap/peer
import cap/report
import cap/strand
import core/msgpack
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

const identity = "00000000-0000-7000-8000-000000000001"

fn session() -> peer.SessionId {
  let assert Ok(id) = peer.parse_session_id(identity)
    as "the fixture identity is valid"
  id
}

fn entry() -> strand.EntryId {
  let assert Ok(id) = strand.parse_entry_id(identity)
    as "the fixture identity is valid"
  id
}

fn install(answer: String) {
  dispatch.install(
    channel.Channel(call: fn(_, _, _) { Ok(msgpack.StringValue(answer)) }),
  )
}

pub fn typed_pages_preserve_empty_page_progress_and_identity_selectors_test() {
  let receipt_cursor = "client/peers/receipt/sha256-" <> string.repeat("a", 64)
  let assert Ok(cursor) = peer.receipt_after(receipt_cursor)
    as "the persisted cursor is valid"
  dispatch.install(
    channel.Channel(call: fn(cap, args, _) {
      assert result.is_error(wire.string_field(args, "strand"))
      case cap {
        "peer.inbox" -> {
          assert wire.string_field(args, "after") == Ok(identity)
          Ok(msgpack.StringValue(
            "{\"revision\":3,\"items\":[],\"total\":5,\"next\":\""
            <> identity
            <> "\"}",
          ))
        }
        "peer.received" -> {
          assert wire.string_field(args, "after") == Ok(receipt_cursor)
          Ok(msgpack.StringValue(
            "{\"items\":[],\"next\":\"" <> receipt_cursor <> "\"}",
          ))
        }
        "peer.history" -> {
          assert wire.int_field(args, "before") == Ok(42)
          Ok(msgpack.StringValue("{\"items\":[],\"next\":41}"))
        }
        "peer.inbox_get" -> {
          assert wire.string_field(args, "id") == Ok(identity)
          Ok(msgpack.StringValue("null"))
        }
        "peer.received_get" -> {
          assert wire.string_field(args, "source_session") == Ok(identity)
          Ok(msgpack.StringValue("null"))
        }
        "peer.sent_receipt" -> {
          assert wire.string_field(args, "session") == Ok(identity)
          assert result.is_error(wire.string_field(args, "source_session"))
          Ok(msgpack.StringValue("null"))
        }
        _ -> panic as "only expected capabilities are called"
      }
    }),
  )
  let assert Ok(inbox) =
    peer.inbox(after: peer.pending_after(entry()), limit: 2)
    as "a short coherent page is decoded"
  assert inbox.total == 5
  assert inbox.next == Some(peer.pending_after(entry()))
  assert peer.inbox_get(id: entry()) == Ok(None)
  let assert Ok(before) = peer.history_before(42)
    as "a positive sequence restores"
  let assert Ok(history) = peer.history(before:, limit: 2)
    as "the scanned window progresses"
  let assert Ok(expected_next) = peer.history_before(41)
    as "the expected continuation is a valid cursor"
  assert history.next == Some(expected_next)
  let assert Ok(received) = peer.received(after: cursor, limit: 2)
    as "a foreign-only window progresses"
  assert received.next == Some(cursor)
  assert peer.received_get(
      source_session: session(),
      source_strand: "reviewer",
      message_id: "report-1",
    )
    == Ok(None)
  assert peer.sent_receipt(session: session(), message_id: "report-1")
    == Ok(None)
  dispatch.reset()
}

pub fn stable_input_and_receipt_envelopes_decode_once_test() {
  install(
    "{\"id\":\""
    <> identity
    <> "\",\"queue\":\"steer\",\"payload\":{\"open\":true}}",
  )
  let assert Ok(Some(peer.Pending(id:, queue: peer.Steer, payload:))) =
    peer.inbox_get(entry())
    as "a typed queue retains its open payload"
  assert strand.entry_id_to_string(id) == identity
  assert report.field(payload, "open") == Ok(report.bool(True))
  install(
    "{\"admitted\":true,\"request\":{\"source_session\":\""
    <> identity
    <> "\",\"source_strand\":\"reviewer\",\"target_strand\":\"main\",\"message_id\":\"retry-1\",\"body\":\"complete body\"},\"source\":null}",
  )
  let assert Ok(peer.Admitted(request:, source: None)) =
    peer.send(session(), "main", "retry-1", "complete body")
    as "the existing admission receipt is typed without losing content"
  assert request.source_session == session()
  assert request.body == "complete body"
  dispatch.reset()
}

pub fn malformed_peer_envelopes_never_become_absence_test() {
  list.each(
    [
      "not-json",
      "{}",
      "{\"id\":\"invalid\",\"queue\":\"steer\",\"payload\":null}",
      "{\"id\":\"" <> identity <> "\",\"queue\":\"unknown\",\"payload\":null}",
      "{\"id\":\"" <> identity <> "\",\"queue\":\"materialized\"}",
    ],
    fn(answer) {
      install(answer)
      let assert Error(peer.PeerResultMalformed(_)) = peer.inbox_get(entry())
        as "malformed input is an error rather than missing"
    },
  )
  list.each(
    ["{\"items\":[],\"next\":\"wrong-prefix\"}", "{\"items\":[]}"],
    fn(answer) {
      install(answer)
      let assert Error(peer.PeerResultMalformed(_)) =
        peer.received(peer.first_receipt(), 1)
        as "cursor grammar and explicit absence are checked"
    },
  )
  install("{\"admitted\":false}")
  let assert Error(peer.PeerResultMalformed(_)) =
    peer.send(session(), "main", "id", "text")
    as "a successful call must prove actual admission"
  dispatch.reset()
}

pub fn denial_and_transport_categories_are_preserved_test() {
  dispatch.install(
    channel.Channel(call: fn(_, _, _) {
      Error(channel.Denied("not_owned", "refused"))
    }),
  )
  assert peer.roster() == Error(peer.PeerDenied("not_owned", "refused"))
  dispatch.install(
    channel.Channel(call: fn(_, _, _) { Error(channel.Unreachable("offline")) }),
  )
  assert peer.roster() == Error(peer.PeerUnavailable("offline"))
  dispatch.reset()
}

pub fn custom_metadata_key_collisions_preserve_the_complete_value_test() {
  list.each(
    [
      "{\"session_id\":\"" <> identity <> "\",\"label\":\"embedded\"}",
      "{\"unavailable\":{\"reason\":\"custom\"}}",
      "{\"unavailable\":\"custom\",\"label\":\"embedded\"}",
    ],
    fn(metadata) {
      let assert Ok(expected) = report.decode_json(metadata)
        as "the custom metadata fixture is valid JSON"
      install(
        "[{\"session\":\""
        <> identity
        <> "\",\"target_strand\":\"main\",\"metadata\":"
        <> metadata
        <> ",\"exported_strands\":null}]",
      )
      let assert Ok([peer.Link(metadata: peer.CustomMetadata(actual), ..)]) =
        peer.roster()
        as "partial known keys must not claim an open metadata object"
      assert actual == expected
    },
  )
  dispatch.reset()
}
