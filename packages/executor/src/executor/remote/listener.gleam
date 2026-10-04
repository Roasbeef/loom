//// Fixed ingress credits retain service custody beyond socket deadlines.
////
//// Each Temporary listener actor owns one relayed socket run and at most one
//// outstanding typed service ask. Native Hello and operation are serial asks;
//// workspace transfers make one ask after their complete bounded decode. The
//// socket deadline kills and joins its worker, but only an actual service reply
//// or confirmed service death resolves queued custody. A credit accepts again
//// only after both facts settle. At most four asks reach the service, even when
//// it stops consuming and peers repeatedly exhaust short socket deadlines.
////
//// The private request subjects belong to the credit, not the socket worker.
//// Final run delivery proves the worker has stopped sending. Already delivered
//// handoffs are reduced before reuse; a late handoff still passes the NoAsk
//// guard, and a second unresolved handoff retires the credit. This protects the
//// bound without assuming ordering across the worker and report senders.
//// Lost run proof, uncertain downstream custody or service death closes credit. Neither acceptors nor their subtree restart automatically:
//// an owner may reconstruct admission only after service death or explicit drain.
////
//// The embedding host closes listener admission before stopping this subtree
//// and separately drains effect/native custody before releasing its journals.
//// Socket death, acceptor death and service reply establish no native retirement.
////
//// <!-- transitions: listener.Pending -->
////
//// | state | decoded request | service reply | network final | service death |
//// | --- | --- | --- | --- | --- |
//// | `NoAsk` | retain one ask and send | fail closed | drain queued handoff, then accept | stop credit |
//// | `NativeAsk` | fail closed | forward; uncertain retires, otherwise clear ask | retain ask | stop credit |
//// | `WorkspaceAsk` | fail closed | forward; uncertain retires, otherwise clear ask | retain ask | stop credit |

import executor/remote/connection
import executor/remote/service
import executor/remote/tls
import executor/remote/wire
import executor/remote/workspace_connection
import executor/remote/workspace_journal
import executor/remote/workspace_service
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import weft
import weft/actor

/// Validated connection capacity and a finite whole-exchange deadline.
pub opaque type Config {
  Config(
    listener: tls.Listener,
    endpoint: Endpoint,
    workers: Int,
    within_ms: Int,
  )
}

// The closed choice reuses the same connection credits and supervision for
// native dispatch and semantic workspace calls, without arbitrary handlers.
type Endpoint {
  Native(service.Service)
  Workspace(workspace_connection.Server)
}

/// Configuration refusal occurs before any accepting process exists.
pub type Error {
  /// More than four concurrent frames would exceed the service's admission plan.
  InvalidCapacity

  /// Every accepted socket must have a bounded lifetime, including handshake.
  InvalidDeadline
}

type Pending {
  NoAsk
  NativeAsk(connection.Request)
  WorkspaceAsk(workspace_connection.Request)
}

type State {
  State(
    config: Config,
    native_requests: process.Subject(connection.Request),
    workspace_requests: process.Subject(workspace_connection.Request),
    native_reply: process.Subject(Result(wire.Body, service.Error)),
    workspace_reply: process.Subject(
      Result(workspace_journal.Status, workspace_service.Error),
    ),
    selector: process.Selector(Message),
    network: Option(process.Subject(weft.Pulled(Nil, Nil))),
    pending: Pending,
  )
}

type Message {
  Accept
  NativeRequest(connection.Request)
  WorkspaceRequest(workspace_connection.Request)
  NativeReply(Result(wire.Body, service.Error))
  WorkspaceReply(Result(workspace_journal.Status, workspace_service.Error))
  NetworkReport(weft.Pulled(Nil, Nil))
  ServiceDown
}

/// Validates the fixed pool before it enters the host's supervision tree.
///
/// ## Examples
///
/// ```gleam
/// // listener.configure(tls_listener, service, workers: 4, within_ms: 5000)
/// ```
pub fn configure(
  listener: tls.Listener,
  executor: service.Service,
  workers workers: Int,
  within_ms within_ms: Int,
) -> Result(Config, Error) {
  configured(listener, Native(executor), workers, within_ms)
}

/// Applies the same fixed connection budget to a semantic workspace endpoint.
///
/// ## Examples
///
/// `configure_workspace(listener, server, 4, 5000)` admits four bounded readers.
pub fn configure_workspace(
  listener: tls.Listener,
  server: workspace_connection.Server,
  workers workers: Int,
  within_ms within_ms: Int,
) -> Result(Config, Error) {
  configured(listener, Workspace(server), workers, within_ms)
}

