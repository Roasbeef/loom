//// The `job_*` tools and `bash`'s `mode` argument, against a scripted
//// door.
////
//// The seam is a fake because everything worth proving here is on this
//// side of it: which schema the model reads, what an argument becomes,
//// which refusal a call renders, and — the load-bearing one — that a job
//// still running comes back as a *success* carrying `details.pending`.
//// The door's own behaviour is `client`'s and is tested there.

import broker/exec
import core/json
import core/message
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import support/fake_broker
import support/memory_fs
import tools/bash
import tools/job
import tools/tool

const workspace = "/work"

const now = 50_000

const job_id = "01JQ8XZ"

// --- the scripted door ------------------------------------------------------

// What the door was asked, so a test can prove an argument reached it as
// the tool read it rather than only that a call happened.
type Asked {
  StartAsked(command: String, wall_ms: option.Option(Int))
  PollAsked(id: String, wait_ms: Int, cursors: job.Cursors)
  ListAsked
  KillAsked(id: String)
  SendAsked(id: String, bytes: BitArray, end: job.StdinEnd)
}

fn recorder() -> Subject(Asked) {
  process.new_subject()
}

fn drain(asked: Subject(Asked)) -> List(Asked) {
  case process.receive(asked, within: 0) {
    Error(Nil) -> []
    Ok(one) -> [one, ..drain(asked)]
  }
}

// A door answering a job in `state`, recording every call. The wait
// ceiling is a small number rather than the real thirty seconds, so a
// test proving the clamp does not have to write 30_001 to see it move.
fn answering(asked: Subject(Asked), state: job.JobState) -> job.Jobs {
  job.Jobs(
    start: fn(_ctx, command, wall_ms) {
      process.send(asked, StartAsked(command, wall_ms))
      Ok(job.Started(id: job_id, deadline_ms: 1_000_000, wall_ms: 600_000))
    },
    poll: fn(_ctx, id, wait_ms, cursors) {
      process.send(asked, PollAsked(id, wait_ms, cursors))
      Ok(polled(state))
    },
    list: fn(_ctx) {
      process.send(asked, ListAsked)
      Ok([
        job.Listed(
          id: job_id,
          state: job.Running,
          age_ms: 4200,
          deadline_ms: 1_000_000,
        ),
      ])
    },
    kill: fn(_ctx, id) {
      process.send(asked, KillAsked(id))
      Ok(Nil)
    },
    send: fn(_ctx, id, bytes, end) {
      process.send(asked, SendAsked(id, bytes, end))
      Ok(Nil)
    },
    max_wait_ms: 5000,
  )
}

fn polled(state: job.JobState) -> job.Polled {
  job.Polled(
    id: job_id,
    state:,
    age_ms: 4200,
    deadline_ms: 1_000_000,
    stdout: job.Streamed(bytes: <<"building\n":utf8>>, cursor: 9, dropped: 0),
    stderr: job.Streamed(bytes: <<>>, cursor: 0, dropped: 0),
    spill: job.JobSpill(stdout_ref: None, stderr_ref: None),
  )
}

// A door whose every operation refuses, for the in-band-refusal tests.
fn refusing(refusal: job.Refusal) -> job.Jobs {
  job.Jobs(
    start: fn(_ctx, _command, _wall) { Error(refusal) },
    poll: fn(_ctx, _id, _wait, _cursors) { Error(refusal) },
    list: fn(_ctx) { Error(refusal) },
    kill: fn(_ctx, _id) { Error(refusal) },
    send: fn(_ctx, _id, _data, _end) { Error(refusal) },
    max_wait_ms: 5000,
  )
}

const finished = job.Exited(
  result: exec.ExecResult(
    code: 3,
    signal: 0,
    stdout_bytes: 9,
    stderr_bytes: 0,
    stdout_truncated: False,
    stderr_truncated: False,
    enforcement: [],
    degraded: False,
    wall_ms: 4100,
    timed_out: False,
    cancelled: False,
  ),
)

// --- running one tool -------------------------------------------------------

fn ctx() -> tool.Ctx {
  fake_broker.ctx(
    workspace:,
    filesystem: memory_fs.filesystem(memory_fs.start()),
    now:,
    script: [],
    recorded: process.new_subject(),
  )
}

