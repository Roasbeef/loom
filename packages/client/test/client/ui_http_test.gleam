//// The web view's request checks as pure functions of a request: which host
//// names count as loopback, which fetch sites may exchange a ticket, which
//// origins may open the socket, and the headers every `/ui` response
//// carries (protocol-change/051).

import client/daemon/ui_http
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn get(path: String, headers: List(#(String, String))) {
  let base =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path(path)
  list.fold(headers, base, fn(request, header) {
    request.set_header(request, header.0, header.1)
  })
}

fn host_of(value: String) {
  ui_http.loopback_host(get("/ui/sessions/s", [#("host", value)]))
}

pub fn only_loopback_names_pass_the_host_check_test() {
  assert host_of("127.0.0.1:4000") == Ok("127.0.0.1:4000")
  assert host_of("[::1]:4000") == Ok("[::1]:4000")
  assert host_of("localhost:52100") == Ok("localhost:52100")
  assert host_of("LOCALHOST:1") == Ok("LOCALHOST:1")
  assert host_of("127.0.0.1") == Ok("127.0.0.1")

  // A rebinding attack presents its own name; lookalikes and garbage in the
  // port are refused too.
  assert host_of("evil.example:4000") == Error(Nil)
  assert host_of("127.0.0.1.evil.example") == Error(Nil)
  assert host_of("localhost.evil.example:4000") == Error(Nil)
  assert host_of("127.0.0.1:4000:1") == Error(Nil)
  assert host_of("127.0.0.1:") == Error(Nil)
  assert host_of("[::1]evil") == Error(Nil)
  assert ui_http.loopback_host(get("/ui/sessions/s", [])) == Error(Nil)
}

pub fn only_a_first_party_navigation_may_open_a_keyed_page_test() {
  let site = fn(value) {
    ui_http.navigation_allowed(
      get("/ui/p/k/sessions/s", [#("sec-fetch-site", value)]),
    )
  }
  assert site("none")
  assert site("same-origin")
  assert !site("same-site")
  assert !site("cross-site")
  assert !ui_http.navigation_allowed(get("/ui/p/k/sessions/s", []))
}

pub fn only_a_first_party_navigation_may_exchange_a_ticket_test() {
  let site = fn(value) {
    ui_http.exchange_allowed(
      get("/ui/sessions/s", [#("sec-fetch-site", value)]),
    )
  }
  assert site("none")
  assert site("same-origin")
  assert !site("same-site")
  assert !site("cross-site")
  assert !ui_http.exchange_allowed(get("/ui/sessions/s", []))
}

pub fn the_socket_needs_this_origin_test() {
  let from = fn(origin) {
    ui_http.origin_matches(
      get("/ui/sessions/s/ws", [#("origin", origin)]),
      "127.0.0.1:4000",
    )
  }
  assert from("http://127.0.0.1:4000")
  assert !from("http://127.0.0.1:4001")
  assert !from("http://evil.example")
  assert !from("https://127.0.0.1:4000")
  assert !ui_http.origin_matches(get("/ui/sessions/s/ws", []), "127.0.0.1:4000")
}

// Only the exchange lives at the unkeyed session path; the page and its
// socket live under the page key, which the cookie's path is scoped to
// (protocol-change/051, the operator addendum).
pub fn routes_are_gets_under_ui_test() {
  assert ui_http.route(get("/ui/sessions/abc", [])) == ui_http.Unknown
  assert ui_http.route(get("/ui/sessions/abc/ws", [])) == ui_http.Unknown
  assert ui_http.route(
      get("/ui/sessions/abc", []) |> request.set_query([#("ticket", "t")]),
    )
    == ui_http.Exchange("abc", "t")
  assert ui_http.route(get("/ui/p/k1/sessions/abc", []))
    == ui_http.Page("k1", "abc")
  assert ui_http.route(get("/ui/p/k1/sessions/abc/ws", []))
    == ui_http.Socket("k1", "abc", None)
  assert ui_http.route(
      get("/ui/p/k1/sessions/abc/ws", [])
      |> request.set_query([#("csrf-token", "n1")]),
    )
    == ui_http.Socket("k1", "abc", Some("n1"))
  assert ui_http.route(get("/ui/assets/web_view_enter.js", []))
    == ui_http.Asset(ui_http.EnterScript)
  assert ui_http.route(get("/ui/assets/web_view_page.js", []))
    == ui_http.Asset(ui_http.PageScript)
  assert ui_http.route(get("/ui/assets/web_view.css", []))
    == ui_http.Asset(ui_http.Stylesheet)
  assert ui_http.route(get("/ui/assets/other.js", [])) == ui_http.Unknown
  assert ui_http.route(
      get("/ui/sessions/abc", []) |> request.set_method(http.Post),
    )
    == ui_http.Unknown
}

pub fn the_cookie_is_read_and_set_with_its_attributes_test() {
  assert ui_http.session_cookies(
      get("/ui/sessions/s", [#("cookie", "other=1; loom_ui=abc")]),
    )
    == ["abc"]
  assert ui_http.session_cookies(get("/ui/sessions/s", [])) == []

  // Every value is kept, in the order the browser sent them, so a value
  // planted under a longer path cannot shadow the real one; the count is
  // bounded.
  assert ui_http.session_cookies(
      get("/ui/p/k/sessions/s", [
        #("cookie", "loom_ui=planted; loom_ui=real; other=2"),
      ]),
    )
    == ["planted", "real"]
  assert ui_http.session_cookies(
      get("/ui/p/k/sessions/s", [
        #("cookie", "loom_ui=a; loom_ui=b; loom_ui=c; loom_ui=d; loom_ui=e"),
      ]),
    )
    == ["a", "b", "c", "d"]
  let set = ui_http.set_cookie("abc", "k1")
  assert string.starts_with(set, "loom_ui=abc;")
  assert string.contains(set, "HttpOnly")
  assert string.contains(set, "SameSite=Strict")
  assert string.ends_with(set, "; Path=/ui/p/k1")
}

pub fn every_ui_response_carries_the_policy_test() {
  let secured = ui_http.secured(response.new(200), "127.0.0.1:4000")
  let assert Ok(policy) =
    response.get_header(secured, "content-security-policy")
    as "the policy is present"
  assert string.contains(policy, "default-src 'none'")
  assert string.contains(policy, "script-src 'self'")
  assert string.contains(policy, "connect-src 'self' ws://127.0.0.1:4000")
  assert string.contains(policy, "base-uri 'none'")
  assert string.contains(policy, "form-action 'none'")
  assert string.contains(policy, "frame-ancestors 'none'")
  assert response.get_header(secured, "x-content-type-options") == Ok("nosniff")
  assert response.get_header(secured, "referrer-policy") == Ok("no-referrer")
  assert response.get_header(secured, "cache-control") == Ok("no-store")
}
