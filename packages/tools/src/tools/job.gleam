//// The `job_*` tools: the model's own door onto background jobs.
////
//// # What a job is, from this side of the seam
////
//// A background job is a jailed command the harness started on the
//// model's behalf which is allowed to outlive the tool call that started
//// it. It is started by `bash` with `mode: "background"` — one flag on a
//// tool the model already has, rather than a fourth definition — and it
//// is watched, fed and stopped by the three tools here.
////
//// The three exist because the alternative is a model that cannot start
//// something and come back to it. Every foreground `bash` call blocks
//// its effect process for the whole execution and returns `[command
//// timed out]` past its budget, so watching a long build means blocking
//// on it. A job turns that into a handle: start it, work on something
//// else, ask what it has printed since the last look, and stop it.
////
//// # A seam of closures, like `schedule`
////
//// `tools` depends on `core` and `broker` and nothing else, which is
//// what keeps a tool definition a value rather than a subsystem. So
//// everything durable and everything enforced is a closure the host
//// fills in (`client/jobtools.seam` over `client/jobseam.Door`): the
//// ceiling on how many jobs a strand may hold, the wall clamp, the
//// ownership rule, the clearance, and every `job/<id>` fact write. This
//// module owns the model-facing surface and nothing else — the argument
//// schema, the wording, the shape of a refusal, and the rendering of a
//// poll.
////
//// Every bound is therefore *stated* here and enforced on the far side.
//// `Jobs.max_wait_ms` is passed in rather than restated for that reason:
//// the number a description promises and the number a call meets have to
//// be one fact.
////
//// # Pending is an answer
////
//// `job_poll` on a job that is still running is a **successful** result
//// carrying its live state, never a failure — the rule `agent_wait`
//// already follows for a subagent that has not settled. A model that
//// treats pending as an error learns to retry immediately, which is the
//// one behaviour a wait exists to prevent. The result says so in its
//// text and carries `details.pending` for a client that reads the
//// structured half.
////
//// # Cursors are opaque
////
//// A poll answers with what arrived *since* a cursor, and the cursor is
//// a token the model hands back unread. It is not a byte offset the
//// model may compute, arithmetic on it means nothing, and the tail it
//// addresses is bounded — output that fell out of the retained window
//// between two polls is reported as a `dropped` count rather than
//// silently skipped, and the whole stream is in the spill once the job
//// ends. Saying this in the descriptions is what stops a model
//// inventing a cursor and believing the empty answer.
////
//// # Replay and batching
////
//// `replay: Never` for all three. A replayed `job_kill` would climb a
//// ladder on a job the first attempt already stopped, a replayed
//// `job_send` would write the same bytes to a REPL twice, and a
//// replayed `job_poll` would move a cursor past output the model never
//// saw. None of those is a difference a crash should produce.
////
//// `execution_mode: Concurrent` for all three, and honestly so: none of
//// them touches the workspace. A job's own command does, but that race
//// was chosen when the model backgrounded it, and the batch scheduler
//// has no way to serialise a process that outlives the batch.

import broker/exec.{type ExecResult}
import broker/policy.{type SandboxPolicy}
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/tool.{type Ctx, type Tool, type ToolOutcome}

/// The polling tool's name.
pub const poll_tool_name = "job_poll"

/// The stopping tool's name.
pub const kill_tool_name = "job_kill"

/// The stdin tool's name.
pub const send_tool_name = "job_send"

// --- what a caller asks for, and what it hears back -------------------------

/// A job that has been admitted and is running, and the terms it runs
/// under.
pub type Started {
  Started(
    /// The handle every other tool here takes.
    id: String,
    /// The absolute instant its wall expires at, on the session's own
    /// time base.
    deadline_ms: Int,
    /// The wall actually granted, which is what was asked for clamped by
    /// the host's ceiling and narrowed by policy. A caller that asked
    /// for more is told what it got rather than left to assume.
    wall_ms: Int,
  )
}

/// Where a poll left off in each stream.
///
/// Two cursors rather than one, because the streams advance
/// independently: a build that writes a megabyte to stdout and nothing
/// to stderr must not drag the stderr cursor past output that has not
/// arrived. They travel to the model as one opaque token — see
/// `cursor_to_string`.
pub type Cursors {
  Cursors(stdout: Int, stderr: Int)
}

