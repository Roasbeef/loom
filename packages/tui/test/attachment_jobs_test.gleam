//// The provisional attachment is a keyed job.
////
//// Opening a session queues `StartJob(key, job.Attach(..))` and starts
//// nothing; the attempt learns its frames inbox only from the `Prepared`
//// the job publishes; the runtime admits the job's messages by key; and
//// whatever `Prepared` the runtime drops, because no attempt waits for its
//// key, has its socket closed and its frames subject emptied, by effects
//// `runtime.hold` queues and the next flush performs. These tests
//// check each of those where it lives. The stand-in socket wraps a subject
//// this process owns, so a close arrives here as a message.

import etui/backend
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import session_view/connection_event
import session_view/snapshot
import tui
import tui/attachment
import tui/connection
import tui/daemon/selection as daemon_selection
import tui/effect
import tui/job
import tui/job_runner
import tui/model as tui_model
import tui/runtime
import tui/session_control
import tui/view_set
import tui/workspace
import tui_test/pushed
import tui_test/stepping
import weft

// Opening a session queues exactly one attachment job under the key the
// attempt holds, and the step creates nothing: no job in the table, no
// frames subject, nothing sent to daemon control.
pub fn opening_a_session_queues_one_attach_job_and_starts_nothing_test() {
  let owner: Subject(Dynamic) = process.new_subject()
  let host = host_on(owner)
  let model = runtime.adopt_control(blank(), host)
  let assert Some(daemon) = model.view.daemon_host

  let #(opening, effects) =
    runtime.take(session_control.begin_open(model, "target"))
  let assert Some(key) = attachment.job_key(opening.view.candidate)
    as "the attempt holds its job's key"
  assert list.filter(effects, is_job)
    == [
      effect.StartJob(
        key,
        job.Attach(job.OpenSession(daemon.control, "target"), 90_000),
      ),
    ]
  assert job_runner.size(opening.view.running) == 0
    as "the step starts no job itself"
  assert process.receive(owner, 0) == Error(Nil)
    as "the step sent nothing to daemon control"
}

// Frames the socket delivers before its `Prepared` is admitted wait in a
// subject the attempt does not know, so no tick can reduce them. Once the
// `Prepared` naming that subject is admitted, the next tick starts the lane
// and captures the cut from those frames, and acknowledges the worker.
pub fn the_frames_inbox_comes_only_from_the_prepared_test() {
  let #(model, key) = tui_model.allocate_job(blank())
  let model =
    tui_model.Model(
      ..model,
      view: view_set.candidate(model.view, attachment.opening(key, None)),
    )
  let frames = connection.new_inbox()
  list.each(pushed.transfer(1, "1:1", "recent", 10), process.send(frames, _))

  let #(waiting, effects) =
    stepping.step(backend.Tick, runtime.receive(runtime.stamp(model)))
  assert attachment.busy(waiting.view.candidate)
  assert list.filter(effects, is_attachment) == []
    as "no tick reduced the frames before the Prepared named them"

  let acknowledgement = process.new_subject()
  let _captured =
    runtime.hold(
      waiting,
      job.AttachArrived(
        key,
        job.Published(prepared_on(
          process.new_subject(),
          frames,
          acknowledgement,
        )),
      ),
    )
    |> fn(model) { tui.update(backend.Tick, model) }
  assert process.receive(acknowledgement, 0) == Ok(Nil)
    as "the tick after the Prepared captured the cut and acknowledged"
}

// A `Prepared` for a key no attempt waits for is dropped by the runtime,
// which closes its socket and empties the frames subject it names: here
// for an attempt that has since been replaced by another key, and for a
// terminal with no attempt at all.
pub fn a_stale_prepared_has_its_socket_closed_test() {
  let #(model, stale) = tui_model.allocate_job(blank())
  let #(model, current) = tui_model.allocate_job(model)
  let waiting =
    tui_model.Model(
      ..model,
      view: view_set.candidate(model.view, attachment.opening(current, None)),
    )

  let owner: Subject(Dynamic) = process.new_subject()
  let frames = connection.new_inbox()
  process.send(frames, connection_event.Connected)
  let held =
    runtime.hold(
      waiting,
      job.AttachArrived(
        stale,
        job.Published(prepared_on(owner, frames, process.new_subject())),
      ),
    )
  assert held.view.candidate == waiting.view.candidate
    as "the stale Prepared reached no attempt"
  assert process.receive(owner, 0) == Error(Nil)
    as "holding the Prepared closed nothing itself"
  let _ = runtime.flush(held)
  let assert Ok(_) = process.receive(owner, 0)
    as "the stale Prepared's socket was closed"
  assert connection.receive(frames) == Error(Nil)
    as "the frames subject it named was emptied"

  let idle_owner: Subject(Dynamic) = process.new_subject()
  let _ =
    runtime.flush(runtime.hold(
      blank(),
      job.AttachArrived(
        stale,
        job.Published(prepared_on(
          idle_owner,
          connection.new_inbox(),
          process.new_subject(),
        )),
      ),
    ))
  let assert Ok(_) = process.receive(idle_owner, 0)
    as "a Prepared with no attempt at all is closed too"
}

