//// The executor's node-level host: the one process that admits, runs, records
//// and answers tool calls that orchestrators send to this machine
//// (protocol-change/078, "Execution ledger").
////
//// A session whose checkout is on this machine sends its tool calls here. The
//// network loses replies, partitions, and outlives either side's VM, so the
//// host keeps a durable record of every call it starts (`storage/exec_ledger`)
//// and treats that record, not any message, as the truth. Exactly one host runs
//// per executor VM, because the ledger's recovery on open ("every run the last
//// VM had in flight is lost") is only correct for a single opener. It
//// registers under a fixed name, and a peer reaches it as `{name, node}` (see
//// `client/remote/address`).
////
//// The host knows nothing about tools, brokers or checkouts. For each session
//// it holds a `Plane`: the functions the workspace plane built on this machine
//// exposes, which the integration supplies through a `PlaneFactory`. That is
//// what keeps this module testable with a fake plane and keeps the placement
//// of the workspace out of the host's business.
////
//// ## One run per call key
////
//// A `Run` is admitted by inserting its row in the same transaction that checks
//// the scope's state, incarnation and attach token, so a request from a dead
//// runtime is refused by content however the network ordered it. The admission
//// answers one of four things, and the host acts on exactly that:
////
//// - a new row: start the tool as a weft run and commit its outcome with
////   `finish` before any reply goes out;
//// - an `Admitted` row: the call is live, so the sender joins its waiters and
////   the tool does not start twice;
//// - a `Terminal` row: reply with the stored outcome;
//// - an `Unknown` row: reply that the outcome is lost.
////
//// The orchestrator re-sends a `Run` after a reconnect, and this idempotence
//// is what makes the re-send safe: messages lost with a dropped connection are
//// never delivered later.
////
//// ## The caller is monitored
////
//// The host monitors the process that owns each `Run`'s reply subject. The
//// orchestrator aborts a call by killing that process, so a `DOWN` whose reason
//// is anything but `noconnection` means someone asked to stop, and when no
//// waiter is left the run is cancelled and its row becomes `Unknown`. A
//// `noconnection` `DOWN` means the orchestrator is only unreachable: the run
//// continues, its outcome waits in the ledger, and the orchestrator asks again
//// when it reconnects. The decision is `cancels_run`.
////
//// ## Work that does not block the host
////
//// Every tool run, every scope close and every plane build is a weft run whose
//// result arrives as a message, so the host keeps answering other sessions
//// while a tool runs or a workspace is still being prepared. A build can take
//// seconds (it probes the toolchain, starts a helper pool and creates
//// directories), and a host that built inside its own loop would stall every
//// other session for that long. The attach is answered when its build lands.
////
//// While a session's build is in flight the scope is `Building`. A second
//// `Attach`, a `Run` and a `Close` for it are each refused with
//// `PlaneBuilding`, which tells the sender to ask again shortly. Refusing is
//// smaller than queueing: the caller already has a retry loop for an executor
//// that is not ready, and a refusal changes no ledger row. The refusal comes
//// before the ledger is touched, so a refused attach does not replace the
//// attach token the first attach is still waiting on.
////
//// ## The scope's children
////
//// A plane's supervised children (its jobs actor, scratch store and language
//// server manager) run under a supervisor of their own for each scope, started
//// by the host once the build lands. A supervisor ends when its parent does, so
//// the short-lived build process cannot be its parent; a small owner process
//// is, and the owner ends when the host does. The planes themselves (the
//// helper pool, the executor service, the broker) are not linked to the host,
//// so a host that restarted alone would leave them running and build second
//// ones beside them. The daemon therefore treats the host's death as its own
//// (see `client/daemon/main`) and never restarts the host independently.
//// Closing a scope hands the plane a function that stops its supervisor, and
//// the plane calls it at the point in its own teardown order where children
//// must go. A supervisor that gives up after repeated child crashes ends only
//// its own scope's services; the scope keeps answering with those tools failing
//// until the session closes and reattaches.
////
//// ## Flow
////
//// `start` → `initialise` → `handle_event` → `handle_peer` → `attach`,
//// `admit_call`, `stop_execution`, `fenced_lookup`, `close`
////
//// 1. `initialise` registers the name and opens the ledger, which turns every
////    row the previous VM left `Admitted` into `Unknown`.
//// 2. `handle_event` takes one message: a peer's request, a job's result, or a
////    caller's `DOWN`, and rebuilds the selector so every live job is listened
////    to.
//// 3. `attach` binds a runtime incarnation to its scope in the ledger and
////    starts a build, or re-points the scope's plane. `plane_built` completes
////    the attach when the build lands.
//// 4. `admit_call` consults the ledger for a `Run` or a `StartExecution` and
////    either `start_call`s the work, `join_run`s a live call, or answers from
////    the stored row.
//// 5. `job_finished` commits a tool's outcome or a program's value with
////    `commit_outcome` and answers every waiter, or settles the call as lost.
//// 6. `caller_down` applies `cancels_run` to an aborted or unreachable caller.
////    `stop_execution` turns a background program's row unknown, or bars a
////    key with no row, and `halt`s the program.
//// 7. `fenced_lookup` answers a recovery query and, for a key with no row,
////    stores "did not start" so a late `Run` for it never starts.
//// 8. `close` fences the scope, cancels its calls, and `finish_closed` records
////    how the plane's cleanup ended.

import broker/internal/call
import client/internal/ffi_os
import client/owner_services.{type ExecutionTerms, type OwnerServices}
import client/remote/address.{type Address}
import client/remote/codec
import client/remote/owner_link
import client/remote/protocol.{
  type CloseOutcome, type ExecutionAnswer, type HostMessage, type Key,
  type Refusal, type RunAnswer,
}
import client/wiring.{type Authority}
import core/clock.{type Clock}
import core/json.{type JsonValue}
import gleam/dict.{type Dict}
import gleam/erlang/node
import gleam/erlang/process.{
  type Down, type ExitReason, type Monitor, type Name, type Pid, type Selector,
  type Subject,
}
import gleam/int
import gleam/list
import gleam/otp/static_supervisor as sup
import gleam/result
import gleam/string
import runtime/effects.{type ToolOutcome, type ToolRun, ToolFailed}
import storage/exec_ledger
import weft
import weft/actor

/// What the host gives a plane factory when a scope needs its workspace plane.
pub type AttachSpec {
  AttachSpec(
    /// The orchestrator session the scope belongs to.
    session: String,
    /// The workspace, as the executor knows it.
    workspace: String,
    /// The incarnation the scope admits calls under.
    incarnation: Int,
    /// The owner callbacks, backed by messages to the attaching runtime's owner
    /// port. The link behind it is re-pointed when a later runtime attaches, so
    /// the plane keeps this record for its whole life.
    owner: OwnerServices,
    /// The executor's clock. Build the plane on it: an escalation's remaining
    /// time is read off a deadline on this clock.
    clock: Clock,
    /// The MCP servers this scope's code mode reaches: the façades of the ones
    /// the orchestrator runs, and the names of the ones it expects this
    /// executor to run from its own configuration. Fixed for the plane's life.
    mcp: protocol.McpPlan,
  )
}

/// One background program to run, as the host hands it to the plane.
pub type ExecutionStart {
  ExecutionStart(
    /// What the launching tool call captured.
    terms: ExecutionTerms,
    /// The execution's step, `async/<id>`: the broker step its effects run
    /// under and the step its owner-bound calls carry.
    step: String,
    /// How long the program may run, from now, on the executor's clock.
    remaining_ms: Int,
  )
}

