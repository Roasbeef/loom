//// The runtime receives the step's traffic; the step reads only what it
//// received.
////
//// `tui.update` tops up the model's inboxes before the step, each to the
//// most the step can take from it, and the reducers take from those
//// buffers instead of reading a mailbox. These tests pin the properties
//// that design exists for. The buffer is bounded. An adoption drops the old
//// inbox's buffer together with the inbox, so nothing the old socket sent
//// reaches the adopted lane. A reader outside the step gets the held
//// messages before anything still in the mailbox. And moving the reads
//// before the step keeps the orderings the step already had: Escape acts
//// before any traffic is reduced, and a tick settles the candidate before it
//// drains the connection.

import etui/backend
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/connection_event
import session_view/model as session_model
import session_view/session_channel
import session_view/shared_set
import session_view/snapshot
import session_view/transcript_line
import tui
import tui/attachment
import tui/buffered
import tui/connection
import tui/inbound
import tui/interaction
import tui/job
import tui/job_runner
import tui/model as tui_model
import tui/msg
import tui/runtime
import tui/tick
import tui/view_set
import tui/workspace
import tui_test/pushed
import weft

pub fn a_top_up_holds_at_most_its_bound_in_arrival_order_test() {
  let inbox = buffered.new(process.new_subject())
  list.each([1, 2, 3, 4, 5], process.send(buffered.sender(inbox), _))

  // Two top-ups to the same bound read nothing the second time, because the
  // inbox already holds what one step can take.
  let inbox = buffered.top_up(inbox, up_to: 3)
  assert buffered.held(inbox) == 3
  let inbox = buffered.top_up(inbox, up_to: 3)
  assert buffered.held(inbox) == 3

  let #(inbox, first) = buffered.take(inbox)
  let #(inbox, second) = buffered.take(inbox)
  assert [first, second] == [Ok(1), Ok(2)]

  // A top-up appends behind what is still held.
  let inbox = buffered.top_up(inbox, up_to: 3)
  let #(inbox, third) = buffered.take(inbox)
  let #(inbox, fourth) = buffered.take(inbox)
  let #(inbox, fifth) = buffered.take(inbox)
  assert [third, fourth, fifth] == [Ok(3), Ok(4), Ok(5)]
  assert buffered.take(inbox).1 == Error(Nil)
}

// The runtime received an older message before a step that did not drain
// it, because Escape cancels the waiting command before any traffic is
// reduced. A driver that then waits on the inbox must be handed that older
// message before the newer one still in the mailbox.
pub fn a_reader_outside_the_step_gets_held_traffic_first_test() {
  let model = waiting(fresh())
  process.send(
    buffered.sender(model.shared.inbox),
    connection_event.NetworkFault("older"),
  )
  let escaped = tui.update(backend.KeyPress("esc"), model)
  assert escaped.shared.pending_submission == None
  assert faults(escaped) == []
    as "Escape cancels before it reduces any queued traffic"

  process.send(
    buffered.sender(escaped.shared.inbox),
    connection_event.NetworkFault("newer"),
  )
  let #(inbox, first) = buffered.receive(escaped.shared.inbox, 0)
  assert first == Ok(connection_event.NetworkFault("older"))
    as "the held message is older than anything in the mailbox"
  let #(_, second) = buffered.receive(inbox, 0)
  assert second == Ok(connection_event.NetworkFault("newer"))
}

// A hundred queued messages meet a key that does not drain and then two
// ticks. The key's top-up holds exactly one drain's worth and reduces none
// of it; each tick reduces at most one batch; nothing is lost or reordered.
pub fn escape_holds_one_batch_and_ticks_drain_it_in_order_test() {
  let model = waiting(fresh())
  int.range(from: 0, to: 100, with: Nil, run: fn(_, n) {
    process.send(
      buffered.sender(model.shared.inbox),
      connection_event.NetworkFault(int.to_string(n)),
    )
  })

  let escaped = tui.update(backend.KeyPress("esc"), model)
  assert buffered.held(escaped.shared.inbox) == tui_model.connection_batch
  assert faults(escaped) == []

  let first = tui.update(backend.Tick, escaped)
  assert buffered.held(first.shared.inbox) == 0
  assert faults(first) == numbered(0, tui_model.connection_batch)

  let second = tui.update(backend.Tick, first)
  assert faults(second) == numbered(0, 100)
}

