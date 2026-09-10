//// Worktree observations retain raw identity, request correlation, and their
//// own viewport even while the conversation composer continues accepting text.

import core/json
import etui/backend
import etui/geometry
import etui/widgets/textarea
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/connection
import tui/frame
import tui/protocol
import tui/session_channel
import tui/workspace
import tui/worktree_view
import tui_test/pushed

fn file(path, patch) {
  worktree_view.File(path, " ", "M", patch, "text", "complete")
}

fn board(id, files) {
  worktree_view.Board(
    id,
    1234,
    "head",
    files,
    list.length(files),
    0,
    "complete",
  )
}

fn waiting(id) {
  worktree_view.new()
  |> worktree_view.request("owner")
  |> worktree_view.sent(id)
}

pub fn request_and_attachment_identity_reject_stale_observations_test() {
  let initial = waiting(8)
  assert worktree_view.receive(
      initial,
      "owner",
      worktree_view.Ready(board(7, [])),
    )
    == initial
  assert worktree_view.receive(
      initial,
      "other",
      worktree_view.Ready(board(8, [])),
    )
    == initial
  let ready =
    worktree_view.receive(initial, "owner", worktree_view.Ready(board(8, [])))
  assert ready.board == Some(board(8, []))
  assert worktree_view.receive(ready, "owner", worktree_view.Pending(8))
    == ready
}

pub fn refresh_retains_raw_path_identity_and_missing_path_returns_all_test() {
  let a = file("a", "a patch")
  let b = file("b\nname", "b patch")
  let loaded =
    worktree_view.receive(
      waiting(8),
      "owner",
      worktree_view.Ready(board(8, [a, b])),
    )
  let selected =
    worktree_view.State(..loaded, selected: 2)
    |> worktree_view.request("owner")
    |> worktree_view.sent(9)
  let reordered =
    worktree_view.receive(
      selected,
      "owner",
      worktree_view.Ready(board(9, [b, a])),
    )
  assert reordered.selected == 1
  assert list.first(worktree_view.patches(reordered))
    == Ok("b name · text · complete")
  let absent =
    reordered
    |> worktree_view.request("owner")
    |> worktree_view.sent(10)
    |> worktree_view.receive("owner", worktree_view.Ready(board(10, [a])))
  assert absent.selected == 0
}

fn raw_ready(id) {
  json.Object([
    #("status", json.String("ready")),
    #("request_id", json.Int(id)),
    #("source", json.String("git")),
    #("observed_at_ms", json.Int(1234)),
    #("repository", json.String("head")),
    #("entries", json.Array([])),
    #("total", json.Int(0)),
    #("omitted", json.Int(0)),
    #("extent", json.String("complete")),
  ])
}

