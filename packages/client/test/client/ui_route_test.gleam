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
import client/daemon_claim_test
import client/daemon_server_test
import client/gateway
import core/clock
import core/ids
import core/json
import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request as req
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import host/claim
import mist
import session_view/transcript_image
import simplifile
import sqlight
import storage/access
import storage/catalogue
import storage/domain
import support/addresses
import support/internal/ffi_daemon_socket
import support/internal/ffi_ws
import web_view/ending
import web_view/home
import web_view/invites
import web_view/page
import web_view/sessions
import weft
import weft/poll

// How long a session named `slow-...` takes to build, in milliseconds.
const slow_build_ms = 1200

// What the page's upgrade does: answer with the role the router handed it, or
// be the daemon's own page socket over a gateway that is not running.
type Upgrade {
  Stubbed
  Real

  /// As `Stubbed`, and the upgrade registers a reader for the page's images
  /// that knows a fixed table (`held`), as the page socket registers its
  /// component's. The upgrade registers before it answers, so a test that
  /// opened the socket may then ask for an image.
  Pictured

  /// The upgrade asks the daemon for a ticket to open the session a header
  /// names, as an operator's page does when its sidebar row is pressed, and
  /// answers with the outcome: 290 and the ticket's address, or 291 and the
  /// reason.
  Switching

  /// The upgrade does what the page socket does for an invitation: it reads
  /// the role the router admitted (`ui_socket.role_of`) and, for an owner's
  /// page, asks the daemon to invite as the page's transport would, with the
  /// role a header names. The answer is 292 and the invitation's fields one
  /// to a line, or 293 and the reason. A page the transport gives no
  /// capability is answered 294 for a member operator's and 295 for an
  /// observer's. `x-invite-force` asks the daemon anyway, as a page whose
  /// capability was wrongly handed out would, and `x-switch-ended` asks as
  /// a page that has ended.
  Inviting
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
  fixture_lasting(serving, ui_sessions.session_ms, run)
}

// `fixture_with` for pages that live `session_ms` milliseconds, so a test can
// see one expire.
fn fixture_lasting(
  serving: Upgrade,
  session_ms: Int,
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
        build: fn(record, _domain, _services, _, _directory) {
          // A session named `slow-...` takes a moment to build, so a test can
          // see an open that has not finished.
          case string.starts_with(record.name, "slow-") {
            True -> process.sleep(slow_build_ms)
            False -> Nil
          }
          Ok(record.id)
        },
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
    ui_sessions.start(ui_sessions.Settings(
      now: bootstrap.monotonic_time_ms,
      entropy: token.production_entropy(),
      ticket_ms: ui_sessions.ticket_ms,
      session_ms:,
    ))
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
      ui: Some(server.Ui(
        sessions:,
        assets:,
        upgrade: fn(request, attachment, open, register, ceiling, reach) {
          case serving {
            // The router hands the page's upgrade the capped role and the
            // grant's reach. The stub reports what it was given.
            Stubbed -> reported(capped(attachment), reach)

            Pictured -> {
              register(held)
              reported(capped(attachment), reach)
            }

            Switching ->
              switching(sessions, request, attachment, ceiling, reach, open)

            Inviting -> inviting(sessions, request, attachment, open)

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
                register,
                ceiling,
                reach,
              )
          }
        },
        home: fn(request, attachment, open, ceiling, reach) {
          case serving {
            // The home's own socket, as the daemon serves it. A request that
            // carries `x-revoke-between` names a credential revoked after the
            // router admitted the page and before the component's first read,
            // which the refresh interval is far too long for a test to wait
            // out.
            Real -> {
              case req.get_header(request, "x-revoke-between") {
                Ok(token) -> revoke(ready.state_root, token)
                Error(Nil) -> Nil
              }
              ui_socket.upgrade_home(
                daemon,
                request,
                attachment,
                sessions,
                open,
                ceiling,
                reach,
              )
            }

            // The home as a row press asks for a ticket: the same call the
            // home's transport makes, for the session a header names.
            Switching ->
              case req.get_header(request, "x-switch-target") {
                Ok(target) ->
                  opening_from_home(
                    sessions,
                    request,
                    attachment,
                    ceiling,
                    reach,
                    open,
                    target,
                  )
                Error(Nil) ->
                  homed(ready.state_root, request, attachment, open, ceiling)
              }

            Stubbed | Pictured | Inviting ->
              homed(ready.state_root, request, attachment, open, ceiling)
          }
        },
      )),
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

// An answer that also says which reach the router read from the page's grant,
// in `x-page-reach`.
fn reported(answer, reach: ui_sessions.Reach) {
  response.set_header(answer, "x-page-reach", case reach {
    ui_sessions.OneSession -> "one_session"
    ui_sessions.Workspace -> "workspace"
  })
}

// What the stubbed upgrade answers: the role the router capped the page to.
fn capped(attachment: server.Attachment(String)) {
  case attachment.authority {
    access.Participant(access.Observer) -> stub(299, "observer")
    access.Participant(access.Operator) -> stub(298, "operator")
    access.Owner -> stub(297, "not capped")
  }
}

