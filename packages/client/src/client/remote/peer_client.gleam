//// One negotiated call to the stable peer endpoint.
////
//// Features and dispatch share one deadline. The endpoint alone receives both
//// messages; the legacy name never receives a probe or a later operation. A
//// lost operation reply is distinct from failure before dispatch.

import client/internal/ffi_os
import client/remote/address.{type Address}
import client/remote/peer_codec
import client/remote/peer_service
import client/remote_top
import core/json.{type JsonValue}
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import weft
import weft/poll

/// What a negotiated operation could establish about dispatch.
pub type Failure {
  /// The endpoint is absent or did not advertise the requested revision.
  Unsupported

  /// Discovery could not complete before any operation was sent.
  Unavailable

  /// A replacement rejected the previously observed epoch before dispatch.
  Stale

  /// The feature reply was malformed or did not match the request.
  InvalidFeatures

  /// The operation request exceeded its limit before dispatch.
  RequestTooLarge

  /// A dispatched operation did not return an answer.
  ReplyLost

  /// A dispatched operation returned an oversized answer.
  ReplyTooLarge

  /// A dispatched operation returned an unreadable answer.
  Unreadable
}

type TransportFailure {
  Absent
  NoAnswer
}

/// Discovers a revision and dispatches it against the observed epoch.
///
/// ## Examples
///
/// ```gleam
/// // peer_client.call(address, "094.stop.1", body, 7000)
/// ```
pub fn call(
  at: Address(peer_service.Message),
  revision: String,
  body: JsonValue,
  within_ms: Int,
) -> Result(Result(JsonValue, remote_top.Refusal), Failure) {
  let clock = poll.monotonic()
  let started = clock.now()
  let feature_id = int.to_string(ffi_os.unique_positive_integer())
  let request = peer_codec.features_request(feature_id)
  use feature_text <- result.try(
    exchange(at, request, within_ms)
    |> result.map_error(fn(error) {
      case error {
        Absent -> Unsupported
        NoAnswer -> Unavailable
      }
    }),
  )

  // Only a correlated features answer can authorize a later dispatch.
  use features <- result.try(
    peer_codec.decode_response(
      feature_text,
      feature_id,
      peer_codec.feature_reply_bytes,
    )
    |> result.map_error(fn(_) { InvalidFeatures })
    |> result.try(fn(response) {
      case response {
        peer_codec.FeaturesResponse(_, features) -> Ok(features)
        peer_codec.Unsupported(_) -> Error(Unsupported)
        peer_codec.OperationResponse(..)
        | peer_codec.RefusalResponse(..)
        | peer_codec.Stale(_)
        | peer_codec.Malformed(_)
        | peer_codec.Oversized(_) -> Error(InvalidFeatures)
      }
    }),
  )

  // The second exchange spends only the first call's remaining budget.
  use <- require_revision(features.revisions, revision)
  let id = int.to_string(ffi_os.unique_positive_integer())
  let operation =
    peer_codec.operation_request(id, features.epoch, revision, body)
  use <- require_size(operation)
  let left = within_ms - { clock.now() - started }
  use <- require_time(left)
  use answer <- result.try(
    exchange(at, operation, left)
    |> result.map_error(fn(error) {
      case error {
        Absent | NoAnswer -> ReplyLost
      }
    }),
  )

  // Once sent, an unreadable answer leaves the operation's effect uncertain.
  use <- require_reply_size(answer)
  use response <- result.try(
    peer_codec.decode_response(answer, id, peer_codec.operation_bytes)
    |> result.replace_error(Unreadable),
  )

  // Only an explicit endpoint refusal proves it rejected the operation.
  case response {
    peer_codec.OperationResponse(_, value) -> Ok(Ok(value))
    peer_codec.RefusalResponse(_, refusal) -> Ok(Error(refusal))
    peer_codec.Unsupported(_) -> Error(Unsupported)
    peer_codec.Stale(_) -> Error(Stale)
    peer_codec.Malformed(_) -> Error(Unreadable)
    peer_codec.Oversized(_) -> Error(ReplyTooLarge)
    peer_codec.FeaturesResponse(..) -> Error(Unreadable)
  }
}

/// The feature list is advisory; dispatch rechecks this revision at the box.
fn require_revision(
  revisions: List(String),
  revision: String,
  then: fn() -> Result(a, Failure),
) -> Result(a, Failure) {
  case list.contains(revisions, revision) {
    True -> then()
    False -> Error(Unsupported)
  }
}

/// Refuses an oversize operation before dispatch.
fn require_size(
  text: String,
  then: fn() -> Result(a, Failure),
) -> Result(a, Failure) {
  case string.byte_size(text) <= peer_codec.operation_bytes {
    True -> then()
    False -> Error(RequestTooLarge)
  }
}

/// An oversized reply can follow an admitted operation.
fn require_reply_size(
  text: String,
  then: fn() -> Result(a, Failure),
) -> Result(a, Failure) {
  case string.byte_size(text) <= peer_codec.operation_bytes {
    True -> then()
    False -> Error(ReplyTooLarge)
  }
}

/// An expired feature budget cannot start a second full wait.
fn require_time(
  left: Int,
  then: fn() -> Result(a, Failure),
) -> Result(a, Failure) {
  case left > 0 {
    True -> then()
    False -> Error(Unavailable)
  }
}

/// Monitors the name before sending and preserves its reason on failure.
fn exchange(
  at: Address(peer_service.Message),
  payload: String,
  within_ms: Int,
) -> Result(String, TransportFailure) {
  let clock = poll.monotonic()
  let started = clock.now()
  let reply = process.new_subject()
  let watched = address.watch(at)

  // Sending to a missing local name raises in OTP. A bounded Weft worker
  // isolates that local race while the destination monitor records its cause.
  case at.node == node.self() {
    True -> {
      let _ =
        weft.new([
          fn() {
            address.deliver(at, peer_service.Exchange(payload, reply))
            Ok(Nil)
          },
        ])
        |> weft.deadline(within_ms)
        |> weft.cancel_grace(0)
        |> weft.start
      Nil
    }
    False -> address.deliver(at, peer_service.Exchange(payload, reply))
  }

  let left = int.max(0, within_ms - { clock.now() - started })

  // Even a failed local send waits for the monitored name's actual DOWN.
  let heard =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(watched, fn(down) { Error(reason(down)) })
    |> process.selector_receive(left)
  process.demonitor_process(watched)
  result.unwrap(heard, Error(NoAnswer))
}

/// `noproc` means the fixed name is absent; disconnection is not that fact.
fn reason(down: process.Down) -> TransportFailure {
  // Both monitor kinds carry the exit reason, not a usable remote PID.
  let exit = case down {
    process.ProcessDown(reason:, ..) | process.PortDown(reason:, ..) -> reason
  }

  // Only OTP's missing-name reason supports an unsupported classification.
  case exit {
    process.Abnormal(detail) ->
      case detail == atom.to_dynamic(atom.create("noproc")) {
        True -> Absent
        False -> NoAnswer
      }
    process.Normal | process.Killed -> NoAnswer
  }
}