/// One stream's answer to a poll.
pub type Streamed {
  Streamed(
    /// What arrived after the cursor and is still retained.
    bytes: BitArray,
    /// The cursor to ask with next time.
    cursor: Int,
    /// How many bytes fell out of the retained window between the cursor
    /// and what is returned. Non-zero means the reader fell behind and
    /// output it never saw is gone from the tail; the spill still has it
    /// once the job ends.
    dropped: Int,
  )
}

/// Why a job is being stopped, or was stopped.
///
/// The cause is chosen when the stop is *requested* and carried into the
/// terminal state, because the helper's own exit report cannot say it: a
/// cancelled run reports only *that* the ladder was climbed, never at
/// whose asking.
pub type StopCause {
  /// The owning strand asked, through `job_kill`.
  ByOwner

  /// The wall deadline fixed at start expired.
  ByDeadline

  /// The session is closing.
  BySessionStop

  /// An operator aborted the operation that started the job.
  ByOperationAbort
}

/// Why a job can no longer be spoken for.
///
/// Distinct from a stop in the one way that matters to a model reading a
/// poll: nobody ended this job on purpose and no exit was ever observed,
/// so what became of the process is unknown rather than reported.
pub type LostReason {
  /// The VM that owned the job's helper restarted.
  VmRestart

  /// The jobs plane restarted, taking every runner it owned with it.
  OwnerRestart

  /// The helper carrying the execution went away without an exit report.
  HelperLoss
}

/// Where a job is in its life, as the model reads it.
///
/// A restatement of the host's own lifecycle (`client/jobstate.JobState`)
/// in this package's vocabulary, for the reason `Refusal` is one: `tools`
/// must not depend on `client`, and the host translates once at the seam.
pub type JobState {
  /// Cleared and dispatched; the helper has not yet accepted the run.
  Starting

  /// The helper accepted the run and the process is live.
  Running

  /// A stop was asked for and the cancel ladder is climbing; the helper
  /// has not yet reported the stopped execution.
  Draining(by: StopCause)

  /// The job ended of its own accord.
  Exited(result: ExecResult)

  /// The job was stopped and the helper reported the stopped execution.
  /// `by` is who asked and `result.cancelled` is the helper's own
  /// witness that it climbed the ladder; the two answer different
  /// questions and neither substitutes for the other.
  Killed(by: StopCause, result: ExecResult)

  /// The job can no longer be spoken for and no exit was ever observed.
  Lost(reason: LostReason)
}

/// Where a finished job's whole output was stored.
///
/// Empty while the job runs. Each field is `Some` only for a stream that
/// carried bytes and whose spill was written, and the text is then a
/// content-addressed ref the model reads with `fs_read`.
pub type JobSpill {
  JobSpill(stdout_ref: Option(String), stderr_ref: Option(String))
}

/// A poll of one job.
pub type Polled {
  Polled(
    id: String,
    state: JobState,
    /// How long the job has been alive, in milliseconds.
    age_ms: Int,
    deadline_ms: Int,
    stdout: Streamed,
    stderr: Streamed,
    spill: JobSpill,
  )
}

/// One row of a strand's job listing — what a poll with no id answers.
pub type Listed {
  Listed(id: String, state: JobState, age_ms: Int, deadline_ms: Int)
}

/// Whether a write to a job's stdin closes it.
///
/// A two-variant type rather than the JSON boolean the model writes,
/// because `send(id, data, True)` names nothing at a call site. The model
/// writes an enum for the same reason; the polarity is converted once, at
/// each boundary.
pub type StdinEnd {
  /// Close the job's stdin after this chunk. Nothing may be written
  /// afterwards, and closing is what makes a pipeline reading stdin
  /// terminate.
  CloseStdin

  /// Leave stdin open — the difference between watching a log and
  /// driving a REPL.
  KeepStdinOpen
}

/// Why a request produced no answer.
///
/// The host's own vocabulary (`client/jobs.Refusal`) restated here, so
/// that the code a model branches on is owned by the surface the model
/// reads rather than by a package it cannot see.
pub type Refusal {
  /// The strand already holds every job it may hold at once. Refused
  /// loudly rather than queued: a model that keeps backgrounding
  /// commands has to be told it is at the limit rather than watching
  /// them silently not run.
  CeilingReached(limit: Int)

  /// No job by that id belongs to the asking strand. Deliberately one
  /// answer for two facts — there is no such job, and there is one and
  /// it is somebody else's — so a strand guessing at a sibling's ids
  /// learns nothing from which guesses were real.
  NotFound(id: String)

  /// The request could not be honoured as asked.
  Invalid(reason: String)

  /// The clearance refused the job before anything ran. The words are
  /// the broker's own, because this is the same refusal a foreground
  /// `bash` would have shown for the same command under the same policy.
  ClearanceRefused(reason: String)

  /// Nothing was decided: this session runs no jobs plane, or the plane
  /// could not answer.
  Unavailable(reason: String)
}