/// The workspace plane for one scope, as the host sees it.
pub type Plane(census) {
  Plane(
    /// Runs one tool call to its outcome. It runs in a process the host owns and
    /// may cancel by killing it, so a caller watch in the plane's broker stops
    /// whatever the call started.
    run: fn(ToolRun, Authority) -> ToolOutcome,
    /// Runs one background program to its end and answers its execution
    /// value. It runs in a process the host owns and may kill, as `run` does.
    execute: fn(ExecutionStart) -> JsonValue,
    /// Aborts every effect under one broker step: the operation id as text and
    /// the step. The host calls it when it stops a background program, so the
    /// program's satellite and jailed calls end with it.
    abort_step: fn(String, String) -> Nil,
    /// What the plane reports about its machine, returned with every attach.
    census: census,
    /// The plane's supervised children. The host starts them under a supervisor
    /// of its own for this scope, after the build and before the attach is
    /// answered.
    children: fn(sup.Builder) -> sup.Builder,
    /// Retires the plane and reports how that ended. Its argument stops the
    /// scope's supervisor and answers `Ok` only when the children are gone; the
    /// plane calls it where its teardown order wants the children stopped, and
    /// must not report `AllRetired` after an `Error`. Only this result is a
    /// retirement witness; a timeout or a `DOWN` never is.
    close: fn(fn() -> Result(Nil, String)) -> CloseOutcome,
  )
}

/// Builds the workspace plane for a scope that has none, or says why it cannot.
pub type PlaneFactory(census) =
  fn(AttachSpec) -> Result(Plane(census), String)

/// How the host is configured.
pub type Config(census) {
  Config(
    /// The name the host registers under. Production uses
    /// `address.default()`.
    name: Name(HostMessage(census)),
    /// The ledger file. Its parent directory must exist and be private.
    ledger_path: String,
    /// The scope and byte caps admission is judged against.
    limits: exec_ledger.Limits,
    /// The most bytes one call's encoded outcome may take. Admission reserves
    /// it, and an outcome that does not fit is replaced by a failure.
    max_result_bytes: Int,
    /// The same for one background execution's value. It is far smaller than
    /// a call's, because an execution holds its reservation for as long as
    /// the program runs and the ledger's budget is shared by every session.
    execution_result_bytes: Int,
    /// The executor's clock, handed to every plane.
    clock: Clock,
    /// Builds a scope's plane.
    factory: PlaneFactory(census),
  )
}

/// The default reservation per call: sixteen mebibytes, twice the largest file
/// `fs_read` returns. An image inflates by a third when it is base64 encoded and
/// the result is wrapped in JSON, so the reservation needs the headroom for a
/// maximum-size read to succeed remotely exactly as it does locally.
pub const default_max_result_bytes = 16_777_216

/// The default reservation per background execution: one mebibyte. An
/// execution may hold it for up to fifteen minutes, and the ledger's budget is
/// the whole executor's, so sixteen mebibytes each would let thirty-two busy
/// executions refuse every tool call on the machine. A larger value is replaced
/// by an errored value that names both sizes, as an oversized tool outcome is.
/// The completion notice quotes two kilobytes of a result, and a program with
/// more to return writes it with `report.emit` and returns the reference.
pub const default_execution_result_bytes = 1_048_576

// One message the host handles. A peer's request arrives on the host's name, a
// job's result on the sink of the weft run that produced it, and a monitored
// caller's exit as a `DOWN`.
type Event(census) {
  FromPeer(message: HostMessage(census))
  JobFinished(job: Int, pulled: weft.Pulled(JobResult(census), Nil))
  CallerDown(down: Down)
}

// What a job's task returns when it completes.
type JobResult(census) {
  ToolRan(outcome: ToolOutcome)
  ProgramRan(value: JsonValue)
  ScopeClosed(outcome: CloseOutcome)
  PlaneBuilt(built: Result(Plane(census), String))
}

// What one attach binds: the scope's identity, where its workspace calls
// back to, and the MCP servers its code mode reaches.
type Binding {
  Binding(
    session: String,
    workspace: String,
    incarnation: Int,
    owner_port: Subject(protocol.OwnerMessage),
    mcp: protocol.McpPlan,
  )
}

// The part of a keyed request that admission judges: the key, the attach it
// claims to come from, and where its answer goes.
type Admission {
  Admission(key: Key, incarnation: Int, token: BitArray, reply: Reply)
}

// What admitted work is: its kind, the name its ledger row carries, the bytes
// it reserves, and the task that runs it once a plane is in hand.
type Work(census) {
  Work(
    kind: CallKind,
    tool: String,
    reservation: Int,
    task: fn(Plane(census)) -> fn() -> Result(JobResult(census), Nil),
  )
}

// The two kinds of keyed work the host admits. They share admission, waiters,
// the commit before any reply and cancellation; they differ in what a waiter
// is answered with and in what a stop must also abort.
type CallKind {
  ToolCall
  Execution
}

// Where one waiter wants its answer. The two kinds of request carry reply
// subjects of different types, and a waiter keeps the one it sent.
type Reply {
  RunReply(reply: Subject(RunAnswer))
  ExecutionReply(reply: Subject(ExecutionAnswer))
}

// How a keyed call ended, before it is put in a waiter's own words.
type Settled {
  // The ledger holds these bytes as the call's terminal row.
  SettledStored(stored: BitArray)

  // The call was admitted and its outcome is lost.
  SettledLost

  // The call was not admitted.
  SettledRefused(refusal: Refusal)
}

// What a job is for.
type Job(census) {
  RunJob(key: Key)
  CloseJob(
    session: String,
    workspace: String,
    incarnation: Int,
    link: owner_link.Link,
    reply: Subject(Result(CloseOutcome, Refusal)),
  )
  BuildJob(
    session: String,
    link: owner_link.Link,
    unacked: protocol.Unacked,
    reply: Subject(Result(protocol.Attached(census), Refusal)),
  )
}

// A started job: where its result arrives, and the signal that cancels it.
type Tracked(census) {
  Tracked(
    job: Job(census),
    sink: Subject(weft.Pulled(JobResult(census), Nil)),
    cancel: weft.Cancel,
  )
}

// A session's scope as this VM holds it. A scope is `Building` from the attach
// that created it until the build job reports, and `Ready` after.
type Slot(census) {
  Building(job: Int)
  Ready(placement: Placement(census))
}

// A scope's plane, the link its owner callbacks go through, and the
// supervisor its children live under.
type Placement(census) {
  Placement(plane: Plane(census), link: owner_link.Link, children: Pid)
}

// A call that is running now: the job that runs it, what kind of call it is,
// and everyone waiting on it.
type Live {
  Live(job: Int, kind: CallKind, waiters: List(Waiter))
}

// One process waiting on a live call, and the monitor that watches it.
type Waiter {
  Waiter(reply: Reply, watch: Monitor)
}

type State(census) {
  State(
    config: Config(census),
    ledger: exec_ledger.Ledger,
    placements: Dict(String, Slot(census)),
    live: Dict(Key, Live),
    watches: Dict(Monitor, Key),
    jobs: Dict(Int, Tracked(census)),
    next_job: Int,
  )
}

