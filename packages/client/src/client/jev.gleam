//// The daemon's one transport to the Jev service.
////
//// Jev answers typed questions about a message with probabilities. The pure
//// half of routing with it, the request to build and the rule that turns the
//// answers into a decision, is `project/jev`. This module is the half that
//// touches the network and the one secret: it holds the key, adds it to the
//// request, bounds the exchange and reports a failure as a reason the ledger
//// can keep. It has one caller today, the project actor's routing pass, and
//// no registry and no cache.
////
//// ## Flow
////
//// `key_from` → `client` → `evaluate` → `pass`
////
//// 1. `key_from` reads the key once, from the variable the file names, when
////    the daemon starts. A rotated key needs a restart.
//// 2. `client` pairs it with the per-request bound and the production fetch.
//// 3. `evaluate` sends one prepared request and returns the decoded answer or
////    a `jev.Why`.
//// 4. `pass` runs a batch's requests one after another, under one bound, and
////    stops asking at the first `Unavailable`.
////
//// ## Where the key goes
////
//// The key is a header value built inside `evaluate` and nowhere else. It is
//// not in a log line, an error, a ledger record or the `Client`'s printed
//// form, and the origin it is sent to is `jevelin.origin`, fixed in code. The
//// fetch is `client/codex/network`'s, which adopts the request into a managed
//// scope, so a cancellation waits for the connection to drain, and the
//// transport refuses redirects, so the header cannot follow one to another
//// host. No new egress path and no new Erlang foreign function is involved.
////
//// ## Why there is no retry
////
//// The model router is the fallback for any trigger Jev cannot answer, and it
//// can decide a candidate now. A retry would delay that candidate to give a
//// failing service another turn, and `network.Response` carries no headers to
//// read the service's retry guidance from. A failed request is therefore a
//// reason, not a loop.

import client/codex/network
import client/jev_settings
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import jevelin
import project/jev
import provider/http

/// The most response bytes the transport reads. A response is a few hundred
/// bytes of probabilities, so a larger body is not Jev's.
pub const response_limit_bytes = 65_536

/// The bound on a whole pass over one batch, in milliseconds. It is well under
/// the router's turn deadline, which a pass that overran would otherwise eat.
pub const pass_bound_ms = 45_000

/// How one exchange is carried out: the request, the most bytes of response to
/// keep and the bound on the whole exchange in milliseconds. The production
/// function is `network.fetch_within` over the shared transport; a test passes
/// its own.
pub type Fetch =
  fn(http.HttpRequest, Int, Int) -> Result(network.Response, String)

/// A key, a bound and a way to fetch. It has no printable form that shows the
/// key: `Client` is opaque and the key is read only by `evaluate`.
pub opaque type Client {
  Client(key: Option(String), timeout_ms: Int, fetch: Fetch)
}

/// The key named by the settings, or none. A variable that is unset or holds
/// only whitespace is no key, which the daemon treats as `NoKey` and not as a
/// failure to start.
///
/// ## Examples
///
/// ```gleam
/// assert jev.key_from(settings, fn(_) { Ok(" k ") }) == Some("k")
/// assert jev.key_from(settings, fn(_) { Error(Nil) }) == None
/// ```
pub fn key_from(
  settings: jev_settings.Settings,
  getenv: fn(String) -> Result(String, Nil),
) -> Option(String) {
  case getenv(settings.api_key_env) {
    Error(Nil) -> None
    Ok(value) ->
      case string.trim(value) {
        "" -> None
        trimmed -> Some(trimmed)
      }
  }
}

/// The client that talks to the real service.
///
/// ## Examples
///
/// ```gleam
/// // jev.client(Some(key), 3000)
/// ```
pub fn client(key: Option(String), timeout_ms: Int) -> Client {
  Client(key:, timeout_ms:, fetch: fn(request, limit, timeout) {
    network.fetch_within(
      http.httpc_transport_with_timeout(timeout),
      request,
      limit,
      timeout,
    )
  })
}

/// A client that fetches with `fetch`, for a test with no network.
///
/// ## Examples
///
/// ```gleam
/// // jev.client_with(Some("k"), 3000, scripted)
/// ```
pub fn client_with(
  key: Option(String),
  timeout_ms: Int,
  fetch: Fetch,
) -> Client {
  Client(key:, timeout_ms:, fetch:)
}

/// The bound on one request, in milliseconds.
///
/// ## Examples
///
/// ```gleam
/// assert jev.timeout_ms(jev.client_with(None, 3000, scripted)) == 3000
/// ```
pub fn timeout_ms(from: Client) -> Int {
  from.timeout_ms
}

