//// Side commands remain outside main submission and transcript projection.

import core/json
import etui/keys
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import session_view/btw
import session_view/command
import session_view/event_fold
import session_view/model as session_model
import session_view/protocol
import session_view/session_channel
import tui/interaction
import tui/model as tui_model
import tui_test/pushed

pub fn btw_grammar_and_palette_are_shared_with_web_test() {
  assert command.parse("/btw Why?")
    == command.Session(command.Btw(btw.Ask("Why?")))
  assert command.parse("/btw") == command.Session(command.Btw(btw.Read))
  assert command.parse("/btw refresh")
    == command.Session(command.Btw(btw.Refresh))
  assert command.parse("/btw cancel")
    == command.Session(command.Btw(btw.Cancel))
  assert list.any(command.suggestions("/bt"), fn(row) { row.command == "/btw" })
}

pub fn side_board_never_becomes_a_transcript_entry_test() {
  let model = pushed.attached()
  let board =
    btw.Board(
      "main",
      "source",
      "fixture",
      "ready",
      [btw.Exchange("Why?", "Because.")],
      "",
    )
  let before = model.shared
  let after = event_fold.apply_event(before, protocol.BtwSnapshot(board))
  assert after.transcript == before.transcript
  assert after.btw.board == Some(board)
  assert session_channel.is_read("btw")
  let assert Ok(decoded) = btw.decode(btw.encode(board)) as "board round trips"
  assert decoded == board
}

pub fn escape_hides_the_side_panel_without_aborting_main_test() {
  let model = pushed.attached()
  let model =
    tui_model.Model(
      ..model,
      shared: session_model.Shared(
        ..model.shared,
        btw: btw.State(..btw.new(), visibility: btw.Visible),
      ),
    )
  let after = interaction.update_ready_key(keys.Escape, model)
  assert after.shared.btw.visibility == btw.Hidden
  assert after.shared.outbox == model.shared.outbox
  assert after.shared.transcript == model.shared.transcript
}

pub fn oversized_or_malformed_boards_are_refused_test() {
  assert result.is_error(btw.decode(json.Null))
  let board =
    btw.Board(
      "main",
      "source",
      "fixture",
      "ready",
      [btw.Exchange("Why?", string.repeat("x", 32_769))],
      "",
    )
  assert result.is_error(btw.decode(btw.encode(board)))
}
