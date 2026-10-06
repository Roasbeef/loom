//// Traffic reaches the step as `msg.Arrived`, which files it and reduces
//// nothing (phase 3 of issue #530).
////
//// Phase 2 filled the model's buffers before the step (`runtime.receive`),
//// and the reducers drained them at a tick or a key. Phase 3 keeps that
//// split and names its first half: the host reads each mailbox up to the
//// room its buffer has, and the step's admission files what was read. These
//// tests pin what that must preserve. An arrival reduces nothing and
//// returns no effect, so a tick still does the reducing. A frame from a
//// replaced socket is not filed. Admission never drops a frame for
//// capacity; the host keeps the bound by reading no more than there is room
//// for. And a generated run of frames, keys, submissions and ticks reduces
//// exactly as it did when the host filled the buffers itself.

import etui/backend
import etui/widgets/textarea
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import session_view/connection_event
import session_view/shared_set
import session_view/transcript_line
import tui
import tui/buffered
import tui/connection
import tui/model as tui_model
import tui/msg
import tui/runtime
import tui/workspace
import tui_test/pushed
import tui_test/stepping

// An arrival is filed behind what the inbox holds, and nothing else moves:
// no line, no notice, no frame, no effect. The tick that follows reduces it.
pub fn an_arrival_is_filed_and_not_reduced_test() {
  let model = fresh()
  let source = buffered.sender(model.shared.inbox)
  let #(admitted, effects) =
    tui.step(
      msg.Arrived([msg.Frame(source, connection_event.NetworkFault("held"))]),
      model,
    )

  assert effects == []
  assert buffered.held(admitted.shared.inbox) == 1
  assert admitted.shared.transcript == model.shared.transcript
  assert admitted.shared.notice == model.shared.notice
  assert admitted.shared.render_revision == model.shared.render_revision
  assert admitted.shared.frame_revision == model.shared.frame_revision
  assert admitted.view.outbox == model.view.outbox

  let #(ticked, _) = stepping.step(backend.Tick, admitted)
  assert list.contains(failures(ticked), "network: held")
    as "the tick reduces what the arrival filed"
}

// A frame whose source is neither the adopted inbox nor a waiting attempt's
// belongs to a socket the model no longer reads, and is not filed.
pub fn a_frame_from_a_replaced_inbox_is_not_filed_test() {
  let model = fresh()
  let replaced = connection.new_inbox()
  let #(admitted, effects) =
    tui.step(
      msg.Arrived([msg.Frame(replaced, connection_event.NetworkFault("stale"))]),
      model,
    )

  assert effects == []
  assert admitted == model
}

// Admission appends whatever it is given; dropping a frame would be a gap
// in the lane's sequence. The bound is the host's to keep.
pub fn admission_never_drops_a_frame_for_capacity_test() {
  let model = fresh()
  let source = buffered.sender(model.shared.inbox)
  let beyond = tui_model.connection_batch + 6
  let frames =
    int.range(from: 0, to: beyond, with: [], run: fn(acc, n) {
      [
        msg.Frame(source, connection_event.NetworkFault(int.to_string(n))),
        ..acc
      ]
    })
    |> list.reverse
  let #(admitted, _) = tui.step(msg.Arrived(frames), model)

  assert buffered.held(admitted.shared.inbox) == beyond
}

// The host reads each mailbox up to the room its buffer has left and no
// further. What it leaves waits in the mailbox, in order, for the next
// event.
pub fn the_host_reads_no_more_than_each_buffer_has_room_for_test() {
  let model = fresh()
  let inbox = buffered.sender(model.shared.inbox)
  int.range(from: 0, to: 100, with: Nil, run: fn(_, n) {
    process.send(inbox, connection_event.NetworkFault(int.to_string(n)))
  })
  let already = 10
  let model =
    tui_model.Model(
      ..model,
      shared: shared_set.inbox(
        model.shared,
        int.range(
          from: 0,
          to: already,
          with: model.shared.inbox,
          run: fn(held, n) {
            buffered.push(
              held,
              connection_event.NetworkFault("held " <> int.to_string(n)),
            )
          },
        ),
      ),
    )

  let arrived = runtime.arrivals(model)
  let from_connection =
    list.filter(arrived, fn(arrival) {
      case arrival {
        msg.Frame(source:, ..) -> source == inbox
        msg.Replayed(..) | msg.JobReplied(..) -> False
      }
    })
  assert list.length(from_connection) == tui_model.connection_batch - already
  assert list.first(from_connection)
    == Ok(msg.Frame(inbox, connection_event.NetworkFault("0")))
    as "the oldest waiting message is read first"
  let assert Ok(next) = process.receive(inbox, 0)
    as "what the host did not read waits in the mailbox"
  assert next
    == connection_event.NetworkFault(int.to_string(
      tui_model.connection_batch - already,
    ))

  // A full buffer has no room and reads nothing.
  let full =
    tui_model.Model(
      ..model,
      shared: shared_set.inbox(
        model.shared,
        buffered.top_up(model.shared.inbox, up_to: tui_model.connection_batch),
      ),
    )
  assert list.filter(runtime.arrivals(full), fn(arrival) {
      case arrival {
        msg.Frame(source:, ..) -> source == inbox
        msg.Replayed(..) | msg.JobReplied(..) -> False
      }
    })
    == []
}

