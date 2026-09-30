//// Version-two routing separates daemon control from resident conversations.
////
//// Every upgrade authenticates a digest against the durable access catalogue.
//// Control requests repeat that check; membership and operation identities are
//// checked by the serialized registry. Session routing never opens a runtime.
//// The supplied conversation adapter must speak v2 and must not return before
//// its websocket process has attempted the parser reservation's transfer, or
//// the release here would race it; the legacy gateway is not an adapter.
////
//// With `loomd --ui` the router also serves the web view under `/ui`
//// (protocol-change/051): a page per session, the ticket exchange, the
//// page's socket and a fixed list of assets. Without it every `/ui` path is
//// a 404 and the control `hello` does not name the view, so the two v2
//// endpoints are the whole surface, as spec Part 1.6 says.

import broker/token
import client/daemon/manager
import client/daemon/protocol
import client/daemon/root
import client/daemon/ui_assets
import client/daemon/ui_http
import client/daemon/ui_relay
import client/daemon/ui_sessions
import client/daemon/upgrade_log
import client/peer_mail
import client/peers
import core/ids
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/pair
import gleam/result
import gleam/string
import host/bootstrap
import host/build_identity
import host/claim
import mist
import storage/access
import storage/catalogue
import storage/domain
import web_view/ending.{type Ending}
import web_view/page
import weft

/// Capabilities owned by the daemon, not supplied over the wire.
pub type Config(instance) {
  Config(
    /// Lifetime owner and admission authority.
    daemon: root.Root(instance),
    /// Projects the address-only communication endpoint from a resident.
    peer_endpoint: fn(instance) -> Option(peer_mail.Endpoint),
    /// Captured owner domain config reference; empty explicitly selects no file.
    domain_configuration: String,
    /// Fresh entropy-seeded generator for explicit creation.
    generator: fn() -> ids.Generator,
    /// A v2-only conversation adapter, responsible for transferring its permit.
    session_upgrade: fn(Request(mist.Connection), Attachment(instance)) ->
      Response(mist.ResponseData),
    /// The web view, present only when the daemon was started with `--ui`.
    ui: Option(Ui(instance)),
  )
}

/// The web view's half of the router's configuration (protocol-change/051).
pub type Ui(instance) {
  Ui(
    /// The ticket and UI-session tables.
    sessions: ui_sessions.Sessions,
    /// The page's stylesheet and scripts and Lustre's client runtime, read
    /// once when the daemon started.
    assets: ui_assets.Assets,
    /// Upgrades a checked page request to the component's socket; like
    /// `session_upgrade`, it transfers the attachment's permit. The third
    /// argument answers the page's deadline while its UI session is still
    /// live, which the socket checks with every authorization and carries onto
    /// a ticket it mints for a switch; the fourth is the page's
    /// ceiling, which the relay caps every authorization with.
    upgrade: fn(
      Request(mist.Connection),
      Attachment(instance),
      fn() -> Result(Int, Nil),
      access.Role,
    ) -> Response(mist.ResponseData),
  )
}

/// Whose role an attachment carries.
type Role {
  /// The principal's membership role, as a terminal socket carries it.
  MembershipRole

  /// The membership role capped by a web page's ceiling and by Operator
  /// (`ui_relay.capped`).
  PageRole(ceiling: access.Role)
}

/// One authorized resident target; it cannot be retargeted by a later command.
pub type Attachment(instance) {
  Attachment(
    /// The resident value resolved with an atomic incarnation comparison.
    instance: instance,
    /// Canonical durable identity from the route.
    session_id: String,
    /// Original runtime reservation identity.
    incarnation: String,
    /// Fresh identity for this attachment, distinct from durable session identity.
    connection_id: String,
    /// Current daemon lifetime identity.
    epoch: String,
    /// Authenticated durable principal.
    principal: access.Principal,
    /// Session-scoped authority at upgrade time.
    authority: access.Authority,
    /// Digest for repeated authorization; never the plaintext credential.
    digest: access.Digest,
    /// Transferred to the actual WebSocket PID in that process's first
    /// handler turn, before it serves a frame.
    permit: root.Permit,
    /// The registry that answers every later question about this attachment.
    /// It is captured here so per-frame authorization and reader failure
    /// reach the registry directly: asking the root for its readiness first
    /// cost a round trip per frame, and a timeout on that round trip once
    /// dropped the incarnation stop a poisoned reader depends on.
    registry: manager.Manager(instance),
    /// The session's catalogue registration, read while the route resolved
    /// the session. The web view's heading takes its name and workspace
    /// from here, so a page needs no second read of the catalogue.
    registration: catalogue.Registration,
  )
}

type Signal {
  // The self-addressed message that runs the permit transfer. The control
  // socket's initializer queues it and nothing else ever sends it.
  Admit
}

type AfterReply {
  KeepServing
  DrainDaemon
}

/// Routes only the two v2 endpoint families, refusing unknown paths.
///
/// ## Examples
///
/// ```gleam
/// // mist.new(fn(request) { server.handle(config, request) })
/// ```
pub fn handle(
  config: Config(instance),
  request: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  case request.path_segments(request) {
    ["v2", "control"] -> authenticated(config, request, None)
    ["v2", "sessions", id, "ws"] -> authenticated(config, request, Some(id))
    ["v2", "claim"] -> claim_route(config, request)
    ["ui", ..] ->
      case config.ui {
        Some(ui) -> web_view(config, ui, request)
        None -> plain(404, "unknown endpoint")
      }
    _ -> plain(404, "unknown endpoint")
  }
}

// The web view's routes, in the order protocol-change/051 checks them: the
// host first, then the check that belongs to the route, then the cookie and
// the credential behind it. Every response carries the view's headers except
// the socket's upgrade, which carries mist's.
fn web_view(config: Config(instance), ui: Ui(instance), request) {
  case ui_http.loopback_host(request) {
    Error(Nil) -> ui_http.refused(plain(403, "forbidden host"))
    Ok(host) ->
      case ui_http.route(request) {
        ui_http.Socket(key, id, nonce) ->
          web_socket(config, ui, request, host, key, id, nonce)
        route -> ui_http.secured(web_document(config, ui, request, route), host)
      }
  }
}

// The page's socket: this origin, then a nonce in the query, then the
// page's grant under its key, then that nonce against the grant's, then the
// same resident-session resolution a terminal's socket uses, with the
// membership role capped by the page's ceiling.
fn web_socket(
  config: Config(instance),
  ui: Ui(instance),
  request,
  host: String,
  key: String,
  id: String,
  nonce: Option(String),
) {
  let checked = {
    use Nil <- result.try(case ui_http.origin_matches(request, host) {
      True -> Ok(Nil)
      False -> Error(plain(403, "forbidden origin"))
    })

    // A socket with no nonce at all is refused before the grant is looked
    // up, so it costs the daemon no readiness, authentication or membership
    // read.
    use nonce <- result.try(
      option.to_result(nonce, Nil)
      |> result.map_error(fn(_) { plain(403, "forbidden page") }),
    )
    use #(state, page, cookie) <- result.try(page_grant(
      config,
      ui,
      request,
      key,
      id,
    ))

    // The nonce is what the tab kept and no other port can read. It is
    // compared with the digest this UI session was given, in constant time,
    // before any resident session is resolved.
    use Nil <- result.try(case ui_sessions.admits(page, nonce) {
      True -> Ok(Nil)
      False -> Error(plain(403, "forbidden page"))
    })
    Ok(#(state, ui_sessions.grant(page), cookie))
  }
  case checked {
    Error(response) -> ui_http.secured(response, host)
    Ok(#(state, grant, cookie)) -> {
      let open = ui_sessions.open_until(ui.sessions, cookie, grant)
      resident_upgrade(
        config,
        request,
        state,
        grant.credential,
        id,
        PageRole(grant.ceiling),
        fn(request, attachment) {
          ui.upgrade(request, attachment, open, grant.ceiling)
        },
      )
    }
  }
}