fn configured(
  listener: tls.Listener,
  endpoint: Endpoint,
  workers: Int,
  within_ms: Int,
) -> Result(Config, Error) {
  case workers >= 1 && workers <= 4, within_ms >= 100 && within_ms <= 30_000 {
    False, _ -> Error(InvalidCapacity)
    True, False -> Error(InvalidDeadline)
    True, True -> Ok(Config(listener:, endpoint:, workers:, within_ms:))
  }
}

/// Describes the bounded acceptor subtree for the embedding host's supervisor.
///
/// A lost credit stays lost until the enclosing owner drains or destroys its
/// service. Automatically replacing either child or subtree could admit another
/// ask while the old child's service message remains queued.
///
/// ## Examples
///
/// ```gleam
/// // supervisor.new(supervisor.OneForOne)
/// // |> supervisor.add(listener.supervised(config))
/// // |> supervisor.start
/// ```
pub fn supervised(
  config: Config,
) -> supervision.ChildSpecification(supervisor.Supervisor) {
  list.repeat(Nil, times: config.workers)
  |> list.fold(
    supervisor.new(supervisor.OneForOne)
      |> supervisor.restart_tolerance(intensity: 4, period: 10),
    fn(tree, _) {
      let child =
        builder(config)
        |> actor.supervised
        |> supervision.restart(supervision.Temporary)
        |> supervision.timeout(1000)
      supervisor.add(tree, child)
    },
  )
  |> supervisor.supervised
  |> supervision.restart(supervision.Temporary)
}

fn builder(config: Config) -> actor.Builder(State, Message, Nil) {
  actor.new_with_initialiser(1000, fn(subject) {
    let native_requests = process.new_subject()
    let workspace_requests = process.new_subject()
    let native_reply = process.new_subject()
    let workspace_reply = process.new_subject()
    let pid = case config.endpoint {
      Native(executor) -> service.pid(executor)
      Workspace(server) -> workspace_connection.service_pid(server)
    }

    // The monitor is installed before any request can be sent to this service.
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_map(native_requests, NativeRequest)
      |> process.select_map(workspace_requests, WorkspaceRequest)
      |> process.select_map(native_reply, NativeReply)
      |> process.select_map(workspace_reply, WorkspaceReply)
      |> process.select_specific_monitor(process.monitor(pid), fn(_) {
        ServiceDown
      })
    Ok(
      actor.initialised(State(
        config,
        native_requests,
        workspace_requests,
        native_reply,
        workspace_reply,
        selector,
        None,
        NoAsk,
      ))
      |> actor.selecting(selector)
      |> actor.continuing(Accept),
    )
  })
  |> actor.on_message(handle)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Accept -> begin_accept(state)
    NativeRequest(request) -> admit_native(state, request)
    WorkspaceRequest(request) -> admit_workspace(state, request)
    NativeReply(reply) -> native_replied(state, reply)
    WorkspaceReply(reply) -> workspace_replied(state, reply)
    NetworkReport(weft.PulledOutcome(_)) | NetworkReport(weft.NotYet) ->
      actor.continue(state)
    NetworkReport(weft.AllDelivered) -> network_finished(state)

    // No final witness means no new credit, even if a socket appears dead.
    NetworkReport(weft.RunLost(_)) | ServiceDown -> actor.stop()
  }
}

fn native_replied(
  state: State,
  reply: Result(wire.Body, service.Error),
) -> actor.Next(State, Message) {
  case state.pending {
    NativeAsk(request) -> {
      connection.respond(request, reply)

      // The service may have abandoned a downstream journal ask. Its error is
      // no consumption witness for those queued bytes, so this credit retires.
      case reply {
        Error(service.Uncertain) -> actor.stop()
        Ok(_)
        | Error(service.Invalid)
        | Error(service.Capacity)
        | Error(service.Expired) ->
          continue_or_accept(State(..state, pending: NoAsk))
      }
    }
    NoAsk | WorkspaceAsk(_) -> actor.stop()
  }
}

