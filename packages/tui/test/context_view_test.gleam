//// A context reply can only finish the read that admitted it. The tests keep
//// attachment and strand changes separate from the command lane, then drive
//// the inspector through actual terminal input to preserve composer ownership.

import core/clock
import core/codec
import core/ids
import core/json
import core/message
import core/register
import etui/backend
import etui/geometry
import etui/widgets/textarea
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/codec as machine_codec
import machine/strand
import tui
import tui/command
import tui/connection
import tui/context_view as context
import tui/frame
import tui/protocol
import tui/session_channel
import tui/snapshot
import tui/snapshot_view
import tui/workspace
import tui/worktree_view
import tui_test/pushed

fn board(id, strand) {
  context.Board(
    id,
    strand,
    12,
    "test/large",
    10_000,
    7004,
    "reported_plus_estimate",
    7004,
    Some(8000),
    2000,
    [context.Item("System prompt", "System prompt", 2000)],
    [context.Item("Tools", "bash", 300)],
    0,
  )
}

fn waiting(id) {
  context.new() |> context.select("owner", "main") |> context.sent(id)
}

pub fn stale_attachment_request_and_strand_cannot_replace_context_test() {
  let original = waiting(8)
  assert context.receive(original, "other", context.Ready(board(8, "main")))
    == original
  assert context.receive(original, "owner", context.Ready(board(7, "main")))
    == original
  let switched = context.select(original, "owner", "fork") |> context.sent(9)
  assert context.receive(switched, "owner", context.Ready(board(8, "main")))
    == switched
  let mismatched =
    context.receive(original, "owner", context.Ready(board(8, "fork")))
  assert mismatched.board == None
  assert string.contains(mismatched.notice, "another strand")
  let ready =
    context.receive(original, "owner", context.Ready(board(8, "main")))
  assert context.footer(ready) == "ctx ~70%"
  assert context.receive(ready, "owner", context.Pending(8)) == ready
  assert context.select(ready, "replacement", "main").board == None
}

pub fn refresh_coalesces_without_reusing_an_outstanding_identity_test() {
  let refreshing = waiting(8) |> context.invalidate |> context.invalidate
  assert refreshing.request == context.RefreshAfter(8)
  let ready =
    context.receive(refreshing, "owner", context.Ready(board(8, "main")))
  assert ready.board == Some(board(8, "main"))
  assert ready.request == context.Requested
  let next = context.sent(ready, 9)
  assert context.receive(next, "owner", context.Ready(board(8, "main"))) == next
}

pub fn optional_refusal_is_correlated_and_does_not_retry_on_every_tick_test() {
  let original = waiting(8)
  assert context.refused(original, 7, "unsupported", "older server") == original
  let refused = context.refused(original, 8, "unsupported", "older server")
  assert refused.board == None
  assert refused.request == context.Unavailable
  assert context.invalidate(refused).request == context.Unavailable
  assert context.select(refused, "owner", "fork").request == context.Unavailable
  assert context.select(refused, "new attachment", "main").request
    == context.Requested
  assert context.footer(refused) == "ctx —"
}

fn raw_board(id) {
  json.Object([
    #("status", json.String("ready")),
    #("request_id", json.Int(id)),
    #("strand", json.String("main")),
    #("as_of", json.Int(12)),
    #("model", json.String("test/large")),
    #("context_window", json.Int(10_000)),
    #("used_tokens", json.Int(7004)),
    #("basis", json.String("reported_plus_estimate")),
    #("compaction_used_tokens", json.Int(7004)),
    #("checkpoint_at", json.Int(8000)),
    #("reserve_tokens", json.Int(2000)),
    #("categories", json.Array([])),
    #("items", json.Array([])),
    #("items_total", json.Int(0)),
    #("items_omitted", json.Int(0)),
  ])
}

fn replace(value, name, next) {
  let assert json.Object(fields) = value as "fixture boards are objects"
  json.Object(list.key_set(fields, name, next))
}

pub fn malformed_counts_or_oversized_boards_never_become_zero_usage_test() {
  let ready = raw_board(8)
  let assert Ok(context.Ready(_)) = context.decode(ready)
    as "valid observation decodes"
  list.each(
    [
      replace(ready, "context_window", json.Int(0)),
      replace(ready, "used_tokens", json.Int(-1)),
      replace(ready, "items_total", json.Int(1)),
      replace(ready, "basis", json.String("exact")),
      replace(ready, "model", json.String(string.repeat("m", 48_000))),
    ],
    fn(bad) {
      let assert Error(_) = context.decode(bad)
        as "invalid data is unavailable rather than a percentage"
    },
  )
}