/// Starts the host, linked to the caller, and returns its address.
///
/// The start fails, and registers nothing, if the name is taken or the ledger
/// cannot be opened. Opening the ledger turns every call the previous VM left
/// running into `Unknown`; nothing is relaunched.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(started) = host.start(config)
/// // address.deliver(started.data, protocol.Ack(key))
/// ```
pub fn start(
  config: Config(census),
) -> actor.StartResult(Address(HostMessage(census))) {
  builder(config) |> actor.start
}

/// The host as a child of a supervision tree.
///
/// ## Examples
///
/// ```gleam
/// // supervisor.add(builder, host.supervised(config))
/// ```
pub fn supervised(config: Config(census)) {
  builder(config) |> actor.supervised
}

/// Whether a caller's exit means the call should stop.
///
/// The orchestrator aborts a call by killing the process that sent its `Run`,
/// so every exit but one stops the call. `noconnection` is the exception: it
/// says the orchestrator became unreachable, which nobody asked for, and the
/// call runs on with its outcome waiting in the ledger.
///
/// ## Examples
///
/// ```gleam
/// assert host.cancels_run(process.Killed)
/// ```
///
/// ```gleam
/// let lost = atom.to_dynamic(atom.create("noconnection"))
/// assert !host.cancels_run(process.Abnormal(lost))
/// ```
pub fn cancels_run(reason: ExitReason) -> Bool {
  case reason {
    process.Normal | process.Killed -> True
    process.Abnormal(_) -> !call.is_disconnection(reason)
  }
}

fn builder(config: Config(census)) {
  actor.new_with_initialiser(10_000, fn(_subject) { initialise(config) })
  |> actor.on_message(handle_event)
}

// Registers the host's name and opens the ledger. Registering first means a
// second host in the same VM fails before it can open the ledger and turn the
// first host's live calls into unknown ones.
fn initialise(
  config: Config(census),
) -> Result(
  actor.Initialised(State(census), Event(census), Address(HostMessage(census))),
  String,
) {
  use Nil <- result.try(
    process.register(process.self(), config.name)
    |> result.replace_error("the host name is already registered"),
  )
  use ledger <- result.try(
    exec_ledger.open(config.ledger_path)
    |> result.map_error(fn(error) {
      "the execution ledger did not open: " <> string.inspect(error)
    }),
  )
  let state =
    State(
      config:,
      ledger:,
      placements: dict.new(),
      live: dict.new(),
      watches: dict.new(),
      jobs: dict.new(),
      next_job: 0,
    )
  actor.initialised(state)
  |> actor.selecting(selector_for(state))
  |> actor.returning(address.Address(node: node.self(), name: config.name))
  |> Ok
}

// Applies one event, then listens for exactly the jobs that are live now.
fn handle_event(
  state: State(census),
  event: Event(census),
) -> actor.Next(State(census), Event(census)) {
  let state = case event {
    FromPeer(message) -> handle_peer(state, message)
    JobFinished(job:, pulled:) -> job_finished(state, job, pulled)
    CallerDown(down:) -> caller_down(state, down)
  }
  actor.continue(state) |> actor.with_selector(selector_for(state))
}

fn handle_peer(
  state: State(census),
  message: HostMessage(census),
) -> State(census) {
  case message {
    protocol.Attach(
      version:,
      session:,
      workspace:,
      incarnation:,
      token:,
      owner_port:,
      mcp:,
      reply:,
    ) ->
      case version == protocol.version {
        True ->
          attach(
            state,
            Binding(session:, workspace:, incarnation:, owner_port:, mcp:),
            token,
            reply,
          )
        False -> {
          process.send(
            reply,
            Error(protocol.VersionMismatch(supported: protocol.version)),
          )
          state
        }
      }
    protocol.Run(key:, incarnation:, token:, run:, authority:, reply:) ->
      admit_call(
        state,
        Admission(key:, incarnation:, token:, reply: RunReply(reply)),
        Work(
          kind: ToolCall,
          tool: run.call.name,
          reservation: state.config.max_result_bytes,
          task: fn(plane: Plane(census)) {
            let run_tool = plane.run
            fn() { Ok(ToolRan(run_tool(run, authority))) }
          },
        ),
      )
    protocol.StartExecution(
      key:,
      incarnation:,
      token:,
      terms:,
      remaining_ms:,
      reply:,
    ) ->
      admit_call(
        state,
        Admission(key:, incarnation:, token:, reply: ExecutionReply(reply)),
        Work(
          kind: Execution,
          tool: protocol.execution_tool,
          reservation: state.config.execution_result_bytes,
          task: fn(plane: Plane(census)) {
            let execute = plane.execute
            let start =
              ExecutionStart(
                terms:,
                step: key.step,
                remaining_ms: int.max(0, remaining_ms),
              )
            fn() { Ok(ProgramRan(execute(start))) }
          },
        ),
      )
    protocol.StopExecution(key:, incarnation:) ->
      stop_execution(state, key, incarnation)
    protocol.Query(key:, reply:) -> {
      process.send(reply, lookup(state, key))
      state
    }
    protocol.QueryOrFence(key:, incarnation:, reply:) -> {
      process.send(reply, fenced_lookup(state, key, incarnation))
      state
    }
    protocol.ListUnacked(session:, reply:) -> {
      process.send(reply, unacked(state, session))
      state
    }
    protocol.Ack(key:) -> {
      // A failed ack leaves a row the next `ListUnacked` offers again.
      let _acked = exec_ledger.ack(state.ledger, to_ledger(key))
      state
    }
    protocol.Close(session:, workspace:, incarnation:, reply:) ->
      close(state, session, workspace, incarnation, reply)
  }
}

// --- attach -------------------------------------------------------------------

// Binds a runtime incarnation to the session's scope. The ledger decides
// whether this created, rebound or reopened the scope, and the answer decides
// whether a plane is built or only re-pointed. A scope that is still being
// built is refused before the ledger is asked, so the refusal changes no row.
fn attach(
  state: State(census),
  binding: Binding,
  token: BitArray,
  reply: Subject(Result(protocol.Attached(census), Refusal)),
) -> State(census) {
  case dict.get(state.placements, binding.session) {
    Ok(Building(..)) -> {
      process.send(reply, Error(protocol.PlaneBuilding))
      state
    }
    Ok(Ready(..)) | Error(Nil) -> {
      let attached =
        exec_ledger.attach(
          state.ledger,
          binding.session,
          binding.workspace,
          binding.incarnation,
          token,
          state.config.limits,
        )
      case attached {
        Error(error) -> {
          process.send(reply, Error(refusal_of(error)))
          state
        }
        Ok(bound) -> {
          let unacked =
            protocol.Unacked(
              terminal: list.map(bound.terminal, from_ledger),
              unknown: list.map(bound.unknown, from_ledger),
              executions: running_executions(state, binding.session),
            )
          place(state, binding, bound.how, unacked, reply)
        }
      }
    }
  }
}

// The session's background executions that are still running, by key. A read
// that fails answers none: the orchestrator's reconciler asks again on its next
// pass, and an attach must not fail because a listing did.
fn running_executions(state: State(census), session: String) -> List(Key) {
  exec_ledger.admitted(state.ledger, session, protocol.execution_tool)
  |> result.map(list.map(_, from_ledger))
  |> result.unwrap([])
}

