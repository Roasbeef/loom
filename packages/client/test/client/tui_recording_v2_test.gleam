//// The real post-launch recorder must capture even a fast local first cut.
//// Recording reuses the terminal-owned driver and actual v2 listener; replay
//// opens no socket and validates the saved initial cut before painting it.

import client/session_socket_test
import client/tui_v2_test
import etui/backend
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import support/tui_driver
import tui
import tui/attempt
import tui/connection
import tui/frame
import tui/recording
import tui/session_channel

pub fn tui_recording_v2_fast_initial_attachment_and_settled_turn_replay_test() {
  session_socket_test.fixture(fn(port, token, session, _epoch, _harness) {
    let path = "build/tui-v2-recording-" <> session <> ".jsonl"
    let address = "ws://127.0.0.1:" <> int.to_string(port) <> "/v2/control"
    let assert Ok(driver) =
      tui_driver.start_recorded(address, token, session, path)
      as "the shipped recorder binds after launch and before terminal polling"
    let _ =
      tui_v2_test.await(driver.data, fn(sample) {
        case sample.model.channel {
          Some(channel) -> session_channel.mutation_available(channel)
          None -> False
        }
      })
    let _ =
      tui_driver.play(driver.data, [
        backend.Paste("recorded v2 turn"),
        backend.KeyPress("enter"),
      ])
    let _ =
      tui_v2_test.await(driver.data, fn(sample) {
        string.contains(sample.frame, "recorded v2 turn")
        && list.length(sample.model.records) >= 2
        && sample.model.streams == []
      })
    let monitor = process.monitor(driver.pid)
    tui_driver.stop(driver.data)
    let assert Ok(_) =
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(down) { down })
      |> process.selector_receive(3000)
      as "the original terminal is down before reading its last recording line"
    let assert Ok(moments) = recording.decode_file(path)
      as "all terminal-owned appends form one complete local format-two log"
    let assert [recording.Moment(_, recording.LocalFormatTwo), ..rest] = moments
      as "new recordings explicitly identify their local format"
    let attempts =
      list.filter_map(rest, fn(moment) {
        case moment.event {
          recording.Attempt(event) -> Ok(event)
          _ -> Error(Nil)
        }
      })
    let assert [
      attempt.Started(id, expected),
      attempt.Issued(issued_id, request),
      ..
    ] = attempts
      as "even the first subscribe is recorded before a local server reply"
    assert expected.session == session
    assert issued_id == id
    assert request == attempt.Request(1, "subscribe", attempt.NoSelection)
    assert list.any(attempts, fn(event) { event == attempt.Adopted(id) })
    assert list.last(attempts) == Ok(attempt.Closed(id))
      as "terminal teardown records retirement of its current attempt"
    assert list.any(attempts, fn(event) {
      case event {
        attempt.Received(_, connection.Incoming(text)) ->
          string.contains(text, "snapshot_end")
        _ -> False
      }
    })
    let assert Ok(frames) =
      tui.replay_steps(
        recording.to_steps(moments),
        backend.TerminalSize(110, 30),
      )
      as "the effect-free live decoder validates every recorded credit and cut"
    let assert Ok(last) = list.last(frames)
      as "replay paints the adopted conversation"
    let visible = frame.buffer_to_text(last)
    assert string.contains(visible, "recorded v2 turn")
    assert string.contains(visible, "Owner")
    assert string.contains(visible, session)
    let assert Ok(Nil) = simplifile.delete(path)
      as "the generated test recording is removed"
  })
}
