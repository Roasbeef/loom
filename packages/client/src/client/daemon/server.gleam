//// Version-two routing separates daemon control from resident conversations.
////
//// Every upgrade authenticates a digest against the durable access catalogue.
//// Control requests repeat that check; membership and operation identities are
//// checked by the serialized registry. Session routing never opens a runtime.
//// The supplied conversation adapter must speak v2 and must not return before
//// its websocket process has attempted the parser reservation's transfer, or
//// the release here would race it; the legacy gateway is not an adapter.

import broker/token
import client/daemon/manager
import client/daemon/protocol
import client/daemon/root
import core/ids
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import mist
import storage/access
import storage/catalogue
import storage/domain

/// Capabilities owned by the daemon, not supplied over the wire.
pub type Config(instance) {
  Config(
    /// Lifetime owner and admission authority.
    daemon: root.Root(instance),
    /// Captured owner domain config reference; empty explicitly selects no file.
    domain_configuration: String,
    /// Fresh entropy-seeded generator for explicit creation.
    generator: fn() -> ids.Generator,
    /// A v2-only conversation adapter, responsible for transferring its permit.
    session_upgrade: fn(Request(mist.Connection), Attachment(instance)) ->
      Response(mist.ResponseData),
  )
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
    _ -> plain(404, "unknown endpoint")
  }
}

