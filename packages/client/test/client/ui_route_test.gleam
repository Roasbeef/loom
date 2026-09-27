//// The web view's routes on a real daemon listener (protocol-change/051):
//// without `--ui` none of them exist; with it, a ticket from `ui.link` is
//// exchanged once for a cookie, and every request is checked for its host,
//// its origin or fetch site, its cookie and the credential behind it, and
//// carries the view's security headers. The page's socket reaches the
//// upgrade only after every check, and always as an observer.
////
//// The session assembly is inert, as in `daemon_server_test`: these tests
//// are about routing and authorization. The upgrade is a stub that answers
//// with the role the router handed it, since the Lustre transport behind it
//// is exercised by the relay and component tests.

import broker/token
import client/daemon/domain as domain_service
import client/daemon/limits
import client/daemon/manager
import client/daemon/root
import client/daemon/server
import client/daemon/ui_sessions
import client/daemon_server_test
import core/clock
import core/ids
import core/json
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import mist
import storage/access
import storage/catalogue
import support/internal/ffi_daemon_socket
import support/internal/ffi_ws
import weft
import weft/poll

// A daemon whose router serves the web view, with the owner credential and
// the listener's port handed to `run`.
fn fixture(run: fn(root.Ready(String), Int, String) -> Nil) -> Nil {
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
  let config =
    server.Config(
      peer_endpoint: fn(_) { None },
      daemon:,
      domain_configuration: "",
      generator: fn() { ids.generator(clock.fixed(1_700_000_000_000), 123) },
      session_upgrade: fn(_, _) { stub(501, "v2 adapter absent") },
      ui: Some(
        server.Ui(sessions:, upgrade: fn(_, attachment, _open) {
          // The router hands the page's upgrade an observer, whatever the
          // principal's membership. The stub reports what it was given.
          case attachment.authority {
            access.Participant(access.Observer) -> stub(299, "observer")
            access.Owner | access.Participant(access.Operator) ->
              stub(298, "not capped")
          }
        }),
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

// A ticket for `session` from `credential`'s own control connection.
fn link(port: Int, credential: String, session: String) -> String {
  let #(socket, _) = daemon_server_test.connect(port, credential, "/v2/control")
  let _hello = daemon_server_test.frame(socket, within_ms: 1000)
  let reply =
    daemon_server_test.send(
      socket,
      1,
      "ui.link",
      json.Object([#("session_id", json.String(session))]),
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

pub fn without_ui_the_routes_do_not_exist_test() {
  daemon_server_test.fixture(fn(_, _, port, credential) {
    let session = "0198c0de-0000-7000-8000-000000000001"
    assert get(port, "/ui/sessions/" <> session, [host(port)]).status == 404
    assert get(port, "/ui/assets/web_view.css", [host(port)]).status == 404

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

pub fn a_ticket_becomes_a_cookie_once_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "once", 901)
    let path = link(port, credential, session)

    // A cross-site navigation cannot exchange it, and does not spend it.
    let cross = get(port, path, [host(port), #("sec-fetch-site", "cross-site")])
    assert cross.status == 403
    let absent = get(port, path, [host(port)])
    assert absent.status == 403

    let entered = exchange(port, path)
    assert entered.status == 200
    assert string.contains(entered.body, "web_view_enter.js")
    let cookie = cookie_of(entered)
    let assert Ok(set) = list.key_find(entered.headers, "set-cookie")
      as "the cookie is set"
    assert string.contains(set, "HttpOnly")
    assert string.contains(set, "SameSite=Strict")
    assert string.contains(set, "Path=/ui")

    // Spent.
    assert exchange(port, path).status == 401

    // The cookie opens the page; nothing else does.
    let page =
      get(port, "/ui/sessions/" <> session, [
        host(port),
        #("cookie", "loom_ui=" <> cookie),
      ])
    assert page.status == 200
    assert string.contains(page.body, "lustre-server-component")
    assert get(port, "/ui/sessions/" <> session, [host(port)]).status == 401
    assert get(port, "/ui/sessions/" <> session, [
        host(port),
        #("cookie", "loom_ui=forged"),
      ]).status
      == 401
  })
}

pub fn every_ui_response_is_checked_and_secured_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "checked", 902)
    let cookie = cookie_of(exchange(port, link(port, credential, session)))
    let page = "/ui/sessions/" <> session
    let with_cookie = #("cookie", "loom_ui=" <> cookie)

    // A rebinding attack's host is refused before anything else.
    assert get(port, page, [#("host", "evil.example"), with_cookie]).status
      == 403

    // Every document carries the policy, a refusal included.
    let refused = get(port, page, [host(port)])
    assert refused.status == 401
    let assert Ok(policy) =
      list.key_find(refused.headers, "content-security-policy")
      as "a refusal carries the policy"
    assert string.contains(policy, "form-action 'none'")
    let stylesheet = get(port, "/ui/assets/web_view.css", [host(port)])
    assert stylesheet.status == 200
    assert list.key_find(stylesheet.headers, "content-security-policy")
      |> result.is_ok
    assert get(port, "/ui/assets/elsewhere.js", [host(port)]).status == 404

    // The socket needs this origin, then reaches the upgrade as an observer
    // although the ticket was minted by the owner.
    let socket = page <> "/ws"
    let origin = "http://127.0.0.1:" <> int.to_string(port)
    assert get(port, socket, [host(port), with_cookie]).status == 403
    assert get(port, socket, [
        host(port),
        with_cookie,
        #("origin", "http://evil.example"),
      ]).status
      == 403
    assert get(port, socket, [host(port), with_cookie, #("origin", origin)]).status
      == 299
  })
}

pub fn a_revoked_credential_refuses_the_page_request_test() {
  fixture(fn(ready, port, _) {
    let session = create_session(ready, "revoked", 903)
    let member = "ui-member-token"
    let assert Ok(digest) =
      member
      |> bit_array.from_string
      |> bootstrap.sha256
      |> bit_array.base16_encode
      |> string.lowercase
      |> access.credential_digest
      as "member digest is valid"
    let assert Ok(store) = catalogue.open(ready.state_root <> "/catalogue.db")
      as "fixture administration opens the durable catalogue"
    let assert Ok(principal) =
      access.create_member(store, "ui-member", "Member", digest)
      as "the member is created"
    assert access.grant(store, principal.id, session, access.Operator)
      == Ok(Nil)

    let cookie = cookie_of(exchange(port, link(port, member, session)))
    let page = "/ui/sessions/" <> session
    let with_cookie = #("cookie", "loom_ui=" <> cookie)
    assert get(port, page, [host(port), with_cookie]).status == 200

    assert access.revoke_credential(store, digest) == Ok(Nil)
    assert get(port, page, [host(port), with_cookie]).status == 401
    assert catalogue.close(store) == Ok(Nil)
  })
}

pub fn a_ticket_for_another_session_is_refused_and_signs_nothing_out_test() {
  fixture(fn(ready, port, credential) {
    let first = create_session(ready, "first", 904)
    let second = create_session(ready, "second", 905)
    let cookie = cookie_of(exchange(port, link(port, credential, first)))
    let with_cookie = #("cookie", "loom_ui=" <> cookie)

    // The second session's ticket, presented on the first session's path
    // with the first page's cookie: refused, spent, and no cookie is set.
    let misdirected =
      string.replace(link(port, credential, second), second, first)
    let refused =
      get(port, misdirected, [
        host(port),
        #("sec-fetch-site", "none"),
        with_cookie,
      ])
    assert refused.status == 403
    assert list.key_find(refused.headers, "set-cookie") == Error(Nil)

    // The first page still opens with the cookie it had.
    assert get(port, "/ui/sessions/" <> first, [host(port), with_cookie]).status
      == 200
  })
}

pub fn a_refused_host_still_carries_the_policy_test() {
  fixture(fn(_, port, _) {
    let refused =
      get(port, "/ui/assets/web_view.css", [#("host", "evil.example")])
    assert refused.status == 403
    let assert Ok(policy) =
      list.key_find(refused.headers, "content-security-policy")
      as "the refusal carries a policy"
    assert string.contains(policy, "default-src 'none'")
    assert !string.contains(policy, "evil.example")
  })
}
