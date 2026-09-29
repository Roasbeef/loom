//// The web view's routes on a real daemon listener (protocol-change/051 and
//// its operator addendum): without `--ui` none of them exist; with it, a
//// ticket from `ui.link` is exchanged once for a cookie scoped to a page
//// key and a nonce the tab keeps, and every request is checked for its
//// host, its origin or fetch site, its cookie, its key, its nonce and the
//// credential behind it, and carries the view's security headers. The
//// page's socket reaches the upgrade only after every check, with the
//// membership role capped by the page's ceiling and by Operator.
////
//// The session assembly is inert, as in `daemon_server_test`: these tests
//// are about routing and authorization. The upgrade is a stub that answers
//// with the role the router handed it, since the Lustre transport behind it
//// is exercised by the relay, component and operator page tests.

import broker/token
import client/daemon/domain as domain_service
import client/daemon/limits
import client/daemon/manager
import client/daemon/root
import client/daemon/server
import client/daemon/ui_assets
import client/daemon/ui_sessions
import client/daemon/ui_socket
import client/daemon_server_test
import client/gateway
import core/clock
import core/ids
import core/json
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request as req
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import mist
import simplifile
import storage/access
import storage/catalogue
import support/addresses
import support/internal/ffi_daemon_socket
import support/internal/ffi_ws
import web_view/ending
import web_view/page
import web_view/sessions
import weft
import weft/poll

// What the page's upgrade does: answer with the role the router handed it, or
// be the daemon's own page socket over a gateway that is not running.
type Upgrade {
  Stubbed
  Real

  /// The upgrade asks the daemon for a ticket to open the session a header
  /// names, as an operator's page does when its sidebar row is pressed, and
  /// answers with the outcome: 290 and the ticket's address, or 291 and the
  /// reason.
  Switching
}

// A daemon whose router serves the web view, with the owner credential and
// the listener's port handed to `run`. The page's upgrade is a stub.
fn fixture(run: fn(root.Ready(String), Int, String) -> Nil) -> Nil {
  fixture_with(Stubbed, run)
}

fn fixture_with(
  serving: Upgrade,
  run: fn(root.Ready(String), Int, String) -> Nil,
) -> Nil {
  let directory =
    "build/test_db/daemon-ui-"
    <> bit_array.base16_encode(token.production_entropy()(8))
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "private fixture directory exists"
  let assert Ok(daemon) =
    root.start(
      root.Config(directory, "Owner", 2, limits.defaults),
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, _, _directory) { Ok(record.id) },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
    )
    as "daemon is prepared"
  let assert Ok(ready) = root.ready(daemon, within: 5000)
    as "durable owner and empty registry are ready"
  let assert Ok(credential) = root.listener_credential(daemon)
    as "only the fixture receives plaintext owner credential"
  let assert Ok(sessions) =
    ui_sessions.start(ui_sessions.production(bootstrap.monotonic_time_ms))
    as "the web view's tables start"
  let assert Ok(assets) = ui_assets.load()
    as "the web view's assets are in web_view's and lustre's priv"
  let config =
    server.Config(
      peer_endpoint: fn(_) { None },
      daemon:,
      domain_configuration: "",
      generator: fn() { ids.generator(clock.fixed(1_700_000_000_000), 123) },
      session_upgrade: fn(_, _) { stub(501, "v2 adapter absent") },
      ui: Some(
        server.Ui(
          sessions:,
          assets:,
          upgrade: fn(request, attachment, open, ceiling) {
            case serving {
              // The router hands the page's upgrade the capped role. The
              // stub reports what it was given.
              Stubbed ->
                case attachment.authority {
                  access.Participant(access.Observer) -> stub(299, "observer")
                  access.Participant(access.Operator) -> stub(298, "operator")
                  access.Owner -> stub(297, "not capped")
                }

              Switching -> switching(sessions, request, attachment, ceiling)

              // The session is resident but its gateway is not running: the
              // relay's attach is refused, as it is when a session is
              // stopped between the router's check and the attach.
              Real ->
                ui_socket.upgrade(
                  daemon,
                  request,
                  attachment,
                  gateway.Gateway(name: addresses.new()),
                  sessions,
                  open,
                  ceiling,
                )
            }
          },
        ),
      ),
    )
  let ports = process.new_subject()
  let assert Ok(listener) =
    mist.new(fn(request) { server.handle(config, request) })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
    |> mist.start
    as "one listener serves the daemon router"
  process.unlink(listener.pid)
  let assert Ok(port) = process.receive(ports, 1000) as "listener port is known"
  let outcomes =
    weft.new([fn() { Ok(run(ready, port, credential)) }])
    |> weft.deadline(40_000)
    |> weft.start
  assert root.shutdown(daemon, within: 5000) == Ok(Nil)
  process.kill(listener.pid)
  let assert [weft.Completed(0, _)] = outcomes
    as "the fixture body ran to completion inside its own deadline"
  Nil
}

