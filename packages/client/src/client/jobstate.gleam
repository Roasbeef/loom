//// The background job lifecycle as data: what a job is, what may happen
//// to it, what its durable `job/<id>` cell holds, and which transitions
//// between those two are legal.
////
//// A background job is a jailed process the harness started on a model's
//// behalf which is allowed to outlive the tool call that started it,
//// bounded by a wall deadline fixed at start, owned by a strand, and
//// killable through the same TERM-then-KILL ladder a foreground call
//// has. It is the fourth lifecycle owner in the tree, beside a subagent
//// strand, a code-mode satellite and an extension satellite, and it is
//// the only one whose durable identity is a *process handle* rather than
//// a strand or a node.
////
//// ## Why this module holds no process
////
//// The actor and the runner that own a live job are WP2's work and they
//// live on weft. What is here is everything about a job that can be
//// decided without one: the state space, the transition relation, and
//// the codec for the cell. Two properties rest on that split.
////
//// The first is testability. A transition relation that is a pure
//// function of a state and an event can be enumerated by a property test
//// rather than supervised by one — every legal pair asserted, every
//// illegal pair asserted to be refused, with no scheduler in the loop and
//// no timing to flake. The actor then applies *only* the transitions this
//// module accepts, so the machine tested here is the machine that runs.
////
//// The second is that a restart has nothing but the cell. A job's process
//// is a child of a helper, the helper is a child of the daemon VM, and
//// nothing in this design survives the VM. So recovery never re-adopts:
//// it lists `job/*`, and every record whose state is not already terminal
//// is committed as `Lost(VmRestart)` before the strand resumes. That
//// sweep is a fold over decoded records and `is_terminal`, which is why
//// both are here and neither needs a runtime.
////
//// ## Why the cell is reserved, and what surviving a rewind means
////
//// `job/` is a reserved corner of `fact.custom`
//// (`runtime/api.job_fact_prefix`), so `put_fact` refuses it and `facts`
//// hides it. The state field is what a poll renders and what the restart
//// sweep filters on, so a model that could write here could mark its own
//// job terminal — the sweep then skips a process that is still running
//// and nothing ever reaps it — or hide a running one from the only
//// listing that would have shown it.
////
//// A register survives compaction untouched (the compaction write is one
//// entry) and survives a rewind. For a fired-mark that is issue #184's
//// bug; here it is the behaviour we want and it is worth saying so
//// plainly rather than leaving a reader to wonder whether it was noticed.
//// A job is a live process, not a conversation event: navigating the
//// conversation tree must neither kill one nor resurrect one.
////
//// A register is also state, not a channel. Nothing here wakes anybody.
//// A model learns that its job exited by polling, which is what keeps the
//// jobs actor out of the strand's turn machinery entirely.

import broker/exec.{type ExecResult, ExecResult}
import core/corruption.{type CorruptionReport}
import core/ids.{type OpId}
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import runtime/api

/// A job's identity: the opaque last segment of its `job/<id>` cell key.
///
/// Constructor invariant, and the whole reason the type is opaque: the
/// text is non-empty and contains no `/`. A prefix is a path, so an id
/// carrying a separator would make `job/<id>` more than two segments —
/// `job_id_of_key` would no longer round-trip, and a prefix delete aimed
/// at one job could reach a neighbour whose id merely started with the
/// same bytes. The actor mints the text; this module only refuses one
/// that would break the key shape.
pub opaque type JobId {
  JobId(text: String)
}

/// Why a job is being stopped, or was stopped — the four parties that may
/// end a job that did not end of its own accord.
///
/// The cause is chosen when the stop is *requested* and carried through
/// draining into the terminal state, because the helper's `exec_exit`
/// cannot say it: a cancelled run whose payload had backgrounded its work
/// reports a clean exit, and `exec_exit.cancelled` says only *that* the
/// helper climbed the ladder, never at whose asking
/// (`protocol-change/006`).
pub type KillCause {
  /// The owning strand asked, through `job_kill`. A strand may always
  /// stop what it started, so this one needs no approval.
  ByOwner

  /// The wall deadline fixed at start expired. The deadline is never
  /// renewed: the token, the relay's receive deadline, the helper's own
  /// wall timer and the budget ledger all read the same number, and a
  /// model that needs longer starts a new job.
  ByDeadline

  /// The session is closing. Jobs die before the broker and its helpers
  /// close, by the actor's position in the ordered shutdown.
  BySessionStop

  /// `broker.abort` of the operation that started the job revoked its
  /// token and cancelled its helper. An abort of a *later* operation does
  /// not reach it, because detachment is what the model asked for.
  ByOperationAbort
}