// Gives the scope a plane. A rebind keeps the plane it has and re-points its
// owner link, and answers at once; the plane keeps the MCP plan it was built
// with, which is fixed for its incarnation. Every other case starts a build,
// retiring a stale link first, and the answer is sent when the build lands.
fn place(
  state: State(census),
  binding: Binding,
  how: exec_ledger.Attachment,
  unacked: protocol.Unacked,
  reply: Subject(Result(protocol.Attached(census), Refusal)),
) -> State(census) {
  case how, dict.get(state.placements, binding.session) {
    exec_ledger.Rebound, Ok(Ready(placement)) -> {
      owner_link.replace(placement.link, binding.owner_port)
      process.send(
        reply,
        Ok(attached_reply(state, placement.plane.census, unacked)),
      )
      state
    }

    // The ledger says this scope is new, or came back from a close, while this
    // VM holds a plane for it. Scope rows are never deleted, and a close removes
    // the placement before it starts, so only a ledger changed outside the host
    // reaches this arm. The plane is retired before the new one is built, so
    // that a scope that did get here leaks no helper pool. It blocks the host
    // for the retirement, which is the price of a path that does not happen.
    exec_ledger.Created, Ok(Ready(stale))
    | exec_ledger.Reopened, Ok(Ready(stale))
    -> {
      let _outcome = stale.plane.close(fn() { retire_children(stale.children) })
      owner_link.stop(stale.link)
      build_plane(state, binding, unacked, reply)
    }

    exec_ledger.Rebound, Ok(Building(..))
    | exec_ledger.Created, Ok(Building(..))
    | exec_ledger.Reopened, Ok(Building(..))
    -> {
      // `attach` refuses a building scope before it reaches the ledger.
      process.send(reply, Error(protocol.PlaneBuilding))
      state
    }
    exec_ledger.Rebound, Error(Nil)
    | exec_ledger.Created, Error(Nil)
    | exec_ledger.Reopened, Error(Nil)
    -> build_plane(state, binding, unacked, reply)
  }
}

// Starts the factory as a weft run. The scope is `Building` until the run
// reports, so no other request for the session can slip in between.
fn build_plane(
  state: State(census),
  binding: Binding,
  unacked: protocol.Unacked,
  reply: Subject(Result(protocol.Attached(census), Refusal)),
) -> State(census) {
  let session = binding.session
  case owner_link.start(binding.owner_port) {
    Error(reason) -> {
      process.send(reply, Error(protocol.NoPlane(reason)))
      state
    }
    Ok(link) -> {
      let spec =
        AttachSpec(
          session:,
          workspace: binding.workspace,
          incarnation: binding.incarnation,
          owner: owner_link.services(link, state.config.clock),
          clock: state.config.clock,
          mcp: binding.mcp,
        )
      let factory = state.config.factory
      let #(state, id, sink, cancel) =
        start_job(state, fn() { Ok(PlaneBuilt(factory(spec))) })
      let tracked =
        Tracked(
          job: BuildJob(session:, link:, unacked:, reply:),
          sink:,
          cancel:,
        )
      State(
        ..state,
        jobs: dict.insert(state.jobs, id, tracked),
        placements: dict.insert(state.placements, session, Building(job: id)),
      )
    }
  }
}

// The build landed. A plane whose children start becomes the scope's, and the
// attach it was started for is answered; any other ending leaves the scope open
// in the ledger and without a plane, so the next attach builds again.
fn plane_built(
  state: State(census),
  session: String,
  link: owner_link.Link,
  unacked: protocol.Unacked,
  reply: Subject(Result(protocol.Attached(census), Refusal)),
  built: Result(Plane(census), String),
) -> State(census) {
  case built {
    Error(reason) -> build_failed(state, session, link, reply, reason)
    Ok(plane) ->
      case start_children(plane) {
        Ok(children) -> {
          let placement = Placement(plane:, link:, children:)
          process.send(reply, Ok(attached_reply(state, plane.census, unacked)))
          State(
            ..state,
            placements: dict.insert(state.placements, session, Ready(placement)),
          )
        }

        // The plane exists and its helpers are running, so a plane whose
        // children would not start is closed before it is forgotten. This path
        // is rare and blocks the host for the close, which is the cost of not
        // leaking a pool.
        Error(reason) -> {
          let _outcome = plane.close(fn() { Ok(Nil) })
          build_failed(state, session, link, reply, reason)
        }
      }
  }
}

// The reply to a successful attach. The executor's clock is read here, when the
// reply is sent, and not kept with the census: a rebound attach answers from a
// plane built long ago, and the orchestrator rebases its deadlines on this
// reading as though it were current.
fn attached_reply(
  state: State(census),
  census: census,
  unacked: protocol.Unacked,
) -> protocol.Attached(census) {
  protocol.Attached(
    census:,
    executor_now_ms: clock.read(state.config.clock).0,
    unacked:,
  )
}

fn build_failed(
  state: State(census),
  session: String,
  link: owner_link.Link,
  reply: Subject(Result(protocol.Attached(census), Refusal)),
  reason: String,
) -> State(census) {
  owner_link.stop(link)
  process.send(reply, Error(protocol.NoPlane(reason)))
  State(..state, placements: dict.delete(state.placements, session))
}

// The scope's supervisor, started by a process of its own that outlives the
// build and ends with the host. A supervisor exits when its parent does, so the
// build process cannot be the parent. The host cannot be either: stopping a
// supervisor on purpose ends it with a `shutdown` exit, and a host linked to it
// would receive that signal and die. The owner has no link to the host. It
// watches the host instead and returns when the host is gone, which ends the
// supervisor and its children with it.
fn start_children(plane: Plane(census)) -> Result(Pid, String) {
  let host = process.self()
  let started = process.new_subject()
  let _owner =
    process.spawn_unlinked(fn() {
      let supervisor = sup.new(sup.OneForOne) |> plane.children |> sup.start
      case supervisor {
        Ok(running) -> {
          process.send(started, Ok(running.pid))
          wait_for_host(host)
        }
        Error(error) ->
          process.send(
            started,
            Error(
              "the workspace's services did not start: "
              <> string.inspect(error),
            ),
          )
      }
    })
  case process.receive(started, children_grace_ms) {
    Ok(outcome) -> outcome
    Error(Nil) -> Error("the workspace's services did not start in time")
  }
}

// Returns when the host process is gone.
fn wait_for_host(host: Pid) -> Nil {
  let watch = process.monitor(host)
  process.new_selector()
  |> process.select_specific_monitor(watch, fn(_down) { Nil })
  |> process.selector_receive_forever
}

// Stops a scope's supervisor and its children, and answers `Ok` only when the
// supervisor has been seen to go. A monitor taken first cannot miss the exit.
fn retire_children(children: Pid) -> Result(Nil, String) {
  let watch = process.monitor(children)
  let asked = ffi_os.terminate_supervisor(children, children_grace_ms)
  let outcome = case asked {
    Ok(Nil) ->
      process.new_selector()
      |> process.select_specific_monitor(watch, fn(down) { down.reason })
      |> process.selector_receive(children_grace_ms)
      |> result.replace_error("the scope's services did not stop in time")
      |> result.map(fn(_reason) { Nil })
    Error(Nil) -> Error("the scope's services did not acknowledge shutdown")
  }
  process.demonitor_process(watch)
  outcome
}

// How long a scope's supervisor has to stop its children.
const children_grace_ms = 5000

// --- run ----------------------------------------------------------------------