fn web_document(
  config: Config(instance),
  ui: Ui(instance),
  request,
  route: ui_http.Route,
) {
  case route {
    ui_http.Unknown | ui_http.Socket(..) -> plain(404, "unknown endpoint")
    ui_http.Asset(asset) -> {
      let #(content_type, body) = ui_assets.body(ui.assets, asset)
      document(200, content_type, body)
    }

    // A keyed page is reached only by a navigation from this origin or from
    // outside any page, so no other page can put it in front of the person.
    ui_http.Page(key, id) ->
      case ui_http.navigation_allowed(request) {
        False -> plain(403, "forbidden navigation")
        True ->
          case page_grant(config, ui, request, key, id) {
            Error(response) -> response
            Ok(_) -> document(200, "text/html; charset=utf-8", page.shell(id))
          }
      }

    // A ticket presented against another session's path is spent without a
    // UI session. A redeemed one adds a page and leaves the principal's
    // others open (the oldest ends only at `ui_sessions.max_pages`), and
    // hands this tab the new page's key, in the cookie's path, and its
    // nonce, in the body, never in a redirect.
    ui_http.Exchange(id, ticket) ->
      case ui_http.exchange_allowed(request) {
        False -> plain(403, "forbidden exchange")
        True ->
          case ui_sessions.redeem(ui.sessions, ticket, id) {
            Error(ui_sessions.UnknownTicket) ->
              refused_page(401, ending.LinkExpired, id)
            Error(ui_sessions.OtherSession) ->
              plain(403, "ticket names another session")
            Ok(redeemed) ->
              document(
                200,
                "text/html; charset=utf-8",
                page.enter(page.session_path(redeemed.key, id), redeemed.nonce),
              )
              |> response.set_header(
                "set-cookie",
                ui_http.set_cookie(redeemed.cookie, redeemed.key),
              )
          }
      }
  }
}