/// Why a job can no longer be spoken for. Distinct from `Killed` in the
/// one way that matters to a reader of a poll: nobody stopped this job on
/// purpose and no `ExecResult` was ever observed, so what became of the
/// process is unknown rather than reported.
pub type LossReason {
  /// The VM that owned the helper restarted. Nothing in this design
  /// survives that, so recovery marks every non-terminal record with this
  /// reason rather than trying to re-adopt a process that is gone.
  VmRestart

  /// The jobs actor restarted. Every runner it owned died with it, which
  /// is the price of putting it in the restartable services tier instead
  /// of among the children whose death takes the session with them.
  OwnerRestart

  /// The helper carrying the execution went away without an `exec_exit` —
  /// a broken channel, a helper the broker declared dead. The distinction
  /// from `VmRestart` is worth keeping because it is the one loss that
  /// says something about this job rather than about the whole node.
  HelperLoss
}

/// Where a job is in its life. Three live states and three terminal ones;
/// `is_terminal` is the split, and every caller that sweeps or filters
/// asks through it rather than re-listing the variants.
pub type JobState {
  /// Cleared and dispatched, but the helper has not yet accepted the run.
  /// The record is committed in this state *before* the broker call, so a
  /// crash in the window leaves evidence a sweep can find — the effect
  /// sandwich applied to a spawn.
  Starting

  /// The helper accepted the run and the process is live. This is the
  /// only state whose deadline timer is armed, so leaving the state
  /// cancels it and a raced fire is dropped.
  Running

  /// A stop was asked for and the cancel ladder is climbing; the helper
  /// has not yet answered with an `exec_exit`. The cause is carried here
  /// rather than recomputed at settlement because the stop is what named
  /// it and the exit report cannot.
  Draining(by: KillCause)

  /// The job ended of its own accord. `result` is the helper's whole
  /// `exec_exit`, which is what lets a poll say "the command finished"
  /// rather than guessing from an exit byte.
  ///
  /// "Of its own accord" is an invariant here and not a hope: a report
  /// carrying `timed_out` or `cancelled` is attributed to `Killed` by
  /// the transition that reads it, so neither flag is ever true in a
  /// state this constructor built.
  ///
  /// Where the run's whole output went is the record's `spill` and not a
  /// payload here; `JobRecord` says why.
  Exited(result: ExecResult)

  /// The job was stopped and the helper reported the stopped execution.
  /// `by` is who asked, `result.cancelled` is the helper's own witness
  /// that it climbed the ladder — the two answer different questions and
  /// neither substitutes for the other.
  ///
  /// `by` is the cause the stop named when a stop passed through the
  /// actor, and the cause deduced from the report when one did not; the
  /// deduction is `exit_state` and its reasoning is written there.
  Killed(by: KillCause, result: ExecResult)

  /// The job can no longer be spoken for and no `ExecResult` was ever
  /// observed. Terminal, and deliberately so: a record that stayed live
  /// would be swept again on every later restart, and a poll would keep
  /// promising an answer that is never coming.
  Lost(reason: LossReason)
}

/// The part of a job's starting request a poll renders back: enough for a
/// model reading a listing weeks of conversation later to recognise which
/// of its jobs this is.
///
/// Constructor invariants: `argv` is the program and its arguments as the
/// broker received them, non-empty; `cwd` is the working directory inside
/// the jail; `requested_wall_ms` is what the *caller* asked for, which is
/// kept because it is not what the job got — the wall policy actually
/// granted is `deadline_ms - started_at_ms` on the record, and the gap
/// between the two is exactly the thing a model that asked for thirty
/// minutes on a ten-minute policy needs to be told.
///
/// The `bash` mode that started the job is deliberately absent. A record
/// exists only for a background call, so a stored mode would be a
/// constant every reader had to carry and no reader could use.
pub type JobSpec {
  JobSpec(argv: List(String), cwd: String, requested_wall_ms: Int)
}

/// Where a finished job's whole output was stored, once it has finished.
///
/// A job's output leaves the harness by two doors. The rolling tail
/// answers "what has it printed since I last looked" while the process
/// runs and is bounded, so it is not the output; these two content
/// addresses are, and the model reads them with `fs_read` exactly as it
/// reads any overflowed tool output.
///
/// Constructor invariants: each field is `Some` only for a stream that
/// carried at least one byte and whose staging file was promoted to its
/// content address, and the text is then a `sha256-`-prefixed ref
/// (`tools/blob.ref_for`). `None` therefore means "nothing to read" and
/// never "we lost it": a promotion that failed leaves `None` and the
/// terminal state still carries the helper's own byte counts, so the two
/// together say whether a stream had output that did not reach a blob.
pub type JobSpill {
  JobSpill(stdout_ref: Option(String), stderr_ref: Option(String))
}

