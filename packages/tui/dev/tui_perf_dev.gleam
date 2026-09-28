//// The model a CPU and memory comparison drives through `tui.update`.
////
//// The driver in `scripts/tui_perf.erl` measures reductions, allocated words
//// and wall time around single calls of `tui.update`. It needs a model built
//// the same way on every revision it compares, so the construction lives
//// here, in Gleam, where the record update is checked by the compiler, and
//// the measurement lives in Erlang, where `process_info` and `tprof` are
//// direct. To compare against an older revision, copy this module into that
//// checkout's `dev/` unchanged; only `tui_perf_jobs_dev`, which stands up
//// running jobs, has to be written for the job API of each revision.

import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import session_view/connection_event
import session_view/transcript_line
import tui
import tui/agents
import tui/connection
import tui/model as tui_model
import tui/workspace

/// A presentation model in the replay posture, and the connection subject
/// its frames arrive on.
///
/// The posture matches `tui_replay_dev`, so a version 1 `Incoming` frame is
/// reduced by the presentation path on both revisions. The subject belongs
/// to the calling process, which must be the one that calls `tui.update`.
///
/// The presentation clock reads the process dictionary key `tui_perf_now`,
/// which the driver sets before every call. Frame pacing, cache refreshes
/// and animation all read that clock, so a sample taken at a real clock
/// would sometimes include a frame's projection and sometimes not; pinning
/// it makes every sample of one event do the same work on both revisions.
///
/// ## Examples
///
/// ```gleam
/// let #(inbox, model) = tui_perf_dev.bench_model()
/// ```
pub fn bench_model() -> #(Subject(connection_event.Message), tui_model.Model) {
  let inbox = connection.new_inbox()
  let model =
    tui.new_model_with_clock(inbox, workspace.Context("bench", None), fn() {
      dictionary_get(atom.create("tui_perf_now"))
    })
  #(inbox, replay_posture(model))
}

/// The same posture on the host's own clock, for an end-to-end replay whose
/// pacing should be the shipped loop's.
///
/// ## Examples
///
/// ```gleam
/// let #(inbox, model) = tui_perf_dev.replay_model()
/// ```
pub fn replay_model() -> #(Subject(connection_event.Message), tui_model.Model) {
  let inbox = connection.new_inbox()
  #(
    inbox,
    replay_posture(tui.new_model(inbox, workspace.Context("bench", None))),
  )
}

// The posture `tui_replay_dev` uses: a replaying peer with the demo
// transcript, catalogue and strands emptied, so the frames the driver sends
// build the only history the model holds and every revision starts from the
// same state.
fn replay_posture(model: tui_model.Model) -> tui_model.Model {
  tui_model.Model(
    shared: tui_model.Shared(
      ..model.shared,
      peer: tui_model.Replaying,
      transcript: [],
      models: [],
      session: "bench",
      strands: [],
      notice: "bench",
    ),
    view: tui_model.View(..model.view, agent_summary: agents.summary([])),
  )
}

/// The same model with a live peer, as a terminal that is not replaying.
///
/// The runtime reads some inboxes only in one posture: the replay inbox is
/// read only while the peer is `Replaying`. A measurement of what a live
/// terminal's mailbox reads cost takes this posture.
///
/// ## Examples
///
/// ```gleam
/// let model = tui_perf_dev.live(model)
/// ```
pub fn live(model: tui_model.Model) -> tui_model.Model {
  tui_model.Model(
    ..model,
    shared: tui_model.Shared(..model.shared, peer: tui_model.Preview),
  )
}

/// The admission witness for a replay: how many durable records the model
/// retained, and how many transcript lines are failures.
///
/// A replay whose frames were all refused still finishes and still draws, so
/// the driver reports these beside its timing, as `tui_replay_dev` asserts
/// them.
///
/// ## Examples
///
/// ```gleam
/// let #(records, failures) = tui_perf_dev.witness(final)
/// ```
pub fn witness(model: tui_model.Model) -> #(Int, Int) {
  #(
    list.length(model.shared.records),
    list.count(model.shared.transcript, fn(line) {
      line.speaker == transcript_line.Failure
    }),
  )
}

// The driver stores an integer under the key before the model is built, so
// the read always finds one.
@external(erlang, "erlang", "get")
fn dictionary_get(key: Atom) -> Int
