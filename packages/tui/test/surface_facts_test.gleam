//// The terminal's surfaces follow what the event fold records for them.
////
//// The event fold (`tui/event_fold`) takes the session state alone, so a
//// pushed event that changes a terminal surface records a surface fact and
//// `inbound.settle_surfaces` applies it after the event. Most facts are
//// observed by the tests of the surface they change. These two cover the
//// facts no other test reached: a full snapshot returning the viewport to
//// the tail, and a models reply refreshing a selector that is open.

import gleam/option.{None}
import session_view/protocol
import session_view/session_channel
import tui
import tui/connection
import tui/inbound
import tui/interaction
import tui/model.{ModelSelector, NoOverlay} as tui_model
import tui/model_selector
import tui/session_model
import tui/workspace

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