fn body(board) {
  json.Object([#("mode", json.String("worktree_diff")), #("board", board)])
}

pub fn ready_push_before_pending_reply_survives_channel_correlation_test() {
  let model = pushed.attached()
  let assert Some(channel) = model.channel
    as "fixture has a synchronized channel"
  let #(channel, disposition) =
    session_channel.submit(channel, protocol.worktree_diff(999))
  let assert session_channel.Sent("worktree_diff", id) = disposition
    as "channel allocates the actual request id"
  assert id != 999
  let #(channel, updates) =
    session_channel.receive(
      channel,
      pushed.push([
        #("event", json.String("snapshot")),
        #("body", body(raw_ready(id))),
      ]),
    )
  let assert [
    session_channel.Auxiliary(protocol.WorktreeSnapshot(worktree_view.Ready(
      found,
    ))),
  ] = updates
    as "a ready push is admitted even before the pending acknowledgement"
  let ready =
    worktree_view.receive(waiting(id), "owner", worktree_view.Ready(found))
  let #(_, updates) =
    session_channel.receive(
      channel,
      pushed.reply(
        id,
        "snapshot",
        body(
          json.Object([
            #("status", json.String("pending")),
            #("request_id", json.Int(id)),
          ]),
        ),
      ),
    )
  let assert [session_channel.Auxiliary(protocol.WorktreeSnapshot(pending))] =
    updates
    as "the delayed acknowledgement settles the command lane"
  assert worktree_view.receive(ready, "owner", pending) == ready
}

fn model_with_patch() {
  let patch =
    range(100)
    |> list.map(fn(index) { "patch-row-" <> int.to_string(index) })
    |> string.join("\n")
  let state =
    worktree_view.receive(
      waiting(8),
      "owner",
      worktree_view.Ready(
        board(8, [
          file("first.gleam", patch),
          file("second.gleam", "second patch"),
        ]),
      ),
    )
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  tui.Model(
    ..base,
    diff_view: tui.DiffVisible,
    worktree: state,
    input: textarea.state_from_string("draft"),
  )
  |> fn(model) { tui.update(backend.Resize(120, 30), model) }
}

fn key(model, key) {
  tui.update(backend.KeyPress(key), model)
}

fn painted(model: tui.Model) {
  let model = tui.update(backend.Resize(model.width, model.height), model)
  let #(buf, _) =
    tui.view(model, geometry.rect_new(0, 0, model.width, model.height))
  frame.buffer_to_text(buf)
}

pub fn file_focus_keeps_composer_text_and_patch_scroll_independent_test() {
  let model = model_with_patch() |> key("r")
  assert textarea.value(model.input) == "draftr"
  let selected = model |> key("ctrl+d") |> key("down") |> key("down")
  assert selected.worktree.selected == 2
  assert textarea.value(selected.input) == "draftr"
  assert string.contains(painted(selected), "second patch")
  let resumed = selected |> key("enter") |> key("x")
  assert textarea.value(resumed.input) == "draftrx"
  let resized = tui.update(backend.Resize(160, 35), resumed)
  assert resized.worktree.selected == 2
}

pub fn patch_scroll_can_reach_the_first_row_before_and_after_resize_test() {
  let model = model_with_patch() |> key("ctrl+d") |> key("down")
  let oldest =
    list.fold(range(20), model, fn(model, _) { key(model, "pageup") })
  assert string.contains(painted(oldest), "patch-row-0")
  assert oldest.scroll_offset == 0
  let resized = tui.update(backend.Resize(160, 35), oldest)
  let oldest =
    list.fold(range(20), resized, fn(model, _) { key(model, "pageup") })
  assert string.contains(painted(oldest), "patch-row-0")
}

pub fn malformed_extent_and_oversized_complete_board_are_refused_test() {
  let assert json.Object(fields) = raw_ready(4) as "fixture is an object"
  let bad =
    json.Object([
      #("total", json.Int(3)),
      ..list.filter(fields, fn(pair) { pair.0 != "total" })
    ])
  let assert Error(_) = worktree_view.decode(bad)
    as "omitted accounting must be exact"
  let huge =
    json.Object([
      #("padding", json.String(string.repeat("x", 48_000))),
      ..fields
    ])
  let assert Error(_) = worktree_view.decode(huge)
    as "the full encoded board is bounded"
}

fn range(stop: Int) -> List(Int) {
  int.range(0, stop, [], fn(acc, value) { [value, ..acc] }) |> list.reverse
}

pub fn live_jobs_is_a_read_and_its_correlated_roster_keeps_channel_ready_test() {
  let model = pushed.attached()
  let assert Some(channel) = model.channel
    as "fixture has a synchronized channel"
  let #(channel, disposition) =
    session_channel.submit(channel, protocol.live_jobs(999, "main"))
  let assert session_channel.Sent("live_jobs", id) = disposition
    as "the roster is issued once with the lane's request id"
  let body =
    json.Object([
      #("mode", json.String("live_jobs")),
      #(
        "board",
        json.Object([
          #("strand", json.String("main")),
          #("observed_at_ms", json.Int(42)),
          #("jobs", json.Array([])),
          #("total", json.Int(0)),
          #("omitted", json.Int(0)),
        ]),
      ),
    ])
  let #(channel, updates) =
    session_channel.receive(channel, pushed.reply(id, "snapshot", body))
  let assert [session_channel.Auxiliary(protocol.LiveJobsSnapshot(board))] =
    updates
    as "a successful read never becomes an unknown mutation or closes the lane"
  assert board.total == 0
  assert session_channel.ready_for_read(channel)
  let #(_, disposition) =
    session_channel.submit(channel, protocol.notes(1000, "main"))
  let assert session_channel.Sent("notes", _) = disposition
    as "the next read can use the same channel"
}

fn apply_incoming(model: tui.Model, message: connection.Message) -> tui.Model {
  let assert Some(channel) = model.channel as "fixture has a channel"
  let #(channel, updates) = session_channel.receive(channel, message)
  list.fold(
    updates,
    tui.Model(..model, channel: Some(channel)),
    tui.apply_channel_update,
  )
}

fn issue(model: tui.Model, command: String) -> #(tui.Model, Int) {
  let assert Some(channel) = model.channel as "fixture has a channel"
  let #(channel, disposition) = session_channel.submit(channel, command)
  let assert session_channel.Sent(_, request_id) = disposition
    as "fixture command is sent immediately"
  #(
    tui.apply_channel_update(
      tui.Model(..model, channel: Some(channel)),
      session_channel.Submission(disposition),
    ),
    request_id,
  )
}

pub fn unrelated_correlated_and_pushed_errors_do_not_cancel_a_worktree_observation_test() {
  let base = pushed.attached()
  let model =
    tui.Model(..base, worktree: worktree_view.request(worktree_view.new(), ""))
  let #(model, observation_id) = issue(model, protocol.worktree_diff(999))
  let model =
    apply_incoming(
      model,
      pushed.reply(
        observation_id,
        "snapshot",
        body(
          json.Object([
            #("status", json.String("pending")),
            #("request_id", json.Int(observation_id)),
          ]),
        ),
      ),
    )
  let #(model, models_id) = issue(model, protocol.models(1000))
  let error =
    json.Object([
      #("code", json.String("unavailable")),
      #("message", json.String("models unavailable")),
    ])
  let model = apply_incoming(model, pushed.reply(models_id, "error", error))
  assert model.worktree.awaiting == Some(observation_id)
  let model =
    apply_incoming(
      model,
      pushed.push([
        #("event", json.String("error")),
        #("body", error),
      ]),
    )
  assert model.worktree.awaiting == Some(observation_id)
  let model =
    apply_incoming(
      model,
      pushed.push([
        #("event", json.String("snapshot")),
        #("body", body(raw_ready(observation_id))),
      ]),
    )
  let assert Some(observation) = model.worktree.board
    as "the independent capture still adopts its final response"
  assert observation.request_id == observation_id
  assert model.worktree.awaiting == None
}
