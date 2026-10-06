//// How long the terminal's loop sleeps between ticks when traffic wakes it.
////
//// A session socket wakes the loop after it files a frame
//// (`connection.connect_waking`), so the poll timeout no longer has to be
//// short to notice traffic. What it still has to do is wake the loop for
//// everything a socket wake does not announce: the lane's own deadline or
//// refresh, a reply to a request just sent, something drawn that moves with
//// time, a job's reply, and frames already received but not yet reduced.
//// These tests pin each of those, and that an idle terminal with nothing
//// due sleeps until its lane is due, capped at the idle ceiling.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import session_view/connection_event
import session_view/model as session_model
import session_view/msg
import session_view/protocol
import session_view/session_channel
import session_view/shared_set
import session_view/snapshot
import tui
import tui/buffered
import tui/connection
import tui/inbound
import tui/job
import tui/job_runner
import tui/model as tui_model
import tui/pacing
import tui/tick
import tui/view_set
import tui/workspace
import tui_test/pushed

// A replay lane that completed its first capture at reading zero, having
// heard a push first when `pushed_first` names one.
fn lane(pushed_first: List(connection_event.Message)) {
  let channel =
    session_channel.replay(snapshot.Expected("A", "epoch", "incarnation"))
  list.fold(
    list.append(pushed_first, pushed.transfer(1, "1:1", "recent", 10)),
    channel,
    fn(channel, frame) { session_channel.receive(channel, frame, now: 0).0 },
  )
}

// A quiet attached model at transport reading `now`, holding `channel`. The
// design preview's strands are running, so a quiet model lists none.
fn attached(channel, now: Int) -> tui_model.Model {
  {
    let base = unattached()
    tui_model.Model(
      ..base,
      shared: base.shared
        |> shared_set.channel(Some(channel))
        |> shared_set.stamp(msg.Stamp(now_ms: 0, transport_ms: now)),
    )
  }
}

fn unattached() -> tui_model.Model {
  {
    let base =
      tui.new_model(connection.new_inbox(), workspace.Context("test", None))
    tui_model.Model(..base, shared: shared_set.strands(base.shared, []))
  }
}

// With nothing moving, the loop sleeps exactly until the lane is due: a
// polling lane's refresh a quarter second after its capture, measured from
// the step's reading, and never a negative wait once it is overdue.
pub fn an_idle_terminal_sleeps_until_its_lane_is_due_test() {
  let polling = lane([])
  assert session_channel.next_due(polling) == Some(250)
  assert !tick.wakes_itself(attached(polling, 0))
  assert tick.terminal_poll_timeout(attached(polling, 0)) == 250
  assert tick.terminal_poll_timeout(attached(polling, 200)) == 50
  assert tick.terminal_poll_timeout(attached(polling, 900)) == 0
}

// A lane that has heard a push refreshes `pushing_refresh_ms` out, and the loop
// still wakes at the idle ceiling, which bounds how late it notices a
// resized window. A terminal with no lane sleeps to the ceiling too.
pub fn a_pushing_lane_sleeps_to_the_idle_ceiling_test() {
  let pushing = lane([pushed.delta("main", "o", "x")])
  assert session_channel.next_due(pushing)
    == Some(session_channel.pushing_refresh_ms)
  assert tick.terminal_poll_timeout(attached(pushing, 0))
    == tick.idle_poll_ceiling_ms

  assert tick.terminal_poll_timeout(unattached()) == tick.idle_poll_ceiling_ms
}

// A request in flight keeps the old short wait. Its reply usually follows
// the wake that let the loop send it by less than the wake interval, so the
// socket holds that reply's wake to the interval's end; the poll takes the
// reply sooner.
pub fn a_request_in_flight_polls_at_eight_milliseconds_test() {
  let #(capturing, _) = session_channel.tick(lane([]), now: 250)
  assert session_channel.in_flight(capturing)
  assert tick.terminal_poll_timeout(attached(capturing, 250)) == 8
}