/// One job's durable record — the `fact.custom` payload stored under
/// `job/<id>`.
///
/// Constructor invariants: `id` is the cell's own key tail, repeated in
/// the payload so a prefix scan needs no key parsing (the shape
/// `runtime/lineage` uses for the same reason); `owner` is the strand
/// that started the job and is the only strand permitted to poll or kill
/// it; `started_by` is the operation the job cleared under, which is what
/// `broker.abort` addresses and therefore what decides whether an
/// operator's abort reaches this job; `started_at_ms` and `deadline_ms`
/// are **absolute** instants in milliseconds on the session's own time
/// base, absolute rather than relative so a restart reasons toward the
/// same instant instead of restarting a clock; `state` is the only field
/// a *transition* changes; `spill` is empty until termination and is
/// written once, in the same commit as the terminal state.
///
/// The spill is a field of the record rather than a payload of the
/// terminal `JobState` variants, and that is a decision worth naming
/// because it is the weaker of the two shapes. Carrying it inside
/// `Exited` and `Killed` would make "a live job with a spill"
/// unrepresentable, which is the house preference — but it would also put
/// a value into the transition relation that no transition depends on,
/// and force every caller of `step` to have promoted its staging files
/// before it could ask what state a job is in. The relation stays a total
/// function of a state and an event; the writer sets `spill` with a
/// record update in the same breath, and this sentence is what stops the
/// next reader wondering whether the empty spill on a `Starting` record
/// was noticed. What the record-level field gives up is only the type's
/// own proof that a live job has no spill; what it does not give up is
/// the shape being settled before the first cell is written, because the
/// field is required by a total decoder from the first payload and never
/// grows an absent-means-none arm.
pub type JobRecord {
  JobRecord(
    id: JobId,
    owner: String,
    started_by: OpId,
    spec: JobSpec,
    started_at_ms: Int,
    deadline_ms: Int,
    state: JobState,
    spill: JobSpill,
  )
}

/// A record with nothing spilled yet — what admission mints, before the
/// job has produced a byte.
///
/// ## Examples
///
/// ```gleam
/// assert jobstate.no_spill()
///   == jobstate.JobSpill(stdout_ref: None, stderr_ref: None)
/// ```
///
pub fn no_spill() -> JobSpill {
  JobSpill(stdout_ref: None, stderr_ref: None)
}

/// Everything that may happen to a job, from the four parties that can
/// make something happen to one.
///
/// The set is closed and each variant carries the whole of what its
/// producer knows, which is what keeps the transition relation a total
/// function. Two shapes are deliberately folded rather than split: a
/// deadline expiring is a `KillRequested(by: ByDeadline)` because the
/// timer asks for the stop exactly as an owner does and the only
/// difference is who asked; and every way of losing custody is one
/// `RunnerLost` carrying its reason, mirroring `Lost` itself, because
/// three events feeding one three-variant enum would be the same
/// information written twice.
pub type JobEvent {
  /// The helper accepted the dispatched run. Sent once by the runner, on
  /// the relay's own channel, so it precedes any settlement for the same
  /// run.
  HelperAccepted

  /// Somebody asked for the job to stop, and named itself.
  KillRequested(by: KillCause)

  /// The helper reported the execution's end. The terminal event for a
  /// run that was accepted; exactly one arrives per accepted run.
  ///
  /// The sealed output rides beside this event rather than in it: the
  /// runner promotes its staging files at the same moment it hears the
  /// report, and the writer sets the record's `spill` in the same commit
  /// as the terminal state this event produces.
  ExitReported(result: ExecResult)

  /// Custody of the job was lost without an exit report.
  RunnerLost(reason: LossReason)
}

/// A transition the machine refuses. There are exactly two, and both mean
/// a caller's model of the job disagrees with the record's.
pub type IllegalTransition {
  /// Acceptance arrived for a job already past `Starting` and not
  /// draining. One run is accepted once; a second report means the runner
  /// dispatched twice, which the actor must fault on rather than absorb.
  AcceptedTwice(state: JobState)

  /// The record is already terminal. A terminal state is written once —
  /// it is the state the restart sweep skips and the state a poll reports
  /// as final — so nothing may move it, including a second copy of the
  /// event that made it terminal.
  AlreadyTerminal(state: JobState, event: JobEvent)
}

/// The reserved `fact.custom` key prefix every job record lives under.
/// One spelling, taken from `runtime/api` rather than repeated here: a
/// second literal that drifted from the one `reserved_fact_key` tests
/// would not fail to compile, it would silently unreserve the namespace.
pub const key_prefix = api.job_fact_prefix

