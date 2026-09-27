//// Background jobs are started, cancelled and answered by key.
////
//// A step describes a job and queues `effect.StartJob(key, spec)`; the
//// runtime starts it after the step, keeps its subject and cancel signal
//// in `Model.running`, and admits each reply into the slot that holds the
//// reply's key. These tests check each half where it lives: the step
//// starts nothing and names the key its slot holds, `runtime.hold` admits
//// a reply only under the slot's own key, a cancelled job's replies never
//// reach a slot, a relay's last message is read even after its slot has
//// moved on, and the tick takes the job replies in its fixed order.

import etui/backend
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/attachment
import tui/buffered
import tui/connection
import tui/daemon/protocol as control_protocol
import tui/daemon/selection as daemon_selection
import tui/effect
import tui/interaction
import tui/job
import tui/job_runner
import tui/model as tui_model
import tui/runtime
import tui/session_channel
import tui/session_control
import tui/session_selector
import tui/snapshot
import tui/workspace
import tui_test/pushed
import weft

// A picker key asks for a catalogue page by queuing exactly one job start,
// under the key the control slot now holds, and the step starts nothing:
// the job table is untouched and nothing reaches the control handle.
pub fn a_picker_key_queues_one_job_start_and_starts_nothing_test() {
  let owner: Subject(Dynamic) = process.new_subject()
  let host = host_on(owner)
  let model = tui_model.Model(..blank(), daemon_host: Some(host))

  let #(loading, effects) = tui.step(backend.KeyPress("left"), model)
  let assert Some(tui_model.ControlRequest(job: awaiting, result: None)) =
    loading.control_request
    as "the page load holds the control slot"
  assert list.filter(effects, is_job)
    == [
      effect.StartJob(
        job.key(awaiting),
        job.Control(
          host,
          job.LoadPage(
            control_protocol.ListSessions("", None),
            session_selector.Active,
            model.session,
            "/work",
          ),
        ),
      ),
    ]
  assert job_runner.size(loading.running) == 0
    as "the step starts no job itself"
  assert process.receive(owner, 0) == Error(Nil)
    as "the step sent nothing to daemon control"
}

// A reply tagged with a key the slot does not hold belongs to some other
// job, and is dropped before any reducer sees it.
pub fn a_reply_for_another_key_is_not_admitted_test() {
  let #(model, current) = tui_model.allocate_job(blank())
  let #(model, other) = tui_model.allocate_job(model)
  let waiting =
    tui_model.Model(
      ..model,
      control_request: Some(tui_model.ControlRequest(
        job.awaiting(current),
        Some(Error("still waiting")),
      )),
    )

  let held = runtime.hold(waiting, job.ControlArrived(other, weft.AllDelivered))
  assert held.control_request == waiting.control_request
  let drained = session_control.drain_control(held)
  assert drained.control_request == waiting.control_request
    as "the slot's own job has not finished"
}

// Two jobs started one after the other are given different keys, so a late
// message from the first cannot finish the second. The first page load's
// relay reports its end only after the second load has taken the slot.
pub fn a_late_reply_from_an_earlier_job_does_not_reach_its_successor_test() {
  let owner: Subject(Dynamic) = process.new_subject()
  let model = tui_model.Model(..blank(), daemon_host: Some(host_on(owner)))

  let #(first, _) =
    runtime.take(session_control.load_catalogue(model, "", None))
  let assert Some(tui_model.ControlRequest(job: earlier, ..)) =
    first.control_request
    as "the first load holds the slot"

  // The first load finishes and the second takes the slot.
  let finished =
    runtime.hold(
      first,
      job.ControlArrived(job.key(earlier), weft.RunLost(process.Normal)),
    )
    |> session_control.drain_control
  assert finished.control_request == None
  let #(second, _) =
    runtime.take(session_control.load_catalogue(finished, "", None))
  let assert Some(tui_model.ControlRequest(job: later, ..)) =
    second.control_request
    as "the second load holds the slot"
  assert job.key(later) != job.key(earlier)

  // A duplicate of the first job's end is not the second job's end.
  let late =
    runtime.hold(
      second,
      job.ControlArrived(job.key(earlier), weft.AllDelivered),
    )
    |> session_control.drain_control
  assert late.control_request == second.control_request
}

