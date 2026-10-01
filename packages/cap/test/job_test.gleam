//// Job identities and stream positions are validated before they leave the
//// capability boundary. The fake channel checks the unchanged wire format.

import cap/internal/channel
import cap/internal/dispatch
import cap/internal/wire
import cap/job
import cap/report
import core/msgpack
import gleam/list

fn id() -> job.JobId {
  let assert Ok(id) = job.parse_job_id("job-one") as "fixture job id is valid"
  id
}

fn answer(value: report.Value) {
  dispatch.install(channel.Channel(call: fn(_, _, _) { Ok(value) }))
}

fn stream(cursor: Int) -> report.Value {
  wire.args([
    #("bytes", wire.binary(<<"output":utf8>>)),
    #("cursor", report.int(cursor)),
    #("dropped", report.int(0)),
  ])
}

fn running(id: String, stdout: Int, stderr: Int) -> report.Value {
  report.object([
    #("job_id", report.string(id)),
    #("state", report.string("running")),
    #("age_ms", report.int(100)),
    #("deadline_ms", report.int(5000)),
    #("stdout", stream(stdout)),
    #("stderr", stream(stderr)),
  ])
}

pub fn saved_ids_follow_the_host_register_grammar_test() {
  list.each(["", "job/child", "/", "../job"], fn(text) {
    let assert Error(_) = job.parse_job_id(text)
      as "empty and multi-segment ids cannot be constructed"
  })

  // The host grammar intentionally imposes no UUID or whitespace rule.
  list.each(["job-one", "opaque id", ".", "é"], fn(text) {
    let assert Ok(id) = job.parse_job_id(text) as "single-segment id is valid"
    assert job.job_id_to_string(id) == text
  })
}

pub fn typed_cursors_preserve_the_two_wire_positions_test() {
  let assert Error(_) = job.parse_stdout_cursor(-1)
    as "stdout never accepts a negative cursor"
  let assert Error(_) = job.parse_stderr_cursor(-1)
    as "stderr never accepts a negative cursor"
  let assert Ok(stdout) = job.parse_stdout_cursor(17)
    as "saved stdout cursor restores"
  let assert Ok(stderr) = job.parse_stderr_cursor(9)
    as "saved stderr cursor restores"
  let cursors = job.Cursors(stdout:, stderr:)
  dispatch.install(
    channel.Channel(call: fn(cap, args, _) {
      assert cap == "job.poll"
      assert wire.string_field(args, "job_id") == Ok("job-one")
      assert wire.int_field(args, "since_stdout") == Ok(17)
      assert wire.int_field(args, "since_stderr") == Ok(9)
      Ok(running("job-one", 23, 11))
    }),
  )
  let assert Ok(watched) = job.poll(id(), 0, cursors)
    as "poll returns domain-specific cursors"
  let next = job.after(watched)
  assert job.stdout_cursor_to_int(next.stdout) == 23
  assert job.stderr_cursor_to_int(next.stderr) == 11
  assert job.stdout_cursor_to_int(job.from_start().stdout) == 0
  assert job.stderr_cursor_to_int(job.from_start().stderr) == 0
}

pub fn malformed_ids_are_rejected_in_every_response_shape_test() {
  list.each(["", "job/child"], fn(invalid) {
    answer(
      report.object([
        #("job_id", report.string(invalid)),
        #("deadline_ms", report.int(5000)),
        #("wall_ms", report.int(1000)),
      ]),
    )
    let assert Error(job.JobResultMalformed(_)) = job.start("true")
      as "start validates its returned identity"

    let value = running(invalid, 0, 0)
    answer(value)
    let assert Error(job.JobResultMalformed(_)) =
      job.poll(id(), 0, job.from_start())
      as "poll validates its returned identity"
    answer(report.object([#("jobs", report.list([value]))]))
    let assert Error(job.JobResultMalformed(_)) = job.list()
      as "every listed identity is validated"
  })
}

pub fn negative_wire_cursors_fail_without_clamping_test() {
  list.each([#(-1, 0), #(0, -1)], fn(offsets) {
    answer(running("job-one", offsets.0, offsets.1))
    let assert Error(job.JobResultMalformed(_)) =
      job.poll(id(), 0, job.from_start())
      as "a malformed stream cannot masquerade as a start cursor"
  })
}

pub fn transport_and_malformed_answers_remain_distinct_test() {
  dispatch.install(
    channel.Channel(call: fn(_, _, _) { Error(channel.Unreachable("closed")) }),
  )
  assert job.start("true") == Error(job.JobUnavailable("closed"))
  answer(report.null())
  let assert Error(job.JobResultMalformed(_)) = job.start("true")
    as "an answer that arrived is not a transport failure"
}

pub fn ids_render_unchanged_for_stdin_and_kill_test() {
  dispatch.install(
    channel.Channel(call: fn(cap, args, _) {
      assert wire.string_field(args, "job_id") == Ok("job-one")
      case cap {
        "job.kill" -> Nil
        "job.send" -> {
          assert wire.binary_field(args, "data") == Ok(<<"input":utf8>>)
          assert wire.bool_field(args, "eof") == Ok(True)
        }
        _ -> panic as "only stop and stdin calls are expected"
      }
      Ok(report.null())
    }),
  )
  assert job.kill(id()) == Ok(Nil)
  assert job.send_last(id(), <<"input":utf8>>) == Ok(Nil)
}

pub fn timeout_and_cancellation_can_both_be_true_test() {
  let exit =
    report.object([
      #("code", report.int(143)),
      #("signal", report.int(15)),
      #("wall_ms", report.int(1000)),
      #("timed_out", report.bool(True)),
      #("cancelled", report.bool(True)),
      #("stdout_bytes", report.int(0)),
      #("stderr_bytes", report.int(0)),
      #("stdout_truncated", report.bool(False)),
      #("stderr_truncated", report.bool(False)),
    ])
  answer(
    report.object([
      #(
        "jobs",
        report.list([
          report.object([
            #("job_id", report.string("job-one")),
            #("state", report.string("killed")),
            #("stopped_by", report.string("deadline")),
            #("age_ms", report.int(1000)),
            #("deadline_ms", report.int(5000)),
            #("exit", exit),
          ]),
        ]),
      ),
    ]),
  )
  let assert Ok([row]) = job.list() as "the terminal record decodes"
  let assert job.Killed(job.ByDeadline, exit) = row.state
    as "the deadline remains the recorded stop cause"
  assert exit.timed_out
  assert exit.cancelled
}

pub fn malformed_spill_reference_does_not_look_absent_test() {
  let assert msgpack.MapValue(fields) = running("job-one", 0, 0)
    as "fixture is a job object"
  answer(
    msgpack.MapValue([#(report.string("stdout_ref"), report.int(7)), ..fields]),
  )
  let assert Error(job.JobResultMalformed(_)) =
    job.poll(id(), 0, job.from_start())
    as "a present malformed reference must not become missing output"
}
