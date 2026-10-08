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

import core/ids
import gleam/bit_array
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import web_view/image
import web_view/page

/// The cookie that carries a UI session.
pub const cookie_name = "loom_ui"

/// The cookie that carries a browser login (protocol-change/065).
pub const login_cookie_name = "loom_login"

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

  /// One bounded text page of an immutable result, behind its page grant.
  ResultPage(key: String, session_id: String, ref: ids.EntryId, index: Int)

  /// An explicit download of that result's complete stored JSON record.
  ResultDownload(key: String, session_id: String, ref: ids.EntryId)

  /// `GET /ui/home?ticket=<ticket>`: the home page's ticket exchange
  /// (protocol-change/065).
  HomeExchange(ticket: String)

  /// `GET /ui/p/<key>/home`: the home page.
  HomePage(key: String)

  /// `GET /ui/p/<key>/home/ws`: the home component's socket, with the nonce
  /// as the socket URL's `csrf-token`.
  HomeSocket(key: String, nonce: Option(String))

  /// `GET /ui/l/<key>/home`: the fixed resume page, which posts the login nonce
  /// the browser kept to the same address.
  LoginPage(key: String)

  /// `POST /ui/l/<key>/home`: a browser login asks for a home page.
  LoginResume(key: String)

  /// `GET /ui/claim`: the fixed claim form.
  ClaimPage

  /// `POST /ui/claim`: the browser claim (protocol-change/065, PR 9).
  ClaimSubmit

  /// `GET /ui/admin?ticket=<ticket>`: the admin page's ticket exchange
  /// (protocol-change/065, the fifth pull request).
  AdminExchange(ticket: String)

  /// `GET /ui/p/<key>/admin`: the admin page.
  AdminPage(key: String)

  /// `GET /ui/p/<key>/admin/ws`: the admin component's socket, with the nonce
  /// as the socket URL's `csrf-token`.
  AdminSocket(key: String, nonce: Option(String))

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

  /// The resume page's script, which posts the login nonce.
  ResumeScript

  /// The client components' bundle.
  Client

  /// The tab icon, an SVG.
  Favicon
}

/// The most images one row may carry that the route will ask the page for.
/// A person's message and a tool's result hold a handful; the bound keeps a
/// request from naming a position no row could have.
pub const max_position = 256

