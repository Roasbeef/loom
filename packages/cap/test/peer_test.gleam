//// Inspection calls marshal only selectors; the host owns caller identity.

import cap/internal/channel
import cap/internal/dispatch
import cap/internal/wire
import cap/peer
import core/msgpack
import gleam/result

pub fn inspection_calls_keep_identity_out_of_program_arguments_test() {
  dispatch.install(
    channel.Channel(call: fn(cap, args, _wait) {
      assert result.is_error(wire.string_field(args, "strand"))
      case cap {
        "peer.inbox" | "peer.received" -> {
          assert wire.string_field(args, "after") == Ok("cursor")
          assert wire.int_field(args, "limit") == Ok(2)
        }
        "peer.history" -> {
          assert wire.int_field(args, "before") == Ok(42)
          assert wire.int_field(args, "limit") == Ok(2)
        }
        "peer.inbox_get" -> {
          assert wire.string_field(args, "id") == Ok("entry")
        }
        "peer.received_get" -> {
          assert wire.string_field(args, "source_session") == Ok("source")
          assert wire.string_field(args, "source_strand") == Ok("reviewer")
          assert wire.string_field(args, "message_id") == Ok("report-1")
        }
        "peer.sent_receipt" -> {
          assert wire.string_field(args, "session") == Ok("target")
          assert wire.string_field(args, "message_id") == Ok("report-1")
          assert result.is_error(wire.string_field(args, "source_session"))
        }
        _ -> panic as "only the expected inspection capabilities are called"
      }
      Ok(msgpack.StringValue("null"))
    }),
  )
  assert peer.inbox(after: "cursor", limit: 2) == Ok("null")
  assert peer.inbox_get(id: "entry") == Ok("null")
  assert peer.history(before: 42, limit: 2) == Ok("null")
  assert peer.received(after: "cursor", limit: 2) == Ok("null")
  assert peer.received_get(
      source_session: "source",
      source_strand: "reviewer",
      message_id: "report-1",
    )
    == Ok("null")
  assert peer.sent_receipt(session: "target", message_id: "report-1")
    == Ok("null")
  dispatch.reset()
}