// The cookie's UI session, re-authorized from scratch: it must be live, be
// the one the path's page key names, name this session, and its minting
// credential must still authenticate and still be a member. The answer
// carries the readiness the socket's upgrade reuses, the UI session, and the
// cookie, which the socket keeps checking.
//
// A browser sends every `loom_ui` cookie whose path covers the request, and
// a longer path sorts first, so a server on another loopback port that knows
// the key could plant one that shadows the real cookie. Every value is
// therefore tried, and the one whose UI session is live under this key wins;
// a planted value names no UI session and is passed over.
fn page_grant(
  config: Config(instance),
  ui: Ui(instance),
  request,
  key: String,
  id: String,
) {
  use #(cookie, page) <- result.try(
    ui_http.session_cookies(request)
    |> list.find_map(fn(cookie) {
      use page <- result.try(ui_sessions.lookup(ui.sessions, cookie))
      case ui_sessions.keyed(page, key) {
        True -> Ok(#(cookie, page))
        False -> Error(Nil)
      }
    })
    |> result.map_error(fn(_) { refused_page(401, ending.PageEnded, id) }),
  )
  let grant = ui_sessions.grant(page)
  use Nil <- result.try(case grant.session_id == id {
    True -> Ok(Nil)
    False -> Error(refused_page(403, ending.PageEnded, id))
  })
  use state <- result.try(
    ready(config, upgrade_log.Page)
    |> result.map_error(fn(_) { refused_page(503, ending.DaemonNotReady, id) }),
  )
  use _principal <- result.try(
    asked(upgrade_log.Page, "authenticate", fn() {
      manager.authenticate(state.registry, grant.credential)
    })
    |> result.map_error(fn(_) { refused_page(401, ending.AccessRevoked, id) }),
  )
  use _authority <- result.try(
    asked(upgrade_log.Page, "session_authority", fn() {
      manager.session_authority(state.registry, grant.credential, id)
    })
    |> result.map_error(fn(_) { refused_page(403, ending.AccessRevoked, id) }),
  )
  Ok(#(state, page, cookie))
}

// The answer to a page request that cannot be served: the status the check
// chose, and a document that says which ending it is and what to do, in the
// fixed words of `web_view/ending`. The page's socket is refused by the same
// checks and its browser reads only that the handshake failed, so the body
// matters to a person who reloads or opens the address; a script never
// reads it. The path's session identity is drawn only if it parses as a
// canonical identity, because it is otherwise whatever the address said and
// the advice would repeat it as a command to run.
fn refused_page(status: Int, reason: Ending, id: String) {
  let session = case ids.parse_session_id(id) {
    Ok(parsed) -> ids.session_id_to_string(parsed)
    Error(_) -> "<id>"
  }
  document(status, "text/html; charset=utf-8", page.refusal(reason, session))
}

fn document(status: Int, content_type: String, body: String) {
  response.new(status)
  |> response.set_header("content-type", content_type)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn authenticated(config: Config(instance), request, target) {
  // A root which has fenced readiness cannot create another control or session
  // attachment, even when a previously read credential remains valid.
  let route = case target {
    None -> upgrade_log.Control
    Some(_) -> upgrade_log.Session
  }
  let ready = ready(config, route)
  let identity = {
    use state <- result.try(ready)
    use digest <- result.try(credential(request))
    use principal <- result.try(
      asked(route, "authenticate", fn() {
        manager.authenticate(state.registry, digest)
      })
      |> result.replace_error("unauthorized"),
    )
    Ok(#(state, digest, principal))
  }
  case identity {
    Error(_) -> plain(401, "unauthorized or unavailable")
    Ok(#(state, digest, principal)) ->
      case target {
        None -> control_upgrade(config, request, state, digest, principal)
        Some(id) ->
          resident_upgrade(
            config,
            request,
            state,
            digest,
            id,
            MembershipRole,
            config.session_upgrade,
          )
      }
  }
}

fn credential(request) {
  use header <- result.try(
    request.get_header(request, "authorization")
    |> result.replace_error("unauthorized"),
  )
  use token <- result.try(string.drop_start(header, 7) |> nonempty)
  case
    string.starts_with(header, "Bearer ") && string.byte_size(header) <= 4096
  {
    False -> Error("unauthorized")
    True ->
      token
      |> bit_array.from_string
      |> bootstrap.sha256
      |> bit_array.base16_encode
      |> string.lowercase
      |> access.credential_digest
      |> result.replace_error("unauthorized")
  }
}

fn nonempty(value) {
  case value {
    "" -> Error("unauthorized")
    _ -> Ok(value)
  }
}

// Resolves one resident session for an authenticated upgrade and hands the
// attachment to `upgrade`. A terminal socket carries the principal's
// membership role; the web view's socket carries that role capped by the
// page's ceiling and by Operator, and is admitted with that role's parser
// permit.
fn resident_upgrade(
  config: Config(instance),
  request,
  state: root.Ready(instance),
  digest,
  id,
  role: Role,
  upgrade: fn(Request(mist.Connection), Attachment(instance)) ->
    Response(mist.ResponseData),
) {
  let route = case role {
    MembershipRole -> upgrade_log.Session
    PageRole(..) -> upgrade_log.Page
  }

  // Resolve metadata first, then compare the observed incarnation in one actor
  // turn. A stop/reopen between those calls must refuse this upgrade.
  let target = {
    use _ <- result.try(
      ids.parse_session_id(id) |> result.replace_error(manager.Unavailable),
    )
    use #(principal, authority) <- result.try(
      asked(route, "session_authority", fn() {
        manager.session_authority(state.registry, digest, id)
      }),
    )
    use view <- result.try(
      asked(route, "get", fn() { manager.get(state.registry, id) }),
    )
    use incarnation <- result.try(resident(route, view.status))
    use instance <- result.try(
      asked(route, "resolve_incarnation", fn() {
        manager.resolve_incarnation(state.registry, id, incarnation)
      }),
    )
    Ok(#(principal, authority, incarnation, instance, view.registration))
  }
  case target {
    Error(_) -> plain(409, "session unavailable")
    Ok(#(principal, membership, incarnation, instance, registration)) -> {
      let authority = case role {
        MembershipRole -> membership
        PageRole(ceiling:) -> ui_relay.capped(membership, ceiling)
      }
      let class = case authority {
        access.Participant(access.Observer) -> root.Observer
        access.Owner | access.Participant(access.Operator) -> root.Operator
      }
      case
        upgrade_log.timed(route, "acquire", fn() {
          root.acquire(config.daemon, class, within: 1000)
        })
      {
        Error(reason) -> {
          upgrade_log.refused(route, "acquire", reason)
          plain(503, reason)
        }
        Ok(permit) -> {
          let #(connection_id, _) = ids.mint_op(config.generator())
          let response =
            upgrade(
              request,
              Attachment(
                instance:,
                session_id: id,
                incarnation:,
                connection_id: ids.op_id_to_string(connection_id),
                epoch: state.epoch,
                principal:,
                authority:,
                digest:,
                permit:,
                registry: state.registry,
                registration:,
              ),
            )
          root.release(config.daemon, permit)
          response
        }
      }
    }
  }
}

// A session that is not resident answers 409, which a browser reports as a
// bare failed socket. The status is what says why, and a page whose session
// was stopped stays refused until something opens it again.
fn resident(route: upgrade_log.Route, status) {
  let refusal = case status {
    manager.Resident(incarnation) -> Ok(incarnation)
    manager.Reserved -> Error("session is reserved")
    manager.Saved -> Error("session is saved, not open")
    manager.Opening(_) -> Error("session is opening")
    manager.Stopping(_) -> Error("session is stopping")
    manager.RecoveryBlocked(_) -> Error("session recovery is blocked")
  }
  case refusal {
    Ok(incarnation) -> Ok(incarnation)
    Error(reason) -> {
      upgrade_log.refused(route, "resident", reason)
      Error(manager.Unavailable)
    }
  }
}

// The root's readiness, timed and, when the daemon is the one refusing,
// written down. Every refusal here is the daemon's own: a root that is
// starting, stopping, fenced or slow to answer.
fn ready(config: Config(instance), route: upgrade_log.Route) {
  upgrade_log.timed(route, "ready", fn() {
    root.ready(config.daemon, within: 1000)
  })
  |> result.map_error(fn(reason) {
    upgrade_log.refused(route, "ready", reason)
    reason
  })
}

// One registry question, timed and, when the registry could not answer it,
// written down. A credential or membership the catalogue does not hold is the
// caller's and is passed through unrecorded.
fn asked(
  route: upgrade_log.Route,
  step: String,
  question: fn() -> Result(answer, manager.Error),
) -> Result(answer, manager.Error) {
  let answer = upgrade_log.timed(route, step, question)
  case answer {
    Ok(_) -> Nil
    Error(error) ->
      case registry_refusal(error) {
        Some(reason) -> upgrade_log.refused(route, step, reason)
        None -> Nil
      }
  }
  answer
}

fn registry_refusal(error: manager.Error) -> Option(String) {
  case error {
    manager.Catalogue(catalogue.Missing) -> None
    manager.Catalogue(_) -> Some("catalogue failed")
    manager.Unavailable -> Some("registry did not answer or is stopping")
    manager.NotInitialized -> Some("session is not initialized")
    manager.SessionArchived -> Some("session is archived")
    manager.Capacity -> Some("registry is at capacity")
    manager.StaleOperation -> Some("operation was overtaken")
    manager.StartFailed(_) -> Some("session start failed")
    manager.Preparation(_) -> Some("session preparation failed")
  }
}

fn control_upgrade(
  config: Config(instance),
  request,
  state: root.Ready(instance),
  digest,
  principal: access.Principal,
) {
  // The daemon's own build identity, read once per upgrade. It is a
  // process-wide fact that cannot change while the listener serves, so
  // there is nothing to re-read, and reading it here rather than per frame
  // keeps the hello's shape built from one value.
  let hello_identity = build_identity.current()
  case root.acquire(config.daemon, root.Control, within: 1000) {
    Error(reason) -> plain(503, reason)
    Ok(permit) -> {
      // The barrier that keeps the permit's custody transfer ordered against
      // the release below. This process owns it; the websocket process signals
      // it once the transfer has been attempted.
      let settled = process.new_subject()
      let response =
        mist.websocket_with_options(
          request:,
          options: mist.WebsocketOptions(
            protocol.max_bytes,
            protocol.max_bytes,
            mist.CompressionDisabled,
          ),
          on_init: fn(_) {
            let signals = process.new_subject()

            // The permit transfer is a one second call into the root, and mist
            // allows this initializer 500 ms it does not expose, killing the
            // process and its socket when that budget is missed. So the call
            // is paid for in the first handler turn, and this self-send is
            // what makes that turn the transfer's: mist arms the socket only
            // after the initializer returns (`mist.websocket_upgrade`), so
            // `Admit` is queued ahead of any frame the peer sends.
            process.send(signals, Admit)
            #(Nil, Some(process.new_selector() |> process.select(signals)))
          },
          handler: fn(_, message, socket) {
            case message {
              mist.Custom(Admit) ->
                admit(config.daemon, upgrade_log.Control, permit, settled, fn() {
                  send(
                    socket,
                    protocol.event(
                      None,
                      "hello",
                      json.Object([
                        #("protocol", json.Int(2)),
                        #("epoch", json.String(state.epoch)),
                        #("principal", json.String(principal.id)),
                        // The build this daemon is (issue #392). A client
                        // compares it against its own and reports a
                        // mismatch instead of attaching silently to a
                        // daemon a newer client cannot speak to.
                        #("build_version", json.String(hello_identity.version)),
                        #("build_commit", json.String(hello_identity.commit)),
                        #(
                          "limits",
                          json.Object([
                            #("control_bytes", json.Int(protocol.max_bytes)),
                            #(
                              "observer_bytes",
                              json.Int(root.message_limit(root.Observer)),
                            ),
                            #(
                              "operator_bytes",
                              json.Int(root.message_limit(root.Operator)),
                            ),
                            #(
                              "connections",
                              json.Int(
                                root.connection_limits(config.daemon).connections,
                              ),
                            ),
                            #(
                              "reserved_message_bytes",
                              json.Int(
                                root.connection_limits(config.daemon).reserved_message_bytes,
                              ),
                            ),
                          ]),
                        ),
                        ..hello_view(config)
                      ]),
                    ),
                  )
                })
              mist.Text(frame) -> {
                let #(reply, after) = control(config, state, digest, frame)
                let next = send(socket, reply)

                // Write the acknowledgement before root drain terminates sockets.
                case after {
                  KeepServing -> Nil
                  DrainDaemon -> root.request_shutdown(config.daemon)
                }
                next
              }
              mist.Binary(_) | mist.Closed | mist.Shutdown -> mist.stop()
            }
          },
          on_close: fn(_) { Nil },
        )

      // Hold this HTTP process until the websocket process has attempted the
      // transfer. The release below and this process's own exit would each
      // race a transfer still in flight, and a release that won would leave an
      // admitted socket refused with its accounting already freed. The reply
      // is consumed from the single process that sends it, so it orders the
      // two rather than assuming anything about two senders. On a transfer the
      // root answers promptly this waits exactly as long as the initializer
      // used to; what it no longer does is give up at 500 ms.
      case response.body {
        mist.Websocket -> {
          let _ = process.receive(settled, within: 5000)
          Nil
        }

        // No websocket process was started, so nothing will ever signal; mist
        // answers a failed start with an empty 400.
        mist.Bytes(_) | mist.Chunked | mist.File(..) | mist.ServerSentEvents ->
          Nil
      }
      root.release(config.daemon, permit)
      response
    }
  }
}