fn authenticated(config: Config(instance), request, target) {
  // A root which has fenced readiness cannot create another control or session
  // attachment, even when a previously read credential remains valid.
  let ready = root.ready(config.daemon, within: 1000)
  let identity = {
    use state <- result.try(ready)
    use digest <- result.try(credential(request))
    use principal <- result.try(
      manager.authenticate(state.registry, digest)
      |> result.replace_error("unauthorized"),
    )
    Ok(#(state, digest, principal))
  }
  case identity {
    Error(_) -> plain(401, "unauthorized or unavailable")
    Ok(#(state, digest, principal)) ->
      case target {
        None -> control_upgrade(config, request, state, digest, principal)
        Some(id) -> session_upgrade(config, request, state, digest, id)
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

fn session_upgrade(
  config: Config(instance),
  request,
  state: root.Ready(instance),
  digest,
  id,
) {
  // Resolve metadata first, then compare the observed incarnation in one actor
  // turn. A stop/reopen between those calls must refuse this upgrade.
  let target = {
    use _ <- result.try(
      ids.parse_session_id(id) |> result.replace_error(manager.Unavailable),
    )
    use #(principal, authority) <- result.try(manager.session_authority(
      state.registry,
      digest,
      id,
    ))
    use view <- result.try(manager.get(state.registry, id))
    use incarnation <- result.try(resident(view.status))
    use instance <- result.try(manager.resolve_incarnation(
      state.registry,
      id,
      incarnation,
    ))
    Ok(#(principal, authority, incarnation, instance))
  }
  case target {
    Error(_) -> plain(409, "session unavailable")
    Ok(#(principal, authority, incarnation, instance)) -> {
      let class = case authority {
        access.Participant(access.Observer) -> root.Observer
        access.Owner | access.Participant(access.Operator) -> root.Operator
      }
      case root.acquire(config.daemon, class, within: 1000) {
        Error(_) -> plain(503, "connection capacity unavailable")
        Ok(permit) -> {
          let #(connection_id, _) = ids.mint_op(config.generator())
          let response =
            config.session_upgrade(
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
              ),
            )
          root.release(config.daemon, permit)
          response
        }
      }
    }
  }
}

fn resident(status) {
  case status {
    manager.Resident(incarnation) -> Ok(incarnation)
    manager.Reserved
    | manager.Saved
    | manager.Opening(_)
    | manager.Stopping(_)
    | manager.RecoveryBlocked(_) -> Error(manager.Unavailable)
  }
}

fn control_upgrade(
  config: Config(instance),
  request,
  state: root.Ready(instance),
  digest,
  principal: access.Principal,
) {
  case root.acquire(config.daemon, root.Control, within: 1000) {
    Error(_) -> plain(503, "connection capacity unavailable")
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
                admit(config.daemon, permit, settled, fn() {
                  send(
                    socket,
                    protocol.event(
                      None,
                      "hello",
                      json.Object([
                        #("protocol", json.Int(2)),
                        #("epoch", json.String(state.epoch)),
                        #("principal", json.String(principal.id)),
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
                            #("connections", json.Int(root.max_connections)),
                            #(
                              "reserved_message_bytes",
                              json.Int(root.max_reserved_message_bytes),
                            ),
                          ]),
                        ),
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

// Takes the reserved permit in the control socket's first handler turn and
// then writes whatever the caller had waiting. `process.self()` is still the
// websocket process here, so the permit's new owner and the PID the root
// monitors are the ones the initializer would have named.
fn admit(
  daemon,
  permit,
  settled: process.Subject(Nil),
  then: fn() -> mist.Next(Nil, Signal),
) {
  let transferred = root.transfer(daemon, permit, within: 1000)

  // Custody is decided either way now, so the waiting HTTP process is released
  // before anything is written to the socket.
  process.send(settled, Nil)
  case transferred {
    // A failed transfer must not leave an unaccounted active socket actor. A
    // stop from a handler turn is terminal, and the root keeps its charge
    // until the DOWN, so the refusal frees nothing here.
    Error(_) -> mist.stop()
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
          |> result.replace_error("unavailable"),
        )
        use principal <- result.try(
          manager.authenticate(current.registry, digest)
          |> result.replace_error("unauthorized"),
        )
        dispatch(config, state, digest, principal, request.command)
      }
      case outcome {
        Ok(#(event, body)) -> {
          // Which commands drain the daemon after their acknowledgement is
          // written, enumerated for the reason `control_use` beside it is: a
          // second shutdown-shaped command must arrive with a compiler prompt
          // rather than inheriting "keep serving" from a catch-all.
          let after = case request.command {
            protocol.Shutdown(_) -> DrainDaemon
            protocol.Status
            | protocol.ListSessions(..)
            | protocol.GetSession(_)
            | protocol.WorkspaceDefault(_)
            | protocol.GetOperation(..)
            | protocol.SetDefault(..)
            | protocol.IsolateSession(..)
            | protocol.Invite(..)
            | protocol.SetRole(..)
            | protocol.RevokeMembership(..)
            | protocol.RotateCredential(..)
            | protocol.RevokeCredentials(..)
            | protocol.CreateSession(..)
            | protocol.OpenSession(..)
            | protocol.StopSession(..) -> KeepServing
          }
          #(protocol.event(Some(request.id), event, body), after)
        }
        Error(code) -> #(
          refusal(protocol.Fault(Some(request.id), code, "request refused")),
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
    | protocol.ListSessions(..)
    | protocol.GetSession(_)
    | protocol.WorkspaceDefault(_)
    | protocol.GetOperation(..) -> root.ControlRead
    protocol.SetDefault(..)
    | protocol.IsolateSession(..)
    | protocol.Invite(..)
    | protocol.SetRole(..)
    | protocol.RevokeMembership(..)
    | protocol.RotateCredential(..)
    | protocol.RevokeCredentials(..)
    | protocol.CreateSession(..)
    | protocol.OpenSession(..)
    | protocol.StopSession(..)
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

fn dispatch(
  config: Config(instance),
  state: root.Ready(instance),
  digest,
  principal,
  command,
) {
  // Owner-only filesystem choices are canonicalized on the host. Participant
  // authority is narrower: an operator may open a granted identity, but cannot
  // choose another workspace, configuration, or durable default.
  case command {
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
    protocol.Invite(session_id, id, name, role, supplied) -> {
      use Nil <- result.try(owner(principal))
      let bearer =
        token.production_entropy()(32)
        |> bit_array.base16_encode
        |> string.lowercase
      use credential <- result.try(
        bearer_digest(bearer)
        |> result.replace_error("unavailable"),
      )
      admin_result(
        state,
        digest,
        supplied,
        manager.Invite(id, name, credential, session_id, role),
        "sessions.invite",
        Some(bearer),
      )
    }
    protocol.RotateCredential(id, supplied) -> {
      use Nil <- result.try(owner(principal))
      let bearer =
        token.production_entropy()(32)
        |> bit_array.base16_encode
        |> string.lowercase
      use credential <- result.try(
        bearer_digest(bearer)
        |> result.replace_error("unavailable"),
      )
      admin_result(
        state,
        digest,
        supplied,
        manager.RotateMember(id, credential),
        "credentials.rotate",
        Some(bearer),
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
    protocol.ListSessions(after, revision) -> {
      use #(current, views) <- result.try(
        manager.authorized_page(state.registry, digest, after:)
        |> result.map_error(error_code),
      )
      use Nil <- result.try(check_revision(revision, current))
      use bounded <- result.try(page_prefix(views, 60_000, []))
      Ok(#("sessions.list", page_body(bounded, current)))
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
        bootstrap.canonical_path(configuration)
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

fn bearer_digest(bearer) {
  bearer
  |> bit_array.from_string
  |> bootstrap.sha256
  |> bit_array.base16_encode
  |> string.lowercase
  |> access.credential_digest
}

// Only an explicitly successful secret-producing mutation returns a bearer.
// Refusals use fixed codes and never stringify a request or durable error.
fn admin_result(
  state: root.Ready(instance),
  digest,
  epoch,
  action,
  event,
  bearer,
) {
  use principal <- result.try(
    manager.administer(state.registry, digest, epoch, action)
    |> result.map_error(admin_error_code),
  )
  let fields = [
    #("principal_id", json.String(principal.id)),
    #("name", json.String(principal.display_name)),
  ]
  let fields = case bearer {
    None -> fields
    Some(value) -> [#("bearer", json.String(value)), ..fields]
  }
  Ok(#(event, json.Object(fields)))
}

fn admin_error_code(error) {
  case error {
    manager.IsolationRequired -> "isolation_required"
    manager.AdminForbidden -> "forbidden"
    manager.AdminStaleEpoch -> "stale_epoch"
    manager.AdminUnavailable -> "unavailable"
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

fn view_json(view: manager.View) -> JsonValue {
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
    manager.StartFailed -> "start_failed"
    manager.Capacity -> "capacity"
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
