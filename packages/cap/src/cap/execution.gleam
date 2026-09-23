//// Typed input endpoints and progress for the current background execution.
////
//// The host owns one ordered, bounded input journal. `serve` registers the
//// names a program accepts, drains that journal once, and routes each value
//// through an endpoint's decoder before its delivery closure runs. The
//// endpoint erases its message type only after those functions are coupled,
//// so a heterogeneous list never exposes an untyped actor address.
////
//// Readiness is explicit. A named send is refused until `serve` registers
//// every endpoint. The older raw `receive` implicitly registers the reserved
//// `default` endpoint. Delivery means the callback returned successfully; it
//// does not prove that an actor has finished processing the message.

import cap/internal/dispatch
import cap/internal/wire
import cap/report.{type Value}
import core/msgpack
import gleam/list
import gleam/result
import gleam/string

/// The largest endpoint set one execution may register.
pub const max_endpoints = 16

/// The longest explicit idle lifetime accepted by `serve`.
pub const max_idle_within_ms = 300_000

const max_receive_wait_ms = 30_000

const receive_deadline_margin_ms = 1000

/// A bounded receive distinguishes silence from a closed execution.
pub type Received {
  /// One committed input and the cursor for the next receive.
  Message(sequence: Int, value: Value)

  /// No input arrived within this call's wait budget.
  TimedOut

  /// The harness has closed the execution's input channel.
  Closed
}

/// Why an endpoint could not be constructed.
pub type EndpointError {
  /// Names are 1..64 ASCII bytes from `[a-z0-9._-]`.
  InvalidEndpointName(name: String)
}

/// A typed delivery endpoint with its message type erased behind a closure.
pub opaque type Endpoint {
  Endpoint(name: String, dispatch: fn(Value) -> Result(Nil, String))
}

/// Why a typed serving loop could not continue.
pub type ServeError {
  /// At least one endpoint is required.
  NoEndpoints

  /// No more than `max_endpoints` may be registered.
  TooManyEndpoints

  /// Every endpoint name must be unique within one execution.
  DuplicateEndpoint(name: String)

  /// The idle lifetime was outside 1..300000 milliseconds.
  InvalidIdleWithin(milliseconds: Int)

  /// The host refused or could not persist readiness.
  ReadyFailed(reason: String)

  /// The ordered input journal could not be read.
  ReceiveFailed(reason: String)

  /// The host could not record the latest delivery status.
  DeliveryFailed(reason: String)
}

/// Why a typed serving loop ended normally.
pub type ServeExit {
  /// No successfully delivered input arrived before the idle lifetime elapsed.
  Idle

  /// The host closed this execution's input channel.
  InputClosed
}

/// The host's acknowledgement of a published progress snapshot.
pub type Progress {
  Progress(observed_sequence: Int, observed_updated_ms: Int)
}

type Enveloped {
  Enveloped(sequence: Int, endpoint: String, value: Value)
  EnvelopedWaitTimedOut
  EnvelopedIdle
  EnvelopedClosed
}

/// Couples one endpoint name to a decoder and typed delivery function.
///
/// The returned value is non-generic because its closure decodes and delivers
/// the same private `message` type. This permits a heterogeneous endpoint list
/// without exposing a raw BEAM subject.
///
/// ## Examples
///
/// ```gleam
/// // execution.endpoint("counter", fn(value) {
/// //   report.as_int(value) |> result.replace_error("expected integer")
/// // }, fn(n) {
/// //   actor.send(counter, n)
/// //   Ok(Nil)
/// // })
/// ```
pub fn endpoint(
  name name: String,
  decode decode: fn(Value) -> Result(message, String),
  deliver deliver: fn(message) -> Result(Nil, String),
) -> Result(Endpoint, EndpointError) {
  case valid_endpoint_name(name) {
    False -> Error(InvalidEndpointName(name:))
    True ->
      Ok(
        Endpoint(name:, dispatch: fn(value) {
          use message <- result.try(decode(value))
          deliver(message)
        }),
      )
  }
}

/// Registers typed endpoints and drains the execution-owned input journal.
///
/// The host measures `idle_within_ms` from readiness or the last successful
/// delivery. A rejected value does not renew it. On idle expiry the host first
/// records terminal loss and starts execution-owned cancellation, then answers
/// this loop with `Idle`; channel closure may win that response race and yield
/// `InputClosed` instead. The host reaps the satellite in either case.
///
/// ## Examples
///
/// ```gleam
/// // execution.serve([counter_endpoint], idle_within_ms: 60_000)
/// ```
pub fn serve(
  endpoints: List(Endpoint),
  idle_within_ms idle: Int,
) -> Result(ServeExit, ServeError) {
  use names <- result.try(validate_endpoints(endpoints))
  use _ <- result.try(validate_idle(idle))
  use _ <- result.try(
    dispatch.call(
      "execution.ready",
      wire.args([
        #("endpoints", wire.string_array(names)),
        #("idle_within_ms", wire.int(idle)),
      ]),
    )
    |> result.map_error(fn(error) { ReadyFailed(string.inspect(error)) }),
  )
  serve_loop(endpoints, 0, idle)
}

