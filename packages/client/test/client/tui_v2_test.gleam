//// Two real terminals traverse daemon control, credited transfer and rendering.
//// No test injects a transcript event or submits directly to the runtime.

import client/session_socket_test
import core/entry
import core/json
import core/message
import etui/backend
import etui/widgets/textarea
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import support/tui_driver
import tui
import tui/attempt
import tui/connection
import tui/daemon
import tui/daemon/selection
import tui/session_channel
import weft/poll

pub fn tui_v2_queued_final_reply_sends_one_waiting_command_without_second_enter_test() {
  session_socket_test.fixture(fn(port, token, session, _, _) {
    let address = "ws://127.0.0.1:" <> int.to_string(port) <> "/v2/control"
    let assert Ok(control) =
      daemon.connect(address, token, process.self(), 2000)
      as "terminal owns the authenticated control connection"
    let assert Ok(host) = selection.host(control, address, token)
      as "one daemon supplies session routing"
    let assert Ok(target) = selection.open(host, session)
      as "resident metadata supplies the exact incarnation"
    let inbox = connection.new_inbox()
    let assert Ok(socket) = connection.connect(target.address, token, inbox)
      as "the real conversation socket belongs to this terminal inbox"
    let issued = process.new_subject()
    let trace =
      attempt.Trace(attempt.Id(1), fn(event) {
        case event {
          attempt.Issued(_, attempt.Request(id, "prompt", _)) ->
            process.send(issued, id)
          _ -> Nil
        }
      })
    let channel =
      session_channel.start_recorded(socket, target.expected, Some(trace))
    let model =
      tui.Model(
        ..tui.new_model(inbox, target.workspace),
        peer: tui.Attached(socket),
        channel: Some(channel),
        session: session,
      )
    let #(initial, ending) = hold_snapshot_end(model, 32)
    let initial = tui.accept_connection_message(initial, ending)
    let assert Some(channel) = initial.channel
      as "initial cut keeps its channel"
    assert session_channel.mutation_available(channel)

    // Start one real periodic catch-up, then withhold only its actual final
    // response. No synthetic snapshot or direct runtime submission is used.
    let assert poll.Answered(channel) =
      poll.until(within: 1000, every: 5, attempt: fn() {
        let #(next, _) = session_channel.tick(channel)
        case session_channel.in_flight(next) {
          True -> poll.Done(next)
          False -> poll.Retry
        }
      })
      as "one catch-up becomes due under a finite deadline"
    let #(waiting, ending) =
      hold_snapshot_end(tui.Model(..initial, channel: Some(channel)), 32)
    let waiting = tui.update(backend.Paste("queued reply prompt"), waiting)
    let refused = tui.update(backend.KeyPress("enter"), waiting)
    assert textarea.value(refused.input) == "queued reply prompt"
      as "a genuinely incomplete cut retains the draft"
    assert refused.next_id == waiting.next_id
    assert refused.pending_submission == Some(tui.ComposerSubmission)
    assert process.receive(issued, 0) == Error(Nil)
    let refused = tui.update(backend.KeyPress("enter"), refused)
    let refused =
      tui.update(backend.Paste("must not replace queued intent"), refused)
    assert textarea.value(refused.input) == "queued reply prompt"

    // The actual final response completes the waiting intent during idle
    // progress. There is no second Enter and no mutation before this reply.
    process.send(inbox, ending)
    let admitted = tui.update(backend.Tick, refused)
    assert textarea.value(admitted.input) == ""
    assert admitted.next_id == refused.next_id + 1
    let assert Ok(_) = process.receive(issued, 1000)
      as "exactly one prompt was issued after the completed cut"
    assert process.receive(issued, 0) == Error(Nil)
    let assert Ok(connection.Incoming(reply)) = process.receive(inbox, 2000)
      as "the real server acknowledges the transmitted mutation"
    let assert Ok(json.Object(fields)) = json.parse(reply) as "response is JSON"
    assert list.key_find(fields, "event") == Ok(json.String("mutation_outcome"))
    connection.close(socket)
    daemon.close(control)
  })
}

fn hold_snapshot_end(model: tui.Model, remaining: Int) {
  assert remaining > 0 as "fixture transfers have a finite frame budget"
  let assert Ok(incoming) = process.receive(model.inbox, 1000)
    as "each credited response arrives within its deadline"
  let ended = case incoming {
    connection.Incoming(text) -> {
      let assert Ok(json.Object(fields)) = json.parse(text)
        as "server sends JSON"
      list.key_find(fields, "event") == Ok(json.String("snapshot_end"))
    }
    connection.Connected -> False
    connection.Closed(_) | connection.NetworkFault(_) ->
      panic as "fixture transport failed"
  }
  case ended {
    True -> #(model, incoming)
    False ->
      hold_snapshot_end(
        tui.accept_connection_message(model, incoming),
        remaining - 1,
      )
  }
}