fn body(board) {
  json.Object([#("mode", json.String("context")), #("board", board)])
}

pub fn ready_push_can_precede_its_pending_acknowledgement_test() {
  let assert Some(channel) = pushed.attached().channel
    as "fixture has a synchronized channel"
  let #(channel, sent) =
    session_channel.submit(channel, protocol.context(500, "main"))
  let assert session_channel.Sent("context", id) = sent
    as "the command lane allocates the read id"
  let #(channel, updates) =
    session_channel.receive(
      channel,
      pushed.push([
        #("event", json.String("snapshot")),
        #("body", body(raw_board(id))),
      ]),
    )
  let assert [
    session_channel.Auxiliary(protocol.ContextSnapshot(context.Ready(found))),
  ] = updates
    as "context pushes reach the local projection"
  let ready = context.receive(waiting(id), "owner", context.Ready(found))
  let #(channel, updates) =
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
  let assert [session_channel.Auxiliary(protocol.ContextSnapshot(pending))] =
    updates
    as "late pending releases the command lane"
  assert context.receive(ready, "owner", pending) == ready
  assert session_channel.ready_for_read(channel)
}

pub fn command_aliases_are_local_context_inspectors_test() {
  assert command.parse("/context") == command.Context
  assert command.parse("/context all") == command.ContextAll
  assert command.parse("/contextall") == command.ContextAll
}

pub fn inspector_retains_the_draft_and_shows_unavailable_without_a_connection_test() {
  let base =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("/work", None),
      fn() { 0 },
    )
  let original =
    tui.Model(..base, input: textarea.state_from_string("unfinished draft"))
  let opened =
    tui.open_context(original, context.Overview)
    |> fn(model) { tui.update(backend.Resize(100, 30), model) }
  let #(buf, _) = tui.view(opened, geometry.rect_new(0, 0, 100, 30))
  assert string.contains(
    frame.buffer_to_text(buf),
    "requires a live connection",
  )
  let ignored = tui.update(backend.Paste("do not edit"), opened)
  let scrolled = tui.update(backend.KeyPress("pagedown"), ignored)
  assert textarea.value(scrolled.input) == "unfinished draft"
  assert scrolled.context.scroll > 0
  let resumed = tui.update(backend.KeyPress("esc"), scrolled)
  assert resumed.context.surface == context.Hidden
  assert textarea.value(resumed.input) == "unfinished draft"
}

pub fn strand_change_waits_for_the_occupied_observation_slot_test() {
  let switched = waiting(8) |> context.select("owner", "fork")
  assert switched.request == context.RefreshAfter(8)
  assert switched.board == None
  let released =
    context.receive(switched, "owner", context.Ready(board(8, "main")))
  assert released.request == context.Requested
  assert released.board == None
  let next = context.sent(released, 9)
  let ready = context.receive(next, "owner", context.Ready(board(9, "fork")))
  assert ready.board == Some(board(9, "fork"))
}

pub fn wheel_scrolls_the_visible_inspector_without_moving_transcript_test() {
  let base =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("/work", None),
      fn() { 0 },
    )
  let opened =
    tui.open_context(base, context.All)
    |> fn(model) { tui.update(backend.Resize(100, 30), model) }
  let moved = tui.update(backend.MouseScroll(5, 5, False), opened)
  assert moved.context.scroll == opened.context.scroll + 3
  assert moved.scroll_offset == opened.scroll_offset
}

pub fn refused_refresh_invalidates_the_cached_percentage_test() {
  let base =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("/work", None),
      fn() { 0 },
    )
  let observed =
    context.receive(waiting(8), "owner", context.Ready(board(8, "main")))
  let refreshing = tui.Model(..base, context: context.sent(observed, 9))
  let refused =
    tui.apply_channel_update(
      refreshing,
      session_channel.RequestRefused(
        "context",
        9,
        "unavailable",
        "capture failed",
      ),
    )
  assert refused.context.board == None
  assert refused.frame_revision > refreshing.frame_revision
}

pub fn automatic_context_read_preserves_the_session_refusal_notice_test() {
  let base = pushed.attached()
  let refused =
    tui.Model(..base, notice: "open session: not_found: request refused")
  let reading =
    tui.apply_channel_update(
      refused,
      session_channel.Submission(session_channel.Sent("context", 500)),
    )
  assert reading.context.request == context.Awaiting(500)
  assert reading.notice == refused.notice
}

