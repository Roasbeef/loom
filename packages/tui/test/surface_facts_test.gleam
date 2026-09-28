//// The terminal's surfaces follow what the event fold records for them.
////
//// The event fold (`tui/event_fold`) takes the session state alone, so a
//// pushed event that changes a terminal surface records a surface fact and
//// `inbound.settle_surfaces` applies it after the event. Most facts are
//// observed by the tests of the surface they change. These two cover the
//// facts no other test reached: a full snapshot returning the viewport to
//// the tail, and a models reply refreshing a selector that is open. The lane
//// fold's facts have the same gap in four places, covered below: a lost
//// lane closing the goal inspector, a replay's adoption forgetting the
//// previous capture's prompts, the activity glyph advancing while the
//// active strand is live, and an acknowledged queue save closing the queue
//// editor. So do two of the three things the lane fold reads from its
//// `Surroundings`: whether a notes surface is open when a notes read is
//// refused, and whether a diff is shown when a new cut arrives.

import core/json
import core/message
import etui/backend
import gleam/dict
import gleam/option.{None, Some}
import session_view/protocol
import session_view/session_channel
import session_view/snapshot
import session_view/snapshot_view
import tui
import tui/attempt_replay
import tui/connection
import tui/focused_goal_panel
import tui/inbound
import tui/interaction
import tui/model.{DiffVisible, GoalInspector, ModelSelector, NoOverlay} as tui_model
import tui/model_selector
import tui/queue_editor
import tui/session_model
import tui/tick
import tui/workspace
import tui_test/pushed

fn model() -> tui_model.Model {
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  tui_model.Model(
    ..base,
    shared: session_model.Shared(
      ..base.shared,
      session: "demo",
      active_strand: "main",
    ),
  )
}

pub fn a_full_snapshot_returns_the_viewport_to_the_tail_test() {
  let base = model()
  let scrolled =
    tui_model.Model(
      ..base,
      view: tui_model.View(..base.view, scroll_offset: 4, record_gutters: [7]),
    )

  // The snapshot names the session and strand already shown, so no
  // workspace switch restores a parked viewport; only the snapshot's own
  // fact can move it.
  let synchronized =
    inbound.apply_channel_update(
      scrolled,
      session_channel.Auxiliary(protocol.FullSnapshot(
        session: "demo",
        strands: [],
        entries: [],
        usage: inbound.zero_usage(),
      )),
    )
  assert synchronized.view.scroll_offset == 0
    as "a replaced transcript starts at its tail"
  assert synchronized.view.record_gutters == []
    as "gutters of rows that are gone are dropped"
}

pub fn a_models_reply_refreshes_an_open_selector_test() {
  let models = interaction.demo_models()
  let opened =
    tui_model.Model(
      ..model(),
      view: tui_model.View(
        ..model().view,
        overlay: ModelSelector(model_selector.new([], "")),
      ),
    )
  let refreshed =
    inbound.apply_channel_update(
      opened,
      session_channel.Auxiliary(protocol.ModelsSnapshot(models:)),
    )
  let assert ModelSelector(selector) = refreshed.view.overlay
    as "the selector stays open"
  assert selector.models == models
    as "an open selector lists the models the daemon just named"

  // With nothing open, the reply only updates the session state.
  let closed =
    inbound.apply_channel_update(
      model(),
      session_channel.Auxiliary(protocol.ModelsSnapshot(models:)),
    )
  assert closed.view.overlay == NoOverlay
  assert closed.shared.models == models
}

pub fn a_lost_lane_closes_the_goal_inspector_test() {
  let base = pushed.attached()
  let inspecting =
    tui_model.Model(
      ..base,
      view: tui_model.View(
        ..base.view,
        overlay: GoalInspector(focused_goal_panel.new(None, "observed")),
      ),
    )
  let failed =
    inbound.apply_channel_update(inspecting, session_channel.Failed("gone"))
  assert failed.view.overlay == NoOverlay
    as "the goal board the lane released is not left on screen"
}