fn workspace_replied(
  state: State,
  reply: Result(workspace_journal.Status, workspace_service.Error),
) -> actor.Next(State, Message) {
  case state.pending {
    WorkspaceAsk(request) -> {
      workspace_connection.respond(request, reply)

      // Unknown is valid retained execution evidence. Only a lost downstream
      // custody answer retires admission; it must never be confused with Unknown.
      case reply {
        Error(workspace_service.Uncertain)
        | Error(workspace_service.Custody(workspace_journal.Uncertain)) ->
          actor.stop()
        Ok(_)
        | Error(workspace_service.InvalidConfiguration)
        | Error(workspace_service.InvalidInput)
        | Error(workspace_service.ScopeMismatch)
        | Error(workspace_service.Capacity)
        | Error(workspace_service.Custody(_))
        | Error(workspace_service.Closing) ->
          continue_or_accept(State(..state, pending: NoAsk))
      }
    }
    NoAsk | NativeAsk(_) -> actor.stop()
  }
}

fn begin_accept(state: State) -> actor.Next(State, Message) {
  case state.network, state.pending {
    None, NoAsk -> {
      let reports = process.new_subject()
      let config = state.config
      let native_requests = state.native_requests
      let workspace_requests = state.workspace_requests
      let _relay =
        weft.new([
          fn() {
            case config.endpoint {
              Native(executor) ->
                connection.serve_relayed(
                  config.listener,
                  executor,
                  native_requests,
                )
                |> result.replace_error(Nil)
              Workspace(server) ->
                workspace_connection.serve_relayed(
                  config.listener,
                  server,
                  workspace_requests,
                )
                |> result.replace_error(Nil)
            }
          },
        ])
        |> weft.deadline(config.within_ms)
        |> weft.cancel_when_exits(process.self())
        |> weft.start_relayed(to: reports)
      let selector = process.select_map(state.selector, reports, NetworkReport)
      actor.continue(State(..state, network: Some(reports), selector:))
      |> actor.with_selector(selector)
    }
    Some(_), NoAsk
    | None, NativeAsk(_)
    | None, WorkspaceAsk(_)
    | Some(_), NativeAsk(_)
    | Some(_), WorkspaceAsk(_)
    -> actor.stop()
  }
}

fn admit_native(
  state: State,
  request: connection.Request,
) -> actor.Next(State, Message) {
  case state.config.endpoint, state.pending {
    Native(executor), NoAsk -> {
      connection.dispatch(request, executor, state.native_reply)
      actor.continue(State(..state, pending: NativeAsk(request)))
    }
    Workspace(_), NoAsk
    | Native(_), NativeAsk(_)
    | Native(_), WorkspaceAsk(_)
    | Workspace(_), NativeAsk(_)
    | Workspace(_), WorkspaceAsk(_)
    -> actor.stop()
  }
}

fn admit_workspace(
  state: State,
  request: workspace_connection.Request,
) -> actor.Next(State, Message) {
  case state.config.endpoint, state.pending {
    Workspace(server), NoAsk -> {
      workspace_connection.dispatch(request, server, state.workspace_reply)
      actor.continue(State(..state, pending: WorkspaceAsk(request)))
    }
    Native(_), NoAsk
    | Native(_), NativeAsk(_)
    | Native(_), WorkspaceAsk(_)
    | Workspace(_), NativeAsk(_)
    | Workspace(_), WorkspaceAsk(_)
    -> actor.stop()
  }
}

fn network_finished(state: State) -> actor.Next(State, Message) {
  case state.network {
    None -> actor.stop()
    Some(reports) -> {
      let selector = process.deselect(state.selector, reports)
      let next = State(..state, network: None, selector:)

      // A final report joins the worker, but comes from a different sender.
      // Drain handoffs already delivered; the NoAsk guard still bounds a late
      // handoff, retiring the credit if another unresolved ask already owns it.
      case state.config.endpoint {
        Native(_) ->
          case process.receive(state.native_requests, 0) {
            Ok(request) ->
              admit_native(next, request) |> actor.with_selector(selector)
            Error(Nil) -> continue_or_accept(next)
          }
        Workspace(_) ->
          case process.receive(state.workspace_requests, 0) {
            Ok(request) ->
              admit_workspace(next, request) |> actor.with_selector(selector)
            Error(Nil) -> continue_or_accept(next)
          }
      }
    }
  }
}

fn continue_or_accept(state: State) -> actor.Next(State, Message) {
  let next = actor.continue(state) |> actor.with_selector(state.selector)
  case state.network, state.pending {
    None, NoAsk -> next |> actor.then_handle(Accept)
    Some(_), NoAsk
    | None, NativeAsk(_)
    | None, WorkspaceAsk(_)
    | Some(_), NativeAsk(_)
    | Some(_), WorkspaceAsk(_)
    -> next
  }
}