/// Reads a minted job id, refusing one that would break the key shape.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(id) = jobstate.parse_job_id("01JQ8XZ")
/// assert jobstate.job_id_to_string(id) == "01JQ8XZ"
/// ```
///
/// ```gleam
/// assert jobstate.parse_job_id("build/1") == Error(Nil)
/// ```
///
/// ```gleam
/// assert jobstate.parse_job_id("") == Error(Nil)
/// ```
///
pub fn parse_job_id(text: String) -> Result(JobId, Nil) {
  case text == "" || string.contains(text, "/") {
    True -> Error(Nil)
    False -> Ok(JobId(text:))
  }
}

/// The text a job id was minted from.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(id) = jobstate.parse_job_id("01JQ8XZ")
/// assert jobstate.job_id_to_string(id) == "01JQ8XZ"
/// ```
///
pub fn job_id_to_string(id: JobId) -> String {
  id.text
}

/// The `fact.custom` register key one job's record lives under.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(id) = jobstate.parse_job_id("01JQ8XZ")
/// assert jobstate.job_key(id) == "job/01JQ8XZ"
/// ```
///
pub fn job_key(id: JobId) -> String {
  key_prefix <> id.text
}

/// The job a key names, or `Error(Nil)` for a key outside the namespace.
/// Total inverse of `job_key`, which is what lets a prefix scan recover an
/// id without a second source of truth about the key's shape — the prefix
/// is read from `key_prefix` here as it is there, so the namespace has one
/// spelling and cannot drift from the one `reserved_fact_key` tests.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(id) = jobstate.job_id_of_key("job/01JQ8XZ")
/// assert jobstate.job_id_to_string(id) == "01JQ8XZ"
/// ```
///
/// ```gleam
/// assert jobstate.job_id_of_key("agent/main/note") == Error(Nil)
/// ```
///
pub fn job_id_of_key(key: String) -> Result(JobId, Nil) {
  case string.starts_with(key, key_prefix) {
    True -> parse_job_id(string.drop_start(key, string.length(key_prefix)))
    False -> Error(Nil)
  }
}

/// Whether a job's life is over. The one question the restart sweep and
/// every listing ask, kept as a function so a fourth terminal state added
/// later reaches every caller by touching one `case`.
///
/// ## Examples
///
/// ```gleam
/// assert !jobstate.is_terminal(jobstate.Draining(by: jobstate.ByOwner))
/// ```
///
/// ```gleam
/// assert jobstate.is_terminal(jobstate.Lost(reason: jobstate.VmRestart))
/// ```
///
pub fn is_terminal(state: JobState) -> Bool {
  case state {
    Starting | Running | Draining(..) -> False
    Exited(..) | Killed(..) | Lost(..) -> True
  }
}

/// Applies one event to a job's record, or refuses it.
///
/// Only `state` ever moves: the id, the owner, the operation, the spec
/// and the two instants are fixed when the record is minted, so a caller
/// cannot rewrite a job's identity by feeding it an event.
///
/// ## Examples
///
/// ```gleam
/// // jobstate.step(record, jobstate.HelperAccepted)
/// // -> Ok(JobRecord(.., state: Running))
/// ```
///
/// ```gleam
/// // jobstate.step(exited_record, jobstate.HelperAccepted)
/// // -> Error(AlreadyTerminal(..))
/// ```
///
pub fn step(
  record: JobRecord,
  event: JobEvent,
) -> Result(JobRecord, IllegalTransition) {
  use next <- result.map(next_state(record.state, event))
  JobRecord(..record, state: next)
}

// The transition relation itself, split by state so each live state's
// four arms sit together with the reasoning for each.
//
// The terminal states share one arm and it is written by naming all three
// variants rather than with a catch-all, so a fourth terminal state added
// later is a compile error here instead of a silent absorption.
fn next_state(
  state: JobState,
  event: JobEvent,
) -> Result(JobState, IllegalTransition) {
  case state {
    Starting -> Ok(from_starting(event))

    Running -> from_running(event)

    Draining(by:) -> Ok(from_draining(by, event))

    // A terminal state is written once. It is what the restart sweep
    // skips and what a poll reports as final, so a later event is a
    // disagreement to report, never a state to overwrite.
    Exited(..) | Killed(..) | Lost(..) -> Error(AlreadyTerminal(state:, event:))
  }
}

