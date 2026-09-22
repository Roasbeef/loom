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

fn file_as(path, index, worktree, patch, kind, extent) {
  worktree_view.File(path, index, worktree, patch, kind, extent)
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
    worktree_view.Committed("Session commits unavailable", "", "complete"),
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
    == Ok(worktree_view.PatchHeading("b name · text · complete"))
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
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("/work", None),
      fn() { 0 },
    )
  tui.Model(
    ..base,
    diff_view: tui.DiffVisible,
    strands: [],
    worktree: state,
    input: textarea.state_from_string("draft"),
  )
  |> fn(model) { tui.update(backend.Resize(120, 30), model) }
}

fn key(model, key) {
  tui.update(backend.KeyPress(key), model)
}

fn painted(model: tui.Model) {
  let model = tui.update(backend.Tick, model)
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
  let visible = painted(selected)
  assert string.contains(visible, "second patch")
  assert !string.contains(visible, "patch-row-")
    as "selection replaces all-file rows without a resize or server event"
  let resumed = selected |> key("enter") |> key("x")
  assert textarea.value(resumed.input) == "draftrx"
  let resized = tui.update(backend.Resize(160, 35), resumed)
  assert resized.worktree.selected == 2
}

pub fn diff_navigation_labels_status_and_selected_extent_test() {
  let files = [
    file_as("added.gleam", "A", " ", "+added", "text", "complete"),
    file_as("changed.gleam", " ", "M", "+changed", "text", "limited"),
    file_as("deleted.gleam", "D", " ", "-deleted", "text", "complete"),
    file_as("asset.bin", " ", "M", "", "binary", "complete"),
    file_as("empty.txt", " ", "M", "", "no_net_change", "complete"),
    file_as("mode.sh", " ", "M", "", "metadata_only", "complete"),
  ]
  let observed =
    worktree_view.receive(
      waiting(8),
      "owner",
      worktree_view.Ready(worktree_view.Board(
        8,
        1234,
        "head",
        files,
        8,
        2,
        "limited",
        worktree_view.Committed("Two commits observed", "", "limited"),
      )),
    )
    |> worktree_view.request("owner")
  let base = model_with_patch()
  let model =
    tui.Model(..base, worktree: observed)
    |> key("ctrl+d")
    |> fn(model) { tui.update(backend.Tick, model) }
  let labels =
    list.fold(range(6), #(model, ""), fn(acc, _) {
      let #(current, text) = acc
      #(key(current, "down"), text <> painted(current))
    })
  let #(selected, visible) = labels
  let visible = visible <> painted(selected)
  assert string.contains(visible, "[A] added.gleam")
  assert string.contains(visible, "[M] changed.gleam")
  assert string.contains(visible, "[D] deleted.gleam")
  assert string.contains(visible, "[BIN] asset.bin")
  assert string.contains(visible, "[NO Δ] empty.txt")
  assert string.contains(visible, "[META] mode.sh")
  assert string.contains(
    visible,
    "Refreshing worktree; previous observation may be stale",
  )
  assert string.contains(visible, "mode.sh · metadata_only · complete")
}

pub fn compact_focused_diff_borrows_status_space_but_keeps_editor_test() {
  let compact =
    model_with_patch()
    |> fn(model) { tui.update(backend.Resize(40, 12), model) }
    |> key("ctrl+d")
    |> key("down")
  let patch = tui.diff_patch_area(compact)
  assert patch.size.height >= 2
  let visible = painted(compact)
  assert string.contains(visible, "NAV ↑↓ r Enter PgUp/Dn")
  assert string.contains(visible, "first.gleam")
  assert compact.diff_row_count > patch.size.height
  let paged = key(compact, "pageup")
  assert paged.diff_scroll_offset > compact.diff_scroll_offset
  assert painted(paged) != visible
  assert textarea.value(compact.input) == "draft"

  let composing = compact |> key("enter") |> key("x")
  assert composing.worktree.focus == worktree_view.Composer
  assert composing.worktree.selected == compact.worktree.selected
  assert textarea.value(composing.input) == "draftx"
}

