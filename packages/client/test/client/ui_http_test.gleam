//// The web view's request checks as pure functions of a request: which host
//// names count as loopback, which fetch sites may exchange a ticket, which
//// origins may open the socket, and the headers every `/ui` response
//// carries (protocol-change/051).

import client/daemon/ui_http
import client/daemon/ui_origin
import client/daemon/ui_sessions
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import qcheck
import web_view/page

// The origin every loopback check in this file is made under: a browser on
// the daemon's own machine, exactly as protocol-change/051 admits it.
const loopback = ui_http.Loopback("127.0.0.1:4000")

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
      loopback,
    )
  }
  assert from("http://127.0.0.1:4000")
  assert !from("http://127.0.0.1:4001")
  assert !from("http://evil.example")
  assert !from("https://127.0.0.1:4000")
  assert !ui_http.origin_matches(get("/ui/sessions/s/ws", []), loopback)
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
  assert ui_http.route(get("/ui/assets/mermaid.html", []))
    == ui_http.Asset(ui_http.MermaidFrame)
  assert ui_http.route(get("/ui/assets/mermaid.js", []))
    == ui_http.Asset(ui_http.MermaidScript)
  assert ui_http.route(get("/favicon.ico", [])) == ui_http.Unknown
  assert ui_http.route(get("/ui/assets/web_view.css", [])) == ui_http.Unknown
  assert ui_http.route(get("/ui/assets/other.js", [])) == ui_http.Unknown

  // A `POST` to an exchange's own address is its confirmation's press, and
  // the path names which exchange; the ticket is in the body, not the route.
  let post = fn(path) {
    ui_http.route(get(path, []) |> request.set_method(http.Post))
  }
  assert post("/ui/sessions/abc")
    == ui_http.ConfirmedExchange(ui_sessions.SessionExchange("abc"))
  assert post("/ui/home") == ui_http.ConfirmedExchange(ui_sessions.HomeExchange)
  assert post("/ui/admin")
    == ui_http.ConfirmedExchange(ui_sessions.AdminExchange)
  assert post("/ui/p/k1/sessions/abc") == ui_http.Unknown
  assert post("/ui/sessions/abc/ws") == ui_http.Unknown
}

