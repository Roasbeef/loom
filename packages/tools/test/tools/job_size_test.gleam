//// A regression pin for the `job_*` family's narrowed capture.
////
//// Same shape as `agent_size_test.gleam` and `schedule_size_test.gleam`:
//// each `job_*` tool's `run` closure used to hold the whole `Jobs`
//// record, so a padded slot none of `job_send`'s work touches would
//// still be duplicated on every copy of that closure. The fix
//// (`packages/tools/src/tools/job.gleam`, and `client/jobtools.seam` on
//// the host side) binds each tool to only the slots it calls.

import gleam/list
import gleam/option.{None}
import support/internal/ffi_memory
import tools/job

// A `Jobs` identical in every slot `job_send` never touches, except that
// `list`'s closure additionally holds a list of the given length.
// `job_send` calls only `send`, so a `send_tool` built correctly must not
// see this padding at all.
fn padded_jobs(padding_words: Int) -> job.Jobs {
  let padding = list.repeat(0, padding_words)
  job.Jobs(
    start: fn(_ctx, _command, _wall) {
      Ok(job.Started(id: "job", deadline_ms: 0, wall_ms: 0))
    },
    poll: fn(_ctx, _id, _wait, _cursors) {
      Ok(job.Polled(
        id: "job",
        state: job.Running,
        age_ms: 0,
        deadline_ms: 0,
        stdout: job.Streamed(bytes: <<>>, cursor: 0, dropped: 0),
        stderr: job.Streamed(bytes: <<>>, cursor: 0, dropped: 0),
        spill: job.JobSpill(stdout_ref: None, stderr_ref: None),
      ))
    },
    // The padded slot. `list.length` keeps the capture live rather than
    // one the compiler could drop as unused.
    list: fn(_ctx) {
      case list.length(padding) {
        0 -> Ok([])
        _ -> Ok([])
      }
    },
    kill: fn(_ctx, _id) { Ok(Nil) },
    send: fn(_ctx, _id, _data, _end) { Ok(Nil) },
    max_wait_ms: 5000,
  )
}

pub fn send_tool_does_not_capture_whole_jobs_test() {
  let light = padded_jobs(1)
  let heavy = padded_jobs(4096)

  // Sanity: the padding actually lands where the closure said it would.
  assert ffi_memory.flat_words(heavy.list)
    > ffi_memory.flat_words(light.list) + 4096

  let tools_light = job.tools(light)
  let tools_heavy = job.tools(heavy)

  // `job_send` is always last — see `job.tools`.
  let assert [_poll_light, _kill_light, send_light] = tools_light
  let assert [_poll_heavy, _kill_heavy, send_heavy] = tools_heavy
  assert ffi_memory.flat_words(send_heavy.run)
    == ffi_memory.flat_words(send_light.run)
}
