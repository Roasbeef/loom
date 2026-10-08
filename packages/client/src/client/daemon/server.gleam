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
//// page's socket and a fixed list of assets, and a home page that is bound
//// to no session (protocol-change/065) with the same three routes under its
//// own scope (`home_grant`, `home_socket`), and the owner's admin page, a third
//// scope with its own three routes (`admin_grant`, `admin_socket`). Without it
//// every `/ui` path is a 404 and the control `hello` does not name the view, so
//// the two v2 endpoints are the whole surface, as spec Part 1.6 says.
////
//// ## Flow
////
//// `handle` → `authenticated` → `resident_upgrade` or `control_upgrade` →
//// `control` → `dispatch` → `dispatch_class`
////
//// 1. `handle` reads the path and chooses a family: the control socket, a
////    session socket, the claim socket (`claim_route`), or `/ui` through
////    `web_view` when the daemon was started with it.
//// 2. `authenticated` asks `ready` whether the root admits attachments, reads
////    the bearer with `credential`, and has the registry authenticate its
////    digest before any socket exists.
//// 3. A session path goes to `resident_upgrade`, which resolves the resident
////    session, acquires the parser permit and hands a checked `Attachment` to
////    the supplied adapter.
//// 4. A control path goes to `control_upgrade`; each frame then runs
////    `control`, which decodes it, re-checks the root with `control_use` and
////    the credential, and calls `dispatch`.
//// 5. `dispatch` answers operation reads itself and sends every other command
////    to `dispatch_class`, one arm per command; replies leave through `send`.
//// 6. A `/ui` request takes `web_socket` for the page's socket or
////    `web_document` for the page, the ticket exchange and images, each
////    re-checking cookie, grant and credential through `page_grant`. The
////    home's socket and page take `home_socket` and `home_grant` instead, and
////    the admin page's take `admin_socket` and `admin_grant`.

import broker/token
import client/daemon/manager
import client/daemon/profiles
import client/daemon/protocol
import client/daemon/root
import client/daemon/ui_assets
import client/daemon/ui_http
import client/daemon/ui_login
import client/daemon/ui_relay
import client/daemon/ui_result
import client/daemon/ui_sessions
import client/daemon/upgrade_log
import client/executors
import client/orchestrators
import client/peer_mail
import client/peers
import client/pools
import client/remote/orchestrator_port
import client/session_directory
import client/session_movers
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
import host/login
import mist
import session_view/transcript_image
import storage/access
import storage/catalogue
import storage/domain
import storage/snapshot as storage_snapshot
import web_view/ending.{type Ending}
import web_view/image
import web_view/page
import web_view/sessions as listed_sessions
import web_view/tool_result
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
    /// The `[executors.<name>]` the owner configured, read once at startup. A
    /// creation that names an executor outside this list is refused before
    /// anything is reserved (protocol-change/078).
    executors: List(executors.Executor),
    /// The `[pools.<name>]` the owner configured, read once at startup. A
    /// creation that names a pool outside this list is refused before anything
    /// is reserved (protocol-change/078).
    pools: List(pools.Pool),
    /// The other orchestrators a session this daemon does not hold may live on
    /// (protocol-change/078, phase 3). It is asked only after the daemon's own
    /// catalogue missed, and only for the owner principal.
    directory: session_directory.Directory,
    /// How an owner starts handing a session to another orchestrator, and the
    /// orchestrators it may name (protocol-change/078, phase 5).
    /// `session_movers.idle()` when there are none.
    movers: session_movers.Control,
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
    /// Reads only immutable result records from the authorized resident.
    result_reader: fn(instance) -> storage_snapshot.Reader,
    /// The page's stylesheet and scripts and Lustre's client runtime, read
    /// once when the daemon started.
    assets: ui_assets.Assets,
    /// The root key every browser login is signed under and verified from
    /// (protocol-change/065, PR 8), read or drawn when the daemon started. It
    /// is held here and nowhere else: no token, log line or reply carries it.
    root_key: login.RootKey,
    /// Upgrades a checked page request to the component's socket; like
    /// `session_upgrade`, it transfers the attachment's permit. The third
    /// argument answers the page's deadline while its UI session is still
    /// live, which the socket checks with every authorization and carries onto
    /// a ticket it mints for a switch; the fourth records how the page's images
    /// are read, under the page's cookie (`ui_sessions.register_images`); the
    /// fifth is what the daemon knows of the page that opened the socket: its
    /// ceiling, which the relay caps every authorization with, its reach, which
    /// the socket carries onto every ticket the page mints and which decides
    /// whether the page may go home, its origin and its login.
    upgrade: fn(
      Request(mist.Connection),
      Attachment(instance),
      fn() -> Result(Int, Nil),
      fn(ui_sessions.Images) -> Nil,
      PageGrant,
    ) -> Response(mist.ResponseData),
    /// Upgrades a checked home request to the home component's socket
    /// (protocol-change/065). It takes the same custody of the attachment's
    /// permit, and its third and fourth arguments are the page's deadline
    /// check and what the daemon knows of the page, as for `upgrade`.
    home: fn(
      Request(mist.Connection),
      HomeAttachment(instance),
      fn() -> Result(Int, Nil),
      PageGrant,
    ) -> Response(mist.ResponseData),
    /// Upgrades a checked admin request to the admin component's socket
    /// (protocol-change/065, the fifth pull request). It takes the same custody
    /// of the attachment's permit, and its third and fourth arguments are the
    /// page's deadline check and ceiling, as for `home`. The page has no reach:
    /// it draws no way to another page.
    admin: fn(
      Request(mist.Connection),
      AdminAttachment(instance),
      fn() -> Result(Int, Nil),
      access.Role,
    ) -> Response(mist.ResponseData),
  )
}

/// One authorized admin page, which is bound to no session and whose principal
/// is the daemon's owner. It holds what the admin socket needs to read the
/// catalogue and to ask for the owner's changes, and the daemon's own epoch,
/// which every change is fenced with.
pub type AdminAttachment(instance) {
  AdminAttachment(
    /// Current daemon lifetime identity, which the registry's dispatch checks
    /// every change against.
    epoch: String,
    /// The authenticated principal the page was opened for, whom `admin_grant`
    /// has already found to be the daemon's owner.
    principal: access.Principal,
    /// Digest for repeated authorization; never the plaintext credential.
    digest: access.Digest,
    /// Transferred to the actual WebSocket PID in that process's first
    /// handler turn, before it serves a frame.
    permit: root.Permit,
    /// The registry the page's reads and changes go to.
    registry: manager.Manager(instance),
    /// The daemon's own state directory, which an isolated session's fresh
    /// stores are minted under (`manager.isolate`). It is the daemon's value and
    /// never a page's.
    state_root: String,
    /// The browser login the page was opened from, when it was, which the page
    /// marks in the owner's own sign-ins. A page a `loom ui` exchange opened
    /// has none.
    login: Option(ui_sessions.Issuer),
  )
}

/// What the daemon knows of the page that opened a socket, which the socket
/// carries onto every ticket and every ask the page makes (protocol-change/065).
/// The daemon wrote all of it when it minted the page's ticket, and the page
/// says none of it of itself.
pub type PageGrant {
  PageGrant(
    /// What the page's UI session grants: its credential, principal, ceiling,
    /// reach and origin.
    grant: ui_sessions.Grant,
    /// The browser login the page is the browser of, when it is one: the one
    /// its exchange set, the one that resumed it, or the one the page that
    /// minted its ticket belonged to.
    login: Option(ui_sessions.Issuer),
    /// This daemon's web address as the browser reached it, `http://` and the
    /// request's loopback host, which a device link and the bookmark are drawn
    /// under. It is the validated `Host` and not anything the page said.
    address: String,
  )
}