pub fn the_cookie_is_read_and_set_with_its_attributes_test() {
  assert ui_http.session_cookies(
      get("/ui/sessions/s", [#("cookie", "other=1; loom_ui=abc")]),
      loopback,
    )
    == ["abc"]
  assert ui_http.session_cookies(get("/ui/sessions/s", []), loopback) == []

  // Every value is kept, in the order the browser sent them, so a value
  // planted under a longer path cannot shadow the real one; the count is
  // bounded.
  assert ui_http.session_cookies(
      get("/ui/p/k/sessions/s", [
        #("cookie", "loom_ui=planted; loom_ui=real; other=2"),
      ]),
      loopback,
    )
    == ["planted", "real"]
  assert ui_http.session_cookies(
      get("/ui/p/k/sessions/s", [
        #("cookie", "loom_ui=a; loom_ui=b; loom_ui=c; loom_ui=d; loom_ui=e"),
      ]),
      loopback,
    )
    == ["a", "b", "c", "d"]
  let set = ui_http.set_cookie("abc", "k1", loopback)
  assert string.starts_with(set, "loom_ui=abc;")
  assert string.contains(set, "HttpOnly")
  assert string.contains(set, "SameSite=Strict")
  assert string.ends_with(set, "; Path=/ui/p/k1")
}

pub fn every_ui_response_carries_the_policy_test() {
  let secured = ui_http.secured(response.new(200), loopback)
  let assert Ok(policy) =
    response.get_header(secured, "content-security-policy")
    as "the policy is present"
  assert string.contains(policy, "default-src 'none'")
  assert string.contains(policy, "script-src 'self'")
  assert string.contains(policy, "frame-src 'self'")
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
  assert ui_http.route(post("/ui/l/home", [])) == ui_http.Unknown
  assert ui_http.route(post("/ui/l/k1/sessions/abc", [])) == ui_http.Unknown
  assert ui_http.route(get("/ui/assets/web_view_resume.js", []))
    == ui_http.Asset(ui_http.ResumeScript)
}

// The login cookie is read the way the page cookie is: every value, in the
// order the browser sent them, and no more than four, so a value another port
// planted under a longer path cannot shadow the real one and a request stuffed
// with cookies costs four chain checks at most.
pub fn the_login_cookie_is_read_in_order_and_bounded_test() {
  assert ui_http.login_cookies(get("/ui/l/k/home", []), loopback) == []
  assert ui_http.login_cookies(
      get("/ui/l/k/home", [#("cookie", "loom_ui=x; loom_login=a; other=1")]),
      loopback,
    )
    == ["a"]
  assert ui_http.login_cookies(
      get("/ui/l/k/home", [#("cookie", "loom_login=planted; loom_login=real")]),
      loopback,
    )
    == ["planted", "real"]
  assert ui_http.login_cookies(
      get("/ui/l/k/home", [
        #(
          "cookie",
          "loom_login=a; loom_login=b; loom_login=c; loom_login=d; loom_login=e",
        ),
      ]),
      loopback,
    )
    == ["a", "b", "c", "d"]

  // The page cookie is not a login and a login is not a page cookie.
  assert ui_http.session_cookies(
      get("/ui/l/k/home", [#("cookie", "loom_login=a")]),
      loopback,
    )
    == []
  assert ui_http.login_cookies(
      get("/ui/p/k/home", [#("cookie", "loom_ui=a")]),
      loopback,
    )
    == []
}

// The login cookie has the page cookie's attributes and one more: it outlives
// the browser, so it names its lifetime, which is the token's.
pub fn the_login_cookie_is_set_with_its_attributes_and_a_lifetime_test() {
  assert ui_http.set_login_cookie("loomb1:token", "k1", 2_592_000, loopback)
    == "loom_login=loomb1:token; HttpOnly; SameSite=Strict; Path=/ui/l/k1; Max-Age=2592000"

  // The page's own cookie keeps no lifetime.
  assert !string.contains(ui_http.set_cookie("abc", "k1", loopback), "Max-Age")
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

// The confirmation's press carries one field, `ticket`, of the shape every
// ticket is minted in, and is held to the nonce's rules field for field.
pub fn the_posted_ticket_is_one_field_of_sixty_four_hex_digits_test() {
  let ticket = string.repeat("0f", 32)
  assert ui_http.posted_ticket(<<"ticket=":utf8, ticket:utf8>>) == Ok(ticket)
  assert ui_http.posted_ticket(<<"ticket=":utf8>>) == Error(Nil)
  assert ui_http.posted_ticket(<<"ticket=":utf8, "0f":utf8>>) == Error(Nil)
  assert ui_http.posted_ticket(<<
      "ticket=":utf8,
      { string.uppercase(ticket) }:utf8,
    >>)
    == Error(Nil)
  assert ui_http.posted_ticket(<<"ticket=":utf8, ticket:utf8, "&x=1":utf8>>)
    == Error(Nil)
  assert ui_http.posted_ticket(<<"nonce=":utf8, ticket:utf8>>) == Error(Nil)
  assert ui_http.posted_nonce(<<"ticket=":utf8, ticket:utf8>>) == Error(Nil)
  assert ui_http.posted_ticket(<<0xff, 0xfe>>) == Error(Nil)
}

// The resume page, and only it, is served under a policy that lets a form submit
// to this origin; everything else in the policy is the same.
pub fn only_the_resume_page_may_submit_a_form_test() {
  let policy = fn(forms) {
    let secured = ui_http.secured_for(response.new(200), loopback, forms)
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
  let ordinary = ui_http.secured(response.new(200), loopback)
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

// A label drawn as numbers: each number picks a letter or digit, so a draw
// stays valid whatever length it shrinks to.
const label_alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"

fn label_of(draws: List(Int)) -> String {
  list.map(draws, fn(draw) {
    string.slice(label_alphabet, draw % string.length(label_alphabet), 1)
  })
  |> string.concat
}

// One to four labels of one to twelve characters, drawn on a fixed seed so
// the gate is deterministic and a failure arrives shrunk.
fn labels_generator() -> qcheck.Generator(List(String)) {
  let label =
    qcheck.generic_list(
      elements_from: qcheck.bounded_int(from: 0, to: 35),
      length_from: qcheck.bounded_int(from: 1, to: 12),
    )
    |> qcheck.map(label_of)
  qcheck.generic_list(
    elements_from: label,
    length_from: qcheck.bounded_int(from: 1, to: 4),
  )
}

fn names_config() -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_test_count(300)
  |> qcheck.with_seed(qcheck.seed(1051))
}

pub fn any_run_of_dns_labels_under_localhost_is_loopback_test() {
  qcheck.run(names_config(), labels_generator(), fn(labels) {
    let name = string.join(labels, ".") <> ".localhost"
    assert host_of(name) == Ok(name)
    assert host_of(name <> ":7440") == Ok(name <> ":7440")

    // The comparison is lowercased, and the host is returned as sent.
    let upper = string.uppercase(name) <> ":1"
    assert host_of(upper) == Ok(upper)
  })
}

pub fn a_malformed_name_under_localhost_is_refused_test() {
  qcheck.run(names_config(), labels_generator(), fn(labels) {
    let name = string.join(labels, ".")

    // A trailing dot leaves a name that no longer ends in `.localhost`, and
    // an empty label in front of it or between two labels is not a label.
    assert host_of(name <> ".localhost.") == Error(Nil)
    assert host_of("." <> name <> ".localhost") == Error(Nil)
    assert host_of(name <> "..localhost") == Error(Nil)
    assert host_of(name <> ".localhost.:80") == Error(Nil)

    // The name must end in `.localhost`, not merely contain it.
    assert host_of("localhost." <> name) == Error(Nil)
    assert host_of(name <> ".localhost." <> name) == Error(Nil)
    assert host_of(name <> ".localhostx") == Error(Nil)
    assert host_of(name <> "localhost") == Error(Nil)

    // Characters a DNS label does not hold.
    assert host_of(name <> "_x.localhost") == Error(Nil)
    assert host_of(name <> " x.localhost") == Error(Nil)
    assert host_of(name <> "@evil.example.localhost") == Error(Nil)
    assert host_of(name <> "\u{e9}.localhost") == Error(Nil)

    // Lowercasing folds U+212A (the Kelvin sign) to `k`, so a name that is
    // ASCII only after folding must still be refused.
    assert host_of(name <> ".localhost") == Ok(name <> ".localhost")
    assert host_of(name <> "\u{212A}.localhost") == Error(Nil)
    assert host_of("\u{212A}.localhost") == Error(Nil)
  })
}

pub fn the_localhost_suffix_shapes_are_accepted_and_refused_test() {
  assert host_of("loom.localhost:7440") == Ok("loom.localhost:7440")
  assert host_of("Loom.LOCALHOST") == Ok("Loom.LOCALHOST")
  assert host_of("a.b.c.localhost:1") == Ok("a.b.c.localhost:1")
  assert host_of("xn--e1afmkfd.localhost") == Ok("xn--e1afmkfd.localhost")
  assert host_of("my-app.localhost") == Ok("my-app.localhost")

  // The bare suffix has no label in front of it.
  assert host_of(".localhost") == Error(Nil)
  assert host_of(".localhost:80") == Error(Nil)
  assert host_of("a..localhost") == Error(Nil)

  // The shapes the issue names, and hyphens at a label's ends.
  assert host_of("localhost.evil.com") == Error(Nil)
  assert host_of("evil.com.localhost.") == Error(Nil)
  assert host_of("-a.localhost") == Error(Nil)
  assert host_of("a-.localhost") == Error(Nil)

  // A port still has to be a port.
  assert host_of("loom.localhost:") == Error(Nil)
  assert host_of("loom.localhost:80:81") == Error(Nil)
  assert host_of("loom.localhost:port") == Error(Nil)
  assert host_of("loom.localhost:123456") == Error(Nil)

  // A label is at most 63 characters and a name at most 253.
  let longest = string.repeat("a", 63)
  assert host_of(longest <> ".localhost") == Ok(longest <> ".localhost")
  assert host_of(string.repeat("a", 64) <> ".localhost") == Error(Nil)
  let long_name = string.repeat(string.repeat("a", 60) <> ".", 5) <> "localhost"
  assert host_of(long_name) == Error(Nil)
}

pub fn a_localhost_name_is_a_loopback_page_origin_with_its_own_socket_origin_test() {
  let socket = fn(sent) {
    get("/ui/p/k/sessions/s/ws", [
      #("host", "loom.localhost:7440"),
      #("origin", sent),
    ])
  }
  let request = socket("http://loom.localhost:7440")
  let assert Ok(origin) = ui_http.page_origin(request, [])
  assert origin == ui_http.Loopback("loom.localhost:7440")
  assert ui_http.address(origin) == "http://loom.localhost:7440"
  assert ui_http.socket_origin(origin) == "ws://loom.localhost:7440"
  assert ui_http.session_cookie_name(origin) == "loom_ui"
  assert ui_http.origin_matches(request, origin)

  // The socket accepts the matching origin and nothing else: not the same
  // name on another port, not another name, not a lookalike.
  assert !ui_http.origin_matches(socket("http://loom.localhost:7441"), origin)
  assert !ui_http.origin_matches(socket("http://other.localhost:7440"), origin)
  assert !ui_http.origin_matches(socket("https://loom.localhost:7440"), origin)
  assert !ui_http.origin_matches(
    socket("http://loom.localhost.evil.example:7440"),
    origin,
  )
}

pub fn the_root_is_a_route_of_its_own_and_only_for_a_get_test() {
  assert ui_http.route(get("/", [])) == ui_http.Root
  assert ui_http.route(request.set_method(get("/", []), http.Post))
    == ui_http.Unknown
  assert ui_http.route(get("/elsewhere", [])) == ui_http.Unknown
  assert ui_http.route(get("/ui/assets/" <> page.root_asset, []))
    == ui_http.Asset(ui_http.RootScript)
}

pub fn the_sign_in_command_follows_the_page_origin_test() {
  assert ui_http.sign_in_command(loopback) == "loom ui"
  let assert Ok(listed) = ui_origin.parse("https://loom.test.example:8443")
  assert ui_http.sign_in_command(ui_http.Remote(listed)) == "loom ui --device"
}

const relayed_session = "0198c0de-0000-7000-8000-000000000001"

// The relayed session page and its socket (protocol-change/094): both routes
// carry the page key, a configured orchestrator's key and a canonical session
// identity, and the socket takes the nonce from the query as every socket does.
pub fn the_relayed_routes_are_exact_test() {
  let page = "/ui/p/k1/orchestrators/box/sessions/" <> relayed_session

  assert ui_http.route(get(page, []))
    == ui_http.RelayedPage("k1", "box", relayed_session)
  assert ui_http.route(
      get(page <> "/ws", []) |> request.set_query([#("csrf-token", "n1")]),
    )
    == ui_http.RelayedSocket("k1", "box", relayed_session, Some("n1"))
  assert ui_http.route(get(page <> "/ws", []))
    == ui_http.RelayedSocket("k1", "box", relayed_session, None)

  // Only a get, and only these shapes.
  let posted =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path(page)
  assert ui_http.route(posted) == ui_http.Unknown
  assert ui_http.route(get(page <> "/image/r/0", [])) == ui_http.Unknown
  assert ui_http.route(get(page <> "/extra", [])) == ui_http.Unknown
  assert ui_http.route(get("/ui/p/k1/orchestrators/box", [])) == ui_http.Unknown
  assert ui_http.route(
      get("/ui/p/k1/peers/box/sessions/" <> relayed_session, []),
    )
    == ui_http.Unknown
}

pub fn a_relayed_route_parameter_outside_its_grammar_is_unknown_test() {
  let at = fn(name, session) {
    ui_http.route(
      get("/ui/p/k1/orchestrators/" <> name <> "/sessions/" <> session, []),
    )
  }

  assert at("Box", relayed_session) == ui_http.Unknown
  assert at("9box", relayed_session) == ui_http.Unknown
  assert at("a.b", relayed_session) == ui_http.Unknown
  assert at("a%2Fb", relayed_session) == ui_http.Unknown
  assert at("box", "not-a-session") == ui_http.Unknown
  assert at("box", string.uppercase(relayed_session)) == ui_http.Unknown
  assert at("box", relayed_session <> "0") == ui_http.Unknown
  assert at("box", "..") == ui_http.Unknown
}

// Whatever the text, a route is made only when the name is a lower-case key of
// at most 32 characters and the identity is canonical, so no path segment that is
// not one reaches a handler.
pub fn only_a_key_and_a_canonical_identity_make_a_relayed_target_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(300)
    |> qcheck.with_seed(qcheck.seed(20_261_021))

  qcheck.run(config, qcheck.string(), fn(text) {
    assert !ui_http.relayed_target(text, relayed_session)
      || {
        string.length(text) >= 1
        && string.length(text) <= 32
        && text == string.lowercase(text)
        && !string.contains(text, "/")
        && !string.contains(text, ".")
      }
    assert !ui_http.relayed_target("box", text)
      || text == relayed_session
      || string.length(text) == 36
  })
  assert ui_http.relayed_target("box", relayed_session)
  assert ui_http.relayed_target("box-2_x", relayed_session)
}
