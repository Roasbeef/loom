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
import web_view/page

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
  assert ui_http.route(get("/ui/assets/web_client.css", []))
    == ui_http.Asset(ui_http.Stylesheet)
  assert ui_http.route(get("/ui/assets/web_client.mjs", []))
    == ui_http.Asset(ui_http.Client)
  assert ui_http.route(get("/ui/assets/favicon.svg", []))
    == ui_http.Asset(ui_http.Favicon)
  assert ui_http.route(get("/favicon.ico", [])) == ui_http.Unknown
  assert ui_http.route(get("/ui/assets/web_view.css", [])) == ui_http.Unknown
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

// The image route is a keyed path with a row's name and a place, and only a
// name and place of the right shape is routed at all.
pub fn an_image_is_a_keyed_get_with_a_named_row_and_a_place_test() {
  assert ui_http.route(get("/ui/p/k1/sessions/abc/image/7.0/0", []))
    == ui_http.Image("k1", "abc", "7.0", 0)
  assert ui_http.route(get("/ui/p/k1/sessions/abc/image/7.0-2/3", []))
    == ui_http.Image("k1", "abc", "7.0-2", 3)
  assert ui_http.route(
      request.new()
      |> request.set_method(http.Post)
      |> request.set_path("/ui/p/k1/sessions/abc/image/7.0/0"),
    )
    == ui_http.Unknown
}

pub fn a_name_or_place_of_the_wrong_shape_is_not_routed_test() {
  let at = fn(ref, place) {
    ui_http.route(get("/ui/p/k/sessions/s/image/" <> ref <> "/" <> place, []))
  }
  assert at("7.0", "-1") == ui_http.Unknown
  assert at("7.0", "x") == ui_http.Unknown
  assert at("7.0", "1.5") == ui_http.Unknown
  assert at("7.0", "") == ui_http.Unknown
  assert at("7.0", "256") == ui_http.Unknown
  assert at("7.0", "255") == ui_http.Image("k", "s", "7.0", 255)
  assert at("..", "0") == ui_http.Unknown
  assert at("a", "0") == ui_http.Unknown
  assert at("7.0%2F2", "0") == ui_http.Unknown
  assert at(string.repeat("1", 49), "0") == ui_http.Unknown
  assert at(string.repeat("1", 48), "0")
    == ui_http.Image("k", "s", string.repeat("1", 48), 0)
  assert ui_http.route(get("/ui/p/k/sessions/s/image/7.0", []))
    == ui_http.Unknown
  assert ui_http.route(get("/ui/p/k/sessions/s/image/7.0/0/x", []))
    == ui_http.Unknown
  assert ui_http.route(get("/ui/sessions/s/image/7.0/0", [])) == ui_http.Unknown
}

// --- the browser login (protocol-change/065, PR 8) --------------------------