// Admits one keyed request, a tool call or a background execution. The
// ledger's answer, not the request, decides what happens. A scope with no plane
// in this VM still answers a key the ledger holds a row for
// (`answer_without_plane`), before it refuses for the missing plane.
fn admit_call(
  state: State(census),
  admission: Admission,
  work: Work(census),
) -> State(census) {
  let key = admission.key
  let reply = admission.reply
  case dict.get(state.placements, key.session), reply_owner(reply) {
    Error(Nil), _ -> answer_without_plane(state, key, reply, no_plane())
    Ok(Building(..)), _ ->
      answer_without_plane(state, key, reply, protocol.PlaneBuilding)
    _, Error(Nil) -> {
      deliver(
        reply,
        SettledRefused(protocol.Invalid(
          "the reply subject has no owner to watch",
        )),
      )
      state
    }
    Ok(Ready(placement)), Ok(_owner) -> {
      let admitted =
        exec_ledger.admit(
          state.ledger,
          to_ledger(key),
          admission.incarnation,
          admission.token,
          work.tool,
          work.reservation,
          state.config.limits,
        )
      case admitted {
        Error(error) -> {
          deliver(reply, SettledRefused(refusal_of(error)))
          state
        }
        Ok(exec_ledger.Fresh) ->
          start_call(state, key, work.kind, work.task(placement.plane), reply)
        Ok(exec_ledger.Existing(exec_ledger.Admitted)) ->
          join_run(state, key, reply)
        Ok(exec_ledger.Existing(exec_ledger.Terminal(stored))) -> {
          deliver(reply, SettledStored(stored))
          state
        }
        Ok(exec_ledger.Existing(exec_ledger.Unknown))
        | Ok(exec_ledger.Existing(exec_ledger.Acked)) -> {
          deliver(reply, SettledLost)
          state
        }
      }
    }
  }
}

// A keyed request for a scope this VM holds no plane for. The ledger outlives
// the VM, so a key it already holds a row for has an answer that does not need
// a plane: the call may have run before the executor restarted, and a refusal
// for lack of a workspace would tell the model it did not. A key with a stored
// outcome or a lost one is answered as the ledger has it. Only a key with no row
// is refused for the missing plane, because for that key nothing started.
fn answer_without_plane(
  state: State(census),
  key: Key,
  reply: Reply,
  refusal: Refusal,
) -> State(census) {
  case exec_ledger.query(state.ledger, to_ledger(key)) {
    Ok(exec_ledger.Missing) -> {
      deliver(reply, SettledRefused(refusal))
      state
    }
    Ok(exec_ledger.Found(exec_ledger.Terminal(stored))) -> {
      deliver(reply, SettledStored(stored))
      state
    }
    Ok(exec_ledger.Found(exec_ledger.Unknown))
    | Ok(exec_ledger.Found(exec_ledger.Acked)) -> {
      deliver(reply, SettledLost)
      state
    }

    // An admitted row with no live run in this VM can only follow a failed
    // write, as in `join_run`, and its outcome is lost.
    Ok(exec_ledger.Found(exec_ledger.Admitted)) ->
      case dict.get(state.live, key) {
        Ok(_live) -> {
          deliver(reply, SettledRefused(refusal))
          state
        }
        Error(Nil) -> {
          let _marked = exec_ledger.mark_unknown(state.ledger, to_ledger(key))
          deliver(reply, SettledLost)
          state
        }
      }
    Error(error) -> {
      deliver(reply, SettledRefused(refusal_of(error)))
      state
    }
  }
}

fn no_plane() -> Refusal {
  protocol.NoPlane("the scope has no workspace plane; attach first")
}

// Starts admitted work as a weft run. The run's cancel signal is the host's
// only handle on it: killing the signal makes the scope kill the worker, and
// the worker's death is what the plane's broker watches to stop a helper.
fn start_call(
  state: State(census),
  key: Key,
  kind: CallKind,
  task: fn() -> Result(JobResult(census), Nil),
  reply: Reply,
) -> State(census) {
  let #(state, id, sink, cancel) = start_job(state, task)
  let tracked = Tracked(job: RunJob(key), sink:, cancel:)
  let state = State(..state, jobs: dict.insert(state.jobs, id, tracked))
  let state =
    State(
      ..state,
      live: dict.insert(state.live, key, Live(job: id, kind:, waiters: [])),
    )
  add_waiter(state, key, reply)
}

// Joins a call that is already running. A row that says `Admitted` with no live
// run behind it can only follow a failed write, and the honest answer is that
// the outcome is lost.
fn join_run(state: State(census), key: Key, reply: Reply) -> State(census) {
  case dict.get(state.live, key) {
    Ok(_live) -> add_waiter(state, key, reply)
    Error(Nil) -> {
      let _marked = exec_ledger.mark_unknown(state.ledger, to_ledger(key))
      deliver(reply, SettledLost)
      state
    }
  }
}

// Watches the process that owns `reply` and records it as a waiter. The owner
// was checked before admission, so the monitor always has a process to watch.
fn add_waiter(state: State(census), key: Key, reply: Reply) -> State(census) {
  case dict.get(state.live, key), reply_owner(reply) {
    Ok(live), Ok(owner) -> {
      let watch = process.monitor(owner)
      let live = Live(..live, waiters: [Waiter(reply:, watch:), ..live.waiters])
      State(
        ..state,
        live: dict.insert(state.live, key, live),
        watches: dict.insert(state.watches, watch, key),
      )
    }
    Error(Nil), _ | _, Error(Nil) -> state
  }
}

fn reply_owner(reply: Reply) -> Result(Pid, Nil) {
  case reply {
    RunReply(reply:) -> process.subject_owner(reply)
    ExecutionReply(reply:) -> process.subject_owner(reply)
  }
}

// Puts a settled call in the words its waiter asked in. A tool call's waiter
// gets a `RunAnswer` and an execution's an `ExecutionAnswer`; stored bytes that
// do not decode as the kind the waiter asked for are a fault, never a
// different result.
fn deliver(reply: Reply, settled: Settled) -> Nil {
  case reply {
    RunReply(reply:) -> process.send(reply, run_answer(settled))
    ExecutionReply(reply:) -> process.send(reply, execution_answer(settled))
  }
}

fn run_answer(settled: Settled) -> RunAnswer {
  case settled {
    SettledStored(stored:) -> stored_answer(stored)
    SettledLost -> protocol.RunLost
    SettledRefused(refusal:) -> protocol.RunRefused(refusal)
  }
}

fn execution_answer(settled: Settled) -> ExecutionAnswer {
  case settled {
    SettledStored(stored:) ->
      case codec.decode_stored(stored) {
        Ok(codec.StoredExecution(value:)) -> protocol.ExecutionFinished(value)
        Ok(codec.StoredOutcome(..)) ->
          protocol.ExecutionRefused(damaged("an execution value"))
        Error(report) -> protocol.ExecutionRefused(damaged(report.expected))
      }
    SettledLost -> protocol.ExecutionLost
    SettledRefused(refusal:) -> protocol.ExecutionRefused(refusal)
  }
}

// --- stop -----------------------------------------------------------------------

