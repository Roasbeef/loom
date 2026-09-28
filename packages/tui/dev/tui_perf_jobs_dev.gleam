//// Three running jobs that never answer, for the mailbox-scan measurement.
////
//// After phase 2 S4 the runtime reads every running job's reply selector on
//// every event (`runtime.receive`). This module puts a control job, a
//// relaunch and an activity poll in `Model.running`, each a worker that
//// sleeps past any benchmark, and parks each slot on its key, so the driver
//// can measure how the per-event reads behave with a socket backlog in the
//// mailbox. A revision from before S4, where each slot held its reply
//// subject and only the tick read it, needs its own copy of this module
//// that parks the same three slots on fresh subjects instead.

import gleam/erlang/process
import gleam/option.{None, Some}
import tui/job
import tui/job_runner
import tui/model.{type Model, Model, View} as tui_model

const forever_ms = 100_000_000

/// The model with three jobs running and each slot waiting on its key.
///
/// ## Examples
///
/// ```gleam
/// let model = tui_perf_jobs_dev.with_jobs(model)
/// ```
pub fn with_jobs(model: Model) -> Model {
  let #(model, control) = tui_model.allocate_job(model)
  let #(model, relaunch) = tui_model.allocate_job(model)
  let #(model, activity) = tui_model.allocate_job(model)
  let running =
    model.view.running
    |> job_runner.start_task(control, sleep, forever_ms, job.ControlArrived)
    |> job_runner.start_task(relaunch, sleep, forever_ms, job.ReconnectArrived)
    |> job_runner.start_task(activity, sleep, forever_ms, job.ActivityArrived)
  Model(
    ..model,
    view: View(
      ..model.view,
      running:,
      control_request: Some(tui_model.ControlRequest(
        job: job.awaiting(control),
        result: None,
      )),
      reconnect: tui_model.ReconnectAttempting(job: job.awaiting(relaunch)),
      activity_poll: tui_model.ActivityAsking(
        job: job.awaiting(activity),
        asked: [],
      ),
    ),
  )
}

// The worker outlives every measurement, so no reply ever reaches the
// mailbox and each read is a full scan that matches nothing.
fn sleep() -> Result(a, String) {
  process.sleep(forever_ms)
  Error("the benchmark worker never finishes")
}
