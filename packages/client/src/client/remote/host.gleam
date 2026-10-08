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
//// Every tool run and every scope close is a weft run whose result arrives as
//// a message, so the host keeps answering other sessions while a tool runs. A
//// plane build (`PlaneFactory`) is the one step that runs inside the host,
//// because attach must finish before the next request for that session can be
//// valid. Integrations should keep the build bounded.
////
//// ## Flow
////
//// `start` → `initialise` → `handle_event` → `handle_peer` → `attach`,
//// `admit_run`, `close`
////
//// 1. `initialise` registers the name and opens the ledger, which turns every
////    row the previous VM left `Admitted` into `Unknown`.
//// 2. `handle_event` takes one message: a peer's request, a job's result, or a
////    caller's `DOWN`, and rebuilds the selector so every live job is listened
////    to.
//// 3. `attach` binds a runtime incarnation to its scope in the ledger and
////    builds or re-points the scope's plane.
//// 4. `admit_run` consults the ledger and either `start_run`s the tool,
////    `join_run`s a live call, or answers from the stored row.
//// 5. `job_finished` commits a tool's outcome with `commit_outcome` and answers
////    every waiter, or settles the call as lost.
//// 6. `caller_down` applies `cancels_run` to an aborted or unreachable caller.
//// 7. `close` fences the scope, cancels its calls, and `finish_closed` records
////    how the plane's cleanup ended.

import client/owner_services.{type OwnerServices}
import client/remote/address.{type Address}
import client/remote/codec
import client/remote/owner_link
import client/remote/protocol.{
  type CloseOutcome, type HostMessage, type Key, type Refusal, type RunAnswer,
}
import client/wiring.{type Authority}
import core/clock.{type Clock}
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process.{
  type Down, type ExitReason, type Monitor, type Name, type Selector,
  type Subject,
}
import gleam/int
import gleam/list
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
  )
}

/// The workspace plane for one scope, as the host sees it.
pub type Plane(census) {
  Plane(
    /// Runs one tool call to its outcome. It runs in a process the host owns and
    /// may cancel by killing it, so a caller watch in the plane's broker stops
    /// whatever the call started.
    run: fn(ToolRun, Authority) -> ToolOutcome,
    /// What the plane reports about its machine, returned with every attach.
    census: census,
    /// Retires the plane's children and reports how that ended. Only this
    /// result is a retirement witness; a timeout or a `DOWN` never is.
    close: fn() -> CloseOutcome,
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
    /// The executor's clock, handed to every plane.
    clock: Clock,
    /// Builds a scope's plane.
    factory: PlaneFactory(census),
  )
}

/// The default reservation per call: four mebibytes.
pub const default_max_result_bytes = 4_194_304

// One message the host handles. A peer's request arrives on the host's name, a
// job's result on the sink of the weft run that produced it, and a monitored
// caller's exit as a `DOWN`.
type Event(census) {
  FromPeer(message: HostMessage(census))
  JobFinished(job: Int, pulled: weft.Pulled(JobResult, Nil))
  CallerDown(down: Down)
}

// What a job's task returns when it completes.
type JobResult {
  ToolRan(outcome: ToolOutcome)
  ScopeClosed(outcome: CloseOutcome)
}

// What a job is for.
type Job {
  RunJob(key: Key)
  CloseJob(
    session: String,
    workspace: String,
    incarnation: Int,
    link: owner_link.Link,
    reply: Subject(Result(CloseOutcome, Refusal)),
  )
}

// A started job: where its result arrives, and the signal that cancels it.
type Tracked {
  Tracked(
    job: Job,
    sink: Subject(weft.Pulled(JobResult, Nil)),
    cancel: weft.Cancel,
  )
}

// A scope's plane and the link its owner callbacks go through.
type Placement(census) {
  Placement(plane: Plane(census), link: owner_link.Link)
}

// A call that is running now: the job that runs it and everyone waiting on it.
type Live {
  Live(job: Int, waiters: List(Waiter))
}

// One process waiting on a live call, and the monitor that watches it.
type Waiter {
  Waiter(reply: Subject(RunAnswer), watch: Monitor)
}

