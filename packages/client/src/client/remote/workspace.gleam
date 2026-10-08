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
//// 1. The candidates are chosen from the scope record in the session's own
////    store (`client/remote/scope`). A record that names an executor makes it
////    the only candidate, ever. With no record, a session on one executor has
////    that executor, and a session in a pool has the pool's executors in the
////    order the configuration lists them.
//// 2. The candidate's peer is connected, so a dead executor fails before any
////    state is touched. The failure keeps the `executor_unavailable:` prefix an
////    operator already greps for.
//// 3. The record is written, naming the executor and the incarnation chosen
////    from it (`scope.attach_at`). It is written before the attach is sent, so
////    an attach whose reply is lost leaves the orchestrator knowing which
////    machine may hold the scope. The next open goes back to that machine, and
////    the ledger's rebind makes the retry converge.
//// 4. The owner port starts over the same `OwnerServices` a local session
////    builds, because the executor's workspace calls back through it.
//// 5. The surface attaches with a fresh token. Every strand and every runtime
////    restart inside this open shares that one surface and token. A second
////    attach would rotate the token and make the executor refuse another
////    strand's live `Run`, so nothing below this module attaches again;
////    orphaned calls are settled through the executor's per-key fence.
//// 6. The census the attach returned is compared with what the operator
////    declared for the executor. A contradiction closes the scope, which frees
////    its slot, and fails the open naming both values.
//// 7. The plane is built from the census, and the placement is told which
////    executor holds the session so the catalogue can show it. This happens
////    after every successful attach, because an earlier open whose reply was
////    lost may have named the executor in the record without the catalogue
////    hearing of it.
////
//// ## When another executor is tried
////
//// Only the first open of a session ever has more than one candidate, and it
//// goes to the next candidate in two cases, both of which prove no scope exists
//// anywhere: the connection to a candidate failed before the attach was sent,
//// or the executor answered that it already holds its limit of scopes. The
//// ledger refuses for capacity inside the attach transaction and before any
//// plane is built, so the checkout was never touched. The record is removed
//// again after such a refusal, so the next open starts from the same candidates.
////
//// Everything else fails the open and leaves the record naming its executor:
//// an attach that got no answer may have created the scope, a refusal for
//// another reason came from a machine that has or had the session, and a scope
//// that was created but whose plane failed to build is the session's. A
//// capacity refusal on a later open is the same failure, not a reason to move,
//// because the session's checkout exists only on the executor the record names.
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
import client/pools
import client/remote/address.{type Address}
import client/remote/owner_port
import client/remote/protocol.{type HostMessage, type Key}
import client/remote/remote_census.{type RemoteCensus}
import client/remote/scope.{type Scope}
import client/remote/surface
import client/system_prompt
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
    address: Address(HostMessage(RemoteCensus)),
    /// Makes the connection to the executor, or says why it cannot. It is
    /// called before the attach and again whenever the surface repairs a
    /// dropped connection.
    connect: fn() -> Result(Nil, String),
    /// How long the attach keeps trying.
    attach_within_ms: Int,
  )
}

/// One executor an open may attach to: its configured row, which carries what
/// the operator declared about the machine, and how to reach it.
pub type Candidate {
  Candidate(
    /// The `[executors.<name>]` row.
    executor: executors.Executor,
    /// How to reach it.
    reach: Reach,
  )
}

/// Where a session's workspace may be placed, as an open asks about it.
///
/// Three questions, each a function so that the configuration, the membership
/// and the catalogue stay on the daemon's side of this module.
pub type Placement {
  Placement(
    /// The candidates for a session that has no scope record yet, in the order
    /// they are tried, or why there are none. It is asked only when the record
    /// is absent, so a session that already has an executor never consults a
    /// pool that has since changed.
    first: fn() -> Result(List(Candidate), String),
    /// The candidate for a configured executor by name, for a scope record that
    /// names one. The executor need not still be in the pool.
    named: fn(String) -> Result(Candidate, String),
    /// Told the name of the executor that holds the session after each attach
    /// that succeeded. The daemon writes it into the catalogue, which keeps the
    /// first one it is given.
    chosen: fn(String) -> Nil,
  )
}

