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
import session_view/attempt
import session_view/model as session_model
import session_view/session_channel
import session_view/shared_set
import session_view/snapshot
import session_view/transcript_line
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
import tui/session_control
import tui/session_selector
import tui/view_set
import tui/workspace
import tui_test/pushed
import tui_test/stepping
import weft

// A picker key asks for a catalogue page by queuing exactly one job start,
// under the key the control slot now holds, and the step starts nothing:
// the job table is untouched and nothing reaches the control handle.
pub fn a_picker_key_queues_one_job_start_and_starts_nothing_test() {
  let owner: Subject(Dynamic) = process.new_subject()
  let host = host_on(owner)
  let model = runtime.adopt_control(blank(), host)
  let assert Some(daemon) = model.view.daemon_host

  let #(loading, effects) = stepping.step(backend.KeyPress("left"), model)
  let assert Some(tui_model.ControlRequest(job: awaiting, result: None)) =
    loading.view.control_request
    as "the page load holds the control slot"
  assert list.filter(effects, is_job)
    == [
      effect.StartJob(
        job.key(awaiting),
        job.Control(
          daemon.control,
          job.LoadPage(
            control_protocol.ListSessions("", None),
            session_selector.Active,
            model.shared.session,
            "/work",
          ),
        ),
      ),
    ]
  assert job_runner.size(loading.view.running) == 0
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
      view: view_set.control_request(
        model.view,
        Some(tui_model.ControlRequest(
          job.awaiting(current),
          Some(Error("still waiting")),
        )),
      ),
    )

  let held = runtime.hold(waiting, job.ControlArrived(other, weft.AllDelivered))
  assert held.view.control_request == waiting.view.control_request
  let drained = session_control.drain_control(held)
  assert drained.view.control_request == waiting.view.control_request
    as "the slot's own job has not finished"
}

// Two jobs started one after the other are given different keys, so a late
// message from the first cannot finish the second. The first page load's
// relay reports its end only after the second load has taken the slot.
pub fn a_late_reply_from_an_earlier_job_does_not_reach_its_successor_test() {
  let owner: Subject(Dynamic) = process.new_subject()
  let model = runtime.adopt_control(blank(), host_on(owner))

  let #(first, _) =
    runtime.take(session_control.load_catalogue(model, "", None))
  let assert Some(tui_model.ControlRequest(job: earlier, ..)) =
    first.view.control_request
    as "the first load holds the slot"

  // The first load finishes and the second takes the slot.
  let finished =
    runtime.hold(
      first,
      job.ControlArrived(job.key(earlier), weft.RunLost(process.Normal)),
    )
    |> session_control.drain_control
  assert finished.view.control_request == None
  let #(second, _) =
    runtime.take(session_control.load_catalogue(finished, "", None))
  let assert Some(tui_model.ControlRequest(job: later, ..)) =
    second.view.control_request
    as "the second load holds the slot"
  assert job.key(later) != job.key(earlier)

  // A duplicate of the first job's end is not the second job's end.
  let late =
    runtime.hold(
      second,
      job.ControlArrived(job.key(earlier), weft.AllDelivered),
    )
    |> session_control.drain_control
  assert late.view.control_request == second.view.control_request
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
      model.view.running,
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
      view: model.view
        |> view_set.running(running)
        |> view_set.activity_poll(
          tui_model.ActivityAsking(job.awaiting(key), ["a"]),
        ),
    )

  let quit = tui.update(backend.KeyPress("ctrl+c"), model)
  assert quit.view.activity_poll == tui_model.ActivityDue

  let arrivals = until_finished(quit.view.running, [], 50)
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
  assert job_runner.size(settled.view.running) == 0
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
  assert spent.view.reconnect == tui_model.ReconnectSpent
  assert job_runner.size(spent.view.running) == 0
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
      model.view.running,
      key,
      fn() { Error("loomd was not found") },
      5000,
      job.ReconnectArrived,
    )
  let model =
    tui_model.Model(
      shared: model.shared
        |> shared_set.session("s")
        |> shared_set.peer(session_model.Disconnected),
      view: model.view
        |> view_set.running(running)
        |> view_set.reconnect(tui_model.ReconnectSpent),
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
  let model =
    tui_model.Model(
      ..model,
      view: view_set.reconnect(model.view, tui_model.ReconnectIdle),
    )

  let held =
    runtime.hold(
      model,
      job.ReconnectArrived(key, weft.PulledOutcome(weft.Completed(0, host))),
    )
  assert held.view.reconnect == tui_model.ReconnectIdle
  let assert [effect.CloseControl(control)] = held.view.outbox
    as "the dropped outcome's control is queued for closing"
  assert job_runner.control(held.view.running, control) == Ok(host)
    as "the queued close names the relaunch's own connection"
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
      shared: shared_set.transcript(model.shared, []),
      view: model.view
        |> view_set.control_request(
          Some(tui_model.ControlRequest(
            job.awaiting(control),
            Some(Error("control failed first")),
          )),
        )
        |> view_set.reconnect(
          tui_model.ReconnectAttempting(job.awaiting(relaunch)),
        ),
    )
    |> runtime.hold(job.ControlArrived(control, weft.AllDelivered))
    |> runtime.hold(job.ReconnectArrived(
      relaunch,
      weft.PulledOutcome(weft.Failed(0, "relaunch failed second")),
    ))

  let #(ticked, _) = stepping.step(backend.Tick, model)
  let failures =
    list.filter_map(ticked.shared.transcript, fn(line) {
      case line {
        transcript_line.Line(speaker: transcript_line.Failure, text:) ->
          Ok(text)
        _ -> Error(Nil)
      }
    })
  let assert [first, second] = failures as "each drain wrote one line"
  assert string.contains(first, "control failed first")
  assert string.contains(second, "relaunch failed second")
}