/// One authorized home page, which is bound to no session. It holds what the
/// home's socket needs to answer the page's questions about its principal
/// and nothing about any session, because there is none to resolve.
pub type HomeAttachment(instance) {
  HomeAttachment(
    /// Current daemon lifetime identity.
    epoch: String,
    /// The authenticated principal the page was opened for.
    principal: access.Principal,
    /// Digest for repeated authorization; never the plaintext credential.
    digest: access.Digest,
    /// Transferred to the actual WebSocket PID in that process's first
    /// handler turn, before it serves a frame.
    permit: root.Permit,
    /// The registry the page's reads go to.
    registry: manager.Manager(instance),
    /// Asks the named sessions what they are doing: the `sessions.activity`
    /// read (protocol-change/050) the control socket serves the owner, made on
    /// a page for the sessions its credential holds, and reduced to one
    /// state for each session that answered (`home_activity`). It blocks for up to the read's own
    /// deadline, so the page never calls it from its runtime
    /// (`ui_socket.activity_task`).
    activity: fn(List(String)) -> List(#(String, listed_sessions.Activity)),
    /// The daemon's own sessions directory, which deleting a session removes
    /// the database family from (`manager.delete_session`). It is the daemon's
    /// value and never a page's, and only the owner's fresh home may reach it
    /// (`ui_socket.manage_for`).
    sessions_directory: String,
    /// The daemon's own state directory, which a typed folder may never be, lie
    /// in or contain (`new_folder.check_in`, protocol-change/074). It is the
    /// daemon's value and never a page's.
    state_root: String,
    /// Creates a session as the principal it is given, which is the control
    /// command's own `create_session` over this daemon's registry and sessions
    /// directory. It blocks for the registry's call, so the page never calls it
    /// from its runtime (`ui_socket.create_task`). The principal is the one the
    /// socket authenticated afresh at the press, and the function refuses all
    /// but the owner.
    create: fn(access.Principal, manager.Creation, domain.Scope) ->
      Result(manager.View, String),
    /// The model profile names the daemon's configuration defines, sorted, which
    /// the owner's new-session forms offer (protocol-change/076). It reads the
    /// configuration file, so it blocks briefly and a page's runtime never calls
    /// it: the home socket asks once when the page opens. A configuration the
    /// daemon cannot read has no names.
    profiles: fn() -> List(String),
    /// The `[executors.<name>]` names of the daemon's configuration, in the
    /// order the configuration lists them, which the owner's page offers a form
    /// for a registered workspace on (protocol-change/078). They are the
    /// daemon's startup capture (`Config.executors`) and never reread, so unlike
    /// the profiles they cost no read. A page learns them once, when it opens,
    /// and only an owner's page that holds the creation capability is told.
    executors: List(String),
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
    /// The daemon's own state directory, which making the session shareable
    /// isolates it under (`client/daemon/shareable`). It is the daemon's value
    /// and never a page's.
    state_root: String,
    /// The daemon's own sessions directory, which the sidebar's session actions
    /// pass to `ui_socket.manage_for` as the home does. Only the owner's fresh
    /// page may reach it, and only Delete, which a session page never offers,
    /// removes anything from it.
    sessions_directory: String,
    /// The session's catalogue registration, read while the route resolved
    /// the session. The web view's heading takes its name and workspace
    /// from here, so a page needs no second read of the catalogue.
    registration: catalogue.Registration,
    /// Asks the sessions what they are doing, for the page's sidebar: the same
    /// read the home makes (`home_activity`), with the page's own credential,
    /// so a member is told only about sessions they hold. It blocks for the
    /// read's deadline, so the page runs it from a task
    /// (`ui_socket.activity_task`).
    activity: fn(List(String)) -> List(#(String, listed_sessions.Activity)),
    /// The daemon's resident-only peer lookups, which an owner's page reads
    /// and changes its session's peer links through (`client/daemon/ui_peers`,
    /// protocol-change/077). They are the daemon's own and a page never
    /// supplies one.
    peers: peers.Directory,
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
        ui_http.HomeSocket(key, nonce) ->
          home_socket(config, ui, request, host, key, nonce)

        // The resume page holds the one form a login's visit posts, so it is
        // served under the policy that lets that form submit to this origin.
        // Every other document, the answer to the post included, keeps
        // `form-action 'none'`.
        ui_http.LoginPage(key) ->
          ui_http.secured_for(login_page(request, key), host, page.OwnForms)

        // The claim form is the second document that holds a form, so it is
        // served under the same policy. Its answers are secured by the handler,
        // which knows which of them draws the form again.
        ui_http.ClaimPage ->
          ui_http.secured_for(claim_page(request), host, page.OwnForms)
        ui_http.ClaimSubmit -> claim_submit(config, ui, request, host)

        ui_http.AdminSocket(key, nonce) ->
          admin_socket(config, ui, request, host, key, nonce)
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
      let register = ui_sessions.register_images(ui.sessions, cookie, _)
      let seen =
        PageGrant(
          grant:,
          login: ui_sessions.login_of(ui.sessions, cookie),
          address: "http://" <> host,
        )
      resident_upgrade(
        config,
        request,
        state,
        grant.credential,
        id,
        PageRole(grant.ceiling),
        fn(request, attachment) {
          ui.upgrade(request, attachment, open, register, seen)
        },
      )
    }
  }
}

// The home's socket (protocol-change/065): the same checks as a session's
// socket, in the same order, against a grant of the `Home` scope. There is no
// session to resolve, so the checks end with the credential, and the upgrade
// is handed the principal it authenticated, under an observer-class permit,
// since the home takes only clicks and never a prompt.
fn home_socket(
  config: Config(instance),
  ui: Ui(instance),
  request,
  host: String,
  key: String,
  nonce: Option(String),
) {
  let checked = {
    use Nil <- result.try(case ui_http.origin_matches(request, host) {
      True -> Ok(Nil)
      False -> Error(plain(403, "forbidden origin"))
    })
    use nonce <- result.try(
      option.to_result(nonce, Nil)
      |> result.map_error(fn(_) { plain(403, "forbidden page") }),
    )
    use #(state, page, cookie, principal) <- result.try(home_grant(
      config,
      ui,
      request,
      key,
    ))
    use Nil <- result.try(case ui_sessions.admits(page, nonce) {
      True -> Ok(Nil)
      False -> Error(plain(403, "forbidden page"))
    })
    Ok(#(state, ui_sessions.grant(page), cookie, principal))
  }
  case checked {
    Error(response) -> ui_http.secured(response, host)
    Ok(#(state, grant, cookie, principal)) ->
      home_upgrade(
        config,
        ui,
        request,
        state,
        principal,
        PageGrant(
          grant:,
          login: ui_sessions.login_of(ui.sessions, cookie),
          address: "http://" <> host,
        ),
        ui_sessions.open_until(ui.sessions, cookie, grant),
      )
  }
}

// Reserves the permit and hands the home's attachment to the upgrade, which
// takes custody of it in the socket's process. The release here follows the
// upgrade's own barrier exactly as `resident_upgrade`'s does.
fn home_upgrade(
  config: Config(instance),
  ui: Ui(instance),
  request,
  state: root.Ready(instance),
  principal: access.Principal,
  seen: PageGrant,
  open: fn() -> Result(Int, Nil),
) {
  let grant = seen.grant
  case
    upgrade_log.timed(upgrade_log.Page, "acquire", fn() {
      root.acquire(config.daemon, root.Observer, within: 1000)
    })
  {
    Error(reason) -> {
      upgrade_log.refused(upgrade_log.Page, "acquire", reason)
      plain(503, reason)
    }
    Ok(permit) -> {
      let response =
        ui.home(
          request,
          HomeAttachment(
            epoch: state.epoch,
            principal:,
            digest: grant.credential,
            permit:,
            registry: state.registry,
            activity: home_activity(config, state.registry, grant.credential),
            sessions_directory: state.sessions_directory,
            state_root: state.state_root,
            create: fn(principal, request, scope) {
              create_session(
                config,
                state.registry,
                state.sessions_directory,
                principal,
                request,
                scope,
              )
            },
            profiles: fn() {
              profiles.names(config.domain_configuration)
              |> result.unwrap([])
            },
            executors: list.map(config.executors, fn(executor) { executor.name }),
          ),
          open,
          seen,
        )
      root.release(config.daemon, permit)
      response
    }
  }
}

// The admin page's socket (protocol-change/065, the fifth pull request): the
// home's checks in the home's order, against a grant of the `Admin` scope, and
// then one more that no other page has: the principal the credential
// authenticates as must be the daemon's owner (`admin_grant`).
fn admin_socket(
  config: Config(instance),
  ui: Ui(instance),
  request,
  host: String,
  key: String,
  nonce: Option(String),
) {
  let checked = {
    use Nil <- result.try(case ui_http.origin_matches(request, host) {
      True -> Ok(Nil)
      False -> Error(plain(403, "forbidden origin"))
    })
    use nonce <- result.try(
      option.to_result(nonce, Nil)
      |> result.map_error(fn(_) { plain(403, "forbidden page") }),
    )
    use #(state, page, cookie, principal) <- result.try(admin_grant(
      config,
      ui,
      request,
      key,
    ))
    use Nil <- result.try(case ui_sessions.admits(page, nonce) {
      True -> Ok(Nil)
      False -> Error(plain(403, "forbidden page"))
    })
    Ok(#(state, ui_sessions.grant(page), cookie, principal))
  }
  case checked {
    Error(response) -> ui_http.secured(response, host)
    Ok(#(state, grant, cookie, principal)) ->
      admin_upgrade(
        config,
        ui,
        request,
        state,
        principal,
        grant,
        ui_sessions.login_of(ui.sessions, cookie),
        ui_sessions.open_until(ui.sessions, cookie, grant),
      )
  }
}

// Reserves the permit and hands the admin page's attachment to the upgrade,
// which takes custody of it in the socket's process, as `home_upgrade` does.
fn admin_upgrade(
  config: Config(instance),
  ui: Ui(instance),
  request,
  state: root.Ready(instance),
  principal: access.Principal,
  grant: ui_sessions.Grant,
  login: Option(ui_sessions.Issuer),
  open: fn() -> Result(Int, Nil),
) {
  case
    upgrade_log.timed(upgrade_log.Page, "acquire", fn() {
      root.acquire(config.daemon, root.Observer, within: 1000)
    })
  {
    Error(reason) -> {
      upgrade_log.refused(upgrade_log.Page, "acquire", reason)
      plain(503, reason)
    }
    Ok(permit) -> {
      let response =
        ui.admin(
          request,
          AdminAttachment(
            epoch: state.epoch,
            principal:,
            digest: grant.credential,
            permit:,
            registry: state.registry,
            state_root: state.state_root,
            login:,
          ),
          open,
          grant.ceiling,
        )
      root.release(config.daemon, permit)
      response
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
    ui_http.Unknown
    | ui_http.Socket(..)
    | ui_http.HomeSocket(..)
    | ui_http.LoginPage(..)
    | ui_http.ClaimPage
    | ui_http.ClaimSubmit
    | ui_http.AdminSocket(..) -> plain(404, "unknown endpoint")

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

    // One image of the page's transcript. It is a fetch of this origin's own
    // (`navigation_allowed`), and it is answered only for a page that passes
    // every check the page itself does (`page_grant`): a live UI session under
    // this key, for this session, whose credential still authenticates and is
    // still a member. The page's component then says whether it drew an image
    // at that row and place; the bytes are the daemon's to check (`picture`).
    ui_http.Image(key, id, ref, position) ->
      case ui_http.navigation_allowed(request) {
        False -> plain(403, "forbidden fetch")
        True -> image_of(config, ui, request, key, id, ref, position)
      }

    // Every explicit result read repeats the page's current authorization and
    // resolves its immutable identity within this session, before reading bytes.
    ui_http.ResultPage(key, id, ref, index) ->
      case ui_http.navigation_allowed(request) {
        False -> plain(403, "forbidden fetch")
        True -> result_of(config, ui, request, key, id, ref, Some(index))
      }

    ui_http.ResultDownload(key, id, ref) ->
      case ui_http.navigation_allowed(request) {
        False -> plain(403, "forbidden fetch")
        True -> result_of(config, ui, request, key, id, ref, None)
      }

    // A ticket presented against another session's path, or a home's ticket
    // presented here, is spent without a UI session. A redeemed one adds a
    // page and leaves the principal's others open (the oldest ends only at
    // `ui_sessions.max_pages`), and hands this tab the new page's key, in the
    // cookie's path, and its nonce, in the body, never in a redirect.
    ui_http.Exchange(id, ticket) ->
      case ui_http.exchange_allowed(request) {
        False -> plain(403, "forbidden exchange")
        True ->
          case
            ui_sessions.redeem(
              ui.sessions,
              ticket,
              ui_sessions.SessionExchange(id),
            )
          {
            Error(ui_sessions.UnknownTicket) ->
              refused_page(401, ending.LinkExpired, id)
            Error(ui_sessions.OtherScope) ->
              plain(403, "ticket names another session")
            Ok(redeemed) ->
              entered(config, ui, redeemed, page.session_path(redeemed.key, id))
          }
      }

    // The home page, kept to the same two rules as a session's: a navigation
    // from this origin or from outside any page, and a cookie under the key
    // that names a live page of the `Home` scope.
    ui_http.HomePage(key) ->
      case ui_http.navigation_allowed(request) {
        False -> plain(403, "forbidden navigation")
        True ->
          case home_grant(config, ui, request, key) {
            Error(response) -> response
            Ok(_) ->
              document(200, "text/html; charset=utf-8", page.home_shell())
          }
      }

    // The admin page, kept to the same two rules: a navigation from this origin
    // or from outside any page, and a cookie under the key that names a live
    // page of the `Admin` scope whose credential is still the owner's.
    ui_http.AdminPage(key) ->
      case ui_http.navigation_allowed(request) {
        False -> plain(403, "forbidden navigation")
        True ->
          case admin_grant(config, ui, request, key) {
            Error(response) -> response
            Ok(_) ->
              document(200, "text/html; charset=utf-8", page.admin_shell())
          }
      }

    // The admin exchange is the home's twin: a session's ticket or a home's
    // presented here is spent and refused, and no page is added, and an admin
    // ticket presented at either of theirs is too, since each exchange redeems
    // only its own scope (`ui_sessions.redeem`).
    ui_http.AdminExchange(ticket) ->
      case ui_http.exchange_allowed(request) {
        False -> plain(403, "forbidden exchange")
        True ->
          case
            ui_sessions.redeem(ui.sessions, ticket, ui_sessions.AdminExchange)
          {
            Error(ui_sessions.UnknownTicket) ->
              refused_admin(401, ending.LinkExpired)
            Error(ui_sessions.OtherScope) ->
              plain(403, "ticket names another page")
            Ok(redeemed) ->
              entered(config, ui, redeemed, page.admin_path(redeemed.key))
          }
      }

    // The home's exchange is the session exchange's twin: a session's ticket
    // presented here is spent and refused, and no page is added.
    ui_http.HomeExchange(ticket) ->
      case ui_http.exchange_allowed(request) {
        False -> plain(403, "forbidden exchange")
        True ->
          case
            ui_sessions.redeem(ui.sessions, ticket, ui_sessions.HomeExchange)
          {
            Error(ui_sessions.UnknownTicket) ->
              refused_home(401, ending.LinkExpired)
            Error(ui_sessions.OtherScope) ->
              plain(403, "ticket names another page")
            Ok(redeemed) ->
              entered(config, ui, redeemed, page.home_path(redeemed.key))
          }
      }

    // A browser's visit to its bookmark: the verification, and then a home page
    // the login mints (protocol-change/065, PR 8).
    ui_http.LoginResume(key) -> login_resume(config, ui, request, key)
  }
}

// The fixed resume page, for a visit to the bookmark. It is a navigation from
// outside any page or from this origin, as every keyed page is, and its key is
// the shape a login key has, so no other path under `/ui/l` is a page.
fn login_page(request, key: String) {
  case ui_http.navigation_allowed(request), login_key(key) {
    False, _ -> plain(403, "forbidden navigation")
    True, False -> plain(404, "unknown endpoint")
    True, True -> document(200, "text/html; charset=utf-8", page.login_page())
  }
}

// A login key is 32 lowercase hexadecimal digits, which is what the token's `k`
// caveat holds, so a path under `/ui/l` that is not one is no login's.
fn login_key(key: String) -> Bool {
  login.is_key(key)
}

// The resume, a `POST` to the bookmark. The checks run in the order 065 gives:
// the host was checked by the router, then this origin's own page as the sender,
// the form's declared size and type, a control-class parser permit (which a
// daemon that is not serving refuses), the body, and the login itself, which is
// verified from the cookies and the posted nonce before the catalogue is asked
// anything. Every refusal of the login is the same `401` with a fixed document
// that echoes nothing.
fn login_resume(config: Config(instance), ui: Ui(instance), request, key) {
  case
    ui_http.same_origin_post(request),
    login_key(key),
    ui_http.form_declared(request)
  {
    False, _, _ -> plain(403, "forbidden sender")
    True, False, _ -> plain(404, "unknown endpoint")
    True, True, False -> plain(400, "bad request")
    True, True, True ->
      case
        upgrade_log.timed(upgrade_log.Page, "acquire", fn() {
          root.acquire(config.daemon, root.Control, within: 1000)
        })
      {
        Error(reason) -> {
          upgrade_log.refused(upgrade_log.Page, "acquire", reason)
          plain(503, "daemon not ready")
        }
        Ok(permit) -> {
          let answer = resumed_page(config, ui, request, key)
          root.release(config.daemon, permit)
          answer
        }
      }
  }
}

fn resumed_page(config: Config(instance), ui: Ui(instance), request, key) {
  case mist.read_body(request, max_body_limit: ui_http.max_form_bytes) {
    Error(_) -> plain(400, "bad request")
    Ok(body) ->
      case ui_http.posted_nonce(body.body), ready(config, upgrade_log.Page) {
        Error(Nil), _ -> plain(400, "bad request")
        Ok(_), Error(_) -> plain(503, "daemon not ready")
        Ok(nonce), Ok(state) ->
          case
            ui_login.resume(
              ui.root_key,
              state.registry,
              ui_http.login_cookies(request),
              key,
              nonce,
              bootstrap.system_time_ms(),
            )
          {
            Error(Nil) -> document_refused()
            Ok(resumed) -> resume_exchange(config, ui, resumed)
          }
      }
  }
}

// The answer to a login that did not open, which is the same whatever the
// reason: a forged token, an altered one, a wrong key or nonce, an expired or
// revoked or unknown row.
fn document_refused() {
  document(401, "text/html; charset=utf-8", page.login_refused())
}

// The fixed claim form, for a person who opens the address. It is a navigation
// from outside any page or from this origin, as the resume page is, and it
// holds nothing the request said.
fn claim_page(request) {
  case ui_http.navigation_allowed(request) {
    False -> plain(403, "forbidden navigation")
    True -> document(200, "text/html; charset=utf-8", page.claim_page(None))
  }
}

// The browser claim, a `POST` from the claim form (protocol-change/065, PR 9).
// The checks run cheapest first: the host was checked by the router, then this
// origin's own page as the sender (the claim's one secret is typed by a person,
// so no other page may post it on their behalf and a program that says nothing
// of its origin is refused too), the form's declared size and type, then the
// body, which is at most 1 KiB, and the token's shape. Only a value that is a
// claim token takes a reservation, one per claim as `/v2/claim` takes it, so a
// second post for a claim already in flight is refused and nothing a stranger
// can post without a claim-shaped value costs the daemon a place. The answer to
// a refusal that a person can correct is the form again with fixed words above
// it, which needs the policy that lets the form post, so this handler secures
// its own answers.
fn claim_submit(config: Config(instance), ui: Ui(instance), request, host) {
  case ui_http.same_origin_post(request), ui_http.form_declared(request) {
    False, _ -> ui_http.secured(plain(403, "forbidden sender"), host)
    True, False -> ui_http.secured(plain(400, "bad request"), host)
    True, True ->
      case mist.read_body(request, max_body_limit: ui_http.max_form_bytes) {
        Error(_) -> ui_http.secured(plain(400, "bad request"), host)
        Ok(body) ->
          case ui_http.posted_claim(body.body) {
            Error(Nil) -> ui_http.secured(plain(400, "bad request"), host)
            Ok(#(typed, name)) ->
              reserve_claim(config, ui, host, string.trim(typed), name)
          }
      }
  }
}

// The token's shape is checked before anything is looked up or reserved, so a
// bearer, a login or a stray word typed into the field is refused having asked
// the daemon nothing. A token that has the shape is hashed here and dropped:
// only its hash goes further, and nothing the person typed is written to a log
// or drawn back.
fn reserve_claim(
  config: Config(instance),
  ui: Ui(instance),
  host,
  typed: String,
  name: Option(String),
) {
  let hashed = case claim.validate_token(typed) {
    Ok(Nil) -> access.claim_digest(claim.digest(typed))
    Error(_) -> Error(catalogue.Invalid("not a claim token"))
  }
  case hashed {
    Error(_) -> claim_refused(host, 400, page.NotAClaim)
    Ok(presented) ->
      case root.acquire_claim(config.daemon, presented, within: 1000) {
        Error(root.ClaimInFlight) -> claim_refused(host, 409, page.ClaimBusy)
        Error(root.NotAdmitted(reason)) -> {
          upgrade_log.refused(upgrade_log.Page, "acquire", reason)
          ui_http.secured(plain(503, "daemon not ready"), host)
        }
        Ok(permit) -> {
          let answer = redeem_claim(config, ui, host, presented, name)
          root.release(config.daemon, permit)
          answer
        }
      }
  }
}

fn redeem_claim(
  config: Config(instance),
  ui: Ui(instance),
  host,
  presented: access.ClaimDigest,
  name: Option(String),
) {
  case ready(config, upgrade_log.Page) {
    Error(_) -> ui_http.secured(plain(503, "daemon not ready"), host)
    Ok(state) ->
      case
        ui_login.claim(
          ui.root_key,
          state.registry,
          presented,
          name,
          bootstrap.system_time_ms(),
        )
      {
        Error(refusal) -> claim_unbound(host, refusal)
        Ok(bound) -> claim_opened(ui, host, bound)
      }
  }
}

// What a claim that bound opens: a `Home` page of the principal at `Operator`
// ceiling, `Fresh` since the person was handed the claim a moment ago, and the
// login the claim bound, attached to the page it opened so the home marks "this
// browser". The ticket is minted and redeemed in this one request and is never
// seen by the browser. A claim that bound and then found the table gone is
// spent with a login nobody holds; the owner rotates, as for a lost reply.
fn claim_opened(ui: Ui(instance), host, bound: ui_login.Claimed) {
  let grant =
    ui_sessions.Grant(
      scope: ui_sessions.Home,
      credential: bound.digest,
      principal: bound.principal.id,
      ceiling: access.Operator,
      reach: ui_sessions.Workspace,
      origin: ui_sessions.Fresh,
      remember: ui_sessions.Forgotten,
    )
  let redeemed = {
    use issued <- result.try(
      ui_sessions.mint(ui.sessions, grant) |> result.replace_error(Nil),
    )
    ui_sessions.redeem(ui.sessions, issued.ticket, ui_sessions.HomeExchange)
    |> result.replace_error(Nil)
  }
  case redeemed {
    Error(Nil) -> ui_http.secured(plain(503, "daemon not ready"), host)
    Ok(redeemed) -> {
      ui_sessions.attach_login(
        ui.sessions,
        redeemed.cookie,
        bound.minted.issuer,
      )
      ui_http.secured(
        enter_response(
          redeemed,
          page.home_path(redeemed.key),
          Ok(option.Some(bound.minted)),
        ),
        host,
      )
    }
  }
}

// A claim that bound nothing, in the words for its reason. Each is the form
// again so the person can correct it.
fn claim_unbound(host, refusal: manager.ClaimError) {
  case refusal {
    manager.ClaimRefused(access.UnknownClaim) ->
      claim_refused(host, 404, page.ClaimUnknown)
    manager.ClaimRefused(access.ExpiredClaim) ->
      claim_refused(host, 410, page.ClaimExpired)
    manager.ClaimRefused(access.ConflictingClaim) ->
      claim_refused(host, 409, page.ClaimUsed)
    manager.ClaimRefused(access.InvalidClaimName) ->
      claim_refused(host, 400, page.NameRefused)
    manager.ClaimRefused(access.ClaimStore(_)) | manager.ClaimUnavailable ->
      claim_refused(host, 503, page.ClaimBusy)
  }
}

fn claim_refused(host, status: Int, notice: page.ClaimNotice) {
  document(
    status,
    "text/html; charset=utf-8",
    page.claim_page(option.Some(notice)),
  )
  |> ui_http.secured_for(host, page.OwnForms)
}

// What a verified login mints. A login narrowed to one session mints a page of
// that session and never a home, because a home's asks (its sign-ins, "sign out
// everywhere", a device link) are the principal's and not the session's; any
// other login mints a home, as a `Resumed` one. The page opens at the login's
// ceiling and is an ordinary eight-hour page: the ticket is minted and redeemed
// in this one request and is never seen by the browser.
fn resume_exchange(
  config: Config(instance),
  ui: Ui(instance),
  resumed: ui_login.Resumed,
) {
  let ceiling = case resumed.allowance.ceiling {
    login.Observer -> access.Observer
    login.Operator -> access.Operator
  }
  let #(scope, reach, exchange, address) = case resumed.allowance.session {
    option.Some(id) -> #(
      ui_sessions.Session(id),
      ui_sessions.OneSession,
      ui_sessions.SessionExchange(id),
      page.session_path(_, id),
    )
    option.None -> #(
      ui_sessions.Home,
      ui_sessions.Workspace,
      ui_sessions.HomeExchange,
      page.home_path,
    )
  }
  let grant =
    ui_sessions.Grant(
      scope:,
      credential: resumed.digest,
      principal: resumed.principal.id,
      ceiling:,
      reach:,
      origin: ui_sessions.Resumed,
      remember: ui_sessions.Forgotten,
    )
  let redeemed = {
    use issued <- result.try(
      ui_sessions.mint_resumed(ui.sessions, grant, resumed.issuer)
      |> result.replace_error(Nil),
    )
    ui_sessions.redeem(ui.sessions, issued.ticket, exchange)
    |> result.replace_error(Nil)
  }
  case redeemed {
    Error(Nil) -> plain(503, "daemon not ready")
    Ok(redeemed) -> entered(config, ui, redeemed, address(redeemed.key))
  }
}