// ADR-010 under event-driven delivery. A socket wakes the loop after it files
// a frame, and etui hands the wake over as a tick. Queued behind an Escape,
// the wake is a separate event: the Escape's step cancels the waiting
// command before any traffic is reduced and holds what it received, and the
// wake's tick then reduces the held frames in the order they arrived. etui
// may instead end the Escape's input burst on the wake and not deliver it;
// the held frames then keep the loop on its short poll rather than the idle
// ceiling, so the tick that drains them still comes.
pub fn a_wake_behind_an_escape_reduces_traffic_only_after_the_cancel_test() {
  let model = waiting(fresh())
  list.each(["0", "1", "2"], fn(label) {
    process.send(
      buffered.sender(model.shared.inbox),
      connection_event.NetworkFault(label),
    )
  })

  let escaped = tui.update(backend.KeyPress("esc"), model)
  assert escaped.shared.pending_submission == None
    as "the Escape cancelled the waiting command"
  assert faults(escaped) == [] as "no traffic was reduced before the cancel"
  assert buffered.held(escaped.shared.inbox) == 3
  assert tick.terminal_poll_timeout(escaped) < tick.idle_poll_ceiling_ms
    as "held frames keep the loop polling even if the wake is swallowed"

  let woken = tui.update(backend.Tick, escaped)
  assert faults(woken) == ["0", "1", "2"]
  assert buffered.held(woken.shared.inbox) == 0
}

// The swap in `candidate_outcome` replaces the whole inbox value. Commit
// notices the runtime already received from the old socket leave the model
// with it; the adopted inbox's own held notice is reduced by the drain that
// follows in the same step, and a later tick finds nothing more.
pub fn adoption_leaves_the_old_inbox_buffer_behind_test() {
  let model = pushed.attached()
  process.send(buffered.sender(model.shared.inbox), pushed.notice("main", 11))
  process.send(buffered.sender(model.shared.inbox), pushed.notice("main", 12))
  let model = runtime.receive(model)
  assert buffered.held(model.shared.inbox) == 2
  let before = model.shared.notices

  let #(replacement, cut, view) = captured_replacement()
  let adopted_inbox = buffered.new(connection.new_inbox())
  process.send(buffered.sender(adopted_inbox), pushed.notice("main", 13))
  let adopted_inbox = buffered.top_up(adopted_inbox, up_to: 40)

  let adopted =
    interaction.advance_candidate(
      model,
      #(
        attachment.idle(),
        Some(attachment.Adopted(
          replacement,
          cut,
          view,
          adopted_inbox,
          workspace.Context("test", None),
          "Session A",
          None,
        )),
        [],
      ),
    )
  assert buffered.sender(adopted.shared.inbox) == buffered.sender(adopted_inbox)

  let drained = inbound.drain_connection(adopted, tui_model.connection_batch)
  assert drained.shared.notices == before + 1
    as "only the adopted inbox's notice reaches the adopted lane"

  let ticked = tui.update(backend.Tick, drained)
  assert ticked.shared.notices == before + 1
    as "no notice from the replaced inbox is reduced after the swap"

  // The host reads the adopted inbox's subject from then on, never the
  // replaced one's: a notice the old socket sends after the swap is not
  // read, and one delivered as if it had been is not filed.
  let replaced = buffered.sender(model.shared.inbox)
  process.send(replaced, pushed.notice("main", 14))
  assert list.all(runtime.arrivals(ticked), fn(arrival) {
    case arrival {
      msg.Frame(source:, ..) -> source == buffered.sender(ticked.shared.inbox)
      msg.Replayed(..) | msg.JobReplied(..) -> True
    }
  })
    as "the host reads only the adopted inbox's subject"
  let #(stale, _) =
    tui.step(
      msg.Arrived([msg.Frame(replaced, pushed.notice("main", 15))]),
      ticked,
    )
  assert buffered.held(stale.shared.inbox) == buffered.held(ticked.shared.inbox)
  let after = tui.update(backend.Tick, stale)
  assert after.shared.notices == before + 1
    as "no notice from the replaced socket is reduced, however it arrives"
}

// The frames a candidate received after its initial cut are not the
// candidate's to reduce. They stay in its frames inbox, and `attachment.adopt`
// hands that inbox to the model with them still held, so the adopted lane
// reduces them in the adoption's own tick.
pub fn adoption_hands_frames_held_after_capture_to_the_adopted_lane_test() {
  let #(model, key) = tui_model.allocate_job(fresh())

  // The worker's part: a published socket naming the frames subject, one
  // complete transfer and two commit notices after its end.
  let frames = connection.new_inbox()
  let acknowledgement = process.new_subject()
  list.each(pushed.transfer(1, "1:1", "recent", 10), process.send(frames, _))
  process.send(frames, pushed.notice("main", 11))
  process.send(frames, pushed.notice("main", 12))
  let model =
    tui_model.Model(
      ..model,
      view: view_set.candidate(model.view, attachment.opening(key, None)),
    )
    |> runtime.hold(job.AttachArrived(
      key,
      job.Published(prepared(frames, acknowledgement)),
    ))
  let before = model.shared.notices

  // One tick creates the candidate and captures its cut; the drain stops
  // there, so both notices stay held and the worker is acknowledged.
  let captured = tui.update(backend.Tick, model)
  assert attachment.busy(captured.view.candidate)
  assert process.receive(acknowledgement, 0) == Ok(Nil)
  assert captured.shared.notices == before

  let captured =
    runtime.hold(
      captured,
      job.AttachArrived(key, job.Settled(weft.AllDelivered)),
    )
  let adopted = tui.update(backend.Tick, captured)
  assert !attachment.busy(adopted.view.candidate)
  assert adopted.shared.session == "A"
  assert adopted.shared.notices == before + 2
    as "both notices held after the capture reach the adopted lane"
}