// The page's upgrade as a session switch asks for one: the same two calls the
// page socket's transport makes, `opened_for` with the role the router
// admitted and `ticket_for` with the attachment and ceiling it handed over,
// for the session the request's header names.
fn switching(tickets, request, attachment: server.Attachment(String), ceiling) {
  let role = case attachment.authority {
    access.Participant(access.Observer) -> ui_socket.Observing
    access.Participant(access.Operator) | access.Owner -> ui_socket.Operating
  }
  let target = result.unwrap(req.get_header(request, "x-switch-target"), "")
  case
    ui_socket.opened_for(role, fn() {
      ui_socket.ticket_for(attachment, tickets, ceiling, target)
    })
  {
    sessions.Ticketed(path) -> stub(290, path)
    sessions.Declined(reason) -> stub(291, string.inspect(reason))
  }
}

fn stub(status: Int, text: String) {
  response.new(status)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(text)))
}

/// One HTTP response: its status, its headers (lowercased names) and body.
type Answer {
  Answer(status: Int, headers: List(#(String, String)), body: String)
}

// A raw GET, so a test can send any Host, Origin, Sec-Fetch-Site or cookie
// a browser or an attacker might.
fn get(port: Int, path: String, headers: List(#(String, String))) -> Answer {
  let assert Ok(socket) =
    ffi_daemon_socket.connect(
      #(127, 0, 0, 1),
      port,
      [ffi_ws.Binary, ffi_ws.Active(False)],
      1000,
    )
    as "raw TCP client connects"
  let lines =
    list.map(headers, fn(header) { header.0 <> ": " <> header.1 <> "\r\n" })
  let request =
    "GET " <> path <> " HTTP/1.1\r\n" <> string.concat(lines) <> "\r\n"
  assert ffi_daemon_socket.send(socket, bit_array.from_string(request))
    == Ok(Nil)
  let head = read_head(socket, "")
  let assert [status_line, ..header_lines] = string.split(head, "\r\n")
    as "a status line"
  let assert [_, code, ..] = string.split(status_line, " ") as "a status code"
  let assert Ok(status) = int.parse(code) as "a numeric status"
  let parsed =
    list.filter_map(header_lines, fn(line) {
      case string.split_once(line, ": ") {
        Ok(#(name, value)) -> Ok(#(string.lowercase(name), value))
        Error(Nil) -> Error(Nil)
      }
    })
  let length =
    list.key_find(parsed, "content-length")
    |> result.try(int.parse)
    |> result.unwrap(0)
  let body = case length > 0 && status != 101 {
    True -> {
      let assert Ok(bytes) = ffi_ws.tcp_receive(socket, length, 1000)
        as "the body arrives"
      let assert Ok(text) = bit_array.to_string(bytes) as "the body is text"
      text
    }
    False -> ""
  }
  let _ = ffi_ws.tcp_close(socket)
  Answer(status, parsed, body)
}

fn read_head(socket, accumulated: String) -> String {
  case string.split_once(accumulated, "\r\n\r\n") {
    Ok(#(head, _)) -> head
    Error(Nil) -> {
      let assert Ok(byte) = ffi_ws.tcp_receive(socket, 1, 1000)
        as "the response head arrives"
      let assert Ok(text) = bit_array.to_string(byte) as "the head is ASCII"
      read_head(socket, accumulated <> text)
    }
  }
}

fn field(value, key) {
  let assert json.Object(fields) = value as "an object"
  list.key_find(fields, key)
}

fn create_session(ready: root.Ready(String), key: String, seed: Int) -> String {
  let assert Ok(created) =
    manager.create(
      ready.registry,
      manager.Creation(key, ready.state_root, key, ""),
      directory: ready.sessions_directory,
      generator: ids.generator(clock.fixed(0), seed),
    )
    as "the session is created"
  let id = created.registration.id
  let assert poll.Answered(_) =
    poll.until(within: 2000, every: 1, attempt: fn() {
      case manager.resolve(ready.registry, id) {
        Ok(instance) -> poll.Done(instance)
        Error(_) -> poll.Retry
      }
    })
    as "the session becomes resident"
  id
}

// A ticket for an observer's page of `session` from `credential`'s own
// control connection.
fn link(port: Int, credential: String, session: String) -> String {
  link_for(port, credential, session, [])
}

// A ticket for an operator's page, as `loom ui --operate` asks for one.
fn operate(port: Int, credential: String, session: String) -> String {
  link_for(port, credential, session, [#("page", json.String("operator"))])
}

fn link_for(
  port: Int,
  credential: String,
  session: String,
  page: List(#(String, json.JsonValue)),
) -> String {
  let #(socket, _) = daemon_server_test.connect(port, credential, "/v2/control")
  let _hello = daemon_server_test.frame(socket, within_ms: 1000)
  let reply =
    daemon_server_test.send(
      socket,
      1,
      "ui.link",
      json.Object([#("session_id", json.String(session)), ..page]),
      within_ms: 1000,
    )
  let _ = ffi_ws.tcp_close(socket)
  let assert Ok(body) = field(reply, "body") as "the reply has a body"
  let assert Ok(json.String(path)) = field(body, "path") as "a link"
  assert field(body, "expires_in_ms") == Ok(json.Int(60_000))
  path
}

fn host(port: Int) -> #(String, String) {
  #("host", "127.0.0.1:" <> int.to_string(port))
}

fn cookie_of(answer: Answer) -> String {
  let assert Ok(set) = list.key_find(answer.headers, "set-cookie")
    as "the exchange sets a cookie"
  let assert Ok(#(pair, _)) = string.split_once(set, ";") as "attributes follow"
  let assert Ok(#("loom_ui", value)) = string.split_once(pair, "=")
    as "the cookie is loom_ui"
  value
}

fn exchange(port: Int, path: String) -> Answer {
  get(port, path, [host(port), #("sec-fetch-site", "none")])
}

/// What an exchange hands one tab: the cookie, the keyed page it moves to,
/// and the nonce it keeps.
type Entered {
  Entered(cookie: String, page: String, nonce: String)
}

fn entered(answer: Answer) -> Entered {
  assert answer.status == 200
  Entered(
    cookie: cookie_of(answer),
    page: attribute(answer.body, "data-next"),
    nonce: attribute(answer.body, "data-nonce"),
  )
}

fn enter(port: Int, path: String) -> Entered {
  entered(exchange(port, path))
}

fn attribute(body: String, name: String) -> String {
  let assert Ok(#(_, rest)) = string.split_once(body, name <> "=\"")
    as "the exchange page carries the attribute"
  let assert Ok(#(value, _)) = string.split_once(rest, "\"")
    as "the attribute is closed"
  value
}

// The keyed page, asked for as the exchange page's own move asks for it.
fn open_page(port: Int, entered: Entered) -> Answer {
  get(port, entered.page, [
    host(port),
    #("sec-fetch-site", "same-origin"),
    #("cookie", "loom_ui=" <> entered.cookie),
  ])
}

// The page's socket, with this origin, the cookie and `nonce` in the query
// Lustre's client runtime appends.
fn open_socket(port: Int, entered: Entered, nonce: String) -> Answer {
  get(port, entered.page <> "/ws?csrf-token=" <> nonce, [
    host(port),
    #("cookie", "loom_ui=" <> entered.cookie),
    #("origin", "http://127.0.0.1:" <> int.to_string(port)),
  ])
}

fn member(
  ready: root.Ready(String),
  name: String,
  session: String,
  role: access.Role,
) -> String {
  let credential = name <> "-token"
  let assert Ok(digest) =
    credential
    |> bit_array.from_string
    |> bootstrap.sha256
    |> bit_array.base16_encode
    |> string.lowercase
    |> access.credential_digest
    as "member digest is valid"
  let assert Ok(store) = catalogue.open(ready.state_root <> "/catalogue.db")
    as "fixture administration opens the durable catalogue"
  let assert Ok(principal) = access.create_member(store, name, name, digest)
    as "the member is created"
  assert access.grant(store, principal.id, session, role) == Ok(Nil)
  assert catalogue.close(store) == Ok(Nil)
  credential
}

// A member that already exists, given a role in another session.
fn also_holds(
  ready: root.Ready(String),
  member: String,
  session: String,
  role: access.Role,
) -> Nil {
  let assert Ok(store) = catalogue.open(ready.state_root <> "/catalogue.db")
    as "fixture administration opens the durable catalogue"
  assert access.grant(store, member, session, role) == Ok(Nil)
  assert catalogue.close(store) == Ok(Nil)
}

fn referrer_policy(answer: Answer) -> Result(String, Nil) {
  list.key_find(answer.headers, "referrer-policy")
}

pub fn without_ui_the_routes_do_not_exist_test() {
  daemon_server_test.fixture(fn(_, _, port, credential) {
    let session = "0198c0de-0000-7000-8000-000000000001"
    assert get(port, "/ui/sessions/" <> session, [host(port)]).status == 404
    assert get(port, "/ui/assets/web_client.css", [host(port)]).status == 404

    // The hello names no view, and a link is refused.
    let #(socket, _) =
      daemon_server_test.connect(port, credential, "/v2/control")
    let hello = daemon_server_test.frame(socket, within_ms: 1000)
    let assert Ok(body) = field(hello, "body") as "the hello has a body"
    assert field(body, "ui") == Error(Nil)
    let refused =
      daemon_server_test.send(
        socket,
        1,
        "ui.link",
        json.Object([#("session_id", json.String(session))]),
        within_ms: 1000,
      )
    let assert Ok(refusal) = field(refused, "body") as "a refusal body"
    assert field(refusal, "code") == Ok(json.String("unavailable"))
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn with_ui_the_hello_names_the_view_test() {
  fixture(fn(_, port, credential) {
    let #(socket, _) =
      daemon_server_test.connect(port, credential, "/v2/control")
    let hello = daemon_server_test.frame(socket, within_ms: 1000)
    let assert Ok(body) = field(hello, "body") as "the hello has a body"
    let assert Ok(view) = field(body, "ui") as "the hello names the view"
    assert field(view, "path") == Ok(json.String("/ui"))
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_ticket_becomes_a_keyed_page_once_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "once", 901)
    let path = link(port, credential, session)

    // A cross-site navigation cannot exchange it, and does not spend it.
    let cross = get(port, path, [host(port), #("sec-fetch-site", "cross-site")])
    assert cross.status == 403
    let absent = get(port, path, [host(port)])
    assert absent.status == 403

    // The exchange answers 200, never a redirect, with the keyed page and
    // the nonce in its body, and a cookie scoped to the page key.
    let answer = exchange(port, path)
    assert string.contains(answer.body, "web_view_enter.js")
    assert list.key_find(answer.headers, "location") == Error(Nil)
    let page = entered(answer)
    assert string.starts_with(page.page, "/ui/p/")
    assert string.ends_with(page.page, "/sessions/" <> session)
    assert page.nonce != ""
    let assert Ok(set) = list.key_find(answer.headers, "set-cookie")
      as "the cookie is set"
    assert string.contains(set, "HttpOnly")
    assert string.contains(set, "SameSite=Strict")
    let key_path = string.replace(page.page, "/sessions/" <> session, "")
    assert string.ends_with(set, "Path=" <> key_path)

    // Spent.
    assert exchange(port, path).status == 401

    // The cookie opens the keyed page; nothing else does, and the unkeyed
    // path holds no page at all.
    let opened = open_page(port, page)
    assert opened.status == 200
    assert string.contains(opened.body, "lustre-server-component")
    assert string.contains(opened.body, "web_view_page.js")
    assert !string.contains(opened.body, page.nonce)
    assert get(port, page.page, [host(port), #("sec-fetch-site", "none")]).status
      == 401
    assert get(port, page.page, [
        host(port),
        #("sec-fetch-site", "none"),
        #("cookie", "loom_ui=forged"),
      ]).status
      == 401
    assert get(port, "/ui/sessions/" <> session, [
        host(port),
        #("cookie", "loom_ui=" <> page.cookie),
      ]).status
      == 404
  })
}

// Only a navigation from this origin, or from outside any page, reaches a
// keyed page: no other site and no other loopback port can frame or open it
// in front of the person.
pub fn a_keyed_page_needs_a_first_party_navigation_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "navigation", 906)
    let page = enter(port, link(port, credential, session))
    let from = fn(site) {
      get(port, page.page, [
        host(port),
        #("sec-fetch-site", site),
        #("cookie", "loom_ui=" <> page.cookie),
      ]).status
    }
    assert from("same-origin") == 200
    assert from("none") == 200
    assert from("same-site") == 403
    assert from("cross-site") == 403
    assert get(port, page.page, [
        host(port),
        #("cookie", "loom_ui=" <> page.cookie),
      ]).status
      == 403
  })
}

// A cookie is honoured only under the key it was issued with: another live
// page's key, with this page's cookie, is refused.
pub fn a_valid_cookie_under_another_key_is_refused_test() {
  fixture(fn(ready, port, credential) {
    let first = create_session(ready, "first-key", 907)
    let second = create_session(ready, "second-key", 908)
    let one = enter(port, link(port, credential, first))
    let two = enter(port, link(port, credential, second))
    let key_of = fn(entered: Entered, session) {
      string.replace(entered.page, "/sessions/" <> session, "")
    }

    // The first page's cookie on the first session's path under the second
    // page's key.
    let crossed = key_of(two, second) <> "/sessions/" <> first
    assert get(port, crossed, [
        host(port),
        #("sec-fetch-site", "same-origin"),
        #("cookie", "loom_ui=" <> one.cookie),
      ]).status
      == 401
    assert get(port, crossed <> "/ws?csrf-token=" <> one.nonce, [
        host(port),
        #("cookie", "loom_ui=" <> one.cookie),
        #("origin", "http://127.0.0.1:" <> int.to_string(port)),
      ]).status
      == 401
    assert open_page(port, one).status == 200
  })
}

// A server on another loopback port that knows the key can plant a
// `loom_ui` cookie under a longer path, which the browser sends first. The
// planted value names no UI session, so the real one behind it still opens
// the page and its socket.
pub fn a_planted_cookie_does_not_shadow_the_real_one_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "planted", 912)
    let page = enter(port, operate(port, credential, session))
    let both = #("cookie", "loom_ui=planted; loom_ui=" <> page.cookie)
    assert get(port, page.page, [
        host(port),
        #("sec-fetch-site", "same-origin"),
        both,
      ]).status
      == 200
    assert get(port, page.page <> "/ws?csrf-token=" <> page.nonce, [
        host(port),
        both,
        #("origin", "http://127.0.0.1:" <> int.to_string(port)),
      ]).status
      == 298
    assert get(port, page.page, [
        host(port),
        #("sec-fetch-site", "same-origin"),
        #("cookie", "loom_ui=planted"),
      ]).status
      == 401
  })
}

pub fn the_socket_needs_origin_cookie_key_and_nonce_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "socket", 902)
    let page = enter(port, link(port, credential, session))
    let socket = page.page <> "/ws?csrf-token=" <> page.nonce
    let with_cookie = #("cookie", "loom_ui=" <> page.cookie)
    let origin = "http://127.0.0.1:" <> int.to_string(port)

    // A rebinding attack's host is refused before anything else.
    assert get(port, socket, [#("host", "evil.example"), with_cookie]).status
      == 403

    // This origin, and nothing else.
    assert get(port, socket, [host(port), with_cookie]).status == 403
    assert get(port, socket, [
        host(port),
        with_cookie,
        #("origin", "http://evil.example"),
      ]).status
      == 403

    // The nonce the exchange handed this tab, and nothing else.
    assert get(port, page.page <> "/ws", [
        host(port),
        with_cookie,
        #("origin", origin),
      ]).status
      == 403
    assert open_socket(port, page, "forged").status == 403
    assert open_socket(port, page, page.nonce <> "0").status == 403

    // With all of them, the upgrade is reached as an observer, although the
    // ticket was minted by the owner: an observer's page is the default.
    assert open_socket(port, page, page.nonce).status == 299
  })
}

// The ceiling caps and never grants: an operator's page is an operator's for
// the owner and for an operator, and an observer's for an observer.
pub fn an_operators_page_caps_the_membership_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "operate", 909)
    let as_owner = enter(port, operate(port, credential, session))
    assert open_socket(port, as_owner, as_owner.nonce).status == 298

    let operator = member(ready, "ui-operator", session, access.Operator)
    let as_operator = enter(port, operate(port, operator, session))
    assert open_socket(port, as_operator, as_operator.nonce).status == 298

    let observer = member(ready, "ui-observer", session, access.Observer)
    let as_observer = enter(port, operate(port, observer, session))
    assert open_socket(port, as_observer, as_observer.nonce).status == 299

    // A page asked for without `--operate` stays an observer's.
    let plain = enter(port, link(port, operator, session))
    assert open_socket(port, plain, plain.nonce).status == 299
  })
}

// The policy protocol-change/051 specifies, spelled out rather than taken
// from `page.content_security_policy`, so that a change to it fails here and
// has to be argued in a 051 addendum. Moving the stylesheet and scripts into
// files changed where they come from and nothing about what may run.
fn policy(port: Int) -> String {
  "default-src 'none'; script-src 'self'; style-src 'self'; "
  <> "style-src-attr 'unsafe-inline'; connect-src 'self' ws://127.0.0.1:"
  <> int.to_string(port)
  <> "; img-src 'self'; base-uri 'none'; form-action 'none'; "
  <> "frame-ancestors 'none'"
}

// Every asset is served from the file its application ships, byte for byte,
// under the unchanged policy; the scripts keep the nonce under the item name
// the page module names.
pub fn the_assets_are_the_priv_files_under_the_unchanged_policy_test() {
  fixture(fn(_ready, port, _credential) {
    let javascript = "text/javascript; charset=utf-8"
    let assets = [
      #(page.stylesheet_asset, "text/css; charset=utf-8", page.static_file),
      #(page.enter_asset, javascript, page.static_file),
      #(page.page_asset, javascript, page.static_file),
      #(page.client_asset, javascript, page.static_file),
      #(page.runtime_asset, javascript, fn(_) { page.runtime_file() }),
    ]
    list.each(assets, fn(asset) {
      let #(name, content_type, file) = asset
      let answer = get(port, page.asset_path(name), [host(port)])
      assert answer.status == 200
      assert list.key_find(answer.headers, "content-type") == Ok(content_type)
      assert list.key_find(answer.headers, "content-security-policy")
        == Ok(policy(port))
      assert list.key_find(answer.headers, "x-content-type-options")
        == Ok("nosniff")
      let assert Ok(path) = file(name) as "the asset has a priv path"
      let assert Ok(on_disk) = simplifile.read(path) as "the priv file reads"
      assert answer.body == on_disk
    })
    list.each([page.enter_asset, page.page_asset], fn(name) {
      let answer = get(port, page.asset_path(name), [host(port)])
      assert string.contains(answer.body, "\"" <> page.nonce_item <> "\"")
    })
  })
}

// Referrer-Policy is load-bearing: the exchange's URL carries the ticket and
// the page's carries its key, and neither may leave in a Referer.
pub fn every_document_and_script_withholds_the_referrer_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "referrer", 910)
    let answer = exchange(port, link(port, credential, session))
    assert referrer_policy(answer) == Ok("no-referrer")
    let page = entered(answer)
    assert referrer_policy(open_page(port, page)) == Ok("no-referrer")
    let enter_script = get(port, "/ui/assets/web_view_enter.js", [host(port)])
    assert enter_script.status == 200
    assert referrer_policy(enter_script) == Ok("no-referrer")
    let page_script = get(port, "/ui/assets/web_view_page.js", [host(port)])
    assert page_script.status == 200
    assert referrer_policy(page_script) == Ok("no-referrer")

    // A refusal carries the policy too.
    let refused = get(port, page.page, [host(port)])
    assert refused.status == 403
    assert referrer_policy(refused) == Ok("no-referrer")
    let assert Ok(policy) =
      list.key_find(refused.headers, "content-security-policy")
      as "a refusal carries the policy"
    assert string.contains(policy, "form-action 'none'")
    assert get(port, "/ui/assets/elsewhere.js", [host(port)]).status == 404
  })
}

// Protocol-change/051, the addendum on several pages: a second exchange for
// the same principal and session opens a second page and leaves the first
// open. Each keeps its own cookie, key and nonce, so neither page's
// credentials reach the other's socket.
pub fn a_second_exchange_leaves_the_first_page_open_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "several", 911)
    let first = enter(port, link(port, credential, session))
    assert open_page(port, first).status == 200
    let second = enter(port, link(port, credential, session))
    assert open_page(port, second).status == 200
    assert open_page(port, first).status == 200
    assert first.cookie != second.cookie
    assert first.page != second.page
    assert first.nonce != second.nonce

    // A page's nonce opens no socket for another page's cookie.
    assert open_socket(port, first, first.nonce).status == 299
    assert open_socket(port, second, second.nonce).status == 299
    assert open_socket(port, first, second.nonce).status == 403
  })
}

// The fifth link for one principal and session is redeemed, and ends the
// oldest of the four pages already open. The other three stay open and the
// ended one is answered as an ended page.
pub fn a_page_past_the_cap_ends_only_the_oldest_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "capped", 923)
    let held =
      list.repeat(Nil, ending.max_pages)
      |> list.map(fn(_) { enter(port, link(port, credential, session)) })
    list.each(held, fn(page) {
      assert open_page(port, page).status == 200
    })

    let newest = enter(port, link(port, credential, session))
    assert open_page(port, newest).status == 200
    let assert [oldest, ..rest] = held
    let ended = open_page(port, oldest)
    assert ended.status == 401
    assert string.contains(ended.body, ending.headline(ending.PageEnded))
    assert open_socket(port, oldest, oldest.nonce).status == 401
    list.each(rest, fn(page) {
      assert open_page(port, page).status == 200
    })
  })
}

