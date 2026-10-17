//// The owner's overview of the daemon's memory (protocol-change/087): how it
//// draws with no rows, one row and many, what a key does, the legacy mark,
//// the refusal for a terminal that is not the owner's, and the shared step's
//// once-a-minute read while the overlay is open.

import core/json
import etui/backend
import etui/buffer
import etui/geometry
import etui/keys
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/memory_overview as words
import session_view/model as session_model
import session_view/msg
import session_view/protocol
import session_view/session_channel
import session_view/shared_set
import session_view/surfaces
import session_view/worktree_view
import tui
import tui/connection
import tui/frame
import tui/inbound
import tui/memory_panel
import tui/model as tui_model
import tui/render
import tui/tick
import tui/view_set
import tui/workspace
import tui_test/pushed

fn file(name: String, state: String, bytes: Int) -> json.JsonValue {
  json.Object([
    #("file", json.String(name)),
    #("state", json.String(state)),
    #("bytes", json.Int(bytes)),
  ])
}

fn note(title: String, legacy: Bool) -> json.JsonValue {
  json.Object([
    #("kind", json.String("fact")),
    #("date", json.String("2026-10-11")),
    #("title", json.String(title)),
    #("description", json.String("one line")),
    #("legacy", json.Bool(legacy)),
  ])
}

fn rule(id: String, line: String) -> json.JsonValue {
  json.Object([
    #("id", json.String(id)),
    #("approved", json.String("2026-10-09")),
    #("session", json.String("0198c0de-0000-7000-8000-000000000001")),
    #("line", json.String(line)),
  ])
}

fn ok(total: Int, omitted: Int, rows: List(json.JsonValue)) -> json.JsonValue {
  json.Object([
    #("state", json.String("ok")),
    #("total", json.Int(total)),
    #("omitted", json.Int(omitted)),
    #("rows", json.Array(rows)),
  ])
}

fn board_of(
  notes: json.JsonValue,
  rules: json.JsonValue,
  pending: Int,
) -> words.Board {
  let assert Ok(decoded) =
    words.decode(
      json.Object([
        #("inject", json.String("notes")),
        #(
          "receives",
          json.Array([
            file("loom-rules.md", "injected", 900),
            file("loom-memory.notes", "injected", 112),
          ]),
        ),
        #("notes", notes),
        #("rules", rules),
        #(
          "proposals",
          json.Object([
            #("state", json.String("ok")),
            #("pending", json.Int(pending)),
          ]),
        ),
      ]),
    )
  decoded
}

// Three notes, one of them legacy, and two rules.
fn typical() -> words.Board {
  board_of(
    ok(3, 0, [
      note("Use tabs", False),
      note("old words from before types", True),
      note("Prefer small commits", False),
    ]),
    ok(2, 0, [
      rule("prop-0000000002", "Never touch vendor/."),
      rule("prop-0000000001", "Run make check before pushing."),
    ]),
    1,
  )
}

fn empty() -> words.Board {
  board_of(ok(0, 0, []), ok(0, 0, []), 0)
}

fn area() -> geometry.Rect {
  geometry.rect_new(0, 0, 100, 40)
}

fn paint(
  state: memory_panel.State,
  board: Option(words.Board),
  notice: String,
) -> String {
  buffer.buffer_new(area())
  |> memory_panel.render(area(), state, board, notice)
  |> frame.buffer_to_text
}

fn press(
  state: memory_panel.State,
  board: Option(words.Board),
  key: keys.Key,
  within: geometry.Rect,
) -> memory_panel.Action {
  memory_panel.update(key, state, board, within)
}

fn next(action: memory_panel.Action) -> memory_panel.State {
  let assert memory_panel.Continue(state) = action
  state
}

pub fn the_overview_shows_every_section_with_its_facts_test() {
  let text = paint(memory_panel.new(), Some(typical()), "")
  assert string.contains(text, " Memory · Esc back ")
  assert string.contains(text, "notes 3 · approved rules 2")
  assert string.contains(text, "pending proposals 1")
  assert string.contains(text, "injected 1012 B")
  assert string.contains(text, "What each run receives")
  assert string.contains(text, "[memory] inject = notes")
  assert string.contains(text, "loom-rules.md (approved rules) · 900 B")
  assert string.contains(text, "loom-memory.notes (notes index) · 112 B")
  assert string.contains(text, "fact · 2026-10-11  Use tabs: one line")
  assert string.contains(text, "Approved rules")
  assert string.contains(
    text,
    "prop-0000000002 · approved 2026-10-09 · session 0198c0de",
  )
  assert string.contains(text, "Run make check before pushing.")
  assert string.contains(text, "1 proposal pending. Review it with Alt+p.")
  assert string.contains(text, "loom-memory.notes (the notes index)")
  assert string.contains(text, "history_search kind=note")
}

