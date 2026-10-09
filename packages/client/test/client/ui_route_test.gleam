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
import client/daemon/admin as access_admin
import client/daemon/domain as domain_service
import client/daemon/limits
import client/daemon/manager
import client/daemon/new_folder
import client/daemon/root
import client/daemon/server
import client/daemon/ui_assets
import client/daemon/ui_login
import client/daemon/ui_sessions
import client/daemon/ui_socket
import client/daemon_claim_test
import client/daemon_server_test
import client/gateway
import client/peers
import client/ui_result_test
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
import gleam/uri
import host/bootstrap
import host/claim
import host/login
import mist
import session_view/transcript_image
import simplifile
import sqlight
import storage/access
import storage/catalogue
import storage/domain
import support/addresses
import support/extensions
import support/internal/ffi_daemon_socket
import support/internal/ffi_ws
import web_view/actions
import web_view/creations
import web_view/ending
import web_view/grants
import web_view/home
import web_view/invites
import web_view/names
import web_view/page
import web_view/peer_links
import web_view/renames
import web_view/sessions
import web_view/signins
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

  /// The home's upgrade runs the page's own sign-in asks with the standing the
  /// daemon built from the grant (protocol-change/065, PR 8): `x-signins` lists,
  /// `x-sign-out` and `x-sign-out-all` end logins, and `x-device-link` asks for a
  /// link, through the capability the socket would be handed, or, with
  /// `x-device-force`, the daemon's own check as a forged request would reach it.
  /// Every answer says the origin, login and address the router read from the
  /// page's grant.
  Signing

  /// The upgrade does what the page socket does for an invitation: it reads
  /// the role the router admitted (`ui_socket.role_of`) and, for an owner's
  /// page, asks the daemon to invite as the page's transport would, with the
  /// role a header names. The answer is 292 and the invitation's fields one
  /// to a line, or 293 and the reason. A page the transport gives no
  /// capability is answered 294 for a member operator's and 295 for an
  /// observer's. `x-invite-force` asks the daemon anyway, as a page whose
  /// capability was wrongly handed out would, and `x-switch-ended` asks as
  /// a page that has ended. A request that names `x-shareable` asks as the
  /// session page's "Make shareable" confirm does instead
  /// (`ui_socket.shareable_for`): 296 when the session was made shareable, or
  /// 297 and the reason, or 294 and 295 for a page with no capability, and
  /// `x-invite-force` asks the daemon anyway.
  Inviting

  /// The upgrades do what `Inviting` does for a session's page, and also what the
  /// owner's admin page and the home's "Admin" button do (protocol-change/065,
  /// the fifth pull request), so one fixture holds both ends of the grant
  /// allowance. The home answers a request that carries `x-admin-open` as the
  /// button's press does: 290 and the ticket's address, or 291 and the reason, or
  /// 289 for a home with no capability unless `x-admin-force` asks the daemon
  /// anyway. The admin page answers a request that names `x-admin-do` with the
  /// change it asks for, and any other with the catalogue it reads.
  Granting
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

          // A session named `broken-...` is refused as a bad configuration is,
          // with the line the owner's terminal would show.
          case string.starts_with(record.name, "broken-") {
            True -> Error(broken_reason)
            False -> Ok(record.id)
          }
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
      wall: bootstrap.system_time_ms,
      entropy: token.production_entropy(),
      ticket_ms: ui_sessions.ticket_ms,
      device_ms: ui_sessions.device_ms,
      session_ms:,
    ))
    as "the web view's tables start"

  // The login's root key is read or drawn as the daemon's own start does, so a
  // test that forges a token reads the same key back from the state directory.
  let assert Ok(root_key) = ui_login.root_key(ready.state_root, ready.registry)
    as "the login's root key is ready"
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
        result_reader: fn(_) { ui_result_test.reader(ui_result_test.payload()) },
        assets:,
        root_key:,
        upgrade: fn(request, attachment, open, register, seen) {
          let reach = seen.grant.reach
          case serving {
            // The router hands the page's upgrade the capped role and the
            // grant's reach. The stub reports what it was given.
            Stubbed | Signing ->
              with_page(reported(capped(attachment), reach), seen)

            Pictured -> {
              register(held)
              reported(capped(attachment), reach)
            }

            Switching -> switching(sessions, request, attachment, seen, open)

            Inviting | Granting ->
              inviting(
                sessions,
                request,
                attachment,
                open,
                origin_of(request, seen),
              )

            // The session is resident but its gateway is not running: the
            // relay's attach is refused, as it is when a session is
            // stopped between the router's check and the attach.
            Real ->
              ui_socket.upgrade(
                daemon,
                request,
                attachment,
                gateway.Gateway(name: addresses.new()),
                fn() { Error("no worktree") },
                sessions,
                open,
                register,
                seen,
              )
          }
        },
        home: fn(request, attachment, open, seen) {
          let ceiling = seen.grant.ceiling
          case serving {
            // The home's own socket, as the daemon serves it. A request that
            // carries `x-revoke-between` names a credential revoked after the
            // router admitted the page and before the component's first read,
            // which the refresh interval is far too long for a test to wait
            // out.
            //
            // A request that carries `x-admin-open` is the owner's press of the
            // "Admin" button instead, answered as the stub answers it, so a test
            // can hold an admin ticket and then watch the real admin socket.
            Real -> {
              case req.get_header(request, "x-admin-open") {
                Ok(_) ->
                  opening_admin_from_home(
                    sessions,
                    request,
                    attachment,
                    seen,
                    open,
                  )
                Error(Nil) -> {
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
                    seen,
                  )
                }
              }
            }

            // The home as the "Admin" button asks for a ticket, and otherwise as
            // a plain read.
            Granting ->
              case req.get_header(request, "x-admin-open") {
                Ok(_) ->
                  opening_admin_from_home(
                    sessions,
                    request,
                    attachment,
                    seen,
                    open,
                  )
                Error(Nil) ->
                  homed(ready.state_root, request, attachment, open, ceiling)
              }

            // The home as a row press asks for a ticket: the same call the
            // home's transport makes, for the session a header names.
            Switching ->
              case
                req.get_header(request, "x-switch-target"),
                req.get_header(request, "x-create-workspace")
              {
                Ok(target), _ ->
                  opening_from_home(
                    sessions,
                    request,
                    attachment,
                    seen,
                    open,
                    target,
                  )
                Error(Nil), Ok(workspace) ->
                  creating_from_home(
                    sessions,
                    request,
                    attachment,
                    seen,
                    open,
                    workspace,
                  )
                Error(Nil), Error(Nil) ->
                  with_page(
                    homed(ready.state_root, request, attachment, open, ceiling),
                    seen,
                  )
              }

            Signing ->
              signing_from_home(sessions, request, attachment, seen, open)

            Stubbed | Pictured | Inviting ->
              with_page(
                homed(ready.state_root, request, attachment, open, ceiling),
                seen,
              )
          }
        },
        admin: fn(request, attachment, open, ceiling) {
          case serving {
            // The admin page's own socket, as the daemon serves it. A request
            // that carries `x-revoke-between` names a credential revoked after
            // the router admitted the page and before the component's first read.
            Real -> {
              case req.get_header(request, "x-revoke-between") {
                Ok(token) -> revoke(ready.state_root, token)
                Error(Nil) -> Nil
              }
              ui_socket.upgrade_admin(
                daemon,
                request,
                attachment,
                sessions,
                open,
                ceiling,
              )
            }

            Granting ->
              administered(sessions, request, attachment, open, ceiling)

            Stubbed | Pictured | Switching | Inviting | Signing ->
              stub(
                278,
                string.join(
                  [
                    attachment.principal.id,
                    case ceiling {
                      access.Operator -> "operator"
                      access.Observer -> "observer"
                    },
                  ],
                  "\n",
                ),
              )
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

// An answer that also says what the router read from the page's grant besides
// its reach: the origin it was reached by, the login it belongs to and the
// address it was reached at (protocol-change/065, PR 8).
fn with_page(answer, seen: server.PageGrant) {
  answer
  |> response.set_header("x-page-origin", case seen.grant.origin {
    ui_sessions.Fresh -> "fresh"
    ui_sessions.Resumed -> "resumed"
  })
  |> response.set_header("x-page-ceiling", case seen.grant.ceiling {
    access.Operator -> "operator"
    access.Observer -> "observer"
  })
  |> response.set_header("x-page-login", case seen.login {
    Some(issuer) -> issuer.fingerprint
    None -> "none"
  })
  |> response.set_header("x-page-address", seen.address)
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
  seen: server.PageGrant,
  open: fn() -> Result(Int, Nil),
) {
  let reach = seen.grant.reach
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
  let standing = ui_socket.page_standing(attachment, seen)
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
  list.fold(
    deadline,
    with_page(reported(answer, reach), seen),
    fn(answer, header) { response.set_header(answer, header.0, header.1) },
  )
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
  seen: server.PageGrant,
  open: fn() -> Result(Int, Nil),
  target: String,
) {
  let reach = seen.grant.reach
  let open = case req.get_header(request, "x-switch-ended") {
    Ok(_) -> fn() { Error(Nil) }
    Error(Nil) -> open
  }
  let deadline = case open() {
    Ok(until) -> [#("x-page-deadline", int.to_string(until))]
    Error(Nil) -> []
  }
  let standing = ui_socket.home_standing(attachment, seen)
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

// The home's upgrade as the form that creates a session asks: the capability the
// socket hands a page (`home_create_capability`) is consulted first, and a page
// with none is answered 289 unless `x-create-force` asks the daemon anyway, as a
// forged message from a page that was wrongly handed the capability would. The
// request is run in the task the page uses (`create_task`) with the daemon's own
// `create` and answered 290 and the ticket's address, or 291 and the reason. The
// name and sharing come from headers; `x-switch-ended` asks as a page that has
// ended but whose socket is still up.
fn creating_from_home(
  tickets,
  request,
  attachment: server.HomeAttachment(String),
  seen: server.PageGrant,
  open: fn() -> Result(Int, Nil),
  workspace: String,
) {
  let ceiling = seen.grant.ceiling
  let reach = seen.grant.reach
  let open = case req.get_header(request, "x-switch-ended") {
    Ok(_) -> fn() { Error(Nil) }
    Error(Nil) -> open
  }
  let standing = ui_socket.home_standing(attachment, seen)
  let name = result.unwrap(req.get_header(request, "x-create-name"), "")
  let sharing = case req.get_header(request, "x-create-sharing") {
    Ok("shareable") -> creations.Shareable
    Ok(_) | Error(Nil) -> creations.Private
  }
  // `x-create-home` stands for the owner's home directory, so a test can type a
  // path under a directory of its own; without it the daemon's own is used.
  let folder = case req.get_header(request, "x-create-home") {
    Ok(home) -> new_folder.check_in(_, home, attachment.state_root)
    Error(Nil) -> new_folder.check(_, attachment.state_root)
  }
  let profile = case req.get_header(request, "x-create-profile") {
    Ok(chosen) -> Some(chosen)
    Error(Nil) -> None
  }
  let model = case req.get_header(request, "x-create-model") {
    Ok(chosen) -> Some(chosen)
    Error(Nil) -> None
  }
  let ask = fn(place, name, sharing, roles, deliver) {
    ui_socket.create_task(
      standing,
      tickets,
      open,
      attachment.create,
      fn(session) {
        manager.delete_session(
          attachment.registry,
          attachment.digest,
          attachment.epoch,
          session,
          attachment.sessions_directory,
        )
        |> result.replace(Nil)
      },
      folder,
      place,
      name,
      sharing,
      roles,
      deliver,
    )
  }
  let capability =
    ui_socket.home_create_capability(attachment.principal, ceiling, ask)
  let asked = case capability, req.get_header(request, "x-create-force") {
    Some(ask), _ -> Some(ask)
    None, Ok(_) -> Some(ask)
    None, Error(Nil) -> None
  }
  case asked {
    None -> stub(289, "no capability")
    Some(ask) -> {
      let answers = process.new_subject()
      let place = case req.get_header(request, "x-create-typed") {
        Ok(_) -> creations.Typed(workspace)
        Error(Nil) -> creations.Drawn(workspace)
      }
      ask(place, name, sharing, creations.Roles(profile:, model:), fn(answer) {
        process.send(answers, answer)
      })
      case process.receive(answers, 10_000) {
        Ok(creations.Ticketed(path)) -> reported(stub(290, path), reach)
        Ok(creations.Declined(reason)) ->
          reported(stub(291, string.inspect(reason)), reach)
        Ok(creations.Unstarted(..) as unstarted) ->
          reported(stub(292, string.inspect(unstarted)), reach)
        Error(Nil) -> stub(298, "the task never answered")
      }
    }
  }
}

// The home's upgrade as the "Admin" button asks: the capability the socket hands
// a page (`home_admin_capability`) is consulted first, and a page with none is
// answered 289 unless `x-admin-force` asks the daemon anyway, as a forged
// message from a page that was wrongly handed the capability would. The request
// is run in the task the page uses (`admin_ticket_task`) and answered 290 and the
// ticket's address, or 291 and the reason. `x-switch-ended` asks as a page that
// has ended but whose socket is still up. A request that carries `x-admin-mint`
// instead mints an admin ticket for the member credential it names, whom the
// daemon would never mint one for, so a test can present the router with a grant
// that should not exist.
fn opening_admin_from_home(
  tickets,
  request,
  attachment: server.HomeAttachment(String),
  seen: server.PageGrant,
  open: fn() -> Result(Int, Nil),
) {
  let open = case req.get_header(request, "x-switch-ended") {
    Ok(_) -> fn() { Error(Nil) }
    Error(Nil) -> open
  }
  let standing = ui_socket.home_standing(attachment, seen)
  case req.get_header(request, "x-admin-mint") {
    Ok(credential) -> {
      let assert Ok(issued) =
        ui_sessions.mint(
          tickets,
          ui_sessions.Grant(
            scope: ui_sessions.Admin,
            credential: digest_of(credential),
            principal: result.unwrap(
              req.get_header(request, "x-admin-mint-principal"),
              "",
            ),
            ceiling: access.Operator,
            reach: ui_sessions.Workspace,
            origin: ui_sessions.Fresh,
            remember: ui_sessions.Forgotten,
          ),
        )
        as "a ticket is minted"
      stub(290, page.admin_exchange_path(issued.ticket))
    }
    Error(Nil) -> {
      let ask = fn(deliver) {
        ui_socket.admin_ticket_task(standing, tickets, open, deliver)
      }
      let capability =
        ui_socket.home_admin_capability(
          attachment.principal,
          seen.grant.ceiling,
          seen.grant.reach,
          seen.grant.origin,
          ask,
        )
      let asked = case capability, req.get_header(request, "x-admin-force") {
        Some(ask), _ -> Some(ask)
        None, Ok(_) -> Some(ask)
        None, Error(Nil) -> None
      }
      case asked {
        None -> stub(289, "no capability")
        Some(ask) -> {
          let answers = process.new_subject()
          ask(fn(answer) { process.send(answers, answer) })
          case process.receive(answers, 10_000) {
            Ok(sessions.Ticketed(path)) -> stub(290, path)
            Ok(sessions.Declined(reason)) -> stub(291, string.inspect(reason))
            Error(Nil) -> stub(298, "the task never answered")
          }
        }
      }
    }
  }
}

// The admin page's upgrade as the daemon's socket asks it. A request that names
// `x-admin-do` asks for that change as the page's component would, in the task
// the page uses (`admin_task`), with the identities and text the other
// `x-admin-` headers carry, and is answered 292 and the claim's fields one to a
// line, or 294 for a change that made no claim, or 293 and the reason. Any other
// request reads the catalogue as the component does (`admin_reading`) and is
// answered 279 and what the read found, one line for each of the principals, the
// sessions and the chosen session's members. `x-switch-ended` asks as a page that
// has ended but whose socket is still up.
fn administered(
  tickets,
  request,
  attachment: server.AdminAttachment(String),
  open: fn() -> Result(Int, Nil),
  ceiling,
) {
  let open = case req.get_header(request, "x-switch-ended") {
    Ok(_) -> fn() { Error(Nil) }
    Error(Nil) -> open
  }
  let standing =
    ui_socket.Standing(
      registry: attachment.registry,
      digest: attachment.digest,
      principal: attachment.principal.id,
      ceiling:,
      reach: ui_sessions.Workspace,
      origin: ui_sessions.Fresh,
      login: attachment.login,
    )
  let header = fn(name) { result.unwrap(req.get_header(request, name), "") }
  case req.get_header(request, "x-admin-do") {
    Error(Nil) -> {
      let chosen = case header("x-admin-chosen") {
        "" -> None
        session -> Some(session)
      }
      let logins = header("x-admin-logins") != ""
      let scope = header("x-admin-scope") != ""
      let summaries = header("x-admin-summaries") != ""
      stub(
        279,
        case ui_socket.admin_reading(attachment, open, chosen, fn(_) { Nil }) {
          grants.Read(snapshot) if summaries -> row_summaries(snapshot)
          grants.Read(snapshot) if scope -> scope_summary(snapshot)
          grants.Read(snapshot) if logins -> logins_summary(snapshot)
          grants.Read(snapshot) -> summary(snapshot)
          grants.Unread -> "unread"
          grants.Closed(reason) -> "closed " <> ending.reason(reason)
        },
      )
    }
    Ok(kind) -> {
      let role = case header("x-admin-role") {
        "operator" -> invites.Operator
        _ -> invites.Observer
      }
      let session = header("x-admin-session")
      let principal = header("x-admin-principal")
      let action = case kind {
        "invite" -> grants.Invite(session, role, header("x-admin-name"))
        "set-role" -> grants.SetRole(session, principal, role)
        "revoke-membership" -> grants.RevokeMembership(session, principal)
        "revoke-credentials" -> grants.RevokeCredentials(principal)
        "revoke-signin" ->
          grants.RevokeSignin(principal, header("x-admin-fingerprint"))
        _ -> grants.Rotate(principal)
      }
      let answers = process.new_subject()
      ui_socket.admin_task(
        standing,
        tickets,
        open,
        attachment.epoch,
        attachment.state_root,
        ui_socket.claim_address(request),
        action,
        fn(answer) { process.send(answers, answer) },
      )
      case process.receive(answers, 10_000) {
        Ok(grants.Claimed(claim)) ->
          stub(
            292,
            string.join(
              [
                claim.command,
                claim.token,
                claim.principal,
                case claim.purpose {
                  grants.Invited(role) -> invites.role_word(role)
                  grants.Rotated -> "rotated"
                },
                int.to_string(claim.expires_in_ms),
                claim.page,
              ],
              "\n",
            ),
          )
        Ok(grants.Changed) -> stub(294, "changed")
        Ok(grants.Declined(grants.TooMany(..))) -> stub(293, "TooMany")
        Ok(grants.Declined(reason)) -> stub(293, string.inspect(reason))
        Error(Nil) -> stub(298, "the task never answered")
      }
    }
  }
}

// What a read found for each listed session's row, one line each as
// `session:people:words`, in the catalogue's order.
fn row_summaries(snapshot: grants.Snapshot) -> String {
  string.join(
    list.filter_map(snapshot.sessions, fn(entry) {
      list.find(snapshot.summaries, fn(held) { held.session == entry.id })
      |> result.map(fn(held) {
        entry.id
        <> ":"
        <> int.to_string(held.people)
        <> ":"
        <> grants.summary_words(held)
      })
    }),
    "\n",
  )
}

// What a read found for the chosen session's scope, as `shareable`, `private` or
// `none` when no session was found.
fn scope_summary(snapshot: grants.Snapshot) -> String {
  case snapshot.selection {
    None -> "none"
    Some(selection) ->
      case selection.scope {
        creations.Shareable -> "shareable"
        creations.Private -> "private"
      }
  }
}

// The sign-ins a read found, one line: each principal that holds any, its count
// and the fingerprints listed, as `id:count:fingerprint+fingerprint`.
fn logins_summary(snapshot: grants.Snapshot) -> String {
  "logins "
  <> string.join(
    list.map(snapshot.logins, fn(held) {
      held.principal
      <> ":"
      <> int.to_string(held.count)
      <> ":"
      <> string.join(list.map(held.shown, fn(row) { row.fingerprint }), "+")
    }),
    ",",
  )
}

// What a read of the catalogue found, one line each: the principals with their
// kinds and credential states, the sessions, and the chosen session's members.
fn summary(snapshot: grants.Snapshot) -> String {
  let credential = fn(state) {
    case state {
      grants.Active(..) -> "active"
      grants.ClaimOpen(..) -> "claim_open"
      grants.ClaimExpired -> "claim_expired"
      grants.NoCredential -> "none"
    }
  }
  string.join(
    [
      "principals "
        <> string.join(
        list.map(snapshot.principals, fn(row) {
          row.id
          <> ":"
          <> case row.kind {
            grants.OwnerKind -> "owner"
            grants.MemberKind -> "member"
          }
          <> ":"
          <> credential(row.credential)
        }),
        ",",
      ),
      "sessions "
        <> string.join(list.map(snapshot.sessions, fn(entry) { entry.id }), ","),
      case snapshot.selection {
        None -> "selection none"
        Some(selection) ->
          "selection "
          <> selection.session
          <> " "
          <> string.join(
            list.map(selection.holders, fn(holder) {
              holder.principal <> "=" <> invites.role_word(holder.role)
            }),
            ",",
          )
      },
    ],
    "\n",
  )
}

// The page's upgrade as an invitation asks for one: what `ui_socket.upgrade`
// does with the role it admitted, without the Lustre component in the way.
// The origin the daemon is asked as. `x-origin-resumed` asks as a page that a
// bookmark opened, which the stub cannot reach through a real login.
fn origin_of(request, seen: server.PageGrant) -> ui_sessions.Origin {
  case req.get_header(request, "x-origin-resumed") {
    Ok(_) -> ui_sessions.Resumed
    Error(Nil) -> seen.grant.origin
  }
}

fn inviting(
  tickets,
  request,
  attachment: server.Attachment(String),
  open: fn() -> Result(Int, Nil),
  origin: ui_sessions.Origin,
) {
  case req.get_header(request, "x-shareable") {
    Ok(_) -> shareabling(request, attachment, open, origin)
    Error(Nil) -> inviting_in(tickets, request, attachment, open, origin)
  }
}

// The page's upgrade as the "Make shareable" confirm asks for it: the daemon's
// own function, behind the capability the socket would hand an owner's page and
// nobody else's, or called anyway when `x-invite-force` names a page whose
// capability was wrongly handed out.
fn shareabling(
  request,
  attachment: server.Attachment(String),
  open: fn() -> Result(Int, Nil),
  origin: ui_sessions.Origin,
) {
  let open = case req.get_header(request, "x-switch-ended") {
    Ok(_) -> fn() { Error(Nil) }
    Error(Nil) -> open
  }
  let ask = fn() {
    // `x-shareable-task` asks as the page's capability does, through the task
    // that outlives the page, and answers at once: the request's process ends
    // while the task runs.
    case req.get_header(request, "x-shareable-task") {
      Ok(_) -> {
        ui_socket.shareable_task(attachment, origin, open, fn(_) { Nil })
        stub(298, "started")
      }
      Error(Nil) -> asked_now(attachment, origin, open)
    }
  }
  let capability =
    ui_socket.shareable_capability(ui_socket.role_of(attachment), origin, fn(_) {
      Nil
    })
  case capability, req.get_header(request, "x-invite-force") {
    Some(_), _ | None, Ok(_) -> ask()
    None, Error(Nil) ->
      case ui_socket.role_of(attachment) {
        ui_socket.Operating | ui_socket.Owning -> stub(294, "no capability")
        ui_socket.Observing -> stub(295, "no capability")
      }
  }
}

fn asked_now(
  attachment: server.Attachment(String),
  origin: ui_sessions.Origin,
  open: fn() -> Result(Int, Nil),
) {
  {
    case ui_socket.shareable_for(attachment, origin, open) {
      grants.Changed -> stub(296, "changed")
      grants.Declined(reason) -> stub(297, string.inspect(reason))
      grants.Claimed(..) -> stub(297, "a claim")
    }
  }
}

fn inviting_in(
  tickets,
  request,
  attachment: server.Attachment(String),
  open: fn() -> Result(Int, Nil),
  origin: ui_sessions.Origin,
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
        origin,
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
              invitation.page,
            ],
            "\n",
          ),
        )
      invites.Declined(reason) -> stub(293, string.inspect(reason))
    }
  }
  let capability =
    ui_socket.invite_capability(ui_socket.role_of(attachment), origin, fn(_) {
      invites.Declined(invites.Unavailable)
    })
  case
    capability,
    ui_socket.role_of(attachment),
    req.get_header(request, "x-invite-force")
  {
    Some(_), _, _ -> ask()
    None, _, Ok(_) -> ask()
    None, ui_socket.Operating, Error(Nil)
    | None, ui_socket.Owning, Error(Nil)
    -> stub(294, "no capability")
    None, ui_socket.Observing, Error(Nil) -> stub(295, "no capability")
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

// The home's upgrade as the sign-in controls ask: the daemon's own functions
// with the standing built from the page's grant, for the asks the request's
// headers name. A listing is 281 and one line for each login; a sign-out is 282
// or 283 and the reason; a link is 284 and the whole address, or 283 and the
// reason, or 289 for a page the socket would hand no capability.
fn signing_from_home(
  tickets,
  request,
  attachment: server.HomeAttachment(String),
  seen: server.PageGrant,
  open: fn() -> Result(Int, Nil),
) {
  let standing = ui_socket.home_standing(attachment, seen)

  // `x-login-ended` asks as a page whose login ran out a moment ago would, for
  // a test that cannot wait thirty days.
  let standing = case req.get_header(request, "x-login-ended") {
    Ok(_) ->
      ui_socket.Standing(
        ..standing,
        login: option.map(standing.login, fn(issuer) {
          ui_sessions.Issuer(..issuer, expires_at_ms: 0)
        }),
      )
    Error(Nil) -> standing
  }
  let answer = case
    req.get_header(request, "x-sign-out"),
    req.get_header(request, "x-sign-out-all"),
    req.get_header(request, "x-device-link"),
    req.get_header(request, "x-signins")
  {
    Ok(fingerprint), _, _, _ ->
      case
        ui_socket.sign_out_for(standing, attachment.epoch, open, fingerprint)
      {
        signins.Revoked -> stub(282, "revoked")
        signins.Linked(_) -> stub(283, "unexpected")
        signins.Declined(reason) -> stub(283, string.inspect(reason))
      }
    Error(Nil), Ok(_), _, _ ->
      case ui_socket.sign_out_all_for(standing, attachment.epoch, open) {
        signins.Revoked -> stub(282, "revoked")
        signins.Linked(_) -> stub(283, "unexpected")
        signins.Declined(reason) -> stub(283, string.inspect(reason))
      }
    Error(Nil), Error(Nil), Ok(_), _ -> {
      let ask = fn() {
        ui_socket.device_link_for(standing, tickets, open, seen.address)
      }
      let capability = ui_socket.device_capability(seen.grant.origin, ask)
      let forced = result.is_ok(req.get_header(request, "x-device-force"))
      case capability, forced {
        None, False -> stub(289, "no capability")
        Some(_), _ | None, True ->
          case ask() {
            signins.Linked(address) -> stub(284, address)
            signins.Revoked -> stub(283, "unexpected")
            signins.Declined(reason) -> stub(283, string.inspect(reason))
          }
      }
    }
    Error(Nil), Error(Nil), Error(Nil), _ ->
      case ui_socket.signins_read(standing, open) {
        signins.Listed(rows) ->
          stub(
            281,
            string.join(
              list.map(rows, fn(row) {
                string.join(
                  [
                    row.fingerprint,
                    int.to_string(row.issued_at_ms),
                    string.inspect(row.last_resumed_ms),
                    string.inspect(row.expires_at_ms),
                    string.inspect(row.issued_by),
                  ],
                  "|",
                )
              }),
              "\n",
            ),
          )
        signins.Unread -> stub(281, "unread")
      }
  }
  with_page(answer, seen)
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
  send_request(port, "GET", path, headers, "")
}

// A raw request with a method and a body, which `get` is the bodyless case of.
// The caller writes every header, `Content-Length` included, so a test can send
// the sizes and types a form, a script or an attacker might.
fn send_request(
  port: Int,
  method: String,
  path: String,
  headers: List(#(String, String)),
  body: String,
) -> Answer {
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
    method
    <> " "
    <> path
    <> " HTTP/1.1\r\n"
    <> string.concat(lines)
    <> "\r\n"
    <> body
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
      manager.Creation(key, ready.state_root, key, "", None, None),
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
  // A wire bearer is 64 lowercase hex characters, so the fixture's token is
  // the hash of a name-derived string rather than the string itself.
  let credential =
    { name <> "-token" }
    |> bit_array.from_string
    |> bootstrap.sha256
    |> bit_array.base16_encode
    |> string.lowercase
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
      #(page.favicon_asset, "image/svg+xml", page.static_file),
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

// The tab keeps one nonce per keyed page (protocol-change/051, the addendum on
// navigation), so Back can return to a page and find its own. Both scripts
// build the item name from the prefix and the page's key; neither spells the
// bare, one-per-tab name, which a later page would overwrite. The bundle
// navigates with `location.assign`, and no component of it replaces the
// location.
pub fn the_nonce_is_kept_per_page_and_the_bundle_assigns_the_location_test() {
  list.each([page.enter_asset, page.page_asset], fn(name) {
    let assert Ok(path) = page.static_file(name) as "the script has a priv path"
    let assert Ok(script) = simplifile.read(path) as "the script reads"
    assert string.contains(script, "\"" <> page.nonce_item <> "\" + ")
    assert !string.contains(script, "\"loom-page-nonce\"")
  })

  let assert Ok(path) = page.static_file(page.client_asset)
    as "the bundle has a priv path"
  let assert Ok(bundle) = simplifile.read(path) as "the bundle reads"
  assert string.contains(bundle, "location.assign(")
  assert !string.contains(bundle, "location.replace(")
  assert string.contains(bundle, "history.back()")
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

    // The placeholder is no command `<loom-copy>` would copy, so the document
    // draws no box rather than one the element would blank.
    assert !string.contains(refused.body, "loom-copy")
    assert !string.contains(refused.body, "--session")
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
        wall: bootstrap.system_time_ms,
        entropy: token.production_entropy(),
        ticket_ms: ui_sessions.ticket_ms,
        device_ms: ui_sessions.device_ms,
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
        origin: ui_sessions.Fresh,
        login: None,
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
    assert string.contains(opened.body, "Home — Loom")
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
      manager.Creation(key, ready.state_root, key, "", None, None),
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
    page: String,
  )
}

fn minted(answer: Answer) -> Minted {
  assert answer.status == 292
  let assert [command, token, principal, role, expires, page] =
    string.split(answer.body, "\n")
    as "an invitation is six lines"
  let assert Ok(expires_in_ms) = int.parse(expires) as "a lifetime"
  Minted(command:, token:, principal:, role:, expires_in_ms:, page:)
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
    assert answer.page
      == "http://127.0.0.1:" <> int.to_string(port) <> "/ui/claim"
    assert !string.contains(answer.page, "loomclaim_")

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
      wall: bootstrap.system_time_ms,
      entropy: token.production_entropy(),
      ticket_ms: ui_sessions.ticket_ms,
      device_ms: ui_sessions.device_ms,
      session_ms: ui_sessions.session_ms,
    ))
    as "the web view's tables start"
  let assert Ok(digest) =
    { name <> "-token" }
    |> bit_array.from_string
    |> bootstrap.sha256
    |> bit_array.base16_encode
    |> string.lowercase
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
      origin: ui_sessions.Fresh,
      login: None,
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

// A creation the registry accepts and whose session cannot start, for a
// configuration that is bad, says why in the startup reason the registry kept
// for that operation, and the reservation that never initialized a database is
// released: the list holds nothing for it, and the same creation made again once
// the cause is corrected succeeds. The release is the registry's own delete, so
// it is what the owner's Delete button would do, made for them.
pub fn a_creation_that_cannot_start_says_why_and_is_released_test() {
  fixture(fn(ready, _, credential) {
    let _known = create_session(ready, "failing-known", 1130)
    let #(standing, tickets) =
      creator_standing(ready, credential, access.Operator)
    let before = session_count(ready, credential)
    let attempt = fn(name, seed) {
      ui_socket.create_for(
        standing,
        tickets,
        page_open,
        registry_create(ready, seed),
        registry_release(ready, credential),
        new_folder.check(_, ready.state_root),
        creations.Drawn(ready.state_root),
        name,
        creations.Private,
        creations.default_roles,
        within: 3000,
      )
    }

    assert attempt("broken-config", 1131)
      == creations.Unstarted(Some(broken_reason), creations.Dropped)
    assert session_count(ready, credential) == before

    // The corrected configuration is the same press with a name the stub no
    // longer refuses, and it opens.
    let assert creations.Ticketed(path) = attempt("fixed-config", 1132)
    assert string.starts_with(path, "/ui/sessions/")
    assert session_count(ready, credential) == before + 1
  })
}

// A release the registry refuses leaves the reserved row for the owner's Delete,
// and the answer still carries the reason and does not claim the session was
// dropped.
pub fn a_refused_release_keeps_the_row_and_the_reason_test() {
  fixture(fn(ready, _, credential) {
    let _known = create_session(ready, "kept-known", 1133)
    let #(standing, tickets) =
      creator_standing(ready, credential, access.Operator)
    let before = session_count(ready, credential)
    assert ui_socket.create_for(
        standing,
        tickets,
        page_open,
        registry_create(ready, 1134),
        no_release,
        new_folder.check(_, ready.state_root),
        creations.Drawn(ready.state_root),
        "broken-kept",
        creations.Private,
        creations.default_roles,
        within: 3000,
      )
      == creations.Unstarted(Some(broken_reason), creations.InList)
    assert session_count(ready, credential) == before + 1
  })
}

// Only the owner's creation reaches a startup reason: a member's page is refused
// as not the owner before any session exists, so it holds no reason and the
// registry gains no row.
pub fn a_member_page_learns_no_startup_reason_test() {
  fixture(fn(ready, _, credential) {
    let _known = create_session(ready, "member-known", 1135)
    let #(standing, tickets) =
      creator_standing(ready, credential, access.Operator)
    let before = session_count(ready, credential)
    assert ui_socket.create_for(
        ui_socket.Standing(..standing, principal: "someone-else"),
        tickets,
        page_open,
        registry_create(ready, 1136),
        registry_release(ready, credential),
        new_folder.check(_, ready.state_root),
        creations.Drawn(ready.state_root),
        "broken-member",
        creations.Private,
        creations.default_roles,
        within: 3000,
      )
      == creations.Declined(creations.NotOwner)
    assert session_count(ready, credential) == before
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

// --- renaming from a page (protocol-change/067) ------------------------------

// The owner's page standing: the daemon's owner and the digest of the plaintext
// credential the fixture's daemon minted for it.
fn owner_standing(
  ready: root.Ready(String),
  credential: String,
  ceiling: access.Role,
) -> ui_socket.Standing(String) {
  let assert Ok(digest) =
    credential
    |> bit_array.from_string
    |> bootstrap.sha256
    |> bit_array.base16_encode
    |> string.lowercase
    |> access.credential_digest
    as "the owner's digest is valid"
  ui_socket.Standing(
    registry: ready.registry,
    digest:,
    principal: ready.owner.id,
    ceiling:,
    reach: ui_sessions.Workspace,
    origin: ui_sessions.Fresh,
    login: None,
  )
}

// The name the registry holds for `session`.
fn name_of(ready: root.Ready(String), session: String) -> String {
  let assert Ok(view) = manager.get(ready.registry, session)
    as "the session is listed"
  view.registration.name
}

// The owner's page renames its session through the registry's owner-checked
// rename. The name is trimmed first, and the answer carries the name the
// catalogue now holds, which the registry's own listing agrees with.
pub fn an_owners_page_renames_its_session_through_the_registry_test() {
  fixture(fn(ready, _, credential) {
    let session = create_session(ready, "rename-owner", 1101)
    let standing = owner_standing(ready, credential, access.Operator)
    assert ui_socket.rename_for(
        standing,
        page_open,
        ready.epoch,
        session,
        "  review auth  ",
      )
      == renames.Renamed("review auth")
    assert name_of(ready, session) == "review auth"

    // Naming it again to what it already is stores the same name.
    assert ui_socket.rename_for(
        standing,
        page_open,
        ready.epoch,
        session,
        "review auth",
      )
      == renames.Renamed("review auth")
  })
}

// Each refusal stores nothing: a member, a forged or unknown session identity, a
// page that has ended, a page minted to read, a stale epoch and a principal the
// page was not admitted for are the owner-only words, and a name that breaks the
// display-name rule is the name's own. The session keeps its name throughout, and
// so does another session.
pub fn a_page_rename_refuses_and_stores_nothing_test() {
  fixture(fn(ready, _, credential) {
    let session = create_session(ready, "rename-held", 1102)
    let other = create_session(ready, "rename-other", 1103)
    let _ = member(ready, "ui-renamer", session, access.Operator)
    let owner = owner_standing(ready, credential, access.Operator)
    let #(member_standing, _) =
      standing_of(ready, "ui-renamer", access.Operator)
    let rename = fn(standing, open, epoch, target, name) {
      ui_socket.rename_for(standing, open, epoch, target, name)
    }
    let refused = renames.Declined(renames.NotOwner)

    // A member operator of the very session is not the owner, even holding a
    // credential that authenticates.
    assert rename(member_standing, page_open, ready.epoch, session, "mine")
      == refused

    // A forged identity: not a session's, empty, or canonical but unknown. The
    // owner is refused the same way, so a page learns nothing about which.
    list.each(
      ["not a session", "", "01900000-0000-7000-8000-000000000000"],
      fn(target) {
        assert rename(owner, page_open, ready.epoch, target, "forged")
          == refused
      },
    )

    // The page has ended, was minted to read, or holds a daemon lifetime that is
    // no longer the daemon's.
    assert rename(owner, fn() { Error(Nil) }, ready.epoch, session, "late")
      == refused
    assert rename(
        ui_socket.Standing(..owner, ceiling: access.Observer),
        page_open,
        ready.epoch,
        session,
        "watching",
      )
      == refused
    assert rename(owner, page_open, "an-earlier-epoch", session, "stale")
      == refused

    // The owner's credential for a principal the page was not admitted as.
    assert rename(
        ui_socket.Standing(..owner, principal: "someone-else"),
        page_open,
        ready.epoch,
        session,
        "swapped",
      )
      == refused

    // Names the catalogue refuses: blank, control, zero-width and
    // direction-changing characters, and past 256 bytes.
    list.each(
      [
        "",
        "   ",
        "line\nbreak",
        "bell\u{7}",
        "reversed \u{202E}name",
        "zero\u{200B}width",
        string.repeat("x", 257),
      ],
      fn(name) {
        assert rename(owner, page_open, ready.epoch, session, name)
          == renames.Declined(renames.InvalidName)
      },
    )
    assert name_of(ready, session) == "rename-held"
    assert name_of(ready, other) == "rename-other"
  })
}

// The page's request runs in a task of its own and the answer is handed to the
// function the page's runtime gave, from that task: the call returns to its
// caller, and the answer arrives from another process.
pub fn the_rename_runs_in_a_task_and_delivers_its_answer_test() {
  fixture(fn(ready, _, credential) {
    let session = create_session(ready, "rename-task", 1104)
    let owner = owner_standing(ready, credential, access.Operator)
    let answered = process.new_subject()
    ui_socket.rename_task(
      owner,
      page_open,
      ready.epoch,
      session,
      "from a task",
      fn(answer) { process.send(answered, #(process.self(), answer)) },
    )
    let assert Ok(#(pid, answer)) = process.receive(answered, 5000)
      as "the task answers"
    assert answer == renames.Renamed("from a task")
    assert pid != process.self()
    assert name_of(ready, session) == "from a task"

    // A refusal is delivered too, so a page that stays open is always answered.
    ui_socket.rename_task(
      owner,
      page_open,
      ready.epoch,
      "not a session",
      "x",
      fn(answer) { process.send(answered, #(process.self(), answer)) },
    )
    let assert Ok(#(_, refusal)) = process.receive(answered, 5000)
      as "the task answers a refusal"
    assert refusal == renames.Declined(renames.NotOwner)
  })
}

// --- creating a session (protocol-change/065, the fourth pull request) --------

// The digest of a plaintext credential, as the registry stores it.
fn digest_of(credential: String) -> access.Digest {
  let assert Ok(digest) =
    credential
    |> bit_array.from_string
    |> bootstrap.sha256
    |> bit_array.base16_encode
    |> string.lowercase
    |> access.credential_digest
    as "the digest is valid"
  digest
}

// How many sessions the owner's authorized read lists: what exists in the
// catalogue, which a refused creation must leave as it was.
fn session_count(ready: root.Ready(String), credential: String) -> Int {
  let assert Ok(#(_, views)) =
    manager.authorized_page(ready.registry, digest_of(credential), after: "")
    as "the owner's read answers"
  list.length(views)
}

// The identity in a ticket's exchange address, `/ui/sessions/<id>?ticket=...`.
fn session_of(path: String) -> String {
  let assert Ok(#(_, rest)) = string.split_once(path, "/ui/sessions/")
    as "a session exchange"
  let assert Ok(#(id, _)) = string.split_once(rest, "?") as "the ticket follows"
  id
}

// The owner's standing, as the home's socket holds it, with a fresh table of
// tickets to mint into.
fn creator_standing(
  ready: root.Ready(String),
  credential: String,
  ceiling: access.Role,
) -> #(ui_socket.Standing(String), ui_sessions.Sessions) {
  let assert Ok(tickets) =
    ui_sessions.start(ui_sessions.Settings(
      now: bootstrap.monotonic_time_ms,
      wall: bootstrap.system_time_ms,
      entropy: token.production_entropy(),
      ticket_ms: ui_sessions.ticket_ms,
      device_ms: ui_sessions.device_ms,
      session_ms: ui_sessions.session_ms,
    ))
    as "the web view's tables start"
  #(
    ui_socket.Standing(
      registry: ready.registry,
      digest: digest_of(credential),
      principal: ready.owner.id,
      ceiling:,
      reach: ui_sessions.Workspace,
      origin: ui_sessions.Fresh,
      login: None,
    ),
    tickets,
  )
}

// A `create` that makes nothing and says how often it was asked, answering with
// the view of a session that already exists, so a test can follow the daemon's
// steps without a second session of the fixture's one seeded identity.
fn counting_create(
  ready: root.Ready(String),
  existing: String,
  asked: process.Subject(manager.Creation),
) -> fn(access.Principal, manager.Creation, domain.Scope) ->
  Result(manager.View, String) {
  fn(_, creation, _) {
    process.send(asked, creation)
    manager.get(ready.registry, existing) |> result.replace_error("unavailable")
  }
}

// The whole path through the router: a press on "New session" on the owner's
// operator home creates a session in a workspace the owner already runs one in,
// with the typed name and the scope the box chose, opens it and mints a ticket,
// and the ticket becomes a page of the new session in the tab, a `Workspace`
// page like any a home opens.
pub fn an_owners_home_creates_a_session_and_the_tab_lands_on_it_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let _known = create_session(ready, "create-known", 1101)
    let before = session_count(ready, credential)
    let home = enter(port, operator_home(port, credential))
    let asked =
      home_socket(port, home, [
        #("x-create-workspace", ready.state_root),
        #("x-create-name", "  fresh session  "),
        #("x-create-sharing", "shareable"),
      ])
    assert asked.status == 290
    assert reach_of(asked) == "workspace"
    assert string.starts_with(asked.body, "/ui/sessions/")
    let created = session_of(asked.body)
    assert session_count(ready, credential) == before + 1

    // The registry holds what the form said, resident, in the owner's
    // workspace, with the scope the box chose.
    let assert Ok(view) = manager.get(ready.registry, created)
    assert view.registration.name == "fresh session"
    assert view.registration.workspace == ready.state_root
    assert result.is_ok(manager.resolve(ready.registry, created))
    let assert Ok(shared) = manager.session_domain(ready.registry, created)
    assert shared.scope == domain.SessionOnly

    // The tab lands on it, and the ticket is spent.
    let page = enter(port, asked.body)
    assert open_page(port, page).status == 200
    assert open_page(port, home).status == 200
    assert exchange(port, asked.body).status == 401
  })
}

// Without the box and without a name the session is private and named for its
// workspace's folder, as the terminal names one.
pub fn a_blank_form_makes_a_private_session_named_for_its_folder_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let _known = create_session(ready, "create-blank", 1102)
    let home = enter(port, operator_home(port, credential))
    let asked =
      home_socket(port, home, [#("x-create-workspace", ready.state_root)])
    assert asked.status == 290
    let created = session_of(asked.body)
    let assert Ok(view) = manager.get(ready.registry, created)
    let assert Ok(folder) = list.last(string.split(ready.state_root, "/"))
    assert view.registration.name == folder
    let assert Ok(private) = manager.session_domain(ready.registry, created)
    assert private.scope == domain.WorkspacePrivate
  })
}

// A member's operator home is handed no capability, and a forged creation that
// reaches the daemon anyway is refused from the grant it holds, whatever the
// frame said. An owner's page minted to read is refused the same way. Nothing
// is created by any of them.
pub fn a_members_and_an_observers_home_create_nothing_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let session = create_session(ready, "create-refused", 1103)
    let before = session_count(ready, credential)
    let operator = [#("page", json.String("operator"))]
    let grant = member(ready, "ui-creator", session, access.Operator)
    let members_home = enter(port, home_link(port, grant, operator))
    let observers_home = enter(port, home_link(port, credential, []))
    let ask = [#("x-create-workspace", ready.state_root)]

    list.each([members_home, observers_home], fn(home) {
      let plain = home_socket(port, home, ask)
      assert plain.status == 289
      let forced = home_socket(port, home, [#("x-create-force", "yes"), ..ask])
      assert forced.status == 291
      assert forced.body == "NotOwner"
    })
    assert session_count(ready, credential) == before
  })
}

// The workspace is the owner's own list's and never a path: a directory the
// owner holds no session in is refused and nothing is created, whatever the
// frame named, and so is a name the page's text rule refuses.
pub fn a_forged_workspace_or_name_creates_nothing_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let _known = create_session(ready, "create-forged", 1104)
    let before = session_count(ready, credential)
    let home = enter(port, operator_home(port, credential))
    list.each(
      ["/tmp", "/", ready.state_root <> "/..", "not a path", ""],
      fn(workspace) {
        let refused =
          home_socket(port, home, [#("x-create-workspace", workspace)])
        assert refused.status == 291
        assert refused.body == "NotKnown"
      },
    )
    list.each([string.repeat("n", 257)], fn(name) {
      let refused =
        home_socket(port, home, [
          #("x-create-workspace", ready.state_root),
          #("x-create-name", name),
        ])
      assert refused.status == 291
      assert refused.body == "InvalidName"
    })
    assert session_count(ready, credential) == before
  })
}

// A home that has ended but whose socket is still up creates nothing: its
// `open` no longer answers, which is also the epoch check, since a page's UI
// session lives in this daemon's memory and no earlier daemon's page answers.
pub fn an_ended_home_creates_nothing_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let _known = create_session(ready, "create-ended", 1105)
    let before = session_count(ready, credential)
    let home = enter(port, operator_home(port, credential))
    let refused =
      home_socket(port, home, [
        #("x-create-workspace", ready.state_root),
        #("x-switch-ended", "yes"),
      ])
    assert refused.status == 291
    assert refused.body == "NotOwner"
    assert session_count(ready, credential) == before
  })
}

// The steps of `create_for` against the real registry, one at a time, with a
// `create` that counts its calls: an owner's page creates, and each of a revoked
// credential, a principal that is not the one the page was admitted for, a page
// minted to read, an ended page and a member's credential is refused before
// `create` is asked.
pub fn each_standing_that_is_not_the_owners_asks_nothing_test() {
  fixture(fn(ready, _, credential) {
    let existing = create_session(ready, "standing-known", 1106)
    let #(standing, tickets) =
      creator_standing(ready, credential, access.Operator)
    let asked = process.new_subject()
    let create = counting_create(ready, existing, asked)
    let attempt = fn(standing) {
      ui_socket.create_for(
        standing,
        tickets,
        page_open,
        create,
        no_release,
        new_folder.check(_, ready.state_root),
        creations.Drawn(ready.state_root),
        "x",
        creations.Private,
        creations.default_roles,
        within: 2000,
      )
    }

    // A principal that is not the one the credential authenticates as.
    assert attempt(ui_socket.Standing(..standing, principal: "someone-else"))
      == creations.Declined(creations.NotOwner)

    // A page minted to read.
    assert attempt(ui_socket.Standing(..standing, ceiling: access.Observer))
      == creations.Declined(creations.NotOwner)

    // A page that has ended.
    assert ui_socket.create_for(
        standing,
        tickets,
        fn() { Error(Nil) },
        create,
        no_release,
        new_folder.check(_, ready.state_root),
        creations.Drawn(ready.state_root),
        "x",
        creations.Private,
        creations.default_roles,
        within: 2000,
      )
      == creations.Declined(creations.NotOwner)

    // A member's credential, with the member's own principal.
    let grant = member(ready, "ui-not-owner", existing, access.Operator)
    let #(members, _) = creator_standing(ready, grant, access.Operator)
    assert attempt(ui_socket.Standing(..members, principal: "ui-not-owner"))
      == creations.Declined(creations.NotOwner)

    // A revoked credential authenticates as nobody.
    revoke(ready.state_root, credential)
    assert attempt(standing) == creations.Declined(creations.NotOwner)
    assert process.receive(asked, 0) == Error(Nil)
  })
}

// The owner's page creates, and a creation the daemon refused before it asked
// costs no allowance: an invalid name and an unknown workspace come first, and
// then ten creations are granted and the eleventh in the hour is refused with
// the counting `create` never asked a second time for it.
pub fn the_eleventh_creation_in_an_hour_is_refused_test() {
  fixture(fn(ready, _, credential) {
    let existing = create_session(ready, "limit-known", 1107)
    let #(standing, tickets) =
      creator_standing(ready, credential, access.Operator)
    let asked = process.new_subject()
    let create = counting_create(ready, existing, asked)
    let attempt = fn(workspace, name) {
      ui_socket.create_for(
        standing,
        tickets,
        page_open,
        create,
        no_release,
        new_folder.check(_, ready.state_root),
        creations.Drawn(workspace),
        name,
        creations.Shareable,
        creations.default_roles,
        within: 2000,
      )
    }
    assert attempt(ready.state_root, "a\nb")
      == creations.Declined(creations.InvalidName)
    assert attempt("/nowhere", "ok") == creations.Declined(creations.NotKnown)
    assert process.receive(asked, 0) == Error(Nil)

    let granted =
      list.index_map(list.repeat(Nil, ui_sessions.creation_limit), fn(_, index) {
        let number = index + 1
        let assert creations.Ticketed(path) =
          attempt(ready.state_root, "session " <> int.to_string(number))
          as "the creation is granted"
        assert string.starts_with(path, "/ui/sessions/")
        let assert Ok(creation) = process.receive(asked, 0)
        assert creation.name == "session " <> int.to_string(number)
        assert creation.workspace == ready.state_root
        assert string.starts_with(creation.request_key, "web-")
      })
      |> list.length
    assert granted == ui_sessions.creation_limit
    assert attempt(ready.state_root, "one too many")
      == creations.Declined(creations.TooMany)
    assert process.receive(asked, 0) == Error(Nil)
  })
}

// Two creations never share a key, so a press repeated by a program cannot be
// mistaken for a retry of the first and silently return it.
pub fn each_creation_draws_its_own_request_key_test() {
  fixture(fn(ready, _, credential) {
    let existing = create_session(ready, "keys-known", 1108)
    let #(standing, tickets) =
      creator_standing(ready, credential, access.Operator)
    let asked = process.new_subject()
    let create = counting_create(ready, existing, asked)
    list.each([1, 2], fn(_) {
      let _ =
        ui_socket.create_for(
          standing,
          tickets,
          page_open,
          create,
          no_release,
          new_folder.check(_, ready.state_root),
          creations.Drawn(ready.state_root),
          "k",
          creations.Private,
          creations.default_roles,
          within: 2000,
        )
      Nil
    })
    let assert Ok(first) = process.receive(asked, 0)
    let assert Ok(second) = process.receive(asked, 0)
    assert first.request_key != second.request_key
  })
}

// A session that was made and did not open is reported as that, which says it
// exists, and not as a refusal that says nothing was made.
pub fn a_session_that_does_not_open_is_reported_as_created_test() {
  fixture(fn(ready, _, credential) {
    let existing = create_session(ready, "unopened-known", 1109)
    let #(standing, tickets) =
      creator_standing(ready, credential, access.Operator)
    let asked = process.new_subject()

    // The creation answers with a session identity the registry cannot open.
    let create = fn(principal, creation, scope) {
      let _ = principal
      let _ = scope
      process.send(asked, creation)
      let assert Ok(view) = manager.get(ready.registry, existing)
      Ok(
        manager.View(
          ..view,
          registration: catalogue.Registration(
            ..view.registration,
            id: "01900000-0000-7000-8000-000000000000",
          ),
        ),
      )
    }
    assert ui_socket.create_for(
        standing,
        tickets,
        page_open,
        create,
        no_release,
        new_folder.check(_, ready.state_root),
        creations.Drawn(ready.state_root),
        "x",
        creations.Private,
        creations.default_roles,
        within: 300,
      )
      == creations.Unstarted(None, creations.InList)
    let assert Ok(_) = process.receive(asked, 0)
    Nil
  })
}

// The wait runs in a task of its own: the call that starts it returns before
// the creation has answered, and the answer then arrives from the task, a
// process other than the caller, as the message the page's component is
// waiting for.
pub fn the_creation_runs_off_the_callers_process_test() {
  fixture(fn(ready, _, credential) {
    let existing = create_session(ready, "task-known", 1110)
    let #(standing, tickets) =
      creator_standing(ready, credential, access.Operator)
    let slow = fn(principal, creation, scope) {
      process.sleep(300)
      counting_create(ready, existing, process.new_subject())(
        principal,
        creation,
        scope,
      )
    }
    let answers = process.new_subject()
    ui_socket.create_task(
      standing,
      tickets,
      page_open,
      slow,
      no_release,
      new_folder.check(_, ready.state_root),
      creations.Drawn(ready.state_root),
      "slow",
      creations.Private,
      creations.default_roles,
      fn(answer) { process.send(answers, #(answer, process.self())) },
    )
    assert process.receive(answers, 0) == Error(Nil)
    let assert Ok(#(creations.Ticketed(path), task)) =
      process.receive(answers, 10_000)
      as "the task answers once the session is resident"
    assert string.starts_with(path, "/ui/sessions/")
    assert task != process.self()
  })
}

// --- a session in a folder that holds none (protocol-change/074) -------------

// The startup reason a session named `broken-...` is refused with: the owner's
// configuration message, with markup in it so a test can see it drawn as text.
const broken_reason = "profile <b>fast</b> is not defined in /etc/loom/loom.toml"

// A creation through the registry's own turn, as the control command makes it,
// under a seed that gives each call its own identity.
fn registry_create(
  ready: root.Ready(String),
  seed: Int,
) -> fn(access.Principal, manager.Creation, domain.Scope) ->
  Result(manager.View, String) {
  fn(_, creation, scope) {
    manager.create_scoped(
      ready.registry,
      creation,
      directory: ready.sessions_directory,
      generator: ids.generator(clock.fixed(0), seed),
      scope:,
      configuration: "",
    )
    |> result.replace_error("unavailable")
  }
}

// The release a page's creation task holds: the registry's own delete, made
// with the owner's credential and this daemon's epoch.
fn registry_release(
  ready: root.Ready(String),
  credential: String,
) -> fn(String) -> Result(Nil, manager.AdminError) {
  fn(session) {
    manager.delete_session(
      ready.registry,
      digest_of(credential),
      ready.epoch,
      session,
      ready.sessions_directory,
    )
    |> result.replace(Nil)
  }
}

// A release the registry would refuse, for a test that does not look at it.
fn no_release(_session: String) -> Result(Nil, manager.AdminError) {
  Error(manager.AdminUnavailable)
}

// A directory the test treats as the owner's home: canonical, empty, and made
// afresh for each test, with a folder `proj` inside it.
fn owners_home(name: String) -> String {
  let assert Ok(home) = bootstrap.canonical_directory(extensions.scratch(name))
    as "the scratch directory resolves"
  let assert Ok(Nil) = simplifile.create_directory_all(home <> "/proj")
    as "the project folder is made"
  home
}

// The whole path through the router: the owner types a path under their home
// into the form for another folder, the daemon makes it canonical, creates the
// session there with the typed name, mints a ticket, and remembers the folder.
pub fn a_typed_folder_creates_a_session_and_is_remembered_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let home = owners_home("typed-creates")
    let before = session_count(ready, credential)
    let owner = enter(port, operator_home(port, credential))
    let asked =
      home_socket(port, owner, [
        #("x-create-workspace", "~/proj/../proj"),
        #("x-create-typed", "yes"),
        #("x-create-home", home),
        #("x-create-name", "typed one"),
      ])
    assert asked.status == 290
    assert string.starts_with(asked.body, "/ui/sessions/")
    assert session_count(ready, credential) == before + 1

    // The session is in the canonical folder, not in the text that was typed.
    let assert Ok(view) = manager.get(ready.registry, session_of(asked.body))
    assert view.registration.workspace == home <> "/proj"
    assert view.registration.name == "typed one"

    // The folder is remembered, once, as the newest.
    let assert Ok([newest, ..]) = manager.recent_folders(ready.registry)
    assert newest.workspace == home <> "/proj"
  })
}

// A path the daemon will not use creates nothing and is answered in a reason's
// fixed words: outside the home directory, the home directory itself, a hidden
// folder, one that is not there, a file, a link that leaves home and a path
// that is not absolute.
pub fn a_typed_path_that_is_not_a_usable_folder_creates_nothing_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let home = owners_home("typed-refused")
    let assert Ok(Nil) = simplifile.create_directory_all(home <> "/.hidden")
      as "a hidden folder"
    let assert Ok(Nil) = simplifile.write(home <> "/file.txt", "x") as "a file"
    let assert Ok(outside) =
      bootstrap.canonical_directory(extensions.scratch("typed-outside"))
      as "a folder outside home"
    let assert Ok(Nil) = simplifile.create_symlink(outside, home <> "/escape")
      as "a link that leaves home"
    let before = session_count(ready, credential)
    let owner = enter(port, operator_home(port, credential))
    let ask = fn(path) {
      home_socket(port, owner, [
        #("x-create-workspace", path),
        #("x-create-typed", "yes"),
        #("x-create-home", home),
      ])
    }
    list.each([outside, "/", "/etc", "~/escape", "~/escape/.."], fn(path) {
      let refused = ask(path)
      assert refused.status == 291
      assert refused.body == "OutsideHome"
    })
    list.each([home, "~"], fn(path) {
      let refused = ask(path)
      assert refused.status == 291
      assert refused.body == "HomeItself"
    })
    let hidden = ask("~/.hidden")
    assert hidden.status == 291
    assert hidden.body == "HiddenFolder"
    list.each(["~/missing", "~/file.txt", "proj", "", "~other/proj"], fn(path) {
      let refused = ask(path)
      assert refused.status == 291
      assert refused.body == "NotAFolder"
    })
    assert session_count(ready, credential) == before
    assert manager.recent_folders(ready.registry) == Ok([])
  })
}

// A forged typed creation from a member's page or an observer-ceiling page is
// refused for who they are, before the path is looked at, and creates nothing.
pub fn a_forged_typed_creation_from_another_page_creates_nothing_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let session = create_session(ready, "typed-forged", 1121)
    let home = owners_home("typed-forged-home")
    let before = session_count(ready, credential)
    let operator = [#("page", json.String("operator"))]
    let grant = member(ready, "ui-typist", session, access.Operator)
    let members_home = enter(port, home_link(port, grant, operator))
    let observers_home = enter(port, home_link(port, credential, []))
    list.each([members_home, observers_home], fn(page) {
      let forced =
        home_socket(port, page, [
          #("x-create-force", "yes"),
          #("x-create-workspace", home <> "/proj"),
          #("x-create-typed", "yes"),
          #("x-create-home", home),
        ])
      assert forced.status == 291
      assert forced.body == "NotOwner"
    })
    assert session_count(ready, credential) == before
    assert manager.recent_folders(ready.registry) == Ok([])
  })
}