// The reload of a page that ended answers with the ending and what to do,
// in the fixed words, not the bare status text it once did. A reload cannot
// bring the page back, so the words say to ask for a fresh link. A cookie
// that names no live UI session is what an expired or forgotten page sends.
pub fn an_ended_pages_reload_says_it_ended_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "ended", 921)
    let first = enter(port, link(port, credential, session))
    let forgotten = Entered(..first, cookie: string.repeat("0", 64))
    let reloaded = open_page(port, forgotten)
    assert reloaded.status == 401
    assert string.contains(reloaded.body, ending.headline(ending.PageEnded))
    assert string.contains(reloaded.body, "loom ui --session " <> session)
    assert !string.contains(reloaded.body, "no page session under this key")
    assert list.key_find(reloaded.headers, "content-type")
      == Ok("text/html; charset=utf-8")
    assert referrer_policy(reloaded) == Ok("no-referrer")
  })
}

// A link that was already used, or that ran out its 60 seconds, is refused
// with a page that says so and how to get another.
pub fn a_spent_link_says_it_expired_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "spent", 922)
    let path = link(port, credential, session)
    let _ = enter(port, path)
    let again = exchange(port, path)
    assert again.status == 401
    assert string.contains(again.body, ending.headline(ending.LinkExpired))
    assert string.contains(again.body, "loom ui --session " <> session)
  })
}