pub fn a_legacy_note_is_marked_and_a_typed_one_is_not_test() {
  let text = paint(memory_panel.new(), Some(typical()), "")
  assert string.contains(text, "fact · 2026-10-11 · legacy  old words")
  assert !string.contains(text, "Use tabs: one line · legacy")
}

pub fn an_empty_board_says_so_in_each_section_test() {
  let text = paint(memory_panel.new(), Some(empty()), "")
  assert string.contains(
    text,
    "No notes yet. The agent writes one when it learns something worth keeping.",
  )
  assert string.contains(text, "No approved rules.")
  assert string.contains(text, "notes 0 · approved rules 0")
}

pub fn a_section_that_could_not_be_read_is_not_drawn_as_empty_test() {
  let broken =
    board_of(
      json.Object([
        #("state", json.String("unavailable")),
        #("reason", json.String("the store is damaged")),
      ]),
      ok(0, 0, []),
      0,
    )
  let text = paint(memory_panel.new(), Some(broken), "")
  assert string.contains(text, "Notes unavailable: the store is damaged")
  assert !string.contains(text, "No notes yet")
  assert string.contains(text, "notes unavailable")
}

pub fn rows_the_board_left_out_are_counted_test() {
  let cut =
    board_of(ok(60, 10, list.repeat(note("n", False), 50)), ok(0, 0, []), 0)
  // Fifty rows are longer than the panel, so the reader scrolls to the end.
  let end = next(press(memory_panel.new(), Some(cut), keys.End, area()))
  let text = paint(end, Some(cut), "")
  assert string.contains(
    text,
    "+10 more not shown; history_search kind=note finds them",
  )
}

pub fn an_unread_board_is_loading_and_a_refusal_is_worded_test() {
  assert string.contains(
    paint(memory_panel.new(), None, ""),
    words.loading_words,
  )
  let refused =
    paint(memory_panel.new(), None, words.refusal_words("forbidden", ""))
  assert string.contains(refused, "Only the daemon's owner can read the memory")
}

pub fn the_arrow_and_page_keys_scroll_and_stop_at_each_end_test() {
  // A short panel, so the body is longer than the screen.
  let short = geometry.rect_new(0, 0, 100, 12)
  let board = Some(typical())
  let down = next(press(memory_panel.new(), board, keys.Down, short))
  assert memory_panel.scroll(down) == 1
  let up = next(press(down, board, keys.Up, short))
  assert memory_panel.scroll(up) == 0
  let still = next(press(memory_panel.new(), board, keys.Up, short))
  assert memory_panel.scroll(still) == 0
  let end = next(press(memory_panel.new(), board, keys.End, short))
  let beyond = next(press(end, board, keys.Down, short))
  assert memory_panel.scroll(beyond) == memory_panel.scroll(end)
  assert memory_panel.scroll(end) > 1
  let page = next(press(memory_panel.new(), board, keys.PageDown, short))
  assert memory_panel.scroll(page) > 1
  let home = next(press(end, board, keys.Home, short))
  assert memory_panel.scroll(home) == 0
}

pub fn a_scrolled_overview_draws_later_lines_and_not_the_first_test() {
  let short = geometry.rect_new(0, 0, 100, 12)
  let board = Some(typical())
  let end = next(press(memory_panel.new(), board, keys.End, short))
  let text =
    buffer.buffer_new(short)
    |> memory_panel.render(short, end, board, "")
    |> frame.buffer_to_text
  assert string.contains(text, "loom-memory.notes (the notes index)")
  assert !string.contains(text, "pending proposals 1")
}

pub fn escape_closes_and_other_keys_change_nothing_test() {
  let assert memory_panel.Close =
    press(memory_panel.new(), Some(typical()), keys.Escape, area())
  let kept =
    next(press(memory_panel.new(), Some(typical()), keys.Char("x"), area()))
  assert memory_panel.scroll(kept) == 0
}

pub fn a_hostile_title_cannot_leave_its_row_test() {
  let hostile =
    board_of(
      ok(1, 0, [note("one\u{1b}[31mtwo\nthree", False)]),
      ok(0, 0, []),
      0,
    )
  let text = paint(memory_panel.new(), Some(hostile), "")
  assert !string.contains(text, "\u{1b}")
}

// --- in the terminal's model --------------------------------------------------

fn model() -> tui_model.Model {
  tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
}

fn painted(model: tui_model.Model) -> String {
  let model = tui.update(backend.Resize(120, 40), model)
  let #(drawn, _) = render.view(model, geometry.rect_new(0, 0, 120, 40))
  frame.buffer_to_text(drawn)
}