/// Publishes the execution's latest bounded progress snapshot.
///
/// Progress is volatile and coalesced by the host. The acknowledgement names
/// the snapshot currently published by the host. The submitted value may still
/// be pending, and a later update may supersede it before publication.
///
/// ## Examples
///
/// ```gleam
/// // execution.progress(report.string("indexing"))
/// ```
pub fn progress(value: Value) -> Result(Progress, String) {
  use answer <- result.try(
    dispatch.call("execution.progress", wire.args([#("value", value)]))
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  use sequence <- result.try(wire.int_field(answer, "sequence"))
  use updated_ms <- result.try(wire.int_field(answer, "updated_ms"))
  Ok(Progress(observed_sequence: sequence, observed_updated_ms: updated_ms))
}

/// Reads input committed after the supplied cursor, initially zero.
/// This never changes the execution's original lifetime or permissions.
/// Calling it before typed `serve` publishes legacy readiness for `default`.
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
  use value <- result.try(call_receive("execution.receive", cursor, wait))
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

fn serve_loop(
  endpoints: List(Endpoint),
  cursor: Int,
  idle: Int,
) -> Result(ServeExit, ServeError) {
  case receive_enveloped(cursor, idle) {
    Error(reason) -> Error(ReceiveFailed(reason:))
    Ok(EnvelopedWaitTimedOut) -> serve_loop(endpoints, cursor, idle)
    Ok(EnvelopedIdle) -> Ok(Idle)
    Ok(EnvelopedClosed) -> Ok(InputClosed)
    Ok(Enveloped(sequence:, endpoint: name, value:)) -> {
      let delivered = deliver_to(endpoints, name, value)
      use _ <- result.try(record_delivery(sequence, name, delivered))
      serve_loop(endpoints, sequence, idle)
    }
  }
}

fn receive_enveloped(cursor: Int, wait: Int) -> Result(Enveloped, String) {
  use value <- result.try(call_receive(
    "execution.receive_enveloped",
    cursor,
    wait,
  ))
  case value {
    msgpack.NilValue -> Ok(EnvelopedWaitTimedOut)
    _ ->
      case wire.field(value, "idle"), wire.field(value, "closed") {
        Ok(msgpack.BoolValue(True)), _ -> Ok(EnvelopedIdle)
        Ok(_), _ -> Error("invalid execution idle marker")
        _, Ok(msgpack.StringValue(_)) -> Ok(EnvelopedClosed)
        _, Ok(_) -> Error("invalid execution closure")
        Error(_), Error(_) -> {
          use sequence <- result.try(wire.int_field(value, "sequence"))
          use name <- result.try(wire.string_field(value, "endpoint"))
          use value <- result.try(wire.field(value, "value"))
          case sequence > cursor {
            True -> Ok(Enveloped(sequence:, endpoint: name, value:))
            False -> Error("execution receive did not advance the cursor")
          }
        }
      }
  }
}

fn call_receive(
  capability: String,
  cursor: Int,
  wait: Int,
) -> Result(Value, String) {
  let bounded_wait = case wait > max_receive_wait_ms {
    True -> max_receive_wait_ms
    False -> wait
  }
  dispatch.call_within(
    capability,
    wire.args([
      #("after", wire.int(cursor)),
      #("within_ms", wire.int(bounded_wait)),
    ]),
    bounded_wait + receive_deadline_margin_ms,
  )
  |> result.map_error(fn(error) { string.inspect(error) })
}

fn record_delivery(
  sequence: Int,
  endpoint: String,
  delivered: Result(Nil, String),
) -> Result(Nil, ServeError) {
  let #(accepted, reason) = case delivered {
    Ok(Nil) -> #(True, msgpack.NilValue)
    Error(reason) -> #(False, msgpack.StringValue(bounded_reason(reason)))
  }
  dispatch.call(
    "execution.delivery",
    wire.args([
      #("sequence", wire.int(sequence)),
      #("endpoint", wire.string(endpoint)),
      #("delivered", wire.bool(accepted)),
      #("reason", reason),
    ]),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) { DeliveryFailed(string.inspect(error)) })
}

fn deliver_to(
  endpoints: List(Endpoint),
  name: String,
  value: Value,
) -> Result(Nil, String) {
  case endpoints {
    [] -> Error("input named an endpoint that was not registered")
    [Endpoint(name: expected, dispatch:), ..rest] ->
      case expected == name {
        True -> dispatch(value)
        False -> deliver_to(rest, name, value)
      }
  }
}

fn validate_endpoints(
  endpoints: List(Endpoint),
) -> Result(List(String), ServeError) {
  case endpoints {
    [] -> Error(NoEndpoints)
    _ ->
      case list.length(endpoints) > max_endpoints {
        True -> Error(TooManyEndpoints)
        False -> unique_names(endpoints, [])
      }
  }
}

fn unique_names(
  endpoints: List(Endpoint),
  seen: List(String),
) -> Result(List(String), ServeError) {
  case endpoints {
    [] -> Ok(list.reverse(seen))
    [Endpoint(name:, ..), ..rest] ->
      case list.contains(seen, name) {
        True -> Error(DuplicateEndpoint(name:))
        False -> unique_names(rest, [name, ..seen])
      }
  }
}

fn validate_idle(idle: Int) -> Result(Nil, ServeError) {
  case idle >= 1 && idle <= max_idle_within_ms {
    True -> Ok(Nil)
    False -> Error(InvalidIdleWithin(milliseconds: idle))
  }
}

fn valid_endpoint_name(name: String) -> Bool {
  string.byte_size(name) >= 1
  && string.byte_size(name) <= 64
  && list.all(string.to_utf_codepoints(name), fn(point) {
    let character = string.utf_codepoint_to_int(point)
    character >= 97
    && character <= 122
    || character >= 48
    && character <= 57
    || character == 46
    || character == 95
    || character == 45
  })
}

fn bounded_reason(reason: String) -> String {
  case string.byte_size(reason) <= 1024 {
    True -> reason
    False -> "endpoint rejected payload with an oversized reason"
  }
}