// The `hello` names the web view only when the daemon serves it, so a
// client can tell a daemon started with `--ui` from one that was not.
fn hello_view(config: Config(instance)) -> List(#(String, JsonValue)) {
  case config.ui {
    Some(_) -> [#("ui", json.Object([#("path", json.String(page.prefix))]))]
    None -> []
  }
}

/// How long a `/v2/claim` socket may stay open without its one command.
const claim_idle_ms = 2000

type ClaimSignal {
  // The permit transfer, queued by the initializer ahead of any frame, as
  // `Admit` is for the control socket.
  AdmitClaim

  // The idle bound. It is armed at the upgrade and never cancelled: the
  // socket stops after answering its one command, so a fire that arrives
  // finds either a socket still waiting for that command or no socket.
  ClaimIdle
}

// `/v2/claim` (protocol-change/053). The route redeems a claim token for the
// credential digest the invitee's client drew, and nothing else: it carries
// one command, `credentials.claim`, over one short-lived socket.
//
// The upgrade's checks run in this order. The header must be exactly
// `Bearer loomclaim_<64 hex>`; a bearer, or anything else, is 401 before the
// daemon is asked anything. The claim row must exist and not be void, also
// 401 otherwise. That lookup only filters: the command decides expiry and
// binding. Then the root admits at most one reservation per claim digest, so
// a second upgrade for the same claim is 409 while the first is open. A
// spent claim is public from then on, sitting in a chat log, and passes the
// filter; the per-digest bound and the idle close are what keep such a token
// from holding control permits open.
fn claim_route(config: Config(instance), request) {
  let admitted = {
    use presented <- result.try(claim_header(request))
    use state <- result.try(
      root.ready(config.daemon, within: 1000)
      |> result.replace_error(plain(503, "daemon unavailable")),
    )
    use Nil <- result.try(case manager.claim_known(state.registry, presented) {
      Ok(Nil) -> Ok(Nil)
      Error(manager.Catalogue(catalogue.Missing)) ->
        Error(plain(401, "unauthorized"))
      Error(_) -> Error(plain(503, "daemon unavailable"))
    })
    Ok(#(state, presented))
  }
  case admitted {
    Error(response) -> response
    Ok(#(state, presented)) ->
      case root.acquire_claim(config.daemon, presented, within: 1000) {
        Error(root.ClaimInFlight) -> plain(409, "claim already in use")
        Error(root.NotAdmitted(reason)) -> plain(503, reason)
        Ok(permit) -> claim_socket(config, request, state, presented, permit)
      }
  }
}

// The token is hashed here and never kept: from this line on the daemon holds
// only the claim's digest, as it does for bearers.
fn claim_header(
  request,
) -> Result(access.ClaimDigest, Response(mist.ResponseData)) {
  let unauthorized = plain(401, "unauthorized")
  use header <- result.try(
    request.get_header(request, "authorization")
    |> result.replace_error(unauthorized),
  )
  use token <- result.try(case string.split_once(header, "Bearer ") {
    Ok(#("", token)) -> Ok(token)
    Ok(_) | Error(Nil) -> Error(unauthorized)
  })
  use Nil <- result.try(
    claim.validate_token(token) |> result.replace_error(unauthorized),
  )
  access.claim_digest(claim.digest(token))
  |> result.replace_error(unauthorized)
}

fn claim_socket(
  config: Config(instance),
  request,
  state: root.Ready(instance),
  presented: access.ClaimDigest,
  permit: root.Permit,
) {
  // The same custody barrier as the control socket's; see `control_upgrade`.
  let settled = process.new_subject()
  let response =
    mist.websocket_with_options(
      request:,
      options: mist.WebsocketOptions(
        protocol.max_claim_bytes,
        protocol.max_claim_bytes,
        mist.CompressionDisabled,
      ),
      on_init: fn(_) {
        let signals = process.new_subject()
        process.send(signals, AdmitClaim)
        let _idle = process.send_after(signals, claim_idle_ms, ClaimIdle)
        #(Nil, Some(process.new_selector() |> process.select(signals)))
      },
      handler: fn(_, message, socket) {
        case message {
          mist.Custom(AdmitClaim) ->
            admit(config.daemon, upgrade_log.Claim, permit, settled, fn() {
              send(
                socket,
                protocol.event(
                  None,
                  "hello",
                  json.Object([#("protocol", json.Int(2))]),
                ),
              )
            })

          // One connection carries one command. The socket closes after the
          // reply is written, whatever the reply said.
          mist.Text(frame) -> {
            let _written = send(socket, claim_reply(state, presented, frame))
            mist.stop()
          }
          mist.Custom(ClaimIdle)
          | mist.Binary(_)
          | mist.Closed
          | mist.Shutdown -> mist.stop()
        }
      },
      on_close: fn(_) { Nil },
    )
  case response.body {
    mist.Websocket -> {
      let _ = process.receive(settled, within: 5000)
      Nil
    }
    mist.Bytes(_) | mist.Chunked | mist.File(..) | mist.ServerSentEvents -> Nil
  }
  root.release(config.daemon, permit)
  response
}

// Decodes the one command, redeems the claim in one serialized registry
// dispatch, and encodes the answer. Refusals carry a fixed code and message
// and never the digest the client sent.
fn claim_reply(
  state: root.Ready(instance),
  presented: access.ClaimDigest,
  frame: String,
) {
  case protocol.decode_claim(frame) {
    Error(fault) -> refusal(fault)
    Ok(protocol.ClaimRequest(id:, credential:)) ->
      case
        manager.claim(
          state.registry,
          presented,
          credential,
          now_ms: bootstrap.system_time_ms(),
        )
      {
        Ok(claimed) ->
          protocol.event(
            Some(id),
            "credentials.claim",
            claimed_json(claimed, access.fingerprint(credential)),
          )
        Error(error) ->
          refusal(protocol.Fault(
            Some(id),
            claim_error_code(error),
            "claim refused",
          ))
      }
  }
}

fn claimed_json(claimed: access.Claimed, fingerprint: String) -> JsonValue {
  json.Object([
    #("principal_id", json.String(claimed.principal.id)),
    #("name", json.String(claimed.principal.display_name)),
    #("fingerprint", json.String(fingerprint)),
    #(
      "sessions",
      json.Array(
        list.map(claimed.memberships, fn(membership) {
          json.Object([
            #("session_id", json.String(membership.session_id)),
            #("role", json.String(role_text(membership.role))),
          ])
        }),
      ),
    ),
  ])
}

fn role_text(role: access.Role) -> String {
  case role {
    access.Operator -> "operator"
    access.Observer -> "observer"
  }
}

fn claim_error_code(error: manager.ClaimError) -> String {
  case error {
    manager.ClaimRefused(access.UnknownClaim) -> "not_found"
    manager.ClaimRefused(access.ExpiredClaim) -> "expired"
    manager.ClaimRefused(access.ConflictingClaim) -> "conflict"
    manager.ClaimRefused(access.ClaimStore(_)) | manager.ClaimUnavailable ->
      "unavailable"
  }
}

// Takes the reserved permit in a socket's first handler turn and then writes
// whatever the caller had waiting. `process.self()` is still the websocket
// process here, so the permit's new owner and the PID the root monitors are
// the ones the initializer would have named.
fn admit(
  daemon,
  route: upgrade_log.Route,
  permit,
  settled: process.Subject(Nil),
  then: fn() -> mist.Next(Nil, signal),
) {
  let transferred = root.transfer(daemon, permit, within: 1000)

  // Custody is decided either way now, so the waiting HTTP process is released
  // before anything is written to the socket.
  process.send(settled, Nil)
  case transferred {
    // A failed transfer must not leave an unaccounted active socket actor. A
    // stop from a handler turn is terminal, and the root keeps its charge
    // until the DOWN, so the refusal frees nothing here.
    Error(reason) -> {
      upgrade_log.closed_early(route, "transfer", reason)
      mist.stop()
    }
    Ok(Nil) -> then()
  }
}

fn send(socket, frame) {
  case frame {
    Error(_) -> mist.stop()
    Ok(text) ->
      case mist.send_text_frame(socket, text) {
        Ok(Nil) -> mist.continue(Nil)
        Error(_) -> mist.stop()
      }
  }
}

fn control(
  config: Config(instance),
  state: root.Ready(instance),
  digest,
  frame,
) {
  case protocol.decode(frame) {
    Error(fault) -> #(refusal(fault), KeepServing)
    Ok(request) -> {
      let outcome = {
        // Socket authentication is not a cached grant. Credential revocation
        // takes effect on the next request without waiting for reconnection.
        use current <- result.try(
          root.control_state(
            config.daemon,
            control_use(request.command),
            within: 1000,
          )
          |> result.replace_error(#("unavailable", "request refused")),
        )
        use principal <- result.try(
          manager.authenticate(current.registry, digest)
          |> result.replace_error(#("unauthorized", "request refused")),
        )
        dispatch(config, state, digest, principal, request.id, request.command)
      }
      case outcome {
        Ok(#(event, body)) -> {
          // Which commands drain the daemon after their acknowledgement is
          // written, enumerated for the reason `control_use` beside it is: a
          // second shutdown-shaped command must arrive with a compiler prompt
          // rather than inheriting "keep serving" from a catch-all.
          let after = case request.command {
            protocol.Shutdown(_) -> DrainDaemon
            protocol.InspectPeers(..)
            | protocol.LinkPeers(..)
            | protocol.UnlinkPeers(..)
            | protocol.SendPeer(..)
            | protocol.Status
            | protocol.ListPrincipals(_)
            | protocol.PrincipalMemberships(..)
            | protocol.UiLink(..)
            | protocol.ListSessions(..)
            | protocol.SessionActivity(..)
            | protocol.ListArchivedSessions(..)
            | protocol.ArchiveSession(..)
            | protocol.RestoreSession(..)
            | protocol.GetSession(_)
            | protocol.WorkspaceDefault(_)
            | protocol.GetOperation(..)
            | protocol.SetDefault(..)
            | protocol.RenameSession(..)
            | protocol.IsolateSession(..)
            | protocol.Invite(..)
            | protocol.SetRole(..)
            | protocol.RevokeMembership(..)
            | protocol.RotateCredential(..)
            | protocol.RevokeCredentials(..)
            | protocol.CreateSession(..)
            | protocol.OpenSession(..)
            | protocol.StopSession(..)
            | protocol.DeleteSession(..) -> KeepServing
          }
          #(protocol.event(Some(request.id), event, body), after)
        }
        Error(#(code, message)) -> #(
          refusal(protocol.Fault(Some(request.id), code, message)),
          KeepServing,
        )
      }
    }
  }
}

// Existing sockets may inspect cleanup while the root refuses new attachment.
// Every mutation still requires accepting admission, including durable defaults.
fn control_use(command: protocol.Command) {
  case command {
    protocol.Status
    | protocol.ListPrincipals(_)
    | protocol.PrincipalMemberships(..)
    | protocol.UiLink(..)
    | protocol.InspectPeers(..)
    | protocol.ListSessions(..)
    | protocol.SessionActivity(..)
    | protocol.ListArchivedSessions(..)
    | protocol.GetSession(_)
    | protocol.WorkspaceDefault(_)
    | protocol.GetOperation(..) -> root.ControlRead
    protocol.LinkPeers(..)
    | protocol.UnlinkPeers(..)
    | protocol.SendPeer(..)
    | protocol.SetDefault(..)
    | protocol.ArchiveSession(..)
    | protocol.RestoreSession(..)
    | protocol.RenameSession(..)
    | protocol.IsolateSession(..)
    | protocol.Invite(..)
    | protocol.SetRole(..)
    | protocol.RevokeMembership(..)
    | protocol.RotateCredential(..)
    | protocol.RevokeCredentials(..)
    | protocol.CreateSession(..)
    | protocol.OpenSession(..)
    | protocol.StopSession(..)
    | protocol.DeleteSession(..)
    | protocol.Shutdown(_) -> root.ControlMutation
  }
}

fn refusal(fault: protocol.Fault) {
  protocol.event(
    fault.reply_to,
    "error",
    json.Object([
      #("code", json.String(fault.code)),
      #("message", json.String(fault.message)),
    ]),
  )
}

fn owner(principal: access.Principal) {
  case principal.kind {
    access.OwnerPrincipal -> Ok(Nil)
    access.MemberPrincipal -> Error("forbidden")
  }
}

fn epoch(state: root.Ready(instance), supplied) {
  case supplied == state.epoch {
    True -> Ok(Nil)
    False -> Error("stale_epoch")
  }
}

fn authorized(state: root.Ready(instance), digest, id) {
  manager.session_authority(state.registry, digest, id)
  |> result.map_error(error_code)
}

// Startup diagnostics follow the same epoch and membership checks as every
// operation read. Other control refusals retain their fixed public wording.
fn dispatch(
  config: Config(instance),
  state: root.Ready(instance),
  digest: access.Digest,
  principal: access.Principal,
  reply_to: Int,
  command: protocol.Command,
) -> Result(#(String, JsonValue), #(String, String)) {
  case command {
    protocol.GetOperation(id, operation, supplied) -> {
      use Nil <- result.try(
        epoch(state, supplied) |> result.map_error(control_refusal),
      )
      use _ <- result.try(
        authorized(state, digest, id) |> result.map_error(control_refusal),
      )
      manager.operation(state.registry, id, operation)
      |> result.map_error(fn(error) {
        case error {
          manager.StartFailed(reason) -> #("start_failed", reason)
          other -> control_refusal(error_code(other))
        }
      })
      |> result.map(fn(view) { #("operations.get", view_json(view)) })
    }
    _ ->
      dispatch_class(config, state, digest, principal, reply_to, command)
      |> result.map_error(control_refusal)
  }
}

fn control_refusal(code: String) -> #(String, String) {
  #(code, "request refused")
}

fn dispatch_class(
  config: Config(instance),
  state: root.Ready(instance),
  digest,
  principal,
  reply_to: Int,
  command,
) {
  // Owner-only filesystem choices are canonicalized on the host. Participant
  // authority is narrower: an operator may open a granted identity, but cannot
  // choose another workspace, configuration, or durable default.
  case command {
    protocol.InspectPeers(source, strand, after, supplied) -> {
      use Nil <- result.try(owner(principal))
      use Nil <- result.try(epoch(state, supplied))
      use endpoint <- result.try(peer_endpoint(config, state.registry, source))
      use metadata <- result.try(
        manager.get(state.registry, source)
        |> result.map(view_json)
        |> result.map_error(error_code),
      )
      let registry = state.registry
      let directory =
        peers.Directory(
          resolve: fn(id) { peer_endpoint(config, registry, id) },
          describe: fn(id) {
            manager.get(registry, id)
            |> result.map(view_json)
            |> result.map_error(error_code)
          },
        )
      use empty_frame <- result.try(
        protocol.event(Some(reply_to), "peers.inspect", json.Null)
        |> result.map_error(fn(_) { "invalid inspection frame" }),
      )
      let body_budget = 60_000 - string.byte_size(empty_frame) + 4
      peers.inspect(
        peers.Wiring(endpoint, metadata, Some(directory)),
        strand,
        after,
        body_budget,
      )
      |> result.map(fn(value) { #("peers.inspect", value) })
    }
    protocol.LinkPeers(source, from, target, to, wake, supplied) -> {
      use Nil <- result.try(owner(principal))
      use Nil <- result.try(epoch(state, supplied))
      use source <- result.try(peer_endpoint(config, state.registry, source))
      use target <- result.try(peer_endpoint(config, state.registry, target))
      peers.link(source, target, from, to, wake)
      |> result.map(fn(value) { #("peers.link", value) })
    }
    protocol.SendPeer(source, from, target, to, id, text, supplied) -> {
      use Nil <- result.try(owner(principal))
      use Nil <- result.try(epoch(state, supplied))
      use source <- result.try(peer_endpoint(config, state.registry, source))
      let registry = state.registry
      let directory =
        peers.Directory(
          resolve: fn(id) { peer_endpoint(config, registry, id) },
          describe: fn(id) {
            manager.get(registry, id)
            |> result.map(view_json)
            |> result.map_error(error_code)
          },
        )
      peers.send(
        peers.Wiring(source, json.Null, Some(directory)),
        from,
        target,
        to,
        id,
        text,
      )
      |> result.map(fn(value) { #("peers.send", value) })
    }
    protocol.UnlinkPeers(source, from, target, to, supplied) -> {
      use Nil <- result.try(owner(principal))
      use Nil <- result.try(epoch(state, supplied))
      use source <- result.try(peer_endpoint(config, state.registry, source))
      let answer = case peer_endpoint(config, state.registry, target) {
        Ok(endpoint) -> peers.unlink(source, endpoint, from, to)
        Error(_) ->
          source.call(peer_mail.Unlink(from, target, to))
          |> result.replace(
            json.Object([
              #("outgoing_link_removed", json.Bool(True)),
              #(
                "recipient_grant",
                json.String("unavailable; no outgoing authority remains"),
              ),
            ]),
          )
      }
      answer |> result.map(fn(value) { #("peers.unlink", value) })
    }
    protocol.RenameSession(id, name, supplied) -> {
      manager.rename(state.registry, digest, supplied, id, name)
      |> result.map_error(admin_error_code)
      |> result.map(fn(view) { #("sessions.rename", view_json(view)) })
    }
    protocol.ArchiveSession(id, supplied) -> {
      manager.set_visibility(
        state.registry,
        digest,
        supplied,
        id,
        catalogue.Archived,
      )
      |> result.map_error(admin_error_code)
      |> result.map(fn(view) { #("sessions.archive", view_json(view)) })
    }
    protocol.RestoreSession(id, supplied) -> {
      manager.set_visibility(
        state.registry,
        digest,
        supplied,
        id,
        catalogue.Active,
      )
      |> result.map_error(admin_error_code)
      |> result.map(fn(view) { #("sessions.restore", view_json(view)) })
    }
    protocol.ListArchivedSessions(after, revision) -> {
      use #(current, views) <- result.try(
        manager.archived_page(state.registry, digest, after:)
        |> result.map_error(admin_error_code),
      )
      use Nil <- result.try(check_revision(revision, current))
      use bounded <- result.try(page_prefix(views, 60_000, []))
      Ok(#("sessions.archived", page_body(bounded, current)))
    }
    protocol.IsolateSession(id, supplied) -> {
      use selected <- result.try(
        manager.isolate(state.registry, digest, supplied, id, state.state_root)
        |> result.map_error(admin_error_code),
      )
      Ok(#(
        "sessions.isolate",
        json.Object([
          #("session_id", json.String(id)),
          #("domain_scope", json.String(scope_text(selected.scope))),
        ]),
      ))
    }
    protocol.Invite(session_id, id, name, role, requested, supplied) -> {
      use Nil <- result.try(owner(principal))
      use #(enrollment, issued) <- result.try(enrollment(requested))
      admin_result(
        state,
        digest,
        supplied,
        manager.Invite(id, name, enrollment, session_id, role),
        "sessions.invite",
        issued,
      )
    }
    protocol.RotateCredential(id, requested, supplied) -> {
      use Nil <- result.try(owner(principal))
      use #(enrollment, issued) <- result.try(enrollment(requested))
      admin_result(
        state,
        digest,
        supplied,
        manager.RotateMember(id, enrollment),
        "credentials.rotate",
        issued,
      )
    }
    protocol.SetRole(session_id, id, role, supplied) ->
      admin_result(
        state,
        digest,
        supplied,
        manager.SetRole(id, session_id, role),
        "sessions.set_role",
        None,
      )
    protocol.RevokeMembership(session_id, id, supplied) ->
      admin_result(
        state,
        digest,
        supplied,
        manager.RevokeMembership(id, session_id),
        "sessions.revoke",
        None,
      )
    protocol.RevokeCredentials(id, supplied) ->
      admin_result(
        state,
        digest,
        supplied,
        manager.RevokeMember(id),
        "credentials.revoke",
        None,
      )
    protocol.ListPrincipals(after) -> {
      use Nil <- result.try(owner(principal))
      use page <- result.try(
        manager.principal_page(
          state.registry,
          digest,
          after:,
          now_ms: bootstrap.system_time_ms(),
        )
        |> result.map_error(admin_error_code),
      )
      let rows =
        list.map(page.entries, fn(row) {
          #(row.principal.id, listing_json(row))
        })
      use #(bounded, more) <- result.try(bounded_rows(rows, page.remainder))
      Ok(#(
        "principals.list",
        json.Object(list.append(
          [#("principals", json.Array(list.map(bounded, pair.second)))],
          next_field(bounded, more),
        )),
      ))
    }
    protocol.PrincipalMemberships(id, after) -> {
      use Nil <- result.try(owner(principal))
      use page <- result.try(
        manager.membership_page(state.registry, digest, id, after:)
        |> result.map_error(admin_error_code),
      )
      let rows =
        list.map(page.entries, fn(row) {
          #(row.session_id, membership_json(row))
        })
      use #(bounded, more) <- result.try(bounded_rows(rows, page.remainder))
      Ok(#(
        "principals.memberships",
        json.Object(list.append(
          [
            #("principal_id", json.String(id)),
            #("memberships", json.Array(list.map(bounded, pair.second))),
          ],
          next_field(bounded, more),
        )),
      ))
    }
    protocol.Status -> {
      use summary <- result.try(
        manager.summary(state.registry) |> result.map_error(error_code),
      )
      Ok(#(
        "status",
        json.Object([
          #("ready", json.Bool(summary.admission == manager.Accepting)),
          #("epoch", json.String(state.epoch)),
          #("capacity", json.Int(summary.capacity)),
          #("occupied", json.Int(summary.occupied)),
          #("opening", json.Int(summary.opening)),
          #("resident", json.Int(summary.resident)),
          #("stopping", json.Int(summary.stopping)),
          #("blocked", json.Int(summary.blocked)),
          #("domain_capacity", json.Int(summary.domain_capacity)),
          #("domain_occupied", json.Int(summary.domain_occupied)),
          #("domain_blocked", json.Int(summary.domain_blocked)),
        ]),
      ))
    }

    // A ticket for this principal's browser to open one session's page. It
    // is minted only for a member of that session, and records the digest of
    // the credential asking, so every later check of the page re-checks it.
    protocol.UiLink(id, page: ceiling) -> {
      use ui <- result.try(option.to_result(config.ui, "unavailable"))
      use _ <- result.try(authorized(state, digest, id))
      use issued <- result.try(
        ui_sessions.mint(
          ui.sessions,
          ui_sessions.Grant(
            session_id: id,
            credential: digest,
            principal: principal.id,
            ceiling:,
          ),
        )
        |> result.replace_error("unavailable"),
      )
      Ok(#(
        "ui.link",
        json.Object([
          #("path", json.String(page.exchange_path(id, issued.ticket))),
          #("expires_in_ms", json.Int(issued.expires_in_ms)),
        ]),
      ))
    }
    protocol.ListSessions(after, revision) -> {
      use #(current, views) <- result.try(
        manager.authorized_page(state.registry, digest, after:)
        |> result.map_error(error_code),
      )
      use Nil <- result.try(check_revision(revision, current))
      use bounded <- result.try(page_prefix(views, 60_000, []))
      Ok(#("sessions.list", page_body(bounded, current)))
    }
    protocol.SessionActivity(sessions, supplied) -> {
      use Nil <- result.try(owner(principal))
      use Nil <- result.try(epoch(state, supplied))
      let rows = activity(config, state.registry, sessions)
      let body = json.Object([#("activity", json.Array(rows))])

      // Each row is bounded, so the reply fits by construction; the check
      // keeps that arithmetic honest if a bound above ever moves.
      use frame <- result.try(
        protocol.event(Some(reply_to), "sessions.activity", body)
        |> result.replace_error("metadata_too_large"),
      )
      case string.byte_size(frame) <= 60_000 {
        True -> Ok(#("sessions.activity", body))
        False -> Error("metadata_too_large")
      }
    }
    protocol.GetSession(id) -> {
      use _ <- result.try(authorized(state, digest, id))
      manager.get(state.registry, id)
      |> result.map_error(error_code)
      |> result.try(fn(view) {
        use body <- result.map(owner_view(state, principal, view))
        #("sessions.get", body)
      })
    }
    protocol.WorkspaceDefault(workspace) -> {
      use Nil <- result.try(owner(principal))
      manager.workspace_default(state.registry, workspace)
      |> result.map_error(error_code)
      |> result.map(fn(view) { #("sessions.default", view_json(view)) })
    }
    protocol.SetDefault(workspace, id) -> {
      use Nil <- result.try(owner(principal))
      manager.set_default(state.registry, workspace, id)
      |> result.map_error(error_code)
      |> result.map(fn(view) { #("sessions.set_default", view_json(view)) })
    }
    protocol.CreateSession(key, workspace, name, configuration, scope) -> {
      use Nil <- result.try(owner(principal))
      use workspace <- result.try(
        bootstrap.canonical_directory(workspace)
        |> result.replace_error("invalid_workspace"),
      )
      use configuration <- result.try(
        case configuration {
          // Absence is a registration choice, not the daemon's current path.
          // Canonicalizing it would replace inherited defaults with a directory.
          "" -> Ok("")
          path -> bootstrap.canonical_path(path)
        }
        |> result.replace_error("invalid_configuration"),
      )
      manager.create_scoped(
        state.registry,
        manager.Creation(key, workspace, name, configuration),
        directory: state.sessions_directory,
        generator: config.generator(),
        scope:,
        configuration: config.domain_configuration,
      )
      |> result.map_error(error_code)
      |> result.map(fn(view) { #("sessions.create", view_json(view)) })
    }
    protocol.OpenSession(id, supplied) -> {
      use Nil <- result.try(epoch(state, supplied))
      use #(_, authority) <- result.try(authorized(state, digest, id))
      use Nil <- result.try(operator(authority))
      manager.open(state.registry, id)
      |> result.map_error(error_code)
      |> result.map(fn(status) { #("sessions.open", status_json(status)) })
    }
    protocol.StopSession(id, supplied) -> {
      use Nil <- result.try(owner(principal))
      use Nil <- result.try(epoch(state, supplied))
      manager.stop_session(state.registry, id)
      |> result.map_error(error_code)
      |> result.map(fn(status) { #("sessions.stop", status_json(status)) })
    }
    protocol.DeleteSession(id, supplied) -> {
      // Owner, epoch and the busy check are all re-decided inside the
      // registry's own dispatch; the check here would only widen the window
      // between deciding and removing.
      use registration <- result.try(
        manager.delete_session(
          state.registry,
          digest,
          supplied,
          id,
          state.sessions_directory,
        )
        |> result.map_error(admin_error_code),
      )
      Ok(#(
        "sessions.delete",
        json.Object([
          #("session_id", json.String(registration.id)),
          #("workspace", json.String(registration.workspace)),
          #("name", json.String(registration.name)),
        ]),
      ))
    }
    protocol.GetOperation(id, operation, supplied) -> {
      use Nil <- result.try(epoch(state, supplied))
      use _ <- result.try(authorized(state, digest, id))
      manager.operation(state.registry, id, operation)
      |> result.map_error(error_code)
      |> result.map(fn(view) { #("operations.get", view_json(view)) })
    }
    protocol.Shutdown(supplied) -> {
      use Nil <- result.try(owner(principal))
      use Nil <- result.try(epoch(state, supplied))
      Ok(#(
        "daemon.shutdown",
        json.Object([#("state", json.String("draining"))]),
      ))
    }
  }
}

fn operator(authority) {
  case authority {
    access.Owner | access.Participant(access.Operator) -> Ok(Nil)
    access.Participant(access.Observer) -> Error("forbidden")
  }
}

// A claim minted for one invitation or rotation, kept only long enough to
// write it into the success reply.
type Issued {
  Issued(token: String, ttl_ms: Int)
}

// Turns the requested enrollment into what the catalogue stores. A claim is
// drawn here, from the same entropy source as every other daemon secret, and
// only its digest leaves this function for the registry; its expiry is a
// wall-clock instant so that it means the same thing after a restart.
fn enrollment(
  requested: protocol.Enrollment,
) -> Result(#(access.Enrollment, Option(Issued)), String) {
  case requested {
    protocol.EnrollDigest(credential:) ->
      Ok(#(access.DigestEnrollment(credential), None))
    protocol.IssueClaim(ttl_ms:) -> {
      let issued = claim.mint_token(token.production_entropy())
      use digest <- result.try(
        access.claim_digest(claim.digest(issued))
        |> result.replace_error("unavailable"),
      )
      let expires_at_ms = bootstrap.system_time_ms() + ttl_ms
      Ok(#(
        access.ClaimEnrollment(digest, expires_at_ms),
        Some(Issued(issued, ttl_ms)),
      ))
    }
  }
}

// Only an explicitly successful invitation or rotation returns a claim, and
// no reply returns a bearer (protocol-change/053 rule 5). Refusals use fixed
// codes and never stringify a request or durable error, so a claim minted for
// a refused mutation is dropped here and exists nowhere else.
fn admin_result(
  state: root.Ready(instance),
  digest,
  epoch,
  action,
  event,
  issued: Option(Issued),
) {
  use principal <- result.try(
    manager.administer(state.registry, digest, epoch, action)
    |> result.map_error(admin_error_code),
  )
  let fields = [
    #("principal_id", json.String(principal.id)),
    #("name", json.String(principal.display_name)),
  ]
  let fields = case issued {
    None -> fields
    Some(Issued(token:, ttl_ms:)) ->
      list.append(fields, [
        #("claim", json.String(token)),
        #("expires_in_ms", json.Int(ttl_ms)),
      ])
  }
  Ok(#(event, json.Object(fields)))
}

fn admin_error_code(error) {
  case error {
    manager.IsolationRequired -> "isolation_required"
    manager.AdminForbidden -> "forbidden"
    manager.AdminStaleEpoch -> "stale_epoch"
    manager.AdminUnavailable -> "unavailable"
    manager.AdminForeignPath -> "unavailable"
    manager.AdminBusy -> "busy"
    manager.AdminMetadata(error) -> error_code(manager.Catalogue(error))
  }
}

fn owner_view(
  state: root.Ready(instance),
  principal: access.Principal,
  view: manager.View,
) {
  case principal.kind {
    access.MemberPrincipal -> Ok(view_json(view))
    access.OwnerPrincipal -> {
      use selected <- result.try(
        manager.session_domain(state.registry, view.registration.id)
        |> result.map_error(error_code),
      )
      Ok(
        json.Object([
          #("session_id", json.String(view.registration.id)),
          #("workspace", json.String(view.registration.workspace)),
          #("name", json.String(view.registration.name)),
          #("created_at", json.Int(view.registration.created_at)),
          #("status", status_json(view.status)),
          #("domain_scope", json.String(scope_text(selected.scope))),
        ]),
      )
    }
  }
}

fn scope_text(scope) {
  case scope {
    domain.WorkspacePrivate -> "workspace_private"
    domain.SessionOnly -> "session_only"
  }
}

fn check_revision(expected, actual) {
  case expected {
    None -> Ok(Nil)
    Some(value) if value == actual -> Ok(Nil)
    Some(_) -> Error("revision_changed")
  }
}

fn page_body(views: List(manager.View), revision) {
  let continuation = case list.last(views) {
    Ok(view) -> json.String(view.registration.id)
    Error(Nil) -> json.Null
  }
  json.Object([
    #("revision", json.Int(revision)),
    #("sessions", json.Array(list.map(views, view_json))),
    #("after", continuation),
  ])
}

// Stop on an authorized record boundary; the next request resumes after the
// final emitted ID. The reserve covers envelope, revision, and continuation.
fn page_prefix(views: List(manager.View), remaining: Int, accumulated) {
  case views {
    [] -> Ok(list.reverse(accumulated))
    [view, ..rest] -> {
      let bytes = view_json(view) |> json.to_string |> string.byte_size
      case bytes <= remaining, accumulated {
        True, _ ->
          page_prefix(rest, remaining - bytes - 1, [view, ..accumulated])
        False, [] -> Error("metadata_too_large")
        False, [_, ..] -> Ok(list.reverse(accumulated))
      }
    }
  }
}

// Keeps the longest prefix of the listing rows that fits the 60,000-byte
// page budget, always ending on a whole row so the next request can resume
// after the last row emitted. A row cut off by the budget makes the page
// incomplete exactly as a row cut off by the storage limit does. A first row
// that alone exceeds the budget is refused rather than skipped, as in
// `page_prefix`; principal and session rows are far smaller than the budget,
// so that refusal is unreachable with the bounds the catalogue enforces.
fn bounded_rows(
  rows: List(#(String, JsonValue)),
  remainder: access.Remainder,
) -> Result(#(List(#(String, JsonValue)), access.Remainder), String) {
  bounded_rows_loop(rows, 60_000, [], remainder)
}

fn bounded_rows_loop(rows, remaining, accumulated, remainder) {
  case rows {
    [] -> Ok(#(list.reverse(accumulated), remainder))
    [#(_, value) as row, ..rest] -> {
      let bytes = json.to_string(value) |> string.byte_size
      case bytes <= remaining, accumulated {
        True, _ ->
          bounded_rows_loop(
            rest,
            remaining - bytes - 1,
            [row, ..accumulated],
            remainder,
          )
        False, [] -> Error("metadata_too_large")
        False, [_, ..] -> Ok(#(list.reverse(accumulated), access.Remaining))
      }
    }
  }
}

// `next` appears only when another page follows, and names the last row of
// this one.
fn next_field(rows: List(#(String, JsonValue)), remainder: access.Remainder) {
  case remainder, list.last(rows) {
    access.Remaining, Ok(#(id, _)) -> [#("next", json.String(id))]
    access.Remaining, Error(Nil) | access.Exhausted, _ -> []
  }
}

// One principal as the owner's listing shows it. The credential is a fingerprint
// and a lifetime, never a bearer or a claim: neither is stored in a form this
// function could read.
fn listing_json(row: access.Listing) -> JsonValue {
  let kind = case row.principal.kind {
    access.OwnerPrincipal -> "owner"
    access.MemberPrincipal -> "member"
  }
  json.Object([
    #("principal_id", json.String(row.principal.id)),
    #("name", json.String(row.principal.display_name)),
    #("kind", json.String(kind)),
    #("credential", credential_json(row.credential)),
  ])
}

fn credential_json(summary: access.CredentialSummary) -> JsonValue {
  case summary {
    access.CredentialActive(fingerprint:, claimed_at_ms: None) ->
      json.Object([
        #("state", json.String("active")),
        #("fingerprint", json.String(fingerprint)),
      ])
    access.CredentialActive(fingerprint:, claimed_at_ms: Some(claimed)) ->
      json.Object([
        #("state", json.String("active")),
        #("fingerprint", json.String(fingerprint)),
        #("claimed_at_ms", json.Int(claimed)),
      ])
    access.CredentialClaimOpen(expires_in_ms:) ->
      json.Object([
        #("state", json.String("claim_open")),
        #("expires_in_ms", json.Int(expires_in_ms)),
      ])
    access.CredentialClaimExpired ->
      json.Object([#("state", json.String("claim_expired"))])
    access.CredentialNone -> json.Object([#("state", json.String("none"))])
  }
}

fn membership_json(row: access.MembershipEntry) -> JsonValue {
  let role = case row.role {
    access.Operator -> "operator"
    access.Observer -> "observer"
  }
  json.Object([
    #("session_id", json.String(row.session_id)),
    #("name", json.String(row.name)),
    #("role", json.String(role)),
  ])
}

pub fn view_json(view: manager.View) -> JsonValue {
  json.Object([
    #("session_id", json.String(view.registration.id)),
    #("workspace", json.String(view.registration.workspace)),
    #("name", json.String(view.registration.name)),
    #("created_at", json.Int(view.registration.created_at)),
    #("status", status_json(view.status)),
  ])
}

fn status_json(status) {
  case status {
    // Distinct from `saved` because the two differ in what a client may do
    // with the row: a reservation has no database and only a create retry
    // under its original request key can finish it.
    manager.Reserved -> json.Object([#("state", json.String("reserved"))])

    manager.Saved -> json.Object([#("state", json.String("saved"))])
    manager.Opening(operation) ->
      json.Object([
        #("state", json.String("opening")),
        #("operation", json.String(operation)),
      ])
    manager.Resident(incarnation) ->
      json.Object([
        #("state", json.String("resident")),
        #("incarnation", json.String(incarnation)),
      ])
    manager.Stopping(operation) ->
      json.Object([
        #("state", json.String("stopping")),
        #("operation", json.String(operation)),
      ])
    manager.RecoveryBlocked(_) ->
      json.Object([#("state", json.String("recovery_blocked"))])
  }
}

fn error_code(error) {
  case error {
    manager.StaleOperation -> "stale_operation"
    manager.StartFailed(..) -> "start_failed"
    manager.Capacity -> "capacity"
    manager.SessionArchived -> "session_archived"
    manager.NotInitialized -> "not_initialized"
    manager.Unavailable | manager.Preparation(_) -> "unavailable"
    manager.Catalogue(catalogue.Missing) -> "not_found"
    manager.Catalogue(catalogue.Conflict) -> "conflict"
    manager.Catalogue(catalogue.Invalid(_)) -> "bad_request"
    manager.Catalogue(catalogue.Unsupported)
    | manager.Catalogue(catalogue.Database(_)) -> "unavailable"
  }
}

fn plain(status, text) {
  response.new(status)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(text)))
}

/// How long `sessions.activity` waits for the slowest resident to answer.
const activity_deadline_ms = 2000

/// The encoded size of one `sessions.activity` row, identity included. The
/// resident bounds its own part to `peer_mail.overview_row_bytes`; this is
/// that bound plus room for the session identity, and 24 rows of this size
/// fit the 60,000-byte reply.
const activity_row_bytes = 2400

// One row per resident identity, in request order. Resolution goes through
// the registry, which answers only for running slots, so a saved session is
// never opened and its database is never read: it is simply left out, which
// is what "inactive" means to the client.
//
// The residents are then asked concurrently, from this control socket's
// process and not the registry's, so a slow Agency holds up neither the
// registry nor the other residents. The run's deadline kills and joins any
// worker still waiting, and every outcome other than an answer becomes an
// `unknown` row rather than a failed reply.
fn activity(
  config: Config(instance),
  registry: manager.Manager(instance),
  sessions: List(String),
) -> List(JsonValue) {
  let residents =
    list.filter_map(sessions, fn(id) {
      manager.resolve(registry, id)
      |> result.map(fn(resident) { #(id, config.peer_endpoint(resident)) })
    })

  // A resident without a peer service is still resident, so it is reported
  // as unknown rather than left out as if it were saved.
  let outcomes =
    residents
    |> list.map(fn(pair) {
      case pair.1 {
        Some(peer_mail.Endpoint(call:, ..)) -> fn() { call(peer_mail.Overview) }
        None -> fn() { Error("peer_service_unavailable") }
      }
    })
    |> weft.new
    |> weft.deadline(activity_deadline_ms)
    |> weft.start
  list.map2(residents, outcomes, fn(pair, outcome) {
    let #(id, _) = pair
    case outcome {
      weft.Completed(value: json.Object(fields), ..) ->
        bounded_row(json.Object([#("session_id", json.String(id)), ..fields]))
        |> result.lazy_unwrap(fn() { unknown_row(id) })
      weft.Completed(..)
      | weft.Failed(..)
      | weft.Crashed(..)
      | weft.Abandoned(..)
      | weft.NeverStarted(..)
      | weft.DrainProofLost(..)
      | weft.CancellationUnconfirmed(..) -> unknown_row(id)
    }
  })
}

fn bounded_row(row: JsonValue) -> Result(JsonValue, Nil) {
  case string.byte_size(json.to_string(row)) <= activity_row_bytes {
    True -> Ok(row)
    False -> Error(Nil)
  }
}

fn unknown_row(id: String) -> JsonValue {
  json.Object([
    #("session_id", json.String(id)),
    #("state", json.String("unknown")),
  ])
}

fn peer_endpoint(
  config: Config(instance),
  registry: manager.Manager(instance),
  id: String,
) -> Result(peer_mail.Endpoint, String) {
  use resident <- result.try(
    manager.resolve(registry, id) |> result.map_error(error_code),
  )
  config.peer_endpoint(resident) |> option.to_result("peer_service_unavailable")
}