// One captured cell in the shape a metadata fragment carries it.
fn cell(namespace, key, value) {
  json.Object([
    #("namespace", json.String(register.ns_to_string(namespace))),
    #("key", json.String(key)),
    #("seq", json.Int(1)),
    #("value", value),
  ])
}

fn cut_metadata(cells) {
  json.Object([
    #("cells", json.Array(cells)),
    #("message_count", json.Int(0)),
    #(
      "usage",
      codec.encode_usage(message.Usage(
        0,
        0,
        0,
        0,
        None,
        None,
        0,
        message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
      )),
    ),
    #(
      "host_run_settings",
      json.Object([
        #("queue_mode", json.String("one_at_a_time")),
        #("tool_execution", json.String("parallel")),
        #("origin", json.Null),
      ]),
    ),
    #("peers", json.Array([])),
  ])
}

// A terminal holding exactly one captured cut, with the active strand in the
// supplied live phase. The three inputs are the three the refresh decision
// reads: the leaf the cut selected, the model the configuration names, and
// whether an operation is still running on this strand.
fn observing(
  leaf: json.JsonValue,
  model_id: String,
  phase: option.Option(String),
) -> tui.Model {
  let cells = [
    cell(
      register.StrandConfig,
      "main",
      machine_codec.encode_configuration(
        strand.StrandConfiguration(
          strand.ModelIdentity("provider", model_id),
          strand.ThinkingOff,
          [],
        ),
      ),
    ),
    cell(register.StrandLeaf, "main", leaf),
    cell(
      register.StrandState,
      "main",
      machine_codec.encode_strand_state(strand.StrandState(None, [])),
    ),
  ]
  let captured =
    snapshot.Captured(
      snapshot.Attachment(
        snapshot.Expected("session", "epoch", "incarnation"),
        "tab",
        message.Origin("principal", "Owner"),
        snapshot.Operator,
      ),
      10,
      cut_metadata(cells),
      snapshot.empty(),
      None,
    )
  let assert Ok(view) = snapshot_view.decode(captured)
    as "the fixture cut is coherent metadata"
  tui.Model(
    ..tui.new_model(connection.new_inbox(), workspace.Context("/work", None)),
    active_strand: "main",
    strands: [protocol.Strand("main", Some("main"), phase)],
    captured: Some(#(captured, view)),
  )
}

fn entry_leaf(seed: Int) -> json.JsonValue {
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(1000), seed))
  json.String(ids.entry_id_to_string(id))
}

pub fn the_footer_reads_at_the_operation_boundary_not_once_per_entry_test() {
  let first = entry_leaf(1)
  let second = entry_leaf(2)
  assert first != second as "the two fixture leaves are distinct"

  // A strand with no capture yet has nothing to show, so the first cut is
  // always worth a read.
  let idle = observing(first, "first", None)
  assert tui.context_refresh_due(tui.Model(..idle, captured: None), idle)

  // An entry committed while the operation runs moves the leaf. That is the
  // transition this refresh deliberately ignores: a thirty-tool turn would
  // otherwise charge the server sixty branch scans for a footer percentage
  // nobody reads until the turn ends.
  let running = observing(first, "first", Some("running tools"))
  let running_later = observing(second, "first", Some("running tools"))
  assert !tui.context_refresh_due(running, running_later)

  // The operation reaching `done` is the boundary the footer is read at.
  let settled = observing(second, "first", None)
  assert tui.context_refresh_due(running_later, settled)

  // A strand switch and a configuration change each stand on their own, and
  // a transition that changes none of the four starts nothing.
  assert tui.context_refresh_due(
    settled,
    tui.Model(..settled, active_strand: "fork"),
  )
  assert tui.context_refresh_due(settled, observing(second, "second", None))
  assert !tui.context_refresh_due(settled, settled)
}

pub fn an_outstanding_context_read_holds_the_shared_observation_slot_test() {
  let base = pushed.attached()
  let pending =
    tui.Model(
      ..base,
      worktree: worktree_view.request(worktree_view.new(), "owner"),
      context: waiting(8),
    )

  // Both reads borrow the same bounded server worker. An acknowledged context
  // read owns it until its final push, so the worktree request stays parked
  // rather than being refused `busy` on the wire.
  let held = tui.update(backend.Tick, pending)
  assert held.worktree.awaiting == None
  assert held.worktree.refresh == worktree_view.Requested

  let released =
    tui.update(backend.Tick, tui.Model(..pending, context: context.new()))
  assert released.worktree.awaiting != None
}
