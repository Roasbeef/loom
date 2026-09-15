//// Scrollback walks real entry ancestry through bounded sequence intervals.
//// Identical message text cannot substitute for identity, and live metadata
//// never advances or rewinds the reader's historical endpoint.

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
import tui/history_view
import tui/protocol
import tui/session_channel
import tui/snapshot
import tui/snapshot_view
import tui/transcript_anchor
import tui/workspace
import tui_test/ffi_term

fn id(seq) {
  ids.mint_entry(ids.generator(clock.fixed(1000), seq)).0
}

fn entries(count) {
  list.repeat(Nil, count)
  |> list.index_map(fn(_, index) {
    let seq = index + 1
    snapshot.Loaded(
      entry.MessageEntry(
        id(seq),
        case seq {
          1 -> None
          _ -> Some(id(seq - 1))
        },
        seq,
        1000,
        message.UserMessage(
          [message.UserText("identical message", None)],
          1000,
          None,
        ),
        False,
      ),
      100,
    )
  })
  |> list.reverse
}

fn window(items) {
  snapshot.Window(items, list.length(items) * 100, None)
}

fn view(leaf) {
  snapshot_view.View(
    [],
    dict.from_list([#("main", Some(id(leaf)))]),
    dict.new(),
    dict.new(),
    message.Usage(
      0,
      0,
      0,
      0,
      None,
      None,
      0,
      message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
    ),
    snapshot_view.RunSettings("one_at_a_time", "parallel", None),
    [],
    [],
    None,
    None,
    None,
  )
}

pub fn history_walks_past_cache_capacity_without_claiming_unrelated_ancestry_test() {
  let all = entries(1200)
  let current = view(1200)
  let initial =
    history_view.capture(
      history_view.empty(),
      window(list.take(all, 100)),
      current,
      "main",
    )
  let #(finished, seen) =
    list.fold(list.repeat(Nil, 11), #(initial, []), fn(acc, _) {
      let missing = history_view.branch(acc.0, current).unloaded
      let wanted = history_view.older(acc.0, missing)
      let assert Some(#(after, before)) = history_view.range(wanted)
        as "every missing ancestor supplies one bounded older interval"
      let page =
        window(
          list.filter(all, fn(item) {
            snapshot.sequence(item) > after && snapshot.sequence(item) < before
          }),
        )
      let received =
        history_view.accept(
          history_view.sent(wanted, before),
          page,
          before,
          after,
          current,
        )
      let branch = history_view.branch(received, current)
      assert list.length(received.window.items) <= 600
      assert received.window.bytes <= 16 * 1024 * 1024
      assert list.all(branch.records, fn(record) { record.strand == "main" })
      #(
        received,
        list.append(
          acc.1,
          list.map(branch.records, fn(record) { record.entry.seq }),
        ),
      )
    })
  let final = history_view.branch(finished, current)
  assert final.unloaded == None
  assert list.last(final.records)
    |> fn(result) {
      let assert Ok(record) = result
        as "the root remains present after eleven pages"
      record.entry.seq == 1
    }
  assert list.contains(seen, 1)
  assert list.contains(seen, 1199)
  assert history_view.range(history_view.older(finished, final.unloaded))
    == None
}

pub fn history_frozen_endpoint_survives_live_cuts_and_ignores_late_pages_test() {
  let all = entries(230)
  let old = view(200)
  let initial =
    history_view.capture(
      history_view.empty(),
      window(list.drop(all, 30) |> list.take(100)),
      old,
      "main",
    )
  let reading = history_view.freeze(initial)
  let fresh =
    history_view.capture(
      reading,
      window(list.take(all, 100)),
      view(230),
      "main",
    )
  assert fresh == reading
  assert list.first(history_view.branch(fresh, view(230)).records)
    |> fn(result) {
      let assert Ok(record) = result
        as "fresh metadata must not move the reading endpoint"
      record.entry.seq == 200
    }
  let wanted = history_view.older(fresh, Some("parent"))
  let assert Some(#(after, before)) = history_view.range(wanted)
    as "older range exists"
  let pending = history_view.sent(wanted, before)
  let switched =
    history_view.capture(
      pending,
      window(list.take(all, 100)),
      view(230),
      "reviewer",
    )
  assert switched.mode == history_view.Live
  assert history_view.accept(switched, window(all), before, after, old)
    == switched
  assert history_view.accept(pending, window(all), before + 1, after, old)
    == pending
}

pub fn history_unrelated_sequences_do_not_fill_a_missing_parent_test() {
  let all = entries(30)
  let state =
    history_view.capture(
      history_view.empty(),
      window(list.take(all, 1)),
      view(30),
      "main",
    )
  let wanted = history_view.older(state, Some("parent"))
  let received =
    history_view.accept(
      history_view.sent(wanted, 30),
      window(list.drop(all, 25)),
      30,
      0,
      view(30),
    )
  let branch = history_view.branch(received, view(30))
  assert list.length(branch.records) == 1
  assert branch.unloaded == Some(ids.entry_id_to_string(id(29)))
}

pub fn transcript_anchor_tracks_identity_when_older_and_newer_rows_arrive_test() {
  let row = fn(id, wrapped) { Some(transcript_anchor.Row(id, 0, wrapped)) }
  let prior = [
    row("third", 0),
    row("second", 1),
    row("second", 0),
    row("first", 0),
  ]
  let older = list.append(prior, [row("older", 0)])
  assert transcript_anchor.relocate(prior, older, 1, 2, 0, 0) == Some(1)
  let newer = [row("fourth", 0), ..older]
  assert transcript_anchor.relocate(prior, newer, 1, 2, 0, 0) == Some(2)
  let wrapped = [
    row("third", 0),
    row("second", 2),
    row("second", 1),
    row("second", 0),
    row("first", 0),
  ]
  assert transcript_anchor.relocate(prior, wrapped, 1, 2, 0, 0) == Some(2)
}

pub fn history_sparse_strand_keeps_endpoint_across_unrelated_pages_test() {
  let all = entries(1200)
  let assert [snapshot.Loaded(entry.MessageEntry(..) as leaf, size), ..rest] =
    all
    as "the fixture has a newest message"
  let all = [
    snapshot.Loaded(entry.MessageEntry(..leaf, parent: Some(id(1))), size),
    ..rest
  ]
  let current = view(1200)
  let initial =
    history_view.capture(
      history_view.empty(),
      window(list.take(all, 100)),
      current,
      "main",
    )
  let finished =
    list.fold(list.repeat(Nil, 11), initial, fn(state, _) {
      let wanted =
        history_view.older(state, history_view.branch(state, current).unloaded)
      let assert Some(#(after, before)) = history_view.range(wanted)
        as "unrelated entries cannot retire the missing ancestor"
      let page =
        window(
          list.filter(all, fn(item) {
            snapshot.sequence(item) > after && snapshot.sequence(item) < before
          }),
        )
      history_view.accept(
        history_view.sent(wanted, before),
        page,
        before,
        after,
        current,
      )
    })
  let branch = history_view.branch(finished, current)
  assert list.map(branch.records, fn(record) { record.entry.seq }) == [1200, 1]
  assert branch.unloaded == None
}

fn top_identity(model: tui.Model) {
  let prefix = model.rendered_row_count - list.length(model.rendered_anchors)
  let height = tui.hit_area(model, geometry.Position(5, 5)).size.height
  model.rendered_anchors
  |> list.index_map(fn(row, index) { #(row, prefix + index) })
  |> list.filter(fn(pair) {
    pair.1 >= model.scroll_offset && pair.1 < model.scroll_offset + height
  })
  |> list.reverse
  |> list.find_map(fn(pair) {
    case pair.0 {
      Some(row) -> Ok(row.entry)
      None -> Error(Nil)
    }
  })
}

pub fn history_pages_and_live_cuts_preserve_the_visible_message_in_the_tui_test() {
  let all = entries(250)
  let current = view(230)
  let recent = window(list.drop(all, 20) |> list.take(100))
  let cut =
    snapshot.Captured(
      snapshot.Attachment(
        snapshot.Expected("session", "epoch", "incarnation"),
        "connection",
        message.Origin("owner", "Owner"),
        snapshot.Owner,
      ),
      231,
      json.Object([]),
      recent,
      Some(131),
    )
  let base =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("/work", None),
      fn() { 0 },
    )
    |> tui.apply_channel_update(session_channel.Captured(
      cut,
      current,
      session_channel.Requested,
    ))
    |> fn(model) { tui.update(backend.Resize(80, 24), model) }
  let reading =
    list.fold(list.repeat(Nil, 40), base, fn(model, _) {
      tui.update(backend.MouseScroll(5, 5, True), model)
    })
  let anchor = top_identity(reading)
  let assert Ok(_) = anchor as "the fixture scrolls into a durable message"
  let pending =
    tui.Model(..reading, scrollback: history_view.sent(reading.scrollback, 131))
  let page =
    window(
      list.filter(all, fn(item) {
        snapshot.sequence(item) > 30 && snapshot.sequence(item) < 131
      }),
    )
  let expanded =
    tui.apply_channel_update(
      pending,
      session_channel.HistoryPage(page, 131, 30),
    )
    |> fn(model) { tui.update(backend.Tick, model) }
  assert list.length(expanded.records) == 200
  assert top_identity(expanded) == anchor
  let latest =
    snapshot.Captured(..cut, next_seq: 251, window: window(list.take(all, 100)))
  let arrived =
    tui.apply_channel_update(
      expanded,
      session_channel.Captured(latest, view(250), session_channel.Notified),
    )
    |> fn(model) { tui.update(backend.Tick, model) }
  assert top_identity(arrived) == anchor
  assert arrived.captured == Some(#(latest, view(250)))
  let resumed = tui.update(backend.KeyPress("end"), arrived)
  assert resumed.scroll_offset == 0
  assert resumed.scrollback.mode == history_view.Live
  let assert Ok(newest) = list.first(resumed.records)
    as "returning to live uses the latest cut"
  assert newest.entry.seq == 250
}

pub fn retained_page_suffix_does_not_skip_evicted_ancestors_test() {
  let all = entries(20)
  let current = view(20)
  let initial =
    history_view.capture(
      history_view.empty(),
      window(list.take(all, 10)),
      current,
      "main",
    )
    |> history_view.freeze
    |> history_view.sent(11)
  let suffix =
    snapshot.Window(
      list.filter(all, fn(item) {
        snapshot.sequence(item) >= 4 && snapshot.sequence(item) <= 10
      }),
      700,
      Some(3),
    )
  let accepted = history_view.accept(initial, suffix, 11, 0, current)
  assert accepted.before_seq == 4
  let wanted =
    history_view.older(
      accepted,
      history_view.branch(accepted, current).unloaded,
    )
  assert history_view.range(wanted) == Some(#(0, 4))
  let completed =
    history_view.accept(
      history_view.sent(wanted, 4),
      window(list.filter(all, fn(item) { snapshot.sequence(item) <= 3 })),
      4,
      0,
      current,
    )
  assert history_view.branch(completed, current).unloaded == None
}

fn captured_window(items, leaf, next) {
  snapshot.Captured(
    snapshot.Attachment(
      snapshot.Expected("session", "epoch", "incarnation"),
      "connection",
      message.Origin("owner", "Owner"),
      snapshot.Owner,
    ),
    next,
    json.Object([]),
    window(items),
    Some(leaf),
  )
}

fn frozen_history() {
  let current = view(200)
  let assert [snapshot.Loaded(entry.MessageEntry(..) as newest, bytes), ..rest] =
    entries(200)
    as "the fixture has a newest message to make detail-sensitive"
  let detailed =
    message.AssistantMessage(
      content: [
        message.AssistantText(
          string.repeat("This paragraph must wrap at the narrower width. ", 8),
          None,
        ),
        message.AssistantThinking(
          string.repeat("A separate reasoning line.\n", 8),
          None,
          False,
        ),
      ],
      api: "messages",
      provider: "fixture",
      model: "fixture",
      response_model: None,
      response_id: None,
      diagnostics: None,
      usage: current.usage,
      stop_reason: message.Stop,
      deferred: None,
      error_message: None,
      raw_stop_reason: None,
      end_turn: None,
      timestamp: 1000,
    )
  let cut =
    captured_window(
      [
        snapshot.Loaded(entry.MessageEntry(..newest, message: detailed), bytes),
        ..rest
      ],
      1,
      201,
    )
  let reading =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("/work", None),
      fn() { 0 },
    )
    |> tui.apply_channel_update(session_channel.Captured(
      cut,
      current,
      session_channel.Requested,
    ))
    |> tui.update(backend.Resize(272, 84), _)
    |> tui.update(backend.MouseScroll(5, 5, True), _)
  assert !list.is_empty(reading.rendered_anchors)
    as "the workload must have frozen durable anchors"
  #(cut, current, reading)
}

pub fn metadata_refresh_reuses_frozen_history_anchors_test() {
  let #(cut, current, reading) = frozen_history()

  // A metadata-only capture still refreshes the footer and transport state.
  // Its unchanged ancestry must not re-project every message to recover the
  // same scroll anchors; equal text alone would miss that repeated work.
  let refreshed =
    reading
    |> tui.apply_channel_update(session_channel.Captured(
      snapshot.Captured(
        ..cut,
        metadata: json.Object([#("revision", json.Int(1))]),
      ),
      current,
      session_channel.Refreshed,
    ))
    |> tui.update(backend.Tick, _)
  assert refreshed.rendered_rows == reading.rendered_rows
  assert refreshed.scroll_offset == reading.scroll_offset
  assert ffi_term.same_term(reading.record_rows, refreshed.record_rows)
    as "the durable row cache stays valid across metadata-only refreshes"
  assert ffi_term.same_term(
    reading.rendered_anchors,
    refreshed.rendered_anchors,
  )
    as "unchanged durable rows must retain their existing source anchors"
}

pub fn streamed_output_reuses_frozen_history_anchors_test() {
  let #(_, _, reading) = frozen_history()
  let streamed =
    reading
    |> tui.apply_channel_update(session_channel.Streamed(
      "main",
      "operation",
      "generation",
      "text",
      "Output arriving below the reader.",
    ))
    |> tui.update(backend.Tick, _)
  assert streamed.streams != reading.streams
    as "live output must still be consumed while reading history"
  assert streamed.render_revision > reading.render_revision
    as "the test must reach a transcript refresh"
  assert streamed.rendered_rows == reading.rendered_rows
  assert streamed.scroll_offset == reading.scroll_offset
  assert ffi_term.same_term(reading.rendered_anchors, streamed.rendered_anchors)
    as "live fragments cannot rebuild the unchanged durable anchor projection"
}

pub fn cached_anchors_match_fresh_anchors_after_layout_changes_test() {
  let #(_, _, reading) = frozen_history()
  let _ =
    list.fold(
      [
        backend.Resize(50, 24),
        backend.KeyPress("ctrl+g"),
        backend.Paste("/help"),
        backend.KeyPress("enter"),
        backend.KeyPress("esc"),
        backend.MouseScroll(5, 5, True),
        backend.Resize(272, 84),
      ],
      reading,
      fn(model, event) {
        let changed = tui.update(event, model)
        case event {
          backend.Resize(..) | backend.KeyPress("ctrl+g") -> {
            assert changed.rendered_anchors != model.rendered_anchors
              as "reflow and expansion must change durable anchors in this fixture"
          }
          backend.KeyPress("enter") -> {
            assert changed.help_open
            assert changed.rendered_anchors == []
          }
          backend.KeyPress("esc") -> {
            assert !changed.help_open
          }
          _ -> Nil
        }

        // The control discards both record hints and anchor hints. Comparing
        // identities as well as rows catches an old anchor retained after a
        // reflow, a detail toggle, or a surface with no durable provenance.
        let fresh =
          tui.Model(
            ..changed,
            record_cache_valid: False,
            rendered_revision: -1,
            rendered_anchors: [],
          )
          |> tui.update(backend.Resize(changed.width, changed.height), _)
        assert changed.rendered_rows == fresh.rendered_rows
        assert changed.rendered_anchors == fresh.rendered_anchors
        changed
      },
    )
}

pub fn short_frozen_history_keeps_return_to_live_available_at_zero_offset_test() {
  let first = captured_window(list.take(entries(10), 5), 6, 11)
  let initial =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("/work", None),
      fn() { 0 },
    )
    |> tui.apply_channel_update(session_channel.Captured(
      first,
      view(10),
      session_channel.Requested,
    ))
    |> tui.update(backend.Resize(170, 104), _)
  let reading = tui.update(backend.MouseScroll(5, 5, True), initial)
  assert reading.scroll_offset == 0
    as "the loaded compact history is shorter than the video viewport"
  assert reading.scrollback.mode == history_view.Reading
  assert reading.reading_lines != None
    as "zero offset cannot silently unfreeze the live preview"
  let later = captured_window(list.take(entries(11), 5), 7, 12)
  let waiting =
    tui.apply_channel_update(
      reading,
      session_channel.Captured(later, view(11), session_channel.Refreshed),
    )
    |> tui.update(backend.Tick, _)
  assert list.map(waiting.records, fn(record) { record.entry.seq })
    == [10, 9, 8, 7, 6]
  let resumed = tui.update(backend.KeyPress("end"), waiting)
  assert resumed.scrollback.mode == history_view.Live
  assert resumed.reading_lines == None
  assert list.any(resumed.records, fn(record) { record.entry.seq == 11 })
}

pub fn unrelated_history_pages_continue_until_visible_ancestry_arrives_test() {
  let all = entries(1200)
  let assert [snapshot.Loaded(entry.MessageEntry(..) as leaf, size), ..rest] =
    all
    as "the fixture has a newest message"
  let all = [
    snapshot.Loaded(entry.MessageEntry(..leaf, parent: Some(id(1))), size),
    ..rest
  ]
  let cut = captured_window(list.take(all, 100), 1101, 1201)
  let initial =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("/work", None),
      fn() { 0 },
    )
    |> tui.apply_channel_update(session_channel.Captured(
      cut,
      view(1200),
      session_channel.Requested,
    ))
    |> tui.update(backend.Resize(170, 104), _)
    |> tui.update(backend.MouseScroll(5, 5, True), _)
  let finished =
    list.fold(list.repeat(Nil, 11), initial, fn(model, _) {
      let assert Some(#(after, before)) = history_view.range(model.scrollback)
        as "one wheel gesture keeps demand alive across unrelated sequence pages"
      let pending =
        tui.Model(
          ..model,
          scrollback: history_view.sent(model.scrollback, before),
        )
      let page =
        window(
          list.filter(all, fn(item) {
            snapshot.sequence(item) > after && snapshot.sequence(item) < before
          }),
        )
      tui.apply_channel_update(
        pending,
        session_channel.HistoryPage(page, before, after),
      )
      |> tui.update(backend.Tick, _)
    })
  assert list.map(finished.records, fn(record) { record.entry.seq })
    == [1200, 1]
  assert finished.scrollback.request == history_view.Quiet
}

// The strand-switch fixture below needs two real ancestry chains sharing one
// global sequence space, because the defect it pins is a size difference: the
// cut window holds the newest hundred records of the whole session, while
// scrollback holds up to six hundred of one strand's proved ancestry.

/// Parent of one interleaved fixture entry, within its own strand's chain.
///
/// Every twentieth sequence starting at one belongs to `main`; the rest form
/// a second chain. Neither chain is the other's ancestor, so a projection of
/// one strand cannot borrow the other's entries to fill a missing parent.
fn interleaved_parent(seq: Int) -> option.Option(Int) {
  case seq % 20 == 1 {
    True ->
      case seq > 20 {
        True -> Some(seq - 20)
        False -> None
      }
    False -> {
      let previous = case { seq - 1 } % 20 == 1 {
        True -> seq - 2
        False -> seq - 1
      }
      case previous >= 2 {
        True -> Some(previous)
        False -> None
      }
    }
  }
}

fn interleaved(count) {
  list.repeat(Nil, count)
  |> list.index_map(fn(_, index) {
    let seq = index + 1
    snapshot.Loaded(
      entry.MessageEntry(
        id(seq),
        option.map(interleaved_parent(seq), id),
        seq,
        1000,
        message.UserMessage(
          [message.UserText("identical message", None)],
          1000,
          None,
        ),
        False,
      ),
      100,
    )
  })
  |> list.reverse
}

fn two_strand_view(main_leaf: Int, sub_leaf: Int) {
  snapshot_view.View(
    ..view(main_leaf),
    strands: [
      protocol.Strand("main", Some("main"), None),
      protocol.Strand("sub:reviewer", Some("reviewer"), None),
    ],
    leaves: dict.from_list([
      #("main", Some(id(main_leaf))),
      #("sub:reviewer", Some(id(sub_leaf))),
    ]),
  )
}

/// Drives one bounded older page for whatever the model currently demands.
fn deliver_page(model: tui.Model, all) {
  let assert Some(#(after, before)) = history_view.range(model.scrollback)
    as "a strand missing its parent keeps one bounded demand alive"
  let page =
    window(
      list.filter(all, fn(item) {
        snapshot.sequence(item) > after && snapshot.sequence(item) < before
      }),
    )
  tui.Model(..model, scrollback: history_view.sent(model.scrollback, before))
  |> tui.apply_channel_update(session_channel.HistoryPage(page, before, after))
  |> tui.update(backend.Tick, _)
}

/// Scrolls to the oldest retained row, which is where a demand is raised.
///
/// An accepted page adds older rows above the reading position, which leaves
/// the reader well short of the top; the next demand is only raised once the
/// reader has scrolled back to it.
fn scroll_to_top(model: tui.Model) {
  list.fold(list.repeat(Nil, 200), model, fn(model, _) {
    tui.update(backend.MouseScroll(5, 5, True), model)
  })
}

/// Types a slash command into the composer and submits it.
fn run_command(model: tui.Model, text: String) {
  string.to_graphemes(text)
  |> list.fold(model, fn(model, key) {
    tui.update(backend.KeyPress(key), model)
  })
  |> tui.update(backend.KeyPress("enter"), _)
  |> tui.update(backend.Tick, _)
}

fn two_strand_model(all, current) {
  tui.new_model_with_clock(
    connection.new_inbox(),
    workspace.Context("/work", None),
    fn() { 0 },
  )
  |> tui.apply_channel_update(session_channel.Captured(
    captured_window(list.take(all, 100), 301, 401),
    current,
    session_channel.Requested,
  ))
  |> tui.update(backend.Resize(170, 104), _)
  |> tui.update(backend.MouseScroll(5, 5, True), _)
}

pub fn switching_strands_and_back_preserves_loaded_history_test() {
  let all = interleaved(400)
  let current = two_strand_view(381, 400)
  let loaded =
    list.fold(list.repeat(Nil, 3), two_strand_model(all, current), fn(model, _) {
      deliver_page(model, all)
    })
  let full = list.length(loaded.records)
  assert history_view.branch(loaded.scrollback, current).unloaded == None
  assert full == 20
    as "three pages recover the whole main chain the cut window omitted"

  // The cut window alone projects five main entries. Anything close to that
  // after the round trip means the retained window was thrown away and the
  // transcript rebuilt from the newest hundred global records.
  let returned =
    loaded
    |> run_command("/strand sub:reviewer")
    |> run_command("/strand main")
  assert returned.active_strand == "main"
  assert list.length(returned.records) == full
  assert history_view.branch(returned.scrollback, current).unloaded == None
  assert list.first(returned.transcript)
    == Ok(tui.Line(tui.System, "Beginning of this conversation."))
  assert returned.scrollback.request == history_view.Quiet
}

pub fn returning_to_a_sub_strand_preserves_its_loaded_history_test() {
  let all = interleaved(400)
  let current = two_strand_view(381, 400)
  let visited =
    two_strand_model(all, current)
    |> run_command("/strand sub:reviewer")
  let loaded =
    list.fold(list.repeat(Nil, 3), visited, fn(model, _) {
      scroll_to_top(model) |> deliver_page(all)
    })
  let full = list.length(loaded.records)
  assert history_view.branch(loaded.scrollback, current).unloaded == None
  assert full > 300 as "the sub chain holds every sequence that is not main's"
  let returned =
    loaded
    |> run_command("/strand main")
    |> run_command("/strand sub:reviewer")
  assert returned.active_strand == "sub:reviewer"
  assert list.length(returned.records) == full
  assert history_view.branch(returned.scrollback, current).unloaded == None
}

pub fn a_retired_strand_releases_its_parked_scrollback_test() {
  let all = interleaved(400)
  let current = two_strand_view(381, 400)
  let visited =
    two_strand_model(all, current)
    |> run_command("/strand sub:reviewer")
    |> run_command("/strand main")
  assert dict.has_key(visited.parked_scrollback, "sub:reviewer")

  // A cut that no longer carries the reviewer retires it: no later switch can
  // select that strand, so its parked window is unreachable and is released
  // rather than accumulating for the life of the session.
  let alone =
    snapshot_view.View(..current, strands: [
      protocol.Strand("main", Some("main"), None),
    ])
  let retired =
    tui.apply_channel_update(
      visited,
      session_channel.Captured(
        captured_window(list.take(all, 100), 301, 402),
        alone,
        session_channel.Notified,
      ),
    )
    |> tui.update(backend.Tick, _)
  assert dict.has_key(retired.parked_scrollback, "sub:reviewer") == False
  assert dict.has_key(retired.parked_scrollback, "main") == False
    as "the active strand's window is held directly, not parked beside it"
}

pub fn history_prefetch_starts_before_the_last_ten_rows_test() {
  let initial =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("/work", None),
      fn() { 0 },
    )
    |> tui.apply_channel_update(session_channel.Captured(
      captured_window(list.take(entries(400), 100), 301, 401),
      view(400),
      session_channel.Requested,
    ))
    |> tui.update(backend.Resize(120, 24), _)
  let requested =
    list.fold(list.repeat(Nil, 200), initial, fn(model, _) {
      case model.scrollback.request {
        history_view.Quiet -> tui.update(backend.MouseScroll(5, 5, True), model)
        history_view.Wanted | history_view.Pending(_) -> model
      }
    })
  assert requested.scrollback.request == history_view.Wanted

  // The entire terminal is taller than the transcript viewport. Subtracting
  // it gives a conservative lower bound on the rows still available to read.
  assert requested.rendered_row_count - requested.scroll_offset - 24 > 10
    as "the read starts while more than the old ten-row margin remains"
  assert history_view.range(requested.scrollback) == Some(#(200, 301))
    as "earlier admission preserves the hundred-position page bound"
}