// The exchange page for a redeemed ticket: the keyed address to move to and
// the page's nonce in the body, and the cookie scoped to the page's key. An
// exchange whose ticket was `Remembered` also sets a browser login, in the same
// response: its token is a second cookie, scoped to the login's own key, and its
// nonce is a second value in the body, which the enter script keeps. This is
// the one function that builds a redeemed ticket's response, so it is the one
// place a login is set (protocol-change/065, PR 8).
fn entered(
  config: Config(instance),
  ui: Ui(instance),
  redeemed: ui_sessions.Redeemed,
  next: String,
) {
  let minted = case redeemed.grant.remember {
    ui_sessions.Remembered -> remembered(config, ui, redeemed)
    ui_sessions.Forgotten -> Ok(option.None)
  }
  enter_response(redeemed, next, minted)
}

// The response itself, from the redeemed ticket and the login to set with it,
// if any. A device link exists to set a login, so one whose login cannot be set
// (`Error`) opens no page at all. Opening it without would leave a page with no
// login and no parent, whose own device link would then start a family of
// thirty fresh days past the one the link came from. The browser claim reaches
// here with the login its claim bound, so it too sets its login in the one place
// a login is set.
fn enter_response(
  redeemed: ui_sessions.Redeemed,
  next: String,
  minted: Result(Option(ui_login.Minted), Nil),
) {
  let page_cookie = ui_http.set_cookie(redeemed.cookie, redeemed.key)
  case minted {
    Error(Nil) -> refused_home(401, ending.LinkExpired)
    Ok(option.None) ->
      document(
        200,
        "text/html; charset=utf-8",
        page.enter(next, redeemed.nonce),
      )
      |> response.set_header("set-cookie", page_cookie)
    Ok(option.Some(login)) ->
      document(
        200,
        "text/html; charset=utf-8",
        page.enter_remembered(next, redeemed.nonce, login.key, login.nonce),
      )
      |> response.set_header(
        "set-cookie",
        ui_http.set_login_cookie(login.token, login.key, login.max_age_s),
      )
      |> response.prepend_header("set-cookie", page_cookie)
  }
}