// A folder that was remembered is creatable after its sessions are gone, is
// judged again at the press, and is refused with a plain reason once the
// directory has been removed. A path the daemon does not remember is not
// creatable as a place the page drew, whatever the frame said.
pub fn a_remembered_folder_is_judged_again_at_the_press_test() {
  fixture(fn(ready, _, credential) {
    let existing = create_session(ready, "remembered-known", 1122)
    let home = owners_home("remembered")
    let folder = home <> "/proj"
    let #(standing, tickets) =
      creator_standing(ready, credential, access.Operator)
    let asked = process.new_subject()
    let create = counting_create(ready, existing, asked)
    let attempt = fn(path) {
      ui_socket.create_for(
        standing,
        tickets,
        page_open,
        create,
        no_release,
        new_folder.check_in(_, home, ready.state_root),
        creations.Drawn(path),
        "again",
        creations.Private,
        creations.default_roles,
        within: 2000,
      )
    }

    // Not remembered, not held: not in the owner's list.
    assert attempt(folder) == creations.Declined(creations.NotKnown)
    assert process.receive(asked, 0) == Error(Nil)

    // Remembered: creatable, in the folder the daemon knows.
    manager.remember_folder(ready.registry, folder)
    let assert creations.Ticketed(_) = attempt(folder)
    let assert Ok(creation) = process.receive(asked, 0)
    assert creation.workspace == folder

    // The directory is removed: the entry is still listed but the press is
    // refused in plain words, and nothing is asked of the registry.
    let assert Ok(Nil) = simplifile.delete(folder) as "the folder is removed"
    assert attempt(folder) == creations.Declined(creations.NotAFolder)
    assert process.receive(asked, 0) == Error(Nil)

    // A remembered folder outside the home directory (a terminal made it) is
    // refused too.
    manager.remember_folder(ready.registry, "/etc")
    assert attempt("/etc") == creations.Declined(creations.OutsideHome)
  })
}