fn arrived(model: tui_model.Model, event: protocol.Event) -> tui_model.Model {
  inbound.apply_channel_update(model, session_channel.Auxiliary(event))
}

pub fn alt_m_opens_the_overview_and_asks_for_a_fresh_board_test() {
  let opened = tui.update(backend.KeyPress("alt+m"), model())
  let assert tui_model.MemoryOverview(_) = opened.view.overlay
  assert opened.shared.memory_refresh == worktree_view.Requested
  assert string.contains(painted(opened), words.loading_words)
}

pub fn a_board_that_arrives_replaces_the_loading_words_test() {
  let opened = tui.update(backend.KeyPress("alt+m"), model())
  let shown = arrived(opened, protocol.MemorySnapshot(typical()))
  let text = painted(shown)
  assert string.contains(text, "Use tabs: one line")
  assert !string.contains(text, words.loading_words)
}

pub fn escape_closes_the_overlay_test() {
  let opened = tui.update(backend.KeyPress("alt+m"), model())
  let closed = tui.update(backend.KeyPress("esc"), opened)
  assert closed.view.overlay == tui_model.NoOverlay
}

pub fn the_arrow_keys_scroll_the_open_overview_test() {
  let opened = tui.update(backend.KeyPress("alt+m"), model())
  let shown = arrived(opened, protocol.MemorySnapshot(typical()))
  let scrolled = tui.update(backend.KeyPress("down"), shown)
  let assert tui_model.MemoryOverview(state) = scrolled.view.overlay
  assert memory_panel.scroll(state) >= 0
  let assert tui_model.MemoryOverview(_) =
    tui.update(backend.KeyPress("pagedown"), scrolled).view.overlay
}

pub fn a_refused_read_is_drawn_in_the_open_overview_test() {
  let opened = tui.update(backend.KeyPress("alt+m"), model())
  let refused =
    inbound.apply_channel_update(
      opened,
      session_channel.RequestRefused("memory_get", 4, "forbidden", "no"),
    )
  let text = painted(refused)
  assert string.contains(text, "Only the daemon's owner can read the memory")
  assert !string.contains(text, "Use tabs")
}

// --- the once-a-minute read ---------------------------------------------------

// An attached terminal whose overlay is open and whose board was last asked for
// at the start of the clock.
fn watching_at(now_ms: Int) -> tui_model.Model {
  let base = pushed.attached()
  let opened =
    tui_model.Model(
      shared: shared_set.peer(base.shared, session_model.Attached),
      view: view_set.overlay(
        base.view,
        tui_model.MemoryOverview(memory_panel.new()),
      ),
    )
  let watched = tick.watch_memory(opened)
  tui_model.Model(
    ..watched,
    shared: session_model.Shared(
      ..watched.shared
      |> shared_set.memory_refresh(worktree_view.Settled)
      |> shared_set.memory_read_ms(Some(0)),
      stamp: msg.Stamp(now_ms, now_ms),
    ),
  )
}

fn sent(model: tui_model.Model) -> Bool {
  let serviced = surfaces.service_memory_read(model.shared)
  serviced.memory_read_ms != model.shared.memory_read_ms
}

pub fn the_tick_watches_the_overview_only_while_its_overlay_is_open_test() {
  let closed = tick.watch_memory(model())
  assert closed.shared.memory_watch == session_model.NotWatchingMemory
  let opened = tick.watch_memory(tui.update(backend.KeyPress("alt+m"), model()))
  assert opened.shared.memory_watch == session_model.WatchingMemory
  let again = tick.watch_memory(tui.update(backend.KeyPress("esc"), opened))
  assert again.shared.memory_watch == session_model.NotWatchingMemory
}

pub fn an_open_overview_is_read_again_once_a_minute_and_not_before_test() {
  assert !sent(watching_at(words.backstop_ms - 1))
  assert sent(watching_at(words.backstop_ms))
}

pub fn a_closed_overview_is_never_read_on_the_backstop_test() {
  let model = watching_at(10 * words.backstop_ms)
  let unwatched =
    tui_model.Model(
      ..model,
      shared: shared_set.memory_watch(
        model.shared,
        session_model.NotWatchingMemory,
      ),
    )
  assert !sent(unwatched)
}

pub fn a_read_that_was_just_sent_is_not_sent_twice_test() {
  let model = watching_at(words.backstop_ms)
  let once = surfaces.service_memory_read(model.shared)
  assert once.memory_read_ms == Some(words.backstop_ms)
  assert once.memory_refresh == worktree_view.Settled
  let twice = surfaces.service_memory_read(once)
  assert twice.memory_read_ms == Some(words.backstop_ms)
  assert int.to_string(words.backstop_ms) == "60000"
}