// The advice names the session only if the address held a canonical
// identity. Anything else is what the address said, and repeating it as a
// command to run would let a crafted link put text in front of the person.
pub fn a_refused_page_never_repeats_an_address_it_cannot_parse_test() {
  fixture(fn(_, port, _) {
    let refused =
      get(port, "/ui/p/nokey/sessions/curl-evil.example-sh", [
        host(port),
        #("sec-fetch-site", "none"),
      ])
    assert refused.status == 401
    assert !string.contains(refused.body, "evil")
    assert string.contains(refused.body, "loom ui --session &lt;id&gt;")
  })
}

// A raw WebSocket to the page's socket, with this origin, the cookie and the
// nonce. Answers the frames the daemon sends until it closes, and the close
// code, or 0 when the connection ended without one.
type Closed {
  Closed(texts: List(String), code: Int)
}

fn watch_socket(port: Int, entered: Entered) -> Closed {
  let assert Ok(socket) =
    ffi_daemon_socket.connect(
      #(127, 0, 0, 1),
      port,
      [ffi_ws.Binary, ffi_ws.Active(False)],
      1000,
    )
    as "raw TCP client connects"
  let handshake =
    "GET "
    <> entered.page
    <> "/ws?csrf-token="
    <> entered.nonce
    <> " HTTP/1.1\r\nHost: 127.0.0.1:"
    <> int.to_string(port)
    <> "\r\nOrigin: http://127.0.0.1:"
    <> int.to_string(port)
    <> "\r\nCookie: loom_ui="
    <> entered.cookie
    <> "\r\nUpgrade: websocket\r\nConnection: Upgrade"
    <> "\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="
    <> "\r\nSec-WebSocket-Version: 13\r\n\r\n"
  assert ffi_daemon_socket.send(socket, bit_array.from_string(handshake))
    == Ok(Nil)
  let head = read_head(socket, "")
  assert string.starts_with(head, "HTTP/1.1 101")
  let closed = read_until_closed(socket, [])
  let _ = ffi_ws.tcp_close(socket)
  closed
}