// A generated run of frames, key presses, submissions, Escapes and ticks
// reduces the same way whether the host files the buffers through
// admission or tops them up directly, as phase 2 did. Twenty seeds of
// thirty operations each drive two identical models side by side.
pub fn generated_runs_reduce_as_they_did_before_admission_test() {
  int.range(from: 1, to: 21, with: Nil, run: fn(_, seed) {
    let reference = pushed.attached()
    let admitted = pushed.attached()
    let #(reference, admitted) =
      list.fold(operations(seed, 30), #(reference, admitted), fn(pair, op) {
        let #(reference, admitted) = pair
        list.each(op.frames, fn(frame) {
          process.send(buffered.sender(reference.shared.inbox), frame)
          process.send(buffered.sender(admitted.shared.inbox), frame)
        })
        let #(reference, _) =
          stepping.step(op.event, phase_two_receive(reference))
        let #(admitted, _) = stepping.step(op.event, runtime.receive(admitted))
        #(reference, admitted)
      })

    assert admitted.shared.transcript == reference.shared.transcript
    assert admitted.shared.notices == reference.shared.notices
    assert admitted.shared.notice == reference.shared.notice
    assert admitted.shared.pending_submission
      == reference.shared.pending_submission
    assert textarea.value(admitted.view.input)
      == textarea.value(reference.view.input)
    assert buffered.held(admitted.shared.inbox)
      == buffered.held(reference.shared.inbox)
  })
}

// Phase 2's receive, for the traffic these runs carry: the connection and
// replay inboxes topped up to their bounds.
fn phase_two_receive(model: tui_model.Model) -> tui_model.Model {
  tui_model.Model(
    ..model,
    shared: model.shared
      |> shared_set.inbox(buffered.top_up(
        model.shared.inbox,
        up_to: tui_model.connection_batch,
      ))
      |> shared_set.replay_inbox(buffered.top_up(
        model.shared.replay_inbox,
        up_to: 1,
      )),
  )
}

type Operation {
  Operation(frames: List(connection_event.Message), event: backend.InputEvent)
}

// A small linear congruential generator, so a failing seed replays exactly.
fn operations(seed: Int, count: Int) -> List(Operation) {
  let #(_, ops) =
    int.range(from: 0, to: count, with: #(seed, []), run: fn(acc, _) {
      let #(state, ops) = acc
      let state = { state * 1_103_515_245 + 12_345 } % 2_147_483_648
      #(state, [operation(state), ..ops])
    })
  list.reverse(ops)
}

fn operation(state: Int) -> Operation {
  let burst = state % 90
  let frames =
    int.range(from: 0, to: burst, with: [], run: fn(acc, n) {
      let frame = case n % 3 {
        0 -> pushed.notice("main", 11 + n)
        1 ->
          connection_event.NetworkFault(
            int.to_string(state) <> "/" <> int.to_string(n),
          )
        _ -> connection_event.Connected
      }
      [frame, ..acc]
    })
    |> list.reverse
  let event = case { state / 90 } % 6 {
    0 -> backend.KeyPress("a")
    1 -> backend.KeyPress("enter")
    2 -> backend.KeyPress("esc")
    3 -> backend.MouseScroll(1, 3, True)
    _ -> backend.Tick
  }
  Operation(frames:, event:)
}

fn fresh() -> tui_model.Model {
  tui.new_model(connection.new_inbox(), workspace.Context("test", None))
}

fn failures(model: tui_model.Model) -> List(String) {
  list.filter_map(model.shared.transcript, fn(line) {
    case line {
      transcript_line.Line(transcript_line.Failure, text) -> Ok(text)
      transcript_line.Line(..) -> Error(Nil)
    }
  })
}