fn post(path: String, headers: List(#(String, String))) {
  get(path, headers) |> request.set_method(http.Post)
}

// The login's two routes are the bookmark and the post to it, and nothing else
// under `/ui/l` is a route.
pub fn the_bookmark_is_a_get_and_the_resume_a_post_test() {
  assert ui_http.route(get("/ui/l/k1/home", [])) == ui_http.LoginPage("k1")
  assert ui_http.route(post("/ui/l/k1/home", [])) == ui_http.LoginResume("k1")
  assert ui_http.route(get("/ui/l/k1", [])) == ui_http.Unknown
  assert ui_http.route(get("/ui/l/k1/home/ws", [])) == ui_http.Unknown
  assert ui_http.route(get("/ui/l/home", [])) == ui_http.Unknown
  assert ui_http.route(post("/ui/home", [])) == ui_http.Unknown
  assert ui_http.route(post("/ui/l/k1/sessions/abc", [])) == ui_http.Unknown
  assert ui_http.route(get("/ui/assets/web_view_resume.js", []))
    == ui_http.Asset(ui_http.ResumeScript)
}

// The login cookie is read the way the page cookie is: every value, in the
// order the browser sent them, and no more than four, so a value another port
// planted under a longer path cannot shadow the real one and a request stuffed
// with cookies costs four chain checks at most.
pub fn the_login_cookie_is_read_in_order_and_bounded_test() {
  assert ui_http.login_cookies(get("/ui/l/k/home", [])) == []
  assert ui_http.login_cookies(
      get("/ui/l/k/home", [#("cookie", "loom_ui=x; loom_login=a; other=1")]),
    )
    == ["a"]
  assert ui_http.login_cookies(
      get("/ui/l/k/home", [#("cookie", "loom_login=planted; loom_login=real")]),
    )
    == ["planted", "real"]
  assert ui_http.login_cookies(
      get("/ui/l/k/home", [
        #(
          "cookie",
          "loom_login=a; loom_login=b; loom_login=c; loom_login=d; loom_login=e",
        ),
      ]),
    )
    == ["a", "b", "c", "d"]

  // The page cookie is not a login and a login is not a page cookie.
  assert ui_http.session_cookies(
      get("/ui/l/k/home", [#("cookie", "loom_login=a")]),
    )
    == []
  assert ui_http.login_cookies(get("/ui/p/k/home", [#("cookie", "loom_ui=a")]))
    == []
}

// The login cookie has the page cookie's attributes and one more: it outlives
// the browser, so it names its lifetime, which is the token's.
pub fn the_login_cookie_is_set_with_its_attributes_and_a_lifetime_test() {
  assert ui_http.set_login_cookie("loomb1:token", "k1", 2_592_000)
    == "loom_login=loomb1:token; HttpOnly; SameSite=Strict; Path=/ui/l/k1; Max-Age=2592000"

  // The page's own cookie keeps no lifetime.
  assert !string.contains(ui_http.set_cookie("abc", "k1"), "Max-Age")
}

// The resume is a post from this origin's own page: `same-origin` and nothing
// else, `none` included, since nobody types a post.
pub fn only_this_origins_own_page_may_post_the_resume_test() {
  let site = fn(value) {
    ui_http.same_origin_post(post("/ui/l/k/home", [#("sec-fetch-site", value)]))
  }
  assert site("same-origin")
  assert !site("none")
  assert !site("same-site")
  assert !site("cross-site")
  assert !ui_http.same_origin_post(post("/ui/l/k/home", []))
}

// The form is declared before it is read: a length no more than a kilobyte,
// the URL-encoded type, and no transfer encoding, whose body has no length to
// bound.
pub fn the_resume_form_is_declared_small_and_urlencoded_test() {
  let form = [#("content-type", "application/x-www-form-urlencoded")]
  let declared = fn(headers) {
    ui_http.form_declared(post("/ui/l/k/home", headers))
  }
  assert declared([#("content-length", "70"), ..form])
  assert declared([#("content-length", "1024"), ..form])
  assert declared([
    #("content-length", "70"),
    #("content-type", "Application/X-WWW-Form-Urlencoded"),
  ])
  assert !declared([#("content-length", "1025"), ..form])
  assert !declared([#("content-length", "-1"), ..form])
  assert !declared([#("content-length", "many"), ..form])
  assert !declared(form)
  assert !declared([
    #("content-length", "70"),
    #("transfer-encoding", "chunked"),
    ..form
  ])
  assert !declared([
    #("content-length", "70"),
    #("content-type", "text/plain"),
  ])
  assert !declared([
    #("content-length", "70"),
    #("content-type", "application/x-www-form-urlencoded; charset=utf-8"),
  ])
  assert !declared([#("content-length", "70")])
}

// The posted body is one field, `nonce`, of 64 lowercase hexadecimal digits.
pub fn the_posted_nonce_is_one_field_of_sixty_four_hex_digits_test() {
  let nonce = string.repeat("ab", 32)
  assert ui_http.posted_nonce(<<"nonce=":utf8, nonce:utf8>>) == Ok(nonce)
  assert ui_http.posted_nonce(<<"nonce=":utf8>>) == Error(Nil)
  assert ui_http.posted_nonce(<<"":utf8>>) == Error(Nil)
  assert ui_http.posted_nonce(<<"nonce=":utf8, "ab":utf8>>) == Error(Nil)
  assert ui_http.posted_nonce(<<"nonce=":utf8, nonce:utf8, "0":utf8>>)
    == Error(Nil)
  assert ui_http.posted_nonce(<<
      "nonce=":utf8,
      { string.uppercase(nonce) }:utf8,
    >>)
    == Error(Nil)
  assert ui_http.posted_nonce(<<"nonce=":utf8, nonce:utf8, "&x=1":utf8>>)
    == Error(Nil)
  assert ui_http.posted_nonce(<<"x=1&nonce=":utf8, nonce:utf8>>) == Error(Nil)
  assert ui_http.posted_nonce(<<"other=":utf8, nonce:utf8>>) == Error(Nil)
  assert ui_http.posted_nonce(<<
      "nonce=":utf8,
      nonce:utf8,
      "&nonce=":utf8,
      nonce:utf8,
    >>)
    == Error(Nil)
  assert ui_http.posted_nonce(<<0xff, 0xfe>>) == Error(Nil)
}

// The resume page, and only it, is served under a policy that lets a form submit
// to this origin; everything else in the policy is the same.
pub fn only_the_resume_page_may_submit_a_form_test() {
  let policy = fn(forms) {
    let secured =
      ui_http.secured_for(response.new(200), "127.0.0.1:4000", forms)
    let assert Ok(text) =
      response.get_header(secured, "content-security-policy")
      as "the policy is present"
    text
  }
  let own = policy(page.OwnForms)
  let none = policy(page.NoForms)
  assert string.contains(own, "form-action 'self'")
  assert string.contains(none, "form-action 'none'")
  assert string.replace(own, "form-action 'self'", "form-action 'none'") == none
  let ordinary = ui_http.secured(response.new(200), "127.0.0.1:4000")
  assert response.get_header(ordinary, "content-security-policy") == Ok(none)
}

// The admin page's three routes (protocol-change/065, the fifth pull request)
// are the home's with their own word: the exchange carries a ticket, the page and
// its socket sit under a page key, and every other shape is nothing.
pub fn the_admin_pages_routes_are_exact_test() {
  let with_ticket = fn(path) {
    get(path, []) |> request.set_query([#("ticket", "t1")])
  }
  assert ui_http.route(with_ticket("/ui/admin")) == ui_http.AdminExchange("t1")
  assert ui_http.route(get("/ui/admin", [])) == ui_http.Unknown
  assert ui_http.route(with_ticket("/ui/admin/x")) == ui_http.Unknown
  assert ui_http.route(with_ticket("/ui/admins")) == ui_http.Unknown
  assert ui_http.route(get("/ui/p/k1/admin", [])) == ui_http.AdminPage("k1")
  assert ui_http.route(
      get("/ui/p/k1/admin/ws", []) |> request.set_query([#("csrf-token", "n1")]),
    )
    == ui_http.AdminSocket("k1", Some("n1"))
  assert ui_http.route(get("/ui/p/k1/admin/ws", []))
    == ui_http.AdminSocket("k1", None)
  assert ui_http.route(get("/ui/p/k1/admin/x", [])) == ui_http.Unknown
  assert ui_http.route(get("/ui/p/k1/admin/ws/x", [])) == ui_http.Unknown
  assert ui_http.route(get("/ui/p/admin", [])) == ui_http.Unknown

  // Every route is a GET, and the home's stay as they were.
  assert ui_http.route(
      get("/ui/p/k1/admin", []) |> request.set_method(http.Post),
    )
    == ui_http.Unknown
  assert ui_http.route(with_ticket("/ui/home")) == ui_http.HomeExchange("t1")
  assert ui_http.route(get("/ui/p/k1/home", [])) == ui_http.HomePage("k1")
}

// --- the browser claim (protocol-change/065, PR 9) --------------------------

// The claim's two routes are the form and the post to it, and nothing under
// `/ui/claim` is a route.
pub fn the_claim_form_is_a_get_and_the_claim_a_post_test() {
  assert ui_http.route(get("/ui/claim", [])) == ui_http.ClaimPage
  assert ui_http.route(post("/ui/claim", [])) == ui_http.ClaimSubmit
  assert ui_http.route(get("/ui/claim/x", [])) == ui_http.Unknown
  assert ui_http.route(post("/ui/claim/x", [])) == ui_http.Unknown
  assert ui_http.route(request.set_method(get("/ui/claim", []), http.Put))
    == ui_http.Unknown
}

// The posted body is `token` and, optionally, `name`, each once and nothing else.
// An empty name is no name, a name is passed on as sent, and a form encoding is
// decoded.
pub fn the_posted_claim_is_a_token_and_an_optional_name_test() {
  assert ui_http.posted_claim(<<"token=loomclaim_00":utf8>>)
    == Ok(#("loomclaim_00", None))
  assert ui_http.posted_claim(<<"token=loomclaim_00&name=":utf8>>)
    == Ok(#("loomclaim_00", None))
  assert ui_http.posted_claim(<<"token=loomclaim_00&name=Alex":utf8>>)
    == Ok(#("loomclaim_00", Some("Alex")))
  assert ui_http.posted_claim(<<"name=Alex&token=loomclaim_00":utf8>>)
    == Ok(#("loomclaim_00", Some("Alex")))
  assert ui_http.posted_claim(<<"token=a%20b&name=Ana+Mar%C3%ADa":utf8>>)
    == Ok(#("a b", Some("Ana María")))
  assert ui_http.posted_claim(<<"name=Alex":utf8>>) == Error(Nil)
  assert ui_http.posted_claim(<<"":utf8>>) == Error(Nil)
  assert ui_http.posted_claim(<<"token=a&token=b":utf8>>) == Error(Nil)
  assert ui_http.posted_claim(<<"token=a&name=b&name=c":utf8>>) == Error(Nil)
  assert ui_http.posted_claim(<<"token=a&other=1":utf8>>) == Error(Nil)
  assert ui_http.posted_claim(<<"token=a&name=b&other=1":utf8>>) == Error(Nil)
  assert ui_http.posted_claim(<<0xff, 0xfe>>) == Error(Nil)
}