/// The jobs seam: everything `bash` and the three tools here may ask of
/// the session.
///
/// Constructor invariants: every closure is total — it returns a
/// `Refusal`, it does not crash — and every one is judged against the
/// `Ctx` it is handed rather than against anything in its other
/// arguments. `max_wait_ms` is the ceiling `poll` clamps a wait to, and
/// is published so the schema can state the real number.
pub type Jobs {
  Jobs(
    /// The command and the wall it asked for in milliseconds, `None` for
    /// the host's default. Returns once the clearance has answered, so a
    /// policy refusal reaches the caller rather than the next poll.
    start: fn(Ctx, String, Option(Int)) -> Result(Started, Refusal),
    /// The job's id, how long to wait for it to finish, and where the
    /// last poll left off. A job still running when the wait expires is
    /// a successful answer carrying its live state.
    poll: fn(Ctx, String, Int, Cursors) -> Result(Polled, Refusal),
    /// Every job the caller's strand owns, with its state and its age.
    list: fn(Ctx) -> Result(List(Listed), Refusal),
    /// Climbs the cancel ladder. Needs no approval: a strand may always
    /// stop what it started.
    kill: fn(Ctx, String) -> Result(Nil, Refusal),
    /// Writes to the job's stdin, optionally closing it.
    send: fn(Ctx, String, BitArray, StdinEnd) -> Result(Nil, Refusal),
    /// The ceiling a poll's wait is clamped to, in milliseconds.
    max_wait_ms: Int,
  )
}

/// The seam a host with no jobs plane hands `bash`: every operation
/// refuses in band, naming the reason.
///
/// The `tools`-side twin of `client/jobseam.none`, and it exists for the
/// same reason: `bash` takes a seam unconditionally, so a host that
/// never stood a jobs actor up must still be able to build the tool, and
/// a model that asks for `mode: "background"` on such a host has to be
/// answered rather than have its effect process exit.
///
/// `max_wait_ms` is zero here because nothing will ever wait.
///
/// ## Examples
///
/// ```gleam
/// // bash.tool(job.unavailable())
/// ```
///
pub fn unavailable() -> Jobs {
  let absent = Unavailable(reason: "this session runs no background jobs")
  Jobs(
    start: fn(_ctx, _command, _wall) { Error(absent) },
    poll: fn(_ctx, _id, _wait, _cursors) { Error(absent) },
    list: fn(_ctx) { Error(absent) },
    kill: fn(_ctx, _id) { Error(absent) },
    send: fn(_ctx, _id, _data, _end) { Error(absent) },
    max_wait_ms: 0,
  )
}

/// The three job tools over one seam.
///
/// A list rather than three exported functions, so a host cannot
/// register the stopper without the poller: a model that can start a job
/// and not read it has no reason to have started one.
///
/// ## Examples
///
/// ```gleam
/// // tool.registry(list.append(base, job.tools(seam)))
/// ```
///
pub fn tools(jobs: Jobs) -> List(Tool) {
  [poll_tool(jobs), kill_tool(jobs), send_tool(jobs)]
}

// --- job_poll ---------------------------------------------------------------

fn poll_tool(jobs: Jobs) -> Tool {
  tool.Tool(
    name: poll_tool_name,
    description: "Read a background job: its state, and whatever it has "
      <> "printed since you last looked. Call it with no `job_id` to list "
      <> "every job this strand owns. A job that is still running is a "
      <> "**successful** answer, not a failure — do other work and poll "
      <> "again, or pass `wait_ms` to block for a while first (clamped to "
      <> int.to_string(jobs.max_wait_ms)
      <> "). Pass the `cursor` from the previous poll back as `since` to "
      <> "get only what is new; the cursor is an opaque token, so hand it "
      <> "back unread rather than computing one. Only the tail of each "
      <> "stream is kept, so a poll can report bytes it had to drop — the "
      <> "whole output is in the spill refs once the job has finished, "
      <> "and `fs_read` reads those.",
    prompt_snippet: Some(
      "`job_poll` reads a background job's state and new output, or lists "
      <> "them all.",
    ),
    schema: tool.object_schema(
      [
        #(
          "job_id",
          tool.string_property(
            "the job to read, as `bash` returned it. Leave it out to list "
            <> "every job this strand owns",
          ),
        ),
        #(
          "wait_ms",
          tool.integer_property(
            "block up to this many milliseconds for the job to finish "
            <> "before answering; clamped to "
            <> int.to_string(jobs.max_wait_ms)
            <> ". Defaults to 0, which answers with whatever is true now. "
            <> "Ignored when no `job_id` is given",
          ),
        ),
        #(
          "since",
          tool.string_property(
            "the `cursor` a previous poll returned, to read only what has "
            <> "arrived since. Opaque: hand back what you were given. "
            <> "Omit it to read the whole retained tail",
          ),
        ),
      ],
      [],
    ),
    replay: tool.Never,
    execution_mode: tool.Concurrent,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_poll(jobs, ctx, args) },
  )
}