type State(census) {
  State(
    config: Config(census),
    ledger: exec_ledger.Ledger,
    placements: Dict(String, Placement(census)),
    live: Dict(Key, Live),
    watches: Dict(Monitor, Key),
    jobs: Dict(Int, Tracked),
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
pub fn start(config: Config(census)) -> actor.StartResult(Address(census)) {
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
    process.Abnormal(detail) -> !is_noconnection(detail)
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
  actor.Initialised(State(census), Event(census), Address(census)),
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
      session:,
      workspace:,
      incarnation:,
      token:,
      owner_port:,
      reply:,
    ) ->
      attach(state, session, workspace, incarnation, token, owner_port, reply)
    protocol.Run(key:, incarnation:, token:, run:, authority:, reply:) ->
      admit_run(state, key, incarnation, token, run, authority, reply)
    protocol.Query(key:, reply:) -> {
      process.send(reply, lookup(state, key))
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
// whether a plane is built or only re-pointed.
fn attach(
  state: State(census),
  session: String,
  workspace: String,
  incarnation: Int,
  token: BitArray,
  owner_port: Subject(protocol.OwnerMessage),
  reply: Subject(Result(protocol.Attached(census), Refusal)),
) -> State(census) {
  let attached =
    exec_ledger.attach(
      state.ledger,
      session,
      workspace,
      incarnation,
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
        )
      case
        place(state, session, workspace, incarnation, owner_port, bound.how)
      {
        Ok(#(state, census)) -> {
          process.send(reply, Ok(protocol.Attached(census:, unacked:)))
          state
        }
        Error(reason) -> {
          // The scope stays open without a plane, so the next attach retries the
          // build at the same incarnation instead of finding a closed scope.
          process.send(reply, Error(protocol.NoPlane(reason)))
          state
        }
      }
    }
  }
}

// Gives the scope a plane. A rebind keeps the plane it has and re-points its
// owner link; every other case builds one, retiring a stale link first.
fn place(
  state: State(census),
  session: String,
  workspace: String,
  incarnation: Int,
  owner_port: Subject(protocol.OwnerMessage),
  how: exec_ledger.Attachment,
) -> Result(#(State(census), census), String) {
  case how, dict.get(state.placements, session) {
    exec_ledger.Rebound, Ok(placement) -> {
      owner_link.replace(placement.link, owner_port)
      Ok(#(state, placement.plane.census))
    }
    exec_ledger.Rebound, Error(Nil) ->
      build_plane(state, session, workspace, incarnation, owner_port)
    exec_ledger.Created, Ok(stale) | exec_ledger.Reopened, Ok(stale) -> {
      owner_link.stop(stale.link)
      build_plane(state, session, workspace, incarnation, owner_port)
    }
    exec_ledger.Created, Error(Nil) | exec_ledger.Reopened, Error(Nil) ->
      build_plane(state, session, workspace, incarnation, owner_port)
  }
}

fn build_plane(
  state: State(census),
  session: String,
  workspace: String,
  incarnation: Int,
  owner_port: Subject(protocol.OwnerMessage),
) -> Result(#(State(census), census), String) {
  use link <- result.try(owner_link.start(owner_port))
  let spec =
    AttachSpec(
      session:,
      workspace:,
      incarnation:,
      owner: owner_link.services(link, state.config.clock),
      clock: state.config.clock,
    )
  case state.config.factory(spec) {
    Ok(plane) -> {
      let placements =
        dict.insert(state.placements, session, Placement(plane:, link:))
      Ok(#(State(..state, placements:), plane.census))
    }
    Error(reason) -> {
      owner_link.stop(link)
      Error(reason)
    }
  }
}

// --- run ----------------------------------------------------------------------

// Admits one call. The ledger's answer, not the request, decides what happens.
fn admit_run(
  state: State(census),
  key: Key,
  incarnation: Int,
  token: BitArray,
  run: ToolRun,
  authority: Authority,
  reply: Subject(RunAnswer),
) -> State(census) {
  case dict.get(state.placements, key.session), process.subject_owner(reply) {
    Error(Nil), _ -> refuse_run(state, reply, no_plane())
    _, Error(Nil) ->
      refuse_run(
        state,
        reply,
        protocol.Invalid("the reply subject has no owner to watch"),
      )
    Ok(placement), Ok(_owner) -> {
      let admitted =
        exec_ledger.admit(
          state.ledger,
          to_ledger(key),
          incarnation,
          token,
          run.call.name,
          state.config.max_result_bytes,
          state.config.limits,
        )
      case admitted {
        Error(error) -> refuse_run(state, reply, refusal_of(error))
        Ok(exec_ledger.Fresh) ->
          start_run(state, placement, key, run, authority, reply)
        Ok(exec_ledger.Existing(exec_ledger.Admitted)) ->
          join_run(state, key, reply)
        Ok(exec_ledger.Existing(exec_ledger.Terminal(stored))) -> {
          process.send(reply, stored_answer(stored))
          state
        }
        Ok(exec_ledger.Existing(exec_ledger.Unknown)) -> {
          process.send(reply, protocol.RunLost)
          state
        }
      }
    }
  }
}

fn refuse_run(
  state: State(census),
  reply: Subject(RunAnswer),
  refusal: Refusal,
) -> State(census) {
  process.send(reply, protocol.RunRefused(refusal))
  state
}

fn no_plane() -> Refusal {
  protocol.NoPlane("the scope has no workspace plane; attach first")
}

// Starts the tool as a weft run. The run's cancel signal is the host's only
// handle on it: killing the signal makes the scope kill the worker, and the
// worker's death is what the plane's broker watches to stop a helper.
fn start_run(
  state: State(census),
  placement: Placement(census),
  key: Key,
  run: ToolRun,
  authority: Authority,
  reply: Subject(RunAnswer),
) -> State(census) {
  let run_tool = placement.plane.run
  let #(state, id, sink, cancel) =
    start_job(state, fn() { Ok(ToolRan(run_tool(run, authority))) })
  let tracked = Tracked(job: RunJob(key), sink:, cancel:)
  let state = State(..state, jobs: dict.insert(state.jobs, id, tracked))
  let state =
    State(
      ..state,
      live: dict.insert(state.live, key, Live(job: id, waiters: [])),
    )
  add_waiter(state, key, reply)
}

// Joins a call that is already running. A row that says `Admitted` with no live
// run behind it can only follow a failed write, and the honest answer is that
// the outcome is lost.
fn join_run(
  state: State(census),
  key: Key,
  reply: Subject(RunAnswer),
) -> State(census) {
  case dict.get(state.live, key) {
    Ok(_live) -> add_waiter(state, key, reply)
    Error(Nil) -> {
      let _marked = exec_ledger.mark_unknown(state.ledger, to_ledger(key))
      process.send(reply, protocol.RunLost)
      state
    }
  }
}

// Watches the process that owns `reply` and records it as a waiter. The owner
// was checked before admission, so the monitor always has a process to watch.
fn add_waiter(
  state: State(census),
  key: Key,
  reply: Subject(RunAnswer),
) -> State(census) {
  case dict.get(state.live, key), process.subject_owner(reply) {
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

// Starts one task as a weft run that reports to a fresh sink, and returns the
// bookkeeping the host needs to hear it and to cancel it.
fn start_job(
  state: State(census),
  task: fn() -> Result(JobResult, Nil),
) -> #(State(census), Int, Subject(weft.Pulled(JobResult, Nil)), weft.Cancel) {
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
  pulled: weft.Pulled(JobResult, Nil),
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
  tracked: Tracked,
  outcome: weft.Outcome(JobResult, Nil),
) -> State(census) {
  case outcome {
    weft.Completed(index: _, value: ToolRan(outcome: finished)) ->
      case tracked.job {
        RunJob(key:) -> run_finished(state, id, key, finished)
        CloseJob(..) -> job_lost(state, id, tracked)
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
        RunJob(..) -> job_lost(state, id, tracked)
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

// A tool ended with an outcome. The row is made terminal before any waiter
// hears of it, so a reply never promises what the ledger does not hold. An
// outcome for a call that was cancelled meanwhile has no live entry and is
// dropped.
fn run_finished(
  state: State(census),
  id: Int,
  key: Key,
  outcome: ToolOutcome,
) -> State(census) {
  case dict.get(state.live, key) {
    Ok(live) if live.job == id -> {
      let answer = commit_outcome(state, key, outcome)
      answer_waiters(state, key, live, answer)
    }
    Ok(_other) | Error(Nil) -> state
  }
}

// Stores the outcome and says what was stored. A result larger than the
// reservation is replaced by a failure that fits, which is stored in its place;
// a ledger that cannot take even that leaves the call lost.
fn commit_outcome(
  state: State(census),
  key: Key,
  outcome: ToolOutcome,
) -> RunAnswer {
  case
    exec_ledger.finish(
      state.ledger,
      to_ledger(key),
      codec.encode_outcome(outcome),
    )
  {
    Ok(Nil) -> protocol.RunFinished(outcome)
    Error(exec_ledger.OutcomeTooLarge(reserved:, size:)) -> {
      let replaced =
        ToolFailed(
          reason: "the tool's result is "
          <> int.to_string(size)
          <> " bytes and the executor reserved "
          <> int.to_string(reserved)
          <> " for it",
        )
      case
        exec_ledger.finish(
          state.ledger,
          to_ledger(key),
          codec.encode_outcome(replaced),
        )
      {
        Ok(Nil) -> protocol.RunFinished(replaced)
        Error(_) -> lose(state, key)
      }
    }
    Error(_) -> lose(state, key)
  }
}

fn lose(state: State(census), key: Key) -> RunAnswer {
  let _marked = exec_ledger.mark_unknown(state.ledger, to_ledger(key))
  protocol.RunLost
}

// A job ended without a result. For a call that is still live, that makes its
// outcome lost; for a call already settled or cancelled it changes nothing.
fn job_lost(state: State(census), id: Int, tracked: Tracked) -> State(census) {
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
  }
}

// Sends one answer to every waiter, stops watching them, and forgets the call.
fn answer_waiters(
  state: State(census),
  key: Key,
  live: Live,
  answer: RunAnswer,
) -> State(census) {
  let watches =
    list.fold(live.waiters, state.watches, fn(watches, waiter) {
      process.send(waiter.reply, answer)
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
// later request can start it again, then the run's worker is killed.
fn cancel_run(state: State(census), key: Key, live: Live) -> State(census) {
  let _marked = exec_ledger.mark_unknown(state.ledger, to_ledger(key))
  case dict.get(state.jobs, live.job) {
    Ok(tracked) -> weft.cancel(tracked.cancel)
    Error(Nil) -> Nil
  }
  State(..state, live: dict.delete(state.live, key))
}

fn is_noconnection(detail: dynamic.Dynamic) -> Bool {
  detail == atom.to_dynamic(atom.create("noconnection"))
}

// --- close --------------------------------------------------------------------

// Closes a scope. The ledger commit that sets `Closing` is the fence: from it
// on no call is admitted. Live calls are then cancelled and their waiters told
// the outcome is lost, and the plane retires its children off the host's own
// process so other sessions keep being served.
fn close(
  state: State(census),
  session: String,
  workspace: String,
  incarnation: Int,
  reply: Subject(Result(CloseOutcome, Refusal)),
) -> State(census) {
  case exec_ledger.begin_close(state.ledger, session, workspace, incarnation) {
    Error(error) -> {
      process.send(reply, Error(refusal_of(error)))
      state
    }
    Ok(Nil) -> {
      let state = cancel_session(state, session)
      case dict.get(state.placements, session) {
        Ok(placement) -> {
          let state =
            State(..state, placements: dict.delete(state.placements, session))
          start_close(state, placement, session, workspace, incarnation, reply)
        }

        // No plane in this VM means no witness: the executor restarted, or the
        // build never succeeded. Without a witness the cleanup is unproven.
        Error(Nil) ->
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
  let #(state, id, sink, cancel) =
    start_job(state, fn() { Ok(ScopeClosed(close_plane())) })
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
        let state = answer_waiters(state, key, live, protocol.RunLost)
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
    Ok(exec_ledger.Found(exec_ledger.Admitted)) -> Ok(protocol.Admitted)
    Ok(exec_ledger.Found(exec_ledger.Unknown)) -> Ok(protocol.Unknown)
    Ok(exec_ledger.Found(exec_ledger.Terminal(stored))) ->
      case codec.decode_outcome(stored) {
        Ok(outcome) -> Ok(protocol.Terminal(outcome))
        Error(report) -> Error(damaged(report.expected))
      }
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