/// Routes a `/ui` request; every route is a `GET` except the login's resume and
/// the claim's submission, which are `POST`s. The session ID is returned as the path gave it; the caller
/// parses it as a canonical ID before using it. The home's three routes and the
/// admin page's three name no session (protocol-change/065).
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
    http.Get, ["ui", "p", key, "sessions", id, "result", ref, "page", index] ->
      case ids.parse_entry_id(ref), int.parse(index) {
        Ok(ref), Ok(index) if index >= 0 && index < 2098 ->
          ResultPage(key, id, ref, index)
        _, _ -> Unknown
      }
    http.Get, ["ui", "p", key, "sessions", id, "result", ref, "download"] ->
      case ids.parse_entry_id(ref) {
        Ok(ref) -> ResultDownload(key, id, ref)
        Error(_) -> Unknown
      }
    http.Get, ["ui", "home"] ->
      case query(request, "ticket") {
        Some(ticket) -> HomeExchange(ticket)
        None -> Unknown
      }
    http.Get, ["ui", "p", key, "home"] -> HomePage(key)
    http.Get, ["ui", "p", key, "home", "ws"] ->
      HomeSocket(key, query(request, "csrf-token"))
    http.Get, ["ui", "l", key, "home"] -> LoginPage(key)
    http.Post, ["ui", "l", key, "home"] -> LoginResume(key)
    http.Get, ["ui", "claim"] -> ClaimPage
    http.Post, ["ui", "claim"] -> ClaimSubmit

    http.Get, ["ui", "admin"] ->
      case query(request, "ticket") {
        Some(ticket) -> AdminExchange(ticket)
        None -> Unknown
      }
    http.Get, ["ui", "p", key, "admin"] -> AdminPage(key)
    http.Get, ["ui", "p", key, "admin", "ws"] ->
      AdminSocket(key, query(request, "csrf-token"))
    http.Get, ["ui", "assets", name] ->
      case name {
        _ if name == page.runtime_asset -> Asset(Runtime)
        _ if name == page.stylesheet_asset -> Asset(Stylesheet)
        _ if name == page.enter_asset -> Asset(EnterScript)
        _ if name == page.page_asset -> Asset(PageScript)
        _ if name == page.resume_asset -> Asset(ResumeScript)
        _ if name == page.client_asset -> Asset(Client)
        _ if name == page.favicon_asset -> Asset(Favicon)
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

/// Whether a state-changing request came from this origin's own page:
/// `Sec-Fetch-Site` is `same-origin` and nothing else. The login's resume is a
/// `POST` from the resume page, which is this origin's, so a link another page
/// followed, a form another page posted and a request with no such header (a
/// program that is not a browser, or one that cannot be trusted to say) are all
/// refused, `none` included: nobody types a `POST`.
///
/// ## Examples
///
/// ```gleam
/// // ui_http.same_origin_post(request)
/// ```
pub fn same_origin_post(request: Request(body)) -> Bool {
  case request.get_header(request, "sec-fetch-site") {
    Ok("same-origin") -> True
    Ok(_) | Error(Nil) -> False
  }
}

/// The most bytes the resume form's body may hold.
pub const max_form_bytes = 1024

/// Whether the request declares a body the resume may read: a `Content-Length`
/// of at most `max_form_bytes`, no `Transfer-Encoding` (a chunked body has no
/// length to bound before it is read), and the URL-encoded form type a form
/// posts. The caller reads the body only after this holds, so an oversized or
/// unbounded one is refused unread.
///
/// ## Examples
///
/// ```gleam
/// // ui_http.form_declared(request)
/// ```
pub fn form_declared(request: Request(body)) -> Bool {
  let length = case request.get_header(request, "content-length") {
    Ok(text) -> int.parse(text) |> result.unwrap(max_form_bytes + 1)
    Error(Nil) -> max_form_bytes + 1
  }
  let chunked = result.is_ok(request.get_header(request, "transfer-encoding"))
  let kind = case request.get_header(request, "content-type") {
    Ok(text) -> string.lowercase(text) == "application/x-www-form-urlencoded"
    Error(Nil) -> False
  }
  length >= 0 && length <= max_form_bytes && !chunked && kind
}

/// The login nonce a resume form posted: a body of exactly one field, `nonce`,
/// whose value is 64 lowercase hexadecimal digits. Anything else, a second
/// field included, is not a resume.
///
/// ## Examples
///
/// ```gleam
/// // ui_http.posted_nonce(<<"nonce=00...">>)
/// ```
pub fn posted_nonce(body: BitArray) -> Result(String, Nil) {
  use text <- result.try(bit_array.to_string(body))
  use fields <- result.try(uri.parse_query(text))
  case fields {
    [#("nonce", value)] ->
      case string.byte_size(value) == 64 && lowercase_hex(value) {
        True -> Ok(value)
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn lowercase_hex(value: String) -> Bool {
  list.all(string.to_graphemes(value), fn(digit) {
    string.contains("0123456789abcdef", digit)
  })
}

/// The claim form's fields, from the body it posted: `token`, and optionally
/// `name`, each at most once and no other field. An empty `name` is no name, so
/// the claim keeps the one the inviter chose. The token is returned as sent, for
/// the caller to check the shape of before anything is looked up, and the name
/// is returned as sent, for the catalogue's rule to judge.
///
/// ## Examples
///
/// ```gleam
/// assert ui_http.posted_claim(<<"token=loomclaim_00&name=Alex">>)
///   == Ok(#("loomclaim_00", Some("Alex")))
/// ```
pub fn posted_claim(body: BitArray) -> Result(#(String, Option(String)), Nil) {
  use text <- result.try(bit_array.to_string(body))
  use fields <- result.try(uri.parse_query(text))
  case list.sort(fields, fn(a, b) { string.compare(a.0, b.0) }) {
    [#("name", name), #("token", token)] -> Ok(#(token, named(name)))
    [#("token", token)] -> Ok(#(token, None))
    _ -> Error(Nil)
  }
}

fn named(name: String) -> Option(String) {
  case name {
    "" -> None
    given -> Some(given)
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

/// The most `loom_login` values a request is tried with. A browser sends one for
/// every login cookie whose path covers the request, which is one for a login
/// set normally, and sends a value planted under a longer path first. Four is
/// enough to pass over a few planted values and still reach the real one, and
/// the bound keeps a request stuffed with cookies from costing a chain
/// verification each.
pub const max_login_cookies = 4

/// Every `loom_login` value the request carries, in the order the browser sent
/// them, up to `max_login_cookies`. The caller opens each in turn and takes the
/// first that verifies and holds for the request.
///
/// ## Examples
///
/// ```gleam
/// // ui_http.login_cookies(request) == ["planted", "real"]
/// ```
pub fn login_cookies(request: Request(body)) -> List(String) {
  request.get_cookies(request)
  |> list.filter_map(fn(pair) {
    case pair.0 == login_cookie_name {
      True -> Ok(pair.1)
      False -> Error(Nil)
    }
  })
  |> list.take(max_login_cookies)
}

/// The `Set-Cookie` value for a browser login whose login key is `key`, with
/// the token `value`, ending `max_age` seconds from now.
///
/// It has the page cookie's attributes: `HttpOnly` keeps it from every script,
/// `SameSite=Strict` keeps a cross-site navigation from carrying it, and
/// `Path=/ui/l/<key>` keeps it off every path that does not name the login key,
/// on this port and on every other, since browsers do not scope a cookie by
/// port. It also has a `Max-Age`, the page cookie's one difference: the login
/// is the cookie that outlives the browser, and it ends when its token's
/// expiry does, so the browser drops it when the token would stop verifying.
///
/// ## Examples
///
/// ```gleam
/// // ui_http.set_login_cookie(token, key, 2_592_000)
/// ```
pub fn set_login_cookie(value: String, key: String, max_age: Int) -> String {
  login_cookie_name
  <> "="
  <> value
  <> "; HttpOnly; SameSite=Strict; Path="
  <> page.login_prefix(key)
  <> "; Max-Age="
  <> int.to_string(max_age)
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
  secured_for(response, host, page.NoForms)
}

/// `secured` for a document that holds a form, whose policy lets that form
/// submit to this origin and nowhere else. The resume page is the one such
/// document, and nothing else in the policy widens for it.
///
/// ## Examples
///
/// ```gleam
/// // ui_http.secured_for(response, "127.0.0.1:4000", page.OwnForms)
/// ```
pub fn secured_for(
  response: Response(body),
  host: String,
  forms: page.Forms,
) -> Response(body) {
  response
  |> response.set_header(
    "content-security-policy",
    page.content_security_policy_for(host, forms),
  )
  |> response.set_header("x-content-type-options", "nosniff")
  |> response.set_header("referrer-policy", "no-referrer")
  |> response.set_header("cache-control", "no-store")
}