fn named(jobs: job.Jobs, name: String) -> tool.Tool {
  let assert Ok(found) =
    list.find(job.tools(jobs), fn(each) { each.name == name })
    as { "the job tools must include " <> name }
  found
}

fn run(jobs: job.Jobs, name: String, args: json.JsonValue) -> tool.ToolOutcome {
  named(jobs, name).run(ctx(), args)
}

fn first_text(outcome: tool.ToolOutcome) -> String {
  let assert [message.ToolResultText(text:, text_signature: _)] =
    outcome.content
    as "expected a single text block"
  text
}

fn detail(outcome: tool.ToolOutcome, key: String) -> json.JsonValue {
  let assert Some(json.Object(fields)) = outcome.details
    as "expected an object of details"
  let assert Ok(found) = list.key_find(fields, key)
    as { "expected a detail named " <> key }
  found
}

fn schema_of(jobs: job.Jobs, name: String) -> List(#(String, json.JsonValue)) {
  let assert json.Object(fields) = named(jobs, name).schema
    as "a tool schema is an object"
  fields
}

fn properties(jobs: job.Jobs, name: String) -> List(String) {
  let assert Ok(json.Object(props)) =
    list.key_find(schema_of(jobs, name), "properties")
    as "a tool schema declares properties"
  list.map(props, fn(entry) { entry.0 })
}

fn required(jobs: job.Jobs, name: String) -> json.JsonValue {
  let assert Ok(found) = list.key_find(schema_of(jobs, name), "required")
    as "a tool schema declares its required arguments"
  found
}

// --- the surface ------------------------------------------------------------

pub fn the_plane_registers_exactly_three_tools_test() {
  // A list rather than three exported functions: a host that could
  // register the stopper without the poller would offer a model a job it
  // could start and never read.
  let asked = recorder()
  assert list.map(job.tools(answering(asked, job.Running)), fn(each) {
      each.name
    })
    == ["job_poll", "job_kill", "job_send"]
}

pub fn every_job_tool_is_never_replayed_and_concurrent_test() {
  // A replayed kill climbs a ladder twice and a replayed send writes to
  // a REPL twice; none of the three touches the workspace.
  let asked = recorder()
  list.each(job.tools(answering(asked, job.Running)), fn(each) {
    assert each.replay == tool.Never
    assert each.execution_mode == tool.Concurrent
  })
}

pub fn job_poll_requires_nothing_test() {
  // No id is the listing, which is why there is no fourth tool.
  let asked = recorder()
  let jobs = answering(asked, job.Running)
  assert required(jobs, "job_poll") == json.Array([])
  assert properties(jobs, "job_poll") == ["job_id", "wait_ms", "since"]
}

pub fn job_kill_and_send_require_their_job_test() {
  let asked = recorder()
  let jobs = answering(asked, job.Running)
  assert required(jobs, "job_kill") == json.Array([json.String("job_id")])
  assert required(jobs, "job_send")
    == json.Array([json.String("job_id"), json.String("data")])
}

pub fn the_wait_description_states_the_seams_own_ceiling_test() {
  // The number in the description and the number a call meets are one
  // fact, passed in rather than restated — so a seam with a different
  // ceiling describes itself honestly.
  let asked = recorder()
  let assert Ok(json.Object(props)) =
    list.key_find(
      schema_of(answering(asked, job.Running), "job_poll"),
      "properties",
    )
    as "job_poll declares properties"
  let assert Ok(json.Object(wait)) = list.key_find(props, "wait_ms")
    as "job_poll declares wait_ms"
  let assert Ok(json.String(described)) = list.key_find(wait, "description")
    as "wait_ms carries a description"
  assert string.contains(described, "5000")
}

pub fn the_eof_argument_is_a_closed_vocabulary_test() {
  let asked = recorder()
  let assert Ok(json.Object(props)) =
    list.key_find(
      schema_of(answering(asked, job.Running), "job_send"),
      "properties",
    )
    as "job_send declares properties"
  let assert Ok(json.Object(eof)) = list.key_find(props, "eof")
    as "job_send declares eof"
  assert list.key_find(eof, "enum")
    == Ok(json.Array([json.String("open"), json.String("close")]))
}