fn run_poll(jobs: Jobs, ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use job_id <- tool.with_arg(tool.optional_string(args, "job_id"))
  use wait_ms <- tool.with_arg(tool.optional_int(args, "wait_ms"))
  use since <- tool.with_arg(tool.optional_string(args, "since"))

  // No id is the listing, which is why there is no fourth tool. The two
  // wait and cursor arguments are silently unused there rather than
  // refused: a model that polls one job and then drops the id to see
  // them all is doing something sensible, and a refusal over a leftover
  // argument would teach it not to.
  case job_id {
    None -> run_list(jobs, ctx)
    Some(id) -> run_poll_one(jobs, ctx, id, wait_ms, since)
  }
}

fn run_poll_one(
  jobs: Jobs,
  ctx: Ctx,
  id: String,
  wait_ms: Option(Int),
  since: Option(String),
) -> ToolOutcome {
  use cursors <- tool.with_arg(parse_cursor(since))
  let wait_ms =
    int.clamp(option.unwrap(wait_ms, 0), min: 0, max: jobs.max_wait_ms)
  use polled <- tool.or_outcome(
    jobs.poll(ctx, id, wait_ms, cursors),
    refusal_outcome,
  )
  polled_outcome(polled)
}

fn run_list(jobs: Jobs, ctx: Ctx) -> ToolOutcome {
  use listed <- tool.or_outcome(jobs.list(ctx), refusal_outcome)
  case listed {
    [] ->
      tool.success(
        "you have no background jobs. Start one with `bash` and "
        <> "`mode: \"background\"`.",
      )
      |> tool.with_details(json.Object([#("jobs", json.Array([]))]))

    rows ->
      tool.success(string.join(list.map(rows, describe_listed), "\n"))
      |> tool.with_details(
        json.Object([#("jobs", json.Array(list.map(rows, listed_json)))]),
      )
  }
}

fn describe_listed(row: Listed) -> String {
  row.id <> " — " <> state_text(row.state) <> ", " <> age_text(row.age_ms)
}

fn listed_json(row: Listed) -> JsonValue {
  json.Object([
    #("job_id", json.String(row.id)),
    #("state", json.String(state_name(row.state))),
    #("pending", json.Bool(is_pending(row.state))),
    #("age_ms", json.Int(row.age_ms)),
    #("deadline_ms", json.Int(row.deadline_ms)),
  ])
}

// The rendered poll: a heading naming the job and its state, then each
// stream's new bytes under its own rule, then the cursor to come back
// with.
//
// The cursor line is last and unconditional even for a terminal job,
// because a model that polled a job into its terminal state still has to
// be able to ask again for the tail it did not consume.
fn polled_outcome(polled: Polled) -> ToolOutcome {
  let heading =
    polled.id
    <> " — "
    <> state_text(polled.state)
    <> ", "
    <> age_text(polled.age_ms)

  let body =
    [
      [heading],
      stream_lines("stdout", polled.stdout),
      stream_lines("stderr", polled.stderr),
      spill_lines(polled.spill),
      ["cursor: " <> cursor_to_string(next_cursors(polled))],
    ]
    |> list.flatten
    |> string.join(with: "\n")

  // A pending job is a success. See the module doc: an `is_error` here
  // would teach a model that waiting is a fault to retry out of.
  tool.success(body)
  |> tool.with_details(polled_json(polled))
}

fn next_cursors(polled: Polled) -> Cursors {
  Cursors(stdout: polled.stdout.cursor, stderr: polled.stderr.cursor)
}

fn stream_lines(name: String, streamed: Streamed) -> List(String) {
  let dropped = case streamed.dropped {
    0 -> []

    bytes -> [
      "["
      <> name
      <> ": "
      <> int.to_string(bytes)
      <> " bytes dropped before this — the tail is bounded; read the "
      <> "spill for the whole stream]",
    ]
  }

  case output_text(streamed.bytes) {
    "" -> dropped
    text -> [dropped, ["--- " <> name <> " ---", text]] |> list.flatten
  }
}

fn spill_lines(spill: JobSpill) -> List(String) {
  [ref_line("stdout", spill.stdout_ref), ref_line("stderr", spill.stderr_ref)]
  |> list.flatten
}

fn ref_line(name: String, spilled: Option(String)) -> List(String) {
  case spilled {
    None -> []
    Some(spill_ref) -> ["whole " <> name <> ": " <> spill_ref]
  }
}

fn polled_json(polled: Polled) -> JsonValue {
  let base = [
    #("job_id", json.String(polled.id)),
    #("state", json.String(state_name(polled.state))),
    #("pending", json.Bool(is_pending(polled.state))),
    #("age_ms", json.Int(polled.age_ms)),
    #("deadline_ms", json.Int(polled.deadline_ms)),
    #("cursor", json.String(cursor_to_string(next_cursors(polled)))),
    #("stdout_dropped", json.Int(polled.stdout.dropped)),
    #("stderr_dropped", json.Int(polled.stderr.dropped)),
    #("stdout_ref", ref_json(polled.spill.stdout_ref)),
    #("stderr_ref", ref_json(polled.spill.stderr_ref)),
  ]
  json.Object(list.append(base, terminal_json(polled.state)))
}

fn ref_json(spilled: Option(String)) -> JsonValue {
  case spilled {
    None -> json.Null
    Some(spill_ref) -> json.String(spill_ref)
  }
}

// The structured half of a terminal state. Nothing is emitted for a live
// job, so a client reading `details` can tell "no exit yet" from "exited
// zero" without consulting `state` — the two are the same JSON otherwise.
fn terminal_json(state: JobState) -> List(#(String, JsonValue)) {
  case state {
    Starting | Running -> []

    Draining(by:) -> [#("stopped_by", json.String(cause_name(by)))]

    Exited(result:) -> result_json(result)

    Killed(by:, result:) -> [
      #("stopped_by", json.String(cause_name(by))),
      ..result_json(result)
    ]

    Lost(reason:) -> [#("lost_reason", json.String(loss_name(reason)))]
  }
}

fn result_json(result: ExecResult) -> List(#(String, JsonValue)) {
  [
    #("exit_code", json.Int(result.code)),
    #("signal", json.Int(result.signal)),
    #("wall_ms", json.Int(result.wall_ms)),
    #("timed_out", json.Bool(result.timed_out)),
    // The helper's own witness that it climbed the cancel ladder, which
    // nothing else in the record can say: a cancelled run whose payload
    // had backgrounded its work reports a clean exit
    // (`protocol-change/006`).
    #("cancelled", json.Bool(result.cancelled)),
    #("stdout_bytes", json.Int(result.stdout_bytes)),
    #("stderr_bytes", json.Int(result.stderr_bytes)),
    #("stdout_truncated", json.Bool(result.stdout_truncated)),
    #("stderr_truncated", json.Bool(result.stderr_truncated)),
    #("degraded", json.Bool(result.degraded)),
  ]
}

// --- job_kill ---------------------------------------------------------------

fn kill_tool(jobs: Jobs) -> Tool {
  tool.Tool(
    name: kill_tool_name,
    description: "Stop a background job. It is sent TERM and then KILL, "
      <> "the same ladder a cancelled foreground command climbs. The "
      <> "answer says whether the job has already settled or is still "
      <> "draining; poll it once more for the exit status either way. "
      <> "Stopping a job you started needs no approval.",
    prompt_snippet: Some("`job_kill` stops a background job."),
    schema: tool.object_schema(
      [
        #(
          "job_id",
          tool.string_property("the job to stop, as `bash` returned it"),
        ),
      ],
      ["job_id"],
    ),
    replay: tool.Never,
    execution_mode: tool.Concurrent,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_kill(jobs, ctx, args) },
  )
}

// A kill is two questions and the tool answers both: the ladder has been
// asked for, and *then* what state the job is in now.
//
// The second question is asked with a zero-wait poll rather than folded
// into the kill's own answer, because the ladder is asynchronous — the
// helper reports a stopped execution when it reports it — and a kill
// that claimed a terminal state would be claiming something the harness
// has not observed. A poll that fails after a kill that succeeded is
// still a successful stop, so the refusal is not propagated.
fn run_kill(jobs: Jobs, ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use id <- tool.with_arg(tool.required_string(args, "job_id"))
  use Nil <- tool.or_outcome(jobs.kill(ctx, id), refusal_outcome)
  let settled = jobs.poll(ctx, id, 0, Cursors(stdout: 0, stderr: 0))
  let state =
    result.map(settled, fn(polled: Polled) { polled.state })
    |> result.unwrap(or: Draining(by: ByOwner))

  tool.success("stopped " <> id <> " — " <> state_text(state) <> ".")
  |> tool.with_details(
    json.Object([
      #("job_id", json.String(id)),
      #("stopped", json.Bool(True)),
      #("state", json.String(state_name(state))),
      #("pending", json.Bool(is_pending(state))),
    ]),
  )
}

// --- job_send ---------------------------------------------------------------

fn send_tool(jobs: Jobs) -> Tool {
  tool.Tool(
    name: send_tool_name,
    description: "Write text to a background job's standard input. This is "
      <> "how you drive something interactive — a REPL, a prompt — rather "
      <> "than only watch it. Nothing is appended for you, so write the "
      <> "newline yourself if the program reads lines. `eof: \"close\"` "
      <> "closes stdin after this write, which is what makes a program "
      <> "reading to end-of-input finish; nothing can be written "
      <> "afterwards. A foreground `bash` call has stdin closed from the "
      <> "start, so this exists for background jobs alone.",
    prompt_snippet: Some("`job_send` writes to a background job's stdin."),
    schema: tool.object_schema(
      [
        #(
          "job_id",
          tool.string_property("the job to write to, as `bash` returned it"),
        ),
        #(
          "data",
          tool.string_property(
            "the text to write, verbatim. Include a trailing newline if "
            <> "the program reads lines",
          ),
        ),
        #(
          "eof",
          tool.enum_property(
            ["open", "close"],
            "whether to close stdin after this write. \"open\" (the "
              <> "default) leaves it open for more writes; \"close\" ends "
              <> "the input, which is what a program reading to "
              <> "end-of-input waits for",
          ),
        ),
      ],
      ["job_id", "data"],
    ),
    replay: tool.Never,
    execution_mode: tool.Concurrent,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_send(jobs, ctx, args) },
  )
}

fn run_send(jobs: Jobs, ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use id <- tool.with_arg(tool.required_string(args, "job_id"))
  use data <- tool.with_arg(tool.required_string(args, "data"))
  use end <- tool.with_arg(requested_end(args))
  let bytes = bit_array.from_string(data)
  use Nil <- tool.or_outcome(jobs.send(ctx, id, bytes, end), refusal_outcome)

  let closed = case end {
    CloseStdin -> " Its stdin is now closed."
    KeepStdinOpen -> ""
  }
  tool.success(
    "wrote "
    <> int.to_string(bit_array.byte_size(bytes))
    <> " bytes to "
    <> id
    <> "."
    <> closed,
  )
  |> tool.with_details(
    json.Object([
      #("job_id", json.String(id)),
      #("bytes", json.Int(bit_array.byte_size(bytes))),
      #("eof", json.String(end_name(end))),
    ]),
  )
}

// The model writes a closed vocabulary rather than a boolean, so
// `eof: "close"` names what it does at the call site the model writes.
// Absent reads as the milder state, which is what a write that never
// considered the question means.
fn requested_end(args: JsonValue) -> Result(StdinEnd, String) {
  case tool.optional_string(args, "eof") {
    Error(reason) -> Error(reason)
    Ok(None) | Ok(Some("open")) -> Ok(KeepStdinOpen)
    Ok(Some("close")) -> Ok(CloseStdin)

    Ok(Some(other)) ->
      Error("`eof` must be \"open\" or \"close\", not \"" <> other <> "\"")
  }
}

fn end_name(end: StdinEnd) -> String {
  case end {
    CloseStdin -> "close"
    KeepStdinOpen -> "open"
  }
}

// --- cursors ----------------------------------------------------------------

/// Renders a pair of cursors as the opaque token the model hands back.
///
/// One token rather than two arguments because the model must not do
/// arithmetic on either half, and two integer arguments invite exactly
/// that. The spelling is deliberately not documented to the model; it is
/// documented here because a maintainer reading a transcript needs to be
/// able to tell a stale cursor from a malformed one.
///
/// ## Examples
///
/// ```gleam
/// assert job.cursor_to_string(job.Cursors(stdout: 12, stderr: 0)) == "12:0"
/// ```
///
pub fn cursor_to_string(cursors: Cursors) -> String {
  int.to_string(cursors.stdout) <> ":" <> int.to_string(cursors.stderr)
}

/// Parses a cursor token back, refusing anything that is not one.
///
/// Total, and it has to be: a model will hand back something mangled
/// sooner or later, and that must be an in-band refusal naming the
/// argument rather than a crash or a silent rewind to the start of the
/// stream.
///
/// ## Examples
///
/// ```gleam
/// assert job.parse_cursor(option.Some("12:0"))
/// //   == Ok(job.Cursors(stdout: 12, stderr: 0))
/// ```
///
pub fn parse_cursor(since: Option(String)) -> Result(Cursors, String) {
  case since {
    None -> Ok(Cursors(stdout: 0, stderr: 0))
    Some(text) -> parse_cursor_text(text)
  }
}

fn parse_cursor_text(text: String) -> Result(Cursors, String) {
  case string.split(text, on: ":") {
    [stdout, stderr] -> cursor_pair(text, stdout, stderr)

    [] | [_one] | [_first, _second, _third, ..] -> Error(malformed_cursor(text))
  }
}

fn cursor_pair(
  text: String,
  stdout: String,
  stderr: String,
) -> Result(Cursors, String) {
  use stdout <- result.try(
    int.parse(stdout) |> result.replace_error(malformed_cursor(text)),
  )
  use stderr <- result.try(
    int.parse(stderr) |> result.replace_error(malformed_cursor(text)),
  )

  // Negative halves are refused rather than clamped: a cursor is a token
  // this tool minted, so one that could not have been minted is a sign
  // the model built its own, and rewinding it silently to the start of
  // the stream would hide that.
  use <- bool.guard(
    when: stdout < 0 || stderr < 0,
    return: Error(malformed_cursor(text)),
  )
  Ok(Cursors(stdout:, stderr:))
}

fn malformed_cursor(text: String) -> String {
  "`since` must be a cursor a previous "
  <> poll_tool_name
  <> " returned, not \""
  <> text
  <> "\". Omit it to read the whole retained tail."
}

// --- states -----------------------------------------------------------------

/// Whether a job in this state is still one the model should come back
/// to.
///
/// The three live states answer yes and the three terminal ones no. Every
/// caller that reports "pending" asks through this rather than
/// re-listing the variants, so `details.pending` and the rendered text
/// cannot disagree.
///
/// ## Examples
///
/// ```gleam
/// assert job.is_pending(job.Running)
/// ```
///
pub fn is_pending(state: JobState) -> Bool {
  case state {
    Starting | Running | Draining(..) -> True
    Exited(..) | Killed(..) | Lost(..) -> False
  }
}

/// The one-word name a state travels under in `details.state`.
///
/// ## Examples
///
/// ```gleam
/// assert job.state_name(job.Running) == "running"
/// ```
///
pub fn state_name(state: JobState) -> String {
  case state {
    Starting -> "starting"
    Running -> "running"
    Draining(..) -> "draining"
    Exited(..) -> "exited"
    Killed(..) -> "killed"
    Lost(..) -> "lost"
  }
}

// The sentence a model reads, which says more than the one-word name:
// who stopped a job, how it exited, and whether the helper witnessed a
// cancel. `timed_out` and `cancelled` are both reported because they
// answer different questions — the deadline fired, and the ladder was
// climbed — and a job killed by its deadline is both.
fn state_text(state: JobState) -> String {
  case state {
    Starting -> "starting (the helper has not accepted it yet)"
    Running -> "running"
    Draining(by:) -> "stopping (" <> cause_text(by) <> "); no exit reported yet"
    Exited(result:) -> "finished, " <> result_text(result)
    Killed(by:, result:) ->
      "stopped (" <> cause_text(by) <> "), " <> result_text(result)
    Lost(reason:) -> "lost — " <> loss_text(reason)
  }
}

fn result_text(result: ExecResult) -> String {
  let how = case result.code, result.signal {
    0, 0 -> "exit code 0"
    code, 0 -> "exit code " <> int.to_string(code)
    _code, signal -> "killed by signal " <> int.to_string(signal)
  }

  let deadline = case result.timed_out {
    True -> " (its wall deadline expired)"
    False -> ""
  }
  how <> deadline
}

fn cause_name(cause: StopCause) -> String {
  case cause {
    ByOwner -> "owner"
    ByDeadline -> "deadline"
    BySessionStop -> "session_stop"
    ByOperationAbort -> "operation_abort"
  }
}

fn cause_text(cause: StopCause) -> String {
  case cause {
    ByOwner -> "you asked"
    ByDeadline -> "its wall deadline expired"
    BySessionStop -> "the session is closing"
    ByOperationAbort -> "the operation that started it was aborted"
  }
}

fn loss_name(reason: LostReason) -> String {
  case reason {
    VmRestart -> "vm_restart"
    OwnerRestart -> "owner_restart"
    HelperLoss -> "helper_loss"
  }
}

fn loss_text(reason: LostReason) -> String {
  case reason {
    VmRestart -> "the harness restarted, so nothing observed how it ended"
    OwnerRestart -> "the jobs plane restarted, so nothing observed how it ended"
    HelperLoss -> "its sandbox helper went away without reporting an exit"
  }
}

fn age_text(age_ms: Int) -> String {
  int.to_string({ age_ms + 999 } / 1000) <> "s old"
}

// Jailed output is expected to be UTF-8; anything else is summarised
// rather than corrupted into the transcript, exactly as `tools/bash`
// summarises a foreground command's.
fn output_text(bytes: BitArray) -> String {
  case bit_array.to_string(bytes) {
    Ok(text) -> text
    Error(Nil) ->
      "["
      <> int.to_string(bit_array.byte_size(bytes))
      <> " bytes of non-UTF-8 output]"
  }
}

// --- refusals ---------------------------------------------------------------

/// Renders a seam refusal as the in-band failure the model reads.
///
/// ## Examples
///
/// ```gleam
/// // job.refusal_outcome(job.NotFound(id: "01JQ")).is_error
/// ```
///
pub fn refusal_outcome(refusal: Refusal) -> ToolOutcome {
  tool.failure(refusal_reason(refusal))
  |> tool.with_details(
    json.Object([
      #("error", json.String(refusal_code(refusal))),
      #("reason", json.String(refusal_reason(refusal))),
    ]),
  )
}

/// The in-band code one refusal travels under.
///
/// Public because it is half of a contract: `cap/job` decodes each of
/// these strings back into the error variant of the same name, and
/// `codemode/workspace` puts them on the capability wire.
///
/// ## Examples
///
/// ```gleam
/// assert job.refusal_code(job.CeilingReached(limit: 4)) == "job_ceiling"
/// ```
///
pub fn refusal_code(refusal: Refusal) -> String {
  case refusal {
    CeilingReached(..) -> "job_ceiling"
    NotFound(..) -> "job_not_found"
    Invalid(..) -> "invalid_job_request"
    ClearanceRefused(..) -> "job_clearance_refused"
    Unavailable(..) -> "jobs_unavailable"
  }
}

/// The worded reason one refusal carries, for a caller rendering it
/// somewhere other than a `ToolOutcome` — the code-mode bridge needs the
/// sentence without the tool-result wrapper around it.
///
/// ## Examples
///
/// ```gleam
/// // job.refusal_reason(job.NotFound(id: "01JQ"))
/// ```
///
pub fn refusal_reason(refusal: Refusal) -> String {
  case refusal {
    CeilingReached(limit:) ->
      "this strand already holds its limit of "
      <> int.to_string(limit)
      <> " background jobs. Stop one with "
      <> kill_tool_name
      <> " before starting another."

    NotFound(id:) ->
      "you own no background job \""
      <> id
      <> "\". "
      <> poll_tool_name
      <> " with no job_id lists the ones you can read."

    Invalid(reason:) -> reason

    ClearanceRefused(reason:) -> reason

    Unavailable(reason:) ->
      "the background jobs plane could not be reached (" <> reason <> ")."
  }
}

// The job door touches no file and runs nothing jailed of its own: the
// job's command is cleared by the host under the job's own identity, not
// under this call's. So the tools ask for nothing, exactly as
// `tools/schedule` does.
fn empty_requirements(workspace: String) -> SandboxPolicy {
  let base = tool.read_requirements(workspace)
  policy.SandboxPolicy(..base, readable_roots: [])
}
