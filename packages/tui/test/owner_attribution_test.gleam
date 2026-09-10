import core/clock
import core/entry
import core/ids
import core/json
import core/message
import etui/backend
import etui/geometry
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/connection
import tui/frame
import tui/protocol
import tui/snapshot
import tui/snapshot_view
import tui/workspace

fn owner() {
  message.Origin("owner-principal", "Owner")
}

fn local_peer() {
  snapshot_view.Peer("local", owner(), snapshot.Owner)
}

fn model(role, peers) {
  let base =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("test", None),
      fn() { -1000 },
    )
  let cut =
    snapshot.Captured(
      snapshot.Attachment(
        snapshot.Expected("session", "epoch", "incarnation"),
        "local",
        owner(),
        role,
      ),
      1,
      json.Object([]),
      snapshot.empty(),
      None,
    )
  let view =
    snapshot_view.View(
      [],
      dict.new(),
      dict.new(),
      dict.new(),
      base.usage,
      snapshot_view.RunSettings("one_at_a_time", "parallel", None),
      peers,
      [],
      None,
      None,
      None,
    )
  tui.Model(..base, captured: Some(#(cut, view)), transcript: [], records: [
    record(owner(), "my prompt"),
  ])
}

fn record(origin, text) {
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(1), seed: 1))
  protocol.EntryRecord(
    "main",
    entry.MessageEntry(
      id,
      None,
      1,
      1,
      message.UserMessage([message.UserText(text, None)], 1, Some(origin)),
      False,
    ),
  )
}

fn paint(model) {
  let updated = tui.update(backend.Resize(96, 30), model)
  let #(painted, _) = tui.view(updated, geometry.rect_new(0, 0, 96, 30))
  frame.buffer_to_text(painted)
}

pub fn owner_attribution_solo_owner_hides_only_current_local_identity_test() {
  let solo = model(snapshot.Owner, [local_peer()])
  assert !string.contains(paint(solo), "Owner:")
  assert string.contains(paint(solo), "my prompt")

  // Historical names remain facts even if the same principal later renames.
  list.each(
    [
      message.Origin("other-principal", "Owner"),
      message.Origin("owner-principal", "Previous name"),
    ],
    fn(author) {
      let historical =
        tui.Model(..solo, records: [record(author, "historical prompt")])
      assert string.contains(paint(historical), author.name <> ":")
      assert historical.records == [record(author, "historical prompt")]
    },
  )
}

pub fn owner_attribution_multiplayer_and_uncertain_presence_keep_labels_test() {
  let other =
    snapshot_view.Peer(
      "remote",
      message.Origin("other", "Alice"),
      snapshot.Operator,
    )
  list.each(
    [
      model(snapshot.Owner, [local_peer(), other]),
      model(snapshot.Owner, []),
      model(snapshot.Owner, [other]),
      model(snapshot.Owner, [
        snapshot_view.Peer("other-tab", owner(), snapshot.Owner),
      ]),
      model(snapshot.Operator, [local_peer()]),
      model(snapshot.Observer, [local_peer()]),
    ],
    fn(value) {
      assert string.contains(paint(value), "Owner:")
    },
  )
  let solo = model(snapshot.Owner, [local_peer()])
  assert string.contains(paint(tui.Model(..solo, captured: None)), "Owner:")
}

pub fn owner_attribution_presence_change_rebuilds_cached_rows_test() {
  let solo = model(snapshot.Owner, [local_peer()])
  let cached = tui.update(backend.Resize(96, 30), solo)
  let other =
    snapshot_view.Peer(
      "remote",
      message.Origin("other", "Alice"),
      snapshot.Operator,
    )
  let multiplayer = model(snapshot.Owner, [local_peer(), other])

  // A completed metadata cut invalidates the record cache even when no
  // immutable message changed. Exercise the corresponding rendering path.
  let joined =
    tui.Model(
      ..cached,
      captured: multiplayer.captured,
      record_cache_valid: False,
      render_revision: cached.render_revision + 1,
    )
  assert string.contains(paint(joined), "Owner:")
  let left =
    tui.Model(
      ..joined,
      captured: solo.captured,
      record_cache_valid: False,
      render_revision: joined.render_revision + 1,
    )
  assert !string.contains(paint(left), "Owner:")
}
