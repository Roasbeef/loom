//// The stable peer endpoint alongside the closed legacy orchestrator port.
////
//// The only outer constructor carries versioned JSON. Features describe this
//// service's incarnation, and operation requests prove their expected epoch and
//// literal revision at this same actor before the TopHost can run. The caller's
//// reply subject supplies its owner's node, as at the legacy port. Enrolled
//// distribution peers are fully trusted; a forwarded subject can name another
//// owner and is not proof of the transport sender.

import client/internal/ffi_remote
import client/remote/orchestrator_port.{type TopHost}
import client/remote/peer_codec
import client/remote/peer_top
import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import weft
import weft/actor

/// The one outer request; future operations extend only the JSON body.
pub type Message {
  /// One bounded JSON payload and the subject to which its answer returns.
  Exchange(
    /// The versioned request, decoded before invoking a host callback.
    payload: String,
    /// The reply subject; its owner supplies the existing node attribution.
    reply: Subject(String),
  )
}

/// The fixed name selected before any peer payload is read.
///
/// ## Examples
///
/// ```gleam
/// // peer_service.default()
/// ```
pub fn default() -> Name(Message) {
  ffi_remote.fixed_name("loom_peer_v1")
}

/// Starts the versioned service beside the legacy port, with one captured epoch.
///
/// ## Examples
///
/// ```gleam
/// // peer_service.start(peer_service.default(), epoch, build, top)
/// ```
pub fn start(
  name: Name(Message),
  epoch: String,
  build: String,
  top: TopHost,
) -> actor.StartResult(Subject(Message)) {
  actor.new(Nil)
  |> actor.on_message(fn(state, message: Message) {
    let Exchange(payload, reply) = message

    // Keep work under the reply owner's lifetime, as the legacy port does.
    case process.subject_owner(reply) {
      Ok(requester) -> {
        let origin = ffi_remote.node_of(requester)
        let _witness =
          weft.new([
            fn() {
              process.send(reply, answer(payload, epoch, build, top, origin))
              Ok(Nil)
            },
          ])
          |> weft.cancel_when_exits(requester)
          |> weft.start_witnessed
        Nil
      }
      Error(Nil) -> Nil
    }

    actor.continue(state)
  })
  |> actor.named(name)
  |> actor.start
}

/// Checks epoch and revision before a callback may change remote state.
fn answer(
  payload: String,
  epoch: String,
  build: String,
  top: TopHost,
  origin: String,
) -> String {
  // Invalid envelopes never reach a host callback or establish authority.
  let response = case peer_codec.decode_request(payload) {
    Error(peer_codec.OversizedRequest) ->
      peer_codec.Oversized(peer_codec.request_id(payload))
    Error(peer_codec.UnsupportedRequest) ->
      peer_codec.Unsupported(peer_codec.request_id(payload))
    Error(peer_codec.InvalidRequest) ->
      peer_codec.Malformed(peer_codec.request_id(payload))
    Ok(peer_codec.FeaturesRequest(id)) ->
      peer_codec.FeaturesResponse(
        id,
        peer_codec.Features(epoch:, build:, revisions: peer_codec.revisions),
      )
    Ok(peer_codec.OperationRequest(id:, epoch: expected, revision:, body:)) ->
      case expected == epoch, list.contains(peer_codec.revisions, revision) {
        False, _ -> peer_codec.Stale(id)
        True, False -> peer_codec.Unsupported(id)
        True, True ->
          case peer_top.dispatch(top, origin, revision, body) {
            Ok(Ok(value)) -> peer_codec.OperationResponse(id, value)
            Ok(Error(refusal)) -> peer_codec.RefusalResponse(id, refusal)
            Error(_) -> peer_codec.Malformed(id)
          }
      }
  }

  peer_codec.encode_response(response)
}