pub fn mouse_uses_visible_navigation_offset_and_other_surface_blocks_hit_test() {
  let files =
    range(8)
    |> list.map(fn(index) {
      file("file-" <> int.to_string(index), "patch-" <> int.to_string(index))
    })
  let state =
    worktree_view.receive(
      waiting(8),
      "owner",
      worktree_view.Ready(board(8, files)),
    )
  let base = model_with_patch()
  let focused =
    tui.Model(
      ..base,
      worktree: worktree_view.State(
        ..state,
        selected: 6,
        focus: worktree_view.Navigator,
      ),
    )
    |> fn(model) { tui.update(backend.Resize(80, 24), model) }
  let navigation = tui.diff_navigation_area(focused)
  let clicked =
    tui.update(
      backend.MousePress(
        navigation.position.x + 1,
        navigation.position.y,
        backend.MouseLeft,
      ),
      focused,
    )
  assert clicked.worktree.selected == 1
    as "the top visible row maps through the shared navigation offset"

  let covered = tui.Model(..focused, notes_open: True)
  let ignored =
    tui.update(
      backend.MousePress(
        navigation.position.x + 1,
        navigation.position.y,
        backend.MouseLeft,
      ),
      covered,
    )
  assert ignored.worktree.selected == 6
}

pub fn patch_page_uses_actual_height_and_preclamps_after_resize_test() {
  let resized =
    model_with_patch()
    |> key("ctrl+d")
    |> key("down")
    |> fn(model) { tui.update(backend.Resize(40, 12), model) }
  let height = tui.diff_patch_area(resized).size.height
  let trapped = tui.Model(..resized, diff_scroll_offset: 10_000)
  let paged = key(trapped, "pageup")
  let maximum = int.max(0, paged.diff_row_count - height)
  assert paged.diff_scroll_offset == maximum
  let newer = key(paged, "pagedown")
  assert newer.diff_scroll_offset == int.max(0, maximum - height)

  let composing = key(resized, "enter")
  let refocused =
    key(tui.Model(..composing, diff_scroll_offset: 10_000), "ctrl+d")
  let focused_maximum =
    int.max(
      0,
      refocused.diff_row_count - tui.diff_patch_area(refocused).size.height,
    )
  assert refocused.diff_scroll_offset == focused_maximum
}

pub fn borrowed_side_patch_routes_wheel_without_moving_transcript_test() {
  let focused =
    model_with_patch()
    |> fn(model) { tui.update(backend.Resize(160, 12), model) }
    |> key("ctrl+d")
    |> key("down")
  let patch = tui.diff_patch_area(focused)
  let moved =
    tui.update(
      backend.MouseScroll(patch.position.x, patch.position.y, True),
      focused,
    )
  assert moved.scroll_offset == focused.scroll_offset
  assert moved.diff_scroll_offset > focused.diff_scroll_offset
}

pub fn mouse_selection_replaces_cached_patch_without_resize_test() {
  let selected =
    tui.update(backend.MousePress(2, 6, backend.MouseLeft), model_with_patch())
  assert selected.worktree.selected == 2
  let visible = painted(selected)
  assert string.contains(visible, "second patch")
  assert !string.contains(visible, "patch-row-")
    as "mouse navigation invalidates the same patch cache as keyboard navigation"
}