// The runtime reads every running job's messages in one pass over the
// mailbox, so replies from different jobs come back interleaved in the order
// they arrived rather than grouped by job. Each must still land in the slot
// that names its own job. Three jobs of three kinds have all answered before
// a keypress on a live terminal, whose replay inbox is empty and unread; the
// key admits each outcome into its own slot, reads every relay to its last
// message, and leaves nothing in the mailbox. A runtime that tagged an
// arrival with another job's key would leave a slot empty here.
pub fn a_keypress_admits_every_jobs_reply_into_its_own_slot_test() {
  let report = process.new_subject()
  process.spawn(fn() { process.send(report, answered_keypress()) })
  let assert Ok(#(pressed, queued)) = process.receive(report, 5000)
    as "the terminal process reports back"

  let assert Some(tui_model.ControlRequest(job: control, ..)) =
    pressed.view.control_request
    as "the control slot still waits for the tick to take its reply"
  assert list.any(job.held(control), fn(reply) {
    reply == weft.PulledOutcome(weft.Failed(0, "control down"))
  })
    as "the control job's outcome is in the control slot"

  let assert tui_model.ReconnectAttempting(job: relaunch) =
    pressed.view.reconnect
    as "the relaunch slot still waits for the tick to take its reply"
  assert list.any(job.held(relaunch), fn(reply) {
    reply == weft.PulledOutcome(weft.Failed(0, "relaunch down"))
  })
    as "the relaunch's outcome is in the relaunch slot"

  let assert tui_model.ActivityAsking(job: activity, ..) =
    pressed.view.activity_poll
    as "the activity slot still waits for the tick to take its reply"
  assert list.any(job.held(activity), fn(reply) {
    reply == weft.PulledOutcome(weft.Completed(0, []))
  })
    as "the activity poll's outcome is in the activity slot"

  assert job_runner.size(pressed.view.running) == 0
    as "every relay was read to its last message"
  assert buffered.held(pressed.shared.replay_inbox) == 0
  assert queued == 0 as "nothing the jobs sent stayed in the mailbox"
}

// A live terminal, whose peer is not `Replaying`, never reads its replay
// inbox, so a read that could only come back empty costs no scan of the
// mailbox. A replay reads it on every event, a keypress included, and holds
// the event for the next tick while the running job's reply is admitted
// beside it.
pub fn only_a_replay_reads_its_replay_inbox_test() {
  let report = process.new_subject()
  process.spawn(fn() {
    process.send(report, #(
      replayed_keypress(session_model.Preview),
      probe_self(),
    ))
  })
  let assert Ok(#(#(live, _), live_queue)) = process.receive(report, 5000)
    as "the live terminal process reports back"
  assert buffered.held(live.shared.replay_inbox) == 0
    as "a live terminal leaves its replay inbox unread"
  assert live_queue == 1 as "the unread event is still in the mailbox"

  process.spawn(fn() {
    process.send(report, #(
      replayed_keypress(session_model.Replaying),
      probe_self(),
    ))
  })
  let assert Ok(#(#(replay, applied), replay_queue)) =
    process.receive(report, 5000)
    as "the replaying terminal process reports back"
  assert buffered.held(replay.shared.replay_inbox) == 1
    as "a replay's keypress admits the recorded event"
  let assert Some(tui_model.ControlRequest(job: control, ..)) =
    replay.view.control_request
    as "the control slot still waits for the tick to take its reply"
  assert list.any(job.held(control), fn(reply) {
    reply == weft.PulledOutcome(weft.Failed(0, "control down"))
  })
    as "the job's reply is admitted beside the replay event"
  assert replay_queue == 0
  assert buffered.held(applied.shared.replay_inbox) == 0
    as "the next tick applies the held event"
}

// A terminal with a control job, a relaunch and an activity poll running,
// each of which answers at once, pressed once after all six relay messages
// have arrived. Returns the model and how many messages its mailbox holds.
fn answered_keypress() -> #(tui_model.Model, Int) {
  let #(model, control) = tui_model.allocate_job(blank())
  let #(model, relaunch) = tui_model.allocate_job(model)
  let #(model, activity) = tui_model.allocate_job(model)
  let running =
    model.view.running
    |> job_runner.start_task(
      control,
      fn() { Error("control down") },
      5000,
      job.ControlArrived,
    )
    |> job_runner.start_task(
      relaunch,
      fn() { Error("relaunch down") },
      5000,
      job.ReconnectArrived,
    )
    |> job_runner.start_task(
      activity,
      fn() { Ok([]) },
      5000,
      job.ActivityArrived,
    )
  let model =
    tui_model.Model(
      ..model,
      view: model.view
        |> view_set.running(running)
        |> view_set.control_request(
          Some(tui_model.ControlRequest(job.awaiting(control), None)),
        )
        |> view_set.reconnect(
          tui_model.ReconnectAttempting(job.awaiting(relaunch)),
        )
        |> view_set.activity_poll(
          tui_model.ActivityAsking(job.awaiting(activity), ["a"]),
        ),
    )

  // Each one-task relay sends its outcome and then `AllDelivered`.
  await_queue(6, 250)
  let pressed = tui.update(backend.KeyPress("j"), model)
  #(pressed, probe_self())
}

