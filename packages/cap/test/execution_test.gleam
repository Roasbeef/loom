//// Typed execution endpoint tests pin both halves of the satellite wire.
////
//// The fake channel exercises exact capability names and argument maps. The
//// serving test also proves heterogeneous decoding, rejection before callback,
//// ordered cursor advancement, and continued service after a bad value.

import cap/execution
import cap/internal/channel
import cap/internal/dispatch
import cap/internal/wire
import cap/report
import core/msgpack
import gleam/erlang/process
import gleam/result
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

fn install_fake(
  with call: fn(String, msgpack.MsgPackValue, Int) ->
    Result(msgpack.MsgPackValue, channel.CallError),
) -> Nil {
  dispatch.install(channel.Channel(call:))
}

fn map(entries: List(#(String, msgpack.MsgPackValue))) -> msgpack.MsgPackValue {
  wire.args(entries)
}

fn envelope(
  sequence: Int,
  endpoint: String,
  value: msgpack.MsgPackValue,
) -> msgpack.MsgPackValue {
  map([
    #("sequence", wire.int(sequence)),
    #("endpoint", wire.string(endpoint)),
    #("value", value),
  ])
}

/// Endpoint construction enforces the host's closed name grammar.
pub fn endpoint_names_are_validated_test() {
  let deliver = fn(_message) { Ok(Nil) }
  assert result.is_ok(execution.endpoint(
    name: "worker.result-1",
    decode: fn(value) { Ok(value) },
    deliver:,
  ))
  assert execution.endpoint(
      name: "Worker Result",
      decode: fn(value) { Ok(value) },
      deliver:,
    )
    == Error(execution.InvalidEndpointName("Worker Result"))
}

/// Typed serve registers once, rejects malformed input without calling its
/// callback, and continues routing later heterogeneous values in order.
pub fn serve_routes_heterogeneous_endpoints_and_records_rejection_test() {
  let calls = process.new_subject()
  let step = process.new_subject()
  let texts = process.new_subject()
  let numbers = process.new_subject()
  process.send(step, 0)
  install_fake(with: fn(capability, args, _deadline) {
    process.send(calls, #(capability, args))
    case capability {
      "execution.ready" -> Ok(msgpack.NilValue)
      "execution.receive_enveloped" -> {
        let assert Ok(index) = process.receive(step, 100)
        process.send(step, index + 1)
        case index {
          0 -> Ok(envelope(1, "number", report.string("wrong")))
          1 -> Ok(envelope(2, "text", report.string("hello")))
          2 -> Ok(envelope(3, "number", report.int(7)))
          _ -> Ok(map([#("idle", wire.bool(True))]))
        }
      }
      "execution.delivery" -> Ok(msgpack.NilValue)
      _ -> Error(channel.Denied("unexpected", capability))
    }
  })
  let assert Ok(text_endpoint) =
    execution.endpoint(
      name: "text",
      decode: fn(value) {
        report.as_string(value) |> result.replace_error("expected text")
      },
      deliver: fn(value) {
        process.send(texts, value)
        Ok(Nil)
      },
    )
  let assert Ok(number_endpoint) =
    execution.endpoint(
      name: "number",
      decode: fn(value) {
        report.as_int(value) |> result.replace_error("expected integer")
      },
      deliver: fn(value) {
        process.send(numbers, value)
        Ok(Nil)
      },
    )

  assert execution.serve([text_endpoint, number_endpoint], idle_within_ms: 1200)
    == Ok(execution.Idle)
  assert process.receive(texts, 100) == Ok("hello")
  assert process.receive(numbers, 100) == Ok(7)

  let assert Ok(#("execution.ready", ready)) = process.receive(calls, 100)
  assert ready
    == map([
      #("endpoints", wire.string_array(["text", "number"])),
      #("idle_within_ms", wire.int(1200)),
    ])
  let assert Ok(#("execution.receive_enveloped", _)) =
    process.receive(calls, 100)
  let assert Ok(#("execution.delivery", rejected)) = process.receive(calls, 100)
  assert rejected
    == map([
      #("sequence", wire.int(1)),
      #("endpoint", wire.string("number")),
      #("delivered", wire.bool(False)),
      #("reason", wire.string("expected integer")),
    ])
  let assert Ok(#("execution.receive_enveloped", second_receive)) =
    process.receive(calls, 100)
  assert wire.int_field(second_receive, "after") == Ok(1)
  let assert Ok(#("execution.delivery", delivered_text)) =
    process.receive(calls, 100)
  assert wire.bool_field(delivered_text, "delivered") == Ok(True)
  let assert Ok(#("execution.receive_enveloped", third_receive)) =
    process.receive(calls, 100)
  assert wire.int_field(third_receive, "after") == Ok(2)
  let assert Ok(#("execution.delivery", delivered_number)) =
    process.receive(calls, 100)
  assert wire.bool_field(delivered_number, "delivered") == Ok(True)
  let assert Ok(#("execution.receive_enveloped", final_receive)) =
    process.receive(calls, 100)
  assert wire.int_field(final_receive, "after") == Ok(3)
}

/// Progress sends one value and decodes the host's sequence and timestamp.
pub fn progress_wire_shape_is_pinned_test() {
  let seen = process.new_subject()
  install_fake(with: fn(capability, args, _deadline) {
    process.send(seen, #(capability, args))
    Ok(
      map([
        #("sequence", wire.int(4)),
        #("updated_ms", wire.int(9000)),
      ]),
    )
  })

  assert execution.progress(report.string("halfway"))
    == Ok(execution.Progress(observed_sequence: 4, observed_updated_ms: 9000))
  assert process.receive(seen, 100)
    == Ok(#("execution.progress", map([#("value", report.string("halfway"))])))
}

/// Raw receive remains wire-compatible and leaves endpoint routing to callers.
pub fn legacy_receive_wire_shape_is_preserved_test() {
  let seen = process.new_subject()
  install_fake(with: fn(capability, args, deadline) {
    process.send(seen, #(capability, args, deadline))
    Ok(
      map([
        #("sequence", wire.int(2)),
        #("value", report.string("legacy")),
      ]),
    )
  })

  assert execution.receive(after: 1, within_ms: 50)
    == Ok(execution.Message(sequence: 2, value: report.string("legacy")))
  assert process.receive(seen, 100)
    == Ok(#(
      "execution.receive",
      map([#("after", wire.int(1)), #("within_ms", wire.int(50))]),
      1050,
    ))
}

/// A host wait never races the channel's deadline at the same millisecond.
pub fn receive_wait_is_capped_with_deadline_slack_test() {
  let seen = process.new_subject()
  install_fake(with: fn(_capability, args, deadline) {
    process.send(seen, #(args, deadline))
    Ok(msgpack.NilValue)
  })

  assert execution.receive(after: 0, within_ms: 90_000)
    == Ok(execution.TimedOut)
  assert process.receive(seen, 100)
    == Ok(#(
      map([#("after", wire.int(0)), #("within_ms", wire.int(30_000))]),
      31_000,
    ))
}
