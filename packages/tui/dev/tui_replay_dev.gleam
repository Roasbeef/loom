//// Validated render profiling over a private terminal recording.
////
//// Decoding a recording proves its container shape, not that its embedded
//// gateway frames reach the reducer. This driver checks admitted history and
//// failure notices before reporting a time, so stale wire fixtures cannot
//// silently turn a conversation benchmark into an error-line benchmark.

import etui/backend
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
import tui
import tui/agents
import tui/connection
import tui/recording
import tui/virtual_backend
import tui/workspace

type ClockUnit {
  Microsecond
}

@external(erlang, "erlang", "monotonic_time")
fn now(unit: ClockUnit) -> Int

/// Replays a recording and refuses timings for missing or rejected history.
///
/// The expected count is the final retained history, after any replacement
/// snapshots. Inputs that intentionally exercise protocol failures belong in
/// correctness tests rather than this conversation-rendering workload.
///
/// ## Examples
///
/// ```sh
/// gleam dev replay /private/tmp/authorized-recording.jsonl 532
/// ```
pub fn run(path: String, expected_records: Int) -> Nil {
  assert expected_records > 0 as "a history benchmark must contain records"
  let assert Ok(moments) = recording.decode_file(path)
    as "the private recording must decode"
  let inbox = connection.new_inbox()
  let model =
    tui.Model(
      ..tui.new_model(inbox, workspace.Context("replay", None)),
      peer: tui.Replaying,
      transcript: [],
      models: [],
      session: "replay",
      strands: [],
      agent_summary: agents.summary([]),
      notice: "replaying",
    )
  let script =
    virtual_backend.script(
      backend.TerminalSize(160, 48),
      recording.to_steps(moments),
      inbox,
    )
    |> virtual_backend.with_attempts(model.replay_inbox)
  let start = now(Microsecond)
  let assert Ok(completed) = tui.run_script(model, script)
    as "the virtual terminal must finish"
  let elapsed = now(Microsecond) - start

  // The run's final model is the admission witness. Frame count or successful
  // recording decoding alone also succeeds when every wire event is refused.
  let final = completed.final
  assert final.replay_error == None as "the replay must not report an error"
  assert list.length(final.records) == expected_records
    as "the reducer must retain the expected durable history"
  assert !list.any(final.transcript, fn(line) { line.speaker == tui.Failure })
    as "the replay must not render protocol failures"
  io.println(
    "replay records="
    <> int.to_string(list.length(final.records))
    <> " rows="
    <> int.to_string(final.rendered_row_count)
    <> " frames="
    <> int.to_string(list.length(completed.frames))
    <> " elapsed_us="
    <> int.to_string(elapsed),
  )
}
