//// The workspace half of a registered session, as the orchestrator holds it
//// (protocol-change/078, "One workspace plane, two placements").
////
//// A session registered on an executor has no checkout on this machine. Its
//// conversation half is assembled here exactly as a local session's is, and
//// this module supplies the other half: a `WorkspacePlane` of the same shape
//// a local start returns, whose functions are answered by the executor. The
//// assembly reads that plane and does not know which placement it holds.
////
//// ## What an open does
////
//// `attach` runs once per session open, in this order, and each step is
//// there because the next one needs it.
////
//// 1. The peer is connected, so a dead executor fails the open before any
////    state is touched. The failure keeps the `executor_unavailable:` prefix
////    an operator already greps for.
//// 2. The incarnation is chosen from the scope record in the session's own
////    store (`client/remote/scope`).
//// 3. The owner port starts over the same `OwnerServices` a local session
////    builds, because the executor's workspace calls back through it.
//// 4. The surface attaches with a fresh token. Every strand and every runtime
////    restart inside this open shares that one surface and token. A second
////    attach would rotate the token and make the executor refuse another
////    strand's live `Run`, so nothing below this module attaches again;
////    orphaned calls are settled through the executor's per-key fence.
//// 5. The attach is recorded in the scope record, and the plane is built from
////    the census the attach returned.
////
//// ## Two clocks
////
//// The orchestrator and the executor do not agree on the time. The runner of
//// an imported hook, the goal check and the Git observations put an absolute
//// deadline into the `CallSpec` they send to the executor's broker, and the
//// broker compares it with its own clock. `Hands.clock` is this machine's
//// clock shifted by the difference the attach measured, so those callers read
//// the executor's timebase and a deadline means the same instant at both ends.
//// The skew is measured once and includes one half of the attach's round
//// trip; deadlines are seconds long, so that error does not matter.
////
//// ## Close
////
//// `Hands.plane.close` asks the executor to close the scope, records the
//// outcome the executor reports, and ends the owner port. A close the
//// executor does not answer leaves the record as it was: the scope is then
//// still open on the executor and the next open rebinds it, which is correct,
//// and failing the session's cleanup over an unreachable machine would only
//// keep the reservation held.

import broker/broker
import client/distribution
import client/executors
import client/jobs
import client/jobstate
import client/owner_services.{type OwnerServices}
import client/remote/address.{type Address}
import client/remote/owner_port
import client/remote/protocol.{type Key}
import client/remote/remote_census.{type RemoteCensus}
import client/remote/scope
import client/remote/surface
import client/tool_placement
import client/wiring
import client/workspace_plane.{type WorkspacePlane}
import core/clock.{type Clock}
import core/ids
import core/json.{type JsonValue}
import core/register
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/operation
import runtime/effects.{type Recovery, type ToolRun}
import session/session.{type Session}
import storage/storage
import tools/tool

/// How an orchestrator reaches one executor.
pub type Reach {
  Reach(
    /// The executor's host.
    address: Address(RemoteCensus),
    /// Makes the connection to the executor, or says why it cannot. It is
    /// called before the attach and again whenever the surface repairs a
    /// dropped connection.
    connect: fn() -> Result(Nil, String),
    /// How long the attach keeps trying.
    attach_within_ms: Int,
  )
}

/// What an open needs to assemble the workspace half.
pub type Registered {
  Registered(
    /// The executor.
    reach: Reach,
    /// The orchestrator's session id, which keys the executor's ledger.
    session: String,
    /// The workspace's registered name. It is carried to the executor and
    /// never opened here.
    workspace: String,
    /// The session's store, for the scope record, the stored authority and the
    /// settled calls.
    opened: Session,
    /// The session's owner services, which the owner port answers with.
    owner: OwnerServices,
    /// This machine's clock.
    clock: Clock,
    /// How often the owner port asks the executor which results it still
    /// holds.
    reconcile_every_ms: Int,
  )
}

/// The workspace half of a session, attached.
pub type Hands {
  Hands(
    /// What the assembly reads of the workspace, with the same shape as a
    /// local plane.
    plane: WorkspacePlane,
    /// The workspace's tools in the executor's registration order.
    tools: List(tool.Described),
    /// This machine's clock shifted onto the executor's timebase. Pass it to
    /// every non-tool caller that builds an absolute deadline.
    clock: Clock,
    /// The incarnation this open attached at.
    incarnation: Int,
    /// `ToolSurface.recover` for the session. A workspace tool asks the
    /// executor; an owner tool is judged by its replay policy alone, as it is
    /// in a session with no recovery.
    recover: fn(ToolRun) -> Recovery,
    /// Unlinks the owner port from the process that started it. Custody calls
    /// this once it holds the cleanup, so the port outlives the builder.
    transfer: fn() -> Nil,
  )
}

// How long a close waits for the executor, which retires the scope's helpers
// before it answers.
const close_within_ms = 60_000