// A quit cancels the running activity poll by its key and clears the slot
// in the same step. The worker has not answered when the cancel lands, so
// its relay reports it abandoned, or never started when the cancel beat
// the task to its slot, rather than completed, and neither of its
// messages reaches the cleared slot. The relay's last message is read, and
// the job leaves the table.
pub fn a_cancelled_job_never_delivers_a_reply_test() {
  let #(model, key) = tui_model.allocate_job(blank())
  let running =
    job_runner.start_task(
      model.running,
      key,
      fn() {
        process.sleep(300)
        Ok([])
      },
      5000,
      job.ActivityArrived,
    )
  let model =
    tui_model.Model(
      ..model,
      running:,
      activity_poll: tui_model.ActivityAsking(job.awaiting(key), ["a"]),
    )

  let quit = tui.update(backend.KeyPress("ctrl+c"), model)
  assert quit.activity_poll == tui_model.ActivityDue

  let arrivals = until_finished(quit.running, [], 50)
  assert list.any(arrivals, fn(arrival) {
    case arrival {
      job.ActivityArrived(reply: weft.PulledOutcome(weft.Abandoned(..)), ..)
      | job.ActivityArrived(
          reply: weft.PulledOutcome(weft.NeverStarted(..)),
          ..,
        )
      | job.ActivityArrived(
          reply: weft.PulledOutcome(weft.CancellationUnconfirmed(..)),
          ..,
        ) -> True
      _ -> False
    }
  })
    as "the cancel stopped the worker before it answered"
  let settled = list.fold(arrivals, quit, runtime.hold)
  assert job_runner.size(settled.running) == 0
    as "the job leaves the table once its last message is read"
}

// A relaunch's relay sends its outcome and then `AllDelivered`. The outcome
// spends the attempt, so no slot waits for the second message, and before
// jobs were keyed the tick stopped reading the relay's subject at that
// point: the `AllDelivered` stayed in the terminal's mailbox for every later
// selective receive to scan past. The runtime reads every running job to
// its last message whatever its slot holds, so a job whose slot has moved on
// is still read, and the mailbox and the job table end empty.
pub fn a_spent_reconnect_leaves_nothing_in_the_mailbox_test() {
  // The terminal runs in a process of its own, so the mailbox it measures
  // holds only what the terminal was sent.
  let report = process.new_subject()
  process.spawn(fn() { process.send(report, spent_terminal()) })
  let assert Ok(#(spent, queued)) = process.receive(report, 5000)
    as "the terminal process reports back"
  assert spent.reconnect == tui_model.ReconnectSpent
  assert job_runner.size(spent.running) == 0
    as "the job was read to its last message"
  assert queued == 0 as "the relay's messages did not stay in the mailbox"
}

// A terminal whose relaunch has already had its outcome taken, so the slot
// is spent while the relay is still sending, ticked until its job table is
// empty. Returns the model and how many messages its mailbox still holds.
fn spent_terminal() -> #(tui_model.Model, Int) {
  let #(model, key) = tui_model.allocate_job(blank())
  let running =
    job_runner.start_task(
      model.running,
      key,
      fn() { Error("loomd was not found") },
      5000,
      job.ReconnectArrived,
    )
  let model =
    tui_model.Model(
      ..model,
      session: "s",
      peer: tui_model.Disconnected,
      running:,
      reconnect: tui_model.ReconnectSpent,
    )
  let spent = tick_until_idle(model, 50)
  #(spent, probe(process.self()).message_queue_len)
}

// A relaunch's outcome carries the control connection it opened. When the
// slot that waited for it has moved on, as an adoption leaves it after
// cancelling the relaunch, the dropped outcome's connection is still
// closed: `hold` queues the close and the flush performs it.
pub fn a_dropped_relaunch_outcome_closes_its_control_test() {
  let owner: Subject(Dynamic) = process.new_subject()
  let host = host_on(owner)
  let #(model, key) = tui_model.allocate_job(blank())
  let model = tui_model.Model(..model, reconnect: tui_model.ReconnectIdle)

  let held =
    runtime.hold(
      model,
      job.ReconnectArrived(key, weft.PulledOutcome(weft.Completed(0, host))),
    )
  assert held.reconnect == tui_model.ReconnectIdle
  assert held.outbox == [effect.CloseControl(daemon_selection.control(host))]
    as "the dropped outcome's control is queued for closing"
  assert process.receive(owner, 0) == Error(Nil)
    as "holding the outcome closed nothing itself"
  let _ = runtime.flush(held)
  let assert Ok(_) = process.receive(owner, 100)
    as "the flush closed the control"
}