// A tick settles the provisional attachment before it drains the connection.
// The failing attempt's outcome and a connection fault are received before
// the same step, and the failure is reduced first.
pub fn a_tick_settles_the_candidate_before_it_drains_the_connection_test() {
  let #(model, key) = tui_model.allocate_job(fresh())
  let model =
    tui_model.Model(
      ..model,
      view: model.view
        |> view_set.running(job_runner.start_attach(
          model.view.running,
          key,
          fn() { Error("refused") },
          5000,
        ))
        |> view_set.candidate(attachment.opening(key, None)),
    )
  let settled = tick_until_settled(model, 0, 400)
  let lines = failures(settled)
  let assert Ok(failed_at) = index_of(lines, "open session: refused")
    as "the failing attempt is reported"
  let assert Ok(last) = list.last(faults(settled))
    as "every tick drained its fault"
  let assert Ok(drained_at) = index_of(lines, "network: " <> last)
    as "the settling tick drained its own fault"
  assert failed_at < drained_at
    as "the candidate is settled before the connection is drained"
}

fn tick_until_settled(
  model: tui_model.Model,
  tick: Int,
  budget: Int,
) -> tui_model.Model {
  process.send(
    buffered.sender(model.shared.inbox),
    connection_event.NetworkFault(int.to_string(tick)),
  )
  let model = tui.update(backend.Tick, model)
  case attachment.busy(model.view.candidate), budget {
    False, _ -> model
    True, 0 -> panic as "the failing attempt settled within its budget"
    True, _ -> {
      process.sleep(5)
      tick_until_settled(model, tick + 1, budget - 1)
    }
  }
}

fn fresh() -> tui_model.Model {
  tui.new_model(connection.new_inbox(), workspace.Context("test", None))
}

// A composer submission is waiting on the lane, which is the state in which
// Escape cancels without draining.
fn waiting(model: tui_model.Model) -> tui_model.Model {
  tui_model.Model(
    ..model,
    shared: shared_set.pending_submission(
      model.shared,
      Some(session_model.ComposerSubmission),
    ),
  )
}

fn failures(model: tui_model.Model) -> List(String) {
  list.filter_map(model.shared.transcript, fn(line) {
    case line {
      transcript_line.Line(transcript_line.Failure, text) -> Ok(text)
      transcript_line.Line(..) -> Error(Nil)
    }
  })
}

// The fault labels a model has reduced, in the order it reduced them.
fn faults(model: tui_model.Model) -> List(String) {
  list.filter_map(failures(model), fn(text) {
    case string.split_once(text, "network: ") {
      Ok(#("", label)) -> Ok(label)
      Ok(_) | Error(Nil) -> Error(Nil)
    }
  })
}

fn numbered(from: Int, to: Int) -> List(String) {
  int.range(from:, to:, with: [], run: fn(labels, n) {
    [int.to_string(n), ..labels]
  })
  |> list.reverse
}

fn index_of(lines: List(String), wanted: String) -> Result(Int, Nil) {
  list.index_fold(lines, Error(Nil), fn(found, line, index) {
    case found, line == wanted {
      Ok(_), _ -> found
      Error(Nil), True -> Ok(index)
      Error(Nil), False -> found
    }
  })
}

// A second socketless lane for the same session with its initial cut
// captured, which is what `attachment.adopt` hands to the swap.
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

// The `Prepared` an attachment worker publishes, for a stand-in socket.
fn prepared(
  frames: Subject(connection_event.Message),
  acknowledgement: Subject(Nil),
) -> job.Prepared {
  job.Prepared(
    socket: socket_on(process.new_subject()),
    expected: snapshot.Expected("A", "epoch", "incarnation"),
    workspace: workspace.Context("test", None),
    session_name: "Session A",
    creation_key: None,
    acknowledgement:,
    frames:,
  )
}

@external(erlang, "effects_test_ffi", "socket_on")
fn socket_on(owner: Subject(Dynamic)) -> connection.Connection