/// Connects to the executor, attaches the session's scope and builds the
/// workspace half from the census.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(hands) = workspace.attach(registered)
/// ```
pub fn attach(registered: Registered) -> Result(Hands, String) {
  let reach = registered.reach
  use Nil <- result.try(
    reach.connect()
    |> result.map_error(fn(reason) { unavailable(reason) }),
  )
  use stored <- result.try(scope.read(registered.opened))
  let incarnation = scope.attach_at(stored)
  use port <- result.try(
    owner_port.start(owner_port.Config(
      services: registered.owner,
      clock: registered.clock,
      settled: fn(key) { settled(registered.opened, key) },
      reconcile_every_ms: registered.reconcile_every_ms,
    ))
    |> result.map_error(unavailable),
  )
  let attached =
    surface.attach(surface.Config(
      address: reach.address,
      session: registered.session,
      workspace: registered.workspace,
      incarnation:,
      port:,
      read_authority: fn(run) { wiring.read_authority(registered.opened, run) },
      reconnect: reach.connect,
      remote_tools: tool_placement.workspace_names,
      attach_within_ms: reach.attach_within_ms,
      mint_token: surface.strong_token,
    ))
  let received = clock.read(registered.clock).0
  case attached {
    Error(refusal) -> {
      owner_port.stop(port)
      Error(refused(refusal, incarnation))
    }
    Ok(surface.Attachment(surface: attached, attached: reply)) ->
      case scope.write(registered.opened, scope.Scope(incarnation, None)) {
        Error(reason) -> {
          owner_port.stop(port)
          Error(unavailable(reason))
        }
        Ok(Nil) ->
          Ok(build(
            registered,
            port,
            incarnation,
            surface.functions(attached),
            reply.census,
            received,
          ))
      }
  }
}

fn build(
  registered: Registered,
  port: owner_port.Port,
  incarnation: Int,
  functions: surface.Functions,
  remote: RemoteCensus,
  received_at_ms: Int,
) -> Hands {
  let executor_clock =
    rebased(
      registered.clock,
      executor_now_ms: remote.executor_now_ms,
      local_now_ms: received_at_ms,
    )
  let opened = registered.opened
  Hands(
    plane: workspace_plane.WorkspacePlane(
      // `run_placed` read this call's authority to route it, and the surface
      // reads it again to send it; the surface owns the send, so the copy
      // handed in here is not used.
      run: fn(run, _authority) { functions.run(run) },
      broker: broker.over(remote.broker, executor_clock),
      census: remote.census,
      prompt_facts: fn() { Ok(remote.prompt) },
      resolve_directory: fn(_requested, _mode) {
        Error(
          "operator directory additions are not supported for a workspace "
          <> "on an executor yet",
        )
      },
      live_jobs: fn(strand) { live_jobs(opened, strand, executor_clock) },
      // The surface is a stub that reconnects by itself, so a partition is
      // not a fault of the session and nothing here is a fatal root.
      fatal: [],
      close: fn() {
        close_scope(registered, incarnation)
        owner_port.stop(port)
      },
    ),
    tools: remote.tools,
    clock: executor_clock,
    incarnation:,
    recover: recover_by_placement(functions),
    transfer: fn() {
      case process.subject_owner(owner_port.inbox(port)) {
        Ok(pid) -> process.unlink(pid)
        Error(Nil) -> Nil
      }
    },
  )
}

/// This machine's clock shifted by the executor's reading at the attach.
///
/// ## Examples
///
/// ```gleam
/// // 10 s ahead: a local reading of 1_000 is 11_000 on the executor.
/// assert clock.read(workspace.rebased(clock.fixed(at: 1000), executor_now_ms: 15_000, local_now_ms: 5000)).0
///   == 11_000
/// ```
pub fn rebased(
  local: Clock,
  executor_now_ms executor_now_ms: Int,
  local_now_ms local_now_ms: Int,
) -> Clock {
  let offset = executor_now_ms - local_now_ms
  clock.from_function(fn() { clock.read(local).0 + offset })
}

/// Reads the executor for an `[executors.<name>]` of this daemon, or says why
/// it cannot be reached.
///
/// A name the daemon has not configured, or one whose node is not a peer the
/// daemon pinned, is refused with the `executor_unavailable:` prefix, as is a
/// daemon that never started distribution.
///
/// ## Examples
///
/// ```gleam
/// // workspace.reach(Some(membership), configured, "build-box")
/// ```
pub fn reach(
  membership: Option(distribution.Membership),
  configured: List(executors.Executor),
  name: String,
) -> Result(Reach, String) {
  use membership <- result.try(option.to_result(
    membership,
    unavailable("this daemon was not started with [distribution]"),
  ))
  use executor <- result.try(
    executors.find(configured, name)
    |> result.replace_error(unavailable(
      "no executor named " <> name <> " is configured",
    )),
  )
  use peer <- result.try(
    distribution.peer(membership, executor.node)
    |> result.map_error(fn(fault) { unavailable(distribution.describe(fault)) }),
  )
  Ok(Reach(
    address: address.Address(
      node: distribution.node(peer),
      name: address.default(),
    ),
    connect: fn() {
      distribution.connect(peer, connect_within_ms)
      |> result.map_error(distribution.describe)
    },
    attach_within_ms: attach_within_ms,
  ))
}

const connect_within_ms = 10_000

const attach_within_ms = 30_000