// A terminal of the given peer with one answered control job and one
// recorded attempt event sent to its replay inbox, pressed once and then
// ticked once. Returns the model after the keypress and after the tick.
fn replayed_keypress(
  peer: session_model.Peer,
) -> #(tui_model.Model, tui_model.Model) {
  let #(model, control) = tui_model.allocate_job(blank())
  let running =
    job_runner.start_task(
      model.view.running,
      control,
      fn() { Error("control down") },
      5000,
      job.ControlArrived,
    )
  let model =
    tui_model.Model(
      shared: shared_set.peer(model.shared, peer),
      view: model.view
        |> view_set.running(running)
        |> view_set.control_request(
          Some(tui_model.ControlRequest(job.awaiting(control), None)),
        ),
    )
  process.send(
    buffered.sender(model.shared.replay_inbox),
    attempt.Adopted(attempt.Id(1)),
  )

  // The relay's two messages and the recorded event.
  await_queue(3, 250)
  let pressed = tui.update(backend.KeyPress("j"), model)
  #(pressed, tui.update(backend.Tick, pressed))
}

// Waits, a few milliseconds at a time, until this process's mailbox holds
// at least `count` messages or `attempts` waits have passed.
fn await_queue(count: Int, attempts: Int) -> Nil {
  case probe_self() >= count || attempts == 0 {
    True -> Nil
    False -> {
      process.sleep(4)
      await_queue(count, attempts - 1)
    }
  }
}

fn probe_self() -> Int {
  probe(process.self()).message_queue_len
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
  received: List(job.Arrival(daemon_selection.Host)),
  attempts: Int,
) -> List(job.Arrival(daemon_selection.Host)) {
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
  case job_runner.size(model.view.running), attempts {
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
      view: view_set.reconnect(
        model.view,
        tui_model.ReconnectAttempting(job.awaiting(key)),
      ),
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

  assert adopted.view.reconnect == tui_model.ReconnectIdle
  assert list.contains(adopted.view.outbox, effect.CancelJob(key))
    as "the relaunch the adoption made unnecessary is cancelled by its key"
}

// A relaunch that completed in the same tick an adoption lands has its
// outcome admitted into the slot before the candidate is polled, and the
// adoption then clears the slot. The outcome's control connection is
// released with the slot rather than left open: the adoption queues its
// close ahead of the relaunch's cancel.
pub fn an_adoption_releases_a_relaunch_outcome_it_clears_test() {
  let owner: Subject(Dynamic) = process.new_subject()
  let host = host_on(owner)
  let #(model, key) = tui_model.allocate_job(pushed.attached())
  let model =
    tui_model.Model(
      ..model,
      view: view_set.reconnect(
        model.view,
        tui_model.ReconnectAttempting(job.awaiting(key)),
      ),
    )
    |> runtime.hold(job.ReconnectArrived(
      key,
      weft.PulledOutcome(weft.Completed(0, host)),
    ))
  let assert tui_model.ReconnectAttempting(held) = model.view.reconnect
    as "premise: the outcome is admitted and not yet taken"
  assert job.held(held) != []
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

  assert adopted.view.reconnect == tui_model.ReconnectIdle
  let lifecycle =
    list.filter_map(list.reverse(adopted.view.outbox), fn(decided) {
      case decided {
        effect.CloseControl(_) -> Ok("close control")
        effect.CancelJob(cancelled) if cancelled == key -> Ok("cancel relaunch")
        _ -> Error(Nil)
      }
    })
  assert lifecycle == ["close control", "cancel relaunch"]
    as "the cleared slot's outcome is released ahead of the cancel"
  assert list.any(adopted.view.outbox, fn(decided) {
    case decided {
      effect.CloseControl(control) ->
        job_runner.control(adopted.view.running, control) == Ok(host)
      _ -> False
    }
  })
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