// --- pending is an answer ---------------------------------------------------

pub fn a_poll_is_a_success_that_says_whether_to_come_back_test() {
  // The rule `agent_wait` already follows: an `is_error` for a running
  // job would teach a model that waiting is a fault to retry out of,
  // which is the one behaviour a wait exists to prevent. Both polarities
  // live in one test on purpose — `details.pending` is one claim, and
  // splitting it would make removing the field fail twice for one bug.
  let asked = recorder()
  let running =
    run(answering(asked, job.Running), "job_poll", poll_args(job_id))
  assert !running.is_error
  assert detail(running, "pending") == json.Bool(True)

  let done = run(answering(asked, finished), "job_poll", poll_args(job_id))
  assert !done.is_error
  assert detail(done, "pending") == json.Bool(False)
}

pub fn a_running_poll_renders_the_state_and_the_new_output_test() {
  let asked = recorder()
  let outcome =
    run(answering(asked, job.Running), "job_poll", poll_args(job_id))
  assert detail(outcome, "state") == json.String("running")
  assert string.contains(first_text(outcome), "building")
}

pub fn a_finished_poll_carries_the_helpers_exit_report_test() {
  let asked = recorder()
  let outcome = run(answering(asked, finished), "job_poll", poll_args(job_id))
  assert detail(outcome, "state") == json.String("exited")
  assert detail(outcome, "exit_code") == json.Int(3)

  // The helper's own witness that it climbed the ladder, which nothing
  // else in the report can say (`protocol-change/006`).
  assert detail(outcome, "cancelled") == json.Bool(False)
}

pub fn a_live_job_carries_no_exit_report_test() {
  // "No exit yet" and "exited zero" must not be the same JSON, or a
  // client reading `details` alone cannot tell them apart.
  let asked = recorder()
  let outcome =
    run(answering(asked, job.Running), "job_poll", poll_args(job_id))
  let assert Some(json.Object(fields)) = outcome.details
    as "expected an object of details"
  assert list.key_find(fields, "exit_code") == Error(Nil)
}

// --- the cursor -------------------------------------------------------------

pub fn an_absent_cursor_reads_the_whole_tail_test() {
  let asked = recorder()
  let _outcome =
    run(answering(asked, job.Running), "job_poll", poll_args(job_id))
  assert drain(asked)
    == [PollAsked(job_id, 0, job.Cursors(stdout: 0, stderr: 0))]
}

pub fn a_cursor_round_trips_through_the_model_test() {
  // The token the poll answers with is the token the next poll takes;
  // nothing in between parses it.
  let asked = recorder()
  let outcome =
    run(answering(asked, job.Running), "job_poll", poll_args(job_id))
  let assert json.String(cursor) = detail(outcome, "cursor")
    as "a poll answers with a cursor"
  let _next =
    run(
      answering(asked, job.Running),
      "job_poll",
      json.Object([
        #("job_id", json.String(job_id)),
        #("since", json.String(cursor)),
      ]),
    )
  let assert [_first, PollAsked(_id, _wait, cursors)] = drain(asked)
    as "the second poll must reach the door"
  assert cursors == job.Cursors(stdout: 9, stderr: 0)
}

pub fn a_cursor_the_model_invented_is_refused_test() {
  // Refused rather than clamped to the start of the stream: a cursor is
  // a token this tool minted, so one that could not have been minted
  // means the model built its own, and a silent rewind would hide that
  // behind a flood of output it had already read.
  let asked = recorder()
  list.each(["nonsense", "1", "1:2:3", "-1:0", "a:b"], fn(bad) {
    let outcome =
      run(
        answering(asked, job.Running),
        "job_poll",
        json.Object([
          #("job_id", json.String(job_id)),
          #("since", json.String(bad)),
        ]),
      )
    assert outcome.is_error
  })
  assert drain(asked) == []
}

pub fn a_wait_is_clamped_to_the_seams_ceiling_test() {
  let asked = recorder()
  let _outcome =
    run(
      answering(asked, job.Running),
      "job_poll",
      json.Object([
        #("job_id", json.String(job_id)),
        #("wait_ms", json.Int(900_000)),
      ]),
    )
  let assert [PollAsked(_id, wait_ms, _cursors)] = drain(asked)
    as "the poll must reach the door"
  assert wait_ms == 5000
}