// The page's list is the owner's remembered folders that a session may start in:
// newest first, only those inside the home directory, and only for the owner.
// Forgetting names the identity the list gave and answers the list that remains.
pub fn the_owners_recent_folders_are_listed_and_forgotten_test() {
  fixture(fn(ready, _, credential) {
    let home = owners_home("recents")
    let assert Ok(Nil) = simplifile.create_directory_all(home <> "/second")
      as "a second folder"
    manager.remember_folder(ready.registry, home <> "/proj")
    manager.remember_folder(ready.registry, "/etc")
    manager.remember_folder(ready.registry, home <> "/second")
    manager.remember_folder(ready.registry, home <> "/.hidden")
    let #(standing, _) = creator_standing(ready, credential, access.Operator)
    let listed = ui_socket.recent_for(standing, page_open, home)
    assert list.map(listed, fn(entry) { entry.path })
      == [home <> "/second", home <> "/proj"]

    // A folder remembered again moves to the front under a new identity, so the
    // old one forgets nothing.
    let assert [second, proj] = listed
    manager.remember_folder(ready.registry, home <> "/proj")
    assert ui_socket.forget_for(standing, page_open, home, proj.id)
      |> list.map(fn(entry) { entry.path })
      == [home <> "/proj", home <> "/second"]
    let assert [fresh, _] = ui_socket.recent_for(standing, page_open, home)
    assert fresh.id != proj.id

    // Forgetting a listed identity removes just that folder, and forgetting it
    // again changes nothing.
    assert ui_socket.forget_for(standing, page_open, home, second.id)
      |> list.map(fn(entry) { entry.path })
      == [home <> "/proj"]
    assert ui_socket.forget_for(standing, page_open, home, second.id)
      |> list.map(fn(entry) { entry.path })
      == [home <> "/proj"]

    // A page that has ended, one minted to read and a member's page are told of
    // no folder and forget nothing.
    let #(readonly, _) = creator_standing(ready, credential, access.Observer)
    assert ui_socket.recent_for(readonly, page_open, home) == []
    assert ui_socket.forget_for(readonly, page_open, home, fresh.id) == []
    assert ui_socket.recent_for(standing, fn() { Error(Nil) }, home) == []
    let existing = create_session(ready, "recents-known", 1123)
    let grant = member(ready, "ui-recents", existing, access.Operator)
    let #(members, _) = creator_standing(ready, grant, access.Operator)
    let members = ui_socket.Standing(..members, principal: "ui-recents")
    assert ui_socket.recent_for(members, page_open, home) == []
    assert ui_socket.forget_for(members, page_open, home, fresh.id) == []
    assert list.map(ui_socket.recent_for(standing, page_open, home), fn(entry) {
        entry.path
      })
      == [home <> "/proj"]
  })
}

// --- the browser login (protocol-change/065, PR 8) -----------------------------

@external(erlang, "client_test_ffi", "reductions_of")
fn reductions_of(pid: process.Pid) -> Int

@external(erlang, "client_test_ffi", "log_capture_start")
fn log_capture_start() -> Nil

@external(erlang, "client_test_ffi", "log_capture_stop")
fn log_capture_stop() -> List(String)

// What a remembered exchange handed one browser: the page it opened, the
// login's token (the cookie's value), its key, the nonce the page kept, and the
// cookie's lifetime in seconds.
type Signed {
  Signed(
    page: Entered,
    token: String,
    key: String,
    nonce: String,
    max_age: Int,
    cookies: List(String),
  )
}

// Every `Set-Cookie` of a response, in the order the daemon wrote them.
fn set_cookies(answer: Answer) -> List(String) {
  list.filter_map(answer.headers, fn(header) {
    case header.0 {
      "set-cookie" -> Ok(header.1)
      _ -> Error(Nil)
    }
  })
}