// Reads server frames, which are never masked, until a close frame or the
// end of the connection. Each text frame is kept, oldest first.
fn read_until_closed(socket, texts: List(String)) -> Closed {
  case ffi_ws.tcp_receive(socket, 2, 5000) {
    Error(_) -> Closed(list.reverse(texts), 0)
    Ok(<<_:4, opcode:4, _:1, marker:7>>) -> {
      let size = case marker {
        126 -> {
          let assert Ok(<<size:16>>) = ffi_ws.tcp_receive(socket, 2, 5000)
            as "the extended length arrives"
          size
        }
        127 -> {
          let assert Ok(<<size:64>>) = ffi_ws.tcp_receive(socket, 8, 5000)
            as "the long length arrives"
          size
        }
        size -> size
      }
      let assert Ok(payload) = case size {
        0 -> Ok(<<>>)
        _ -> ffi_ws.tcp_receive(socket, size, 5000)
      }
        as "the payload arrives"
      case opcode {
        // A close frame opens with its code.
        8 ->
          case payload {
            <<code:16, _:bytes>> -> Closed(list.reverse(texts), code)
            _ -> Closed(list.reverse(texts), 0)
          }
        1 -> {
          let assert Ok(text) = bit_array.to_string(payload)
            as "a text frame is UTF-8"
          read_until_closed(socket, [text, ..texts])
        }
        _ -> read_until_closed(socket, texts)
      }
    }
    Ok(_) -> Closed(list.reverse(texts), 0)
  }
}