// An attempt takes one `Prepared`. A second one under the same key names a
// socket the attempt will never use, so it is dropped and closed as a
// stale one is.
pub fn a_second_prepared_for_the_same_attempt_is_closed_test() {
  let #(model, key) = tui_model.allocate_job(blank())
  let model =
    tui_model.Model(
      ..model,
      view: view_set.candidate(model.view, attachment.opening(key, None)),
    )
    |> runtime.hold(job.AttachArrived(
      key,
      job.Published(prepared_on(
        process.new_subject(),
        connection.new_inbox(),
        process.new_subject(),
      )),
    ))
  let owner: Subject(Dynamic) = process.new_subject()
  let again =
    runtime.hold(
      model,
      job.AttachArrived(
        key,
        job.Published(prepared_on(
          owner,
          connection.new_inbox(),
          process.new_subject(),
        )),
      ),
    )
  assert again.view.candidate == model.view.candidate
  let _ = runtime.flush(again)
  let assert Ok(_) = process.receive(owner, 0)
    as "the second Prepared's socket was closed"
}

// A quit clears the attempt and cancels its job in the same step, so
// nothing that job sends afterwards is delivered: a late outcome changes
// nothing, and a late `Prepared` is closed rather than started.
pub fn an_arrival_for_a_cancelled_attach_key_is_never_delivered_test() {
  let #(model, key) = tui_model.allocate_job(blank())
  let model =
    tui_model.Model(
      ..model,
      view: view_set.candidate(model.view, attachment.opening(key, None)),
    )
  let #(quit, effects) = stepping.step(backend.KeyPress("ctrl+c"), model)
  assert list.contains(effects, effect.CancelJob(key))
  assert !attachment.busy(quit.view.candidate)

  let owner: Subject(Dynamic) = process.new_subject()
  let late =
    quit
    |> runtime.hold(job.AttachArrived(
      key,
      job.Settled(weft.PulledOutcome(weft.Abandoned(0))),
    ))
    |> runtime.hold(job.AttachArrived(
      key,
      job.Published(prepared_on(
        owner,
        connection.new_inbox(),
        process.new_subject(),
      )),
    ))
  assert late.view.candidate == quit.view.candidate
    as "no arrival for the cancelled key reached an attempt"
  let _ = runtime.flush(late)
  let assert Ok(_) = process.receive(owner, 0)
    as "the late Prepared's socket was closed"
}

// A failed attempt cancels its job by key ahead of its own cleanup, so a
// worker still waiting on its acknowledgement is stopped rather than left
// to its deadline.
pub fn a_failed_attempt_cancels_its_job_ahead_of_its_cleanup_test() {
  let #(model, key) = tui_model.allocate_job(blank())
  let model =
    tui_model.Model(
      ..model,
      view: view_set.candidate(model.view, attachment.opening(key, None)),
    )
    |> runtime.hold(job.AttachArrived(
      key,
      job.Settled(weft.PulledOutcome(weft.Failed(0, "refused"))),
    ))
  let #(failed, effects) = stepping.step(backend.Tick, model)
  assert !attachment.busy(failed.view.candidate)
  let lifecycle =
    list.filter_map(effects, fn(decided) {
      case decided {
        effect.CancelJob(cancelled) if cancelled == key -> Ok("cancel job")
        effect.Attachment(attachment.Abandon(_)) -> Ok("abandon")
        _ -> Error(Nil)
      }
    })
  assert lifecycle == ["cancel job", "abandon"]
}

// --- helpers ---------------------------------------------------------------

fn blank() -> tui_model.Model {
  tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
}

fn is_attachment(requested: effect.Effect) -> Bool {
  case requested {
    effect.Attachment(_) -> True
    _ -> False
  }
}

fn is_job(requested: effect.Effect) -> Bool {
  case requested {
    effect.StartJob(..) | effect.CancelJob(_) -> True
    _ -> False
  }
}

// The `Prepared` an attachment worker publishes, for a stand-in socket
// whose close arrives at `owner`.
fn prepared_on(
  owner: Subject(Dynamic),
  frames: Subject(connection_event.Message),
  acknowledgement: Subject(Nil),
) -> job.Prepared {
  job.Prepared(
    socket: socket_on(owner),
    expected: snapshot.Expected("A", "epoch", "incarnation"),
    workspace: workspace.Context("/work", None),
    session_name: "Session A",
    creation_key: None,
    acknowledgement:,
    frames:,
  )
}

@external(erlang, "effects_test_ffi", "socket_on")
fn socket_on(owner: Subject(Dynamic)) -> connection.Connection

@external(erlang, "effects_test_ffi", "host_on")
fn host_on(owner: Subject(Dynamic)) -> daemon_selection.Host
