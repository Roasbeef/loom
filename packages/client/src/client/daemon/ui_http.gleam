//// The web view's request checks and response headers (protocol-change/051),
//// as pure functions of a request.
////
//// A page served from loopback is reachable by every other page the same
//// browser loads, so the loopback bind that protects the v2 sockets does
//// not protect the view. These checks are what does. Each is a function of
//// the request alone, generic over its body, so the tests can hand them any
//// header a browser, a rebinding attacker or a program that is not a
//// browser might send, without a listener. `client/daemon/server` applies
//// them in the order 051 gives: the host first, then the check that belongs
//// to the route, then the cookie.

import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import web_view/page

/// The cookie that carries a UI session.
pub const cookie_name = "loom_ui"

/// One `/ui` request, by route.
pub type Route {
  /// `GET /ui/sessions/<id>`: the page.
  Page(session_id: String)

  /// `GET /ui/sessions/<id>?ticket=<ticket>`: the ticket exchange.
  Exchange(session_id: String, ticket: String)

  /// `GET /ui/sessions/<id>/ws`: the component's socket.
  Socket(session_id: String)

  /// `GET /ui/assets/<name>`, for one of the fixed asset names.
  Asset(asset: Asset)

  /// Anything else under `/ui`.
  Unknown
}

/// The fixed list of assets.
pub type Asset {
  /// Lustre's client runtime.
  Runtime

  /// The page's stylesheet.
  Stylesheet

  /// The exchange page's script.
  EnterScript
}

/// Routes a `/ui` request; every route is a `GET`. The session ID is returned as the path gave it;
/// the caller parses it as a canonical ID before using it.
///
/// ## Examples
///
/// ```gleam
/// // ui_http.route(request) == ui_http.Socket("0198...")
/// ```
pub fn route(request: Request(body)) -> Route {
  case request.method, request.path_segments(request) {
    http.Get, ["ui", "sessions", id] ->
      case ticket(request) {
        Some(ticket) -> Exchange(id, ticket)
        None -> Page(id)
      }
    http.Get, ["ui", "sessions", id, "ws"] -> Socket(id)
    http.Get, ["ui", "assets", name] ->
      case name {
        _ if name == page.runtime_asset -> Asset(Runtime)
        _ if name == page.stylesheet_asset -> Asset(Stylesheet)
        _ if name == page.enter_asset -> Asset(EnterScript)
        _ -> Unknown
      }
    _, _ -> Unknown
  }
}

fn ticket(request: Request(body)) -> Option(String) {
  request.get_query(request)
  |> result.unwrap([])
  |> list.key_find("ticket")
  |> option.from_result
}

/// The request's `Host` when it names loopback, with any port.
///
/// The listener binds only loopback, and a browser that reaches it through
/// a local forward presents the forward's port, so the port is not checked.
/// The name is: a DNS rebinding attack reaches the listener under its own
/// host name, and is refused here.
///
/// ## Examples
///
/// ```gleam
/// // ui_http.loopback_host(request) == Ok("127.0.0.1:4000")
/// ```
pub fn loopback_host(request: Request(body)) -> Result(String, Nil) {
  use host <- result.try(request.get_header(request, "host"))
  let name = case string.split_once(host, "]") {
    // A bracketed IPv6 literal, with or without a port after the bracket.
    Ok(#(literal, rest)) -> #(literal <> "]", rest)
    Error(Nil) ->
      case string.split_once(host, ":") {
        Ok(#(name, port)) -> #(name, ":" <> port)
        Error(Nil) -> #(host, "")
      }
  }
  case string.lowercase(name.0), valid_port(name.1) {
    "127.0.0.1", True | "[::1]", True | "localhost", True -> Ok(host)
    _, _ -> Error(Nil)
  }
}

fn valid_port(suffix: String) -> Bool {
  case suffix {
    "" -> True
    ":" <> digits ->
      digits != ""
      && string.length(digits) <= 5
      && list.all(string.to_graphemes(digits), fn(digit) {
        string.contains("0123456789", digit)
      })
    _ -> False
  }
}

/// Whether the ticket exchange may proceed: `Sec-Fetch-Site` is `none` (a
/// link opened from outside any page) or `same-origin`.
///
/// A top-level navigation sends no `Origin`, so this is the exchange's
/// cross-site check. The ticket itself is the CSRF secret; this refuses the
/// exchange when another site drives the browser to it.
///
/// ## Examples
///
/// ```gleam
/// // ui_http.exchange_allowed(request)
/// ```
pub fn exchange_allowed(request: Request(body)) -> Bool {
  case request.get_header(request, "sec-fetch-site") {
    Ok("none") | Ok("same-origin") -> True
    Ok(_) | Error(Nil) -> False
  }
}

/// Whether a WebSocket upgrade came from this origin: `Origin` is present
/// and is `http://` followed by the request's host.
///
/// ## Examples
///
/// ```gleam
/// // ui_http.origin_matches(request, "127.0.0.1:4000")
/// ```
pub fn origin_matches(request: Request(body), host: String) -> Bool {
  case request.get_header(request, "origin") {
    Ok(origin) -> origin == "http://" <> host
    Error(Nil) -> False
  }
}

/// The `loom_ui` cookie, when the request carries one.
///
/// ## Examples
///
/// ```gleam
/// // ui_http.session_cookie(request) == Some("…")
/// ```
pub fn session_cookie(request: Request(body)) -> Option(String) {
  request.get_cookies(request)
  |> list.key_find(cookie_name)
  |> option.from_result
}

/// The `Set-Cookie` value for a new UI session.
///
/// `HttpOnly` keeps it from every script, `SameSite=Strict` keeps a
/// cross-site navigation from carrying it, and `Path=/ui` keeps it off
/// every other path on this host. It has no `Max-Age`, so the browser
/// drops it when its session ends; the daemon's own lifetime bounds it
/// either way.
///
/// ## Examples
///
/// ```gleam
/// // ui_http.set_cookie("abc")
/// ```
pub fn set_cookie(value: String) -> String {
  cookie_name <> "=" <> value <> "; HttpOnly; SameSite=Strict; Path=/ui"
}

/// Adds the headers every `/ui` response carries.
///
/// ## Examples
///
/// ```gleam
/// // ui_http.secured(response, "127.0.0.1:4000")
/// ```
pub fn secured(response: Response(body), host: String) -> Response(body) {
  response
  |> response.set_header(
    "content-security-policy",
    page.content_security_policy(host),
  )
  |> response.set_header("x-content-type-options", "nosniff")
  |> response.set_header("referrer-policy", "no-referrer")
  |> response.set_header("cache-control", "no-store")
}