// The relay's attach is refused, so the page draws that the session is not
// open and closes with a code Lustre's client runtime retries (anything but
// 1000). The gateway's own words are not among what the browser is sent.
pub fn a_refused_attach_is_drawn_and_retried_test() {
  fixture_with(Real, fn(ready, port, credential) {
    let session = create_session(ready, "unattached", 923)
    let page = enter(port, link(port, credential, session))
    let closed = watch_socket(port, page)
    let drawn = string.join(closed.texts, "\n")
    assert string.contains(drawn, ending.headline(ending.NotOpen))
    assert string.contains(drawn, "loom ui --session " <> session)
    assert !string.contains(drawn, "gateway unavailable")
    assert closed.code == 4000
  })
}

pub fn a_revoked_credential_refuses_the_page_request_test() {
  fixture(fn(ready, port, _) {
    let session = create_session(ready, "revoked", 903)
    let credential = member(ready, "ui-member", session, access.Operator)
    let page = enter(port, link(port, credential, session))
    assert open_page(port, page).status == 200

    let assert Ok(digest) =
      credential
      |> bit_array.from_string
      |> bootstrap.sha256
      |> bit_array.base16_encode
      |> string.lowercase
      |> access.credential_digest
      as "member digest is valid"
    let assert Ok(store) = catalogue.open(ready.state_root <> "/catalogue.db")
      as "fixture administration opens the durable catalogue"
    assert access.revoke_credential(store, digest) == Ok(Nil)
    assert catalogue.close(store) == Ok(Nil)
    assert open_page(port, page).status == 401
  })
}