// An exchange that set a login, read the way the browser's enter script reads
// it: the cookie from the headers, the key and nonce from the body.
fn signed_in(answer: Answer) -> Signed {
  let page = entered(answer)
  let cookies = set_cookies(answer)
  let assert [cookie] =
    list.filter(cookies, fn(set) { string.starts_with(set, "loom_login=") })
    as "the exchange set one login cookie"
  let assert Ok(#(pair, attributes)) = string.split_once(cookie, "; ")
    as "attributes follow the token"
  let assert Ok(#(_, max_age)) = string.split_once(attributes, "Max-Age=")
    as "the login cookie has a lifetime"
  let assert Ok(seconds) = int.parse(max_age) as "the lifetime is a number"
  Signed(
    page:,
    token: string.drop_start(pair, string.length("loom_login=")),
    key: attribute(answer.body, "data-login-key"),
    nonce: attribute(answer.body, "data-login-nonce"),
    max_age: seconds,
    cookies:,
  )
}

// `loom ui`: a home ticket the daemon mints with the login unless declined,
// exchanged by a browser.
fn sign_in(port: Int, credential: String) -> Signed {
  signed_in(exchange(port, operator_home(port, credential)))
}

// A home ticket the launcher asked not to remember (`loom ui --no-remember`).
fn forgotten_home(port: Int, credential: String) -> String {
  home_link(port, credential, [
    #("page", json.String("operator")),
    #("remember", json.Bool(False)),
  ])
}

// The resume, as the resume page's own form posts it: this origin's
// `Sec-Fetch-Site`, the form's type and length, the cookie header the browser
// sends, and the nonce in the body.
fn resume(
  port: Int,
  key: String,
  cookie: String,
  nonce: String,
  more: List(#(String, String)),
) -> Answer {
  let body = "nonce=" <> nonce
  let defaults = [
    host(port),
    #("sec-fetch-site", "same-origin"),
    #("content-type", "application/x-www-form-urlencoded"),
    #("content-length", int.to_string(string.byte_size(body))),
    #("cookie", cookie),
  ]
  send_request(
    port,
    "POST",
    "/ui/l/" <> key <> "/home",
    list.append(defaults, more),
    body,
  )
}

fn resume_as(port: Int, signed: Signed) -> Answer {
  resume(port, signed.key, "loom_login=" <> signed.token, signed.nonce, [])
}

// The root key the daemon signs logins under, read from the state directory the
// way a restart reads it.
fn root_key(ready: root.Ready(String)) -> login.RootKey {
  let assert Ok(login.Present(key)) = login.probe_root(ready.state_root)
    as "the daemon wrote its login key"
  key
}

fn id_of(token: String) -> String {
  let assert Ok(parsed) = login.parse(token) as "the token parses"
  login.id(parsed)
}

fn parsed(token: String) -> login.Parsed {
  let assert Ok(found) = login.parse(token) as "the token parses"
  found
}

// The six caveats a login is minted with, for a token a test signs itself.
fn six(
  principal: String,
  key: String,
  nonce: String,
  expires_at_ms: Int,
) -> List(login.Caveat) {
  [
    login.Caveat("p", principal),
    login.Caveat("c", "operator"),
    login.Caveat("r", "workspace"),
    login.Caveat("e", int.to_string(expires_at_ms)),
    login.Caveat("k", key),
    login.Caveat("n", login.nonce_digest(nonce)),
  ]
}

// A refusal of a login is the same `401` document whatever the reason, with no
// cookie and nothing the request carried.
fn refused_login(answer: Answer, signed: Signed) -> Nil {
  assert answer.status == 401
  assert string.contains(answer.body, "loom ui")
  assert set_cookies(answer) == []
  assert !string.contains(answer.body, signed.token)
  assert !string.contains(answer.body, signed.key)
  assert !string.contains(answer.body, signed.nonce)
  Nil
}

// One control command as `credential` sends it, with the daemon's epoch in
// the body when the command is fenced.
fn control(
  port: Int,
  credential: String,
  command: String,
  fields: List(#(String, json.JsonValue)),
) -> json.JsonValue {
  let #(socket, _) = daemon_server_test.connect(port, credential, "/v2/control")
  let hello = daemon_server_test.frame(socket, within_ms: 1000)
  let assert Ok(hello_body) = field(hello, "body") as "the hello has a body"
  let assert Ok(json.String(epoch)) = field(hello_body, "epoch")
    as "the hello names the epoch"
  let reply =
    daemon_server_test.send(
      socket,
      1,
      command,
      json.Object([#("epoch", json.String(epoch)), ..fields]),
      within_ms: 1000,
    )
  let _ = ffi_ws.tcp_close(socket)
  reply
}

// The fingerprints the credential's principal lists as its sign-ins.
fn listed_signins(port: Int, credential: String) -> List(json.JsonValue) {
  let reply = control(port, credential, "credentials.signins", [])
  assert field(reply, "event") == Ok(json.String("credentials.signins"))
  let assert Ok(body) = field(reply, "body") as "a body"
  let assert Ok(json.Array(rows)) = field(body, "signins") as "the rows"
  rows
}

fn fingerprints(rows: List(json.JsonValue)) -> List(String) {
  list.map(rows, fn(row) {
    let assert Ok(json.String(fingerprint)) = field(row, "fingerprint")
      as "a fingerprint"
    fingerprint
  })
}

fn sha256_text(text: String) -> String {
  text
  |> bit_array.from_string
  |> bootstrap.sha256
  |> bit_array.base16_encode
  |> string.lowercase
}

// An exchange of `loom ui` sets a login whose cookie has exactly the attributes
// 065 gives it, carries the key and nonce in the body, and leaves one row; the
// page's own cookie keeps no `Max-Age`, since only the login lasts a month.
pub fn a_remembered_exchange_sets_the_login_beside_the_page_test() {
  fixture(fn(ready, port, credential) {
    let answer = exchange(port, operator_home(port, credential))
    let signed = signed_in(answer)

    // Two cookies, the page's first. The page's has no lifetime and the login's
    // is thirty days, the same instant the token's expiry names.
    let assert [page_cookie, login_cookie] = signed.cookies
    assert string.starts_with(page_cookie, "loom_ui=")
    assert !string.contains(page_cookie, "Max-Age")
    assert string.ends_with(
      login_cookie,
      "; HttpOnly; SameSite=Strict; Path=/ui/l/"
        <> signed.key
        <> "; Max-Age="
        <> int.to_string(signed.max_age),
    )
    assert signed.max_age <= 2_592_000
    assert signed.max_age >= 2_591_990

    // The token is what the grammar says, signed by this daemon's key and for
    // this principal, and the body delivers the nonce once.
    assert string.byte_size(signed.token) <= login.max_token_bytes
    let now = bootstrap.system_time_ms()
    let assert Ok(opened) =
      login.open(
        root_key(ready),
        signed.token,
        now_ms: now,
        key: signed.key,
        nonce: signed.nonce,
      )
      as "the daemon's own key opens the token"
    assert opened.allowance.principal == ready.owner.id
    assert opened.allowance.ceiling == login.Operator
    assert string.byte_size(signed.nonce) == 64
    assert string.byte_size(signed.key) == 32
    assert signed.max_age * 1000 <= opened.allowance.expires_at_ms - now + 1000

    // The principal has one sign-in now, and it is this one: the row is keyed
    // by the digest of the identifier.
    let rows = listed_signins(port, credential)
    assert fingerprints(rows)
      == [string.slice(login.row_digest(opened.id), 0, 16)]
  })
}

// `loom ui --no-remember` opens the page and sets nothing: one cookie, no key
// or nonce in the body, no row.
pub fn no_remember_sets_no_login_test() {
  fixture(fn(_, port, credential) {
    let answer = exchange(port, forgotten_home(port, credential))
    let page = entered(answer)
    assert list.length(set_cookies(answer)) == 1
    assert !string.contains(answer.body, "data-login")
    assert string.starts_with(page.page, "/ui/p/")
    assert listed_signins(port, credential) == []
  })
}

// A link for one session is not a home, and neither is a ticket a page mints:
// no exchange but a home's, from `loom ui`, a claim or a device link, sets a
// login. The launcher cannot ask a session link to remember either.
pub fn session_links_and_switch_tickets_set_no_login_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let session = create_session(ready, "no-login", 970)
    let answer = exchange(port, operate(port, credential, session))
    assert list.length(set_cookies(answer)) == 1
    assert !string.contains(answer.body, "data-login")

    // A home page's row press asks for a ticket, and exchanging it sets no
    // login either.
    let home = enter(port, operator_home(port, credential))
    let pressed = press_row(port, home, session)
    assert pressed.status == 290
    let switched = exchange(port, pressed.body)
    assert switched.status == 200
    assert list.length(set_cookies(switched)) == 1
    assert !string.contains(switched.body, "data-login")

    // The way home from a session page is a ticket too, and a forgotten one.
    let #(socket, _) =
      daemon_server_test.connect(port, credential, "/v2/control")
    let _hello = daemon_server_test.frame(socket, within_ms: 1000)
    let reply =
      daemon_server_test.send(
        socket,
        1,
        "ui.link",
        json.Object([
          #("session_id", json.String(session)),
          #("remember", json.Bool(True)),
        ]),
        within_ms: 1000,
      )
    let _ = ffi_ws.tcp_close(socket)
    assert field(reply, "event") == Ok(json.String("error"))
  })
}

// The bookmark: a new browser with no page and no tab, only the cookie and the
// nonce its storage kept, is served the resume page, posts its nonce and lands
// on a home page. No `loom`, no ticket.
pub fn the_bookmark_resumes_a_home_without_loom_test() {
  fixture(fn(_, port, credential) {
    let signed = sign_in(port, credential)
    let bookmark = "/ui/l/" <> signed.key <> "/home"

    // The resume page is a fixed document with one form, served under the one
    // policy that lets a form submit to this origin; every other document keeps
    // `form-action 'none'`.
    let resume_page =
      get(port, bookmark, [host(port), #("sec-fetch-site", "none")])
    assert resume_page.status == 200
    assert string.contains(resume_page.body, "name=\"nonce\"")
    assert string.contains(resume_page.body, "method=\"post\"")
    assert !string.contains(resume_page.body, signed.token)
    assert !string.contains(resume_page.body, signed.key)
    let assert Ok(policy) =
      list.key_find(resume_page.headers, "content-security-policy")
    assert string.contains(policy, "form-action 'self'")
    assert referrer_policy(resume_page) == Ok("no-referrer")
    let other = open_page(port, signed.page)
    let assert Ok(other_policy) =
      list.key_find(other.headers, "content-security-policy")
    assert string.contains(other_policy, "form-action 'none'")

    // The resume page's script and the enter script both spell the storage
    // item the nonce lives under.
    let script = get(port, "/ui/assets/web_view_resume.js", [host(port)])
    assert script.status == 200
    assert string.contains(script.body, page.login_nonce_item)
    let enter_script = get(port, "/ui/assets/web_view_enter.js", [host(port)])
    assert string.contains(enter_script.body, page.login_nonce_item)

    // Posting the nonce with the cookie mints a home page. The login's expiry
    // is fixed when it is made: a resume reads it and never moves it.
    let expiry = fn() {
      list.map(listed_signins(port, credential), fn(row) {
        field(row, "expires_at_ms")
      })
    }
    let before = expiry()
    assert before != [Error(Nil)]
    let resumed = resume_as(port, signed)
    assert resumed.status == 200
    let home = entered(resumed)
    assert string.ends_with(home.page, "/home")
    assert home.nonce != signed.page.nonce
    assert home.cookie != signed.page.cookie

    // It mints a page and not another login: the resume sets one cookie, and the
    // login ends when it always did.
    assert list.length(set_cookies(resumed)) == 1
    assert expiry() == before
    assert !string.contains(resumed.body, "data-login")
    let shown = open_page(port, home)
    assert shown.status == 200
    assert string.contains(shown.body, "Home — Loom")

    // The page is the login's: it is a resumed home, at the login's ceiling,
    // and the login it belongs to is the one that resumed it.
    let upgraded = home_socket(port, home, [])
    assert upgraded.status == 280
    assert list.key_find(upgraded.headers, "x-page-origin") == Ok("resumed")
    let assert Ok(fingerprint) = list.key_find(upgraded.headers, "x-page-login")
    assert fingerprints(listed_signins(port, credential)) == [fingerprint]
    let assert [_, "operator", ..] = string.split(upgraded.body, "\n")

    // The first page, which a `loom ui` exchange opened, is a fresh home.
    let first = home_socket(port, signed.page, [])
    assert list.key_find(first.headers, "x-page-origin") == Ok("fresh")
    assert list.key_find(first.headers, "x-page-login") == Ok(fingerprint)
  })
}

// The resume page and the resume are held to their sender and their size.
pub fn the_resume_is_a_same_origin_form_of_one_small_field_test() {
  fixture(fn(_, port, credential) {
    let signed = sign_in(port, credential)
    let path = "/ui/l/" <> signed.key <> "/home"
    let cookie = "loom_login=" <> signed.token

    // The page is a navigation, from outside any page or from this origin.
    let from_elsewhere = fn(site) {
      get(port, path, [host(port), #("sec-fetch-site", site)]).status
    }
    assert from_elsewhere("none") == 200
    assert from_elsewhere("same-origin") == 200
    assert from_elsewhere("same-site") == 403
    assert from_elsewhere("cross-site") == 403
    assert get(port, path, [host(port)]).status == 403
    assert get(port, "/ui/l/short/home", [
        host(port),
        #("sec-fetch-site", "none"),
      ]).status
      == 404
    assert get(port, path, [
        #("host", "evil.example"),
        #("sec-fetch-site", "none"),
      ]).status
      == 403

    // The post is this origin's own page and nothing else, `none` included.
    let sent_from = fn(site) {
      resume(port, signed.key, cookie, signed.nonce, [#("sec-fetch-site", site)]).status
    }
    assert sent_from("same-origin") == 200
    assert sent_from("same-site") == 403
    assert sent_from("cross-site") == 403
    assert sent_from("none") == 403
    assert send_request(
        port,
        "POST",
        path,
        [
          host(port),
          #("content-type", "application/x-www-form-urlencoded"),
          #("content-length", "70"),
          #("cookie", cookie),
        ],
        "nonce=" <> signed.nonce,
      ).status
      == 403

    // The form is one field of the declared size and type.
    let post = fn(headers, body) {
      send_request(
        port,
        "POST",
        path,
        list.append(
          [host(port), #("sec-fetch-site", "same-origin"), #("cookie", cookie)],
          headers,
        ),
        body,
      ).status
    }
    let form = [#("content-type", "application/x-www-form-urlencoded")]
    let sized = fn(body) {
      list.append(form, [
        #("content-length", int.to_string(string.byte_size(body))),
      ])
    }
    let good = "nonce=" <> signed.nonce
    assert post(sized(good), good) == 200
    assert post(
        [#("content-type", "text/plain"), #("content-length", "70")],
        good,
      )
      == 400
    assert post(form, good) == 400
    let big = string.repeat("a", 2000)
    assert post(sized(big), big) == 400
    let extra = good <> "&other=1"
    assert post(sized(extra), extra) == 400
    let short = "nonce=00"
    assert post(sized(short), short) == 400
    let upper = "nonce=" <> string.uppercase(signed.nonce)
    assert post(sized(upper), upper) == 400
    let other = "other=" <> signed.nonce
    assert post(sized(other), other) == 400
  })
}

// Everything that is not a login that opens is refused as one: a forged
// signature, a caveat removed, an unknown caveat, capitals, the wrong key in the
// path, the wrong nonce, an expired login, a row that was never made, a row of
// another principal and a row that was revoked. Each is the same `401` with no
// cookie and nothing echoed, and none of the first seven makes the registry do
// any work: the chain and the caveats are checked before the catalogue is asked.
pub fn every_token_that_does_not_open_is_refused_alike_test() {
  fixture(fn(ready, port, credential) {
    let signed = sign_in(port, credential)
    let id = id_of(signed.token)
    let root = root_key(ready)
    let owner = ready.owner.id
    let soon = bootstrap.system_time_ms() + 600_000
    let good = six(owner, signed.key, signed.nonce, soon)
    let attempt = fn(token) {
      resume(port, signed.key, "loom_login=" <> token, signed.nonce, [])
    }
    let registry = manager.pid(ready.registry)

    // Pure refusals: none of them reaches the registry.
    let before = reductions_of(registry)
    refused_login(
      attempt(string.replace(signed.token, owner, "owner-other")),
      signed,
    )
    refused_login(attempt(login.sign(root_key_other(), id, good)), signed)
    refused_login(attempt(login.sign(root, id, list.take(good, 5))), signed)
    refused_login(
      attempt(login.sign(root, id, list.append(good, [login.Caveat("x", "1")]))),
      signed,
    )
    refused_login(
      attempt(string.replace(signed.token, id, string.uppercase(id))),
      signed,
    )
    refused_login(attempt(signed.token <> "00"), signed)
    refused_login(attempt(""), signed)
    refused_login(attempt(string.repeat("a", 400)), signed)

    // The wrong key in the path and the wrong nonce in the body, and an expiry
    // in the past, are caveats the request fails.
    refused_login(
      resume(
        port,
        string.repeat("0", 32),
        "loom_login=" <> signed.token,
        signed.nonce,
        [],
      ),
      signed,
    )
    refused_login(
      resume(
        port,
        signed.key,
        "loom_login=" <> signed.token,
        string.repeat("0", 64),
        [],
      ),
      signed,
    )
    refused_login(
      attempt(login.sign(root, id, six(owner, signed.key, signed.nonce, 1000))),
      signed,
    )
    refused_login(resume(port, signed.key, "", signed.nonce, []), signed)
    assert reductions_of(registry) == before

    // A genuine chain is looked up. A row that was never made, a row of
    // another principal and a revoked row are each refused after that.
    let unknown =
      login.sign(root, login.fresh_id(token.production_entropy()), good)
    refused_login(attempt(unknown), signed)
    assert reductions_of(registry) > before
    refused_login(
      attempt(login.sign(
        root,
        id,
        six("someone-else", signed.key, signed.nonce, soon),
      )),
      signed,
    )
    let fingerprint = string.slice(login.row_digest(id), 0, 16)
    let revoked =
      control(port, credential, "credentials.revoke_login", [
        #("fingerprint", json.String(fingerprint)),
      ])
    assert field(revoked, "event")
      == Ok(json.String("credentials.revoke_login"))
    refused_login(resume_as(port, signed), signed)
  })
}

fn root_key_other() -> login.RootKey {
  login.draw_root(token.production_entropy())
}

// A cookie another page planted under a longer path is sent first, and must not
// deny the person their own: the first value that opens is the login. Four
// values are tried and no more, so a request stuffed with cookies costs four
// chain checks at most.
pub fn a_planted_login_cookie_does_not_deny_the_real_one_test() {
  fixture(fn(ready, port, credential) {
    let signed = sign_in(port, credential)
    let root = root_key(ready)
    let planted = fn(n) {
      // A genuine token for another login, under another key: it opens nothing
      // at this path, as the cookie of an attacker's own login would not.
      login.sign(
        root,
        login.fresh_id(token.production_entropy()),
        six(
          "someone-else",
          login.fresh_key(token.production_entropy()),
          "00",
          1,
        )
          |> list.take(n),
      )
    }
    let real = "loom_login=" <> signed.token
    let with = fn(values: List(String)) {
      resume(
        port,
        signed.key,
        string.join(
          list.map(values, fn(value) { "loom_login=" <> value }),
          "; ",
        ),
        signed.nonce,
        [],
      )
    }
    assert with([signed.token]).status == 200
    assert with(["garbage", signed.token]).status == 200
    assert with([planted(6), "garbage", signed.token]).status == 200
    assert with(["a", "b", "c", signed.token]).status == 200

    // A fifth value is not read.
    refused_login(with(["a", "b", "c", "d", signed.token]), signed)

    // The real cookie among others of another name is found as well.
    let mixed =
      resume(
        port,
        signed.key,
        "loom_ui=x; " <> real <> "; other=y",
        signed.nonce,
        [],
      )
    assert mixed.status == 200
  })
}

// A token narrowed by a caveat the daemon appends verifies, and is held to the
// narrower value: a ceiling, an earlier expiry, one session. A wider repeat is
// ignored, two sessions allow nothing, and a login narrowed to a session mints
// a page of that session and never a home.
pub fn a_narrowed_token_is_held_to_the_narrower_value_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "narrowed", 971)
    let signed = sign_in(port, credential)
    let wide = parsed(signed.token)
    let cookie = fn(token) { "loom_login=" <> token }
    let resume_with = fn(token) {
      resume(port, signed.key, cookie(token), signed.nonce, [])
    }

    // The ceiling: an observer's token mints an observer's home, and a wider
    // repeat appended afterwards does not widen it.
    let observer = login.append(wide, login.Caveat("c", "observer"))
    let narrowed = resume_with(observer)
    assert narrowed.status == 200
    let assert [_, who, ..] =
      string.split(home_socket(port, entered(narrowed), []).body, "\n")
    assert who == "observer"
    let widened = login.append(parsed(observer), login.Caveat("c", "operator"))
    let again = resume_with(widened)
    assert again.status == 200
    let assert [_, still, ..] =
      string.split(home_socket(port, entered(again), []).body, "\n")
    assert still == "observer"

    // The expiry: an earlier instant appended holds until it comes, and a later
    // one appended after it does not extend it.
    let instant = bootstrap.system_time_ms() + 5000
    let early = login.append(wide, login.Caveat("e", int.to_string(instant)))
    let extended =
      login.append(parsed(early), login.Caveat("e", "9999999999999"))
    assert resume_with(extended).status == 200
    process.sleep(int.max(0, instant - bootstrap.system_time_ms()) + 100)
    refused_login(resume_with(extended), signed)
    refused_login(resume_with(early), signed)

    // One session: a page of that session, opened at the login's ceiling and
    // with the reach of a link for one session, and no home.
    let one = login.append(wide, login.Caveat("s", session))
    let opened = resume_with(one)
    assert opened.status == 200
    let page = entered(opened)
    assert string.ends_with(page.page, "/sessions/" <> session)
    assert !string.contains(opened.body, "/home")
    assert list.length(set_cookies(opened)) == 1
    let socket = open_socket(port, page, page.nonce)
    assert list.key_find(socket.headers, "x-page-reach") == Ok("one_session")
    assert list.key_find(socket.headers, "x-page-origin") == Ok("resumed")

    // Two different sessions allow nothing.
    let other = "0198c0de-0000-7000-8000-00000000ffff"
    let two = login.append(parsed(one), login.Caveat("s", other))
    refused_login(resume_with(two), signed)
  })
}

// Revoking one sign-in ends the pages that login minted at their next request
// and leaves the principal's other sign-ins, its bearer and the page a `loom ui`
// exchange opened. The owner may revoke any principal's; a member only its own.
pub fn revoking_one_sign_in_ends_its_pages_and_leaves_the_others_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "revoking", 972)
    let first = sign_in(port, credential)
    let second = sign_in(port, credential)
    let page = entered(resume_as(port, first))
    assert home_socket(port, page, []).status == 280
    assert open_page(port, page).status == 200

    let revoked =
      control(port, credential, "credentials.revoke_login", [
        #(
          "fingerprint",
          json.String(string.slice(login.row_digest(id_of(first.token)), 0, 16)),
        ),
      ])
    assert field(revoked, "event")
      == Ok(json.String("credentials.revoke_login"))

    // The page the revoked login minted is over: its keyed page and its socket
    // are refused, and the login resumes nothing.
    assert open_page(port, page).status == 401
    assert home_socket(port, page, []).status == 401
    refused_login(resume_as(port, first), first)

    // Everything else stands: the other sign-in, the bearer, and the page the
    // exchange opened, which is bound to the bearer and not to the login.
    assert resume_as(port, second).status == 200
    assert open_page(port, first.page).status == 200
    assert fingerprints(listed_signins(port, credential))
      == [string.slice(login.row_digest(id_of(second.token)), 0, 16)]

    // A member lists and revokes its own, never another's, and the owner may
    // name any principal.
    let shared = member(ready, "ui-login-member", session, access.Operator)
    let own = sign_in_as(port, shared)
    let own_fingerprint =
      string.slice(login.row_digest(id_of(own.token)), 0, 16)
    assert fingerprints(listed_signins(port, shared)) == [own_fingerprint]
    let naming_owner =
      control(port, shared, "credentials.signins", [
        #("principal_id", json.String(ready.owner.id)),
      ])
    assert field(naming_owner, "event") == Ok(json.String("error"))
    let revoking_owner =
      control(port, shared, "credentials.revoke_login", [
        #("principal_id", json.String(ready.owner.id)),
        #(
          "fingerprint",
          json.String(string.slice(login.row_digest(id_of(second.token)), 0, 16)),
        ),
      ])
    assert field(revoking_owner, "event") == Ok(json.String("error"))
    assert resume_as(port, second).status == 200
    let seen =
      control(port, credential, "credentials.signins", [
        #("principal_id", json.String("ui-login-member")),
      ])
    let assert Ok(seen_body) = field(seen, "body") as "a body"
    let assert Ok(json.Array(seen_rows)) = field(seen_body, "signins") as "rows"
    assert fingerprints(seen_rows) == [own_fingerprint]
    let by_owner =
      control(port, credential, "credentials.revoke_login", [
        #("principal_id", json.String("ui-login-member")),
        #("fingerprint", json.String(own_fingerprint)),
      ])
    assert field(by_owner, "event")
      == Ok(json.String("credentials.revoke_login"))
    refused_login(resume_as(port, own), own)

    // A fingerprint that names no sign-in of the principal is refused.
    let missing =
      control(port, credential, "credentials.revoke_login", [
        #("fingerprint", json.String(own_fingerprint)),
      ])
    assert field(missing, "event") == Ok(json.String("error"))
    let malformed =
      control(port, credential, "credentials.revoke_login", [
        #("fingerprint", json.String("not-a-fingerprint")),
      ])
    assert field(malformed, "event") == Ok(json.String("error"))
  })
}

// A member's `loom ui`, as the member's own credential asks for it.
fn sign_in_as(port: Int, member_credential: String) -> Signed {
  signed_in(exchange(port, operator_home(port, member_credential)))
}

// `credentials.revoke` and `credentials.rotate` end every login of the member
// with its bearer, since each revokes every active credential.
pub fn revoke_credentials_and_rotate_end_every_login_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "ends-all", 973)
    let revoked = member(ready, "ui-login-revoked", session, access.Operator)
    let rotated = member(ready, "ui-login-rotated", session, access.Operator)
    let revoked_login = sign_in_as(port, revoked)
    let rotated_login = sign_in_as(port, rotated)
    assert resume_as(port, revoked_login).status == 200
    assert resume_as(port, rotated_login).status == 200

    let answer =
      control(port, credential, "credentials.revoke", [
        #("principal_id", json.String("ui-login-revoked")),
      ])
    assert field(answer, "event") == Ok(json.String("credentials.revoke"))
    refused_login(resume_as(port, revoked_login), revoked_login)
    assert resume_as(port, rotated_login).status == 200

    let replacement = sha256_text("a replacement credential")
    let answer =
      control(port, credential, "credentials.rotate", [
        #("principal_id", json.String("ui-login-rotated")),
        #("credential_digest", json.String(replacement)),
      ])
    assert field(answer, "event") == Ok(json.String("credentials.rotate"))
    refused_login(resume_as(port, rotated_login), rotated_login)
  })
}

// 065's attack: the identifier is in the cookie, so anyone who sees the cookie
// knows it, and its digest is the row's key. Presented as a bearer, the bare
// identifier, the whole token and the digest of the identifier are each `401`
// on the control socket and on a session socket.
pub fn a_login_authenticates_on_no_v2_route_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "no-v2", 974)
    let signed = sign_in(port, credential)
    let id = id_of(signed.token)
    list.each(
      [id, signed.token, login.row_digest(id), sha256_text(id)],
      fn(presented) {
        let #(socket, response) =
          daemon_server_test.connect(port, presented, "/v2/control")
        assert string.contains(response, "401")
        let _ = ffi_ws.tcp_close(socket)
        let #(socket, response) =
          daemon_server_test.connect(
            port,
            presented,
            "/v2/sessions/" <> session <> "/ws",
          )
        assert string.contains(response, "401")
        let _ = ffi_ws.tcp_close(socket)
        Nil
      },
    )

    // The owner's bearer is unaffected.
    let #(socket, response) =
      daemon_server_test.connect(port, credential, "/v2/control")
    assert string.contains(response, "101")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

