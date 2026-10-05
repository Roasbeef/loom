//// `cap/job` — background jobs a program can start, watch, feed and
//// stop: a jailed command that keeps running after the call that
//// started it, and after the program itself has returned.
////
//// The same door `tools/job` opens for a model calling a tool directly,
//// reached from inside a code-mode program instead. Both land on one
//// implementation (`client/jobseam.Door`), so a job started here is
//// indistinguishable from one `bash` started with `mode: "background"`:
//// same record, same owner, same ceiling, same listing — and either
//// door can poll or kill what the other started, because a job belongs
//// to the **strand** the execution runs on and never to the caller.
////
//// ## Why this is here and not a `proc.run` with a longer timeout
////
//// `proc.run` blocks the program for the whole command and dies with
//// the execution. A job does neither. That is the difference between
//// running a build and *supervising* one: start a server, poll until a
//// line matches, run the tests against it, kill the server, return one
//// result. Every one of those shapes is a loop with no round-trip cost
//// here, which is exactly why the top-level tool surface does not grow
//// a "wait until the output contains X" argument — see
//// `docs/design-notes/background-jobs.md`.
////
//// ## A program's own deadline is not the job's
////
//// An execution has a wall (`within_ms`) and so does each job, and the
//// two are unrelated. The satellite ends when the program returns; a job
//// it started keeps running under its own token until its own deadline
//// expires, and a later turn — a tool call, or another program — reads
//// it. So a program that starts a job and returns has not leaked
//// anything and has not waited for anything either. If the point of the
//// program was the command's output, either `poll` until it is terminal
//// or use `proc.run`.
////
//// A finite deadline is fixed at `start` and is never renewed: the token, the
//// relay, the helper's own wall timer and the budget ledger all read one
//// number, and a program that needs longer starts another job. `start`
//// answers with the wall it was actually **granted**, which is what was
//// asked for clamped by the host's ceiling and narrowed by the session's
//// policy — read `Started.wall_ms` rather than assuming the request.
//// `start_for_session` explicitly requests no wall deadline under approved
//// authority. Its zero wall and deadline do not remove ownership, other
//// resource limits, or cancellation; the job ends when stopped, when its
//// command exits, or when its session closes.
////
//// ## The tail is bounded and the spill is not
////
//// `poll` answers with what a stream has printed *since a cursor*, out
//// of a bounded rolling window. A program that polls rarely and prints
//// a lot will see `Stream.dropped` above zero, which means output it
//// never read has left the window — not that it was lost: the whole of
//// each stream is content-addressed at termination and `Job.spill`
//// carries the refs, which `cap/fs.read` reads. Treat a non-zero
//// `dropped` as "poll more often, or read the spill at the end", never
//// as an error.
////
//// Cursors are the harness's own tokens. Take `Stream.cursor` from one
//// answer and hand it to the next `poll`; do not compute one.
////
//// ## Ceilings and refusals
////
//// A strand holds a small number of live jobs at once, and the ceiling
//// is the host's; a program starting them in a loop is denied
//// `job_ceiling` at the same count a tool call would be. A `poll` with a
//// wait is clamped host-side to the same ceiling `agent_wait` is held
//// to, so a tight poll loop costs at least a slice each time round.
////
//// Killing a job needs no approval — a strand may always stop what it
//// started — but *starting* one admits under exactly the rules a
//// foreground command does, so a wall the session's policy will not
//// grant is refused or escalated there rather than here.

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import core/msgpack.{type MsgPackValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// A job's validated identity: nonempty text with no register separator.
/// The host owns authorization; possessing this value grants no authority.
pub opaque type JobId {
  JobId(
    /// The register key segment accepted by the host.
    text: String,
  )
}

/// Parses a saved job identity using the host's register-key grammar.
///
/// ## Examples
///
/// ```gleam
/// assert job.parse_job_id("job/other") == Error("job id must be nonempty and contain no '/'")
/// ```
pub fn parse_job_id(text: String) -> Result(JobId, String) {
  case text == "" || string.contains(text, "/") {
    True -> Error("job id must be nonempty and contain no '/'")
    False -> Ok(JobId(text:))
  }
}

/// Renders the identity for storage in a later program's input.
///
/// ## Examples
///
/// ```gleam
/// // job.job_id_to_string(started.id)
/// ```
pub fn job_id_to_string(id: JobId) -> String {
  id.text
}

/// A nonnegative stdout byte position, never a stderr cursor.
pub opaque type StdoutCursor {
  StdoutCursor(
    /// Bytes consumed from stdout, never negative.
    offset: Int,
  )
}

/// A nonnegative stderr byte position, never a stdout cursor.
pub opaque type StderrCursor {
  StderrCursor(
    /// Bytes consumed from stderr, never negative.
    offset: Int,
  )
}

/// Restores a saved stdout position; a negative position is invalid.
/// Prefer `after` when continuing directly from a poll.
///
/// ## Examples
///
/// ```gleam
/// assert job.parse_stdout_cursor(-1) == Error("stdout cursor must be nonnegative")
/// ```
pub fn parse_stdout_cursor(offset: Int) -> Result(StdoutCursor, String) {
  case offset >= 0 {
    True -> Ok(StdoutCursor(offset:))
    False -> Error("stdout cursor must be nonnegative")
  }
}

/// Restores a saved stderr position; a negative position is invalid.
///
/// ## Examples
///
/// ```gleam
/// assert job.parse_stderr_cursor(-1) == Error("stderr cursor must be nonnegative")
/// ```
pub fn parse_stderr_cursor(offset: Int) -> Result(StderrCursor, String) {
  case offset >= 0 {
    True -> Ok(StderrCursor(offset:))
    False -> Error("stderr cursor must be nonnegative")
  }
}

/// Renders a stdout position for persistence between programs.
///
/// ## Examples
///
/// ```gleam
/// assert job.stdout_cursor_to_int(job.from_start().stdout) == 0
/// ```
pub fn stdout_cursor_to_int(cursor: StdoutCursor) -> Int {
  cursor.offset
}

/// Renders a stderr position for persistence between programs.
///
/// ## Examples
///
/// ```gleam
/// assert job.stderr_cursor_to_int(job.from_start().stderr) == 0
/// ```
pub fn stderr_cursor_to_int(cursor: StderrCursor) -> Int {
  cursor.offset
}

/// Why a background-job call failed.
///
/// Split the way `cap/proc`'s is: the reasons a program can branch on
/// get their own variants, and everything else keeps the host's code
/// verbatim rather than being flattened into one.
pub type JobError {
  /// This strand already holds every job it may hold at once. Stop one
  /// with `kill` before starting another.
  JobCeilingReached(message: String)

  /// This strand owns no job of that id — which is also the answer for a
  /// job another strand owns, so a program learns what is its own and
  /// nothing about anyone else's.
  JobNotFound(message: String)

  /// The clearance refused the command before anything ran, in the
  /// broker's own words: the same refusal a foreground command would
  /// have met under the same policy.
  JobRefused(message: String)

  /// The host denied the call for a reason this module has no variant
  /// for. `code` is the host's own, carried verbatim.
  JobDenied(code: String, message: String)

  /// The host answered, but the payload violates this API.
  JobResultMalformed(reason: String)

  /// The capability channel could not carry the call, or the host runs
  /// no background-jobs plane at all.
  JobUnavailable(reason: String)
}

/// A job that has been admitted and is running.
pub type Started {
  Started(
    /// The handle every other function here takes.
    id: JobId,
    /// The absolute instant its wall expires at, in milliseconds on the
    /// session's own time base. Zero denotes authorized session lifetime.
    deadline_ms: Int,
    /// The wall actually granted, which is not always what was asked
    /// for. Zero denotes authorized session lifetime.
    wall_ms: Int,
  )
}

/// Why a job is being stopped, or was stopped.
///
/// Carried separately from the exit report because the report cannot say
/// it: a cancelled run says only *that* the ladder was climbed, never at
/// whose asking.
pub type StopCause {
  /// This strand asked, through `kill`.
  ByOwner

  /// The wall deadline fixed at `start` expired.
  ByDeadline

  /// The session is closing.
  BySessionStop

  /// An operator aborted the operation that started the job.
  ByOperationAbort
}

/// Why a job can no longer be spoken for: nobody ended it on purpose and
/// no exit was ever observed, so what became of the process is unknown
/// rather than reported.
pub type LostReason {
  /// The harness VM restarted. Nothing in this design survives that.
  VmRestart

  /// The jobs plane restarted, taking every runner it owned with it.
  OwnerRestart

  /// The sandbox helper went away without reporting an exit.
  HelperLoss
}

/// The helper's own report of how a job's command ended.
///
/// `timed_out` and `cancelled` answer different questions and a job
/// killed by its deadline is both: the first says the wall expired, the
/// second is the helper's witness that it climbed the TERM-then-KILL
/// ladder. Under a jail the payload's own signal is relayed as an exit
/// code rather than as `signal`, so read `code` for the
/// cross-environment answer.
pub type Exit {
  Exit(
    code: Int,
    signal: Int,
    wall_ms: Int,
    timed_out: Bool,
    cancelled: Bool,
    stdout_bytes: Int,
    stderr_bytes: Int,
    stdout_truncated: Bool,
    stderr_truncated: Bool,
  )
}

/// Where a job is in its life.
///
/// Three live states and three terminal ones. `is_pending` is the split,
/// and a loop that waits for a job should ask through it rather than
/// listing the variants, so a state added later does not read as
/// finished.
pub type State {
  /// Cleared and dispatched; the helper has not accepted the run yet.
  Starting

  /// The helper accepted the run and the process is live.
  Running

  /// A stop was asked for and the cancel ladder is climbing; no exit has
  /// been reported yet. Poll again for the terminal state.
  Draining(by: StopCause)

  /// The command ended of its own accord.
  Exited(exit: Exit)

  /// The job was stopped and the helper reported the stopped execution.
  Killed(by: StopCause, exit: Exit)

  /// The job can no longer be spoken for, and no exit was observed.
  Lost(reason: LostReason)
}

/// One stream's answer to a poll. `Job` fixes the cursor type separately
/// for stdout and stderr, so swapping them cannot compile.
pub type Stream(cursor) {
  Stream(
    /// What arrived after the cursor asked with and is still retained.
    bytes: BitArray,
    /// The cursor to hand to the next `poll`. Opaque — take it, do not
    /// compute it.
    cursor: cursor,
    /// How many bytes left the retained window unread. Non-zero means
    /// poll more often, or read the spill at the end; it never means the
    /// output was lost.
    dropped: Int,
  )
}

/// Where a finished job's whole output was stored.
///
/// Empty while the job runs. Each field is `Some` only for a stream that
/// carried bytes and was promoted to its content address; the text is
/// then a ref `cap/fs.read` reads. `None` means "nothing to read", and
/// the exit report's byte counts are what tell a program whether a
/// stream had output that did not reach a blob.
pub type Spill {
  Spill(stdout_ref: Option(String), stderr_ref: Option(String))
}

/// One job, as `poll` reads it.
pub type Job {
  Job(
    /// The validated durable identity of this job.
    id: JobId,
    /// Its observed lifecycle state.
    state: State,
    /// How long the job has been alive, in milliseconds.
    age_ms: Int,
    /// The absolute instant its wall expires at.
    deadline_ms: Int,
    /// The retained stdout tail and its next stdout cursor.
    stdout: Stream(StdoutCursor),
    /// The retained stderr tail and its next stderr cursor.
    stderr: Stream(StderrCursor),
    /// Content references for complete terminal output.
    spill: Spill,
  )
}

/// One row of this strand's job listing.
pub type Row {
  Row(
    /// The validated durable identity of this job.
    id: JobId,
    /// Its observed lifecycle state.
    state: State,
    /// Elapsed lifetime in milliseconds.
    age_ms: Int,
    /// The absolute instant its wall expires at.
    deadline_ms: Int,
  )
}

/// Whether a job in this state is one to come back to.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(watched) = job.poll(started.id, 5000, job.from_start())
/// case job.is_pending(watched.state) {
///   True -> Nil
///   False -> Nil
/// }
/// ```
///
pub fn is_pending(state: State) -> Bool {
  case state {
    Starting | Running | Draining(..) -> True
    Exited(..) | Killed(..) | Lost(..) -> False
  }
}

/// Where a poll left off in each stream.
pub type Cursors {
  Cursors(
    /// The position consumed from stdout.
    stdout: StdoutCursor,
    /// The position consumed from stderr.
    stderr: StderrCursor,
  )
}

/// The cursors that read a job's whole retained tail: the first poll's.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(id) = job.parse_job_id("01JQ8XZ")
/// let assert Ok(watched) = job.poll(id, 0, job.from_start())
/// ```
///
pub fn from_start() -> Cursors {
  Cursors(stdout: StdoutCursor(0), stderr: StderrCursor(0))
}

/// The cursors one poll's answer leaves behind, to hand to the next.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(id) = job.parse_job_id("01JQ8XZ")
/// let assert Ok(first) = job.poll(id, 0, job.from_start())
/// let assert Ok(_next) = job.poll(id, 0, job.after(first))
/// ```
///
pub fn after(watched: Job) -> Cursors {
  Cursors(stdout: watched.stdout.cursor, stderr: watched.stderr.cursor)
}

/// Starts `command` as a background job with the host's default wall.
///
/// It runs as `bash -lc` in the workspace, under exactly the sandbox
/// policy a foreground command runs under, and it keeps running after
/// this call and after this program returns.
///
/// Capability: `job.start`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(building) = job.start("make check")
/// ```
///
pub fn start(command: String) -> Result(Started, JobError) {
  started([#("command", wire.string(command))])
}

/// `start`, asking for a particular wall in milliseconds.
///
/// The host clamps it to its own ceiling and the session's policy
/// narrows it further, so read `Started.wall_ms` for what was granted.
/// It is never renewed once the job is running.
///
/// Capability: `job.start`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(serving) = job.start_within("./serve", 600_000)
/// ```
///
pub fn start_within(
  command: String,
  wall_ms: Int,
) -> Result(Started, JobError) {
  started([#("command", wire.string(command)), #("wall_ms", wire.int(wall_ms))])
}

/// Starts an explicitly authorized job without a wall deadline.
///
/// The code_mode invocation must declare permissions.wall_s: 0 and obtain
/// approval, or already hold equivalent sandbox authority. The job remains
/// owned by this strand and stops on job.kill, initiating-operation abort,
/// session shutdown, or loss of its owning runtime. Quiet runtime causes no
/// model turns. Started.deadline_ms and Started.wall_ms are zero.
///
/// Capability: job.start.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(watching) = job.start_for_session("substrate watch --session-id ...")
/// ```
///
pub fn start_for_session(command: String) -> Result(Started, JobError) {
  started([
    #("command", wire.string(command)),
    #("lifetime", wire.string("session")),
  ])
}

fn started(fields: List(#(String, MsgPackValue))) -> Result(Started, JobError) {
  use value <- result.try(
    dispatch.call("job.start", wire.args(fields)) |> result.map_error(map_error),
  )
  use id <- result.try(decode_job_id(value))
  use deadline_ms <- result.try(number(value, "deadline_ms"))
  use wall_ms <- result.try(number(value, "wall_ms"))
  Ok(Started(id:, deadline_ms:, wall_ms:))
}

/// Reads one job: its state, and what each stream has printed since
/// `cursors`.
///
/// `wait_ms` blocks for the job to *finish* before answering, and is
/// clamped host-side. A job still running when the wait expires is a
/// successful answer carrying its live state, never an error — so a
/// supervision loop is `poll` with a wait until `is_pending` is false,
/// and it costs at least one slice per turn whatever it passes.
///
/// Capability: `job.poll`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(id) = job.parse_job_id("01JQ8XZ")
/// let assert Ok(watched) = job.poll(id, 5000, job.from_start())
/// ```
///
pub fn poll(
  id: JobId,
  wait_ms: Int,
  cursors: Cursors,
) -> Result(Job, JobError) {
  use value <- result.try(
    dispatch.call(
      "job.poll",
      wire.args([
        #("job_id", wire.string(job_id_to_string(id))),
        #("wait_ms", wire.int(wait_ms)),
        #("since_stdout", wire.int(stdout_cursor_to_int(cursors.stdout))),
        #("since_stderr", wire.int(stderr_cursor_to_int(cursors.stderr))),
      ]),
    )
    |> result.map_error(map_error),
  )
  decode_job(value)
}

/// Lists every job this strand owns, live and terminal alike, with its
/// state and how long it has been alive.
///
/// The listing is the answer to "what did I start" across turns: a job
/// outlives the program that made it, so a later execution finds one it
/// never started here.
///
/// Capability: `job.list`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(mine) = job.list()
/// ```
///
pub fn list() -> Result(List(Row), JobError) {
  use value <- result.try(
    dispatch.call("job.list", wire.args([])) |> result.map_error(map_error),
  )
  use rows <- result.try(
    wire.array_field(value, "jobs") |> result.map_error(bad_result),
  )
  list.try_map(rows, decode_row)
}

/// Stops one job: TERM to the payload and its descendants, then KILL of
/// the group — the same ladder a cancelled foreground command climbs.
///
/// It returns once the stop has been asked for, which is not the same as
/// the job being over: the helper reports the stopped execution when it
/// reports it. `poll` afterwards for the terminal state, whose
/// `Exit.cancelled` is the helper's own witness that it climbed.
///
/// Capability: `job.kill`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(id) = job.parse_job_id("01JQ8XZ")
/// let assert Ok(Nil) = job.kill(id)
/// ```
///
pub fn kill(id: JobId) -> Result(Nil, JobError) {
  dispatch.call(
    "job.kill",
    wire.args([#("job_id", wire.string(job_id_to_string(id)))]),
  )
  |> result.replace(Nil)
  |> result.map_error(map_error)
}

/// Writes bytes to a job's standard input, leaving it open.
///
/// Nothing is appended, so write the newline yourself if the program
/// reads lines. This is what makes a job a REPL rather than a log to
/// watch; a foreground command has stdin closed from the start.
///
/// Capability: `job.send`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(id) = job.parse_job_id("01JQ8XZ")
/// let assert Ok(Nil) = job.send(id, <<"2 + 2\n":utf8>>)
/// ```
///
pub fn send(id: JobId, data: BitArray) -> Result(Nil, JobError) {
  write(id, data, close: False)
}

/// `send`, closing the job's stdin after this write.
///
/// Closing is what makes a program reading to end-of-input finish.
/// Nothing can be written afterwards.
///
/// Capability: `job.send`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(id) = job.parse_job_id("01JQ8XZ")
/// let assert Ok(Nil) = job.send_last(id, <<"quit\n":utf8>>)
/// ```
///
pub fn send_last(id: JobId, data: BitArray) -> Result(Nil, JobError) {
  write(id, data, close: True)
}

// The capability wire carries the end-of-input question as a boolean,
// which is what the host's router decodes. The two public functions above
// are what keep that boolean off every call site: `send_last` names what
// it does, and `send(id, data, True)` would not.
fn write(
  id: JobId,
  data: BitArray,
  close close: Bool,
) -> Result(Nil, JobError) {
  dispatch.call(
    "job.send",
    wire.args([
      #("job_id", wire.string(job_id_to_string(id))),
      #("data", wire.binary(data)),
      #("eof", wire.bool(close)),
    ]),
  )
  |> result.replace(Nil)
  |> result.map_error(map_error)
}

// --- decoding ---------------------------------------------------------------
//
// The host answers a flat map, because msgpack has no sum type: `state`
// names the variant and licenses the fields that go with it. So the state
// is read first and each arm reads only what its own variant carries — a
// live job carries no exit report and none is looked for.

fn decode_job(value: MsgPackValue) -> Result(Job, JobError) {
  use id <- result.try(decode_job_id(value))
  use state <- result.try(decode_state(value))
  use age_ms <- result.try(number(value, "age_ms"))
  use deadline_ms <- result.try(number(value, "deadline_ms"))
  use stdout <- result.try(decode_stream(value, "stdout", parse_stdout_cursor))
  use stderr <- result.try(decode_stream(value, "stderr", parse_stderr_cursor))
  use stdout_ref <- result.try(optional_text(value, "stdout_ref"))
  use stderr_ref <- result.try(optional_text(value, "stderr_ref"))
  let spill = Spill(stdout_ref:, stderr_ref:)
  Ok(Job(id:, state:, age_ms:, deadline_ms:, stdout:, stderr:, spill:))
}

fn decode_row(row: MsgPackValue) -> Result(Row, JobError) {
  use id <- result.try(decode_job_id(row))
  use state <- result.try(decode_state(row))
  use age_ms <- result.try(number(row, "age_ms"))
  use deadline_ms <- result.try(number(row, "deadline_ms"))
  Ok(Row(id:, state:, age_ms:, deadline_ms:))
}

fn decode_state(value: MsgPackValue) -> Result(State, JobError) {
  use name <- result.try(text(value, "state"))
  case name {
    "starting" -> Ok(Starting)
    "running" -> Ok(Running)
    "draining" -> decode_draining(value)
    "exited" -> decode_exited(value)
    "killed" -> decode_killed(value)
    "lost" -> decode_lost(value)

    other -> Error(bad_result("unknown job state " <> other))
  }
}

fn decode_draining(value: MsgPackValue) -> Result(State, JobError) {
  use by <- result.try(decode_cause(value))
  Ok(Draining(by:))
}

fn decode_exited(value: MsgPackValue) -> Result(State, JobError) {
  use exit <- result.try(decode_exit(value))
  Ok(Exited(exit:))
}

fn decode_killed(value: MsgPackValue) -> Result(State, JobError) {
  use by <- result.try(decode_cause(value))
  use exit <- result.try(decode_exit(value))
  Ok(Killed(by:, exit:))
}

fn decode_lost(value: MsgPackValue) -> Result(State, JobError) {
  use name <- result.try(text(value, "lost_reason"))
  case name {
    "vm_restart" -> Ok(Lost(reason: VmRestart))
    "owner_restart" -> Ok(Lost(reason: OwnerRestart))
    "helper_loss" -> Ok(Lost(reason: HelperLoss))

    other -> Error(bad_result("unknown loss reason " <> other))
  }
}

fn decode_cause(value: MsgPackValue) -> Result(StopCause, JobError) {
  use name <- result.try(text(value, "stopped_by"))
  case name {
    "owner" -> Ok(ByOwner)
    "deadline" -> Ok(ByDeadline)
    "session_stop" -> Ok(BySessionStop)
    "operation_abort" -> Ok(ByOperationAbort)

    other -> Error(bad_result("unknown stop cause " <> other))
  }
}

fn decode_exit(value: MsgPackValue) -> Result(Exit, JobError) {
  use report <- result.try(
    wire.field(value, "exit") |> result.map_error(bad_result),
  )
  use code <- result.try(number(report, "code"))
  use signal <- result.try(number(report, "signal"))
  use wall_ms <- result.try(number(report, "wall_ms"))
  use timed_out <- result.try(flag(report, "timed_out"))
  use cancelled <- result.try(flag(report, "cancelled"))
  use stdout_bytes <- result.try(number(report, "stdout_bytes"))
  use stderr_bytes <- result.try(number(report, "stderr_bytes"))
  use stdout_truncated <- result.try(flag(report, "stdout_truncated"))
  use stderr_truncated <- result.try(flag(report, "stderr_truncated"))
  Ok(Exit(
    code:,
    signal:,
    wall_ms:,
    timed_out:,
    cancelled:,
    stdout_bytes:,
    stderr_bytes:,
    stdout_truncated:,
    stderr_truncated:,
  ))
}

fn decode_job_id(value: MsgPackValue) -> Result(JobId, JobError) {
  use raw <- result.try(text(value, "job_id"))
  parse_job_id(raw) |> result.map_error(bad_result)
}

// The parser fixes the stream's cursor domain before its value is exposed.
fn decode_stream(
  value: MsgPackValue,
  key: String,
  parse: fn(Int) -> Result(cursor, String),
) -> Result(Stream(cursor), JobError) {
  use found <- result.try(
    wire.field(value, key) |> result.map_error(bad_result),
  )
  use bytes <- result.try(
    wire.binary_field(found, "bytes") |> result.map_error(bad_result),
  )
  use offset <- result.try(number(found, "cursor"))
  use cursor <- result.try(parse(offset) |> result.map_error(bad_result))
  use dropped <- result.try(number(found, "dropped"))
  Ok(Stream(bytes:, cursor:, dropped:))
}

fn text(value: MsgPackValue, key: String) -> Result(String, JobError) {
  wire.string_field(value, key) |> result.map_error(bad_result)
}

fn number(value: MsgPackValue, key: String) -> Result(Int, JobError) {
  wire.int_field(value, key) |> result.map_error(bad_result)
}

fn flag(value: MsgPackValue, key: String) -> Result(Bool, JobError) {
  wire.bool_field(value, key) |> result.map_error(bad_result)
}

fn optional_text(
  value: MsgPackValue,
  key: String,
) -> Result(Option(String), JobError) {
  case wire.optional_field(value, key) {
    None -> Ok(None)
    Some(msgpack.StringValue(found)) -> Ok(Some(found))
    Some(_other) -> Error(bad_result(key <> " must be text or null"))
  }
}

fn bad_result(reason: String) -> JobError {
  JobResultMalformed("bad job result: " <> reason)
}

// The other half of a contract whose first half is
// `codemode/workspace.job_denial` and `tools/job.refusal_code`: the same
// five strings reach a model in a tool result and a program here. A code
// this module has not learned arrives as `JobDenied` carrying it
// verbatim, which is a worse answer than a named variant and a much
// better one than a lie.
fn map_error(error: CallError) -> JobError {
  case error {
    Unreachable(reason:) -> JobUnavailable(reason:)

    Denied(code:, message:) ->
      case code {
        "job_ceiling" -> JobCeilingReached(message:)
        "job_not_found" -> JobNotFound(message:)
        "job_clearance_refused" -> JobRefused(message:)
        "invalid_job_request" -> JobDenied(code:, message:)
        "jobs_unavailable" -> JobUnavailable(reason: message)

        other -> JobDenied(code: other, message:)
      }
  }
}

/// A one-line rendering of a `JobError`.
///
/// ## Examples
///
/// ```gleam
/// assert job.error_text(job.JobNotFound("j1")) == "job not found: j1"
/// ```
///
pub fn error_text(error: JobError) -> String {
  case error {
    JobCeilingReached(message:) -> "job ceiling reached: " <> message
    JobNotFound(message:) -> "job not found: " <> message
    JobRefused(message:) -> "job refused: " <> message
    JobDenied(code:, message:) -> code <> ": " <> message
    JobResultMalformed(reason:) -> "malformed job result: " <> reason
    JobUnavailable(reason:) -> "job unavailable: " <> reason
  }
}
