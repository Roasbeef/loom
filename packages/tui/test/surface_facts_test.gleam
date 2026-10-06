//// The terminal's surfaces follow what the event fold records for them.
////
//// The event fold (`session_view/event_fold`) takes the session state alone, so a
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
//// refused, and whether a diff is shown when a new cut arrives. The
//// commands (`session_view/commands`) record facts too; those no other test reached
//// are an interrupt returning a steering composer to prompting, a
//// dispatched prompt returning it too while a dispatched command leaves it
//// alone, `/clear` dropping the gutters, and `/approvals <id>` naming the
//// record the dialog waits for.

import core/json
import core/message
import etui/backend
import etui/widgets/textarea as text_area
import gleam/dict
import gleam/option.{None, Some}
import session_view/attempt_replay
import session_view/model as session_model
import session_view/notice_words
import session_view/protocol
import session_view/session_channel
import session_view/shared_set
import session_view/snapshot
import session_view/snapshot_view
import tui
import tui/connection
import tui/focused_goal_panel
import tui/inbound
import tui/interaction
import tui/model.{DiffVisible, GoalInspector, ModelSelector, NoOverlay} as tui_model
import tui/model_selector
import tui/queue_editor
import tui/submit
import tui/tick
import tui/view_set
import tui/workspace
import tui_test/pushed

fn model() -> tui_model.Model {
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  tui_model.Model(
    ..base,
    shared: base.shared
      |> shared_set.session("demo")
      |> shared_set.active_strand("main"),
  )
}

// Input typed after an interrupt is released with the input the daemon
// holds, so a composer that was set to steer the running turn goes back to
// prompting when the interrupt is sent, and stays as it was when there is
// nothing to interrupt.
pub fn an_interrupt_returns_the_composer_to_prompting_test() {
  // The demo roster shows `main` streaming.
  let base = model()
  let steering =
    tui_model.Model(
      ..base,
      view: view_set.submission_mode(base.view, tui_model.SteerNow),
    )
  let interrupted = submit.interrupt_active(steering)
  assert interrupted.shared.interrupt != None
    as "the interrupt is held for the running strand"
  assert interrupted.view.submission_mode == tui_model.PromptNext
    as "the next line is a prompt, not a steer into the stopping turn"

  let idle =
    tui_model.Model(
      shared: base.shared
        |> shared_set.strands([])
        |> shared_set.submitting(None),
      view: view_set.submission_mode(base.view, tui_model.SteerNow),
    )
  let untouched = submit.interrupt_active(idle)
  assert untouched.shared.notice == "nothing is running"
  assert untouched.view.submission_mode == tui_model.SteerNow
    as "an interrupt with nothing running leaves the composer alone"
}

// A draft typed into the composer of the preview, whose lane never locks a
// submission, so the dispatch consumes the draft at once.
fn drafted(text: String) -> tui_model.Model {
  let base = model()
  tui_model.Model(
    ..base,
    view: base.view
      |> view_set.input(text_area.state_from_string(text))
      |> view_set.submission_mode(tui_model.SteerNow),
  )
}

// A prompt the dispatch consumes returns a steering composer to prompting;
// a command it consumes empties the editor and leaves the mode alone. Both
// keep the text in the input history.
pub fn a_dispatched_prompt_returns_the_composer_to_prompting_test() {
  let prompted = submit.submit(drafted("look at the failing test"))
  assert text_area.value(prompted.view.input) == ""
  assert prompted.view.history == ["look at the failing test"]
  assert prompted.view.submission_mode == tui_model.PromptNext
    as "the draft went as a prompt, so the next line is a prompt too"

  let compacted = submit.submit(drafted("/compact"))
  assert text_area.value(compacted.view.input) == ""
  assert compacted.view.history == ["/compact"]
  assert compacted.view.submission_mode == tui_model.SteerNow
    as "a command leaves the composer's mode as the operator set it"
}

pub fn clearing_the_transcript_drops_its_gutters_test() {
  let base = drafted("/clear")
  let cleared =
    submit.submit(
      tui_model.Model(..base, view: view_set.record_gutters(base.view, [7])),
    )
  assert cleared.shared.transcript == []
  assert cleared.view.record_gutters == []
    as "gutters of rows that are gone are dropped"
}

pub fn an_approval_lookup_names_the_record_the_dialog_waits_for_test() {
  let asked = submit.submit(drafted("/approvals esc-1"))
  assert asked.view.inspecting_approval == Some("esc-1")
    as "the dialog opens on this record when the lookup answers"
}

pub fn a_full_snapshot_returns_the_viewport_to_the_tail_test() {
  let base = model()
  let scrolled =
    tui_model.Model(
      ..base,
      view: base.view
        |> view_set.scroll_offset(4)
        |> view_set.record_gutters([7]),
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
      view: view_set.overlay(
        base.view,
        GoalInspector(focused_goal_panel.new(None, "observed")),
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
      view: base.view
        |> view_set.prompted_approvals([#("esc-1", 4)])
        |> view_set.inspecting_approval(Some("esc-2"))
        |> view_set.note_selected(Some("note")),
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
      shared: shared_set.strands(base.shared, [
        protocol.Strand("main", Some("main"), Some("assistant")),
      ]),
    )
  let ticked = tui.update(backend.Tick, live)
  assert ticked.view.activity_frame == live.view.activity_frame + 1
    as "each tick of a live strand advances the glyph's frame"
  let resting =
    tui_model.Model(
      ..base,
      shared: shared_set.strands(base.shared, [
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
      view: view_set.queue_editor(
        base.view,
        queue_editor.State(
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
  assert saved.shared.notice
    == notice_words.outcome("edit_queued_input", "queued")
}

// A notes read the operator did not ask for is the todo panel's seed, and
// its refusal is not reported; one refused while a notes surface is open is.
pub fn a_refused_notes_read_is_reported_only_to_an_open_surface_test() {
  let base = model()
  let refusal = session_channel.RequestRefused("notes", 7, "unsupported", "no")
  let quiet = inbound.apply_channel_update(base, refusal)
  assert quiet.shared.transcript == base.shared.transcript
  let open = tui_model.Model(..base, view: view_set.notes_open(base.view, True))
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
      shared: shared_set.peer(replaying.shared, session_model.Attached),
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
      tui_model.Model(..base, view: view_set.diff_view(base.view, DiffVisible)),
      update,
    )
  assert shown.shared.worktree != hidden.shared.worktree
    as "a shown diff asks for the worktree the cut may have changed"
}