// The page's upgrade as a session switch asks for one: the same two calls the
// page socket's transport makes, `opened_for` with the role the router
// admitted and `ticket_for` with the attachment and ceiling it handed over,
// for the session the request's header names.
//
// A request that carries `x-switch-ended` is asked as a page that has ended
// but whose socket is still up: its `open` answers that it is no longer open.
// The answer carries the asking page's deadline in `x-page-deadline`.
//
// A request that carries `x-go-home` asks as the page's "Home" button does
// instead: the capability the page socket is handed (`home_capability`) is
// consulted first and a page with none is answered 289, and otherwise the
// daemon's `home_ticket_for` answers 288 and the home exchange's address, or 291
// and the reason. Every answer carries the page's reach in `x-page-reach`.
fn switching(
  tickets,
  request,
  attachment: server.Attachment(String),
  ceiling,
  reach: ui_sessions.Reach,
  open: fn() -> Result(Int, Nil),
) {
  let role = case attachment.authority {
    access.Participant(access.Observer) -> ui_socket.Observing
    access.Participant(access.Operator) | access.Owner -> ui_socket.Operating
  }
  let target = result.unwrap(req.get_header(request, "x-switch-target"), "")
  let open = case req.get_header(request, "x-switch-ended") {
    Ok(_) -> fn() { Error(Nil) }
    Error(Nil) -> open
  }
  let deadline = case open() {
    Ok(until) -> [#("x-page-deadline", int.to_string(until))]
    Error(Nil) -> []
  }
  let standing = ui_socket.page_standing(attachment, ceiling, reach)
  let answer = case
    req.get_header(request, "x-resume"),
    req.get_header(request, "x-go-home")
  {
    Ok(mode), _ -> resumed(role, standing, tickets, open, target, mode)
    Error(Nil), Ok(_) ->
      case
        ui_socket.home_capability(reach, fn() {
          ui_socket.home_ticket_for(standing, tickets, open)
        })
      {
        None -> stub(289, "no capability")
        Some(ask) ->
          case ask() {
            sessions.Ticketed(path) -> stub(288, path)
            sessions.Declined(reason) -> stub(291, string.inspect(reason))
          }
      }
    Error(Nil), Error(Nil) ->
      case
        ui_socket.opened_for(role, fn() {
          ui_socket.ticket_for(standing, tickets, open, target)
        })
      {
        sessions.Ticketed(path) -> stub(290, path)
        sessions.Declined(reason) -> stub(291, string.inspect(reason))
      }
  }
  list.fold(deadline, reported(answer, reach), fn(answer, header) {
    response.set_header(answer, header.0, header.1)
  })
}

// A resume as a page asks for one, with the page socket's own gate for its role
// (`resumed_for`) in front of either way of running it: `task` is the weft run
// the page uses, and a number is the blocking steps with that wait in
// milliseconds. The answer is 290 and the ticket's address, or 291 and the
// reason, as a switch's is.
fn resumed(
  role: ui_socket.Role,
  standing: ui_socket.Standing(String),
  tickets,
  open: fn() -> Result(Int, Nil),
  target: String,
  mode: String,
) {
  let answers = process.new_subject()
  let deliver = fn(answer) { process.send(answers, answer) }
  ui_socket.resumed_for(role, deliver, fn() {
    case mode {
      "task" -> ui_socket.resume_task(standing, tickets, open, target, deliver)
      within ->
        deliver(ui_socket.resume_for(
          standing,
          tickets,
          open,
          target,
          within: result.unwrap(int.parse(within), 0),
        ))
    }
  })
  case process.receive(answers, 10_000) {
    Ok(sessions.Ticketed(path)) -> stub(290, path)
    Ok(sessions.Declined(reason)) -> stub(291, string.inspect(reason))
    Error(Nil) -> stub(298, "the task never answered")
  }
}

// The home's upgrade as a row press asks for a ticket: `ticket_for` with the
// home's standing, for the session `target` names. A request that carries
// `x-switch-ended` is asked as a home that has ended but whose socket is still
// up. The answer is as `switching`'s.
fn opening_from_home(
  tickets,
  request,
  attachment: server.HomeAttachment(String),
  ceiling,
  reach: ui_sessions.Reach,
  open: fn() -> Result(Int, Nil),
  target: String,
) {
  let open = case req.get_header(request, "x-switch-ended") {
    Ok(_) -> fn() { Error(Nil) }
    Error(Nil) -> open
  }
  let deadline = case open() {
    Ok(until) -> [#("x-page-deadline", int.to_string(until))]
    Error(Nil) -> []
  }
  let standing = ui_socket.home_standing(attachment, ceiling, reach)
  let answer = case req.get_header(request, "x-resume") {
    Ok(mode) ->
      resumed(ui_socket.Operating, standing, tickets, open, target, mode)
    Error(Nil) ->
      case ui_socket.ticket_for(standing, tickets, open, target) {
        sessions.Ticketed(path) -> stub(290, path)
        sessions.Declined(reason) -> stub(291, string.inspect(reason))
      }
  }
  list.fold(deadline, reported(answer, reach), fn(answer, header) {
    response.set_header(answer, header.0, header.1)
  })
}

// The page's upgrade as an invitation asks for one: what `ui_socket.upgrade`
// does with the role it admitted, without the Lustre component in the way.
fn inviting(
  tickets,
  request,
  attachment: server.Attachment(String),
  open: fn() -> Result(Int, Nil),
) {
  let chosen = case req.get_header(request, "x-invite-role") {
    Ok("operator") -> invites.Operator
    Ok(_) | Error(Nil) -> invites.Observer
  }
  let open = case req.get_header(request, "x-switch-ended") {
    Ok(_) -> fn() { Error(Nil) }
    Error(Nil) -> open
  }
  let ask = fn() {
    case
      ui_socket.invite_for(
        attachment,
        tickets,
        open,
        ui_socket.claim_address(request),
        chosen,
      )
    {
      invites.Minted(invitation) ->
        stub(
          292,
          string.join(
            [
              invitation.command,
              invitation.token,
              invitation.principal,
              invites.role_word(invitation.role),
              int.to_string(invitation.expires_in_ms),
            ],
            "\n",
          ),
        )
      invites.Declined(reason) -> stub(293, string.inspect(reason))
    }
  }
  case
    ui_socket.role_of(attachment),
    req.get_header(request, "x-invite-force")
  {
    ui_socket.Owning, _ -> ask()
    _, Ok(_) -> ask()
    ui_socket.Operating, Error(Nil) -> stub(294, "no capability")
    ui_socket.Observing, Error(Nil) -> stub(295, "no capability")
  }
}

// The home's upgrade as the daemon's socket asks it: the read the home
// component makes (`ui_socket.home_listing`), answered as status 280 and, one
// to a line, the principal, the ceiling the router handed over and what the
// read found. A request that carries `x-revoke-between` names a credential
// that is revoked after the first read and before a second, which is the
// home's next read after access was taken away; both answers are in the body.
fn homed(
  state_root: String,
  request,
  attachment: server.HomeAttachment(String),
  open: fn() -> Result(Int, Nil),
  ceiling: access.Role,
) {
  let read = fn() {
    case ui_socket.home_listing(attachment, open, fn(_) { Nil }) {
      home.Listed(entries) ->
        "listed " <> string.join(list.map(entries, fn(entry) { entry.id }), ",")
      home.Unread -> "unread"
      home.Closed(reason) -> "closed " <> ending.reason(reason)
    }
  }
  let first = read()
  let reads = case req.get_header(request, "x-revoke-between") {
    Ok(token) -> {
      revoke(state_root, token)
      [first, read()]
    }
    Error(Nil) -> [first]
  }
  let who = case ceiling {
    access.Operator -> "operator"
    access.Observer -> "observer"
  }
  stub(280, string.join([attachment.principal.id, who, ..reads], "\n"))
}

// Revokes the credential `token` names, as the owner's administration would.
fn revoke(state_root: String, token: String) -> Nil {
  let assert Ok(digest) =
    token
    |> bit_array.from_string
    |> bootstrap.sha256
    |> bit_array.base16_encode
    |> string.lowercase
    |> access.credential_digest
    as "the digest is valid"
  let assert Ok(store) = catalogue.open(state_root <> "/catalogue.db")
    as "fixture administration opens the durable catalogue"
  assert access.revoke_credential(store, digest) == Ok(Nil)
  assert catalogue.close(store) == Ok(Nil)
  Nil
}

fn stub(status: Int, text: String) {
  response.new(status)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(text)))
}

/// One HTTP response: its status, its headers (lowercased names), its body as
/// text where it is text, and its body's bytes.
type Answer {
  Answer(
    status: Int,
    headers: List(#(String, String)),
    body: String,
    raw: BitArray,
  )
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
  let raw = case length > 0 && status != 101 {
    True -> {
      let assert Ok(bytes) = ffi_ws.tcp_receive(socket, length, 1000)
        as "the body arrives"
      bytes
    }
    False -> <<>>
  }
  let _ = ffi_ws.tcp_close(socket)
  Answer(status, parsed, result.unwrap(bit_array.to_string(raw), ""), raw)
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
  let socket = connect_socket(port, entered, [])
  let closed = read_until_closed(socket, [])
  let _ = ffi_ws.tcp_close(socket)
  closed
}

// The handshake alone, with more request headers: a WebSocket to the page's
// socket that is open and not yet read.
fn connect_socket(port: Int, entered: Entered, more: List(#(String, String))) {
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
    <> string.concat(
      list.map(more, fn(header) { "\r\n" <> header.0 <> ": " <> header.1 }),
    )
    <> "\r\nUpgrade: websocket\r\nConnection: Upgrade"
    <> "\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="
    <> "\r\nSec-WebSocket-Version: 13\r\n\r\n"
  assert ffi_daemon_socket.send(socket, bit_array.from_string(handshake))
    == Ok(Nil)
  let head = read_head(socket, "")
  assert string.starts_with(head, "HTTP/1.1 101")
  socket
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
  ask_with(port, entered, target, [])
}

// `ask`, with more request headers.
fn ask_with(
  port: Int,
  entered: Entered,
  target: String,
  more: List(#(String, String)),
) -> Answer {
  get(port, entered.page <> "/ws?csrf-token=" <> entered.nonce, [
    host(port),
    #("cookie", "loom_ui=" <> entered.cookie),
    #("origin", "http://127.0.0.1:" <> int.to_string(port)),
    #("x-switch-target", target),
    ..more
  ])
}

// The deadline a switch answer says the asking page ends at.
fn deadline_of(answer: Answer) -> Int {
  let assert Ok(text) = list.key_find(answer.headers, "x-page-deadline")
    as "the answer carries the asking page's deadline"
  let assert Ok(until) = int.parse(text) as "the deadline is a number"
  until
}

// A page's switch to another session never ends later than the page it left:
// the ticket carries the asking page's deadline, and the page it becomes is
// given the earlier of that and its own eight hours, so a chain of switches
// is bounded by the page it began from.
pub fn a_switch_never_outlives_the_page_it_left_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let left = create_session(ready, "chain-left", 941)
    let target = create_session(ready, "chain-target", 942)
    let first = enter(port, operate(port, credential, left))
    let from_first = ask(port, first, target)
    assert from_first.status == 290
    let first_ends = deadline_of(from_first)

    let second = enter(port, from_first.body)
    let from_second = ask(port, second, left)
    assert from_second.status == 290
    assert deadline_of(from_second) <= first_ends

    let third = enter(port, from_second.body)
    assert deadline_of(ask(port, third, target)) <= first_ends

    // A link from `loom ui` is not a switch, and keeps its own eight hours.
    let fresh = enter(port, operate(port, credential, target))
    assert deadline_of(ask(port, fresh, left)) >= first_ends
  })
}

// A page that has ended but whose socket is still up mints nothing.
pub fn an_ended_page_mints_no_ticket_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let left = create_session(ready, "ended-left", 943)
    let target = create_session(ready, "ended-target", 944)
    let page = enter(port, operate(port, credential, left))
    let refused = ask_with(port, page, target, [#("x-switch-ended", "yes")])
    assert refused.status == 291
    assert refused.body == "NotHeld"
  })
}