// --- the listing ------------------------------------------------------------

pub fn a_poll_with_no_id_lists_test() {
  let asked = recorder()
  let outcome = run(answering(asked, job.Running), "job_poll", json.Object([]))
  assert !outcome.is_error
  assert drain(asked) == [ListAsked]
  assert string.contains(first_text(outcome), job_id)
  assert detail(outcome, "jobs") != json.Array([])
}

// --- kill and send ----------------------------------------------------------

pub fn a_kill_reports_the_state_it_settled_into_test() {
  let asked = recorder()
  let outcome =
    run(
      answering(asked, finished),
      "job_kill",
      json.Object([#("job_id", json.String(job_id))]),
    )
  assert !outcome.is_error
  assert detail(outcome, "state") == json.String("exited")
  assert detail(outcome, "pending") == json.Bool(False)
  let assert [KillAsked(killed), PollAsked(..)] = drain(asked)
    as "a kill asks the ladder and then reads the state"
  assert killed == job_id
}

pub fn a_kill_that_is_still_draining_says_so_test() {
  // The ladder is asynchronous, so a kill that claimed a terminal state
  // would be claiming something the harness has not observed.
  let asked = recorder()
  let outcome =
    run(
      answering(asked, job.Draining(by: job.ByOwner)),
      "job_kill",
      json.Object([#("job_id", json.String(job_id))]),
    )
  assert detail(outcome, "state") == json.String("draining")
  assert detail(outcome, "pending") == json.Bool(True)
}

pub fn a_send_defaults_to_leaving_stdin_open_test() {
  let asked = recorder()
  let outcome =
    run(
      answering(asked, job.Running),
      "job_send",
      json.Object([
        #("job_id", json.String(job_id)),
        #("data", json.String("2 + 2\n")),
      ]),
    )
  assert !outcome.is_error
  assert detail(outcome, "eof") == json.String("open")
  assert drain(asked)
    == [SendAsked(job_id, <<"2 + 2\n":utf8>>, job.KeepStdinOpen)]
}

pub fn a_send_can_close_stdin_test() {
  let asked = recorder()
  let outcome =
    run(
      answering(asked, job.Running),
      "job_send",
      json.Object([
        #("job_id", json.String(job_id)),
        #("data", json.String("quit\n")),
        #("eof", json.String("close")),
      ]),
    )
  assert detail(outcome, "eof") == json.String("close")
  assert drain(asked) == [SendAsked(job_id, <<"quit\n":utf8>>, job.CloseStdin)]
}

pub fn an_eof_outside_the_vocabulary_never_reaches_the_door_test() {
  let asked = recorder()
  let outcome =
    run(
      answering(asked, job.Running),
      "job_send",
      json.Object([
        #("job_id", json.String(job_id)),
        #("data", json.String("x")),
        #("eof", json.String("maybe")),
      ]),
    )
  assert outcome.is_error
  assert drain(asked) == []
}

// --- refusals are in band ---------------------------------------------------

pub fn every_refusal_renders_as_an_in_band_failure_test() {
  // Never a crash, and never a bare sentence: the code is what a client
  // and a code-mode program both branch on.
  let cases = [
    #(job.CeilingReached(limit: 4), "job_ceiling"),
    #(job.NotFound(id: job_id), "job_not_found"),
    #(job.Invalid(reason: "no"), "invalid_job_request"),
    #(job.ClearanceRefused(reason: "policy"), "job_clearance_refused"),
    #(job.Unavailable(reason: "down"), "jobs_unavailable"),
  ]
  list.each(cases, fn(one) {
    let outcome = run(refusing(one.0), "job_poll", poll_args(job_id))
    assert outcome.is_error
    assert detail(outcome, "error") == json.String(one.1)
  })
}

pub fn a_refused_listing_is_in_band_too_test() {
  let outcome =
    run(refusing(job.Unavailable(reason: "down")), "job_poll", json.Object([]))
  assert outcome.is_error
  assert detail(outcome, "error") == json.String("jobs_unavailable")
}

// --- bash's two modes -------------------------------------------------------

fn bash_run(jobs: job.Jobs, args: json.JsonValue) -> tool.ToolOutcome {
  bash.tool(jobs).run(ctx(), args)
}

pub fn the_bash_schema_defaults_to_the_foreground_test() {
  // The default is what keeps every `bash` call written before this
  // argument existed meaning exactly what it meant: `mode` is optional,
  // and only `command` is required.
  let asked = recorder()
  let assert json.Object(fields) =
    bash.tool(answering(asked, job.Running)).schema
    as "a tool schema is an object"
  assert list.key_find(fields, "required")
    == Ok(json.Array([json.String("command")]))
  let assert Ok(json.Object(props)) = list.key_find(fields, "properties")
    as "the bash schema declares properties"
  let assert Ok(json.Object(mode)) = list.key_find(props, "mode")
    as "the bash schema declares mode"
  assert list.key_find(mode, "enum")
    == Ok(json.Array([json.String("foreground"), json.String("background")]))
}

pub fn a_bash_call_with_no_mode_never_reaches_the_jobs_door_test() {
  // The foreground path is what it was: the door is present, the command
  // clears through the broker, and the jobs seam is never asked. That
  // the broker path itself is unchanged is `bash_test`'s subject.
  let asked = recorder()
  let ctx =
    fake_broker.ctx(
      workspace:,
      filesystem: memory_fs.filesystem(memory_fs.start()),
      now:,
      script: [fake_broker.exited(code: 0, stdout_bytes: 0)],
      recorded: process.new_subject(),
    )
  let outcome =
    bash.tool(answering(asked, job.Running)).run(
      ctx,
      json.Object([#("command", json.String("true"))]),
    )
  assert !outcome.is_error
  assert drain(asked) == []
}

pub fn a_background_call_starts_a_job_and_returns_its_handle_test() {
  let asked = recorder()
  let outcome =
    bash_run(
      answering(asked, job.Running),
      json.Object([
        #("command", json.String("make check")),
        #("mode", json.String("background")),
      ]),
    )
  assert !outcome.is_error
  assert detail(outcome, "job_id") == json.String(job_id)
  assert detail(outcome, "mode") == json.String("background")
  assert detail(outcome, "wall_ms") == json.Int(600_000)
  assert drain(asked) == [StartAsked("make check", None)]
}

pub fn a_background_timeout_reaches_the_door_unclamped_test() {
  // `bash`'s own ceiling is ten minutes and a job's is the host's hour,
  // so clamping here would silently cap a job at the foreground limit
  // and no reader of either number could tell which had applied.
  let asked = recorder()
  let _outcome =
    bash_run(
      answering(asked, job.Running),
      json.Object([
        #("command", json.String("./serve")),
        #("mode", json.String("background")),
        #("timeout_ms", json.Int(3_600_000)),
      ]),
    )
  assert drain(asked) == [StartAsked("./serve", Some(3_600_000))]
}

pub fn a_background_refusal_is_in_band_in_the_doors_own_words_test() {
  let outcome =
    bash_run(
      refusing(job.CeilingReached(limit: 4)),
      json.Object([
        #("command", json.String("make")),
        #("mode", json.String("background")),
      ]),
    )
  assert outcome.is_error
  assert detail(outcome, "error") == json.String("job_ceiling")
  assert string.contains(first_text(outcome), "4")
}

pub fn a_host_with_no_jobs_plane_answers_rather_than_crashing_test() {
  // `bash` takes the door unconditionally, so this is the path a build
  // that never stood the actor up takes.
  let outcome =
    bash.tool(job.unavailable()).run(
      ctx(),
      json.Object([
        #("command", json.String("make")),
        #("mode", json.String("background")),
      ]),
    )
  assert outcome.is_error
  assert detail(outcome, "error") == json.String("jobs_unavailable")
}

pub fn a_mode_outside_the_vocabulary_is_refused_test() {
  let asked = recorder()
  let outcome =
    bash_run(
      answering(asked, job.Running),
      json.Object([
        #("command", json.String("make")),
        #("mode", json.String("detached")),
      ]),
    )
  assert outcome.is_error
  assert drain(asked) == []
}

fn poll_args(id: String) -> json.JsonValue {
  json.Object([#("job_id", json.String(id))])
}