// Each thing that moves with time or waits on a message no wake announces
// keeps the paced poll, capped by the lane's own due reading.
pub fn what_no_wake_announces_keeps_the_paced_poll_test() {
  let quiet = attached(lane([pushed.delta("main", "o", "x")]), 0)
  // The quiet paced poll is 400 ms, and what wakes itself keeps the 250 ms
  // cap the loop had before wakes, so its animation keeps its cadence.
  let paced =
    int.min(
      pacing.paced_poll_timeout(pacing.FrameSettled, quiet.view.quiet_for_ms),
      tick.self_wake_ceiling_ms,
    )
  assert paced == 250

  // A running strand: the activity glyph and the strip clocks advance on
  // ticks.
  let running =
    tui_model.Model(
      ..quiet,
      shared: shared_set.strands(quiet.shared, [
        protocol.Strand("side", None, Some("assistant")),
      ]),
    )
  assert tick.wakes_itself(running)
  assert tick.terminal_poll_timeout(running) == paced

  // A deferred frame is painted by the tick after its burst.
  let deferred =
    tui_model.Model(
      ..quiet,
      view: view_set.frame_debt(quiet.view, pacing.FrameDeferred),
    )
  assert tick.wakes_itself(deferred)
  assert tick.terminal_poll_timeout(deferred) == 8

  // A drain that stopped at its batch may have left frames whose wakes were
  // spent on earlier ticks, so the next batch is taken without waiting.
  let backlogged =
    tui_model.Model(
      ..quiet,
      shared: shared_set.connection_backlog(
        quiet.shared,
        session_model.MailboxMayHoldMore,
      ),
    )
  assert tick.wakes_itself(backlogged)
  assert tick.terminal_poll_timeout(backlogged) == 0

  // A running job answers on its own subjects, which wake nothing.
  let #(allocated, key) = tui_model.allocate_job(quiet)
  let running_job =
    tui_model.Model(
      ..allocated,
      view: view_set.running(
        allocated.view,
        job_runner.start_task(
          allocated.view.running,
          key,
          fn() {
            process.sleep(200)
            Ok([])
          },
          5000,
          job.ActivityArrived,
        ),
      ),
    )
  assert tick.wakes_itself(running_job)
  assert tick.terminal_poll_timeout(running_job) == paced

  // Frames the buffer still holds, as after an Escape that cancelled first.
  let inbox = buffered.new(process.new_subject())
  process.send(buffered.sender(inbox), connection_event.Connected)
  let held =
    tui_model.Model(
      ..quiet,
      shared: shared_set.inbox(quiet.shared, buffered.top_up(inbox, up_to: 64)),
    )
  assert tick.wakes_itself(held)
  assert tick.terminal_poll_timeout(held) == paced
}

// A drain records whether it stopped at its batch: a full batch may have
// left frames in the mailbox, and a short one read everything there was.
pub fn a_drain_records_whether_it_stopped_at_its_batch_test() {
  let model = attached(lane([]), 0)
  let sender = buffered.sender(model.shared.inbox)
  list.each(list.repeat(Nil, 70), fn(_) {
    process.send(sender, connection_event.NetworkFault("x"))
  })
  let full = drain(model)
  assert full.shared.connection_backlog == session_model.MailboxMayHoldMore
  let rest = drain(full)
  assert rest.shared.connection_backlog == session_model.MailboxDrained
}

// One step's receive and drain of the connection, as a tick runs them.
fn drain(model: tui_model.Model) -> tui_model.Model {
  let topped =
    tui_model.Model(
      ..model,
      shared: shared_set.inbox(
        model.shared,
        buffered.top_up(model.shared.inbox, up_to: tui_model.connection_batch),
      ),
    )
  inbound.drain_connection(topped, tui_model.connection_batch)
}

// An adoption swaps in the candidate's inbox, whose mailbox may still hold
// frames the candidate stopped reading at its capture; their wakes went to
// ticks that could not read them, so the adopting tick owes one more batch.
pub fn an_adopting_tick_owes_one_more_batch_test() {
  let before = attached(lane([]), 0)
  assert tick.adopted_backlog(before, before) == session_model.MailboxDrained
  let adopted =
    tui_model.Model(
      ..before,
      shared: shared_set.inbox(
        before.shared,
        buffered.new(connection.new_inbox()),
      ),
    )
  assert tick.adopted_backlog(before, adopted)
    == session_model.MailboxMayHoldMore
  assert tick.terminal_poll_timeout(
      tui_model.Model(
        ..adopted,
        shared: shared_set.connection_backlog(
          adopted.shared,
          tick.adopted_backlog(before, adopted),
        ),
      ),
    )
    == 0
}
