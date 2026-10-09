//// A peer joining or leaving a live session must not move the transcript's tail.
////
//// A terminal alone in its session leaves the author label off its owner's
//// own prompts and draws it on every one of them once anyone else attaches
//// (`transcript_lines.solo_owner`). The projection therefore gains a row above
//// each prompt when another terminal or a browser page opens the session, and
//// loses them again when it leaves. The pacing walk counts every row beyond
//// the revealed ones as output still arriving, so before this was fixed a join
//// hid the last rows of the transcript and walked them back in a row a frame.
//// These fixtures drive the cut through `projection.refresh_render_cache`,
//// which is what the shipped step runs after the event that adopted it, with
//// the model from before the event as its first argument.

import core/accounting
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
import session_view/protocol
import session_view/session_channel
import session_view/snapshot
import session_view/snapshot_view
import tui
import tui/connection
import tui/frame
import tui/inbound
import tui/model as tui_model
import tui/projection
import tui/render
import tui/workspace

const prompts = 20

fn id(seq) {
  ids.mint_entry(ids.generator(clock.fixed(1000), seq)).0
}

fn owner() {
  message.Origin("owner-principal", "Owner")
}

fn local() {
  snapshot_view.Peer("local", owner(), snapshot.Owner)
}

fn remote() {
  snapshot_view.Peer(
    "remote",
    message.Origin("other", "Alice"),
    snapshot.Operator,
  )
}

fn usage() {
  accounting.zero_usage()
}

fn answer(text) {
  message.AssistantMessage(
    content: [message.AssistantText(text, None)],
    api: "messages",
    provider: "fixture",
    model: "fixture",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: usage(),
    stop_reason: message.Stop,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: None,
    timestamp: 1000,
  )
}

// Alternating owner prompts and answers, newest first, so the window ends on
// an answer and holds one prompt for each odd sequence.
fn window() {
  let items =
    list.repeat(Nil, prompts * 2)
    |> list.index_map(fn(_, index) {
      let seq = index + 1
      let body = case seq % 2 {
        1 ->
          message.UserMessage(
            [message.UserText("prompt " <> string.inspect(seq), None)],
            1000,
            Some(owner()),
          )
        _ -> answer("answer " <> string.inspect(seq))
      }
      let parent = case seq {
        1 -> None
        _ -> Some(id(seq - 1))
      }
      snapshot.Loaded(
        entry.MessageEntry(id(seq), parent, seq, 1000, body, False),
        100,
      )
    })
    |> list.reverse
  snapshot.Window(items, list.length(items) * 100, None)
}

// A running strand, so the pacing walk is armed, and the given attachments.
fn view(peers) {
  snapshot_view.View(
    [protocol.Strand("main", Some("main"), Some("working"))],
    dict.from_list([#("main", Some(id(prompts * 2)))]),
    dict.new(),
    dict.new(),
    usage(),
    snapshot_view.RunSettings("one_at_a_time", "parallel", None),
    peers,
    [],
    None,
    None,
    None,
  )
}

// The cut a daemon sends when the same history is read again. Only the
// metadata, which carries the attachments, differs between the cuts here.
fn cut(peers) {
  snapshot.Captured(
    snapshot.Attachment(
      snapshot.Expected("session", "epoch", "incarnation"),
      "local",
      owner(),
      snapshot.Owner,
    ),
    prompts * 2 + 1,
    json.Object([#("peers", json.Int(list.length(peers)))]),
    window(),
    Some(1),
  )
}

// One cut adopted by the lane, projected the way the step projects it, with
// the model from before the event as the reference.
fn adopt(before, peers) {
  inbound.apply_channel_update(
    before,
    session_channel.Captured(cut(peers), view(peers), session_channel.Notified),
  )
  |> projection.refresh_render_cache(before, _)
}

// A terminal that has been shown a running session with the given peers and
// has finished walking to the tail.
fn settled(peers) {
  let drawn =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("/work", None),
      fn() { 0 },
    )
    |> tui.update(backend.Resize(100, 30), _)
    |> inbound.apply_channel_update(session_channel.Captured(
      cut(peers),
      view(peers),
      session_channel.Refreshed,
    ))
  list.fold(list.repeat(Nil, 60), drawn, fn(model, _) {
    tui.update(backend.Tick, model)
  })
}

fn painted(model: tui_model.Model) -> String {
  render.view(
    model,
    geometry.rect_new(0, 0, model.view.width, model.view.height),
  ).0
  |> frame.buffer_to_text
}

pub fn a_peer_joining_adds_label_rows_without_holding_back_the_tail_test() {
  let alone = settled([local()])
  assert tui_model.viewport_backlog(alone) == 0
  assert string.contains(
    painted(alone),
    "answer " <> string.inspect(prompts * 2),
  )

  let joined = adopt(alone, [local(), remote()])

  // The fixture has to add rows, or a backlog of zero would prove nothing.
  assert joined.view.rendered_row_count
    == alone.view.rendered_row_count + prompts
    as "an attached peer labels each of the owner's prompts on a row of its own"
  assert tui_model.viewport_backlog(joined) == 0
    as "labels above the tail are not output waiting to be revealed"
  assert string.contains(
    painted(joined),
    "answer " <> string.inspect(prompts * 2),
  )
    as "the newest answer stays on screen through the join"
}

// A shrink was already adopted whole before attribution was considered, so
// this guards that path against the new rule and does not exercise the rule.
pub fn a_peer_leaving_keeps_the_tail_in_place_test() {
  let shared = settled([local(), remote()])
  assert tui_model.viewport_backlog(shared) == 0

  let alone = adopt(shared, [local()])
  assert alone.view.rendered_row_count
    == shared.view.rendered_row_count - prompts
  assert tui_model.viewport_backlog(alone) == 0
  assert string.contains(
    painted(alone),
    "answer " <> string.inspect(prompts * 2),
  )
}