// The tick takes the control reply before the relaunch's, as it always
// has. Both fail here, so each writes one transcript line, and the lines'
// order is the order the drains ran in.
pub fn a_tick_drains_the_jobs_in_their_fixed_order_test() {
  let #(model, control) = tui_model.allocate_job(blank())
  let #(model, relaunch) = tui_model.allocate_job(model)
  let model =
    tui_model.Model(
      ..model,
      transcript: [],
      control_request: Some(tui_model.ControlRequest(
        job.awaiting(control),
        Some(Error("control failed first")),
      )),
      reconnect: tui_model.ReconnectAttempting(job.awaiting(relaunch)),
    )
    |> runtime.hold(job.ControlArrived(control, weft.AllDelivered))
    |> runtime.hold(job.ReconnectArrived(
      relaunch,
      weft.PulledOutcome(weft.Failed(0, "relaunch failed second")),
    ))

  let #(ticked, _) = tui.step(backend.Tick, model)
  let failures =
    list.filter_map(ticked.transcript, fn(line) {
      case line {
        tui_model.Line(speaker: tui_model.Failure, text:) -> Ok(text)
        _ -> Error(Nil)
      }
    })
  let assert [first, second] = failures as "each drain wrote one line"
  assert string.contains(first, "control failed first")
  assert string.contains(second, "relaunch failed second")
}

// --- helpers ---------------------------------------------------------------

fn blank() -> tui_model.Model {
  tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
}

fn is_job(requested: effect.Effect) -> Bool {
  case requested {
    effect.StartJob(..) | effect.CancelJob(_) -> True
    _ -> False
  }
}

// Reads a job table until every job in it has sent its last message, or
// until `attempts` reads twenty milliseconds apart have passed.
fn until_finished(
  running: job_runner.Running,
  received: List(job.Arrival),
  attempts: Int,
) -> List(job.Arrival) {
  let received = list.append(received, job_runner.receive(running))
  let running = list.fold(received, running, job_runner.observed)
  case job_runner.size(running), attempts {
    0, _ | _, 0 -> received
    _, _ -> {
      process.sleep(20)
      until_finished(running, received, attempts - 1)
    }
  }
}

// Ticks through the shipped update until the job table is empty, or until
// `attempts` ticks twenty milliseconds apart have passed.
fn tick_until_idle(model: tui_model.Model, attempts: Int) -> tui_model.Model {
  let model = tui.update(backend.Tick, model)
  case job_runner.size(model.running), attempts {
    0, _ | _, 0 -> model
    _, _ -> {
      process.sleep(20)
      tick_until_idle(model, attempts - 1)
    }
  }
}

pub type Probe {
  Probe(
    memory: Int,
    message_queue_len: Int,
    heap_size: Int,
    binary_bytes: Int,
    binary_count: Int,
  )
}

@external(erlang, "tui_probe_ffi", "probe")
fn probe(pid: Pid) -> Probe

@external(erlang, "effects_test_ffi", "host_on")
fn host_on(owner: Subject(Dynamic)) -> daemon_selection.Host

// An adopted attachment proves the daemon answers, so a relaunch still in
// flight is cancelled by its key in the adoption's own step. Clearing the
// slot alone would leave the relaunch running: it could take the launch lock
// and start a second daemon whose replies nothing reads.
pub fn an_adoption_cancels_a_relaunch_still_in_flight_test() {
  let #(model, key) = tui_model.allocate_job(pushed.attached())
  let model =
    tui_model.Model(
      ..model,
      reconnect: tui_model.ReconnectAttempting(job.awaiting(key)),
    )
  let #(replacement, cut, view) = captured_replacement()
  let adopted =
    interaction.advance_candidate(
      model,
      #(
        attachment.idle(),
        Some(attachment.Adopted(
          replacement,
          cut,
          view,
          buffered.new(connection.new_inbox()),
          workspace.Context("test", None),
          "Session A",
          None,
        )),
        [],
      ),
    )

  assert adopted.reconnect == tui_model.ReconnectIdle
  assert list.contains(adopted.outbox, effect.CancelJob(key))
    as "the relaunch the adoption made unnecessary is cancelled by its key"
}

// A replay lane credited with one validated transfer, which is what an
// attachment hands over when it adopts.
fn captured_replacement() {
  let channel =
    session_channel.replay(snapshot.Expected("A", "epoch", "incarnation"))
  let #(ready, updates) =
    list.fold(
      pushed.transfer(1, "1:1", "recent", 10),
      #(channel, []),
      fn(acc, frame) {
        let #(channel, updates) = session_channel.receive(acc.0, frame, now: 0)
        #(channel, list.append(acc.1, updates))
      },
    )
  let assert Ok(#(cut, view)) =
    list.find_map(updates, fn(update) {
      case update {
        session_channel.Captured(cut, view, _) -> Ok(#(cut, view))
        _ -> Error(Nil)
      }
    })
    as "the replacement's first transfer is a validated cut"
  #(ready, cut, view)
}