// The orchestrator's record of an execution closed. The ledger's
// `stop_or_fence` decides in one transaction: a running row turns lost, and
// then the program is stopped here; a key with no row is barred, so a start
// still in flight from a dead worker never runs. Anything else, including a
// refusal for another incarnation, changes nothing. There is no reply, because
// the orchestrator's reconciler sends a stop again for a row it still sees
// running.
fn stop_execution(
  state: State(census),
  key: Key,
  incarnation: Int,
) -> State(census) {
  let stopped =
    exec_ledger.stop_or_fence(
      state.ledger,
      to_ledger(key),
      incarnation,
      protocol.execution_tool,
    )
  case stopped, dict.get(state.live, key) {
    Ok(exec_ledger.Stopped), Ok(live) -> {
      let state = answer_waiters(state, key, live, SettledLost)
      halt(state, key, live)
    }
    Ok(exec_ledger.Stopped), Error(Nil)
    | Ok(exec_ledger.Barred), _
    | Ok(exec_ledger.Untouched(..)), _
    | Error(_), _
    -> state
  }
}

// Starts one task as a weft run that reports to a fresh sink, and returns the
// bookkeeping the host needs to hear it and to cancel it.
fn start_job(
  state: State(census),
  task: fn() -> Result(JobResult(census), Nil),
) -> #(
  State(census),
  Int,
  Subject(weft.Pulled(JobResult(census), Nil)),
  weft.Cancel,
) {
  let id = state.next_job
  let sink = process.new_subject()
  let cancel = weft.cancel_signal()
  let _relay =
    weft.new([task])
    |> weft.cancel_with(cancel)
    |> weft.start_relayed(to: sink)
  #(State(..state, next_job: id + 1), id, sink, cancel)
}

// --- results ------------------------------------------------------------------

fn job_finished(
  state: State(census),
  id: Int,
  pulled: weft.Pulled(JobResult(census), Nil),
) -> State(census) {
  case dict.get(state.jobs, id), pulled {
    Error(Nil), _ -> state
    Ok(tracked), weft.PulledOutcome(outcome:) ->
      settle_job(state, id, tracked, outcome)
    Ok(tracked), weft.RunLost(reason: _) ->
      drop_job(job_lost(state, id, tracked), id)
    Ok(_tracked), weft.AllDelivered -> drop_job(state, id)
    Ok(_tracked), weft.NotYet -> state
  }
}

// One task's account. Only a completed task carries a result; every other
// ending means the work stopped without one, and the host cannot say what it
// did.
fn settle_job(
  state: State(census),
  id: Int,
  tracked: Tracked(census),
  outcome: weft.Outcome(JobResult(census), Nil),
) -> State(census) {
  case outcome {
    weft.Completed(index: _, value: ToolRan(outcome: finished)) ->
      case tracked.job {
        RunJob(key:) ->
          run_finished(
            state,
            id,
            key,
            Finished(
              stored: codec.encode_outcome(finished),
              oversized: oversized_outcome,
            ),
          )
        CloseJob(..) | BuildJob(..) -> job_lost(state, id, tracked)
      }
    weft.Completed(index: _, value: ProgramRan(value:)) ->
      case tracked.job {
        RunJob(key:) ->
          run_finished(
            state,
            id,
            key,
            Finished(
              stored: codec.encode_execution(value),
              oversized: oversized_value,
            ),
          )
        CloseJob(..) | BuildJob(..) -> job_lost(state, id, tracked)
      }
    weft.Completed(index: _, value: ScopeClosed(outcome: closed)) ->
      case tracked.job {
        CloseJob(session:, workspace:, incarnation:, link:, reply:) ->
          finish_closed(
            state,
            session,
            workspace,
            incarnation,
            link,
            closed,
            reply,
          )
        RunJob(..) | BuildJob(..) -> job_lost(state, id, tracked)
      }
    weft.Completed(index: _, value: PlaneBuilt(built:)) ->
      case tracked.job {
        BuildJob(session:, link:, unacked:, reply:) ->
          plane_built(state, session, link, unacked, reply, built)
        RunJob(..) | CloseJob(..) -> job_lost(state, id, tracked)
      }
    weft.Failed(index: _, error: Nil)
    | weft.Crashed(index: _, reason: _)
    | weft.Abandoned(index: _)
    | weft.NeverStarted(index: _)
    | weft.DrainProofLost(index: _, reason: _)
    | weft.CancellationUnconfirmed(index: _) -> job_lost(state, id, tracked)
  }
}

// The relay is over, so the signal that could still cancel it is spent.
fn drop_job(state: State(census), id: Int) -> State(census) {
  case dict.get(state.jobs, id) {
    Ok(tracked) -> {
      weft.cancel(tracked.cancel)
      State(..state, jobs: dict.delete(state.jobs, id))
    }
    Error(Nil) -> state
  }
}

// What a finished task hands the commit: the bytes it wants stored, and how to
// say "too large" in its own kind when they do not fit the reservation.
type Finished {
  Finished(stored: BitArray, oversized: fn(Int, Int) -> BitArray)
}

// A call ended with a result. The row is made terminal before any waiter hears
// of it, so a reply never promises what the ledger does not hold. A result for
// a call that was cancelled meanwhile has no live entry and is dropped.
fn run_finished(
  state: State(census),
  id: Int,
  key: Key,
  finished: Finished,
) -> State(census) {
  case dict.get(state.live, key) {
    Ok(live) if live.job == id -> {
      let settled = commit_outcome(state, key, finished)
      answer_waiters(state, key, live, settled)
    }
    Ok(_other) | Error(Nil) -> state
  }
}

// Stores the result and says what was stored. A result larger than the
// reservation is replaced by one of its own kind that says so and fits, which
// is stored in its place; a ledger that cannot take even that leaves the call
// lost.
fn commit_outcome(
  state: State(census),
  key: Key,
  finished: Finished,
) -> Settled {
  case exec_ledger.finish(state.ledger, to_ledger(key), finished.stored) {
    Ok(Nil) -> SettledStored(finished.stored)
    Error(exec_ledger.OutcomeTooLarge(reserved:, size:)) -> {
      let replaced = finished.oversized(reserved, size)
      case exec_ledger.finish(state.ledger, to_ledger(key), replaced) {
        Ok(Nil) -> SettledStored(replaced)
        Error(_) -> lose(state, key)
      }
    }
    Error(_) -> lose(state, key)
  }
}

// A tool outcome too large for its reservation, as the failure stored instead.
fn oversized_outcome(reserved: Int, size: Int) -> BitArray {
  codec.encode_outcome(
    ToolFailed(reason: too_large("the tool's result", reserved, size)),
  )
}

// An execution value too large for its reservation, as the errored value
// stored instead. It has the shape `execution_value` gives a program that
// returned an error, so a reader of the record sees an ordinary failed run.
fn oversized_value(reserved: Int, size: Int) -> BitArray {
  codec.encode_execution(
    json.Object([
      #("status", json.String("errored")),
      #(
        "message",
        json.String(too_large("the program's result", reserved, size)),
      ),
      #("details", json.Null),
    ]),
  )
}

fn too_large(what: String, reserved: Int, size: Int) -> String {
  what
  <> " is "
  <> int.to_string(size)
  <> " bytes and the executor reserved "
  <> int.to_string(reserved)
  <> " for it"
}

fn lose(state: State(census), key: Key) -> Settled {
  let _marked = exec_ledger.mark_unknown(state.ledger, to_ledger(key))
  SettledLost
}

