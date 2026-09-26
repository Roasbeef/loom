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
import gleam/option.{type Option, None, Some}
import gleam/string
import tui
import tui/attachment
import tui/buffered
import tui/connection
import tui/inbound
import tui/interaction
import tui/model as tui_model
import tui/runtime
import tui/session_channel
import tui/snapshot
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
  process.send(buffered.sender(model.inbox), connection.NetworkFault("older"))
  let escaped = tui.update(backend.KeyPress("esc"), model)
  assert escaped.pending_submission == None
  assert faults(escaped) == []
    as "Escape cancels before it reduces any queued traffic"

  process.send(buffered.sender(escaped.inbox), connection.NetworkFault("newer"))
  let #(inbox, first) = buffered.receive(escaped.inbox, 0)
  assert first == Ok(connection.NetworkFault("older"))
    as "the held message is older than anything in the mailbox"
  let #(_, second) = buffered.receive(inbox, 0)
  assert second == Ok(connection.NetworkFault("newer"))
}

// A hundred queued messages meet a key that does not drain and then two
// ticks. The key's top-up holds exactly one drain's worth and reduces none
// of it; each tick reduces at most one batch; nothing is lost or reordered.
pub fn escape_holds_one_batch_and_ticks_drain_it_in_order_test() {
  let model = waiting(fresh())
  int.range(from: 0, to: 100, with: Nil, run: fn(_, n) {
    process.send(
      buffered.sender(model.inbox),
      connection.NetworkFault(int.to_string(n)),
    )
  })

  let escaped = tui.update(backend.KeyPress("esc"), model)
  assert buffered.held(escaped.inbox) == tui_model.connection_batch
  assert faults(escaped) == []

  let first = tui.update(backend.Tick, escaped)
  assert buffered.held(first.inbox) == 0
  assert faults(first) == numbered(0, tui_model.connection_batch)

  let second = tui.update(backend.Tick, first)
  assert faults(second) == numbered(0, 100)
}

// The swap in `candidate_outcome` replaces the whole inbox value. Commit
// notices the runtime already received from the old socket leave the model
// with it; the adopted inbox's own held notice is reduced by the drain that
// follows in the same step, and a later tick finds nothing more.
pub fn adoption_leaves_the_old_inbox_buffer_behind_test() {
  let model = pushed.attached()
  process.send(buffered.sender(model.inbox), pushed.notice("main", 11))
  process.send(buffered.sender(model.inbox), pushed.notice("main", 12))
  let model = runtime.receive(model)
  assert buffered.held(model.inbox) == 2
  let before = model.notices

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
  assert buffered.sender(adopted.inbox) == buffered.sender(adopted_inbox)

  let drained = inbound.drain_connection(adopted, tui_model.connection_batch)
  assert drained.notices == before + 1
    as "only the adopted inbox's notice reaches the adopted lane"

  let ticked = tui.update(backend.Tick, drained)
  assert ticked.notices == before + 1
    as "no notice from the replaced inbox is reduced after the swap"
}

// The frames a candidate received after its initial cut are not the
// candidate's to reduce. They stay in its frames inbox, and `attachment.adopt`
// hands that inbox to the model with them still held, so the adopted lane
// reduces them in the adoption's own tick.
pub fn adoption_hands_frames_held_after_capture_to_the_adopted_lane_test() {
  let status =
    attachment.start(
      fn() {
        process.sleep(60_000)
        Error("the test plays the worker")
      },
      120_000,
    )
  let #(prepared, frames, outcomes) = attempt_subjects(status)

  // The worker's part: a prepared socket, one complete transfer and two
  // commit notices after its end.
  let acknowledgement = process.new_subject()
  process.send(
    prepared,
    prepared_message(
      socket_on(process.new_subject()),
      snapshot.Expected("A", "epoch", "incarnation"),
      workspace.Context("test", None),
      "Session A",
      None,
      acknowledgement,
    ),
  )
  list.each(pushed.transfer(1, "1:1", "recent", 10), process.send(frames, _))
  process.send(frames, pushed.notice("main", 11))
  process.send(frames, pushed.notice("main", 12))
  let model = tui_model.Model(..fresh(), candidate: status)
  let before = model.notices

  // One tick creates the candidate and captures its cut; the drain stops
  // there, so both notices stay held and the worker is acknowledged.
  let captured = tui.update(backend.Tick, model)
  assert attachment.busy(captured.candidate)
  assert process.receive(acknowledgement, 0) == Ok(Nil)
  assert captured.notices == before

  process.send(outcomes, weft.AllDelivered)
  let adopted = tui.update(backend.Tick, captured)
  assert !attachment.busy(adopted.candidate)
  assert adopted.session == "A"
  assert adopted.notices == before + 2
    as "both notices held after the capture reach the adopted lane"
  attachment.cancel(status)
}

// A tick settles the provisional attachment before it drains the connection.
// The failing attempt's outcome and a connection fault are received before
// the same step, and the failure is reduced first.
pub fn a_tick_settles_the_candidate_before_it_drains_the_connection_test() {
  let model =
    tui_model.Model(
      ..fresh(),
      candidate: attachment.start(fn() { Error("refused") }, 5000),
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
    buffered.sender(model.inbox),
    connection.NetworkFault(int.to_string(tick)),
  )
  let model = tui.update(backend.Tick, model)
  case attachment.busy(model.candidate), budget {
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
    pending_submission: Some(tui_model.ComposerSubmission),
  )
}

fn failures(model: tui_model.Model) -> List(String) {
  list.filter_map(model.transcript, fn(line) {
    case line {
      tui_model.Line(tui_model.Failure, text) -> Ok(text)
      tui_model.Line(..) -> Error(Nil)
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

@external(erlang, "runtime_receive_test_ffi", "attempt_subjects")
fn attempt_subjects(
  status: attachment.Status,
) -> #(
  Subject(Dynamic),
  Subject(connection.Message),
  Subject(weft.Pulled(Nil, String)),
)

@external(erlang, "runtime_receive_test_ffi", "prepared")
fn prepared_message(
  socket: connection.Connection,
  expected: snapshot.Expected,
  workspace: workspace.Context,
  name: String,
  creation_key: Option(String),
  acknowledgement: Subject(Nil),
) -> Dynamic

@external(erlang, "effects_test_ffi", "socket_on")
fn socket_on(owner: Subject(Dynamic)) -> connection.Connection