pub fn ready_observation_replaces_cached_patch_without_resize_test() {
  let previous = model_with_patch()
  let waiting =
    tui.Model(
      ..previous,
      worktree: worktree_view.State(
        ..previous.worktree,
        owner: "",
        awaiting: Some(9),
      ),
    )
  let observed =
    tui.apply_channel_update(
      waiting,
      session_channel.Auxiliary(
        protocol.WorktreeSnapshot(
          worktree_view.Ready(
            board(9, [file("refreshed.gleam", "fresh observation patch")]),
          ),
        ),
      ),
    )
    |> fn(model) { tui.update(backend.Tick, model) }
  let visible = painted(observed)
  assert string.contains(visible, "fresh observation patch")
  assert !string.contains(visible, "second patch")
    as "the delivered board replaces cached rows without a terminal resize"
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

pub fn automatic_wide_diff_preserves_composer_and_explicit_dismissal_test() {
  let base =
    tui.Model(
      ..tui.new_model(connection.new_inbox(), workspace.Context("/work", None)),
      input: textarea.state_from_string("draft"),
    )
  let wide = tui.update(backend.Resize(160, 35), base)
  assert wide.diff_view == tui.DiffAutomatic
  assert string.contains(painted(wide), "captured changes")
  assert string.contains(painted(wide), "transcript / main")
  assert textarea.value(key(wide, "x").input) == "draftx"
  assert key(wide, "esc").diff_view == tui.DiffAutomatic
    as "the default pane must not intercept the operation stop key"

  let narrow = tui.update(backend.Resize(100, 35), wide)
  assert !string.contains(painted(narrow), "captured changes")
  let wide_again = tui.update(backend.Resize(160, 35), narrow)
  assert string.contains(painted(wide_again), "captured changes")
  let dismissed = tui.open_diff(wide_again)
  assert dismissed.diff_view == tui.DiffHidden
  let resized = tui.update(backend.Resize(170, 35), dismissed)
  assert !string.contains(painted(resized), "captured changes")
  assert textarea.value(resized.input) == "draft"

  let manual = tui.open_diff(narrow)
  assert manual.diff_view == tui.DiffVisible
  assert string.contains(painted(manual), "captured changes")
}

pub fn changes_during_observation_schedule_exactly_one_followup_test() {
  let inflight = waiting(8)
  let dirty = worktree_view.request(inflight, "owner")
  assert dirty.awaiting == Some(8)
  assert dirty.refresh == worktree_view.Requested
  assert worktree_view.request(dirty, "owner") == dirty
  let ready =
    worktree_view.receive(dirty, "owner", worktree_view.Ready(board(8, [])))
  assert ready.awaiting == None
  assert ready.refresh == worktree_view.Requested
  let next = worktree_view.sent(ready, 9)
  assert next.awaiting == Some(9)
  assert next.refresh == worktree_view.Settled
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

// Commit navigation remains selected even when current file status changes.
pub fn committed_patches_are_navigable_in_a_clean_worktree_test() {
  let observation = board(8, [])
  let observation =
    worktree_view.Board(
      ..observation,
      committed: worktree_view.Committed(
        "Commits since session start",
        "commit abc\n+added",
        "limited",
      ),
    )
  let loaded =
    worktree_view.receive(waiting(8), "owner", worktree_view.Ready(observation))
  assert worktree_view.labels(loaded)
    == ["All files (0)", "Commits since session start"]
  let selected = worktree_view.State(..loaded, selected: 1)
  assert worktree_view.patches(selected)
    == [
      worktree_view.PatchHeading("Commits since session start"),
      worktree_view.PatchBody("commit abc\n+added"),
      worktree_view.PatchHeading(
        "Commit patches truncated by the display limit",
      ),
    ]
  let refreshed =
    selected
    |> worktree_view.request("owner")
    |> worktree_view.sent(9)
    |> worktree_view.receive(
      "owner",
      worktree_view.Ready(board(9, [file("new", "patch")])),
    )
  assert refreshed.selected == 2
}

// New hosts add committed data without making old ready boards invalid.
pub fn committed_wire_extension_is_bounded_and_optional_test() {
  let assert json.Object(fields) = raw_ready(8)
    as "the fixture is a ready board"
  let extension = fn(patch) {
    json.Object([
      #(
        "committed",
        json.Object([
          #("message", json.String("Commits since session start")),
          #("patch", json.String(patch)),
          #("extent", json.String("complete")),
        ]),
      ),
      ..fields
    ])
  }
  let assert Ok(worktree_view.Ready(decoded)) =
    worktree_view.decode(extension("+added"))
    as "the new optional field reaches the commit view"
  assert decoded.committed.patch == "+added"
  let assert Ok(worktree_view.Ready(legacy)) =
    worktree_view.decode(raw_ready(8))
    as "old hosts remain readable"
  assert string.contains(legacy.committed.message, "unavailable")
  let assert Error(_) =
    worktree_view.decode(extension(string.repeat("x", 4097)))
    as "oversized commit streams cannot enter retained display state"
  Nil
}