// Every event is legal against `Starting`, including the two that skip
// `Running` entirely.
//
// A stop asked for before the helper accepted still drains: the clearance
// has already happened, so there is something to cancel. And an exit
// report against `Starting` is accepted rather than refused because the
// exit is ground truth — refusing it would leave a durable `Starting`
// cell for a process that is gone, which is exactly the "hide a running
// job" harm this namespace is reserved against, arriving by accident
// instead of by forgery.
fn from_starting(event: JobEvent) -> JobState {
  case event {
    HelperAccepted -> Running

    KillRequested(by:) -> Draining(by:)

    ExitReported(result:) -> exit_state(result)

    RunnerLost(reason:) -> Lost(reason:)
  }
}

// The one illegal live pair in the machine lives here.
//
// A second `HelperAccepted` against a running job cannot be a race: the
// runner sends it once, on the relay's own channel. A second means one
// job dispatched two runs, and absorbing that would leave the second
// execution with no record and no reaper.
fn from_running(event: JobEvent) -> Result(JobState, IllegalTransition) {
  case event {
    HelperAccepted -> Error(AcceptedTwice(state: Running))

    KillRequested(by:) -> Ok(Draining(by:))

    ExitReported(result:) -> Ok(exit_state(result))

    RunnerLost(reason:) -> Ok(Lost(reason:))
  }
}

// Draining absorbs both of the events that would be surprising anywhere
// else, and the first stop's cause is the one that survives.
//
// An acceptance arriving here is the ordinary race, not a bug: a stop
// asked for during `Starting` leaves the helper's acceptance in flight,
// and it changes nothing about a job whose ladder is already climbing. A
// second stop request is likewise a no-op, because a cancel is idempotent
// and because the party that asked first is the one a reader of the
// terminal state needs named — overwriting it would let a session-stop
// sweep erase the owner's own `job_kill` from the record.
fn from_draining(by: KillCause, event: JobEvent) -> JobState {
  case event {
    HelperAccepted -> Draining(by:)

    KillRequested(..) -> Draining(by:)

    ExitReported(result:) -> Killed(by:, result:)

    RunnerLost(reason:) -> Lost(reason:)
  }
}

// Where an exit report lands when the job was not draining: the report is
// the only witness to a stop nobody told the actor about, and it carries
// enough to say which stop it was.
//
// Two orderings put one here. The helper's own wall timer is armed from
// `exec_start` and the actor's deadline timer from the same number, so
// two clocks race to the same instant and the helper's can win by
// milliseconds — the report arrives before the actor sends its own
// `KillRequested(ByDeadline)`. And `broker.abort` of the operation that
// started the job revokes its token and cancels its helper directly; the
// actor has no hook on an abort, so the settlement is the first it hears.
// Recording `Exited` for either would be a poll rendering "finished" for
// a job an operator stopped, and a terminal state is written once, so no
// later event corrects it.
//
// The flags cannot say who asked — `cancelled` says only *that* the
// helper climbed the ladder (`protocol-change/006`) — but from a
// non-draining state the deduction is forced. `timed_out` can only be the
// deadline. A cancel with no `timed_out` can only be the abort, because
// `job_kill` and session stop both pass through the actor, which drains
// the record before the ladder starts, and a helper lost with the runner
// reports nothing at all.
fn exit_state(result: ExecResult) -> JobState {
  case result.timed_out, result.cancelled {
    True, _ -> Killed(by: ByDeadline, result:)

    False, True -> Killed(by: ByOperationAbort, result:)

    False, False -> Exited(result:)
  }
}

// --- the durable cell -----------------------------------------------------

/// Encodes a job record as its stored register payload.
///
/// ## Examples
///
/// ```gleam
/// // jobstate.encode(record) |> jobstate.decode == Ok(record)
/// ```
///
pub fn encode(record: JobRecord) -> JsonValue {
  json.Object([
    #("id", json.String(record.id.text)),
    #("owner", json.String(record.owner)),
    #("startedBy", json.String(ids.op_id_to_string(record.started_by))),
    #(
      "spec",
      json.Object([
        #("argv", json.Array(list.map(record.spec.argv, json.String))),
        #("cwd", json.String(record.spec.cwd)),
        #("requestedWallMs", json.Int(record.spec.requested_wall_ms)),
      ]),
    ),
    #("startedAtMs", json.Int(record.started_at_ms)),
    #("deadlineMs", json.Int(record.deadline_ms)),
    #("state", encode_state(record.state)),
    #("spill", encode_spill(record.spill)),
  ])
}

// The two refs, each written as a field that is always present and
// sometimes null rather than a field that is sometimes absent.
//
// The difference decides what every later build has to carry. A field
// added once cells exist can only be read with an absent-means-`None`
// arm, and that arm is permanent: it cannot tell a stream whose runner
// never sealed a ref from a cell some future writer forgot to fill.
// Nothing has written a `job/` cell yet, so both fields are required from
// the first one and the decoder never has to guess.
fn encode_spill(spill: JobSpill) -> JsonValue {
  json.Object([
    #("stdoutRef", nullable_string(spill.stdout_ref)),
    #("stderrRef", nullable_string(spill.stderr_ref)),
  ])
}

