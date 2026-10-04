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
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import web_view/image
import web_view/page

/// The cookie that carries a UI session.
pub const cookie_name = "loom_ui"

/// One `/ui` request, by route.
///
/// A page and its socket live under the page key its UI session was given
/// at the exchange (`/ui/p/<key>`), which is also the path its cookie is
/// scoped to (protocol-change/051, the operator addendum). The exchange and
/// the assets carry no key.
pub type Route {
  /// `GET /ui/p/<key>/sessions/<id>`: the page.
  Page(key: String, session_id: String)

  /// `GET /ui/sessions/<id>?ticket=<ticket>`: the ticket exchange.
  Exchange(session_id: String, ticket: String)

  /// `GET /ui/p/<key>/sessions/<id>/ws`: the component's socket. `nonce`
  /// is the socket URL's `csrf-token`, the page nonce the tab kept.
  Socket(key: String, session_id: String, nonce: Option(String))

  /// `GET /ui/p/<key>/sessions/<id>/image/<ref>/<position>`: one image of the
  /// page's transcript. `ref` is a row's name and `position` an image's place
  /// in the row (protocol-change/051, the addendum on images). Neither is
  /// trusted: the page answers for a name and place it drew and no other.
  Image(key: String, session_id: String, ref: String, position: Int)

  /// `GET /ui/home?ticket=<ticket>`: the home page's ticket exchange
  /// (protocol-change/065).
  HomeExchange(ticket: String)

  /// `GET /ui/p/<key>/home`: the home page.
  HomePage(key: String)

  /// `GET /ui/p/<key>/home/ws`: the home component's socket, with the nonce
  /// as the socket URL's `csrf-token`.
  HomeSocket(key: String, nonce: Option(String))

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

  /// The session page's script.
  PageScript

  /// The client components' bundle.
  Client
}

/// The most images one row may carry that the route will ask the page for.
/// A person's message and a tool's result hold a handful; the bound keeps a
/// request from naming a position no row could have.
pub const max_position = 256

/// Routes a `/ui` request; every route is a `GET`. The session ID is returned as the path gave it;
/// the caller parses it as a canonical ID before using it. The home's three
/// routes name no session (protocol-change/065).
///
/// ## Examples
///
/// ```gleam
/// // ui_http.route(request) == ui_http.Socket("0198...")
/// ```
pub fn route(request: Request(body)) -> Route {
  case request.method, request.path_segments(request) {
    // Only the exchange lives at the unkeyed session path. A page asked for
    // there has no key, so no cookie scoped to a key reaches it.
    http.Get, ["ui", "sessions", id] ->
      case query(request, "ticket") {
        Some(ticket) -> Exchange(id, ticket)
        None -> Unknown
      }
    http.Get, ["ui", "p", key, "sessions", id] -> Page(key, id)
    http.Get, ["ui", "p", key, "sessions", id, "ws"] ->
      Socket(key, id, query(request, "csrf-token"))
    http.Get, ["ui", "p", key, "sessions", id, "image", ref, position] ->
      case image.plausible_ref(ref), int.parse(position) {
        True, Ok(place) if place >= 0 && place < max_position ->
          Image(key, id, ref, place)
        _, _ -> Unknown
      }
    http.Get, ["ui", "home"] ->
      case query(request, "ticket") {
        Some(ticket) -> HomeExchange(ticket)
        None -> Unknown
      }
    http.Get, ["ui", "p", key, "home"] -> HomePage(key)
    http.Get, ["ui", "p", key, "home", "ws"] ->
      HomeSocket(key, query(request, "csrf-token"))
    http.Get, ["ui", "assets", name] ->
      case name {
        _ if name == page.runtime_asset -> Asset(Runtime)
        _ if name == page.stylesheet_asset -> Asset(Stylesheet)
        _ if name == page.enter_asset -> Asset(EnterScript)
        _ if name == page.page_asset -> Asset(PageScript)
        _ if name == page.client_asset -> Asset(Client)
        _ -> Unknown
      }
    _, _ -> Unknown
  }
}

fn query(request: Request(body), name: String) -> Option(String) {
  request.get_query(request)
  |> result.unwrap([])
  |> list.key_find(name)
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
  navigation_allowed(request)
}

/// Whether a navigation to a keyed page may proceed: `Sec-Fetch-Site` is
/// `same-origin`, the exchange page's move or a reload, or `none`, a link
/// or bookmark opened from outside a page. A missing header, `same-site`
/// (another loopback port) or `cross-site` is refused, so no other page can
/// put the keyed page in front of the person.
///
/// The image route asks the same question. The page's own `<img>` is
/// `same-origin`, and an image opened on its own is `none`; another page's
/// `<img src>` aimed at the daemon is `same-site` or `cross-site` and is
/// refused, so another origin cannot have the browser fetch the person's
/// images on its behalf (and the cookie, which is `SameSite=Strict`, would
/// not go with it in any case).
///
/// ## Examples
///
/// ```gleam
/// // ui_http.navigation_allowed(request)
/// ```
pub fn navigation_allowed(request: Request(body)) -> Bool {
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

/// The most `loom_ui` values a request is searched for. A browser sends one
/// per cookie whose path covers the request, which is one for a page opened
/// normally; the bound keeps a request stuffed with planted values from
/// costing a UI-session lookup each.
pub const max_session_cookies = 4

/// Every `loom_ui` value the request carries, in the order the browser sent
/// them, up to `max_session_cookies`. The caller accepts the one whose UI
/// session is live under the page's key, so a value planted under a longer
/// path, which the browser sends first, cannot shadow the real one.
///
/// ## Examples
///
/// ```gleam
/// // ui_http.session_cookies(request) == ["planted", "real"]
/// ```
pub fn session_cookies(request: Request(body)) -> List(String) {
  request.get_cookies(request)
  |> list.filter_map(fn(pair) {
    case pair.0 == cookie_name {
      True -> Ok(pair.1)
      False -> Error(Nil)
    }
  })
  |> list.take(max_session_cookies)
}

/// The `Set-Cookie` value for a new UI session whose page key is `key`.
///
/// `HttpOnly` keeps it from every script, `SameSite=Strict` keeps a
/// cross-site navigation from carrying it, and `Path=/ui/p/<key>` keeps it
/// off every path that does not name the page key, on this port and on
/// every other port of the host, since browsers do not scope a cookie by
/// port. It has no `Max-Age`, so the browser drops it when its session
/// ends; the daemon's own lifetime bounds it either way.
///
/// ## Examples
///
/// ```gleam
/// // ui_http.set_cookie("abc", "key")
/// ```
pub fn set_cookie(value: String, key: String) -> String {
  cookie_name
  <> "="
  <> value
  <> "; HttpOnly; SameSite=Strict; Path="
  <> page.keyed_prefix(key)
}

/// Adds the view's headers to a refusal made before the host was trusted.
///
/// The policy names no socket origin, since the request's `Host` is exactly
/// what was refused, and allows nothing to load at all.
///
/// ## Examples
///
/// ```gleam
/// // ui_http.refused(response)
/// ```
pub fn refused(response: Response(body)) -> Response(body) {
  response
  |> response.set_header(
    "content-security-policy",
    "default-src 'none'; base-uri 'none'; form-action 'none'; "
      <> "frame-ancestors 'none'",
  )
  |> response.set_header("x-content-type-options", "nosniff")
  |> response.set_header("referrer-policy", "no-referrer")
  |> response.set_header("cache-control", "no-store")
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