// A principal who operates the session it is on and only observes the target
// gets an observer's page there, which cannot switch onward.
pub fn a_switch_cannot_raise_the_role_on_the_target_test() {
  fixture_with(Switching, fn(ready, port, _) {
    let left = create_session(ready, "role-left", 945)
    let target = create_session(ready, "role-target", 946)
    let operator = member(ready, "ui-mixed", left, access.Operator)
    also_holds(ready, "ui-mixed", target, access.Observer)
    let page = enter(port, operate(port, operator, left))
    let asked = ask(port, page, target)
    assert asked.status == 290
    let arrived = enter(port, asked.body)
    let refused = ask(port, arrived, left)
    assert refused.status == 291
    assert refused.body == "NotHeld"
  })
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

// --- the home (protocol-change/065) ------------------------------------------

// The reach the router read from the page's grant, as the stub's answer says.
fn reach_of(answer: Answer) -> String {
  let assert Ok(reach) = list.key_find(answer.headers, "x-page-reach")
    as "the answer says the page's reach"
  reach
}

// A press of a running session's row on the home, for `target`.
fn press_row(port: Int, home: Entered, target: String) -> Answer {
  home_socket(port, home, [#("x-switch-target", target)])
}

// A press of a session page's "Home" button.
fn press_home(
  port: Int,
  page: Entered,
  more: List(#(String, String)),
) -> Answer {
  ask_with(port, page, "", [#("x-go-home", "yes"), ..more])
}

// A row on the home mints a ticket for a page of that session, with the
// home's own ceiling and reach, so the page it becomes is a `Workspace` page.
// The home stays open, the ticket is single use, and the new page's own socket
// reports the reach it was admitted with.
pub fn a_home_row_opens_a_session_page_of_workspace_reach_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let session = create_session(ready, "row-open", 970)
    let home = enter(port, operator_home(port, credential))
    let asked = press_row(port, home, session)
    assert asked.status == 290
    assert reach_of(asked) == "workspace"
    assert string.starts_with(
      asked.body,
      "/ui/sessions/" <> session <> "?ticket=",
    )
    let page = enter(port, asked.body)
    assert open_page(port, page).status == 200
    assert open_page(port, home).status == 200
    assert exchange(port, asked.body).status == 401

    // The page the row opened was admitted as a `Workspace` page.
    assert reach_of(ask(port, page, session)) == "workspace"
  })
}

// A switch from a page a link for one session opened keeps `OneSession`: the
// page it opens draws no way home, as the ruling on handed-out links says. Only
// a home's tickets carry `Workspace`, and a page carries it onward.
pub fn a_switch_carries_the_pages_own_reach_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let left = create_session(ready, "reach-left", 971)
    let target = create_session(ready, "reach-target", 972)
    let linked = enter(port, operate(port, credential, left))
    assert reach_of(ask(port, linked, left)) == "one_session"
    let switched = ask(port, linked, target)
    assert switched.status == 290
    assert reach_of(switched) == "one_session"
    let arrived = enter(port, switched.body)
    assert reach_of(ask(port, arrived, left)) == "one_session"

    // From a home, the same switch carries `Workspace` onward.
    let home = enter(port, operator_home(port, credential))
    let opened = enter(port, press_row(port, home, left).body)
    let onward = ask(port, opened, target)
    assert onward.status == 290
    assert reach_of(onward) == "workspace"
    assert reach_of(ask(port, enter(port, onward.body), left)) == "workspace"
  })
}

// A page opened from a home may go home: the daemon mints a home ticket whose
// exchange is the home's, for the same principal. A page a link for one session
// opened has no capability to call, so the way home is not offered to it, and
// the daemon's own answer would be the same refusal to a forged call.
pub fn only_a_workspace_page_may_go_home_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let session = create_session(ready, "go-home", 973)
    let home = enter(port, operator_home(port, credential))
    let page = enter(port, press_row(port, home, session).body)
    let back = press_home(port, page, [])
    assert back.status == 288
    assert string.starts_with(back.body, "/ui/home?ticket=")
    let arrived = enter(port, back.body)
    assert string.ends_with(arrived.page, "/home")
    assert open_page(port, arrived).status == 200
    assert exchange(port, back.body).status == 401

    let linked = enter(port, operate(port, credential, session))
    let refused = press_home(port, linked, [])
    assert refused.status == 289
    assert refused.body == "no capability"
  })
}

// The way home is an observer page's one control: an observer page opened from
// an observer home has it, cannot switch to another session, and the home it
// returns to is an observer's too.
pub fn an_observers_workspace_page_goes_home_but_not_elsewhere_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let session = create_session(ready, "observed-home", 974)
    let other = create_session(ready, "observed-other", 975)
    let home = enter(port, home_link(port, credential, []))
    let page = enter(port, press_row(port, home, session).body)
    assert reach_of(ask(port, page, other)) == "workspace"
    let refused = ask(port, page, other)
    assert refused.status == 291
    assert refused.body == "NotHeld"

    let back = press_home(port, page, [])
    assert back.status == 288
    let again = enter(port, back.body)

    // The observer's home opens only observer pages.
    let reopened = enter(port, press_row(port, again, session).body)
    assert ask(port, reopened, other).status == 291
  })
}

// A chain home, session, home, session never outlives the first home: each
// ticket a page mints carries the page's deadline, and a fresh `loom ui` link
// keeps its own eight hours.
pub fn a_chain_through_a_home_ends_with_the_first_home_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let session = create_session(ready, "chain-through-home", 976)
    let first = enter(port, operator_home(port, credential))
    let opened = press_row(port, first, session)
    let first_ends = deadline_of(opened)

    let page = enter(port, opened.body)
    let back = press_home(port, page, [])
    assert back.status == 288
    assert deadline_of(back) <= first_ends

    let second = enter(port, back.body)
    let again = press_row(port, second, session)
    assert deadline_of(again) <= first_ends

    let last = enter(port, press_home(port, enter(port, again.body), []).body)
    assert deadline_of(press_row(port, last, session)) <= first_ends

    let fresh = enter(port, operator_home(port, credential))
    assert deadline_of(press_row(port, fresh, session)) >= first_ends
  })
}

// A row for a session the principal does not hold, that does not exist or that
// is not a session's identity is the same refusal, whatever frame carried it:
// the daemon makes the membership check itself, from the home's own
// credential.
pub fn a_forged_row_press_for_a_session_not_held_is_refused_test() {
  fixture_with(Switching, fn(ready, port, _) {
    let held = create_session(ready, "home-held", 977)
    let other = create_session(ready, "home-other", 978)
    let operator = member(ready, "ui-home-narrow", held, access.Operator)
    let home =
      enter(
        port,
        home_link(port, operator, [#("page", json.String("operator"))]),
      )
    list.each(
      [
        other,
        "01900000-0000-7000-8000-000000000000",
        "not a session",
        "",
      ],
      fn(target) {
        let refused = press_row(port, home, target)
        assert refused.status == 291
        assert refused.body == "NotHeld"
      },
    )
    assert press_row(port, home, held).status == 290
  })
}

// A saved session has no page to show: the home's row is text for it, and a
// forged press is refused in the reason's own word.
pub fn a_row_press_for_a_saved_session_is_refused_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let session = create_session(ready, "home-saved", 979)
    let assert Ok(_) = manager.stop_session(ready.registry, session)
      as "stop requested"
    assert poll.until(within: 2000, every: 1, attempt: fn() {
        case manager.get(ready.registry, session) {
          Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
          Ok(_) -> poll.Retry
          Error(error) -> poll.Fail(error)
        }
      })
      == poll.Answered(Nil)
    let home = enter(port, operator_home(port, credential))
    let refused = press_row(port, home, session)
    assert refused.status == 291
    assert refused.body == "NotRunning"
  })
}