/// What an open needs to assemble the workspace half.
pub type Registered {
  Registered(
    /// Where the workspace may be placed.
    placement: Placement,
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

// Why one candidate did not hold the session.
type Attempt {
  // The candidate provably created no scope, and the open may try the next one.
  // `reason` says why, with no executor prefix.
  Declined(executor: String, reason: String)

  // The open fails with this reason, already worded for the operator.
  Failed(reason: String)
}

/// Chooses an executor, attaches the session's scope to it and builds the
/// workspace half from the census.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(hands) = workspace.attach(registered)
/// ```
pub fn attach(registered: Registered) -> Result(Hands, String) {
  use stored <- result.try(scope.read(registered.opened))
  use candidates <- result.try(case scope.executor_of(stored) {
    Some(name) ->
      registered.placement.named(name) |> result.map(fn(found) { [found] })
    None -> registered.placement.first()
  })
  try_in_order(registered, stored, candidates, [])
}

// Tries each candidate in the order given. Only a first open can have a
// candidate left over, because a record that names an executor is the only
// candidate there is.
fn try_in_order(
  registered: Registered,
  stored: Option(Scope),
  candidates: List(Candidate),
  declined: List(Attempt),
) -> Result(Hands, String) {
  case candidates {
    [] -> Error(none_accepted(list.reverse(declined)))
    [candidate, ..rest] ->
      case attach_to(registered, stored, candidate) {
        Ok(hands) -> Ok(hands)
        Error(Failed(reason)) -> Error(reason)
        Error(Declined(..) as attempt) ->
          try_in_order(registered, stored, rest, [attempt, ..declined])
      }
  }
}

// The reason an open ends when every candidate declined. One candidate keeps
// its own reason, which is the message a session on a named executor has always
// had.
fn none_accepted(declined: List(Attempt)) -> String {
  case declined {
    [Declined(reason:, ..)] -> unavailable(reason)
    [] -> unavailable("no executor is available for this session")
    many ->
      unavailable(
        "no executor accepted the session: "
        <> string.join(
          list.map(many, fn(attempt) {
            case attempt {
              Declined(executor:, reason:) -> executor <> ": " <> reason
              Failed(reason:) -> reason
            }
          }),
          "; ",
        ),
      )
  }
}

fn attach_to(
  registered: Registered,
  stored: Option(Scope),
  candidate: Candidate,
) -> Result(Hands, Attempt) {
  let reach = candidate.reach
  let name = candidate.executor.name
  let first_open = option.is_none(stored)

  // A connection that fails has not sent the attach, so this candidate holds
  // nothing for the session. If it was the only candidate, as it is whenever
  // the record names an executor, the open ends with this reason.
  use Nil <- result.try(
    reach.connect()
    |> result.map_error(fn(reason) { Declined(name, reason) }),
  )

  // The record names the executor before the attach can reach it. If the reply
  // to the attach is lost, the next open finds this record and goes back to the
  // same machine.
  let incarnation = scope.attach_at(stored)
  use Nil <- result.try(
    scope.write(registered.opened, scope.Scope(incarnation, None, Some(name)))
    |> result.map_error(fn(reason) { Failed(unavailable(reason)) }),
  )
  use port <- result.try(
    owner_port.start(owner_port.Config(
      services: registered.owner,
      clock: registered.clock,
      settled: fn(key) { settled(registered.opened, key) },
      reconcile_every_ms: registered.reconcile_every_ms,
    ))
    |> result.map_error(fn(reason) { Failed(unavailable(reason)) }),
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
    // The executor refused for capacity inside the attach transaction, before it
    // built a plane, so on a first open it holds nothing for this session and
    // the record that named it is withdrawn.
    Error(protocol.CapacityExhausted(..) as refusal) if first_open -> {
      owner_port.stop(port)
      case scope.clear(registered.opened) {
        Ok(Nil) -> Error(Declined(name, protocol.describe(refusal)))
        Error(reason) -> Error(Failed(unavailable(reason)))
      }
    }
    Error(refusal) -> {
      owner_port.stop(port)
      Error(Failed(refused(refusal, incarnation)))
    }
    Ok(surface.Attachment(surface: joined, attached: reply)) ->
      case executors.contradiction(candidate.executor, observed(reply.census)) {
        Error(contradiction) -> {
          // The scope exists and is idle. Closing it returns its slot to the
          // executor at once and records a clean close, so fixing the
          // declaration and opening again reattaches at the next incarnation.
          close_scope(registered, candidate, incarnation)
          owner_port.stop(port)
          Error(Failed(unavailable(contradiction)))
        }
        Ok(Nil) -> {
          // Told after every attach that succeeded, not only the first open's.
          // An earlier open whose reply was lost left the record naming this
          // executor without the catalogue ever hearing of it, and the
          // catalogue keeps only the first executor it is given.
          registered.placement.chosen(name)
          Ok(build(
            registered,
            candidate,
            port,
            incarnation,
            surface.functions(joined),
            reply,
            received,
          ))
        }
      }
  }
}

// The three facts a declaration makes claims about, read from a census.
fn observed(remote: RemoteCensus) -> executors.Observed {
  let census = remote.census
  executors.Observed(
    platform: system_prompt.platform(census.platform),
    enforcement: case remote.prompt.helper {
      workspace_plane.Healthy -> executors.Enforced
      workspace_plane.Degraded -> executors.Degraded
    },
    toolchains: list.append(
      case census.toolchain {
        Ok(_found) -> ["codemode"]
        Error(_reason) -> []
      },
      list.map(census.lsp_servers, fn(server) { server.name }),
    ),
  )
}

fn build(
  registered: Registered,
  candidate: Candidate,
  port: owner_port.Port,
  incarnation: Int,
  functions: surface.Functions,
  reply: protocol.Attached(RemoteCensus),
  received_at_ms: Int,
) -> Hands {
  let remote = reply.census

  // The reading comes from this reply and not from the census, because a
  // rebound attach is answered from a plane built before this open began.
  let executor_clock =
    rebased(
      registered.clock,
      executor_now_ms: reply.executor_now_ms,
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
        close_scope(registered, candidate, incarnation)
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
  candidate(membership, configured, name)
  |> result.map(fn(found) { found.reach })
}

/// The candidate for an `[executors.<name>]`: its row and the way to reach it.
/// It fails as `reach` does.
///
/// ## Examples
///
/// ```gleam
/// // workspace.candidate(Some(membership), configured, "build-box")
/// ```
pub fn candidate(
  membership: Option(distribution.Membership),
  configured: List(executors.Executor),
  name: String,
) -> Result(Candidate, String) {
  use membership <- result.try(option.to_result(
    membership,
    unavailable("this daemon was not started with [distribution]"),
  ))
  use executor <- result.try(
    executors.find(configured, name)
    |> result.map_error(fn(_missing) {
      unavailable("no executor named " <> name <> " is configured")
    }),
  )
  use peer <- result.try(
    distribution.peer(membership, executor.node)
    |> result.map_error(fn(fault) { unavailable(distribution.describe(fault)) }),
  )
  Ok(Candidate(
    executor:,
    reach: Reach(
      address: address.Address(
        node: distribution.node(peer),
        name: address.default(),
      ),
      connect: fn() {
        distribution.connect(peer, connect_within_ms)
        |> result.map_error(distribution.describe)
      },
      attach_within_ms: attach_within_ms,
    ),
  ))
}

/// The placement of a session registered on one named executor. The name is
/// its only candidate, and `chosen` is told it after the first attach.
///
/// ## Examples
///
/// ```gleam
/// // workspace.fixed(Some(membership), configured, "build-box", fn(_name) { Nil })
/// ```
pub fn fixed(
  membership: Option(distribution.Membership),
  configured: List(executors.Executor),
  name: String,
  chosen: fn(String) -> Nil,
) -> Placement {
  Placement(
    first: fn() {
      candidate(membership, configured, name)
      |> result.map(fn(found) { [found] })
    },
    named: fn(each) { candidate(membership, configured, each) },
    chosen:,
  )
}

/// The placement of a session created in a pool: the pool's executors that
/// satisfy its requirements, in the order the configuration lists them, with
/// the executors that cannot be reached left to the open to skip.
///
/// A pool that is not configured, or that no executor satisfies, is a reason
/// the first open fails; a session that already has a scope record never asks.
///
/// ## Examples
///
/// ```gleam
/// // workspace.pooled(Some(membership), configured, pools, "linux", record_choice)
/// ```
pub fn pooled(
  membership: Option(distribution.Membership),
  configured: List(executors.Executor),
  available: List(pools.Pool),
  pool: String,
  chosen: fn(String) -> Nil,
) -> Placement {
  Placement(
    first: fn() {
      use found <- result.try(
        pools.find(available, pool)
        |> result.map_error(fn(_missing) {
          unavailable("no pool named " <> pool <> " is configured")
        }),
      )
      case pools.candidates(found, configured) {
        [] ->
          Error(unavailable(
            "no executor of pool "
            <> pool
            <> " satisfies its requirements ("
            <> pools.requirements(found)
            <> ")",
          ))
        admitted ->
          list.try_map(admitted, fn(executor) {
            candidate(membership, configured, executor.name)
          })
      }
    },
    named: fn(each) { candidate(membership, configured, each) },
    chosen:,
  )
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
fn close_scope(
  registered: Registered,
  candidate: Candidate,
  incarnation: Int,
) -> Nil {
  case ask_close(registered, candidate.reach, incarnation, 2) {
    Ok(closed) -> {
      let _written =
        scope.write(
          registered.opened,
          scope.Scope(incarnation, Some(closed), Some(candidate.executor.name)),
        )
      Nil
    }
    Error(Nil) -> Nil
  }
}

fn ask_close(
  registered: Registered,
  reach: Reach,
  incarnation: Int,
  attempts: Int,
) -> Result(protocol.CloseOutcome, Nil) {
  request_close(
    registered.session,
    registered.workspace,
    reach,
    incarnation,
    attempts,
  )
  |> result.replace_error(Nil)
}

/// Why a close that no session is running produced no outcome.
pub type CloseFailure {
  /// The executor answered and refused. Nothing it holds changed, and asking
  /// again would be refused again.
  CloseRefused(refusal: protocol.Refusal)

  /// The executor did not answer: it is unreachable, went away mid-close, or
  /// took longer than the close is allowed. The scope may or may not have
  /// closed, and the same question can be asked again.
  CloseUnanswered
}

/// Asks the executor to close the scope of a session that is not running, and
/// answers how the close ended.
///
/// A session move uses this when the last close was never recorded: the
/// orchestrator died, or the executor did not answer, before the session's own
/// cleanup could write what happened. A scope that already ended at this
/// incarnation answers the outcome it stored (`host`), so asking again after a
/// lost reply is how the move learns the cleanup finished. The call connects,
/// asks once, and reconnects and asks once more if the host went away first.
///
/// ## Examples
///
/// ```gleam
/// // workspace.close_stopped(reach, "0198c0de", "repo", 3)
/// ```
pub fn close_stopped(
  reach: Reach,
  session: String,
  workspace: String,
  incarnation: Int,
) -> Result(protocol.CloseOutcome, CloseFailure) {
  case reach.connect() {
    Ok(Nil) -> request_close(session, workspace, reach, incarnation, 2)
    Error(_) -> Error(CloseUnanswered)
  }
}

fn request_close(
  session: String,
  workspace: String,
  reach: Reach,
  incarnation: Int,
  attempts: Int,
) -> Result(protocol.CloseOutcome, CloseFailure) {
  let reply = process.new_subject()
  let watch = address.watch(reach.address)
  address.deliver(
    reach.address,
    protocol.Close(session:, workspace:, incarnation:, reply:),
  )
  let heard =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(watch, fn(_down) { Error(Nil) })
    |> process.selector_receive(close_within_ms)
  process.demonitor_process(watch)
  case heard {
    Ok(Ok(Ok(closed))) -> Ok(closed)
    Ok(Ok(Error(refusal))) -> Error(CloseRefused(refusal))

    // The host went away first. One reconnect and one more ask: a close that
    // already landed answers with its stored outcome, which is how a lost reply
    // is learned.
    Ok(Error(Nil)) ->
      case attempts > 1, reach.connect() {
        True, Ok(Nil) ->
          request_close(session, workspace, reach, incarnation, attempts - 1)
        _, _ -> Error(CloseUnanswered)
      }
    Error(Nil) -> Error(CloseUnanswered)
  }
}