// A job ended without a result. For a call that is still live, that makes its
// outcome lost; for a call already settled or cancelled it changes nothing.
fn job_lost(
  state: State(census),
  id: Int,
  tracked: Tracked(census),
) -> State(census) {
  case tracked.job {
    RunJob(key:) ->
      case dict.get(state.live, key) {
        Ok(live) if live.job == id ->
          answer_waiters(state, key, live, lose(state, key))
        Ok(_other) | Error(Nil) -> state
      }
    CloseJob(session:, workspace:, incarnation:, link:, reply:) ->
      finish_closed(
        state,
        session,
        workspace,
        incarnation,
        link,
        protocol.UnknownCleanup(count: 1),
        reply,
      )

    // A build that died without a result may have started helpers nobody
    // holds, so the scope is left without a plane and the sender is told why.
    BuildJob(session:, link:, unacked: _, reply:) ->
      build_failed(
        state,
        session,
        link,
        reply,
        "the workspace build ended without a result",
      )
  }
}

// Sends one answer to every waiter, stops watching them, and forgets the call.
fn answer_waiters(
  state: State(census),
  key: Key,
  live: Live,
  settled: Settled,
) -> State(census) {
  let watches =
    list.fold(live.waiters, state.watches, fn(watches, waiter) {
      deliver(waiter.reply, settled)
      process.demonitor_process(waiter.watch)
      dict.delete(watches, waiter.watch)
    })
  State(..state, live: dict.delete(state.live, key), watches:)
}

// --- callers ------------------------------------------------------------------

// A watched caller exited. It is no longer a waiter whatever the reason; the
// reason decides whether its call stops with it.
fn caller_down(state: State(census), down: Down) -> State(census) {
  case down {
    process.ProcessDown(monitor:, reason:, pid: _) ->
      case dict.get(state.watches, monitor) {
        Error(Nil) -> state
        Ok(key) -> waiter_gone(state, key, monitor, reason)
      }
    process.PortDown(..) -> state
  }
}

fn waiter_gone(
  state: State(census),
  key: Key,
  monitor: Monitor,
  reason: ExitReason,
) -> State(census) {
  let watches = dict.delete(state.watches, monitor)
  case dict.get(state.live, key) {
    Error(Nil) -> State(..state, watches:)
    Ok(live) -> {
      let waiters =
        list.filter(live.waiters, fn(waiter) { waiter.watch != monitor })
      let live = Live(..live, waiters:)
      let state =
        State(..state, watches:, live: dict.insert(state.live, key, live))
      case waiters, cancels_run(reason) {
        [], True -> cancel_run(state, key, live)
        _, _ -> state
      }
    }
  }
}

// Stops a call nobody is waiting for. The row becomes `Unknown` first, so no
// later request can start it again, then the run is halted.
fn cancel_run(state: State(census), key: Key, live: Live) -> State(census) {
  let _marked = exec_ledger.mark_unknown(state.ledger, to_ledger(key))
  halt(state, key, live)
}

// Kills a live call's worker and forgets it; its row is already settled or
// lost. A background program also has its broker step aborted, because its
// satellite and jailed calls run under that step and are not children of the
// worker, as a local execution service aborts the step when it stops one.
fn halt(state: State(census), key: Key, live: Live) -> State(census) {
  case dict.get(state.jobs, live.job) {
    Ok(tracked) -> weft.cancel(tracked.cancel)
    Error(Nil) -> Nil
  }
  case live.kind, dict.get(state.placements, key.session) {
    Execution, Ok(Ready(placement)) ->
      placement.plane.abort_step(key.op, key.step)
    Execution, Ok(Building(..)) | Execution, Error(Nil) | ToolCall, _ -> Nil
  }
  State(..state, live: dict.delete(state.live, key))
}

// --- close --------------------------------------------------------------------

// Closes a scope. The ledger commit that sets `Closing` is the fence: from it
// on no call is admitted. Live calls are then cancelled and their waiters told
// the outcome is lost, and the plane retires its children off the host's own
// process so other sessions keep being served. A repeat of a close that has
// finished answers the stored outcome and does no work.
fn close(
  state: State(census),
  session: String,
  workspace: String,
  incarnation: Int,
  reply: Subject(Result(CloseOutcome, Refusal)),
) -> State(census) {
  case dict.get(state.placements, session) {
    Ok(Building(..)) -> {
      process.send(reply, Error(protocol.PlaneBuilding))
      state
    }
    Ok(Ready(..)) | Error(Nil) ->
      close_scope(state, session, workspace, incarnation, reply)
  }
}

// The ledger half of a close, then the plane's: the fence first, so nothing is
// admitted from here on.
fn close_scope(
  state: State(census),
  session: String,
  workspace: String,
  incarnation: Int,
  reply: Subject(Result(CloseOutcome, Refusal)),
) -> State(census) {
  case exec_ledger.begin_close(state.ledger, session, workspace, incarnation) {
    // A scope that already ended at this incarnation answers what it stored.
    // The orchestrator asks again when a reply was lost or the host went
    // away mid-close, and a refusal would leave it unable to learn that the
    // cleanup finished. The plane is not asked a second time: the ledger row
    // is the evidence, and `begin_close` has already checked the workspace
    // and the incarnation.
    Error(exec_ledger.ScopeNotOpen(state: exec_ledger.Closed(outcome:))) -> {
      process.send(reply, Ok(from_ledger_close(outcome)))
      state
    }
    Error(error) -> {
      process.send(reply, Error(refusal_of(error)))
      state
    }
    Ok(Nil) -> {
      let state = cancel_session(state, session)
      case dict.get(state.placements, session) {
        Ok(Ready(placement)) -> {
          let state =
            State(..state, placements: dict.delete(state.placements, session))
          start_close(state, placement, session, workspace, incarnation, reply)
        }

        // No plane in this VM means no witness: the executor restarted, or the
        // build never succeeded. Without a witness the cleanup is unproven.
        Ok(Building(..)) | Error(Nil) ->
          finish_closed_without_link(
            state,
            session,
            workspace,
            incarnation,
            protocol.UnknownCleanup(count: 0),
            reply,
          )
      }
    }
  }
}

fn start_close(
  state: State(census),
  placement: Placement(census),
  session: String,
  workspace: String,
  incarnation: Int,
  reply: Subject(Result(CloseOutcome, Refusal)),
) -> State(census) {
  let close_plane = placement.plane.close
  let children = placement.children
  let #(state, id, sink, cancel) =
    start_job(state, fn() {
      Ok(ScopeClosed(close_plane(fn() { retire_children(children) })))
    })
  let job =
    CloseJob(session:, workspace:, incarnation:, link: placement.link, reply:)
  State(
    ..state,
    jobs: dict.insert(state.jobs, id, Tracked(job:, sink:, cancel:)),
  )
}

// Cancels every live call of a session, telling its waiters the outcome is
// lost, because the scope is going away under them.
fn cancel_session(state: State(census), session: String) -> State(census) {
  dict.fold(state.live, state, fn(state, key, live) {
    case key.session == session {
      True -> {
        let state = answer_waiters(state, key, live, SettledLost)
        cancel_run(state, key, live)
      }
      False -> state
    }
  })
}

fn finish_closed(
  state: State(census),
  session: String,
  workspace: String,
  incarnation: Int,
  link: owner_link.Link,
  outcome: CloseOutcome,
  reply: Subject(Result(CloseOutcome, Refusal)),
) -> State(census) {
  owner_link.stop(link)
  finish_closed_without_link(
    state,
    session,
    workspace,
    incarnation,
    outcome,
    reply,
  )
}

