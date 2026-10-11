//// Native Sign in with ChatGPT transport and operator custody.
////
//// One parked managed task owns each operation. Its witnessed scope adopts
//// every authentication request, callback listener and inference HTTP owner
//// before work begins. Killing the worker therefore cannot erase a socket's
//// cancellation obligation: only the surviving scope publishes the drain proof.
////
//// Profiles own their protected record under a short kernel file lock. The
//// bearer enters only the fixed public API request after that lock is released;
//// control commands and other profiles share no VM-global token cache.

import client/codex/profile
import client/codex/profile_control as control
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/result
import provider/gateway
import provider/http
import weft

/// The native subscription transport, whose caller supplies no credential or host.
///
/// ## Examples
///
/// ```gleam
/// let native = transport.transport()
/// let configured = gateway.with_codex_transport(gateway, native)
/// ```
pub fn transport() -> gateway.CodexTransport {
  gateway.CodexTransport(prepare_streaming: prepare_streaming)
}

/// Prepares one redacted operator command before any file or network work.
/// The caller monitors the returned owner before granting its begin permit.
/// Normal owner exit proves all adopted authentication resources have drained.
///
/// ## Examples
///
/// ```gleam
/// // transport.command("default", control.Status, events)
/// ```
pub fn command(
  profile_name: String,
  action: control.Command,
  events: Subject(control.ControlEvent),
) -> Result(http.PreparedRequest, String) {
  prepare_with(events, fn(ledger) {
    case profile.execute(profile_name, action, events, ledger) {
      Ok(Nil) -> Ok(Nil)
      Error(code) -> {
        process.send(events, control.ControlFailed(code))
        Ok(Nil)
      }
    }
  })
}

fn prepare_streaming(
  profile_name: String,
  request: http.HttpRequest,
  events: Subject(http.HttpEvent),
) -> Result(http.PreparedRequest, String) {
  prepare_streaming_with(
    profile.auth,
    http.httpc_transport(),
    profile_name,
    request,
    events,
  )
}

/// Injects authorization and inference preparation under production custody.
/// Authorization runs only after begin; a refusal admits no inference owner.
///
/// ## Examples
///
/// ```gleam
/// // prepare_streaming_with(authorize, inference, "work", request, events)
/// ```
@internal
pub fn prepare_streaming_with(
  authorize: fn(String, weft.Ledger) -> Result(String, String),
  inference: http.Transport,
  profile_name: String,
  request: http.HttpRequest,
  events: Subject(http.HttpEvent),
) -> Result(http.PreparedRequest, String) {
  use Nil <- result.try(validate_request(request))
  prepare_with(events, fn(ledger) {
    case authorize(profile_name, ledger) {
      Error(code) -> {
        // This local terminal proves no inference request was admitted. The
        // provider retains that evidence while decoding the redacted refusal.
        process.send(events, http.RequestRefused(401, error_body(code)))
        Ok(Nil)
      }
      Ok(bearer) ->
        authenticated_request(ledger, inference, request, bearer, events)
    }
  })
}

/// Prepares an injected operation under the same production custody boundary.
/// The worker owns its begin subject and publishes it before preparation returns.
///
/// ## Examples
///
/// ```gleam
/// // prepare_with(events, fn(_ledger) { Ok(Nil) })
/// ```
@internal
pub fn prepare_with(
  events: Subject(event),
  operation: fn(weft.Ledger) -> Result(Nil, String),
) -> Result(http.PreparedRequest, String) {
  use consumer <- result.try(
    process.subject_owner(events)
    |> result.replace_error("subscription consumer unavailable"),
  )
  let ready = process.new_subject()
  let witnessed =
    weft.new_prepared([
      weft.managed(fn(ledger) {
        let begin = process.new_subject()
        process.send(ready, begin)
        process.receive_forever(begin)
        operation(ledger)
      }),
    ])
    |> weft.on_failure(weft.CancelSiblings)
    |> weft.cancel_when_exits(consumer)
    |> weft.start_witnessed
  let watch = process.monitor(weft.witness_pid(witnessed))
  let readiness =
    process.new_selector()
    |> process.select_map(ready, Ok)
    |> process.select_specific_monitor(watch, fn(_) { Error(Nil) })
  let publication = process.selector_receive(readiness, 5000)
  process.demonitor_process(watch)

  // Only the worker can receive its permit. A failed publication cancels the
  // surviving scope, which keeps custody of any resource already adopted.
  case publication {
    Ok(Ok(begin)) ->
      Ok(
        http.PreparedRequest(
          running: http.RunningRequest(
            owner: weft.witness_pid(witnessed),
            cancel: fn() { weft.cancel_witnessed(witnessed) },
          ),
          begin: fn() { process.send(begin, Nil) },
        ),
      )
    Ok(Error(Nil)) | Error(Nil) -> {
      weft.cancel_witnessed(witnessed)
      Error("subscription operation unavailable")
    }
  }
}

// The uncredentialed relative boundary is checked before parking. The only
// authenticated request this task can construct targets the public Responses API.
fn authenticated_request(
  ledger: weft.Ledger,
  inference: http.Transport,
  request: http.HttpRequest,
  bearer: String,
  events: Subject(http.HttpEvent),
) -> Result(Nil, String) {
  let authenticated =
    http.HttpRequest(
      ..request,
      url: "https://api.openai.com/v1/responses",
      headers: [#("authorization", "Bearer " <> bearer), ..request.headers],
    )
  case inference.prepare_streaming(authenticated, events) {
    Error(_) -> {
      process.send(events, http.RequestFailed("subscription transport failed"))
      Ok(Nil)
    }
    Ok(prepared) ->
      case weft.adopt(ledger, prepared.running.owner, prepared.running.cancel) {
        weft.Refused -> Ok(Nil)
        weft.Adopted -> {
          // The native HTTP owner also watches its creating worker. Keeping
          // that worker alive through drain prevents a normal return from
          // cancelling the admitted request before its terminal response.
          let watch = process.monitor(prepared.running.owner)
          prepared.begin()
          process.new_selector()
          |> process.select_specific_monitor(watch, fn(_) { Nil })
          |> process.selector_receive_forever
          Ok(Nil)
        }
      }
  }
}

/// Refuses arbitrary URLs, routing headers and caller-supplied credentials.
///
/// ## Examples
///
/// ```gleam
/// // validate_request(http.HttpRequest("POST", "/responses", [#("content-type", "application/json"), #("accept", "text/event-stream")], "{}")) == Ok(Nil)
/// ```
pub fn validate_request(request: http.HttpRequest) -> Result(Nil, String) {
  case request.method, request.url, request.headers {
    "POST",
      "/responses",
      [#("content-type", "application/json"), #("accept", "text/event-stream")]
    -> Ok(Nil)
    _, _, _ ->
      Error("subscription request contains a forbidden method, URL, or header")
  }
}

// Only locally defined error codes reach this JSON boundary. Escaping remains
// structural so a future code addition cannot introduce an invalid response.
fn error_body(code: String) -> BitArray {
  json.object([
    #(
      "error",
      json.object([
        #("type", json.string("subscription_authentication")),
        #("code", json.string(code)),
        #("message", json.string("Sign in with ChatGPT requires authorization")),
      ]),
    ),
  ])
  |> json.to_string
  |> bit_array.from_string
}