/// Sends one prepared request and decodes the answer.
///
/// A client with no key sends nothing and says `NoKey`. Every failure to get
/// an answer, whether the connection, the bound, an oversized body or any
/// status but 200, is `Unavailable`. A 200 whose body is not a valid answer to
/// this request is `Invalid`: the service answered, and the answer is
/// refused. Neither carries the response's text, which could echo a message.
///
/// ## Examples
///
/// ```gleam
/// // jev.evaluate(client, request) -> Error(jev.NoKey) for a client with no key
/// ```
pub fn evaluate(
  from: Client,
  request: jevelin.Request(jevelin.Evaluation(a)),
) -> Result(jevelin.Evaluation(a), jev.Why) {
  // A client with no key never builds the request.
  case from.key {
    None -> Error(jev.NoKey)
    Some(key) -> send(from, key, request)
  }
}

/// Sends the request with the key as its bearer header and reads the answer.
fn send(
  from: Client,
  key: String,
  request: jevelin.Request(jevelin.Evaluation(a)),
) -> Result(jevelin.Evaluation(a), jev.Why) {
  let prepared = jevelin.http_request(request)
  let sent =
    http.HttpRequest(
      method: method_word(prepared.method),
      url: jevelin.origin <> prepared.path,
      headers: [#("authorization", "Bearer " <> key), ..prepared.headers],
      body: prepared.body,
    )

  // A failed exchange carries no response, so there is nothing to decode.
  case from.fetch(sent, response_limit_bytes, from.timeout_ms) {
    Error(_) -> Error(jev.Unavailable)
    Ok(response) -> read(request, response)
  }
}

/// Reads a response as the answer to a request.
fn read(
  request: jevelin.Request(jevelin.Evaluation(a)),
  response: network.Response,
) -> Result(jevelin.Evaluation(a), jev.Why) {
  let received = jevelin.HttpResponse(response.status, [], response.body)

  // The service refusing is not the service answering badly: only a 200 whose
  // body fails decoding is `Invalid`.
  case jevelin.decode_response(request, received) {
    Ok(answered) -> Ok(answered)
    Error(jevelin.HttpFailure(_)) -> Error(jev.Unavailable)
    Error(jevelin.InvalidResponse(_)) -> Error(jev.Invalid)
  }
}

fn method_word(method: jevelin.Method) -> String {
  case method {
    jevelin.Get -> "GET"
    jevelin.Post -> "POST"
  }
}

/// What one candidate's request came to in a pass.
pub type Attempt(a) {
  /// The service answered.
  Answered(jevelin.Evaluation(a))

  /// The request got no usable answer, for this reason.
  Failed(jev.Why)

  /// The pass stopped before this candidate, so no request was sent for it.
  /// The model router receives it with no fallback recorded, since Jev was
  /// not tried.
  Skipped
}

/// Runs the requests of a batch one after another, in order, and answers each
/// with what came of it.
///
/// There is one request in flight. The pass stops asking at the first
/// `Unavailable`, since a service that is down for one candidate is down for
/// the rest, and before a request that could not finish inside `bound_ms` of
/// the pass's start. Every later candidate is `Skipped`. An `Invalid` answer
/// does not stop the pass, because the service did answer. `now_ms` is a
/// monotonic clock, so the bound holds across a change of the wall clock.
///
/// ## Examples
///
/// ```gleam
/// // jev.pass(client, [#("c1", request)], now, 45_000) == [#("c1", Answered(_))]
/// ```
pub fn pass(
  from: Client,
  items: List(#(key, jevelin.Request(jevelin.Evaluation(a)))),
  now_ms: fn() -> Int,
  bound_ms: Int,
) -> List(#(key, Attempt(a))) {
  let deadline = now_ms() + bound_ms
  let #(done, _halted) =
    list.fold(items, #([], False), fn(acc, item) {
      let #(so_far, halted) = acc

      // A halted pass, or one with too little time left for another request,
      // sends nothing.
      case halted || now_ms() + from.timeout_ms > deadline {
        True -> #([#(item.0, Skipped), ..so_far], True)
        False ->
          case evaluate(from, item.1) {
            Ok(answered) -> #([#(item.0, Answered(answered)), ..so_far], False)
            Error(jev.Unavailable) -> #(
              [#(item.0, Failed(jev.Unavailable)), ..so_far],
              True,
            )
            Error(why) -> #([#(item.0, Failed(why)), ..so_far], False)
          }
      }
    })
  list.reverse(done)
}