fn nullable_string(value: Option(String)) -> JsonValue {
  case value {
    None -> json.Null
    Some(text) -> json.String(text)
  }
}

// The state as the cell carries it: a `phase` tag plus whatever that
// phase's variant holds.
//
// A tag rather than a bare string for the live phases too, so that adding
// a field to `Running` later is a change to this object and not a change
// to the shape a stored cell has.
fn encode_state(state: JobState) -> JsonValue {
  case state {
    Starting -> json.Object([#("phase", json.String("starting"))])

    Running -> json.Object([#("phase", json.String("running"))])

    Draining(by:) ->
      json.Object([
        #("phase", json.String("draining")),
        #("by", json.String(cause_to_string(by))),
      ])

    Exited(result:) ->
      json.Object([
        #("phase", json.String("exited")),
        #("result", encode_result(result)),
      ])

    Killed(by:, result:) ->
      json.Object([
        #("phase", json.String("killed")),
        #("by", json.String(cause_to_string(by))),
        #("result", encode_result(result)),
      ])

    Lost(reason:) ->
      json.Object([
        #("phase", json.String("lost")),
        #("reason", json.String(reason_to_string(reason))),
      ])
  }
}

fn cause_to_string(cause: KillCause) -> String {
  case cause {
    ByOwner -> "owner"
    ByDeadline -> "deadline"
    BySessionStop -> "session_stop"
    ByOperationAbort -> "operation_abort"
  }
}

fn reason_to_string(reason: LossReason) -> String {
  case reason {
    VmRestart -> "vm_restart"
    OwnerRestart -> "owner_restart"
    HelperLoss -> "helper_loss"
  }
}

// The helper's own terminal report, stored whole.
//
// Whole rather than summarised because #71's complaint is that
// `cancelled` had no reader: a stored subset would settle today which of
// these eleven fields a future poll may render, and the record outlives
// the build that wrote it.
fn encode_result(result: ExecResult) -> JsonValue {
  json.Object([
    #("code", json.Int(result.code)),
    #("signal", json.Int(result.signal)),
    #("stdoutBytes", json.Int(result.stdout_bytes)),
    #("stderrBytes", json.Int(result.stderr_bytes)),
    #("stdoutTruncated", json.Bool(result.stdout_truncated)),
    #("stderrTruncated", json.Bool(result.stderr_truncated)),
    #("enforcement", json.Array(list.map(result.enforcement, json.String))),
    #("degraded", json.Bool(result.degraded)),
    #("wallMs", json.Int(result.wall_ms)),
    #("timedOut", json.Bool(result.timed_out)),
    #("cancelled", json.Bool(result.cancelled)),
  ])
}

/// Reads one stored job record back. Total: anything malformed is a
/// corruption report, never a crash and never a partial record.
///
/// There is no lenient arm, and that is the point. A half-read record
/// would be one whose *state* was guessed, and the two ways to guess are
/// both harmful in the same direction: guessing terminal hides a running
/// process from the restart sweep, and guessing live keeps a dead job in
/// every listing forever. A caller that cannot read a cell reports
/// corruption and leaves the cell alone.
///
/// ## Examples
///
/// ```gleam
/// // jobstate.decode(jobstate.encode(record)) == Ok(record)
/// ```
///
/// ```gleam
/// // jobstate.decode(json.Null) -> Error(CorruptionReport(..))
/// ```
///
pub fn decode(payload: JsonValue) -> Result(JobRecord, CorruptionReport) {
  let where = "client/jobstate.decode"
  case payload {
    json.Object(fields) -> {
      use id_text <- result.try(require_string(fields, "id", where))
      use id <- result.try(require_job_id(id_text, where))
      use owner <- result.try(require_string(fields, "owner", where))
      use started_text <- result.try(require_string(fields, "startedBy", where))
      use started_by <- result.try(ids.parse_op_id(started_text))
      use spec <- result.try(decode_spec(fields, where))
      use started_at_ms <- result.try(require_int(fields, "startedAtMs", where))
      use deadline_ms <- result.try(require_int(fields, "deadlineMs", where))
      use state <- result.try(decode_state(fields, where))
      use spill <- result.try(decode_spill(fields, where))
      Ok(JobRecord(
        id:,
        owner:,
        started_by:,
        spec:,
        started_at_ms:,
        deadline_ms:,
        state:,
        spill:,
      ))
    }

    other ->
      Error(corruption.report(
        at: where,
        on: "payload",
        expected: "a job object",
        context: json.to_string(other),
      ))
  }
}

// The id is re-validated on the way out rather than trusted from the way
// in, for the reason `client/schedule.decode` re-checks its bounds: the
// cell outlives the build that wrote it, and a stored id carrying a
// separator would make every later `job_key` round-trip disagree with the
// key the cell is actually filed under.
fn require_job_id(
  text: String,
  where: String,
) -> Result(JobId, CorruptionReport) {
  case parse_job_id(text) {
    Ok(id) -> Ok(id)
    Error(Nil) ->
      Error(corruption.report(
        at: where,
        on: "id",
        expected: "a non-empty id containing no '/'",
        context: text,
      ))
  }
}

fn decode_spec(
  fields: List(#(String, JsonValue)),
  where: String,
) -> Result(JobSpec, CorruptionReport) {
  use spec <- result.try(require_object(fields, "spec", where))
  use argv <- result.try(require_string_list(spec, "argv", where))
  use cwd <- result.try(require_string(spec, "cwd", where))
  use wall <- result.try(require_int(spec, "requestedWallMs", where))
  Ok(JobSpec(argv:, cwd:, requested_wall_ms: wall))
}

// The phase tag decides the shape, and an unknown tag is corruption
// rather than a fallback to any live or terminal phase — see `decode`.
fn decode_state(
  fields: List(#(String, JsonValue)),
  where: String,
) -> Result(JobState, CorruptionReport) {
  use state <- result.try(require_object(fields, "state", where))
  use phase <- result.try(require_string(state, "phase", where))
  case phase {
    "starting" -> Ok(Starting)

    "running" -> Ok(Running)

    "draining" -> {
      use by <- result.try(decode_cause(state, where))
      Ok(Draining(by:))
    }

    "exited" -> {
      use result <- result.try(decode_result(state, where))
      Ok(Exited(result:))
    }

    "killed" -> {
      use by <- result.try(decode_cause(state, where))
      use result <- result.try(decode_result(state, where))
      Ok(Killed(by:, result:))
    }

    "lost" -> {
      use reason <- result.try(decode_reason(state, where))
      Ok(Lost(reason:))
    }

    other ->
      Error(corruption.report(
        at: where,
        on: "state.phase",
        expected: "starting, running, draining, exited, killed or lost",
        context: other,
      ))
  }
}

// The two content addresses, each present-or-null.
//
// A null is a stream with nothing to read, which is a fact rather than an
// absence: it is what a job that printed nothing to stderr leaves, and it
// is also what a promotion that failed leaves. Anything other than a
// string or a null is corruption, because a ref that will not read as text
// is a ref no `fs_read` can be handed.
fn decode_spill(
  fields: List(#(String, JsonValue)),
  where: String,
) -> Result(JobSpill, CorruptionReport) {
  use spill <- result.try(require_object(fields, "spill", where))
  use stdout_ref <- result.try(spill_ref(spill, "stdoutRef", where))
  use stderr_ref <- result.try(spill_ref(spill, "stderrRef", where))
  Ok(JobSpill(stdout_ref:, stderr_ref:))
}

// One stream's ref, blamed by its path inside the spill rather than by
// its bare name, so a report tells an operator which cell broke instead
// of naming a key that appears in more than one object.
fn spill_ref(
  fields: List(#(String, JsonValue)),
  key: String,
  where: String,
) -> Result(Option(String), CorruptionReport) {
  let on = "spill." <> key
  case list.key_find(fields, key) {
    Error(Nil) ->
      Error(corruption.report(
        at: where,
        on:,
        expected: "a present field",
        context: "absent",
      ))

    Ok(json.Null) -> Ok(None)

    Ok(json.String(text)) -> Ok(Some(text))

    Ok(other) ->
      Error(corruption.report(
        at: where,
        on:,
        expected: "a string or null",
        context: json.to_string(other),
      ))
  }
}

fn decode_cause(
  state: List(#(String, JsonValue)),
  where: String,
) -> Result(KillCause, CorruptionReport) {
  use text <- result.try(require_string(state, "by", where))
  case text {
    "owner" -> Ok(ByOwner)
    "deadline" -> Ok(ByDeadline)
    "session_stop" -> Ok(BySessionStop)
    "operation_abort" -> Ok(ByOperationAbort)
    other ->
      Error(corruption.report(
        at: where,
        on: "state.by",
        expected: "owner, deadline, session_stop or operation_abort",
        context: other,
      ))
  }
}

fn decode_reason(
  state: List(#(String, JsonValue)),
  where: String,
) -> Result(LossReason, CorruptionReport) {
  use text <- result.try(require_string(state, "reason", where))
  case text {
    "vm_restart" -> Ok(VmRestart)
    "owner_restart" -> Ok(OwnerRestart)
    "helper_loss" -> Ok(HelperLoss)
    other ->
      Error(corruption.report(
        at: where,
        on: "state.reason",
        expected: "vm_restart, owner_restart or helper_loss",
        context: other,
      ))
  }
}

fn decode_result(
  state: List(#(String, JsonValue)),
  where: String,
) -> Result(ExecResult, CorruptionReport) {
  use fields <- result.try(require_object(state, "result", where))
  use code <- result.try(require_int(fields, "code", where))
  use signal <- result.try(require_int(fields, "signal", where))
  use stdout_bytes <- result.try(require_int(fields, "stdoutBytes", where))
  use stderr_bytes <- result.try(require_int(fields, "stderrBytes", where))
  use out_cut <- result.try(require_bool(fields, "stdoutTruncated", where))
  use err_cut <- result.try(require_bool(fields, "stderrTruncated", where))
  use enforcement <- result.try(require_string_list(
    fields,
    "enforcement",
    where,
  ))
  use degraded <- result.try(require_bool(fields, "degraded", where))
  use wall_ms <- result.try(require_int(fields, "wallMs", where))
  use timed_out <- result.try(require_bool(fields, "timedOut", where))
  use cancelled <- result.try(require_bool(fields, "cancelled", where))
  Ok(ExecResult(
    code:,
    signal:,
    stdout_bytes:,
    stderr_bytes:,
    stdout_truncated: out_cut,
    stderr_truncated: err_cut,
    enforcement:,
    degraded:,
    wall_ms:,
    timed_out:,
    cancelled:,
  ))
}

// --- field readers --------------------------------------------------------
//
// The same five shapes `runtime/lineage` grew for the same reason: a
// stored object is read field by field, and a missing or mistyped field
// is named in the report so the cell that broke can be found by hand.

fn require(
  fields: List(#(String, JsonValue)),
  key: String,
  where: String,
) -> Result(JsonValue, CorruptionReport) {
  case list.key_find(fields, key) {
    Ok(value) -> Ok(value)
    Error(Nil) ->
      Error(corruption.report(
        at: where,
        on: key,
        expected: "a present field",
        context: "absent",
      ))
  }
}

fn require_object(
  fields: List(#(String, JsonValue)),
  key: String,
  where: String,
) -> Result(List(#(String, JsonValue)), CorruptionReport) {
  use value <- result.try(require(fields, key, where))
  case value {
    json.Object(inner) -> Ok(inner)
    other ->
      Error(corruption.report(
        at: where,
        on: key,
        expected: "an object",
        context: json.to_string(other),
      ))
  }
}

fn require_string(
  fields: List(#(String, JsonValue)),
  key: String,
  where: String,
) -> Result(String, CorruptionReport) {
  use value <- result.try(require(fields, key, where))
  case value {
    json.String(text) -> Ok(text)
    other ->
      Error(corruption.report(
        at: where,
        on: key,
        expected: "a string",
        context: json.to_string(other),
      ))
  }
}

fn require_int(
  fields: List(#(String, JsonValue)),
  key: String,
  where: String,
) -> Result(Int, CorruptionReport) {
  use value <- result.try(require(fields, key, where))
  case value {
    json.Int(number) -> Ok(number)
    other ->
      Error(corruption.report(
        at: where,
        on: key,
        expected: "an integer",
        context: json.to_string(other),
      ))
  }
}

fn require_bool(
  fields: List(#(String, JsonValue)),
  key: String,
  where: String,
) -> Result(Bool, CorruptionReport) {
  use value <- result.try(require(fields, key, where))
  case value {
    json.Bool(flag) -> Ok(flag)
    other ->
      Error(corruption.report(
        at: where,
        on: key,
        expected: "a boolean",
        context: json.to_string(other),
      ))
  }
}

fn require_string_list(
  fields: List(#(String, JsonValue)),
  key: String,
  where: String,
) -> Result(List(String), CorruptionReport) {
  use value <- result.try(require(fields, key, where))
  case value {
    json.Array(items) -> list.try_map(items, require_string_item(_, where, key))
    other ->
      Error(corruption.report(
        at: where,
        on: key,
        expected: "an array of strings",
        context: json.to_string(other),
      ))
  }
}

fn require_string_item(
  item: JsonValue,
  where: String,
  key: String,
) -> Result(String, CorruptionReport) {
  case item {
    json.String(text) -> Ok(text)
    other ->
      Error(corruption.report(
        at: where,
        on: key,
        expected: "an array of strings",
        context: json.to_string(other),
      ))
  }
}
