//// Bounded authentication HTTP over Loom's existing transport ownership.
////
//// A managed scope adopts the parked HTTP owner before admission. The scope
//// waits for its original drain witness on success, overflow and cancellation,
//// so a failed token exchange cannot abandon a request holding credentials.
//// HTTP redirects are disabled by the shared production transport.

import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import host/bootstrap
import provider/http
import weft

/// A bounded response whose body may still contain secrets until decoded.
pub type Response {
  Response(
    /// The upstream HTTP status.
    status: Int,
    /// The complete bounded UTF-8 response body.
    body: String,
  )
}

/// Publishes HTTP custody into an already managed subscription operation.
///
/// ## Examples
///
/// ```gleam
/// // network.fetch(ledger, request, 65_536)
/// ```
pub fn fetch(
  ledger: weft.Ledger,
  request: http.HttpRequest,
  limit: Int,
) -> Result(Response, String) {
  fetch_adopted(ledger, http.httpc_transport(), request, limit)
}

fn fetch_adopted(
  ledger: weft.Ledger,
  transport: http.Transport,
  request: http.HttpRequest,
  limit: Int,
) -> Result(Response, String) {
  let events = process.new_subject()
  use prepared <- result.try(
    transport.prepare_streaming(request, events)
    |> result.replace_error("request_transport_failed"),
  )
  use Nil <- result.try(
    case
      weft.adopt(
        ledger,
        owner: prepared.running.owner,
        cancel: prepared.running.cancel,
      )
    {
      weft.Adopted -> Ok(Nil)
      weft.Refused -> Error("request_cancelled")
    },
  )
  prepared.begin()
  let answer =
    collect(
      events,
      None,
      <<>>,
      int.max(limit, 0),
      bootstrap.monotonic_time_ms() + 30_000,
    )
  http.cancel(prepared.running)
  answer
}

/// Injects the same transport boundary for ownership and overflow regressions.
///
/// ## Examples
///
/// ```gleam
/// // network.fetch_with(scripted, request, 65_536)
/// ```
@internal
pub fn fetch_with(
  transport: http.Transport,
  request: http.HttpRequest,
  limit: Int,
) -> Result(Response, String) {
  let outcomes =
    weft.new_prepared([
      weft.managed(fn(ledger) {
        fetch_adopted(ledger, transport, request, limit)
      }),
    ])
    |> weft.deadline(30_000)
    |> weft.start
  case outcomes {
    [weft.Completed(_, response)] -> Ok(response)
    [weft.Failed(_, code)] -> Error(code)
    [weft.Crashed(_, _)]
    | [weft.Abandoned(_)]
    | [weft.NeverStarted(_)]
    | [weft.DrainProofLost(_, _)]
    | [weft.CancellationUnconfirmed(_)] -> Error("request_transport_failed")
    _ -> Error("request_transport_failed")
  }
}

fn collect(
  events: process.Subject(http.HttpEvent),
  status: Option(Int),
  bytes: BitArray,
  limit: Int,
  deadline: Int,
) -> Result(Response, String) {
  use event <- result.try(
    process.receive(
      events,
      int.max(deadline - bootstrap.monotonic_time_ms(), 0),
    )
    |> result.replace_error("request_transport_failed"),
  )
  case event {
    http.ResponseStatus(code, _) ->
      case status {
        None -> collect(events, Some(code), bytes, limit, deadline)
        Some(_) -> Error("invalid_http_response")
      }
    http.ResponseChunk(chunk) ->
      case status {
        None -> Error("invalid_http_response")
        Some(_) ->
          case
            bit_array.byte_size(bytes) + bit_array.byte_size(chunk) <= limit
          {
            True ->
              collect(
                events,
                status,
                <<bytes:bits, chunk:bits>>,
                limit,
                deadline,
              )
            False -> Error("response_too_large")
          }
      }
    http.ResponseEnd -> {
      use code <- result.try(case status {
        Some(code) -> Ok(code)
        None -> Error("invalid_http_response")
      })
      use body <- result.try(
        bit_array.to_string(bytes)
        |> result.replace_error("invalid_http_response"),
      )
      Ok(Response(code, body))
    }

    // Authentication fetches have no local inference admission step. A
    // refusal cannot stand in for a remote token or discovery response.
    http.RequestRefused(_, _) | http.RequestFailed(_) ->
      Error("request_transport_failed")
  }
}