pub fn a_ticket_for_another_session_is_refused_and_signs_nothing_out_test() {
  fixture(fn(ready, port, credential) {
    let first = create_session(ready, "first", 904)
    let second = create_session(ready, "second", 905)
    let page = enter(port, link(port, credential, first))

    // The second session's ticket, presented on the first session's path:
    // refused, spent, and no cookie is set.
    let misdirected =
      string.replace(link(port, credential, second), second, first)
    let refused =
      get(port, misdirected, [host(port), #("sec-fetch-site", "none")])
    assert refused.status == 403
    assert list.key_find(refused.headers, "set-cookie") == Error(Nil)

    // The first page still opens with the cookie it had.
    assert open_page(port, page).status == 200
  })
}

// The page's socket as a switch asks for a ticket: the upgrade of the page
// `entered` is asked for `target`, and answers with what the daemon decided.
fn ask(port: Int, entered: Entered, target: String) -> Answer {
  get(port, entered.page <> "/ws?csrf-token=" <> entered.nonce, [
    host(port),
    #("cookie", "loom_ui=" <> entered.cookie),
    #("origin", "http://127.0.0.1:" <> int.to_string(port)),
    #("x-switch-target", target),
  ])
}

// The daemon answers an operator's page holding another session with a ticket
// for it, which is exchanged like any other into a new page that carries the
// page's own ceiling. The page left behind stays open, and is not the one a
// new page for the other session could displace.
pub fn an_operators_page_opens_a_session_its_principal_holds_test() {
  fixture_with(Switching, fn(ready, port, _) {
    let left = create_session(ready, "left", 931)
    let target = create_session(ready, "target", 932)
    let operator = member(ready, "ui-switcher", left, access.Operator)
    also_holds(ready, "ui-switcher", target, access.Operator)

    let page_left = enter(port, operate(port, operator, left))
    let asked = ask(port, page_left, target)
    assert asked.status == 290
    assert string.starts_with(
      asked.body,
      "/ui/sessions/" <> target <> "?ticket=",
    )

    // The ticket opens a page of the target session, and the page left behind
    // is still open.
    let page_target = enter(port, asked.body)
    assert open_page(port, page_target).status == 200
    assert open_page(port, page_left).status == 200
    assert page_target.cookie != page_left.cookie

    // The new page is an operator's: the ceiling the switch carried is the
    // page's own.
    assert ask(port, page_target, left).status == 290

    // The ticket is spent once.
    let again = get(port, asked.body, [host(port), #("sec-fetch-site", "none")])
    assert again.status == 401
  })
}

// A ticket is minted only for a session the page's principal holds: a session
// it has no membership in, one that does not exist and text that is not a
// session identity are all the same refusal, so a page learns nothing about
// sessions it cannot open.
pub fn a_page_cannot_open_a_session_its_principal_does_not_hold_test() {
  fixture_with(Switching, fn(ready, port, _) {
    let held = create_session(ready, "held", 933)
    let other = create_session(ready, "other", 934)
    let operator = member(ready, "ui-narrow", held, access.Operator)
    let page = enter(port, operate(port, operator, held))
    list.each(
      [
        other,
        "01900000-0000-7000-8000-000000000000",
        "not a session",
        "",
      ],
      fn(target) {
        let refused = ask(port, page, target)
        assert refused.status == 291
        assert refused.body == "NotHeld"
      },
    )
  })
}

// An observer's page asks and is refused in the same words, although its
// principal holds the target, and no ticket exists for a later redemption.
pub fn an_observers_page_cannot_open_a_session_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let left = create_session(ready, "watching", 935)
    let target = create_session(ready, "watched", 936)
    let observed = enter(port, link(port, credential, left))
    let refused = ask(port, observed, target)
    assert refused.status == 291
    assert refused.body == "NotHeld"
  })
}

// A session no process runs has no page to show, so the daemon says so
// instead of minting a ticket for a page that would be refused at its socket.
pub fn a_saved_session_is_not_opened_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let left = create_session(ready, "running", 937)
    let target = create_session(ready, "saved", 938)
    let assert Ok(_) = manager.stop_session(ready.registry, target)
      as "stop requested"
    assert poll.until(within: 2000, every: 1, attempt: fn() {
        case manager.get(ready.registry, target) {
          Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
          Ok(_) -> poll.Retry
          Error(error) -> poll.Fail(error)
        }
      })
      == poll.Answered(Nil)
    let page = enter(port, operate(port, credential, left))
    let refused = ask(port, page, target)
    assert refused.status == 291
    assert refused.body == "NotRunning"
  })
}

pub fn a_refused_host_still_carries_the_policy_test() {
  fixture(fn(_, port, _) {
    let refused =
      get(port, "/ui/assets/web_client.css", [#("host", "evil.example")])
    assert refused.status == 403
    let assert Ok(policy) =
      list.key_find(refused.headers, "content-security-policy")
      as "the refusal carries a policy"
    assert string.contains(policy, "default-src 'none'")
    assert !string.contains(policy, "evil.example")
  })
}
