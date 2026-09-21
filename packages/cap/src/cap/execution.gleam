//// Input to the current background execution, bound by the harness.
////
//// Reads are non-destructive. Keep the last returned sequence in program
//// state and pass it to the next receive. Retrying a receive with the same
//// cursor returns the same value after a lost response. The program decodes
//// the value before sending a typed message to one of its own actors.

import cap/internal/dispatch
import cap/internal/wire
import cap/report.{type Value}
import core/msgpack
import gleam/result
import gleam/string

/// A bounded receive distinguishes silence from a closed execution.
pub type Received {
  /// One committed input and the cursor for the next receive.
  Message(sequence: Int, value: Value)

  /// No input arrived within this call's wait budget.
  TimedOut

  /// The harness has closed the execution's input channel.
  Closed
}

/// Reads input committed after the supplied cursor, initially zero.
/// This never changes the execution's original lifetime or permissions.
///
/// ## Examples
///
/// ```gleam
/// // execution.receive(after: 0, within_ms: 1000)
/// ```
pub fn receive(
  after cursor: Int,
  within_ms wait: Int,
) -> Result(Received, String) {
  use value <- result.try(
    dispatch.call(
      "execution.receive",
      wire.args([
        #("after", wire.int(cursor)),
        #("within_ms", wire.int(wait)),
      ]),
    )
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  case value {
    msgpack.NilValue -> Ok(TimedOut)
    _ ->
      case wire.field(value, "closed") {
        Ok(msgpack.StringValue(_)) -> Ok(Closed)
        Ok(_) -> Error("invalid execution closure")
        Error(_) -> {
          use sequence <- result.try(wire.int_field(value, "sequence"))
          use value <- result.try(wire.field(value, "value"))
          case sequence > cursor {
            True -> Ok(Message(sequence:, value:))
            False -> Error("execution receive did not advance the cursor")
          }
        }
      }
  }
}