pub fn a_replay_adoption_forgets_the_previous_prompts_test() {
  let base = model()
  let prompted =
    tui_model.Model(
      ..base,
      view: tui_model.View(
        ..base.view,
        prompted_approvals: [#("esc-1", 4)],
        inspecting_approval: Some("esc-2"),
        note_selected: Some("note"),
      ),
    )
  let cut =
    snapshot.Captured(
      snapshot.Attachment(
        snapshot.Expected("replayed", "epoch", "instance"),
        "peer",
        message.Origin("operator", "Operator"),
        snapshot.Owner,
      ),
      1,
      json.Object([]),
      snapshot.empty(),
      None,
    )
  let view =
    snapshot_view.View(
      [protocol.Strand("main", Some("main"), None)],
      dict.new(),
      dict.new(),
      dict.new(),
      base.shared.usage,
      snapshot_view.RunSettings("one_at_a_time", "parallel", None),
      [],
      [],
      None,
      Some([]),
      None,
    )
  let adopted =
    tick.apply_replay_change(prompted, attempt_replay.Adopt(cut, view))
  assert adopted.shared.session == "replayed"
  assert adopted.view.prompted_approvals == []
  assert adopted.view.inspecting_approval == None
  assert adopted.view.note_selected == None
}

pub fn a_live_strand_advances_the_activity_glyph_test() {
  let base = model()
  let live =
    tui_model.Model(
      ..base,
      shared: session_model.Shared(..base.shared, strands: [
        protocol.Strand("main", Some("main"), Some("assistant")),
      ]),
    )
  let ticked = tui.update(backend.Tick, live)
  assert ticked.view.activity_frame == live.view.activity_frame + 1
    as "each tick of a live strand advances the glyph's frame"
  let resting =
    tui_model.Model(
      ..base,
      shared: session_model.Shared(..base.shared, strands: [
        protocol.Strand("main", Some("main"), None),
      ]),
    )
  let idle = tui.update(backend.Tick, resting)
  assert idle.view.activity_frame == resting.view.activity_frame
    as "an idle strand's glyph does not move"
}

pub fn an_acknowledged_queue_save_closes_the_editor_test() {
  let base = model()
  let editing =
    tui_model.Model(
      ..base,
      view: tui_model.View(
        ..base.view,
        queue_editor: queue_editor.State(
          ..queue_editor.new(),
          surface: queue_editor.Inspector,
          message: "saving",
        ),
      ),
    )
  let saved =
    inbound.apply_channel_update(
      editing,
      session_channel.Acknowledged("edit_queued_input", "queued"),
    )
  assert saved.view.queue_editor == queue_editor.new()
  assert saved.shared.notice == "queued input updated"
}

// A notes read the operator did not ask for is the todo panel's seed, and
// its refusal is not reported; one refused while a notes surface is open is.
pub fn a_refused_notes_read_is_reported_only_to_an_open_surface_test() {
  let base = model()
  let refusal = session_channel.RequestRefused("notes", 7, "unsupported", "no")
  let quiet = inbound.apply_channel_update(base, refusal)
  assert quiet.shared.transcript == base.shared.transcript
  let open =
    tui_model.Model(..base, view: tui_model.View(..base.view, notes_open: True))
  let reported = inbound.apply_channel_update(open, refusal)
  assert reported.shared.notice == "unsupported: no"
}

// A cut that moves the sequence asks for a fresh worktree only while the
// terminal shows captured edits.
pub fn a_new_cut_refreshes_a_shown_worktree_only_test() {
  let replaying = pushed.attached()
  let base =
    tui_model.Model(
      ..replaying,
      shared: session_model.Shared(
        ..replaying.shared,
        peer: session_model.Attached,
      ),
    )
  let cut =
    snapshot.Captured(
      snapshot.Attachment(
        snapshot.Expected("A", "epoch", "incarnation"),
        "peer",
        message.Origin("operator", "Operator"),
        snapshot.Owner,
      ),
      base.shared.captured
        |> option.map(fn(shown) { { shown.0 }.next_seq + 1 })
        |> option.unwrap(1),
      json.Object([]),
      snapshot.empty(),
      None,
    )
  let view =
    snapshot_view.View(
      [protocol.Strand("main", Some("main"), None)],
      dict.new(),
      dict.new(),
      dict.new(),
      base.shared.usage,
      snapshot_view.RunSettings("one_at_a_time", "parallel", None),
      [],
      [],
      None,
      Some([]),
      None,
    )
  let update = session_channel.Captured(cut, view, session_channel.Notified)
  let hidden = inbound.apply_channel_update(base, update)
  let shown =
    inbound.apply_channel_update(
      tui_model.Model(
        ..base,
        view: tui_model.View(..base.view, diff_view: DiffVisible),
      ),
      update,
    )
  assert shown.shared.worktree != hidden.shared.worktree
    as "a shown diff asks for the worktree the cut may have changed"
}