// A home or a page that has ended but whose socket is still up mints nothing.
pub fn an_ended_page_mints_nothing_across_the_home_test() {
  fixture_with(Switching, fn(ready, port, _) {
    let session = create_session(ready, "home-ended", 980)
    let operator = member(ready, "ui-home-ended", session, access.Operator)
    let home =
      enter(
        port,
        home_link(port, operator, [#("page", json.String("operator"))]),
      )
    let page = enter(port, press_row(port, home, session).body)
    let ended = [#("x-switch-ended", "yes")]
    let refused = press_row_with(port, home, session, ended)
    assert refused.status == 291
    assert refused.body == "NotHeld"
    let refused = press_home(port, page, ended)
    assert refused.status == 291
    assert refused.body == "NoHome"
  })
}

// The way home is checked against the registry when it is asked for, not when
// the page opened: a credential that no longer authenticates, or whose
// principal is not the one the page says it is, is given no ticket. (A revoked
// credential's page is refused earlier still, at its next socket.)
pub fn the_way_home_is_checked_against_the_registry_test() {
  fixture(fn(ready, _, _) {
    let session = create_session(ready, "home-revoked", 981)
    let credential = member(ready, "ui-home-revoked", session, access.Operator)
    let assert Ok(tickets) =
      ui_sessions.start(ui_sessions.Settings(
        now: bootstrap.monotonic_time_ms,
        entropy: token.production_entropy(),
        ticket_ms: ui_sessions.ticket_ms,
        session_ms: ui_sessions.session_ms,
      ))
      as "the web view's tables start"
    let assert Ok(digest) =
      credential
      |> bit_array.from_string
      |> bootstrap.sha256
      |> bit_array.base16_encode
      |> string.lowercase
      |> access.credential_digest
      as "the digest is valid"
    let standing =
      ui_socket.Standing(
        registry: ready.registry,
        digest:,
        principal: "ui-home-revoked",
        ceiling: access.Operator,
        reach: ui_sessions.Workspace,
      )
    let open = fn() { Ok(bootstrap.monotonic_time_ms() + 60_000) }

    // The principal the credential authenticates as, with the page's own
    // ceiling, gets a home ticket.
    let assert sessions.Ticketed(path) =
      ui_socket.home_ticket_for(standing, tickets, open)
      as "an authenticated page may go home"
    assert string.starts_with(path, "/ui/home?ticket=")

    // The same credential under another principal's name is refused.
    assert ui_socket.home_ticket_for(
        ui_socket.Standing(..standing, principal: "someone-else"),
        tickets,
        open,
      )
      == sessions.Declined(sessions.NoHome)

    // A page that has ended is refused, and so is a revoked credential.
    assert ui_socket.home_ticket_for(standing, tickets, fn() { Error(Nil) })
      == sessions.Declined(sessions.NoHome)
    revoke(ready.state_root, credential)
    assert ui_socket.home_ticket_for(standing, tickets, open)
      == sessions.Declined(sessions.NoHome)
    assert ui_socket.ticket_for(standing, tickets, open, session)
      == sessions.Declined(sessions.NotHeld)
  })
}

fn press_row_with(
  port: Int,
  home: Entered,
  target: String,
  more: List(#(String, String)),
) -> Answer {
  home_socket(port, home, [#("x-switch-target", target), ..more])
}

// A ticket for the home, as `loom ui` with no session asks for one: a
// `ui.link` that names no session.
fn home_link(
  port: Int,
  credential: String,
  page: List(#(String, json.JsonValue)),
) -> String {
  let #(socket, _) = daemon_server_test.connect(port, credential, "/v2/control")
  let _hello = daemon_server_test.frame(socket, within_ms: 1000)
  let reply =
    daemon_server_test.send(
      socket,
      1,
      "ui.link",
      json.Object(page),
      within_ms: 1000,
    )
  let _ = ffi_ws.tcp_close(socket)
  let assert Ok(body) = field(reply, "body") as "the reply has a body"
  let assert Ok(json.String(path)) = field(body, "path") as "a link"
  path
}

fn operator_home(port: Int, credential: String) -> String {
  home_link(port, credential, [#("page", json.String("operator"))])
}

fn home_socket(port: Int, entered: Entered, more) -> Answer {
  get(port, entered.page <> "/ws?csrf-token=" <> entered.nonce, [
    host(port),
    #("cookie", "loom_ui=" <> entered.cookie),
    #("origin", "http://127.0.0.1:" <> int.to_string(port)),
    ..more
  ])
}

// The three routes of the home work in order: the ticket exchange, the keyed
// page, and the socket, which the router hands to the home's upgrade with the
// principal and the ceiling the ticket was minted with. The exchange's cookie
// is scoped to the page's key as a session page's is.
pub fn a_home_ticket_becomes_a_keyed_home_once_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "home-one", 960)
    let path = operator_home(port, credential)
    assert string.starts_with(path, "/ui/home?ticket=")

    // The exchange's checks are the session exchange's.
    assert get(port, path, [host(port), #("sec-fetch-site", "cross-site")]).status
      == 403
    let answer = exchange(port, path)
    let page = entered(answer)
    assert string.ends_with(page.page, "/home")
    let assert Ok(set) = list.key_find(answer.headers, "set-cookie")
      as "the cookie is set"
    assert string.contains(set, "HttpOnly")
    assert string.contains(set, "SameSite=Strict")
    assert string.ends_with(
      set,
      "Path=" <> string.replace(page.page, "/home", ""),
    )
    assert exchange(port, path).status == 401

    // The page is the home's shell, which names no session.
    let opened = open_page(port, page)
    assert opened.status == 200
    assert string.contains(opened.body, "Loom · Home")
    assert !string.contains(opened.body, page.nonce)
    assert !string.contains(opened.body, session)
    assert referrer_policy(opened) == Ok("no-referrer")

    // The socket needs the host, the origin, the cookie, the key and the
    // nonce, in that order.
    let socket = page.page <> "/ws?csrf-token=" <> page.nonce
    let with_cookie = #("cookie", "loom_ui=" <> page.cookie)
    assert get(port, socket, [#("host", "evil.example"), with_cookie]).status
      == 403
    assert get(port, socket, [host(port), with_cookie]).status == 403
    assert home_socket(port, Entered(..page, nonce: "forged"), []).status == 403
    assert get(port, page.page <> "/ws", [
        host(port),
        with_cookie,
        #("origin", "http://127.0.0.1:" <> int.to_string(port)),
      ]).status
      == 403
    assert get(port, page.page <> "/ws?csrf-token=" <> page.nonce, [
        host(port),
        #("origin", "http://127.0.0.1:" <> int.to_string(port)),
      ]).status
      == 401
    let upgraded = home_socket(port, page, [])
    assert upgraded.status == 280
    let assert [_, "operator", listed] = string.split(upgraded.body, "\n")
    assert listed == "listed " <> session
  })
}

// A ticket is honoured only at the exchange of its own scope: a session's at
// the home and a home's at a session's are each refused and spent, and no
// cookie is set for either.
pub fn a_ticket_of_the_other_scope_is_refused_and_spent_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "scopes", 961)
    let for_session = link(port, credential, session)
    let for_home = home_link(port, credential, [])
    let home_at_session =
      "/ui/sessions/" <> session <> "?ticket=" <> after_ticket(for_home)
    let session_at_home = "/ui/home?ticket=" <> after_ticket(for_session)

    let refused = exchange(port, home_at_session)
    assert refused.status == 403
    assert list.key_find(refused.headers, "set-cookie") == Error(Nil)
    let refused = exchange(port, session_at_home)
    assert refused.status == 403
    assert list.key_find(refused.headers, "set-cookie") == Error(Nil)

    // Both are spent: neither opens its own exchange afterwards.
    assert exchange(port, for_home).status == 401
    assert exchange(port, for_session).status == 401
  })
}

fn after_ticket(path: String) -> String {
  let assert Ok(#(_, ticket)) = string.split_once(path, "?ticket=")
    as "a link carries a ticket"
  ticket
}

// A home page's cookie opens no session page and a session page's cookie
// opens no home, under their own keys or each other's.
pub fn a_cookie_opens_only_the_scope_it_was_issued_for_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "cookies", 962)
    let home_page = enter(port, home_link(port, credential, []))
    let session_page = enter(port, link(port, credential, session))
    let home_key = string.replace(home_page.page, "/home", "")
    let session_key =
      string.replace(session_page.page, "/sessions/" <> session, "")

    let wrong_scope = fn(path, cookie) {
      get(port, path, [
        host(port),
        #("sec-fetch-site", "same-origin"),
        #("cookie", "loom_ui=" <> cookie),
      ]).status
    }
    assert wrong_scope(home_key <> "/sessions/" <> session, home_page.cookie)
      == 403
    assert wrong_scope(session_key <> "/home", session_page.cookie) == 403
    assert wrong_scope(session_key <> "/home", home_page.cookie) == 401
    assert open_page(port, home_page).status == 200
    assert open_page(port, session_page).status == 200

    // The home's socket is refused to a session page, and a session's socket
    // to a home page, before any upgrade.
    assert get(
        port,
        home_key
          <> "/sessions/"
          <> session
          <> "/ws?csrf-token="
          <> home_page.nonce,
        [
          host(port),
          #("cookie", "loom_ui=" <> home_page.cookie),
          #("origin", "http://127.0.0.1:" <> int.to_string(port)),
        ],
      ).status
      == 403
    assert get(
        port,
        session_key <> "/home/ws?csrf-token=" <> session_page.nonce,
        [
          host(port),
          #("cookie", "loom_ui=" <> session_page.cookie),
          #("origin", "http://127.0.0.1:" <> int.to_string(port)),
        ],
      ).status
      == 403
  })
}

pub fn the_home_page_needs_a_first_party_navigation_test() {
  fixture(fn(_, port, credential) {
    let page = enter(port, home_link(port, credential, []))
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
    assert get(port, page.page, [host(port)]).status == 403
    assert get(port, "/ui/home", [host(port)]).status == 404
  })
}

// The ceiling the ticket was minted with reaches the home's upgrade: a link
// asked for with no page is an observer's, as `ui.link`'s default says.
pub fn the_home_socket_carries_the_tickets_ceiling_test() {
  fixture(fn(_, port, credential) {
    let operator = enter(port, operator_home(port, credential))
    let observer = enter(port, home_link(port, credential, []))
    let ceiling_of = fn(page) {
      let assert [_, ceiling, ..] =
        string.split(home_socket(port, page, []).body, "\n")
      ceiling
    }
    assert ceiling_of(operator) == "operator"
    assert ceiling_of(observer) == "observer"
  })
}

// A member's home lists only their memberships, and not the sessions the owner
// holds that they do not.
pub fn a_members_home_lists_only_their_sessions_test() {
  fixture(fn(ready, port, credential) {
    let held = create_session(ready, "member-held", 963)
    let other = create_session(ready, "member-other", 964)
    let member = member(ready, "home-member", held, access.Operator)
    let as_member = enter(port, operator_home(port, member))
    let body = home_socket(port, as_member, []).body
    assert string.contains(body, "listed " <> held)
    assert !string.contains(body, other)

    let as_owner = enter(port, operator_home(port, credential))
    let owner_body = home_socket(port, as_owner, []).body
    assert string.contains(owner_body, held)
    assert string.contains(owner_body, other)
  })
}

// A revoked credential's home is refused at its next request, and a home
// that is already open learns it at its next read, which answers `Closed`.
pub fn a_revoked_credential_ends_the_home_test() {
  fixture(fn(ready, port, _) {
    let session = create_session(ready, "home-revoked", 965)
    let credential =
      member(ready, "home-revoked-member", session, access.Operator)
    let page = enter(port, operator_home(port, credential))
    assert open_page(port, page).status == 200

    let read = home_socket(port, page, [#("x-revoke-between", credential)])
    assert read.status == 280
    let assert [_, _, first, second] = string.split(read.body, "\n")
    assert first == "listed " <> session
    assert second == "closed " <> ending.reason(ending.AccessRevoked)

    let reloaded = open_page(port, page)
    assert reloaded.status == 401
    assert string.contains(
      reloaded.body,
      ending.home_headline(ending.AccessRevoked),
    )
    assert string.contains(reloaded.body, "subject=\"link\" text=\"loom ui\"")
    assert !string.contains(reloaded.body, "--session")
    assert home_socket(port, page, []).status == 401
  })
}

// The home's own socket, not the stub: a home whose credential is revoked
// after the router admitted it reads the catalogue, finds no such credential,
// draws the home's ending and closes the socket.
pub fn a_revoked_credential_closes_the_real_home_socket_test() {
  fixture_with(Real, fn(ready, port, _) {
    let session = create_session(ready, "home-real", 967)
    let credential = member(ready, "home-real-member", session, access.Operator)
    let page = enter(port, operator_home(port, credential))
    let socket = connect_socket(port, page, [#("x-revoke-between", credential)])
    let closed = read_until_closed(socket, [])
    let _ = ffi_ws.tcp_close(socket)
    assert closed.code != 0
    assert string.contains(
      string.join(closed.texts, "\n"),
      ending.home_headline(ending.AccessRevoked),
    )
  })
}

// A home that has been replaced by a fifth is the oldest's end, and a home
// beyond the cap leaves the principal's session pages open.
pub fn homes_are_capped_apart_from_session_pages_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "home-cap", 966)
    let session_page = enter(port, link(port, credential, session))
    let homes =
      list.map(list.repeat(Nil, ui_sessions.max_pages + 1), fn(_) {
        enter(port, home_link(port, credential, []))
      })
    let assert [oldest, ..rest] = homes
    assert open_page(port, oldest).status == 401
    list.each(rest, fn(page) {
      assert open_page(port, page).status == 200
    })
    assert open_page(port, session_page).status == 200
  })
}

// Without `--ui` there is no home to link to.
pub fn without_ui_a_home_link_is_refused_test() {
  daemon_server_test.fixture(fn(_, _, port, credential) {
    assert get(port, "/ui/home?ticket=t", [host(port)]).status == 404
    let #(socket, _) =
      daemon_server_test.connect(port, credential, "/v2/control")
    let _hello = daemon_server_test.frame(socket, within_ms: 1000)
    let refused =
      daemon_server_test.send(
        socket,
        1,
        "ui.link",
        json.Object([]),
        within_ms: 1000,
      )
    let assert Ok(refusal) = field(refused, "body") as "a refusal body"
    assert field(refusal, "code") == Ok(json.String("unavailable"))
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

// A malformed session identity is refused, and never read as a request for
// the home.
pub fn a_malformed_session_is_not_a_home_link_test() {
  fixture(fn(_, port, credential) {
    let #(socket, _) =
      daemon_server_test.connect(port, credential, "/v2/control")
    let _hello = daemon_server_test.frame(socket, within_ms: 1000)
    let refused =
      daemon_server_test.send(
        socket,
        1,
        "ui.link",
        json.Object([#("session_id", json.String("not a session"))]),
        within_ms: 1000,
      )
    let assert Ok(refusal) = field(refused, "body") as "a refusal body"
    assert field(refusal, "code") == Ok(json.String("bad_request"))
    let _ = ffi_ws.tcp_close(socket)
    Nil
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

// --- images (protocol-change/051, the addendum on images) ------------------

const png_bytes = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3>>

// The images the stubbed page's reader knows, as the page socket's component
// would answer for a lane that drew them: a PNG, an SVG declared as such, an
// HTML document declared as a PNG, and a PNG one byte over the limit's text.
fn held(ref: String, position: Int) -> Result(transcript_image.Image, Nil) {
  case ref, position {
    "1.0", 0 ->
      Ok(transcript_image.Image(
        "image/png",
        bit_array.base64_encode(png_bytes, True),
      ))
    "1.0", 1 ->
      Ok(transcript_image.Image(
        "image/svg+xml",
        bit_array.base64_encode(<<"<svg><script/></svg>":utf8>>, True),
      ))
    "1.0", 2 ->
      Ok(transcript_image.Image(
        "image/png",
        bit_array.base64_encode(<<"<html><script/></html>":utf8>>, True),
      ))
    "2.0", 0 ->
      Ok(transcript_image.Image("image/png", string.repeat("A", 28_000_000)))
    _, _ -> Error(Nil)
  }
}

// An image of the page, asked for as the page's own `<img>` asks.
fn picture(port: Int, page: Entered, ref: String, position: String) -> Answer {
  get(port, page.page <> "/image/" <> ref <> "/" <> position, [
    host(port),
    #("sec-fetch-site", "same-origin"),
    #("cookie", "loom_ui=" <> page.cookie),
  ])
}

// A page whose socket has opened, so its reader is registered.
fn opened(port: Int, path: String) -> Entered {
  let page = enter(port, path)
  let status = open_socket(port, page, page.nonce).status
  assert status == 298 || status == 299
  page
}

pub fn a_page_reads_its_image_with_the_headers_of_the_view_test() {
  fixture_with(Pictured, fn(ready, port, credential) {
    let session = create_session(ready, "pictures", 940)
    let page = opened(port, operate(port, credential, session))
    let answer = picture(port, page, "1.0", "0")
    assert answer.status == 200
    assert answer.raw == png_bytes
    assert list.key_find(answer.headers, "content-type") == Ok("image/png")
    assert list.key_find(answer.headers, "x-content-type-options")
      == Ok("nosniff")
    assert list.key_find(answer.headers, "cache-control") == Ok("no-store")
    assert list.key_find(answer.headers, "referrer-policy") == Ok("no-referrer")
    assert list.key_find(answer.headers, "content-security-policy")
      == Ok(policy(port))
  })
}

// An image is read for either role: an observer's page draws pictures too,
// and neither reader can name anything the page did not draw.
pub fn an_observers_page_reads_its_image_too_test() {
  fixture_with(Pictured, fn(ready, port, credential) {
    let session = create_session(ready, "watchers", 941)
    let observer = opened(port, link(port, credential, session))
    assert picture(port, observer, "1.0", "0").status == 200
    let operator = opened(port, operate(port, credential, session))
    assert picture(port, operator, "1.0", "0").status == 200
  })
}

pub fn an_image_is_unknown_until_the_pages_socket_has_opened_test() {
  fixture_with(Pictured, fn(ready, port, credential) {
    let session = create_session(ready, "early", 942)
    let page = enter(port, operate(port, credential, session))
    let answer = picture(port, page, "1.0", "0")
    assert answer.status == 404
    assert answer.raw == <<"unknown image":utf8>>
  })
}

// Each page reads its own component's images. A second page of the same
// principal and session whose socket never opened has no reader, however the
// first page's readers answer.
pub fn a_page_cannot_read_through_another_pages_reader_test() {
  fixture_with(Pictured, fn(ready, port, credential) {
    let session = create_session(ready, "twins", 943)
    let first = opened(port, operate(port, credential, session))
    let second = enter(port, operate(port, credential, session))
    assert picture(port, first, "1.0", "0").status == 200
    assert picture(port, second, "1.0", "0").status == 404
    assert get(port, first.page <> "/image/1.0/0", [
        host(port),
        #("sec-fetch-site", "same-origin"),
        #("cookie", "loom_ui=" <> second.cookie),
      ]).status
      == 401
  })
}

pub fn the_daemon_serves_only_what_it_has_checked_test() {
  fixture_with(Pictured, fn(ready, port, credential) {
    let session = create_session(ready, "checked", 944)
    let page = opened(port, operate(port, credential, session))

    // The page drew nothing at this name or place.
    assert picture(port, page, "9.0", "0").status == 404
    assert picture(port, page, "1.0", "7").status == 404

    // A non-raster type, however declared, and bytes that are not the type
    // they were declared as.
    assert picture(port, page, "1.0", "1").status == 415
    assert picture(port, page, "1.0", "2").status == 415

    // More than the terminal's own limit.
    assert picture(port, page, "2.0", "0").status == 413
  })
}

pub fn a_malformed_image_address_is_not_routed_test() {
  fixture_with(Pictured, fn(ready, port, credential) {
    let session = create_session(ready, "shapes", 945)
    let page = opened(port, operate(port, credential, session))
    assert picture(port, page, "1.0", "-1").status == 404
    assert picture(port, page, "1.0", "x").status == 404
    assert picture(port, page, "1.0", "9999").status == 404
    assert picture(port, page, "..%2Fx", "0").status == 404
    assert picture(port, page, "a.b", "0").status == 404
    assert picture(port, page, string.repeat("1", 49), "0").status == 404
  })
}

pub fn an_image_needs_the_pages_own_cookie_key_and_session_test() {
  fixture_with(Pictured, fn(ready, port, credential) {
    let session = create_session(ready, "guarded", 946)
    let elsewhere = create_session(ready, "elsewhere", 947)
    let page = opened(port, operate(port, credential, session))
    let other = opened(port, operate(port, credential, elsewhere))
    let address = page.page <> "/image/1.0/0"
    let same_origin = #("sec-fetch-site", "same-origin")

    // No cookie, a planted one, and another page's.
    assert get(port, address, [host(port), same_origin]).status == 401
    assert get(port, address, [
        host(port),
        same_origin,
        #("cookie", "loom_ui=planted"),
      ]).status
      == 401
    assert get(port, address, [
        host(port),
        same_origin,
        #("cookie", "loom_ui=" <> other.cookie),
      ]).status
      == 401

    // The page's own key with another session's identity in the path.
    let crossed =
      string.replace(page.page, session, elsewhere) <> "/image/1.0/0"
    assert get(port, crossed, [
        host(port),
        same_origin,
        #("cookie", "loom_ui=" <> page.cookie),
      ]).status
      == 403

    // A host that is not loopback.
    assert get(port, address, [
        #("host", "evil.example"),
        same_origin,
        #("cookie", "loom_ui=" <> page.cookie),
      ]).status
      == 403
  })
}

// Another page cannot have the browser fetch the person's images: the fetch
// must be this origin's own, or one the person opened from outside a page.
pub fn an_image_is_only_a_fetch_of_this_origin_test() {
  fixture_with(Pictured, fn(ready, port, credential) {
    let session = create_session(ready, "origins", 948)
    let page = opened(port, operate(port, credential, session))
    let address = page.page <> "/image/1.0/0"
    let cookie = #("cookie", "loom_ui=" <> page.cookie)
    let with = fn(site) {
      get(port, address, [host(port), #("sec-fetch-site", site), cookie])
    }
    assert with("same-origin").status == 200
    assert with("none").status == 200
    assert with("same-site").status == 403
    assert with("cross-site").status == 403
    assert get(port, address, [host(port), cookie]).status == 403
  })
}

pub fn an_expired_page_reads_no_image_test() {
  fixture_lasting(Pictured, 1500, fn(ready, port, credential) {
    let session = create_session(ready, "expiring", 949)
    let page = opened(port, operate(port, credential, session))
    assert picture(port, page, "1.0", "0").status == 200
    assert poll.until(within: 5000, every: 100, attempt: fn() {
        case picture(port, page, "1.0", "0").status {
          401 -> poll.Done(Nil)
          _ -> poll.Retry
        }
      })
      == poll.Answered(Nil)
  })
}

pub fn a_revoked_credential_reads_no_image_test() {
  fixture_with(Pictured, fn(ready, port, _) {
    let session = create_session(ready, "revoked-pictures", 950)
    let credential = member(ready, "ui-picture", session, access.Operator)
    let page = opened(port, operate(port, credential, session))
    assert picture(port, page, "1.0", "0").status == 200

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
    assert picture(port, page, "1.0", "0").status == 401
  })
}

pub fn without_ui_the_image_route_does_not_exist_test() {
  daemon_server_test.fixture(fn(_, _, port, _) {
    let session = "0198c0de-0000-7000-8000-000000000001"
    assert get(port, "/ui/p/k/sessions/" <> session <> "/image/1.0/0", [
        host(port),
        #("sec-fetch-site", "same-origin"),
      ]).status
      == 404
  })
}

// --- inviting from an owner's page (protocol-change/051, the addendum) --------

// A session that is shared (`SessionOnly`) and resident, which is the only
// kind the daemon lets anyone else into.
fn create_shared_session(
  ready: root.Ready(String),
  key: String,
  seed: Int,
) -> String {
  let assert Ok(created) =
    manager.create_scoped(
      ready.registry,
      manager.Creation(key, ready.state_root, key, ""),
      directory: ready.sessions_directory,
      generator: ids.generator(clock.fixed(0), seed),
      scope: domain.SessionOnly,
      configuration: "",
    )
    as "the shared session is created"
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

// What an invitation answer carries, one field to a line.
type Minted {
  Minted(
    command: String,
    token: String,
    principal: String,
    role: String,
    expires_in_ms: Int,
  )
}

fn minted(answer: Answer) -> Minted {
  assert answer.status == 292
  let assert [command, token, principal, role, expires] =
    string.split(answer.body, "\n")
    as "an invitation is five lines"
  let assert Ok(expires_in_ms) = int.parse(expires) as "a lifetime"
  Minted(command:, token:, principal:, role:, expires_in_ms:)
}

// The page's socket as an invitation asks for one, for the role named.
fn invite(port: Int, entered: Entered, role: String) -> Answer {
  invite_with(port, entered, role, [])
}

fn invite_with(
  port: Int,
  entered: Entered,
  role: String,
  more: List(#(String, String)),
) -> Answer {
  get(port, entered.page <> "/ws?csrf-token=" <> entered.nonce, [
    host(port),
    #("cookie", "loom_ui=" <> entered.cookie),
    #("origin", "http://127.0.0.1:" <> int.to_string(port)),
    #("x-invite-role", role),
    ..more
  ])
}

fn catalogue_rows(
  state_root: String,
  query: String,
  with: List(sqlight.Value),
) {
  let assert Ok(db) = sqlight.open(state_root <> "/catalogue.db")
    as "a read connection opens"
  let assert Ok(rows) =
    sqlight.query(
      query,
      on: db,
      with:,
      expecting: decode.at([0], decode.string),
    )
    as "the catalogue answers"
  assert sqlight.close(db) == Ok(Nil)
  rows
}

fn members(state_root: String) -> List(String) {
  catalogue_rows(
    state_root,
    "SELECT principal_id FROM access_principals WHERE kind = 'member' ORDER BY principal_id",
    [],
  )
}

fn role_in(
  state_root: String,
  principal: String,
  session: String,
) -> List(String) {
  catalogue_rows(
    state_root,
    "SELECT role FROM access_memberships WHERE principal_id = ? AND session_id = ?",
    [sqlight.text(principal), sqlight.text(session)],
  )
}

fn grants_of(state_root: String, principal: String) -> List(String) {
  catalogue_rows(
    state_root,
    "SELECT session_id FROM access_memberships WHERE principal_id = ?",
    [sqlight.text(principal)],
  )
}

// An owner's operator page asks the daemon to invite and is given the same
// claim `loomd access invite` makes: a principal the daemon named, a member
// role in this session and no other, an open claim that lives an hour, and a
// command that names this daemon's loopback address and not the token.
pub fn an_owners_operator_page_invites_into_its_own_session_test() {
  fixture_with(Inviting, fn(ready, port, credential) {
    let session = create_shared_session(ready, "invite-one", 951)
    let other = create_shared_session(ready, "invite-two", 952)
    let page = enter(port, operate(port, credential, session))
    let answer = minted(invite(port, page, "observer"))

    assert claim.validate_token(answer.token) == Ok(Nil)
    assert string.starts_with(answer.principal, "guest-")
    assert string.length(answer.principal) == 14
    assert answer.role == "observer"
    assert answer.expires_in_ms == 3_600_000
    assert answer.command
      == "loom claim --addr ws://127.0.0.1:"
      <> int.to_string(port)
      <> "/v2/control"
    assert !string.contains(answer.command, "loomclaim_")

    // The membership is this session's alone, at the role asked for.
    assert role_in(ready.state_root, answer.principal, session) == ["observer"]
    assert grants_of(ready.state_root, answer.principal) == [session]
    assert role_in(ready.state_root, answer.principal, other) == []

    // The claim is open and expires an hour from now, on the wall clock.
    let expiry =
      catalogue_rows(
        ready.state_root,
        "SELECT CAST(expires_at_ms AS TEXT) FROM access_claims WHERE principal_id = ? AND state = 'open'",
        [sqlight.text(answer.principal)],
      )
    let assert [text] = expiry as "one open claim"
    let assert Ok(expires_at) = int.parse(text) as "an instant"
    let remaining = expires_at - bootstrap.system_time_ms()
    assert remaining > 3_500_000 && remaining <= 3_600_000
  })
}

// The owner may pick operator, and the role reaches the catalogue as asked.
// Owner is not a role the control has, so there is nothing to forge.
pub fn the_owner_may_invite_an_operator_test() {
  fixture_with(Inviting, fn(ready, port, credential) {
    let session = create_shared_session(ready, "invite-role", 953)
    let page = enter(port, operate(port, credential, session))
    let answer = minted(invite(port, page, "operator"))
    assert answer.role == "operator"
    assert role_in(ready.state_root, answer.principal, session) == ["operator"]

    // Anything else a header says is the default, an observer.
    let default = minted(invite(port, page, "owner"))
    assert default.role == "observer"
    assert role_in(ready.state_root, default.principal, session) == ["observer"]
  })
}

// Which pages the capability is given to, decided from the router's own
// admission: only an operator's page of the owner's principal. An owner who
// asked for an observer's page, a member operator and a member observer get
// none.
pub fn only_an_owners_operator_page_is_offered_the_capability_test() {
  fixture_with(Inviting, fn(ready, port, credential) {
    let session = create_shared_session(ready, "invite-offer", 954)
    let operator = member(ready, "ui-op", session, access.Operator)
    let watcher = member(ready, "ui-watch", session, access.Observer)

    let owning = enter(port, operate(port, credential, session))
    assert invite(port, owning, "observer").status == 292
    let owner_watching = enter(port, link(port, credential, session))
    assert invite(port, owner_watching, "observer").status == 295
    let operating = enter(port, operate(port, operator, session))
    assert invite(port, operating, "observer").status == 294

    // A member who asked for an operator's page only observes.
    let watching = enter(port, operate(port, watcher, session))
    assert invite(port, watching, "observer").status == 295

    // Only the one invitation was made.
    assert list.length(members(ready.state_root)) == 3
  })
}

// The daemon refuses again if the capability reached a page it was not meant
// for, by the principal and never by the page: a member operator's page that
// asked anyway is `NotOwner`, and nothing is made.
pub fn the_daemon_refuses_a_member_that_reaches_it_anyway_test() {
  fixture_with(Inviting, fn(ready, port, _) {
    let session = create_shared_session(ready, "invite-member", 955)
    let operator = member(ready, "ui-forced", session, access.Operator)
    let page = enter(port, operate(port, operator, session))
    let before = members(ready.state_root)
    let refused =
      invite_with(port, page, "operator", [#("x-invite-force", "1")])
    assert refused.status == 293
    assert refused.body == "NotOwner"
    assert members(ready.state_root) == before
  })
}

// A page that has ended but whose socket is still up invites nobody.
pub fn an_ended_page_invites_nobody_test() {
  fixture_with(Inviting, fn(ready, port, credential) {
    let session = create_shared_session(ready, "invite-ended", 956)
    let page = enter(port, operate(port, credential, session))
    let before = members(ready.state_root)
    let refused =
      invite_with(port, page, "observer", [#("x-switch-ended", "yes")])
    assert refused.status == 293
    assert refused.body == "NotOwner"
    assert members(ready.state_root) == before
  })
}

// A session that still shares its history with its workspace is not shared
// with anyone, and the daemon says how to change that. A refusal that made
// nothing costs none of the credential's invitations, so the owner who hit it
// three times can still invite once the session is isolated.
pub fn a_session_that_is_not_shared_is_refused_and_costs_nothing_test() {
  fixture_with(Inviting, fn(ready, port, credential) {
    let private = create_session(ready, "invite-private", 957)
    let shared = create_shared_session(ready, "invite-shared", 958)
    let before = members(ready.state_root)
    let private_page = enter(port, operate(port, credential, private))
    list.each(list.repeat(Nil, 5), fn(_) {
      let refused = invite(port, private_page, "observer")
      assert refused.status == 293
      assert refused.body == "NotIsolated"
    })
    assert members(ready.state_root) == before

    let shared_page = enter(port, operate(port, credential, shared))
    assert invite(port, shared_page, "observer").status == 292
  })
}

// The limit is the credential's: `ui_sessions.invite_limit` invitations from
// any of its pages in the window, and the next is `TooMany` on the same page,
// on a second page of the same session, and on a page of another session.
pub fn the_limit_is_the_credentials_across_pages_test() {
  fixture_with(Inviting, fn(ready, port, credential) {
    let first = create_shared_session(ready, "limit-one", 959)
    let second = create_shared_session(ready, "limit-two", 960)
    let page = enter(port, operate(port, credential, first))
    list.each(list.repeat(Nil, ui_sessions.invite_limit), fn(_) {
      assert invite(port, page, "observer").status == 292
    })
    let made = members(ready.state_root)
    assert list.length(made) == ui_sessions.invite_limit

    let refused = invite(port, page, "observer")
    assert refused.status == 293
    assert refused.body == "TooMany"

    // A fresh page for the same session, and a page of another session,
    // start with nothing left.
    let again = enter(port, operate(port, credential, first))
    assert invite(port, again, "observer").body == "TooMany"
    let elsewhere = enter(port, operate(port, credential, second))
    assert invite(port, elsewhere, "operator").body == "TooMany"
    assert members(ready.state_root) == made
  })
}

// The claim an invitation carries is real: an invitee redeems it once on
// `/v2/claim`, and the daemon keeps only its digest. Neither the token nor
// the invitee's credential is in any file under the state root.
pub fn the_claim_redeems_and_only_its_digest_is_kept_test() {
  fixture_with(Inviting, fn(ready, port, credential) {
    let session = create_shared_session(ready, "invite-claim", 961)
    let page = enter(port, operate(port, credential, session))
    let answer = minted(invite(port, page, "observer"))
    let invitee = claim.random_credential()
    let redeemed =
      daemon_claim_test.redeem(port, answer.token, claim.digest(invitee))
    let assert json.Object(fields) = redeemed as "a reply"
    assert list.key_find(fields, "event")
      == Ok(json.String("credentials.claim"))

    // A second binding with another credential is refused: a claim is single
    // use.
    let other = claim.digest(claim.random_credential())
    let assert json.Object(refusal) =
      daemon_claim_test.redeem(port, answer.token, other)
      as "a refusal"
    assert list.key_find(refusal, "event") == Ok(json.String("error"))

    let assert Ok(files) = simplifile.get_files(ready.state_root)
      as "the state root is readable"
    list.each(files, fn(path) {
      let assert Ok(bytes) = simplifile.read_bits(path) as "a state file reads"
      assert !holds(bytes, bit_array.from_string(answer.token))
      assert !holds(bytes, bit_array.from_string(invitee))
    })
  })
}

fn holds(haystack: BitArray, needle: BitArray) -> Bool {
  let size = bit_array.byte_size(needle)
  holds_from(haystack, needle, size, 0, bit_array.byte_size(haystack) - size)
}

fn holds_from(haystack, needle, size, offset, last) -> Bool {
  case offset > last {
    True -> False
    False ->
      case bit_array.slice(haystack, offset, size) == Ok(needle) {
        True -> True
        False -> holds_from(haystack, needle, size, offset + 1, last)
      }
  }
}

// --- opening a saved session (protocol-change/065, the third pull request) ----

// Stops `session` and waits until the registry says it is saved.
fn saved(ready: root.Ready(String), session: String) -> Nil {
  let assert Ok(_) = manager.stop_session(ready.registry, session)
    as "stop requested"
  assert poll.until(within: 2000, every: 1, attempt: fn() {
      case manager.get(ready.registry, session) {
        Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
    == poll.Answered(Nil)
}

// Whether the registry holds `session` as saved.
fn is_saved(ready: root.Ready(String), session: String) -> Bool {
  case manager.get(ready.registry, session) {
    Ok(manager.View(status: manager.Saved, ..)) -> True
    _ -> False
  }
}

// A page's standing for the member `name`, whose credential `member` made, with
// a fresh table of tickets to mint into.
fn standing_of(
  ready: root.Ready(String),
  name: String,
  ceiling: access.Role,
) -> #(ui_socket.Standing(String), ui_sessions.Sessions) {
  let assert Ok(tickets) =
    ui_sessions.start(ui_sessions.Settings(
      now: bootstrap.monotonic_time_ms,
      entropy: token.production_entropy(),
      ticket_ms: ui_sessions.ticket_ms,
      session_ms: ui_sessions.session_ms,
    ))
    as "the web view's tables start"
  let assert Ok(digest) =
    { name <> "-token" }
    |> bit_array.from_string
    |> bootstrap.sha256
    |> bit_array.base16_encode
    |> string.lowercase
    |> access.credential_digest
    as "the digest is valid"
  #(
    ui_socket.Standing(
      registry: ready.registry,
      digest:,
      principal: name,
      ceiling:,
      reach: ui_sessions.Workspace,
    ),
    tickets,
  )
}

fn page_open() -> Result(Int, Nil) {
  Ok(bootstrap.monotonic_time_ms() + 60_000)
}

// The steps of `resume_for`, one at a time, each against the real registry: an
// operator opens a saved session and is given a ticket for its page, and the
// registry then holds the session as resident. A resident session resumes too,
// since the open is idempotent.
pub fn an_operator_resumes_a_saved_session_and_is_minted_a_ticket_test() {
  fixture(fn(ready, _, _) {
    let session = create_session(ready, "resume-ok", 1001)
    let _ = member(ready, "ui-resumer", session, access.Operator)
    let #(standing, tickets) = standing_of(ready, "ui-resumer", access.Operator)
    saved(ready, session)
    let assert sessions.Ticketed(path) =
      ui_socket.resume_for(standing, tickets, page_open, session, within: 5000)
      as "the session opens and a ticket is minted"
    assert string.starts_with(path, "/ui/sessions/" <> session <> "?ticket=")
    assert is_saved(ready, session) == False
    assert result.is_ok(manager.resolve(ready.registry, session))

    // Resident already: the open is idempotent, so the same call mints again.
    let assert sessions.Ticketed(again) =
      ui_socket.resume_for(standing, tickets, page_open, session, within: 5000)
      as "a resident session resumes too"
    assert string.starts_with(again, "/ui/sessions/" <> session <> "?ticket=")
  })
}

// Each refusal opens nothing: the session is as saved afterwards as it was.
pub fn a_resume_refuses_and_opens_nothing_test() {
  fixture(fn(ready, _, _) {
    let held = create_session(ready, "resume-held", 1002)
    saved(ready, held)
    let watched = create_session(ready, "resume-watched", 1003)
    saved(ready, watched)
    let other = create_session(ready, "resume-other", 1004)
    saved(ready, other)
    let _ = member(ready, "ui-refused", held, access.Operator)
    also_holds(ready, "ui-refused", watched, access.Observer)
    let #(standing, tickets) = standing_of(ready, "ui-refused", access.Operator)
    let resume = fn(standing, open, target) {
      ui_socket.resume_for(standing, tickets, open, target, within: 2000)
    }

    // An observer member is told to ask an operator, as the control command's
    // own check refuses, and the session stays saved.
    assert resume(standing, page_open, watched)
      == sessions.Declined(sessions.NotOperator)

    // A session the principal holds nothing in, one that does not exist and
    // text that is no identity are the same refusal.
    list.each(
      [other, "01900000-0000-7000-8000-000000000000", "not a session", ""],
      fn(target) {
        assert resume(standing, page_open, target)
          == sessions.Declined(sessions.NotHeld)
      },
    )

    // A page minted to read opens nothing, though its principal operates the
    // session, and a page that has ended asks nothing.
    assert resume(
        ui_socket.Standing(..standing, ceiling: access.Observer),
        page_open,
        held,
      )
      == sessions.Declined(sessions.NotHeld)
    assert resume(standing, fn() { Error(Nil) }, held)
      == sessions.Declined(sessions.NotHeld)

    assert is_saved(ready, held)
    assert is_saved(ready, watched)
    assert is_saved(ready, other)
  })
}

// A session that is not resident within the wait is refused in the fixed words,
// and the refusal minted nothing: a later exchange of any ticket would find
// none for it.
pub fn an_open_that_outlasts_the_wait_mints_nothing_test() {
  fixture(fn(ready, _, _) {
    let session = create_session(ready, "slow-wait", 1005)
    let _ = member(ready, "ui-slow", session, access.Operator)
    let #(standing, tickets) = standing_of(ready, "ui-slow", access.Operator)
    saved(ready, session)
    assert ui_socket.resume_for(
        standing,
        tickets,
        page_open,
        session,
        within: 200,
      )
      == sessions.Declined(sessions.NotOpened)
    assert sessions.reason_words(sessions.NotOpened)
      == "That session did not open. Resume it from a terminal."
  })
}

// The wait runs in a task of its own: the call that starts it returns before
// the slow session has opened, and the answer arrives afterwards from the task,
// as the message the page's component is waiting for.
pub fn the_wait_runs_off_the_callers_process_test() {
  fixture(fn(ready, _, _) {
    let session = create_session(ready, "slow-task", 1006)
    let _ = member(ready, "ui-task", session, access.Operator)
    let #(standing, tickets) = standing_of(ready, "ui-task", access.Operator)
    saved(ready, session)
    let answers = process.new_subject()
    ui_socket.resume_task(standing, tickets, page_open, session, fn(answer) {
      process.send(answers, #(answer, process.self()))
    })
    assert process.receive(answers, 0) == Error(Nil)
    let assert Ok(#(sessions.Ticketed(path), task)) =
      process.receive(answers, 10_000)
      as "the task answers once the session is resident"
    assert string.starts_with(path, "/ui/sessions/" <> session <> "?ticket=")
    assert task != process.self()
  })
}

// The home's activity read asks the sessions in a task of its own: the call
// that starts it returns before the slowest session has answered, so the page's
// runtime is never held for the deadline, and the answer then arrives from the
// task, naming the sessions the page asked about.
pub fn the_activity_read_runs_off_the_callers_process_test() {
  let answers = process.new_subject()
  let asked = process.new_subject()
  let ask = fn(ids) {
    process.send(asked, ids)
    process.sleep(300)
    [#("A", sessions.Working)]
  }
  ui_socket.activity_task(ask, ["A", "B"], fn(rows) {
    process.send(answers, #(rows, process.self()))
  })

  // Nothing has answered when the call returns, and the task is another
  // process.
  assert process.receive(answers, 0) == Error(Nil)
  assert process.receive(asked, 5000) == Ok(["A", "B"])
  let assert Ok(#(rows, task)) = process.receive(answers, 5000)
    as "the task answers once the sessions have"
  assert rows == [#("A", sessions.Working)]
  assert task != process.self()
}

// An observer page's socket gate refuses before any task starts, so nothing is
// opened for it, and an operator's page starts the work.
pub fn only_an_operators_page_starts_the_task_test() {
  let refused = process.new_subject()
  let started = process.new_subject()
  let deliver = fn(answer) { process.send(refused, answer) }
  let start = fn() { process.send(started, Nil) }
  ui_socket.resumed_for(ui_socket.Observing, deliver, start)
  assert process.receive(refused, 0) == Ok(sessions.Declined(sessions.NotHeld))
  assert process.receive(started, 0) == Error(Nil)
  ui_socket.resumed_for(ui_socket.Operating, deliver, start)
  ui_socket.resumed_for(ui_socket.Owning, deliver, start)
  assert process.receive(started, 0) == Ok(Nil)
  assert process.receive(started, 0) == Ok(Nil)
  assert process.receive(refused, 0) == Error(Nil)
}

// The whole path through the router: a press on a saved session's row on an
// operator home opens it, and the ticket becomes a page of that session in the
// tab, a `Workspace` page like any a home opens.
pub fn a_saved_session_opens_from_the_home_and_the_tab_lands_on_it_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let session = create_session(ready, "home-resume", 1007)
    saved(ready, session)
    let home = enter(port, operator_home(port, credential))
    let asked =
      home_socket(port, home, [
        #("x-switch-target", session),
        #("x-resume", "task"),
      ])
    assert asked.status == 290
    assert reach_of(asked) == "workspace"
    assert string.starts_with(
      asked.body,
      "/ui/sessions/" <> session <> "?ticket=",
    )
    assert is_saved(ready, session) == False
    let page = enter(port, asked.body)
    assert open_page(port, page).status == 200
    assert open_page(port, home).status == 200
    assert exchange(port, asked.body).status == 401
  })
}

// A home minted to read is refused for a forged resume, and the session stays
// saved: the daemon decides from the grant it holds, whatever the socket
// forwarded.
pub fn an_observer_homes_forged_resume_is_refused_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let session = create_session(ready, "home-observer-resume", 1008)
    saved(ready, session)
    let home = enter(port, home_link(port, credential, []))
    let refused =
      home_socket(port, home, [
        #("x-switch-target", session),
        #("x-resume", "task"),
      ])
    assert refused.status == 291
    assert refused.body == "NotHeld"
    assert is_saved(ready, session)
  })
}

// An operator-ceiling page may not open a session its principal only observes,
// from the home or from a session page, whatever the ceiling says: the daemon
// takes the principal's own role in the target, as the control command does.
pub fn an_observer_member_cannot_resume_from_an_operator_page_test() {
  fixture_with(Switching, fn(ready, port, _) {
    let left = create_session(ready, "resume-left", 1009)
    let target = create_session(ready, "resume-target", 1010)
    let credential = member(ready, "ui-observer-of", left, access.Operator)
    also_holds(ready, "ui-observer-of", target, access.Observer)
    saved(ready, target)
    let operator = [#("page", json.String("operator"))]
    let home = enter(port, home_link(port, credential, operator))
    let from_home =
      home_socket(port, home, [
        #("x-switch-target", target),
        #("x-resume", "task"),
      ])
    assert from_home.status == 291
    assert from_home.body == "NotOperator"

    let page = enter(port, operate(port, credential, left))
    let from_page = ask_with(port, page, target, [#("x-resume", "task")])
    assert from_page.status == 291
    assert from_page.body == "NotOperator"
    assert is_saved(ready, target)
  })
}

// An observer's session page has no resume at all: the socket's gate refuses
// before the daemon is asked, in the words for a session not held.
pub fn an_observer_session_page_cannot_resume_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let left = create_session(ready, "observer-page", 1011)
    let target = create_session(ready, "observer-target", 1012)
    saved(ready, target)
    let page = enter(port, link(port, credential, left))
    let refused = ask_with(port, page, target, [#("x-resume", "task")])
    assert refused.status == 291
    assert refused.body == "NotHeld"
    assert is_saved(ready, target)
  })
}

// A home that has ended but whose socket is still up resumes nothing.
pub fn an_ended_home_resumes_nothing_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let session = create_session(ready, "ended-resume", 1013)
    saved(ready, session)
    let home = enter(port, operator_home(port, credential))
    let refused =
      home_socket(port, home, [
        #("x-switch-target", session),
        #("x-resume", "task"),
        #("x-switch-ended", "yes"),
      ])
    assert refused.status == 291
    assert refused.body == "NotHeld"
    assert is_saved(ready, session)
  })
}