/// Samples the real terminal until a visible condition or an eight-second deadline.
///
/// ## Examples
///
/// ```gleam
/// // tui_v2_test.await(driver, fn(sample) { sample.model.session == selected })
/// ```
@internal
pub fn await(driver, predicate) {
  let outcome =
    poll.fold_until(
      clock: poll.monotonic(),
      within: 8000,
      every: poll.Fixed(10),
      from: "no terminal sample",
      attempt: fn(_) {
        let sample = tui_driver.play(driver, [])
        case predicate(sample) {
          True -> poll.Settled(sample)
          False -> poll.Pending(sample.model.notice <> "\n" <> sample.frame)
        }
      },
    )
  case outcome {
    poll.Answer(sample) -> sample
    poll.RanOut(last) -> {
      let reason = "terminal deadline: " <> last
      panic as reason
    }
    poll.Failure(reason) -> panic as reason
  }
}

fn synchronized(sample: tui_driver.Sample) {
  case sample.model.peer, sample.model.captured {
    tui.Attached(_), Some(_) -> True
    _, _ -> False
  }
}

fn users(sample: tui_driver.Sample) {
  list.filter_map(sample.model.records, fn(record) {
    case record.entry {
      entry.MessageEntry(message: message.UserMessage(content:, ..), ..) ->
        Ok(
          list.filter_map(content, fn(block) {
            case block {
              message.UserText(text, _) -> Ok(text)
              message.UserImage(..) -> Error(Nil)
            }
          })
          |> string.join("\n"),
        )
      _ -> Error(Nil)
    }
  })
}

fn assistant_settled(sample: tui_driver.Sample) {
  list.any(sample.model.records, fn(record) {
    case record.entry {
      entry.MessageEntry(message: message.AssistantMessage(content:, ..), ..) ->
        list.any(content, fn(block) {
          case block {
            message.AssistantText(text, _) -> text != ""
            _ -> False
          }
        })
      _ -> False
    }
  })
  && list.all(sample.model.strands, fn(strand) {
    strand.live_phase == option.None
  })
}

pub fn tui_v2_two_terminals_validate_initial_cuts_and_share_a_real_turn_test() {
  session_socket_test.fixture(fn(port, token, session, epoch, _) {
    let address = "ws://127.0.0.1:" <> int.to_string(port) <> "/v2/control"
    let assert Ok(alice) = tui_driver.start(address, token, session)
      as "first terminal authenticates daemon control and starts explicit selection"
    let assert Ok(bob) = tui_driver.start(address, token, session)
      as "second terminal has independent control and conversation lifetimes"
    let a = await(alice.data, synchronized)
    let b = await(bob.data, synchronized)
    let assert Some(#(a_cut, _)) = a.model.captured
      as "Alice adopted a validated cut"
    let assert Some(#(b_cut, _)) = b.model.captured
      as "Bob adopted a validated cut"
    assert a_cut.attachment.expected.epoch == epoch
    assert a_cut.attachment.expected == b_cut.attachment.expected
    assert a_cut.attachment.connection_id != b_cut.attachment.connection_id

    let _ =
      tui_driver.play(alice.data, [
        backend.Paste("shared-v2-turn"),
        backend.KeyPress("enter"),
      ])
    let a =
      await(alice.data, fn(sample) {
        list.contains(users(sample), "shared-v2-turn")
      })
    let b =
      await(bob.data, fn(sample) {
        list.contains(users(sample), "shared-v2-turn")
      })
    assert list.filter(users(a), fn(text) { text == "shared-v2-turn" })
      == ["shared-v2-turn"]
    assert list.filter(users(b), fn(text) { text == "shared-v2-turn" })
      == ["shared-v2-turn"]
    assert string.contains(b.frame, "Owner:")
      as "durable human attribution is rendered on the peer terminal"
    let a = await(alice.data, assistant_settled)
    let b = await(bob.data, assistant_settled)
    assert a.model.records == b.model.records
      as "both terminals reconcile the committed assistant result after operation settlement"
    tui_driver.stop(bob.data)
    tui_driver.stop(alice.data)
    Nil
  })
}