fn unavailable(reason: String) -> String {
  "executor_unavailable: " <> reason
}

// An attach the executor refused. A stale incarnation means the record in this
// store and the executor's ledger disagree about how often the scope has been
// reopened; retrying cannot reconcile them, so the open fails and says both
// numbers.
fn refused(refusal: protocol.Refusal, attempted: Int) -> String {
  case refusal {
    protocol.StaleIncarnation(stored:) ->
      unavailable(
        "this session's record attaches at incarnation "
        <> int.to_string(attempted)
        <> " but the executor's scope is at incarnation "
        <> int.to_string(stored)
        <> "; the record is missing or out of step with the executor",
      )
    other -> unavailable(protocol.describe(other))
  }
}

// A workspace tool is recovered by the executor's ledger. An owner tool never
// reached the executor, so its answer is the one a session with no recovery
// gives: a call that is safe to repeat is offered for replay, and any other is
// unknown.
fn recover_by_placement(
  functions: surface.Functions,
) -> fn(ToolRun) -> Recovery {
  fn(run: ToolRun) {
    case tool_placement.placement(run.call.name) {
      Ok(tool_placement.WorkspaceSide) -> functions.recover(run)
      Ok(tool_placement.OwnerSide) | Error(Nil) ->
        case run.replay {
          operation.ReplaySafe -> effects.NotStarted
          operation.ReplayNever -> effects.OutcomeUnknown
        }
    }
  }
}

// --- settled calls --------------------------------------------------------------

// Whether this session no longer holds the call pending, so the executor's row
// for it may go. A call is pending only while the operation's batch for that
// step still lists it as planned or running. Everything else is settled: its
// result is staged or placed, it was interrupted or aborted and the runtime
// staged that, or the operation is over and its state deleted. A key the store
// cannot answer is left alone.
@internal
pub fn settled(opened: Session, key: Key) -> Bool {
  case ids.parse_op_id(key.op) {
    Error(_report) -> False
    Ok(operation) ->
      case session.op_state(opened, operation) {
        Error(_error) -> False
        Ok(None) -> True
        Ok(Some(cell)) -> !pending(cell.value, key.step, key.source_index)
      }
  }
}

@internal
pub fn pending(
  state: operation.OperationState,
  step: String,
  index: Int,
) -> Bool {
  case state {
    operation.RunState(phase: operation.Tools(batch:), ..)
      if batch.turn_id == step
    ->
      list.any(batch.calls, fn(call) {
        case call {
          operation.CallPlanned(source_index:, ..)
          | operation.CallEffectPending(source_index:, ..) ->
            source_index == index
          operation.CallOutcomeReady(..) | operation.CallCompleted(..) -> False
        }
      })
    _ -> False
  }
}

// --- jobs -----------------------------------------------------------------------

// The jobs actor runs beside the checkout, and every record it writes is also
// a `job/<id>` cell here, so the live board is read from the store instead of
// asked of the executor. A record that does not decode is skipped, as it would
// be by the actor's own sweep.
fn live_jobs(
  opened: Session,
  strand: String,
  executor_clock: Clock,
) -> Result(JsonValue, String) {
  use cells <- result.map(
    storage.list_registers(
      opened.store,
      register.FactCustom,
      Some(jobstate.key_prefix),
    )
    |> result.map_error(string.inspect),
  )
  let records =
    list.filter_map(cells, fn(cell) {
      let #(_key, held) = cell
      jobstate.decode(held.value.payload) |> result.replace_error(Nil)
    })
  jobs.live_board_of(records, strand, clock.read(executor_clock).0)
}

// --- close ----------------------------------------------------------------------

// Asks the executor to close the scope and records what it reports. An answer
// that is a refusal, or no answer, records nothing.
fn close_scope(registered: Registered, incarnation: Int) -> Nil {
  case ask_close(registered, incarnation, 2) {
    Ok(closed) -> {
      let _written =
        scope.write(registered.opened, scope.Scope(incarnation, Some(closed)))
      Nil
    }
    Error(Nil) -> Nil
  }
}

fn ask_close(
  registered: Registered,
  incarnation: Int,
  attempts: Int,
) -> Result(protocol.CloseOutcome, Nil) {
  let reach = registered.reach
  let reply = process.new_subject()
  let watch = address.watch(reach.address)
  address.deliver(
    reach.address,
    protocol.Close(
      session: registered.session,
      workspace: registered.workspace,
      incarnation:,
      reply:,
    ),
  )
  let heard =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(watch, fn(_down) { Error(Nil) })
    |> process.selector_receive(close_within_ms)
  process.demonitor_process(watch)
  case heard {
    Ok(Ok(Ok(closed))) -> Ok(closed)
    Ok(Ok(Error(_refusal))) -> Error(Nil)

    // The host went away first. One reconnect and one more ask: a close that
    // already landed answers with a refusal, which records nothing.
    Ok(Error(Nil)) ->
      case attempts > 1, reach.connect() {
        True, Ok(Nil) -> ask_close(registered, incarnation, attempts - 1)
        _, _ -> Error(Nil)
      }
    Error(Nil) -> Error(Nil)
  }
}