// The login a remembered exchange sets, written to the catalogue and attached to
// the page the exchange opened. A ticket with no issuing login is a person's
// own `loom ui`: when the daemon is not ready or the row is refused, the page
// still opens with none, and the person can run `loom ui` again. A ticket
// minted under a login is a device link, which never opens without one, so the
// same failures, and a parent whose time has run out, are an `Error`.
fn remembered(
  config: Config(instance),
  ui: Ui(instance),
  redeemed: ui_sessions.Redeemed,
) -> Result(Option(ui_login.Minted), Nil) {
  let none = case redeemed.login {
    option.None -> Ok(option.None)
    option.Some(_) -> Error(Nil)
  }
  case ready(config, upgrade_log.Page) {
    Error(_) -> none
    Ok(state) ->
      case
        ui_login.issue(
          ui.root_key,
          state.registry,
          redeemed.grant,
          redeemed.login,
          bootstrap.system_time_ms(),
        )
      {
        Error(_) -> none
        Ok(minted) -> {
          ui_sessions.attach_login(ui.sessions, redeemed.cookie, minted.issuer)
          Ok(option.Some(minted))
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
    keyed_page(ui, request, key)
    |> result.map_error(fn(_) { refused_page(401, ending.PageEnded, id) }),
  )
  let grant = ui_sessions.grant(page)
  use Nil <- result.try(case grant.scope == ui_sessions.Session(id) {
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

// The cookie value whose UI session is live under `key`, with that session,
// which is what both kinds of page start from. A planted value that names no
// UI session under the key is passed over.
fn keyed_page(ui: Ui(instance), request, key: String) {
  ui_http.session_cookies(request)
  |> list.find_map(fn(cookie) {
    use page <- result.try(ui_sessions.lookup(ui.sessions, cookie))
    case ui_sessions.keyed(page, key) {
      True -> Ok(#(cookie, page))
      False -> Error(Nil)
    }
  })
}

// A home page's `page_grant` (protocol-change/065): the cookie names a live
// UI session under this key, whose scope is `Home`, and its credential still
// authenticates. There is no session to hold a membership in, so that check
// does not exist; what the home then shows is read with the same credential
// digest on every refresh. The answer carries the readiness the socket's
// upgrade reuses, the UI session, the cookie and the principal.
fn home_grant(
  config: Config(instance),
  ui: Ui(instance),
  request,
  key: String,
) {
  use #(cookie, page) <- result.try(
    keyed_page(ui, request, key)
    |> result.map_error(fn(_) { refused_home(401, ending.PageEnded) }),
  )
  let grant = ui_sessions.grant(page)
  use Nil <- result.try(case grant.scope {
    ui_sessions.Home -> Ok(Nil)
    ui_sessions.Session(_) | ui_sessions.Admin ->
      Error(refused_home(403, ending.PageEnded))
  })
  use state <- result.try(
    ready(config, upgrade_log.Page)
    |> result.map_error(fn(_) { refused_home(503, ending.DaemonNotReady) }),
  )
  use principal <- result.map(
    asked(upgrade_log.Page, "authenticate", fn() {
      manager.authenticate(state.registry, grant.credential)
    })
    |> result.map_error(fn(_) { refused_home(401, ending.AccessRevoked) }),
  )
  #(state, page, cookie, principal)
}

// An admin page's `page_grant`: the cookie names a live UI session under this
// key whose scope is `Admin`, its credential still authenticates, and the
// principal it authenticates as is the daemon's owner. The last is checked here
// as well as when a ticket is minted, because the admin page is the one page
// that changes who may see what, so no earlier check is trusted to stay true:
// a credential that was the owner's when the page was opened and is not now ends
// the page at its next request. The answer is `home_grant`'s.
fn admin_grant(
  config: Config(instance),
  ui: Ui(instance),
  request,
  key: String,
) {
  use #(cookie, page) <- result.try(
    keyed_page(ui, request, key)
    |> result.map_error(fn(_) { refused_admin(401, ending.PageEnded) }),
  )
  let grant = ui_sessions.grant(page)
  use Nil <- result.try(case grant.scope {
    ui_sessions.Admin -> Ok(Nil)
    ui_sessions.Session(_) | ui_sessions.Home ->
      Error(refused_admin(403, ending.PageEnded))
  })
  use state <- result.try(
    ready(config, upgrade_log.Page)
    |> result.map_error(fn(_) { refused_admin(503, ending.DaemonNotReady) }),
  )
  use principal <- result.try(
    asked(upgrade_log.Page, "authenticate", fn() {
      manager.authenticate(state.registry, grant.credential)
    })
    |> result.map_error(fn(_) { refused_admin(401, ending.AccessRevoked) }),
  )
  use Nil <- result.map(case principal.kind {
    access.OwnerPrincipal -> Ok(Nil)
    access.MemberPrincipal -> Error(refused_admin(403, ending.AccessRevoked))
  })
  #(state, page, cookie, principal)
}

// The page's image at a row's name and position, for a request that already
// passed the fetch-site check: the page grant, then the reader the page's
// socket registered under its cookie. A page whose socket has not opened has
// no reader and so no image.
fn image_of(
  config: Config(instance),
  ui: Ui(instance),
  request,
  key: String,
  id: String,
  ref: String,
  position: Int,
) {
  let found = {
    use #(_, _, cookie) <- result.try(page_grant(config, ui, request, key, id))
    ui_sessions.images(ui.sessions, cookie)
    |> result.map(fn(read) { picture(read(ref, position)) })
    |> result.replace_error(plain(404, "unknown image"))
  }
  case found {
    Ok(answer) | Error(answer) -> answer
  }
}

// The result identity is resolved only through this session's concrete store.
// The resident is resolved without opening or attaching another session. The
// grant is checked again after a bounded read, so expiry while reading cannot
// deliver result bytes after the handler's final authorization check.
fn result_of(
  config: Config(instance),
  ui: Ui(instance),
  request,
  key,
  id,
  ref,
  index,
) {
  let found = {
    use #(ready, _, _) <- result.try(page_grant(config, ui, request, key, id))
    use resident <- result.try(
      manager.resolve(ready.registry, id)
      |> result.map_error(fn(_) { plain(404, "session unavailable") }),
    )
    let reader = ui.result_reader(resident)
    use descriptor <- result.try(
      ui_result.descriptor(reader, ref)
      |> result.map_error(fn(_) { plain(404, "result unavailable") }),
    )
    use answer <- result.try(case index {
      Some(index) -> {
        use #(text, pages) <- result.map(
          ui_result.page(reader, descriptor, index)
          |> result.map_error(fn(_) { plain(404, "result page unavailable") }),
        )
        document(
          200,
          "text/html; charset=utf-8",
          tool_result.document(text, index, pages, descriptor.byte_length),
        )
      }
      None -> {
        use bytes <- result.map(
          ui_result.download(reader, descriptor)
          |> result.map_error(fn(_) {
            plain(503, "result download unavailable")
          }),
        )
        response.new(200)
        |> response.set_header("content-type", "application/json")
        |> response.set_header(
          "content-disposition",
          "attachment; filename=\"loom-tool-result.json\"",
        )
        |> response.set_body(mist.Bytes(bytes))
      }
    })
    use _ <- result.map(page_grant(config, ui, request, key, id))
    answer
  }
  case found {
    Ok(answer) | Error(answer) -> answer
  }
}

// The answer for one image the page drew, or the refusal for one it did not
// or one the daemon will not send. `image.serve` is the check: a raster type,
// bytes that decode, at most the terminal's limit and a magic number that
// says the declared type. The type is the served one and the response is
// already `nosniff`, so the browser draws what was checked and nothing it
// might sniff from the bytes.
fn picture(found: Result(transcript_image.Image, Nil)) {
  let served = {
    use held <- result.try(result.replace_error(
      found,
      plain(404, "unknown image"),
    ))
    use image.Served(mime_type:, bytes:) <- result.map(
      image.serve(held)
      |> result.map_error(fn(refusal) {
        case refusal {
          image.NotAnImage -> plain(415, "not a supported image")
          image.TooLarge -> plain(413, "image too large")
        }
      }),
    )
    response.new(200)
    |> response.set_header("content-type", mime_type)
    |> response.set_header("content-disposition", "inline")
    |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(bytes)))
  }
  case served {
    Ok(answer) | Error(answer) -> answer
  }
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

// `refused_page` for the home: the same fixed documents, with the home's
// words, which name no session.
fn refused_home(status: Int, reason: Ending) {
  document(status, "text/html; charset=utf-8", page.home_refusal(reason))
}

// `refused_page` for the admin page: the same fixed documents, with its words,
// which name its fifteen minutes and the home's "Admin" button.
fn refused_admin(status: Int, reason: Ending) {
  document(status, "text/html; charset=utf-8", page.admin_refusal(reason))
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

// The bearer reader for `/v2/control` and the session attach. A credential
// the daemon or `loom claim` draws is exactly 64 lowercase hex characters, so
// any other presented string is refused here, before it is hashed and before
// the catalogue is read. `access.credential_digest` is the shape check, since
// a credential and its digest have the same 64-character shape. This narrows
// what reaches the catalogue; the `Bearer` kind in the lookup is what decides
// which row can match (protocol-change/065).
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
    True -> {
      use _shape <- result.try(
        access.credential_digest(token)
        |> result.replace_error("unauthorized"),
      )
      token
      |> bit_array.from_string
      |> bootstrap.sha256
      |> bit_array.base16_encode
      |> string.lowercase
      |> access.credential_digest
      |> result.replace_error("unauthorized")
    }
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
      let class = case authority, role {
        access.Participant(access.Observer), _ -> root.Observer
        access.Owner, MembershipRole
        | access.Participant(access.Operator), MembershipRole
        -> root.Operator
        access.Owner, PageRole(..)
        | access.Participant(access.Operator), PageRole(..)
        -> root.PageOperator
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
                state_root: state.state_root,
                sessions_directory: state.sessions_directory,
                registration:,
                activity: home_activity(config, state.registry, digest),
                peers: peer_directory(config, state.registry),
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
    manager.SessionMoving(..) ->
      Some("session is moving to another orchestrator")
    manager.SessionMoved(..) ->
      Some("session was moved to another orchestrator")
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
    Ok(protocol.ClaimRequest(id:, credential:, name:)) ->
      case
        manager.claim(
          state.registry,
          presented,
          credential,
          name,
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
    manager.ClaimRefused(access.InvalidClaimName) -> "invalid_name"
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
          |> result.replace_error(control_refusal("unavailable")),
        )
        use principal <- result.try(
          manager.authenticate(current.registry, digest)
          |> result.replace_error(control_refusal("unauthorized")),
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
            | protocol.CredentialSignins(..)
            | protocol.RevokeLogin(..)
            | protocol.RenamePrincipal(..)
            | protocol.SessionMembers(..)
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
            | protocol.MoveSession(..)
            | protocol.DeleteSession(..) -> KeepServing
          }
          #(protocol.event(Some(request.id), event, body), after)
        }
        Error(Refused(code:, message:, detail:)) -> #(
          refusal_with(protocol.Fault(Some(request.id), code, message), detail),
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
    | protocol.CredentialSignins(..)
    | protocol.SessionMembers(..)
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
    | protocol.RevokeLogin(..)
    | protocol.RenamePrincipal(..)
    | protocol.CreateSession(..)
    | protocol.OpenSession(..)
    | protocol.StopSession(..)
    | protocol.MoveSession(..)
    | protocol.DeleteSession(..)
    | protocol.Shutdown(_) -> root.ControlMutation
  }
}

fn refusal(fault: protocol.Fault) {
  refusal_with(fault, [])
}

// A refusal frame with more members than the code and the words. The two
// redirect codes of protocol-change/078 name where the session lives, and every
// other refusal passes an empty list.
fn refusal_with(fault: protocol.Fault, detail: List(#(String, JsonValue))) {
  protocol.event(
    fault.reply_to,
    "error",
    json.Object([
      #("code", json.String(fault.code)),
      #("message", json.String(fault.message)),
      ..detail
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

// A ticket for `grant`, or the control refusal for a table that did not
// answer.
fn mint_link(ui: Ui(instance), grant: ui_sessions.Grant) {
  ui_sessions.mint(ui.sessions, grant) |> result.replace_error("unavailable")
}

// The `ui.link` reply: the exchange address the browser is sent to, and how
// long its ticket lasts.
fn link_reply(
  path: String,
  issued: ui_sessions.Issued,
) -> #(String, JsonValue) {
  #(
    "ui.link",
    json.Object([
      #("path", json.String(path)),
      #("expires_in_ms", json.Int(issued.expires_in_ms)),
    ]),
  )
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
) -> Result(#(String, JsonValue), Refused) {
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
          manager.StartFailed(reason) -> Refused("start_failed", reason, [])
          other -> control_refusal(error_code(other))
        }
      })
      |> result.map(fn(view) { #("operations.get", view_json(view)) })
    }
    protocol.CreateSession(_, _, _, configuration, profile, _, _, _) ->
      dispatch_class(config, state, digest, principal, reply_to, command)
      |> result.map_error(fn(code) {
        creation_refusal(config, configuration, profile, code)
      })

    // A session this daemon's catalogue does not hold may be one that another
    // orchestrator owns. The miss comes out of the authorization step as
    // `not_found`, and for the owner principal that is the one place the
    // directory is asked (protocol-change/078, phase 3). A session this
    // daemon handed away is held here as a tombstone, and `open` on it says
    // where it went and, while it is on its way, that it is moving (phase 5).
    protocol.GetSession(id) | protocol.OpenSession(id, _) ->
      dispatch_class(config, state, digest, principal, reply_to, command)
      |> result.map_error(control_refusal)
      |> result.map_error(redirected(config, principal, id, _))
      |> result.map_error(in_flight(state, id, _))

    // Archiving, restoring and deleting a session that moved away name the new
    // owner from the tombstone, and ask no one: the directory is not consulted
    // for a session this daemon never held.
    protocol.ArchiveSession(id, _)
    | protocol.RestoreSession(id, _)
    | protocol.DeleteSession(id, _) ->
      dispatch_class(config, state, digest, principal, reply_to, command)
      |> result.map_error(control_refusal)
      |> result.map_error(tombstoned(config, principal, id, _))
    _ ->
      dispatch_class(config, state, digest, principal, reply_to, command)
      |> result.map_error(control_refusal)
  }
}

// A refusal as the control socket sends it: the code and its words, and any
// members beyond them. Only the two redirect codes carry members.
type Refused {
  Refused(code: String, message: String, detail: List(#(String, JsonValue)))
}

fn control_refusal(code: String) -> Refused {
  Refused(code, "request refused", [])
}

/// The code `sessions.get` and `sessions.open` answer when the session is not in
/// this daemon's catalogue but another configured orchestrator holds it
/// (protocol-change/078, phase 3).
pub const not_owner_code = "not_owner"

/// The code `sessions.get` and `sessions.open` answer when the session is not in
/// this daemon's catalogue, no orchestrator said it holds it, and some could not
/// be asked (protocol-change/078, phase 3).
pub const owner_unreachable_code = "owner_unreachable"

// The refusal for a session this daemon does not hold. Only the owner principal
// is redirected: a member's standing on the session is the owning daemon's to
// judge, and this one cannot vouch for it. A miss that no orchestrator explains
// stays `not_found`, and so does a directory that says the session is here after
// all, which can only be a creation that landed between the two reads and which
// the client's retry finds.
fn redirected(
  config: Config(instance),
  principal: access.Principal,
  id: String,
  refused: Refused,
) -> Refused {
  case refused.code, principal.kind {
    "not_found", access.OwnerPrincipal ->
      case config.directory.lookup(id) {
        Ok(session_directory.Elsewhere(owner)) -> not_owner(owner)
        Error(session_directory.Unreachable(names)) -> owner_unreachable(names)
        Ok(session_directory.Here) | Error(session_directory.Unknown) -> refused
      }
    code, access.OwnerPrincipal if code == not_owner_code ->
      tombstoned(config, principal, id, refused)
    _, _ -> refused
  }
}

// The refusal for a session this daemon handed to another orchestrator. Only the
// owner is told where it went, as for any redirect, and the answer comes from
// the daemon's own tombstone: the directory answers a session it holds a
// tombstone for without asking a peer. Anything else is left as it was.
fn tombstoned(
  config: Config(instance),
  principal: access.Principal,
  id: String,
  refused: Refused,
) -> Refused {
  case refused.code, principal.kind {
    code, access.OwnerPrincipal if code == not_owner_code ->
      case config.directory.lookup(id) {
        Ok(session_directory.Elsewhere(owner)) -> not_owner(owner)
        Ok(session_directory.Here) | Error(_) -> refused
      }
    _, _ -> refused
  }
}

/// The code `sessions.open` answers while the session is being handed to
/// another orchestrator (protocol-change/078, phase 5). It names the
/// orchestrator the session is going to and the move.
pub const moving_code = "moving"

// A session whose move is in flight cannot be opened, and the refusal says where
// it is going and which move it is, so a client can wait and then ask again.
fn in_flight(
  state: root.Ready(instance),
  id: String,
  refused: Refused,
) -> Refused {
  case refused.code {
    code if code == moving_code ->
      case manager.custody(state.registry, id) {
        Ok(catalogue.Moving(op:, to:)) ->
          Refused(
            moving_code,
            "this session is being moved to another orchestrator",
            [
              #("orchestrator", json.String(to)),
              #("op", json.String(op)),
            ],
          )
        Ok(_) | Error(_) -> refused
      }
    _ -> refused
  }
}

fn not_owner(owner: orchestrators.Orchestrator) -> Refused {
  let address = case owner.address {
    Some(address) -> [#("address", json.String(address))]
    None -> []
  }
  Refused(not_owner_code, "this session is owned by another orchestrator", [
    #("orchestrator", json.String(owner.name)),
    ..address
  ])
}

fn owner_unreachable(names: List(String)) -> Refused {
  Refused(
    owner_unreachable_code,
    "the orchestrator that owns this session could not be reached",
    [#("orchestrators", json.Array(list.map(names, json.String)))],
  )
}

/// The code `sessions.move` answers when the destination is not one of the
/// `[orchestrators.<name>]` the daemon's configuration defines (protocol-change/078,
/// phase 5).
pub const orchestrator_unknown_code = "orchestrator_unknown"

/// The code `create_session` answers when the profile a creation names is not
/// one its configuration defines.
pub const unknown_profile_code = "unknown_profile"

/// The code `create_session` answers when a creation names an executor that
/// the daemon's configuration does not define (protocol-change/078).
pub const executor_unknown_code = "executor_unknown"

/// The code `create_session` answers when a creation names a pool that the
/// daemon's configuration does not define (protocol-change/078).
pub const pool_unknown_code = "pool_unknown"

/// The code `create_session` answers when a creation names a profile and the
/// configuration it would load cannot be read or parsed. The profile was never
/// looked up, so `unknown_profile` would blame the name for the file.
pub const unusable_configuration_code = "unusable_configuration"

// A refused creation's code and message. An unknown profile, an unusable
// configuration, an unknown executor and an unknown pool are the refusals that
// say more than "request refused": the owner who mistyped a name needs the
// names that exist, the owner whose file does not parse needs the key it names,
// and the owner who named an executor or a pool needs to know it is the
// configuration that lacks it.
// The caller is the owner because `create_session` checks that first. The
// message is worded again here, from the same check, rather than carried out
// of `create_session`, so that function's error stays the single code the
// home page's creation shares.
fn creation_refusal(
  config: Config(instance),
  configuration: String,
  profile: Option(String),
  code: String,
) -> Refused {
  case code, profile {
    "unknown_profile", Some(name) | "unusable_configuration", Some(name) -> {
      let canonical = case configuration {
        "" -> ""
        path -> bootstrap.canonical_path(path) |> result.unwrap(path)
      }
      let words = case
        profiles.check(
          profiles.effective(canonical, config.domain_configuration),
          name,
        )
      {
        Error(refusal) -> profiles.refusal_message(refusal)
        Ok(Nil) -> "request refused"
      }
      Refused(code, words, [])
    }

    "executor_unknown", _ ->
      Refused(
        code,
        "no executor with that name is configured on this daemon",
        [],
      )

    "pool_unknown", _ ->
      Refused(code, "no pool with that name is configured on this daemon", [])

    _, _ -> control_refusal(code)
  }
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
      let directory = peer_directory(config, state.registry)
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
      use target <- result.try(
        peer_directory(config, state.registry).resolve(target)
        |> peer_mail.plain,
      )
      peers.link(source, target, from, to, wake)
      |> result.map(fn(value) { #("peers.link", value) })
    }
    protocol.SendPeer(source, from, target, to, id, text, supplied) -> {
      use Nil <- result.try(owner(principal))
      use Nil <- result.try(epoch(state, supplied))
      use source <- result.try(peer_endpoint(config, state.registry, source))
      let directory = peer_directory(config, state.registry)
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
      let directory = peer_directory(config, state.registry)
      let answer = peers.unlink_session(directory, source, from, target, to)
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

    // A principal's browser logins (protocol-change/065, PR 8). A member reads its
    // own; the owner may name any principal. The registry reauthenticates the
    // caller and applies that rule in its own dispatch, and a member naming
    // another principal is `forbidden`. A row is a fingerprint and times, never a
    // token.
    protocol.CredentialSignins(target, after) -> {
      use #(id, page) <- result.try(
        manager.signins(
          state.registry,
          digest,
          target,
          after:,
          now_ms: bootstrap.system_time_ms(),
        )
        |> result.map_error(admin_error_code),
      )
      let rows =
        list.map(page.entries, fn(row) { #(row.fingerprint, signin_json(row)) })
      use #(bounded, more) <- result.try(bounded_rows(rows, page.remainder))
      Ok(#(
        "credentials.signins",
        json.Object(list.append(
          [
            #("principal_id", json.String(id)),
            #("signins", json.Array(list.map(bounded, pair.second))),
          ],
          next_field(bounded, more),
        )),
      ))
    }
    protocol.RevokeLogin(target, fingerprint, supplied) -> {
      use #(id, revoked) <- result.map(
        manager.revoke_login(
          state.registry,
          digest,
          supplied,
          target,
          fingerprint,
        )
        |> result.map_error(admin_error_code),
      )
      ui_login.revoked(id, revoked)
      #(
        "credentials.revoke_login",
        json.Object([
          #("principal_id", json.String(id)),
          #("fingerprint", json.String(fingerprint)),
        ]),
      )
    }

    // A principal's display name (protocol-change/065, PR 10). A member omits the
    // principal and renames itself, and the owner may name any principal and
    // itself. The registry reauthenticates the caller and applies that rule in
    // its own dispatch, so a member naming another principal is `forbidden`. The
    // name is judged there too, by the rule a claim's chosen name is, and a name
    // it refuses is `invalid_name`. The reply names the principal and the name as
    // stored, which is the trimmed text.
    protocol.RenamePrincipal(target, name, supplied) -> {
      use renamed <- result.map(
        manager.rename_principal(state.registry, digest, supplied, target, name)
        |> result.map_error(rename_error_code),
      )
      #(
        "principals.rename",
        json.Object([
          #("principal_id", json.String(renamed.id)),
          #("name", json.String(renamed.display_name)),
        ]),
      )
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
    protocol.SessionMembers(id, after) -> {
      use Nil <- result.try(owner(principal))
      use page <- result.try(
        manager.session_member_page(state.registry, digest, id, after:)
        |> result.map_error(admin_error_code),
      )
      let rows =
        list.map(page.page.entries, fn(row) {
          #(row.principal_id, member_json(row))
        })
      use #(bounded, more) <- result.try(bounded_rows(rows, page.page.remainder))
      Ok(#(
        "sessions.members",
        json.Object(list.append(
          [
            #("session_id", json.String(id)),
            #("scope", json.String(scope_text(page.scope))),
            #("members", json.Array(list.map(bounded, pair.second))),
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
    // Its reach is `OneSession`: the page it opens draws nothing that names
    // another session unless the page's own role already did.
    protocol.UiLink(Some(id), page: ceiling, remember: _) -> {
      use ui <- result.try(option.to_result(config.ui, "unavailable"))
      use _ <- result.try(authorized(state, digest, id))
      use issued <- result.map(mint_link(
        ui,
        ui_sessions.Grant(
          scope: ui_sessions.Session(id),
          credential: digest,
          principal: principal.id,
          ceiling:,
          reach: ui_sessions.OneSession,
          origin: ui_sessions.Fresh,
          remember: ui_sessions.Forgotten,
        ),
      ))
      link_reply(page.exchange_path(id, issued.ticket), issued)
    }

    // A ticket for the principal's home page (protocol-change/065). No
    // membership is checked, since the home is bound to no session: the
    // credential that authenticated this control connection is the whole of
    // what the ticket records, and what the home lists is read with that
    // digest on every refresh, so it is what the principal may see then.
    protocol.UiLink(None, page: ceiling, remember:) -> {
      use ui <- result.try(option.to_result(config.ui, "unavailable"))

      // The exchange sets a browser login unless the launcher declined it, so
      // the next visit needs no `loom ui`. The ticket is `Fresh`: someone who
      // holds a credential asked for it a moment ago.
      let remember = case remember {
        option.Some(protocol.Forget) -> ui_sessions.Forgotten
        option.Some(protocol.Remember) | option.None -> ui_sessions.Remembered
      }
      use issued <- result.map(mint_link(
        ui,
        ui_sessions.Grant(
          scope: ui_sessions.Home,
          credential: digest,
          principal: principal.id,
          ceiling:,
          reach: ui_sessions.Workspace,
          origin: ui_sessions.Fresh,
          remember:,
        ),
      ))
      link_reply(page.home_exchange_path(issued.ticket), issued)
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
      use Nil <- result.try(epoch(state, supplied))

      // A member is asked about only the sessions its credential holds; the
      // rest are dropped as unknown identities are (protocol-change/050, the
      // addendum on members).
      let rows =
        activity(config, state.registry, held(state.registry, digest, sessions))
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
        #("sessions.get", with_custody(state, id, body))
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
    protocol.CreateSession(
      key,
      workspace,
      name,
      configuration,
      profile,
      executor,
      pool,
      scope,
    ) ->
      create_session(
        config,
        state.registry,
        state.sessions_directory,
        principal,
        manager.Creation(
          key,
          workspace,
          name,
          configuration,
          profile,
          option.unwrap(executor, ""),
          option.unwrap(pool, ""),
        ),
        scope,
      )
      |> result.map(fn(view) { #("sessions.create", view_json(view)) })
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
    protocol.MoveSession(id, to, supplied) -> {
      use Nil <- result.try(owner(principal))
      use Nil <- result.try(epoch(state, supplied))
      use _destination <- result.try(
        orchestrators.find(config.movers.orchestrators, to)
        |> result.replace_error(orchestrator_unknown_code),
      )

      use Nil <- result.try(
        inbound_settled(config.movers, state.registry, id)
        |> result.replace_error(
          admin_error_code(manager.AdminNotMovable(
            "the move in from the session's origin has not finished",
          )),
        ),
      )

      // Each asker mints an operation of its own, and the registry keeps the
      // first: a second request toward the same orchestrator answers the stored
      // one, so two owners asking at once start one move.
      let #(minted, _) = ids.mint_op(config.generator())
      use custody <- result.try(
        manager.begin_move(
          state.registry,
          digest,
          supplied,
          id,
          to:,
          op: ids.op_id_to_string(minted),
        )
        |> result.map_error(admin_error_code),
      )
      case custody {
        catalogue.Moving(op:, to: heading) -> {
          config.movers.begin(catalogue.Pending(session: id, op:, to: heading))
          Ok(#(
            "sessions.move",
            json.Object([
              #("session_id", json.String(id)),
              #("op", json.String(op)),
              #("to", json.String(heading)),
              #("state", json.String("moving")),
            ]),
          ))
        }
        catalogue.Moved(to: owner, ..) ->
          Error(admin_error_code(manager.AdminMoved(to: owner)))
        catalogue.Resident | catalogue.Imported(..) -> Error("unavailable")
      }
    }
    protocol.DeleteSession(id, supplied) -> {
      // A session imported from an orchestrator that has not retired its move is
      // busy: deleting it would be undone by that orchestrator's retry. The
      // question crosses the network, so only the owner holding a current epoch
      // may cause it; the registry decides both again inside its own turn.
      use Nil <- result.try(owner(principal))
      use Nil <- result.try(epoch(state, supplied))
      use Nil <- result.try(
        inbound_settled(config.movers, state.registry, id)
        |> result.replace_error(admin_error_code(manager.AdminBusy)),
      )

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

// A session this daemon imported cannot be handed on, or deleted, until the
// orchestrator it came from has retired the move that brought it here. Until
// then that orchestrator still holds the session as `moving`, and its mover may
// yet ask this one to activate it. Beginning a move here replaces the `imported`
// row with `moving`, and a move that is then abandoned deletes that row, so the
// activation of the first move would be refused for a conflict and the source
// would abandon its move as well: both sides resident. A delete removes the row
// outright, so the source's retry finds nothing, sends the file again and
// imports it afresh, and the delete is undone. The origin's port answers `Moved`
// only after its own row says so, and a retired source never holds the session
// again under that move, so one answer decides and there is no race to lose. The
// ask runs here, outside the registry's turn, because it crosses the network.
// Silence, an origin this daemon no longer lists, and any other answer say the
// session is not settled yet, and the caller refuses in the words of its own
// command: the owner asks again later.
fn inbound_settled(
  movers: session_movers.Control,
  registry: manager.Manager(instance),
  id: String,
) -> Result(Nil, Unsettled) {
  case manager.custody(registry, id) {
    Ok(catalogue.Imported(from:, ..)) ->
      case orchestrators.find(movers.orchestrators, from) {
        Ok(origin) ->
          case movers.holds(origin, id) {
            Ok(orchestrator_port.Moved(..)) -> Ok(Nil)
            Ok(orchestrator_port.Owned)
            | Ok(orchestrator_port.NotOwned)
            | Error(Nil) -> Error(Unsettled)
          }
        Error(Nil) -> Error(Unsettled)
      }
    Ok(catalogue.Resident)
    | Ok(catalogue.Moving(..))
    | Ok(catalogue.Moved(..))
    | Error(_) -> Ok(Nil)
  }
}

// The origin of an imported session has not said it retired the move. It is a
// value of its own so each command can name the refusal its contract has.
type Unsettled {
  Unsettled
}

/// The control command `sessions.create`, as a function of what it needs, so
/// the control socket and a home page's creation (`ui_socket.create_for`) run
/// one path. The caller must be the owner; the workspace is canonicalized on
/// the daemon's host; a configuration path is canonicalized and an empty one is
/// kept as the registration's own choice. The registry's own turn reserves the
/// identity under `request.request_key`, which is stable across a retry. Once
/// the session exists its canonical workspace is remembered among the owner's
/// recent folders (`manager.remember_folder`), so every surface that creates
/// feeds the list the home page offers.
///
/// The error is the control command's own code: `forbidden` for a caller that
/// is not the owner, `invalid_workspace` and `invalid_configuration` for a path
/// the host cannot canonicalize, and the registry's codes for the rest.
///
/// ## Examples
///
/// ```gleam
/// // server.create_session(config, registry, directory, owner, creation, domain.SessionOnly)
/// ```
@internal
pub fn create_session(
  config: Config(instance),
  registry: manager.Manager(instance),
  directory: String,
  principal: access.Principal,
  request: manager.Creation,
  scope: domain.Scope,
) -> Result(manager.View, String) {
  use Nil <- result.try(owner(principal))

  // A local workspace is a path on this host and is canonicalized here. A
  // registered one is a name that only the executor can resolve, so it is kept
  // exactly as sent and is never statted, canonicalized or created on this
  // host: the executor or the pool must be configured, and nothing more is asked
  // of it. A creation names one of the two, never both: a pool picks the
  // executor when the session first opens.
  use workspace <- result.try(case request.executor, request.pool {
    "", "" ->
      bootstrap.canonical_directory(request.workspace)
      |> result.replace_error("invalid_workspace")
    executor, "" ->
      case executors.find(config.executors, executor) {
        Ok(_) -> Ok(request.workspace)
        Error(Nil) -> Error(executor_unknown_code)
      }
    "", pool ->
      case pools.find(config.pools, pool) {
        Ok(_) -> Ok(request.workspace)
        Error(Nil) -> Error(pool_unknown_code)
      }
    _, _ -> Error("bad_request")
  })
  use configuration <- result.try(
    case request.configuration {
      // Absence is a registration choice, not the daemon's current path.
      // Canonicalizing it would replace inherited defaults with a directory.
      "" -> Ok("")
      path -> bootstrap.canonical_path(path)
    }
    |> result.replace_error("invalid_configuration"),
  )

  // A profile is judged against the configuration this session will load,
  // before an identity is reserved, so a mistyped name stores nothing. The
  // session's builder resolves it again on every open, which is what keeps a
  // later edit of the file from being silently ignored.
  use Nil <- result.try(case request.profile {
    None -> Ok(Nil)
    Some(name) ->
      profiles.check(
        profiles.effective(configuration, config.domain_configuration),
        name,
      )
      |> result.map_error(fn(refusal) {
        case refusal {
          profiles.UnknownProfile(_) -> unknown_profile_code
          profiles.UnusableConfiguration(_) -> unusable_configuration_code
        }
      })
  })
  use created <- result.map(
    manager.create_scoped(
      registry,
      manager.Creation(..request, workspace:, configuration:),
      directory:,
      generator: config.generator(),
      scope:,
      configuration: config.domain_configuration,
    )
    |> result.map_error(error_code),
  )

  // The folder is remembered once the session exists, under the canonical text
  // the catalogue holds, so the home can offer it again after every session in
  // it is gone (protocol-change/074). A creation that failed leaves no trace.
  // A registered name is no folder on this host, so it is never offered.
  case request.executor, request.pool {
    "", "" -> manager.remember_folder(registry, workspace)
    _, _ -> Nil
  }
  created
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
      use #(enrollment, issued) <- result.try(
        claim_enrollment(ttl_ms) |> result.replace_error("unavailable"),
      )
      Ok(#(enrollment, Some(Issued(issued, ttl_ms))))
    }
  }
}

/// Draws one claim token and the enrollment the catalogue stores for it: the
/// token's digest and an expiry `ttl_ms` from now, as a wall-clock instant.
/// This is the one place a claim is drawn. The control command's invitation
/// and a page's invitation (`ui_socket.invite_for`) both come here, so a claim
/// has the same entropy, shape and digest whichever asked. The token is the
/// caller's alone to hand on; only the digest goes to the registry.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(#(enrollment, token)) = server.claim_enrollment(3_600_000)
/// ```
@internal
pub fn claim_enrollment(
  ttl_ms: Int,
) -> Result(#(access.Enrollment, String), Nil) {
  let issued = claim.mint_token(token.production_entropy())
  use digest <- result.try(
    access.claim_digest(claim.digest(issued)) |> result.replace_error(Nil),
  )
  let expires_at_ms = bootstrap.system_time_ms() + ttl_ms
  Ok(#(access.ClaimEnrollment(digest, expires_at_ms), issued))
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

// A refused rename's code. A name the catalogue's display-name rule refuses is
// `invalid_name`, as a refused claim's is, and every other refusal is the
// administration's own.
fn rename_error_code(error) {
  case error {
    manager.AdminMetadata(catalogue.Invalid(_)) -> "invalid_name"
    manager.IsolationRequired
    | manager.AdminForbidden
    | manager.AdminStaleEpoch
    | manager.AdminUnavailable
    | manager.AdminForeignPath
    | manager.AdminBusy
    | manager.AdminMoving(..)
    | manager.AdminMoved(..)
    | manager.AdminNotMovable(..)
    | manager.AdminFailed(..)
    | manager.AdminMetadata(_) -> admin_error_code(error)
  }
}

fn admin_error_code(error) {
  case error {
    manager.IsolationRequired -> "isolation_required"
    manager.AdminForbidden -> "forbidden"
    manager.AdminStaleEpoch -> "stale_epoch"
    manager.AdminUnavailable -> "unavailable"
    manager.AdminForeignPath -> "unavailable"
    manager.AdminBusy -> "busy"
    manager.AdminMoving(..) -> "moving"
    manager.AdminMoved(..) -> not_owner_code
    manager.AdminNotMovable(..) -> "not_movable"
    manager.AdminFailed(..) -> "unavailable"
    manager.AdminMetadata(error) -> error_code(manager.Catalogue(error))
  }
}

// The move a session is in, if any, as members of its view
// (protocol-change/078, phase 5). A session that is not moving and has not moved
// carries neither, so its view is byte for byte what a daemon without moves
// sends. `moving` names the move and where it goes, and `moved` names where the
// session went; a session that is moving is also still stopped and `saved`.
fn with_custody(
  state: root.Ready(instance),
  id: String,
  body: JsonValue,
) -> JsonValue {
  case manager.custody(state.registry, id), body {
    Ok(catalogue.Moving(op:, to:)), json.Object(fields) ->
      json.Object(
        list.append(fields, [
          #(
            "moving",
            json.Object([
              #("op", json.String(op)),
              #("to", json.String(to)),
            ]),
          ),
        ]),
      )
    Ok(catalogue.Moved(to:, ..)), json.Object(fields) ->
      json.Object(
        list.append(fields, [
          #("moved", json.Object([#("to", json.String(to))])),
        ]),
      )
    _, _ -> body
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
          ..placement_fields(view.registration)
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
    #("logins", json.Int(row.logins)),
  ])
}

// One browser login as its principal's sign-in list shows it. The fingerprint
// identifies the login and authenticates nothing; the token is in the browser and
// on no row.
fn signin_json(row: access.Signin) -> JsonValue {
  json.Object(
    list.flatten([
      [
        #("fingerprint", json.String(row.fingerprint)),
        #("issued_at_ms", json.Int(row.issued_at_ms)),
      ],
      case row.last_resumed_ms {
        Some(at) -> [#("last_resumed_ms", json.Int(at))]
        None -> []
      },
      case row.expires_at_ms {
        Some(at) -> [#("expires_at_ms", json.Int(at))]
        None -> []
      },
      case row.issued_by {
        Some(parent) -> [#("issued_by", json.String(parent))]
        None -> []
      },
    ]),
  )
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

fn member_json(row: access.SessionMember) -> JsonValue {
  json.Object([
    #("principal_id", json.String(row.principal_id)),
    #("name", json.String(row.name)),
    #("role", json.String(role_text(row.role))),
  ])
}

pub fn view_json(view: manager.View) -> JsonValue {
  json.Object([
    #("session_id", json.String(view.registration.id)),
    #("workspace", json.String(view.registration.workspace)),
    #("name", json.String(view.registration.name)),
    #("created_at", json.Int(view.registration.created_at)),
    #("status", status_json(view.status)),
    ..list.append(
      subtitle_field(view.registration.subtitle),
      placement_fields(view.registration),
    )
  ])
}

// The optional `executor` and `pool` of `protocol-change/078`. A local session
// omits both fields, so its frame is byte-for-byte what a daemon without
// executors sent, and a client that does not know them reads the rest as before.
// A session in a pool has no executor until its first open chooses one, so it
// carries the pool alone until then.
fn placement_fields(
  registration: catalogue.Registration,
) -> List(#(String, JsonValue)) {
  list.append(
    named("executor", registration.executor),
    named("pool", registration.pool),
  )
}

fn named(key: String, name: String) -> List(#(String, JsonValue)) {
  case name {
    "" -> []
    present -> [#(key, json.String(present))]
  }
}

// The optional `subtitle` of `protocol-change/067`. A session with none omits
// the field, so a frame for it is byte-for-byte what an older daemon sent, and
// a client that does not know the field reads the rest as before.
fn subtitle_field(subtitle: Option(String)) -> List(#(String, JsonValue)) {
  case subtitle {
    Some(text) -> [#("subtitle", json.String(text))]
    None -> []
  }
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
    manager.SessionMoving(..) -> "moving"
    manager.SessionMoved(..) -> not_owner_code
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
        None -> fn() { Error(peer_mail.Refused("peer_service_unavailable")) }
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

/// The activity read a home page is handed: `activity_states` over the
/// sessions the page's credential holds. Membership is derived here, in the
/// registry, at the moment of each read, from the credential's digest and never
/// from the page's list, so a revoked credential or a removed membership reads
/// nothing from the next read on.
///
/// ## Examples
///
/// ```gleam
/// // server.home_activity(config, registry, digest)(["0198..."])
/// ```
@internal
pub fn home_activity(
  config: Config(instance),
  registry: manager.Manager(instance),
  digest: access.Digest,
) -> fn(List(String)) -> List(#(String, listed_sessions.Activity)) {
  // The control command refuses a list past `activity_limit`; this read has no
  // request to refuse, so it keeps the first ones and the bound holds here too.
  fn(ids) {
    let asked = list.take(ids, protocol.activity_limit)
    activity_states(config, registry, held(registry, digest, asked))
  }
}

// The identities among `ids` the credential holds a membership in, at any role,
// in their order. The owner holds every session in the catalogue. An identity
// the credential does not hold is dropped exactly as one the registry has never
// heard of is, so `activity` leaves both out the same way and a reply never
// tells a session that is not the caller's from one that is not running.
fn held(
  registry: manager.Manager(instance),
  digest: access.Digest,
  ids: List(String),
) -> List(String) {
  list.filter(ids, fn(id) {
    manager.session_authority(registry, digest, id) |> result.is_ok
  })
}

/// What the named sessions are doing, for a home page's list: the same read
/// the control command `sessions.activity` makes (`activity`, with its
/// deadline and its bound on a row), reduced to the one state word the page
/// draws for each session that answered. A session that was not running, did
/// not answer in time, or answered with a state the page does not know has no
/// entry. Only the state leaves the daemon here: the row's last message, model
/// and glances, which the control command hands the owner, are dropped, so the
/// page learns no more about a session than whether it works.
///
/// The caller names sessions from the page's own authorized list, at most 24
/// of them, and runs this off the page's runtime. It blocks for up to the
/// deadline.
///
/// ## Examples
///
/// ```gleam
/// // server.activity_states(config, registry, ["0198..."]) == [#("0198...", Working)]
/// ```
@internal
pub fn activity_states(
  config: Config(instance),
  registry: manager.Manager(instance),
  sessions: List(String),
) -> List(#(String, listed_sessions.Activity)) {
  activity(config, registry, sessions)
  |> list.filter_map(state_of)
}

// The session and the state a reply row names, when it names a state the page
// knows. The row's count of pending approvals tells a failed run from an
// escalation, as both are `needs_you` (`listed_sessions.activity_from`); a row
// that carries no count is taken at its word.
fn state_of(
  row: JsonValue,
) -> Result(#(String, listed_sessions.Activity), Nil) {
  case row {
    json.Object(fields) -> {
      use id <- result.try(text_field(fields, "session_id"))
      use state <- result.try(text_field(fields, "state"))
      let approvals = case list.key_find(fields, "approvals") {
        Ok(json.Int(count)) -> count
        Ok(_) | Error(Nil) -> 1
      }
      use doing <- result.map(listed_sessions.activity_from(state, approvals))
      #(id, doing)
    }
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(Nil)
  }
}

fn text_field(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(String, Nil) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
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

// The daemon's peer lookups, which the control commands and an owner's web
// page share so that both resolve a session the same way. A session resident
// here resolves to its Agency, and one a configured orchestrator owns resolves
// to that orchestrator's port (`peers.routed`); discovery is the catalogue's.
fn peer_directory(
  config: Config(instance),
  registry: manager.Manager(instance),
) -> peers.Directory {
  peers.Directory(
    resolve: peers.routed(
      fn(id) { peer_endpoint(config, registry, id) |> peer_mail.refused },
      config.directory,
    ),
    describe: fn(id) {
      manager.get(registry, id)
      |> result.map(view_json)
      |> result.map_error(error_code)
    },
  )
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