// Only a fresh home makes a device link, and the link signs in another device
// for the time the issuing login has left: the new login inherits the
// expiry, is listed beside it naming it as its parent, redeems once, and costs
// one place of the credential's grant allowance of three an hour.
pub fn a_fresh_home_signs_in_another_device_for_the_time_the_login_has_left_test() {
  fixture_with(Signing, fn(_, port, credential) {
    let first = sign_in(port, credential)
    let ask = fn(page: Entered) {
      home_socket(port, page, [#("x-device-link", "1")])
    }
    let link = ask(first.page)
    assert link.status == 284
    assert list.key_find(link.headers, "x-page-origin") == Ok("fresh")
    let prefix =
      "http://127.0.0.1:" <> int.to_string(port) <> "/ui/home?ticket="
    assert string.starts_with(link.body, prefix)
    assert string.byte_size(link.body) == string.byte_size(prefix) + 64

    // The device opens it: a home page and a login whose lifetime is the
    // issuing login's, and not a fresh thirty days.
    let path =
      string.drop_start(
        link.body,
        string.length("http://127.0.0.1:" <> int.to_string(port)),
      )
    let device = signed_in(exchange(port, path))
    assert int.absolute_value(device.max_age - first.max_age) <= 5
    assert device.key != first.key
    assert exchange(port, path).status == 401

    // Both are listed, and the new one names its parent.
    let rows = listed_signins(port, credential)
    assert list.length(rows) == 2
    let parent = string.slice(login.row_digest(id_of(first.token)), 0, 16)
    let child = string.slice(login.row_digest(id_of(device.token)), 0, 16)
    let assert Ok(row) =
      list.find(rows, fn(row) {
        field(row, "fingerprint") == Ok(json.String(child))
      })
    assert field(row, "issued_by") == Ok(json.String(parent))

    // The device's page belongs to the new login and is a fresh home, so it may
    // make a link of its own, which inherits the same expiry and names it.
    let seen = home_socket(port, device.page, [])
    assert list.key_find(seen.headers, "x-page-login") == Ok(child)
    assert list.key_find(seen.headers, "x-page-origin") == Ok("fresh")
    let second_path =
      string.drop_start(
        ask(device.page).body,
        string.length("http://127.0.0.1:" <> int.to_string(port)),
      )
    let grandchild = signed_in(exchange(port, second_path))
    assert int.absolute_value(grandchild.max_age - first.max_age) <= 5

    // The third link is the last of the hour; the fourth is refused.
    assert ask(first.page).status == 284
    let refused = ask(first.page)
    assert refused.status == 283
    assert string.contains(refused.body, "TooMany")
  })
}

// A page that no login belongs to (`loom ui --no-remember`) makes a link whose
// login has thirty days of its own and no parent. A link from an observer's home
// is an observer's.
pub fn a_page_with_no_login_makes_a_device_link_of_thirty_days_test() {
  fixture_with(Signing, fn(ready, port, credential) {
    let page = enter(port, forgotten_home(port, credential))
    let seen = home_socket(port, page, [])
    assert list.key_find(seen.headers, "x-page-login") == Ok("none")
    let link = home_socket(port, page, [#("x-device-link", "1")])
    assert link.status == 284
    let path =
      string.drop_start(
        link.body,
        string.length("http://127.0.0.1:" <> int.to_string(port)),
      )
    let device = signed_in(exchange(port, path))
    assert device.max_age >= 2_591_990
    assert device.max_age <= 2_592_000
    let assert [row] = listed_signins(port, credential)
    assert field(row, "issued_by") == Error(Nil)

    // The observer's home, as `loom ui --observe` opens it.
    let watching = enter(port, home_link(port, credential, []))
    let watch_link = home_socket(port, watching, [#("x-device-link", "1")])
    assert watch_link.status == 284
    let watch_path =
      string.drop_start(
        watch_link.body,
        string.length("http://127.0.0.1:" <> int.to_string(port)),
      )
    let watcher = signed_in(exchange(port, watch_path))
    let assert Ok(opened) =
      login.open(
        root_key(ready),
        watcher.token,
        now_ms: bootstrap.system_time_ms(),
        key: watcher.key,
        nonce: watcher.nonce,
      )
    assert opened.allowance.ceiling == login.Observer
  })
}

// A home the bookmark resumed draws no device-link control, and the daemon
// refuses the request from one that was forged, minting nothing and costing no
// place of the allowance.
pub fn a_resumed_home_makes_no_device_link_test() {
  fixture_with(Signing, fn(_, port, credential) {
    let signed = sign_in(port, credential)
    let resumed = entered(resume_as(port, signed))
    let asked = home_socket(port, resumed, [#("x-device-link", "1")])
    assert asked.status == 289
    assert list.key_find(asked.headers, "x-page-origin") == Ok("resumed")

    let forced =
      home_socket(port, resumed, [
        #("x-device-link", "1"),
        #("x-device-force", "1"),
      ])
    assert forced.status == 283
    assert string.contains(forced.body, "NotFresh")

    // Nothing was minted and no place was taken: a fresh page still has all
    // three.
    let fresh = fn() {
      home_socket(port, signed.page, [#("x-device-link", "1")]).status
    }
    assert [fresh(), fresh(), fresh()] == [284, 284, 284]
  })
}

// The page's own sign-in asks are the daemon's, made as the principal the page
// was admitted for: the list is the principal's own, a sign-out finds the login
// among the principal's and no one else's, and "sign out everywhere" ends every
// one of them and no other principal's.
pub fn the_pages_sign_in_asks_reach_only_the_principals_own_logins_test() {
  fixture_with(Signing, fn(ready, port, credential) {
    let session = create_session(ready, "sign-out", 975)
    let shared = member(ready, "ui-signout-member", session, access.Operator)
    let first = sign_in(port, credential)
    let second = sign_in(port, credential)
    let theirs = sign_in_as(port, shared)
    let their_fingerprint =
      string.slice(login.row_digest(id_of(theirs.token)), 0, 16)
    let first_fingerprint =
      string.slice(login.row_digest(id_of(first.token)), 0, 16)
    let second_fingerprint =
      string.slice(login.row_digest(id_of(second.token)), 0, 16)

    // The list is the principal's own, never the member's.
    let listing = home_socket(port, first.page, [#("x-signins", "1")])
    assert listing.status == 281
    assert list.key_find(listing.headers, "x-page-login")
      == Ok(first_fingerprint)
    let listed =
      list.map(string.split(listing.body, "\n"), fn(line) {
        let assert [fingerprint, ..] = string.split(line, "|")
        fingerprint
      })
    assert list.sort(listed, string.compare)
      == list.sort([first_fingerprint, second_fingerprint], string.compare)

    // A sign-out of another principal's login, of an unknown fingerprint and of
    // text that is not one is `NotFound`, and ends nothing.
    let out = fn(fingerprint) {
      home_socket(port, first.page, [#("x-sign-out", fingerprint)])
    }
    let refused = out(their_fingerprint)
    assert refused.status == 283
    assert string.contains(refused.body, "NotFound")
    assert string.contains(out(string.repeat("0", 16)).body, "NotFound")
    assert string.contains(out("zz").body, "NotFound")
    assert resume_as(port, theirs).status == 200

    // Its own is ended, and the login resumes nothing afterwards.
    assert out(second_fingerprint).status == 282
    refused_login(resume_as(port, second), second)
    assert resume_as(port, first).status == 200

    // Everywhere ends the rest of the principal's and the member's stands.
    let everywhere = home_socket(port, first.page, [#("x-sign-out-all", "1")])
    assert everywhere.status == 282
    refused_login(resume_as(port, first), first)
    assert resume_as(port, theirs).status == 200
    assert fingerprints(listed_signins(port, credential)) == []
  })
}

// The token, its nonce, its key and its identifier appear in no file under the
// state root, and in no line the daemon logs; the log names the login by its
// fingerprint, the principal and, for a device link, its parent.
pub fn the_token_is_in_no_file_and_no_log_line_test() {
  fixture_with(Signing, fn(ready, port, credential) {
    log_capture_start()
    let first = sign_in(port, credential)
    let resumed = entered(resume_as(port, first))
    let link = home_socket(port, first.page, [#("x-device-link", "1")])
    let path =
      string.drop_start(
        link.body,
        string.length("http://127.0.0.1:" <> int.to_string(port)),
      )
    let device = signed_in(exchange(port, path))
    refused_login(
      resume(
        port,
        first.key,
        "loom_login=" <> first.token,
        string.repeat("0", 64),
        [],
      ),
      first,
    )
    let fingerprint = string.slice(login.row_digest(id_of(device.token)), 0, 16)
    let ended = home_socket(port, first.page, [#("x-sign-out", fingerprint)])
    assert ended.status == 282
    let lines = log_capture_stop()

    // The secrets: each token, its nonce, its key and identifier, the cookies
    // and the bearer that asked for the page.
    let secrets =
      list.flat_map([first, device], fn(login_set) {
        [
          login_set.token,
          login_set.nonce,
          login_set.key,
          id_of(login_set.token),
          login_set.page.cookie,
          login_set.page.nonce,
        ]
      })
      |> list.append([resumed.cookie, resumed.nonce])
    let root_text = case simplifile.read(ready.state_root <> "/browser.key") {
      Ok(text) -> text
      Error(_) -> ""
    }
    assert string.byte_size(root_text) == 64

    // No log line holds any of them or the root key.
    let joined = string.join(lines, "\n")
    list.each([root_text, credential, ..secrets], fn(secret) {
      assert !string.contains(joined, secret)
    })

    // The log says what happened, by fingerprint and without a secret.
    let parent = string.slice(login.row_digest(id_of(first.token)), 0, 16)
    assert string.contains(joined, "daemon.login_issued")
    assert string.contains(joined, "daemon.login_resumed")
    assert string.contains(joined, "daemon.login_revoked")
    assert string.contains(joined, parent)
    assert string.contains(joined, fingerprint)
    assert string.contains(joined, "issued_by")

    // No file under the state root holds one either. The root key is in its own
    // file and nowhere else. The owner's bearer is in `owner.token`, which is
    // why it is not among the secrets a file is searched for.
    let assert Ok(files) = simplifile.get_files(ready.state_root)
      as "the state root is readable"

    // The scan has to reach the catalogue, where the rows are, or it would pass
    // over an empty list.
    assert list.any(files, fn(file) { string.ends_with(file, "/catalogue.db") })
    list.each(files, fn(file) {
      let assert Ok(bytes) = simplifile.read_bits(file) as "a state file reads"
      list.each(secrets, fn(secret) {
        assert !holds(bytes, bit_array.from_string(secret))
      })
      case string.ends_with(file, "/browser.key") {
        True -> Nil
        False -> {
          assert !holds(bytes, bit_array.from_string(root_text))
          Nil
        }
      }
    })
    Nil
  })
}

// The root key's three start cases (protocol-change/065): a readable key is the
// key; a file that is present and wrong refuses start and is never regenerated;
// and a missing file draws a new key and, before it writes it, revokes every
// login the lost key had verified, with one line saying how many.
pub fn the_root_key_cases_at_start_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "root-key", 977)
    let shared = member(ready, "ui-rootkey-member", session, access.Operator)
    let path = ready.state_root <> "/browser.key"
    let _ = sign_in(port, credential)
    let _ = sign_in(port, credential)
    let _ = sign_in_as(port, shared)
    let active = fn() {
      list.length(listed_signins(port, credential))
      + list.length(listed_signins(port, shared))
    }
    assert active() == 3

    // A readable key is kept, and nothing is revoked.
    let assert Ok(kept) = simplifile.read(path) as "the key was written"
    assert string.byte_size(kept) == 64
    let assert Ok(_) = ui_login.root_key(ready.state_root, ready.registry)
    assert active() == 3
    assert simplifile.read(path) == Ok(kept)

    // Present and wrong: shorter, not hex, group-readable. Each refuses start,
    // none is replaced, and nothing is revoked.
    list.each(
      [
        string.repeat("ab", 31),
        string.repeat("zz", 32),
        string.repeat("AB", 32),
      ],
      fn(contents) {
        let assert Ok(Nil) = bootstrap.atomic_write_private(path, contents)
        let assert Error(_) =
          ui_login.root_key(ready.state_root, ready.registry)
        assert simplifile.read(path) == Ok(contents)
        assert active() == 3
      },
    )
    let assert Ok(Nil) = bootstrap.atomic_write_private(path, kept)
    let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o644)
    let assert Error(_) = ui_login.root_key(ready.state_root, ready.registry)
    assert active() == 3
    let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o600)

    // Missing: a new key is drawn, every login is revoked, and the count is
    // logged once.
    let assert Ok(Nil) = simplifile.delete(path)
    log_capture_start()
    let assert Ok(_) = ui_login.root_key(ready.state_root, ready.registry)
    let lines = log_capture_stop()
    assert active() == 0
    let assert Ok(fresh) = simplifile.read(path) as "a new key was written"
    assert fresh != kept
    assert string.byte_size(fresh) == 64
    let counted =
      list.filter(lines, fn(line) {
        string.contains(line, "daemon.logins_revoked")
      })
    assert list.length(counted) == 1
    let assert [line] = counted
    assert string.contains(line, "\"count\":3}")
      || string.contains(line, "\"count\":3,")
  })
}

// Every ticket a page mints carries the page's origin and login (protocol-change/065,
// PR 8): a switch from a resumed home opens a resumed session page, the way home
// from it a resumed home, and each belongs to the login that resumed the first.
// So a chain from the bookmark can never become a fresh home, which is what an
// admin page and a device link are minted from, and never loses the login whose
// expiry a device link inherits. Nothing a page mints sets a login.
pub fn a_chain_from_a_resumed_home_stays_resumed_and_keeps_its_login_test() {
  fixture_with(Switching, fn(ready, port, credential) {
    let session = create_session(ready, "resumed-chain", 979)
    let signed = sign_in(port, credential)
    let fingerprint = string.slice(login.row_digest(id_of(signed.token)), 0, 16)
    let home = entered(resume_as(port, signed))

    // The home, to a session page of the same reach and origin.
    let pressed = press_row(port, home, session)
    assert pressed.status == 290
    let switched = exchange(port, pressed.body)
    assert list.length(set_cookies(switched)) == 1
    assert !string.contains(switched.body, "data-login")
    let page = entered(switched)
    let at_session = ask(port, page, session)
    assert list.key_find(at_session.headers, "x-page-origin") == Ok("resumed")
    assert list.key_find(at_session.headers, "x-page-login") == Ok(fingerprint)
    assert list.key_find(at_session.headers, "x-page-reach") == Ok("workspace")

    // And back home from it.
    let back = press_home(port, page, [])
    assert back.status == 288
    let there = exchange(port, back.body)
    assert list.length(set_cookies(there)) == 1
    let again = entered(there)
    let at_home = home_socket(port, again, [])
    assert list.key_find(at_home.headers, "x-page-origin") == Ok("resumed")
    assert list.key_find(at_home.headers, "x-page-login") == Ok(fingerprint)

    // A fresh home's chain stays fresh and keeps the login its exchange set.
    let fresh = sign_in(port, credential)
    let fresh_fingerprint =
      string.slice(login.row_digest(id_of(fresh.token)), 0, 16)
    let from_fresh = press_row(port, fresh.page, session)
    let fresh_page = entered(exchange(port, from_fresh.body))
    let at_fresh = ask(port, fresh_page, session)
    assert list.key_find(at_fresh.headers, "x-page-origin") == Ok("fresh")
    assert list.key_find(at_fresh.headers, "x-page-login")
      == Ok(fresh_fingerprint)
  })
}

// The ceiling the exchange was minted at is the login's: an observer's `loom ui
// --observe` sets an observer's login, and the home it resumes is read-only.
pub fn an_observers_login_mints_an_observers_home_test() {
  fixture(fn(ready, port, credential) {
    let observer = signed_in(exchange(port, home_link(port, credential, [])))
    let assert Ok(opened) =
      login.open(
        root_key(ready),
        observer.token,
        now_ms: bootstrap.system_time_ms(),
        key: observer.key,
        nonce: observer.nonce,
      )
    assert opened.allowance.ceiling == login.Observer
    let resumed = entered(resume_as(port, observer))
    let assert [_, who, ..] =
      string.split(home_socket(port, resumed, []).body, "\n")
    assert who == "observer"
  })
}

// `principals.list` reports each principal's logins beside its credential: the
// credential is still the bearer's state, and a login is counted and never shown
// in its place.
pub fn the_principal_listing_counts_logins_beside_the_credential_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "listing", 980)
    let shared = member(ready, "ui-listing-member", session, access.Operator)
    let _ = sign_in(port, credential)
    let _ = sign_in(port, credential)
    let _ = sign_in_as(port, shared)
    let reply = control(port, credential, "principals.list", [])
    assert field(reply, "event") == Ok(json.String("principals.list"))
    let assert Ok(body) = field(reply, "body") as "a body"
    let assert Ok(json.Array(rows)) = field(body, "principals") as "the rows"
    let logins = fn(id) {
      let assert Ok(row) =
        list.find(rows, fn(row) {
          field(row, "principal_id") == Ok(json.String(id))
        })
      let assert Ok(json.Int(count)) = field(row, "logins") as "a count"
      let assert Ok(credential_state) = field(row, "credential")
        as "a credential state"
      #(count, credential_state)
    }
    let #(owner_logins, _) = logins(ready.owner.id)
    let #(member_logins, member_credential) = logins("ui-listing-member")
    assert owner_logins == 2
    assert member_logins == 1
    assert field(member_credential, "state") == Ok(json.String("active"))
  })
}

// A device link whose issuing login has ended opens no page and writes no row.
// Opening it without a login would leave a page with no parent, whose own
// device link would then start thirty fresh days past the family's end.
pub fn a_device_link_from_an_ended_login_opens_no_page_test() {
  fixture_with(Signing, fn(_, port, credential) {
    let first = sign_in(port, credential)
    let link =
      home_socket(port, first.page, [
        #("x-device-link", "1"),
        #("x-login-ended", "1"),
      ])
    assert link.status == 284
    let path =
      string.drop_start(
        link.body,
        string.length("http://127.0.0.1:" <> int.to_string(port)),
      )
    let answer = exchange(port, path)
    assert answer.status == 401
    assert list.key_find(answer.headers, "set-cookie") == Error(Nil)
    assert list.length(listed_signins(port, credential)) == 1
    assert exchange(port, path).status == 401
  })
}

// A login made from a device link ends when the login that made it does, and
// names it; a parent that has already ended makes none; and a page with no login
// gives a fresh thirty days. This is `ui_login.issue`'s own rule, held with a
// parent whose expiry is a day away, which an exchange minutes old cannot be.
pub fn a_login_inherits_its_parents_expiry_and_a_dead_parent_makes_none_test() {
  fixture(fn(ready, port, credential) {
    let root = root_key(ready)
    let assert Ok(digest) = access.credential_digest(sha256_text(credential))
      as "the owner's digest is valid"
    let grant =
      ui_sessions.Grant(
        scope: ui_sessions.Home,
        credential: digest,
        principal: ready.owner.id,
        ceiling: access.Operator,
        reach: ui_sessions.Workspace,
        origin: ui_sessions.Fresh,
        remember: ui_sessions.Remembered,
      )
    let now = bootstrap.system_time_ms()
    let parent =
      ui_sessions.Issuer(
        fingerprint: "0123456789abcdef",
        expires_at_ms: now + 86_400_000,
        key: string.repeat("a", 32),
      )

    // A day left on the parent is a day on the child, in the cookie and in the
    // row, and the row names the parent.
    let assert Ok(child) =
      ui_login.issue(root, ready.registry, grant, Some(parent), now)
      as "a login is made from a device link"
    assert child.issuer.expires_at_ms == parent.expires_at_ms
    assert child.max_age_s == 86_400
    let assert [row] = listed_signins(port, credential)
    assert field(row, "expires_at_ms") == Ok(json.Int(parent.expires_at_ms))
    assert field(row, "issued_by") == Ok(json.String("0123456789abcdef"))
    let assert Ok(opened) =
      login.open(
        root,
        child.token,
        now_ms: now,
        key: child.key,
        nonce: child.nonce,
      )
      as "the token opens"
    assert opened.allowance.expires_at_ms == parent.expires_at_ms

    // A parent that has ended makes no login and writes no row.
    let dead = ui_sessions.Issuer(..parent, expires_at_ms: now)
    assert ui_login.issue(root, ready.registry, grant, Some(dead), now)
      == Error(ui_login.ParentEnded)
    assert list.length(listed_signins(port, credential)) == 1

    // No parent gives thirty days of its own and no parent in the row.
    let assert Ok(own) = ui_login.issue(root, ready.registry, grant, None, now)
      as "a login with no parent is made"
    assert own.max_age_s == 2_592_000
    assert own.issuer.expires_at_ms == now + login.lifetime_ms
    assert list.length(listed_signins(port, credential)) == 2
  })
}

// --- the owner's admin page (protocol-change/065, the fifth pull request) -----

// The owner's operator home, and the press of its "Admin" button: the ticket
// the daemon mints, as the address the browser is sent to.
fn admin_ticket(port: Int, home: Entered) -> String {
  let pressed = home_socket(port, home, [#("x-admin-open", "1")])
  assert pressed.status == 290
  pressed.body
}

// An admin page opened from the owner's operator home, through the exchange.
fn admin_page(port: Int, credential: String) -> Entered {
  let home = enter(port, operator_home(port, credential))
  enter(port, admin_ticket(port, home))
}

// The admin page's socket as a change asks for one, with the header that names
// it and the ones that carry what it needs.
fn admin_do(
  port: Int,
  page: Entered,
  kind: String,
  more: List(#(String, String)),
) -> Answer {
  home_socket(port, page, [#("x-admin-do", kind), ..more])
}

// What the admin page's read found, one line for each of the principals, the
// sessions and the chosen session's members.
fn admin_read(
  port: Int,
  page: Entered,
  chosen: String,
) -> #(String, String, String) {
  let answer = home_socket(port, page, [#("x-admin-chosen", chosen)])
  assert answer.status == 279
  let assert [people, listed, selection] = string.split(answer.body, "\n")
    as "a read is three lines"
  #(people, listed, selection)
}

// The owner's operator home presses "Admin", the ticket exchanges once for a
// page of the admin scope under its own key and cookie, and the page's socket
// reaches the admin upgrade with the owner and the ceiling the ticket carried.
pub fn an_owners_home_opens_an_admin_page_once_test() {
  fixture_with(Granting, fn(ready, port, credential) {
    let home = enter(port, operator_home(port, credential))
    let path = admin_ticket(port, home)
    assert string.starts_with(path, "/ui/admin?ticket=")

    // The exchange's checks are the home's.
    assert get(port, path, [host(port), #("sec-fetch-site", "cross-site")]).status
      == 403
    let answer = exchange(port, path)
    let page = entered(answer)
    assert string.ends_with(page.page, "/admin")
    let assert Ok(set) = list.key_find(answer.headers, "set-cookie")
      as "the cookie is set"
    assert string.contains(set, "HttpOnly")
    assert string.contains(set, "SameSite=Strict")
    assert string.ends_with(
      set,
      "Path=" <> string.replace(page.page, "/admin", ""),
    )

    // Spent, and said so in the admin page's words.
    let again = exchange(port, path)
    assert again.status == 401
    assert string.contains(
      again.body,
      ending.admin_headline(ending.LinkExpired),
    )

    // The page is the admin shell, which names no session and carries no nonce.
    let opened = open_page(port, page)
    assert opened.status == 200
    assert string.contains(opened.body, "Admin — Loom")
    assert !string.contains(opened.body, page.nonce)
    assert referrer_policy(opened) == Ok("no-referrer")

    // Only a first-party navigation reaches it.
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

    // The socket needs the host, the origin, the cookie, the key and the nonce.
    assert home_socket(port, Entered(..page, nonce: "forged"), []).status == 403
    let upgraded = home_socket(port, page, [])
    assert upgraded.status == 279
    assert string.starts_with(
      upgraded.body,
      "principals " <> ready.owner.id <> ":owner:active",
    )

    // The home that pressed the button is unaffected.
    assert open_page(port, home).status == 200
  })
}

// An admin page is not on offer to a home that is not the owner's, minted to
// operate and fresh, and the daemon refuses a press that reached it anyway: the
// capability is the first layer and `admin_ticket_for` the third.
pub fn only_an_owners_operating_home_is_offered_an_admin_page_test() {
  fixture_with(Granting, fn(ready, port, credential) {
    let session = create_session(ready, "admin-offer", 1201)
    let invitee = member(ready, "admin-member", session, access.Operator)

    // A member's operator home, and an owner's observer home, have no
    // capability and no button.
    let members_home = enter(port, operator_home(port, invitee))
    assert home_socket(port, members_home, [#("x-admin-open", "1")]).status
      == 289
    let observing = enter(port, home_link(port, credential, []))
    assert home_socket(port, observing, [#("x-admin-open", "1")]).status == 289

    // Asked anyway, the daemon refuses each in the same words and mints nothing.
    let forced = fn(page) {
      home_socket(port, page, [
        #("x-admin-open", "1"),
        #("x-admin-force", "1"),
      ])
    }
    let member_refused = forced(members_home)
    assert member_refused.status == 291
    assert member_refused.body == "NoAdmin"
    let observer_refused = forced(observing)
    assert observer_refused.status == 291
    assert observer_refused.body == "NoAdmin"

    // A home that has ended asks nothing of the registry.
    let owners = enter(port, operator_home(port, credential))
    let ended =
      home_socket(port, owners, [
        #("x-admin-open", "1"),
        #("x-switch-ended", "1"),
      ])
    assert ended.status == 291
    assert ended.body == "NoAdmin"
  })
}

// A ticket is honoured only at the exchange of its own scope: a session's and a
// home's at the admin exchange, and an admin ticket at either of theirs, are each
// refused and spent, and no cookie is set for any.
pub fn an_admin_ticket_redeems_only_at_the_admin_exchange_test() {
  fixture_with(Granting, fn(ready, port, credential) {
    let session = create_session(ready, "admin-scopes", 1202)
    let for_session = link(port, credential, session)
    let for_home = home_link(port, credential, [])
    let home = enter(port, operator_home(port, credential))
    let for_admin = admin_ticket(port, home)
    let other_admin = admin_ticket(port, home)

    // A session's ticket and a home's presented at the admin exchange.
    let session_at_admin = "/ui/admin?ticket=" <> after_ticket(for_session)
    let home_at_admin = "/ui/admin?ticket=" <> after_ticket(for_home)
    let refused = exchange(port, session_at_admin)
    assert refused.status == 403
    assert list.key_find(refused.headers, "set-cookie") == Error(Nil)
    let refused = exchange(port, home_at_admin)
    assert refused.status == 403
    assert list.key_find(refused.headers, "set-cookie") == Error(Nil)

    // An admin ticket presented at the home's exchange and at a session's.
    let admin_at_home = "/ui/home?ticket=" <> after_ticket(for_admin)
    let admin_at_session =
      "/ui/sessions/" <> session <> "?ticket=" <> after_ticket(other_admin)
    let refused = exchange(port, admin_at_home)
    assert refused.status == 403
    assert list.key_find(refused.headers, "set-cookie") == Error(Nil)
    let refused = exchange(port, admin_at_session)
    assert refused.status == 403
    assert list.key_find(refused.headers, "set-cookie") == Error(Nil)

    // All four are spent: none opens its own exchange afterwards.
    assert exchange(
        port,
        "/ui/sessions/" <> session <> "?ticket=" <> after_ticket(for_session),
      ).status
      == 401
    assert exchange(port, for_home).status == 401
    assert exchange(port, for_admin).status == 401
    assert exchange(port, other_admin).status == 401
  })
}

// A cookie opens only the scope it was issued for. The admin page's opens no
// session page and no home, a home's and a session's open no admin page, and the
// sockets are refused across scopes before any upgrade.
pub fn an_admin_cookie_opens_only_the_admin_page_test() {
  fixture_with(Granting, fn(ready, port, credential) {
    let session = create_session(ready, "admin-cookies", 1203)
    let home = enter(port, operator_home(port, credential))
    let admin = enter(port, admin_ticket(port, home))
    let session_page = enter(port, link(port, credential, session))
    let key_of = fn(page: Entered, suffix) {
      string.replace(page.page, suffix, "")
    }
    let admin_key = key_of(admin, "/admin")
    let home_key = key_of(home, "/home")
    let session_key = key_of(session_page, "/sessions/" <> session)
    let under = fn(path, cookie) {
      get(port, path, [
        host(port),
        #("sec-fetch-site", "same-origin"),
        #("cookie", "loom_ui=" <> cookie),
      ]).status
    }

    // The admin cookie on the home's and a session's path, and theirs on the
    // admin's, under their own keys.
    assert under(admin_key <> "/home", admin.cookie) == 403
    assert under(admin_key <> "/sessions/" <> session, admin.cookie) == 403
    assert under(home_key <> "/admin", home.cookie) == 403
    assert under(session_key <> "/admin", session_page.cookie) == 403

    // A cookie under another page's key is no page at all.
    assert under(admin_key <> "/admin", home.cookie) == 401
    assert under(home_key <> "/admin", admin.cookie) == 401
    assert open_page(port, admin).status == 200
    assert open_page(port, home).status == 200

    // The sockets are refused across scopes: the admin's cookie at the home's
    // socket and the home's at the admin's.
    let socket = fn(path, nonce, cookie) {
      get(port, path <> "/ws?csrf-token=" <> nonce, [
        host(port),
        #("cookie", "loom_ui=" <> cookie),
        #("origin", "http://127.0.0.1:" <> int.to_string(port)),
      ]).status
    }
    assert socket(admin_key <> "/home", admin.nonce, admin.cookie) == 403
    assert socket(home_key <> "/admin", home.nonce, home.cookie) == 403
    assert socket(admin.page, admin.nonce, admin.cookie) == 279
  })
}

// A grant for the admin scope whose credential is not the owner's is refused at
// every request, whatever minted it: the router asks the registry who the
// credential is, so no ticket can open the admin page for a member.
pub fn a_members_credential_holds_no_admin_page_test() {
  fixture_with(Granting, fn(ready, port, credential) {
    let session = create_session(ready, "admin-forged", 1204)
    let invitee = member(ready, "admin-forged-member", session, access.Operator)
    let home = enter(port, operator_home(port, credential))
    let forged =
      home_socket(port, home, [
        #("x-admin-open", "1"),
        #("x-admin-mint", invitee),
        #("x-admin-mint-principal", "admin-forged-member"),
      ])
    assert forged.status == 290

    // The exchange honours the ticket, since a ticket records no principal's
    // kind, and the page and its socket are refused.
    let page = enter(port, forged.body)
    let refused = open_page(port, page)
    assert refused.status == 403
    assert string.contains(
      refused.body,
      ending.admin_headline(ending.AccessRevoked),
    )
    assert home_socket(port, page, []).status == 403
  })
}

// A revoked credential's admin page is refused at its next request.
pub fn a_revoked_owner_credential_ends_the_admin_page_test() {
  fixture_with(Granting, fn(ready, port, credential) {
    let page = admin_page(port, credential)
    assert open_page(port, page).status == 200
    assert home_socket(port, page, []).status == 279

    // The owner's own credential is revoked in the catalogue, as the router's
    // next check will find.
    revoke(ready.state_root, credential)
    let reloaded = open_page(port, page)
    assert reloaded.status == 401
    assert string.contains(
      reloaded.body,
      ending.admin_headline(ending.AccessRevoked),
    )
    assert string.contains(reloaded.body, "subject=\"link\" text=\"loom ui\"")
    assert home_socket(port, page, []).status == 401
  })
}

// The admin page reads the principals with their credential state, a pending
// invitation as an open claim, and a chosen session's members, and each change
// shows at the page's next read.
pub fn the_admin_page_reads_and_each_change_shows_at_the_next_read_test() {
  fixture_with(Granting, fn(ready, port, credential) {
    let session = create_shared_session(ready, "admin-reads", 1205)
    let page = admin_page(port, credential)
    let owner = ready.owner.id

    // Before anyone is invited: the owner alone, the session, no selection.
    let #(people, listed, selection) = admin_read(port, page, "")
    assert people == "principals " <> owner <> ":owner:active"
    assert listed == "sessions " <> session
    assert selection == "selection none"

    // An invitation is a pending claim and a member of the session.
    let invited =
      minted(
        admin_do(port, page, "invite", [
          #("x-admin-session", session),
          #("x-admin-role", "observer"),
          #("x-admin-name", "  Ana Admin  "),
        ]),
      )
    assert claim.validate_token(invited.token) == Ok(Nil)
    assert string.starts_with(invited.principal, "guest-")
    assert invited.role == "observer"
    assert invited.expires_in_ms == 3_600_000
    assert invited.command
      == "loom claim --addr ws://127.0.0.1:"
      <> int.to_string(port)
      <> "/v2/control"

    // A person without `loom` claims in a browser, at the address the page was
    // reached at.
    assert invited.page
      == "http://127.0.0.1:" <> int.to_string(port) <> "/ui/claim"
    let #(people, _, selection) = admin_read(port, page, session)
    assert string.contains(people, invited.principal <> ":member:claim_open")

    // The owner leads, though a `guest-` identity sorts above `owner-` ones.
    assert string.starts_with(
      people,
      "principals " <> owner <> ":owner:active,",
    )
    assert selection
      == "selection " <> session <> " " <> invited.principal <> "=observer"

    // The suggested name is the principal's name, trimmed.
    assert catalogue_rows(
        ready.state_root,
        "SELECT display_name FROM access_principals WHERE principal_id = ?",
        [sqlight.text(invited.principal)],
      )
      == ["Ana Admin"]

    // The claim redeems once, and the listing then shows an active credential.
    let invitee = claim.random_credential()
    assert field(
        daemon_claim_test.redeem(port, invited.token, claim.digest(invitee)),
        "event",
      )
      == Ok(json.String("credentials.claim"))
    let #(people, _, _) = admin_read(port, page, session)
    assert string.contains(people, invited.principal <> ":member:active")

    // Raising the role, then lowering it, then removing the member.
    assert admin_do(port, page, "set-role", [
        #("x-admin-session", session),
        #("x-admin-principal", invited.principal),
        #("x-admin-role", "operator"),
      ]).status
      == 294
    assert role_in(ready.state_root, invited.principal, session) == ["operator"]
    let #(_, _, selection) = admin_read(port, page, session)
    assert selection
      == "selection " <> session <> " " <> invited.principal <> "=operator"
    assert admin_do(port, page, "set-role", [
        #("x-admin-session", session),
        #("x-admin-principal", invited.principal),
        #("x-admin-role", "observer"),
      ]).status
      == 294
    assert role_in(ready.state_root, invited.principal, session) == ["observer"]
    assert admin_do(port, page, "revoke-membership", [
        #("x-admin-session", session),
        #("x-admin-principal", invited.principal),
      ]).status
      == 294
    assert grants_of(ready.state_root, invited.principal) == []
    let #(_, _, selection) = admin_read(port, page, session)
    assert selection == "selection " <> session <> " "

    // Revoking the credentials ends the invitee's access and keeps the identity.
    assert admin_do(port, page, "revoke-credentials", [
        #("x-admin-principal", invited.principal),
      ]).status
      == 294
    let #(people, _, _) = admin_read(port, page, session)
    assert string.contains(people, invited.principal <> ":member:none")
    assert members(ready.state_root) == [invited.principal]
  })
}

// The admin page's read of a session's members says whether the session may be
// shared: a session created for sharing reads `shareable`, and one that shares
// its notes and history with its workspace reads `private`, which is what lets
// the page draw no invitation form for it (round 4, F88).
pub fn the_admin_read_says_whether_the_chosen_session_may_be_shared_test() {
  fixture_with(Granting, fn(ready, port, credential) {
    let shared = create_shared_session(ready, "admin-scope-shared", 1230)
    let assert Ok(created) =
      manager.create_scoped(
        ready.registry,
        manager.Creation(
          "admin-scope-private",
          ready.state_root,
          "admin-scope-private",
          "",
          None,
          None,
        ),
        directory: ready.sessions_directory,
        generator: ids.generator(clock.fixed(0), 1231),
        scope: domain.WorkspacePrivate,
        configuration: "",
      )
      as "the private session is created"
    let page = admin_page(port, credential)
    let scope = fn(chosen) {
      let answer =
        home_socket(port, page, [
          #("x-admin-chosen", chosen),
          #("x-admin-scope", "1"),
        ])
      assert answer.status == 279
      answer.body
    }
    assert scope(shared) == "shareable"
    assert scope(created.registration.id) == "private"
    assert scope("") == "none"
  })
}

// The admin page's read summarises every listed session for its row: the owner
// counts as a person, an invitation adds one, and the words say the scope the
// session was created with (round 5, F118).
pub fn the_admin_read_summarises_each_listed_session_test() {
  fixture_with(Granting, fn(ready, port, credential) {
    let shared = create_shared_session(ready, "admin-rows-shared", 1240)
    let assert Ok(created) =
      manager.create_scoped(
        ready.registry,
        manager.Creation(
          "admin-rows-private",
          ready.state_root,
          "admin-rows-private",
          "",
          None,
          None,
        ),
        directory: ready.sessions_directory,
        generator: ids.generator(clock.fixed(0), 1241),
        scope: domain.WorkspacePrivate,
        configuration: "",
      )
      as "the private session is created"
    let page = admin_page(port, credential)
    let rows = fn() {
      let answer = home_socket(port, page, [#("x-admin-summaries", "1")])
      assert answer.status == 279
      string.split(answer.body, "\n")
    }
    assert list.contains(rows(), shared <> ":1:1 person · shareable")
    assert list.contains(
      rows(),
      created.registration.id <> ":1:1 person · private",
    )
    let _ =
      minted(admin_do(port, page, "invite", [#("x-admin-session", shared)]))
    assert list.contains(rows(), shared <> ":2:2 people · shareable")
  })
}

// A rotation voids what a principal held and makes a new claim, shown once. The
// page's read never carries a claim.
pub fn a_rotation_makes_a_claim_and_only_its_digest_is_kept_test() {
  fixture_with(Granting, fn(ready, port, credential) {
    let session = create_shared_session(ready, "admin-rotate", 1206)
    let page = admin_page(port, credential)
    let invited =
      minted(
        admin_do(port, page, "invite", [
          #("x-admin-session", session),
          #("x-admin-role", "operator"),
        ]),
      )
    let rotated =
      minted(
        admin_do(port, page, "rotate", [
          #("x-admin-principal", invited.principal),
        ]),
      )
    assert rotated.role == "rotated"
    assert rotated.principal == invited.principal
    assert rotated.token != invited.token
    assert claim.validate_token(rotated.token) == Ok(Nil)
    assert rotated.expires_in_ms == 3_600_000

    // The earlier claim is void and the new one is open, and the new one binds.
    assert catalogue_rows(
        ready.state_root,
        "SELECT state FROM access_claims WHERE principal_id = ? ORDER BY state",
        [sqlight.text(invited.principal)],
      )
      == ["open", "void"]
    let digest = claim.digest(claim.random_credential())
    assert field(daemon_claim_test.redeem(port, rotated.token, digest), "event")
      == Ok(json.String("credentials.claim"))

    // Neither token is in any file under the state root; only digests are.
    let assert Ok(files) = simplifile.get_files(ready.state_root)
      as "the state root lists"
    list.each(files, fn(file) {
      let assert Ok(bytes) = simplifile.read_bits(file) as "the file reads"
      assert !holds(bytes, bit_array.from_string(invited.token))
      assert !holds(bytes, bit_array.from_string(rotated.token))
    })
  })
}

// The admin page's grants and the session page's invitations are one
// allowance, the credential's: three in the window across both, and the fourth is
// refused wherever it is asked. A role raised to operator, a rotation and an
// invitation are grants; lowering a role, removing a member and revoking
// credentials are not.
pub fn the_fourth_grant_across_the_admin_page_and_a_session_page_is_refused_test() {
  fixture_with(Granting, fn(ready, port, credential) {
    let session = create_shared_session(ready, "admin-limit", 1207)
    let admin = admin_page(port, credential)
    let session_page = enter(port, operate(port, credential, session))
    let asked = fn(role) {
      admin_do(port, admin, "invite", [
        #("x-admin-session", session),
        #("x-admin-role", role),
      ])
    }

    // Two from the admin page and one from the session page are the three.
    let first = minted(asked("observer"))
    let second = minted(asked("observer"))
    assert minted(invite(port, session_page, "observer")).principal != ""
    let made = members(ready.state_root)
    assert list.length(made) == ui_sessions.invite_limit

    // The fourth is refused on each surface, and on a second admin page of the
    // same credential, which starts with nothing left.
    let refused = asked("observer")
    assert refused.status == 293
    assert refused.body == "TooMany"
    assert invite(port, session_page, "observer").body == "TooMany"
    let again = admin_page(port, credential)
    assert admin_do(port, again, "invite", [
        #("x-admin-session", session),
        #("x-admin-role", "operator"),
      ]).body
      == "TooMany"

    // A role raised to operator is a grant, and so is a rotation: both refused,
    // and the catalogue is as it was.
    let raise = fn(page) {
      admin_do(port, page, "set-role", [
        #("x-admin-session", session),
        #("x-admin-principal", first.principal),
        #("x-admin-role", "operator"),
      ])
    }
    let raised = raise(admin)
    assert raised.status == 293
    assert raised.body == "TooMany"
    assert role_in(ready.state_root, first.principal, session) == ["observer"]
    assert admin_do(port, admin, "rotate", [
        #("x-admin-principal", second.principal),
      ]).body
      == "TooMany"
    assert members(ready.state_root) == made

    // Every reduction still works with the allowance spent: lowering a role
    // (here one that is already lowest), removing a member and revoking
    // credentials.
    assert admin_do(port, admin, "set-role", [
        #("x-admin-session", session),
        #("x-admin-principal", first.principal),
        #("x-admin-role", "observer"),
      ]).status
      == 294
    assert admin_do(port, admin, "revoke-membership", [
        #("x-admin-session", session),
        #("x-admin-principal", first.principal),
      ]).status
      == 294
    assert admin_do(port, admin, "revoke-credentials", [
        #("x-admin-principal", second.principal),
      ]).status
      == 294
    assert grants_of(ready.state_root, first.principal) == []
  })
}

// A role raised to operator costs one of the three, and a demotion costs none:
// after any number of demotions the credential still has what it had.
pub fn a_raised_role_costs_an_allowance_and_a_demotion_costs_none_test() {
  fixture_with(Granting, fn(ready, port, credential) {
    let session = create_shared_session(ready, "admin-raise", 1208)
    let admin = admin_page(port, credential)
    let session_page = enter(port, operate(port, credential, session))
    let first =
      minted(
        admin_do(port, admin, "invite", [
          #("x-admin-session", session),
          #("x-admin-role", "observer"),
        ]),
      )

    // Six demotions and two removals that change nothing cost nothing.
    list.each(list.repeat(Nil, 6), fn(_) {
      assert admin_do(port, admin, "set-role", [
          #("x-admin-session", session),
          #("x-admin-principal", first.principal),
          #("x-admin-role", "observer"),
        ]).status
        == 294
    })

    // So the second and third places are still there: a raise and an invitation
    // from the session page.
    assert admin_do(port, admin, "set-role", [
        #("x-admin-session", session),
        #("x-admin-principal", first.principal),
        #("x-admin-role", "operator"),
      ]).status
      == 294
    assert role_in(ready.state_root, first.principal, session) == ["operator"]
    assert minted(invite(port, session_page, "observer")).principal != ""

    // The fourth place does not exist.
    assert invite(port, session_page, "observer").body == "TooMany"
    assert admin_do(port, admin, "set-role", [
        #("x-admin-session", session),
        #("x-admin-principal", first.principal),
        #("x-admin-role", "operator"),
      ]).body
      == "TooMany"
  })
}

// A refusal that made nothing gives its place back: a name the catalogue will
// not take, a session that is not shared, a session or a person that is not
// there. After all of them the credential still has every place.
pub fn a_refused_grant_costs_nothing_test() {
  fixture_with(Granting, fn(ready, port, credential) {
    let shared = create_shared_session(ready, "admin-refused", 1209)
    let private = create_session(ready, "admin-private", 1210)
    let page = admin_page(port, credential)
    let absent = "0198c0de-0000-7000-8000-0000000000ff"
    let refusal = fn(more) {
      let refused = admin_do(port, page, "invite", more)
      assert refused.status == 293
      refused.body
    }
    list.each(list.repeat(Nil, 4), fn(_) {
      assert refusal([#("x-admin-session", private)]) == "NotIsolated"
      assert refusal([
          #("x-admin-session", shared),
          #("x-admin-name", string.repeat("n", 257)),
        ])
        == "InvalidName"
      assert refusal([#("x-admin-session", absent)]) == "NotFound"
      assert refusal([#("x-admin-session", "not-a-session")]) == "NotFound"
      let raise =
        admin_do(port, page, "set-role", [
          #("x-admin-session", shared),
          #("x-admin-principal", "nobody"),
          #("x-admin-role", "operator"),
        ])
      assert raise.body == "NotFound"
      let rotate =
        admin_do(port, page, "rotate", [#("x-admin-principal", "nobody")])
      assert rotate.body == "NotFound"
    })
    assert members(ready.state_root) == []

    // All three places remain.
    list.each(list.repeat(Nil, ui_sessions.invite_limit), fn(_) {
      assert admin_do(port, page, "invite", [
          #("x-admin-session", shared),
          #("x-admin-role", "observer"),
        ]).status
        == 292
    })
  })
}

// A page that has ended but whose socket is still up changes nothing and reads
// nothing: the change is `NotOwner`, and the read says the page ended.
pub fn an_ended_admin_page_changes_and_reads_nothing_test() {
  fixture_with(Granting, fn(ready, port, credential) {
    let session = create_shared_session(ready, "admin-ended", 1211)
    let page = admin_page(port, credential)
    let before = members(ready.state_root)
    let refused =
      admin_do(port, page, "invite", [
        #("x-admin-session", session),
        #("x-switch-ended", "1"),
      ])
    assert refused.status == 293
    assert refused.body == "NotOwner"
    assert members(ready.state_root) == before
    let read = home_socket(port, page, [#("x-switch-ended", "1")])
    assert read.body == "closed " <> ending.reason(ending.PageEnded)
  })
}

// The daemon's own checks, made from the standing it holds and not from any
// page: an observer-ceiling page, a member's credential and a credential that is
// not the page's principal each change nothing and cost no allowance.
pub fn the_daemon_refuses_a_standing_that_is_not_the_owners_operating_one_test() {
  fixture_with(Granting, fn(ready, _, credential) {
    let session = create_shared_session(ready, "admin-standing", 1212)
    let invitee =
      member(ready, "admin-standing-member", session, access.Operator)
    let address = Ok("ws://127.0.0.1:1/v2/control")
    let #(member_standing, tickets) =
      standing_of(ready, "admin-standing-member", access.Operator)
    let observer = owner_standing(ready, credential, access.Observer)
    let owner = owner_standing(ready, credential, access.Operator)
    let ask = fn(standing, action) {
      ui_socket.admin_for(
        standing,
        tickets,
        page_open,
        ready.epoch,
        ready.state_root,
        address,
        action,
      )
    }
    let invite = grants.Invite(session, invites.Observer, "")
    let held = "admin-standing-member"
    let every_action = [
      invite,
      grants.SetRole(session, held, invites.Operator),
      grants.SetRole(session, held, invites.Observer),
      grants.RevokeMembership(session, held),
      grants.RevokeCredentials(held),
      grants.Rotate(held),
      grants.Rename(held, "Renamed"),
      grants.MakeShareable(session),
    ]
    let refused = grants.Declined(grants.NotOwner)
    list.each(every_action, fn(action) {
      assert ask(observer, action) == refused
      assert ask(member_standing, action) == refused
      assert ask(ui_socket.Standing(..owner, principal: "someone-else"), action)
        == refused
      assert ui_socket.admin_for(
          owner,
          tickets,
          fn() { Error(Nil) },
          ready.epoch,
          ready.state_root,
          address,
          action,
        )
        == refused
    })

    // None of them changed anything: the member is still the only one and still
    // an operator of the session.
    assert members(ready.state_root) == [held]
    assert role_in(ready.state_root, held, session) == ["operator"]
    assert invitee != ""

    // None of them took a place: the owner's own standing, with its own table of
    // tickets, still has all three.
    list.each(list.repeat(Nil, ui_sessions.invite_limit), fn(_) {
      let assert grants.Claimed(_) = ask(owner, invite) as "an invitation"
      Nil
    })
    let before = bootstrap.system_time_ms()
    let assert grants.Declined(grants.TooMany(used:, free_at_ms:)) =
      ask(owner, invite)
      as "the fourth grant is refused with the count and the reset"
    assert used == ui_sessions.invite_limit

    // The next place frees when the first grant leaves the hour: no earlier than
    // an hour after the first, and no later than an hour after now.
    assert free_at_ms > before
    assert free_at_ms
      <= bootstrap.system_time_ms() + ui_sessions.invite_window_ms
  })
}

// A stale epoch is the registry's own refusal, which the page words as the
// daemon being unable, and it gives the place back.
pub fn a_stale_epoch_changes_nothing_test() {
  fixture_with(Granting, fn(ready, _, credential) {
    let session = create_shared_session(ready, "admin-epoch", 1213)
    let owner = owner_standing(ready, credential, access.Operator)
    let #(_, tickets) = standing_of(ready, "unused", access.Operator)
    let invite = grants.Invite(session, invites.Observer, "")
    list.each(list.repeat(Nil, 5), fn(_) {
      assert ui_socket.admin_for(
          owner,
          tickets,
          page_open,
          "an-earlier-daemon",
          ready.state_root,
          Ok("ws://127.0.0.1:1/v2/control"),
          invite,
        )
        == grants.Declined(grants.Unavailable)
    })
    assert members(ready.state_root) == []
  })
}

// The admin change runs in a task of its own: the caller returns at once and the
// answer comes later, from another process.
pub fn the_admin_change_runs_off_the_callers_process_test() {
  fixture_with(Granting, fn(ready, _, credential) {
    let session = create_shared_session(ready, "admin-task", 1214)
    let owner = owner_standing(ready, credential, access.Operator)
    let #(_, tickets) = standing_of(ready, "unused", access.Operator)
    let answers = process.new_subject()
    ui_socket.admin_task(
      owner,
      tickets,
      page_open,
      ready.epoch,
      ready.state_root,
      Ok("ws://127.0.0.1:1/v2/control"),
      grants.Invite(session, invites.Observer, ""),
      fn(answer) { process.send(answers, #(answer, process.self())) },
    )
    let assert Ok(#(grants.Claimed(_), task)) = process.receive(answers, 10_000)
      as "the task answers"
    assert task != process.self()
  })
}

// The real admin component behind the real socket: it draws the principals, a
// pending invitation among them as a claim that is open, and its frames carry no
// claim at all, because the catalogue keeps only a claim's digest and the page
// asked for none. The invitation is made from a terminal's command, so the token
// is known to the test and can be looked for.
pub fn the_real_admin_socket_carries_no_claim_test() {
  fixture_with(Real, fn(ready, port, credential) {
    let session = create_shared_session(ready, "admin-real", 1215)
    let assert Ok(invite) =
      access_admin.parse(["invite", session, "pending-one", "observer", "Pen"])
    let assert Ok(invited) =
      access_admin.exchange(
        "ws://127.0.0.1:" <> int.to_string(port) <> "/v2/control",
        credential,
        ready.epoch,
        invite,
      )
    let assert Ok(json.String(token)) = field(invited, "claim")
      as "an invitation carries a claim"
    let home = enter(port, operator_home(port, credential))
    let pressed = home_socket(port, home, [#("x-admin-open", "1")])
    assert pressed.status == 290
    let page = enter(port, pressed.body)
    let socket = connect_socket(port, page, [])

    // The page stays open, so "closed" here means no frame for five seconds.
    let closed = read_until_closed(socket, [])
    let _ = ffi_ws.tcp_close(socket)
    let drawn = string.join(closed.texts, "\n")

    // The page drew its people, the pending invitation, and the owner's session.
    assert string.contains(drawn, "pending-one")
    assert string.contains(drawn, "claim open")
    assert string.contains(drawn, "Admin")
    assert string.contains(drawn, "admin-real")

    // No frame carries a claim, whole or in part.
    assert !string.contains(drawn, "loomclaim_")
    assert !string.contains(drawn, token)
    assert !string.contains(drawn, string.drop_start(token, 10))
  })
}

// An admin page whose owner credential is revoked after the router admitted it
// reads the catalogue, finds no owner, draws the ending and closes the socket
// finally (1000), so the client runtime does not retry.
pub fn a_revoked_owner_closes_the_real_admin_socket_test() {
  fixture_with(Real, fn(ready, port, credential) {
    let _ = create_shared_session(ready, "admin-revoked", 1216)
    let home = enter(port, operator_home(port, credential))
    let pressed = home_socket(port, home, [#("x-admin-open", "1")])
    assert pressed.status == 290
    let page = enter(port, pressed.body)
    let socket = connect_socket(port, page, [#("x-revoke-between", credential)])
    let closed = read_until_closed(socket, [])
    let _ = ffi_ws.tcp_close(socket)
    assert closed.code == 1000
    let drawn = string.join(closed.texts, "\n")
    assert string.contains(drawn, ending.admin_headline(ending.AccessRevoked))
    assert !string.contains(drawn, "Rotate")
  })
}

// A home the bookmark resumed is offered no Admin button, even the owner's and
// operating, and the daemon refuses a press forced from one in the same words as
// every other refusal: `fresh_home` reads the origin the daemon wrote on the
// grant. The home that signed in fresh still has both.
pub fn a_resumed_home_is_offered_no_admin_page_test() {
  fixture_with(Granting, fn(_, port, credential) {
    let signed = sign_in(port, credential)
    let resumed = entered(resume_as(port, signed))
    assert home_socket(port, resumed, [#("x-admin-open", "1")]).status == 289
    let forced =
      home_socket(port, resumed, [
        #("x-admin-open", "1"),
        #("x-admin-force", "1"),
      ])
    assert forced.status == 291
    assert forced.body == "NoAdmin"

    // The same owner's fresh home is unaffected.
    assert home_socket(port, signed.page, [#("x-admin-open", "1")]).status
      == 290
  })
}

// The admin page lists the sign-ins of each principal that holds any, beside its
// row, and ends one by fingerprint: the login then resumes nothing, the other
// logins stay, and a fingerprint under another principal is not found. The
// change is the daemon's own, made as the owner at the click.
pub fn the_admin_page_lists_each_principals_sign_ins_and_ends_one_test() {
  fixture_with(Granting, fn(ready, port, credential) {
    let session = create_session(ready, "admin-signins", 1210)
    let shared = member(ready, "ui-admin-signins", session, access.Operator)
    let theirs = sign_in_as(port, shared)
    let other = sign_in_as(port, shared)
    let page = admin_page(port, credential)
    let owner = ready.owner.id
    let fingerprint = fn(signed: Signed) {
      string.slice(login.row_digest(id_of(signed.token)), 0, 16)
    }
    let read = fn() {
      let answer = home_socket(port, page, [#("x-admin-logins", "1")])
      assert answer.status == 279
      answer.body
    }

    // The member's two logins are listed, and the owner's own login that opened
    // this page, each with its principal.
    let before = read()
    assert string.contains(before, "ui-admin-signins:2:")
    assert string.contains(before, fingerprint(theirs))
    assert string.contains(before, fingerprint(other))
    assert string.contains(before, owner <> ":")

    // A fingerprint under another principal is not found, and ends nothing.
    let wrong =
      admin_do(port, page, "revoke-signin", [
        #("x-admin-principal", owner),
        #("x-admin-fingerprint", fingerprint(theirs)),
      ])
    assert wrong.status == 293
    assert wrong.body == "NotFound"
    assert resume_as(port, theirs).status == 200

    // Ending one is the registry's change as the owner: that login resumes
    // nothing, the member's other login and its bearer stay.
    let ended =
      admin_do(port, page, "revoke-signin", [
        #("x-admin-principal", "ui-admin-signins"),
        #("x-admin-fingerprint", fingerprint(theirs)),
      ])
    assert ended.status == 294
    refused_login(resume_as(port, theirs), theirs)
    assert resume_as(port, other).status == 200
    let after = read()
    assert string.contains(after, "ui-admin-signins:1:" <> fingerprint(other))
    assert !string.contains(after, fingerprint(theirs))
  })
}

// --- the browser claim (protocol-change/065, PR 9) ------------------------------

// An invitation as the owner's control command makes one: a member of
// `session` at `role` with an open claim, whose token the reply carries.
fn invitation(
  port: Int,
  credential: String,
  session: String,
  principal: String,
  role: String,
) -> String {
  let reply =
    control(port, credential, "sessions.invite", [
      #("session_id", json.String(session)),
      #("principal_id", json.String(principal)),
      #("name", json.String("Invited " <> principal)),
      #("role", json.String(role)),
    ])
  assert field(reply, "event") == Ok(json.String("sessions.invite"))
  let assert Ok(body) = field(reply, "body") as "the invitation has a body"
  let assert Ok(json.String(token)) = field(body, "claim")
    as "the invitation carries a claim"
  token
}

// The claim form's body as a browser encodes it.
fn claim_form(token: String, name: String) -> String {
  "token=" <> uri.percent_encode(token) <> "&name=" <> uri.percent_encode(name)
}

// The claim, as the claim form posts it: this origin's `Sec-Fetch-Site`, the
// form's type and length. `more` overrides or adds a header.
fn claim_post(
  port: Int,
  body: String,
  more: List(#(String, String)),
) -> Answer {
  let defaults = [
    host(port),
    #("sec-fetch-site", "same-origin"),
    #("content-type", "application/x-www-form-urlencoded"),
    #("content-length", int.to_string(string.byte_size(body))),
  ]
  send_request(port, "POST", "/ui/claim", list.append(defaults, more), body)
}

fn redeemed_in_browser(port: Int, token: String, name: String) -> Answer {
  claim_post(port, claim_form(token, name), [])
}

// A refusal of a claim is the form again with the reason's fixed words over it:
// the status, the notice, the policy that lets the form post, no cookie, and
// nothing the request carried.
fn claim_refused(
  answer: Answer,
  status: Int,
  notice: page.ClaimNotice,
  token: String,
) -> Nil {
  assert answer.status == status
  assert string.contains(
    answer.body,
    "<p class=\"claim-notice\" role=\"alert\">"
      <> page.claim_notice(notice)
      <> "</p>",
  )
  assert string.contains(answer.body, "name=\"token\"")

  // A value shorter than the claim's prefix, which the fixed words themselves
  // name, is too short to tell an echo from them.
  assert string.length(token) <= string.length("loomclaim_")
    || !string.contains(answer.body, token)
  assert set_cookies(answer) == []
  assert string.contains(policy_header(answer), "form-action 'self'")
  Nil
}

fn policy_header(answer: Answer) -> String {
  let assert Ok(policy) =
    list.key_find(answer.headers, "content-security-policy")
    as "every answer carries the policy"
  policy
}

// The states of the claim's row, as the catalogue holds it, read straight from
// the file.
fn claim_rows(state_root: String, token: String) -> List(String) {
  catalogue_rows(
    state_root,
    "SELECT state FROM access_claims WHERE digest = ?",
    [
      sqlight.text(claim.digest(token)),
    ],
  )
}

// The form is a fixed document: two fields, no script of its own, no value from
// the request, under the one policy that lets a form post to this origin. It is
// a navigation, from outside any page or from this origin.
pub fn the_claim_form_is_one_fixed_document_test() {
  fixture(fn(_, port, _) {
    let path = "/ui/claim"
    let open = fn(site) {
      get(port, path, [host(port), #("sec-fetch-site", site)])
    }
    let first = open("none")
    assert first.status == 200
    assert first.body == page.claim_page(None)
    assert string.contains(first.body, "name=\"token\"")
    assert string.contains(first.body, "name=\"name\"")
    assert string.contains(first.body, page.claim_name_hint())
    assert !string.contains(first.body, "<script")
    assert string.contains(policy_header(first), "form-action 'self'")
    assert referrer_policy(first) == Ok("no-referrer")
    assert open("same-origin").body == first.body

    // Another site, another port and a program that says nothing are refused,
    // and so is a host that is not this daemon's.
    assert open("same-site").status == 403
    assert open("cross-site").status == 403
    assert get(port, path, [host(port)]).status == 403
    assert get(port, path, [
        #("host", "evil.example"),
        #("sec-fetch-site", "none"),
      ]).status
      == 403

    // A query on the address is not read: a token in a URL would sit in history.
    assert get(port, path <> "?token=" <> string.repeat("a", 74), [
        host(port),
        #("sec-fetch-site", "none"),
      ]).body
      == first.body
  })
}

// The claim redeems in a browser with no `loom`: the response sets a page and a
// login, the page is an operator `Fresh` home that is the browser of the login,
// the login's row ends in thirty days, the name the person chose is the
// principal's, and the owner's listing shows the claim redeemed and one login.
pub fn a_browser_claim_lands_on_an_operator_fresh_home_with_a_login_test() {
  fixture_with(Signing, fn(ready, port, credential) {
    let session = create_shared_session(ready, "browser-claim", 1300)
    let token = invitation(port, credential, session, "claimant", "observer")
    let before = bootstrap.system_time_ms()
    let answer = redeemed_in_browser(port, token, "  Alex  ")
    let signed = signed_in(answer)
    assert string.contains(policy_header(answer), "form-action 'none'")
    assert signed.max_age <= 2_592_000
    assert signed.max_age >= 2_592_000 - 60

    // The page is a home, fresh, at operator ceiling, and it is the browser of
    // the login the claim bound.
    let fingerprint = string.slice(login.row_digest(id_of(signed.token)), 0, 16)
    assert string.contains(signed.page.page, "/home")
    assert open_page(port, signed.page).status == 200
    let home = home_socket(port, signed.page, [])
    assert home.status == 281
    assert list.key_find(home.headers, "x-page-origin") == Ok("fresh")
    assert list.key_find(home.headers, "x-page-ceiling") == Ok("operator")
    assert list.key_find(home.headers, "x-page-login") == Ok(fingerprint)

    // The login's row records its end, as a login the exchange sets does.
    let assert [row] = string.split(home.body, "\n")
    let assert [listed, issued, resumed, expires, parent] =
      string.split(row, "|")
    assert listed == fingerprint
    let assert Ok(began) = int.parse(issued) as "an instant"
    assert began >= before
    assert resumed == "None"
    assert expires == "Some(" <> int.to_string(began + login.lifetime_ms) <> ")"
    assert parent == "None"

    // The owner's listing shows the name chosen, the claim redeemed and the one
    // login.
    let reply = control(port, credential, "principals.list", [])
    let assert Ok(body) = field(reply, "body") as "a body"
    let assert Ok(json.Array(rows)) = field(body, "principals") as "the rows"
    let assert Ok(claimant) =
      list.find(rows, fn(row) {
        field(row, "principal_id") == Ok(json.String("claimant"))
      })
    assert field(claimant, "name") == Ok(json.String("Alex"))
    assert field(claimant, "logins") == Ok(json.Int(1))
    let assert Ok(credential_state) = field(claimant, "credential")
      as "a credential state"
    assert field(credential_state, "state") == Ok(json.String("active"))
    assert field(credential_state, "fingerprint")
      == Ok(json.String(fingerprint))
    assert field(credential_state, "claimed_at_ms") == Ok(json.Int(began))

    // The bookmark resumes without `loom`, and the claim is spent.
    assert resume_as(port, signed).status == 200
    claim_refused(
      redeemed_in_browser(port, token, "Again"),
      409,
      page.ClaimUsed,
      token,
    )
    assert claim_rows(ready.state_root, token) == ["claimed"]
  })
}

// Each way a claim cannot redeem is a refusal in its own fixed words: a spent
// claim, one bound to a bearer through `/v2/claim`, one the owner replaced, one
// nobody issued, one that has expired, and a name the catalogue will not take,
// which binds nothing and leaves the claim open for another try. None of them
// sets a cookie or repeats the token.
pub fn a_claim_that_cannot_redeem_is_refused_in_fixed_words_test() {
  fixture(fn(ready, port, credential) {
    let session = create_shared_session(ready, "browser-claim-refusals", 1301)

    // Spent: a second redemption of one that bound.
    let spent = invitation(port, credential, session, "spent", "observer")
    assert redeemed_in_browser(port, spent, "").status == 200
    claim_refused(
      redeemed_in_browser(port, spent, ""),
      409,
      page.ClaimUsed,
      spent,
    )

    // Bound to a bearer by the terminal's own route.
    let other = invitation(port, credential, session, "other", "observer")
    let bearer = claim.random_credential()
    let wire = daemon_claim_test.redeem(port, other, claim.digest(bearer))
    assert field(wire, "event") == Ok(json.String("credentials.claim"))
    claim_refused(
      redeemed_in_browser(port, other, ""),
      409,
      page.ClaimUsed,
      other,
    )

    // Void: the owner rotated the member, which ends its open claim. One that
    // was never issued is the same words.
    let voided = invitation(port, credential, session, "voided", "observer")
    let rotated =
      control(port, credential, "credentials.rotate", [
        #("principal_id", json.String("voided")),
      ])
    assert field(rotated, "event") == Ok(json.String("credentials.rotate"))
    claim_refused(
      redeemed_in_browser(port, voided, ""),
      404,
      page.ClaimUnknown,
      voided,
    )
    let never = claim.mint_token(token.production_entropy())
    claim_refused(
      redeemed_in_browser(port, never, ""),
      404,
      page.ClaimUnknown,
      never,
    )

    // Expired: the claim's time ran out before it was used.
    let late = invitation(port, credential, session, "late", "observer")
    let assert Ok(db) = sqlight.open(ready.state_root <> "/catalogue.db")
      as "the catalogue opens"
    assert sqlight.exec(
        "UPDATE access_claims SET expires_at_ms = 1 WHERE digest = '"
          <> claim.digest(late)
          <> "'",
        on: db,
      )
      == Ok(Nil)
    assert sqlight.close(db) == Ok(Nil)
    claim_refused(
      redeemed_in_browser(port, late, ""),
      410,
      page.ClaimExpired,
      late,
    )

    // A name the catalogue refuses binds nothing and leaves the claim open, so
    // another name redeems it.
    let named = invitation(port, credential, session, "named", "observer")
    claim_refused(
      redeemed_in_browser(port, named, string.repeat("n", 257)),
      400,
      page.NameRefused,
      named,
    )
    claim_refused(
      redeemed_in_browser(port, named, "  "),
      400,
      page.NameRefused,
      named,
    )
    claim_refused(
      redeemed_in_browser(port, named, "a\u{1}b"),
      400,
      page.NameRefused,
      named,
    )
    assert claim_rows(ready.state_root, named) == ["open"]
    assert redeemed_in_browser(port, named, "Second try").status == 200
    assert claim_rows(ready.state_root, named) == ["claimed"]
  })
}

// A cross-site post is refused before the claim is touched, and so is every
// request that does not declare itself this origin's own form: the claim is
// still open afterwards and redeems from the form. A bearer, a login and any
// other value that is not a claim token are refused before the registry does
// any work.
pub fn a_cross_site_claim_and_a_value_that_is_no_claim_ask_nothing_test() {
  fixture(fn(ready, port, credential) {
    let session = create_shared_session(ready, "browser-claim-senders", 1302)
    let token = invitation(port, credential, session, "careful", "observer")
    let body = claim_form(token, "Sam")
    let sent_from = fn(site) {
      claim_post(port, body, [#("sec-fetch-site", site)]).status
    }
    assert sent_from("same-site") == 403
    assert sent_from("cross-site") == 403
    assert sent_from("none") == 403
    assert send_request(
        port,
        "POST",
        "/ui/claim",
        [
          host(port),
          #("content-type", "application/x-www-form-urlencoded"),
          #("content-length", int.to_string(string.byte_size(body))),
        ],
        body,
      ).status
      == 403
    assert claim_post(port, body, [#("host", "evil.example")]).status == 403
    assert claim_rows(ready.state_root, token) == ["open"]

    // The form is a small URL-encoded body of the fields and no others.
    let post = fn(headers, text) { claim_post(port, text, headers).status }
    assert post([#("content-type", "text/plain")], body) == 400
    assert send_request(
        port,
        "POST",
        "/ui/claim",
        [
          host(port),
          #("sec-fetch-site", "same-origin"),
          #("content-type", "application/x-www-form-urlencoded"),
        ],
        body,
      ).status
      == 400
    assert post([], claim_form(token, string.repeat("a", 1100))) == 400
    assert post([], body <> "&other=1") == 400
    assert post([], "token=" <> token <> "&token=" <> token) == 400
    assert post([], "name=Sam") == 400
    assert claim_rows(ready.state_root, token) == ["open"]

    // Not a claim: a bearer, the owner's credential, a login, a claim with a
    // capital or too few hex characters, the claim's prefix alone. Each is the
    // notice for a value that is not a claim, with the registry untouched.
    let registry = manager.pid(ready.registry)
    let before = reductions_of(registry)
    let tail = string.drop_start(token, string.length("loomclaim_"))
    list.each(
      [
        credential,
        claim.random_credential(),
        sha256_text(token),
        "loomb1:" <> tail,
        "loomclaim_" <> string.uppercase(tail),
        "loomclaim_" <> string.drop_end(tail, 1),
        token <> "0",
        "loomclaim_",
        "",
      ],
      fn(typed) {
        claim_refused(
          redeemed_in_browser(port, typed, "Sam"),
          400,
          page.NotAClaim,
          typed,
        )
      },
    )
    assert reductions_of(registry) == before

    // A genuine claim is looked up, which the registry's work shows, and the
    // surrounding spaces a paste carries are not part of it.
    let signed =
      signed_in(claim_post(port, claim_form(" " <> token <> "\n", "Sam"), []))
    assert string.length(signed.token) > 0
    assert reductions_of(registry) > before
    assert claim_rows(ready.state_root, token) == ["claimed"]
  })
}

// The claim token, the login's three secrets and the page's are in no file
// under the state root and in no log line: the catalogue holds the claim's and
// the login's digests, and the owner's bearer is in `owner.token` only.
pub fn the_browser_claim_keeps_only_digests_under_the_state_root_test() {
  fixture(fn(ready, port, credential) {
    let session = create_shared_session(ready, "browser-claim-scan", 1303)
    let token = invitation(port, credential, session, "scanned", "observer")
    log_capture_start()
    let signed = signed_in(redeemed_in_browser(port, token, "Quinn"))
    claim_refused(
      redeemed_in_browser(port, token, "Quinn"),
      409,
      page.ClaimUsed,
      token,
    )
    let lines = log_capture_stop()
    let secrets = [
      token,
      signed.token,
      signed.nonce,
      signed.key,
      id_of(signed.token),
      signed.page.cookie,
      signed.page.nonce,
    ]

    // The log says a login was issued for a claim, by fingerprint.
    let joined = string.join(lines, "\n")
    list.each(secrets, fn(secret) {
      assert !string.contains(joined, secret)
    })
    assert string.contains(joined, "daemon.login_issued")
    assert string.contains(
      joined,
      string.slice(login.row_digest(id_of(signed.token)), 0, 16),
    )

    // No file under the state root holds one either. The scan has to reach the
    // catalogue, where the digests are, or it would pass over an empty list.
    let assert Ok(files) = simplifile.get_files(ready.state_root)
      as "the state root is readable"
    assert list.any(files, fn(file) { string.ends_with(file, "/catalogue.db") })
    list.each(files, fn(file) {
      let assert Ok(bytes) = simplifile.read_bits(file) as "a state file reads"
      list.each(secrets, fn(secret) {
        assert !holds(bytes, bit_array.from_string(secret))
      })
    })

    // The digests are there: the claim's, bound, and the login row's.
    assert claim_rows(ready.state_root, token) == ["claimed"]
    assert catalogue_rows(
        ready.state_root,
        "SELECT kind FROM access_credentials WHERE digest = ?",
        [sqlight.text(login.row_digest(id_of(signed.token)))],
      )
      == ["browser"]
  })
}

// Two browsers posting one claim at once redeem it once: the claim is reserved
// for the one in flight, and the other is refused either as busy (the first still
// holds the reservation) or as used (it had already finished). Never two logins
// for one claim, and the catalogue holds one.
pub fn two_posts_of_one_claim_redeem_it_once_test() {
  fixture(fn(ready, port, credential) {
    let session = create_shared_session(ready, "browser-claim-race", 1304)
    let token = invitation(port, credential, session, "racer", "observer")
    let answers = process.new_subject()
    let post = fn(name) {
      process.spawn(fn() {
        process.send(answers, redeemed_in_browser(port, token, name).status)
      })
    }
    let _ = post("One")
    let _ = post("Two")
    let assert Ok(first) = process.receive(answers, 10_000)
      as "the first post answers"
    let assert Ok(second) = process.receive(answers, 10_000)
      as "the second post answers"
    assert list.sort([first, second], int.compare) == [200, 409]
    assert claim_rows(ready.state_root, token) == ["claimed"]
    assert catalogue_rows(
        ready.state_root,
        "SELECT CAST(COUNT(*) AS TEXT) FROM access_credentials WHERE principal_id = 'racer'",
        [],
      )
      == ["1"]
  })
}

// --- stopping, archiving and deleting from the home (protocol-change/065) ----

// One action asked of the registry as the page's standing, in the open page's
// daemon lifetime.
fn manage(
  ready: root.Ready(String),
  standing: ui_socket.Standing(String),
  action: actions.Action,
  target: String,
) -> actions.Answer {
  ui_socket.manage_for(
    standing,
    page_open,
    ready.epoch,
    ready.sessions_directory,
    action,
    target,
  )
}

// A stop ends the process and answers once the registry holds the session saved,
// so the page's next read does not list it as running.
pub fn an_owners_home_stops_a_running_session_test() {
  fixture(fn(ready, _, credential) {
    let session = create_session(ready, "manage-stop", 1201)
    let owner = owner_standing(ready, credential, access.Operator)
    assert !is_saved(ready, session)
    assert manage(ready, owner, actions.Stop, session)
      == actions.Done(actions.Stop)
    assert is_saved(ready, session)

    // Stopping a session that is already saved is a stop that was made.
    assert manage(ready, owner, actions.Stop, session)
      == actions.Done(actions.Stop)
  })
}

// The sidebar's action on a running row is the stop and the archive as one
// request: the session ends, is held saved, and is hidden from the owner's list,
// all from the one answer.
pub fn an_owners_page_stops_and_archives_a_running_session_test() {
  fixture(fn(ready, _, credential) {
    let session = create_session(ready, "manage-stop-archive", 1205)
    let owner = owner_standing(ready, credential, access.Operator)
    let before = session_count(ready, credential)
    assert !is_saved(ready, session)
    assert manage(ready, owner, actions.StopArchive, session)
      == actions.Done(actions.StopArchive)
    assert session_count(ready, credential) == before - 1

    // A session that is already saved is archived all the same, so a row that
    // stopped between the page's list and the press is not an error.
    let saved_already = create_session(ready, "manage-saved-archive", 1206)
    saved(ready, saved_already)
    let listed = session_count(ready, credential)
    assert manage(ready, owner, actions.StopArchive, saved_already)
      == actions.Done(actions.StopArchive)
    assert session_count(ready, credential) == listed - 1
  })
}

// An archive and a delete refuse a session a process still holds, in the
// reason's words for it, and change nothing. Once the session is stopped an
// archive hides it from the owner's list and a delete removes it.
pub fn an_owners_home_archives_and_deletes_only_a_stopped_session_test() {
  fixture(fn(ready, _, credential) {
    let kept = create_session(ready, "manage-kept", 1202)
    let doomed = create_session(ready, "manage-doomed", 1203)
    let owner = owner_standing(ready, credential, access.Operator)
    let before = session_count(ready, credential)

    // Running: both are refused and the sessions are still listed.
    assert manage(ready, owner, actions.Archive, kept)
      == actions.Declined(actions.Running)
    assert manage(ready, owner, actions.Delete, doomed)
      == actions.Declined(actions.Running)
    assert session_count(ready, credential) == before

    // Saved: the archive hides one, and the delete removes the other.
    saved(ready, kept)
    saved(ready, doomed)
    assert manage(ready, owner, actions.Archive, kept)
      == actions.Done(actions.Archive)
    assert session_count(ready, credential) == before - 1
    assert manage(ready, owner, actions.Delete, doomed)
      == actions.Done(actions.Delete)
    assert session_count(ready, credential) == before - 2
    assert case manager.get(ready.registry, doomed) {
      Error(_) -> True
      Ok(_) -> False
    }
  })
}

// Each refusal changes nothing and is the owner-only words: a member, a home a
// bookmark resumed, a page minted to read, a page that has ended, a stale
// epoch, a principal the page was not admitted for, and a forged or unknown
// identity.
pub fn a_home_action_refuses_and_changes_nothing_test() {
  fixture(fn(ready, _, credential) {
    let session = create_session(ready, "manage-held", 1204)
    let _ = member(ready, "ui-manager", session, access.Operator)
    let owner = owner_standing(ready, credential, access.Operator)
    let #(member_standing, _) =
      standing_of(ready, "ui-manager", access.Operator)
    let refused = actions.Declined(actions.NotOwner)
    let ask = fn(standing, open, epoch, action, target) {
      ui_socket.manage_for(
        standing,
        open,
        epoch,
        ready.sessions_directory,
        action,
        target,
      )
    }

    list.each(
      [actions.Stop, actions.Archive, actions.Delete, actions.StopArchive],
      fn(action) {
        assert ask(member_standing, page_open, ready.epoch, action, session)
          == refused
        assert ask(
            ui_socket.Standing(..owner, origin: ui_sessions.Resumed),
            page_open,
            ready.epoch,
            action,
            session,
          )
          == refused
        assert ask(
            ui_socket.Standing(..owner, reach: ui_sessions.OneSession),
            page_open,
            ready.epoch,
            action,
            session,
          )
          == refused
        assert ask(
            ui_socket.Standing(..owner, ceiling: access.Observer),
            page_open,
            ready.epoch,
            action,
            session,
          )
          == refused
        assert ask(owner, fn() { Error(Nil) }, ready.epoch, action, session)
          == refused
        assert ask(
            ui_socket.Standing(..owner, principal: "someone-else"),
            page_open,
            ready.epoch,
            action,
            session,
          )
          == refused
        list.each(
          ["not a session", "", "01900000-0000-7000-8000-000000000000"],
          fn(target) {
            assert ask(owner, page_open, ready.epoch, action, target) == refused
          },
        )
      },
    )

    // A stale epoch reaches the registry, which refuses an archive or a delete
    // in the same words.
    saved(ready, session)
    assert ask(owner, page_open, "an-earlier-epoch", actions.Archive, session)
      == refused
    assert ask(owner, page_open, "an-earlier-epoch", actions.Delete, session)
      == refused
    assert is_saved(ready, session)
    assert session_count(ready, credential) >= 1
  })
}

// The request runs in a task of its own and the answer is handed to the function
// the page's runtime gave, from that task, whatever it is.
pub fn the_home_action_runs_in_a_task_and_delivers_its_answer_test() {
  fixture(fn(ready, _, credential) {
    let session = create_session(ready, "manage-task", 1205)
    let owner = owner_standing(ready, credential, access.Operator)
    let answered = process.new_subject()
    ui_socket.manage_task(
      owner,
      page_open,
      ready.epoch,
      ready.sessions_directory,
      actions.Stop,
      session,
      fn(answer) { process.send(answered, #(process.self(), answer)) },
    )
    let assert Ok(#(pid, answer)) = process.receive(answered, 10_000)
      as "the task answers"
    assert answer == actions.Done(actions.Stop)
    assert pid != process.self()
    assert is_saved(ready, session)

    ui_socket.manage_task(
      owner,
      page_open,
      ready.epoch,
      ready.sessions_directory,
      actions.Delete,
      "not a session",
      fn(answer) { process.send(answered, #(process.self(), answer)) },
    )
    let assert Ok(#(_, refusal)) = process.receive(answered, 10_000)
      as "the task answers a refusal"
    assert refusal == actions.Declined(actions.NotOwner)
  })
}

// `principals.rename` (protocol-change/065, the tenth pull request): a member
// omits the principal and renames itself, naming itself is the same, a member
// naming another is `forbidden`, and the owner may name any member and itself.
// The reply carries the name as stored, trimmed, and the owner's listing shows
// it at once.
pub fn principals_rename_follows_who_may_name_whom_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "rename-control", 1401)
    let mira = member(ready, "rename-mira", session, access.Operator)
    let _ = member(ready, "rename-noor", session, access.Operator)
    let renamed = fn(reply, id, name) {
      assert field(reply, "event") == Ok(json.String("principals.rename"))
      let assert Ok(body) = field(reply, "body") as "a body"
      assert field(body, "principal_id") == Ok(json.String(id))
      assert field(body, "name") == Ok(json.String(name))
    }
    let refused = fn(reply, code) {
      assert field(reply, "event") == Ok(json.String("error"))
      let assert Ok(body) = field(reply, "body") as "a body"
      assert field(body, "code") == Ok(json.String(code))
    }
    let named = fn(id) {
      let listed = control(port, credential, "principals.list", [])
      let assert Ok(body) = field(listed, "body") as "a body"
      let assert Ok(json.Array(rows)) = field(body, "principals") as "rows"
      let assert Ok(row) =
        list.find(rows, fn(row) {
          field(row, "principal_id") == Ok(json.String(id))
        })
        as "the principal is listed"
      field(row, "name")
    }

    // A member renames itself, with or without naming itself, and the name is
    // trimmed.
    renamed(
      control(port, mira, "principals.rename", [
        #("name", json.String("  Mira  ")),
      ]),
      "rename-mira",
      "Mira",
    )
    assert named("rename-mira") == Ok(json.String("Mira"))
    renamed(
      control(port, mira, "principals.rename", [
        #("principal_id", json.String("rename-mira")),
        #("name", json.String("Mira K")),
      ]),
      "rename-mira",
      "Mira K",
    )

    // A member naming another, or the owner, is forbidden and changes nothing.
    refused(
      control(port, mira, "principals.rename", [
        #("principal_id", json.String("rename-noor")),
        #("name", json.String("Taken")),
      ]),
      "forbidden",
    )
    refused(
      control(port, mira, "principals.rename", [
        #("principal_id", json.String(ready.owner.id)),
        #("name", json.String("Taken")),
      ]),
      "forbidden",
    )
    assert named("rename-noor") == Ok(json.String("rename-noor"))

    // The owner names a member, and itself with or without naming itself.
    renamed(
      control(port, credential, "principals.rename", [
        #("principal_id", json.String("rename-noor")),
        #("name", json.String("Noor")),
      ]),
      "rename-noor",
      "Noor",
    )
    assert named("rename-noor") == Ok(json.String("Noor"))
    renamed(
      control(port, credential, "principals.rename", [
        #("name", json.String("Olive")),
      ]),
      ready.owner.id,
      "Olive",
    )
    renamed(
      control(port, credential, "principals.rename", [
        #("principal_id", json.String(ready.owner.id)),
        #("name", json.String("Olive O")),
      ]),
      ready.owner.id,
      "Olive O",
    )
    assert named(ready.owner.id) == Ok(json.String("Olive O"))

    // A principal the catalogue does not hold is not found.
    refused(
      control(port, credential, "principals.rename", [
        #("principal_id", json.String("nobody-here")),
        #("name", json.String("Ghost")),
      ]),
      "not_found",
    )
  })
}

// A name the claim-time rule refuses is `invalid_name` and stores nothing:
// blank, control, zero-width and direction-changing characters and more than 256
// bytes. A malformed request is `bad_request`, and a stale epoch is
// `stale_epoch`, before the name is judged.
pub fn principals_rename_refuses_names_by_the_claim_rule_test() {
  fixture(fn(ready, port, credential) {
    let session = create_session(ready, "rename-rule", 1402)
    let ines = member(ready, "rename-ines", session, access.Operator)
    let code_of = fn(reply) {
      assert field(reply, "event") == Ok(json.String("error"))
      let assert Ok(body) = field(reply, "body") as "a body"
      let assert Ok(json.String(code)) = field(body, "code") as "a code"
      code
    }
    list.each(
      [
        "",
        "   ",
        "line\nbreak",
        "bell\u{7}",
        "reversed \u{202E}name",
        "zero\u{200B}width",
        string.repeat("x", 257),
      ],
      fn(name) {
        let reply =
          control(port, ines, "principals.rename", [
            #("name", json.String(name)),
          ])
        assert code_of(reply) == "invalid_name"
      },
    )
    let listed = control(port, credential, "principals.list", [])
    let assert Ok(body) = field(listed, "body") as "a body"
    let assert Ok(json.Array(rows)) = field(body, "principals") as "rows"
    let assert Ok(row) =
      list.find(rows, fn(row) {
        field(row, "principal_id") == Ok(json.String("rename-ines"))
      })
      as "the member is listed"
    assert field(row, "name") == Ok(json.String("rename-ines"))

    // Malformed: no name, a name that is not text, a principal that is not text,
    // and a frame that carries a megabyte of name.
    list.each(
      [
        [],
        [#("name", json.Int(7))],
        [#("name", json.String("Ines")), #("principal_id", json.Int(1))],
        [#("name", json.String(string.repeat("x", 2048)))],
      ],
      fn(fields) {
        assert code_of(control(port, ines, "principals.rename", fields))
          == "bad_request"
      },
    )

    // A stale epoch is refused, whatever the name.
    let #(socket, _) = daemon_server_test.connect(port, ines, "/v2/control")
    let _ = daemon_server_test.frame(socket, within_ms: 1000)
    let stale =
      daemon_server_test.send(
        socket,
        1,
        "principals.rename",
        json.Object([
          #("epoch", json.String("an-earlier-epoch")),
          #("name", json.String("Ines")),
        ]),
        within_ms: 1000,
      )
    let _ = ffi_ws.tcp_close(socket)
    assert code_of(stale) == "stale_epoch"
  })
}

// The home's own rename (protocol-change/065, the tenth pull request): a member
// operator's page and an owner's page rename their own principal through the
// registry, the answer is the name as stored, and `name_read` shows it on the
// next read. The name is trimmed, and a name that is already the page's stores
// the same one.
pub fn a_home_page_renames_its_own_principal_test() {
  fixture(fn(ready, _, credential) {
    let session = create_session(ready, "rename-self", 1403)
    let _ = member(ready, "rename-self-member", session, access.Operator)
    let #(member_standing, _) =
      standing_of(ready, "rename-self-member", access.Operator)
    let owner = owner_standing(ready, credential, access.Operator)

    assert ui_socket.name_read(member_standing, page_open)
      == Some("rename-self-member")
    assert ui_socket.rename_self_for(
        member_standing,
        page_open,
        ready.epoch,
        "  Mira  ",
      )
      == names.Renamed("Mira")
    assert ui_socket.name_read(member_standing, page_open) == Some("Mira")
    assert ui_socket.rename_self_for(
        member_standing,
        page_open,
        ready.epoch,
        "Mira",
      )
      == names.Renamed("Mira")

    assert ui_socket.rename_self_for(owner, page_open, ready.epoch, "Olive")
      == names.Renamed("Olive")
    assert ui_socket.name_read(owner, page_open) == Some("Olive")
  })
}

// Each refusal stores nothing: a page that ended, a page minted to read, a stale
// epoch and a credential that is not the page's principal are the page's own
// words, and a name that breaks the claim-time rule is the name's.
pub fn a_home_page_rename_refuses_and_stores_nothing_test() {
  fixture(fn(ready, _, credential) {
    let session = create_session(ready, "rename-self-refused", 1404)
    let _ = member(ready, "rename-self-held", session, access.Operator)
    let #(standing, _) = standing_of(ready, "rename-self-held", access.Operator)
    let rename = fn(standing, open, epoch, name) {
      ui_socket.rename_self_for(standing, open, epoch, name)
    }
    let refused = names.Declined(names.NotAllowed)

    assert rename(standing, fn() { Error(Nil) }, ready.epoch, "late") == refused
    assert rename(
        ui_socket.Standing(..standing, ceiling: access.Observer),
        page_open,
        ready.epoch,
        "watching",
      )
      == refused
    assert rename(standing, page_open, "an-earlier-epoch", "stale") == refused
    assert rename(
        ui_socket.Standing(..standing, principal: "someone-else"),
        page_open,
        ready.epoch,
        "swapped",
      )
      == refused

    list.each(
      [
        "",
        "   ",
        "line\nbreak",
        "bell\u{7}",
        "reversed \u{202E}name",
        "zero\u{200B}width",
        string.repeat("x", 257),
      ],
      fn(name) {
        assert rename(standing, page_open, ready.epoch, name)
          == names.Declined(names.InvalidName)
      },
    )

    // A name that was never read back: the page is open and the credential is
    // the principal's, and nothing above changed it.
    assert ui_socket.name_read(standing, page_open) == Some("rename-self-held")
    assert ui_socket.name_read(standing, fn() { Error(Nil) }) == None
    assert ui_socket.name_read(
        ui_socket.Standing(..standing, principal: "someone-else"),
        page_open,
      )
      == None
    let owner = owner_standing(ready, credential, access.Operator)
    assert ui_socket.name_read(owner, page_open) != None
  })
}

// The admin page's rename (protocol-change/065, the tenth pull request): the
// owner's page renames a member and itself, the answer carries no claim, and it
// costs no allowance: more renames than the allowance holds all succeed. A name
// the rule refuses is `InvalidName` and a principal the catalogue lacks is
// `NotFound`.
pub fn the_admin_page_renames_people_without_spending_the_allowance_test() {
  fixture(fn(ready, _, credential) {
    let session = create_session(ready, "rename-admin", 1405)
    let _ = member(ready, "rename-admin-member", session, access.Operator)
    let #(member_standing, tickets) =
      standing_of(ready, "rename-admin-member", access.Operator)
    let owner = owner_standing(ready, credential, access.Operator)
    let ask = fn(standing, action) {
      ui_socket.admin_for(
        standing,
        tickets,
        page_open,
        ready.epoch,
        ready.state_root,
        Ok("ws://127.0.0.1:1/v2/control"),
        action,
      )
    }

    list.index_map(list.repeat(Nil, ui_sessions.invite_limit + 2), fn(_, index) {
      let number = index + 1
      assert ask(
          owner,
          grants.Rename("rename-admin-member", "Name " <> int.to_string(number)),
        )
        == grants.Changed
    })
    assert ui_socket.name_read(member_standing, page_open) == Some("Name 5")
    assert ask(owner, grants.Rename(ready.owner.id, "  The Owner "))
      == grants.Changed
    assert ui_socket.name_read(owner, page_open) == Some("The Owner")

    assert ask(owner, grants.Rename("rename-admin-member", "line\nbreak"))
      == grants.Declined(grants.InvalidName)
    assert ask(owner, grants.Rename("rename-admin-member", "   "))
      == grants.Declined(grants.InvalidName)
    assert ask(owner, grants.Rename("nobody-here", "Ghost"))
      == grants.Declined(grants.NotFound)
    assert ui_socket.name_read(member_standing, page_open) == Some("Name 5")
  })
}

// The page's socket as the "Make shareable" confirm asks for it.
fn shareable_with(
  port: Int,
  entered: Entered,
  more: List(#(String, String)),
) -> Answer {
  get(port, entered.page <> "/ws?csrf-token=" <> entered.nonce, [
    host(port),
    #("cookie", "loom_ui=" <> entered.cookie),
    #("origin", "http://127.0.0.1:" <> int.to_string(port)),
    #("x-shareable", "1"),
    ..more
  ])
}

// The scope the catalogue holds for a session.
fn scope_in(state_root: String, session: String) -> List(String) {
  catalogue_rows(
    state_root,
    "SELECT d.scope FROM catalogue_domains d JOIN catalogue_domain_sessions s ON s.domain_id = d.domain_id WHERE s.session_id = ?",
    [sqlight.text(session)],
  )
}

// Whether the registry holds a process for the session.
fn running_now(ready: root.Ready(String), session: String) -> Bool {
  result.is_ok(manager.resolve(ready.registry, session))
}

// Only an owner's operator page is handed the capability: an owner who asked for
// an observer's page, a member operator and a member observer get none.
pub fn only_an_owners_operator_page_is_offered_make_shareable_test() {
  fixture_with(Inviting, fn(ready, port, credential) {
    let session = create_session(ready, "shareable-offer", 1501)
    let operator = member(ready, "shareable-op", session, access.Operator)
    let watcher = member(ready, "shareable-watch", session, access.Observer)

    let owner_watching = enter(port, link(port, credential, session))
    assert shareable_with(port, owner_watching, []).status == 295
    let operating = enter(port, operate(port, operator, session))
    assert shareable_with(port, operating, []).status == 294
    let watching = enter(port, operate(port, watcher, session))
    assert shareable_with(port, watching, []).status == 295

    // None of them touched the session.
    assert scope_in(ready.state_root, session) == ["workspace_private"]
    assert running_now(ready, session)
  })
}

// The daemon refuses again if the capability reached a page it was not meant
// for, by the principal and the page's own standing and never by the page: a
// member operator, an owner's read-only page and a page that has ended each get
// `NotOwner`, and the session is neither stopped nor changed.
pub fn the_daemon_refuses_a_forced_make_shareable_test() {
  fixture_with(Inviting, fn(ready, port, credential) {
    let session = create_session(ready, "shareable-forced", 1502)
    let operator =
      member(ready, "shareable-forced-op", session, access.Operator)
    let force = [#("x-invite-force", "1")]

    let operating = enter(port, operate(port, operator, session))
    let refused = shareable_with(port, operating, force)
    assert refused.status == 297
    assert refused.body == "NotOwner"

    let owner_watching = enter(port, link(port, credential, session))
    assert shareable_with(port, owner_watching, force).body == "NotOwner"

    let owning = enter(port, operate(port, credential, session))
    let ended = [#("x-switch-ended", "1"), ..force]
    assert shareable_with(port, owning, ended).body == "NotOwner"

    assert scope_in(ready.state_root, session) == ["workspace_private"]
    assert running_now(ready, session)
  })
}

// The whole task against the real registry: a running private session is stopped,
// isolated and resumed, the owner's invitation into it was refused before and is
// made after, and asking again changes nothing.
pub fn an_owner_makes_a_running_private_session_shareable_test() {
  fixture_with(Inviting, fn(ready, port, credential) {
    let session = create_session(ready, "shareable-run", 1503)
    let page = enter(port, operate(port, credential, session))
    assert invite(port, page, "observer").body == "NotIsolated"
    assert scope_in(ready.state_root, session) == ["workspace_private"]

    let answer = shareable_with(port, page, [])
    assert answer.status == 296
    assert scope_in(ready.state_root, session) == ["session_only"]

    // The session was started again, so the page's next request finds it.
    let assert poll.Answered(Nil) =
      poll.until(within: 5000, every: 10, attempt: fn() {
        case running_now(ready, session) {
          True -> poll.Done(Nil)
          False -> poll.Retry
        }
      })
    let again = enter(port, operate(port, credential, session))
    assert invite(port, again, "observer").status == 292
    assert shareable_with(port, again, []).status == 296
  })
}

// A page that a bookmark opened mints no access: the owner's operator page gets
// neither capability, and a press forced from it is refused as `NotOwner`
// before the session is stopped or an invitation is made. The session is still
// running, still private, and nobody was invited.
pub fn a_bookmarks_page_may_not_mint_access_test() {
  fixture_with(Inviting, fn(ready, port, credential) {
    let session = create_session(ready, "bookmark-mint", 1504)
    let page = enter(port, operate(port, credential, session))
    let bookmark = [#("x-origin-resumed", "1")]
    let force = [#("x-invite-force", "1"), ..bookmark]

    assert shareable_with(port, page, bookmark).status == 294
    assert invite_with(port, page, "observer", bookmark).status == 294

    let refused = shareable_with(port, page, force)
    assert refused.status == 297
    assert refused.body == "NotOwner"
    let refused = invite_with(port, page, "observer", force)
    assert refused.status == 293
    assert refused.body == "NotOwner"

    assert scope_in(ready.state_root, session) == ["workspace_private"]
    assert running_now(ready, session)
    assert members(ready.state_root) == []
  })
}

// The property the design rests on: the task outlives the request that began it.
// The stub answers at once and its process goes, and the session still ends up
// session-only and running again, which a task linked to that process could not
// do once the stop had ended the page.
pub fn the_task_outlives_the_page_that_asked_for_it_test() {
  fixture_with(Inviting, fn(ready, port, credential) {
    let session = create_session(ready, "task-outlives", 1505)
    let page = enter(port, operate(port, credential, session))
    let started = shareable_with(port, page, [#("x-shareable-task", "1")])
    assert started.status == 298

    let assert poll.Answered(Nil) =
      poll.until(within: 10_000, every: 20, attempt: fn() {
        case
          scope_in(ready.state_root, session) == ["session_only"]
          && running_now(ready, session)
        {
          True -> poll.Done(Nil)
          False -> poll.Retry
        }
      })
      as "the session becomes session-only and runs again"
    Nil
  })
}

// The profile a page chose reaches the creation unchanged, and the default
// roles are no profile at all: the daemon's registry stores what this hands it.
pub fn a_page_creation_carries_the_chosen_profile_to_the_registry_test() {
  fixture(fn(ready, _, credential) {
    let existing = create_session(ready, "profile-known", 1108)
    let #(standing, tickets) =
      creator_standing(ready, credential, access.Operator)
    let asked = process.new_subject()
    let create = counting_create(ready, existing, asked)
    let attempt = fn(roles) {
      ui_socket.create_for(
        standing,
        tickets,
        page_open,
        create,
        no_release,
        new_folder.check(_, ready.state_root),
        creations.Drawn(ready.state_root),
        "x",
        creations.Private,
        roles,
        within: 2000,
      )
    }
    let _ = attempt(creations.Roles(Some("deepseek"), None))
    let assert Ok(named) = process.receive(asked, 0)
    assert named.profile == Some("deepseek")
    assert named.model == None
    let _ = attempt(creations.default_roles)
    let assert Ok(plain) = process.receive(asked, 0)
    assert plain.profile == None
    assert plain.model == None
  })
}

// The model a page chose reaches the creation beside the profile, and each is
// independent: the registry stores both when both were chosen and either alone.
pub fn a_page_creation_carries_the_chosen_model_to_the_registry_test() {
  fixture(fn(ready, _, credential) {
    let existing = create_session(ready, "model-known", 1110)
    let #(standing, tickets) =
      creator_standing(ready, credential, access.Operator)
    let asked = process.new_subject()
    let create = counting_create(ready, existing, asked)
    let attempt = fn(roles) {
      ui_socket.create_for(
        standing,
        tickets,
        page_open,
        create,
        no_release,
        new_folder.check(_, ready.state_root),
        creations.Drawn(ready.state_root),
        "x",
        creations.Private,
        roles,
        within: 2000,
      )
    }
    let _ = attempt(creations.Roles(None, Some("fast")))
    let assert Ok(pinned) = process.receive(asked, 0)
    assert pinned.model == Some("fast")
    assert pinned.profile == None
    let _ = attempt(creations.Roles(Some("deepseek"), Some("fast")))
    let assert Ok(both) = process.receive(asked, 0)
    assert both.model == Some("fast")
    assert both.profile == Some("deepseek")
  })
}

// The registry's refusal of a model its configuration does not define reaches
// the page as the model's own fixed words, not as a general failure.
pub fn an_unknown_model_is_declined_in_its_own_words_test() {
  fixture(fn(ready, _, credential) {
    let _existing = create_session(ready, "model-unknown", 1111)
    let #(standing, tickets) =
      creator_standing(ready, credential, access.Operator)
    let refuse = fn(_, _, _) { Error("unknown_model") }
    assert ui_socket.create_for(
        standing,
        tickets,
        page_open,
        refuse,
        no_release,
        new_folder.check(_, ready.state_root),
        creations.Drawn(ready.state_root),
        "x",
        creations.Private,
        creations.Roles(None, Some("nope")),
        within: 2000,
      )
      == creations.Declined(creations.UnknownModel)
  })
}

// The registry's refusal of a profile its configuration does not define reaches
// the page as the profile's own fixed words, not as a general failure.
pub fn an_unknown_profile_is_declined_in_its_own_words_test() {
  fixture(fn(ready, _, credential) {
    let _existing = create_session(ready, "profile-unknown", 1109)
    let #(standing, tickets) =
      creator_standing(ready, credential, access.Operator)
    let refuse = fn(_, _, _) { Error("unknown_profile") }
    assert ui_socket.create_for(
        standing,
        tickets,
        page_open,
        refuse,
        no_release,
        new_folder.check(_, ready.state_root),
        creations.Drawn(ready.state_root),
        "x",
        creations.Private,
        creations.Roles(Some("nope"), None),
        within: 2000,
      )
      == creations.Declined(creations.UnknownProfile)
  })
}

// --- peer links from a page (protocol-change/077) ----------------------------

// A directory that resolves no session, so a request that passes the daemon's
// authority checks is refused at the first resolution with the fixed words for
// an unavailable read, and any refusal before that is the owner-only words.
fn unreachable_directory() -> peers.Directory {
  peers.Directory(resolve: fn(_) { Error("not resident") }, describe: fn(_) {
    Error("not resident")
  })
}

// The authority is re-derived at each request: a member of the very session, a
// page that has ended, one minted to read and a principal the page was not
// admitted as are all refused as the owner-only words before the request is
// looked at, and only the owner's open operating page reaches it.
pub fn a_page_peer_request_is_refused_unless_the_owner_still_asks_test() {
  fixture(fn(ready, _, credential) {
    let session = create_session(ready, "peers-held", 1121)
    let _ = member(ready, "ui-peer-member", session, access.Operator)
    let owner = owner_standing(ready, credential, access.Operator)
    let #(member_standing, _) =
      standing_of(ready, "ui-peer-member", access.Operator)
    let directory = unreachable_directory()
    let ask = fn(standing, open) {
      ui_socket.peer_links_for(
        standing,
        open,
        directory,
        session,
        peer_links.Read("main"),
      )
    }
    let refused = peer_links.Declined(peer_links.NotOwner)
    assert ask(member_standing, page_open) == refused
    assert ask(owner, fn() { Error(Nil) }) == refused
    assert ask(ui_socket.Standing(..owner, ceiling: access.Observer), page_open)
      == refused
    assert ask(
        ui_socket.Standing(..owner, principal: "someone-else"),
        page_open,
      )
      == refused

    // The owner's open page passes every check and stops at the directory.
    assert ask(owner, page_open) == peer_links.Declined(peer_links.Unavailable)
  })
}

// A link names its other session and strand as text, and each is judged again
// by the daemon: an identity that is not a session's, the page's own session
// and a strand that is blank are refused with their own words, and nothing is
// resolved for any of them.
pub fn a_page_link_judges_what_the_request_names_test() {
  fixture(fn(ready, _, credential) {
    let session = create_session(ready, "peers-judged", 1122)
    let other = create_session(ready, "peers-other", 1123)
    let owner = owner_standing(ready, credential, access.Operator)
    let link = fn(target_session, target) {
      ui_socket.peer_links_for(
        owner,
        page_open,
        unreachable_directory(),
        session,
        peer_links.Link(
          "main",
          target_session,
          target,
          peer_links.BusyOnly,
          peer_links.OneWay,
        ),
      )
    }
    assert link(session, "main") == peer_links.Declined(peer_links.SameSession)
    assert link(other, "") == peer_links.Declined(peer_links.InvalidStrand)
    assert link(other, string.repeat("x", 129))
      == peer_links.Declined(peer_links.InvalidStrand)
    assert link("not a session", "main")
      == peer_links.Declined(peer_links.NotRunning)

    // A session that is not resident is not opened for the link.
    assert link(other, "main") == peer_links.Declined(peer_links.NotRunning)
  })
}

// The request runs in a task of its own and the answer is handed to the
// function the page's runtime gave, from that task.
pub fn the_peer_request_runs_in_a_task_and_delivers_its_answer_test() {
  fixture(fn(ready, _, credential) {
    let session = create_session(ready, "peers-task", 1124)
    let owner = owner_standing(ready, credential, access.Operator)
    let answered = process.new_subject()
    ui_socket.peer_links_task(
      owner,
      page_open,
      unreachable_directory(),
      session,
      peer_links.Read("main"),
      fn(answer) { process.send(answered, #(process.self(), answer)) },
    )
    let assert Ok(#(from, answer)) = process.receive(answered, 5000)
      as "the task answers"
    assert from != process.self()
    assert answer == peer_links.Declined(peer_links.Unavailable)
  })
}

// --- default peer links' eligibility (protocol-change/077) -------------------

// A session with a member is not one the owner holds alone, and one with none is. The registry answers from one query of
// the membership table, in session-ID order.
pub fn a_session_with_a_member_is_not_unshared_test() {
  fixture(fn(ready, _, _) {
    let alone = create_session(ready, "peers-alone", 1131)
    let shared = create_session(ready, "peers-shared", 1132)
    let _ = member(ready, "ui-peer-operator", shared, access.Operator)
    let listed = manager.unshared_sessions(ready.registry)
    assert list.contains(listed, alone)
    assert !list.contains(listed, shared)
    assert list.sort(listed, string.compare) == listed
  })
}

// Explicit result reads go through a real HTTP listener and the same page grant
// as images. Their fixture reader supplies immutable bytes, never HTML.
fn result_read(port: Int, page: Entered, suffix: String) -> Answer {
  get(
    port,
    page.page
      <> "/result/"
      <> ids.entry_id_to_string(ui_result_test.result_id())
      <> "/"
      <> suffix,
    [
      host(port),
      #("sec-fetch-site", "same-origin"),
      #("cookie", "loom_ui=" <> page.cookie),
    ],
  )
}

pub fn large_results_page_and_download_through_the_authenticated_router_test() {
  fixture_with(Pictured, fn(ready, port, credential) {
    let session = create_session(ready, "results", 951)
    let early = enter(port, operate(port, credential, session))
    assert result_read(port, early, "page/0").status == 200
    let page = opened(port, link(port, credential, session))
    let answer = result_read(port, page, "page/0")
    assert answer.status == 200
    assert bit_array.byte_size(answer.raw) < 35_000
    assert !string.contains(answer.body, "<script>")
    assert string.contains(answer.body, "&lt;script&gt;")
    assert list.key_find(answer.headers, "cache-control") == Ok("no-store")
    assert list.key_find(answer.headers, "content-security-policy")
      == Ok(policy(port))
    assert result_read(port, page, "page/-1").status == 404
    assert result_read(port, page, "page/2098").status == 404
    let download = result_read(port, page, "download")
    assert download.status == 200
    assert download.raw == bit_array.from_string(ui_result_test.payload())
    assert list.key_find(download.headers, "content-type")
      == Ok("application/json")
    assert list.key_find(download.headers, "content-disposition")
      == Ok("attachment; filename=\"loom-tool-result.json\"")
    assert list.key_find(download.headers, "x-content-type-options")
      == Ok("nosniff")
    let unknown =
      get(
        port,
        page.page <> "/result/0198c0de-0000-7000-8000-000000000002/download",
        [
          host(port),
          #("sec-fetch-site", "same-origin"),
          #("cookie", "loom_ui=" <> page.cookie),
        ],
      )
    assert unknown.status == 404
  })
}

pub fn a_result_read_keeps_page_isolation_and_fetch_site_checks_test() {
  fixture_with(Pictured, fn(ready, port, credential) {
    let session = create_session(ready, "result-guards", 952)
    let page = opened(port, operate(port, credential, session))
    let other = opened(port, operate(port, credential, session))
    let address =
      page.page
      <> "/result/"
      <> ids.entry_id_to_string(ui_result_test.result_id())
      <> "/download"
    assert get(port, address, [host(port), #("sec-fetch-site", "same-origin")]).status
      == 401
    assert get(port, address, [
        host(port),
        #("sec-fetch-site", "same-origin"),
        #("cookie", "loom_ui=" <> other.cookie),
      ]).status
      == 401
    assert get(port, address, [
        host(port),
        #("sec-fetch-site", "cross-site"),
        #("cookie", "loom_ui=" <> page.cookie),
      ]).status
      == 403
  })
}

pub fn a_revoked_credential_reads_neither_a_result_page_nor_download_test() {
  fixture_with(Pictured, fn(ready, port, _) {
    let session = create_session(ready, "revoked-results", 953)
    let credential = member(ready, "ui-result", session, access.Operator)
    let page = opened(port, operate(port, credential, session))
    assert result_read(port, page, "page/0").status == 200
    let assert Ok(digest) =
      credential
      |> bit_array.from_string
      |> bootstrap.sha256
      |> bit_array.base16_encode
      |> string.lowercase
      |> access.credential_digest
      as "the member digest is valid"
    let assert Ok(store) = catalogue.open(ready.state_root <> "/catalogue.db")
      as "fixture administration opens the catalogue"
    assert access.revoke_credential(store, digest) == Ok(Nil)
    assert catalogue.close(store) == Ok(Nil)
    assert result_read(port, page, "page/0").status == 401
    assert result_read(port, page, "download").status == 401
  })
}

pub fn an_expired_page_reads_neither_a_result_page_nor_download_test() {
  fixture_lasting(Pictured, 1500, fn(ready, port, credential) {
    let session = create_session(ready, "expired-results", 954)
    let page = opened(port, operate(port, credential, session))
    assert result_read(port, page, "page/0").status == 200
    assert poll.until(within: 5000, every: 100, attempt: fn() {
        case result_read(port, page, "page/0").status {
          401 -> poll.Done(Nil)
          _ -> poll.Retry
        }
      })
      == poll.Answered(Nil)
    assert result_read(port, page, "download").status == 401
  })
}