fn finish_closed_without_link(
  state: State(census),
  session: String,
  workspace: String,
  incarnation: Int,
  outcome: CloseOutcome,
  reply: Subject(Result(CloseOutcome, Refusal)),
) -> State(census) {
  let recorded =
    exec_ledger.finish_close(
      state.ledger,
      session,
      workspace,
      incarnation,
      to_ledger_close(outcome),
    )
  case recorded {
    Ok(Nil) -> process.send(reply, Ok(outcome))
    Error(error) -> process.send(reply, Error(refusal_of(error)))
  }
  state
}

// --- queries ------------------------------------------------------------------

fn lookup(state: State(census), key: Key) -> Result(protocol.Lookup, Refusal) {
  case exec_ledger.query(state.ledger, to_ledger(key)) {
    Ok(exec_ledger.Missing) -> Ok(protocol.Missing)
    Ok(exec_ledger.Found(found)) -> lookup_of(found)
    Error(error) -> Error(refusal_of(error))
  }
}

// What a row says, in the protocol's words. A stored outcome that no longer
// decodes is a fault, never a different result.
fn lookup_of(found: exec_ledger.CallState) -> Result(protocol.Lookup, Refusal) {
  case found {
    exec_ledger.Admitted -> Ok(protocol.Admitted)
    exec_ledger.Unknown -> Ok(protocol.Unknown)

    // The orchestrator staged this call's result and the host kept only the
    // key. The outcome is not recoverable from here, which is what `Unknown`
    // says, and the key never starts again.
    exec_ledger.Acked -> Ok(protocol.Unknown)

    // A terminal row holds either kind of result; the envelope says which, and
    // the answer names it, so recovery of a tool call never reads a program's
    // value as its outcome.
    exec_ledger.Terminal(stored) ->
      case codec.decode_stored(stored) {
        Ok(codec.StoredOutcome(outcome:)) -> Ok(protocol.Terminal(outcome))
        Ok(codec.StoredExecution(value:)) -> Ok(protocol.Executed(value))
        Error(report) -> Error(damaged(report.expected))
      }
  }
}

// Answers a query that must not leave a gap. A key with a row is reported as
// `lookup` reports it. A key without one is fenced in the ledger's own
// transaction, so a `Run` that is still in flight from a dead runtime finds the
// key taken and the answer given here stays true.
fn fenced_lookup(
  state: State(census),
  key: Key,
  incarnation: Int,
) -> Result(protocol.Lookup, Refusal) {
  let outcome =
    codec.encode_outcome(ToolFailed(reason: protocol.did_not_run_text))
  case
    exec_ledger.query_or_fence(
      state.ledger,
      to_ledger(key),
      incarnation,
      outcome,
    )
  {
    Ok(exec_ledger.Fenced) -> Ok(protocol.Fenced)
    Ok(exec_ledger.Standing(found)) -> lookup_of(found)
    Error(error) -> Error(refusal_of(error))
  }
}

fn unacked(
  state: State(census),
  session: String,
) -> Result(protocol.Unacked, Refusal) {
  exec_ledger.unacked(state.ledger, session)
  |> result.map(fn(found) {
    protocol.Unacked(
      terminal: list.map(found.terminal, from_ledger),
      unknown: list.map(found.unknown, from_ledger),
      executions: running_executions(state, session),
    )
  })
  |> result.map_error(refusal_of)
}

// The answer a stored outcome stands for. Bytes that no longer decode are
// reported as a fault and never as a different result.
fn stored_answer(stored: BitArray) -> RunAnswer {
  case codec.decode_outcome(stored) {
    Ok(outcome) -> protocol.RunFinished(outcome)
    Error(report) -> protocol.RunRefused(damaged(report.expected))
  }
}

fn damaged(detail: String) -> Refusal {
  protocol.ExecutorFault("a stored outcome is damaged: expected " <> detail)
}

// --- the selector -------------------------------------------------------------

// Everything the host listens to: its name, every monitor it holds, and the
// sink of each live job.
fn selector_for(state: State(census)) -> Selector(Event(census)) {
  let base =
    process.new_selector()
    |> process.select_map(process.named_subject(state.config.name), FromPeer)
    |> process.select_monitors(CallerDown)
  dict.fold(state.jobs, base, fn(selector, id, tracked) {
    process.select_map(selector, tracked.sink, fn(pulled) {
      JobFinished(job: id, pulled:)
    })
  })
}

// --- the ledger's vocabulary ---------------------------------------------------

fn to_ledger(key: Key) -> exec_ledger.Key {
  exec_ledger.Key(
    session: key.session,
    op: key.op,
    step: key.step,
    source_index: key.source_index,
  )
}

fn from_ledger(key: exec_ledger.Key) -> Key {
  protocol.Key(
    session: key.session,
    op: key.op,
    step: key.step,
    source_index: key.source_index,
  )
}

fn to_ledger_close(outcome: CloseOutcome) -> exec_ledger.CloseOutcome {
  case outcome {
    protocol.AllRetired -> exec_ledger.AllRetired
    protocol.UnknownCleanup(count:) -> exec_ledger.UnknownCleanup(count:)
  }
}

fn from_ledger_close(outcome: exec_ledger.CloseOutcome) -> CloseOutcome {
  case outcome {
    exec_ledger.AllRetired -> protocol.AllRetired
    exec_ledger.UnknownCleanup(count:) -> protocol.UnknownCleanup(count:)
  }
}

// Every ledger error is named, so a new one fails to compile here and gets a
// wire meaning on purpose.
fn refusal_of(error: exec_ledger.Error) -> Refusal {
  case error {
    exec_ledger.Invalid(reason:) -> protocol.Invalid(reason)
    exec_ledger.Unsupported ->
      protocol.ExecutorFault("the ledger file is not one this build can use")
    exec_ledger.NoSuchScope -> protocol.NoSuchScope
    exec_ledger.WorkspaceMismatch(stored:) -> protocol.WorkspaceMismatch(stored)
    exec_ledger.StaleIncarnation(stored:) -> protocol.StaleIncarnation(stored)
    exec_ledger.StaleToken -> protocol.StaleToken
    exec_ledger.ScopeNotOpen(state: _) -> protocol.ScopeNotOpen
    exec_ledger.ScopeClosing -> protocol.ScopeClosing
    exec_ledger.ScopeNotClosing(state: _) ->
      protocol.Invalid("the scope is not closing")
    exec_ledger.UncleanClose(count:) -> protocol.UncleanClose(count)
    exec_ledger.NotReleasable(state: _) ->
      protocol.Invalid("the scope is not releasable")
    exec_ledger.CapacityExhausted(limit:) -> protocol.CapacityExhausted(limit)
    exec_ledger.BudgetExhausted(limit:) -> protocol.BudgetExhausted(limit)
    exec_ledger.NoSuchCall -> protocol.Invalid("the executor has no such call")
    exec_ledger.CallNotAdmitted -> protocol.Invalid("the call is not running")
    exec_ledger.OutcomeTooLarge(reserved:, size:) ->
      protocol.ExecutorFault(
        "an outcome of "
        <> int.to_string(size)
        <> " bytes did not fit its reservation of "
        <> int.to_string(reserved),
      )
    exec_ledger.DigestMismatch(key: _) ->
      protocol.ExecutorFault("a stored outcome does not match its digest")
    exec_ledger.MalformedRow(reason:) -> protocol.ExecutorFault(reason)
    exec_ledger.Database(reason:) -> protocol.ExecutorFault(reason)
  }
}
