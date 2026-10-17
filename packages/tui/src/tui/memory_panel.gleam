//// The owner's overview of the daemon's memory (protocol-change/087).
////
//// The daemon keeps two things for a workspace that reach later runs: a
//// bounded index of the notes the agent wrote, and the rules a person
//// approved from the proposal queue. Whether a run receives the index is one
//// setting, and until now the only way to see the setting, the notes and the
//// rules was to open the files. This overlay shows them in one place,
//// read-only.
////
//// The board is not stored here. It lives in the shared session record
//// (`Shared.memory`), where the lane's reply to a read replaces it, and the
//// shared step reads it again once a minute while this overlay is open,
//// because a change to memory pushes nothing. The overlay keeps only how far
//// the reader has scrolled.
////
//// There is nothing to do here but read, so the keys are the scroll keys and
//// Escape. A note's body is not in the board; the overlay says the agent reads
//// one with `history_search kind=note`. The proposals queue has its own
//// review, and the overlay counts it and names the key that opens it.
////
//// Every string in the board is text a model wrote, or a person approved
//// after one did. The panel draws it as text, one row at a time, through
//// `session_view/text_hygiene`.
////
//// ## Flow
////
//// `update` → `max_scroll` → `render` → `body_lines`
////
//// 1. `update` turns a key into an `Action`: the next scroll place, or a
////    close.
//// 2. `max_scroll` measures the body against the panel's geometry, so paging
////    in a small terminal never skips lines a larger layout would show.
//// 3. `render` draws the frame, the body from the scroll place, and the one
////    key-hint row.
//// 4. `body_lines` lays the sections out in the order the questions are asked:
////    the counts, what each run receives, the notes, the rules, the queue and
////    where the files live.

import etui/buffer
import etui/geometry
import etui/keys
import etui/span
import etui/style
import etui/text
import etui/widgets/block
import etui/widgets/paragraph
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/memory_overview as words
import session_view/text_hygiene
import tui/theme

/// The key that opens the overview from the composer, in the words the footer
/// and the help use for it.
pub const open_key = "Alt+m"

/// What a key does to the overview.
pub type Action {
  /// Keep the overview open at this scroll place.
  Continue(state: State)

  /// Return focus to the composer.
  Close
}

/// Where the reader is in the overview.
pub opaque type State {
  State(scroll: Int)
}

/// An overview opened at its top.
///
/// ## Examples
///
/// ```gleam
/// assert memory_panel.scroll(memory_panel.new()) == 0
/// ```
pub fn new() -> State {
  State(scroll: 0)
}

/// How many lines the reader has scrolled past.
///
/// ## Examples
///
/// ```gleam
/// assert memory_panel.scroll(memory_panel.new()) == 0
/// ```
pub fn scroll(state: State) -> Int {
  state.scroll
}

/// Handles one key.
///
/// The area is the panel's actual geometry, so paging in a small terminal
/// never skips the lines a larger layout would have shown.
///
/// ## Examples
///
/// ```gleam
/// // memory_panel.update(keys.Down, memory_panel.new(), board, area)
/// ```
pub fn update(
  key: keys.Key,
  state: State,
  board: Option(words.Board),
  area: geometry.Rect,
) -> Action {
  let step = int.max(1, viewport_rows(area) - 1)
  let maximum = max_scroll(board, area)
  let here = int.min(state.scroll, maximum)
  case key {
    keys.Escape -> Close
    keys.Up -> Continue(State(scroll: int.max(0, here - 1)))
    keys.Down -> Continue(State(scroll: int.min(maximum, here + 1)))
    keys.PageUp -> Continue(State(scroll: int.max(0, here - step)))
    keys.PageDown -> Continue(State(scroll: int.min(maximum, here + step)))
    keys.Home -> Continue(State(scroll: 0))
    keys.End -> Continue(State(scroll: maximum))
    _ -> Continue(State(scroll: here))
  }
}

/// Renders the overview over the conversation.
///
/// `notice` is the last refusal's words, empty when there is none.
///
/// ## Examples
///
/// ```gleam
/// // memory_panel.render(buffer, body, state, board, "")
/// ```
pub fn render(
  buf: buffer.Buffer,
  area: geometry.Rect,
  state: State,
  board: Option(words.Board),
  notice: String,
) -> buffer.Buffer {
  use <- bool.guard(area.size.width <= 0 || area.size.height <= 0, buf)
  let #(card, content, controls) = layout_areas(area)
  let frame =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.current, theme.graphite)
    |> block.with_bg_fill
    |> block.with_title(" Memory · Esc back ", block.Top)
  let rows = body_lines(board, notice, int.max(1, content.size.width))
  let maximum = int.max(0, list.length(rows) - content.size.height)
  let cleared = buf |> buffer.clear(area)
  let framed = case card.size.height >= 8 && card.size.width >= 20 {
    True -> block.render(cleared, card, frame)
    False -> cleared
  }
  framed
  |> paragraph.render_styled(
    content,
    list.drop(rows, int.min(maximum, state.scroll)),
  )
  |> paragraph.render_styled(controls, [
    span.line_new([
      span.span_styled(
        text.truncate(
          "↑/↓ PgUp/PgDn scroll · Home/End · Esc back",
          controls.size.width,
          "…",
        ),
        theme.overlay_signal(),
      ),
    ]),
  ])
}

// The frame's inside, split into the body and the one key-hint row beneath
// it. A terminal too small for a frame keeps the body and the row and drops
// the border, as the proposals review does.
fn layout_areas(
  area: geometry.Rect,
) -> #(geometry.Rect, geometry.Rect, geometry.Rect) {
  let framed = area.size.height >= 8 && area.size.width >= 20
  let horizontal = case framed && area.size.width >= 70 {
    True -> 2
    False -> 0
  }
  let card =
    geometry.rect_new(
      area.position.x + horizontal,
      area.position.y,
      int.max(1, area.size.width - horizontal * 2),
      area.size.height,
    )
  let inside = case framed {
    True ->
      block.inner(card, block.block_new() |> block.with_border(block.Rounded))
    False -> card
  }
  let controls_height = case inside.size.height >= 3 {
    True -> 1
    False -> 0
  }
  let content =
    geometry.rect_new(
      inside.position.x,
      inside.position.y,
      inside.size.width,
      int.max(1, inside.size.height - controls_height),
    )
  let controls =
    geometry.rect_new(
      inside.position.x,
      inside.position.y + content.size.height,
      inside.size.width,
      controls_height,
    )
  #(card, content, controls)
}

fn viewport_rows(area: geometry.Rect) -> Int {
  let #(_, content, _) = layout_areas(area)
  content.size.height
}

fn max_scroll(board: Option(words.Board), area: geometry.Rect) -> Int {
  let #(_, content, _) = layout_areas(area)
  int.max(
    0,
    list.length(body_lines(board, "", int.max(1, content.size.width)))
      - content.size.height,
  )
}

// The body, from the top: the refusal if there was one, then the sections.
fn body_lines(
  board: Option(words.Board),
  notice: String,
  width: Int,
) -> List(span.Line) {
  let lead = case notice {
    "" -> []
    words ->
      wrapped(text_hygiene.single_line(words), theme.overlay_signal(), width)
  }
  case board {
    None ->
      list.append(
        lead,
        wrapped(words.loading_words, theme.overlay_quiet(), width),
      )
    Some(board) -> list.append(lead, sections(board, width))
  }
}

fn sections(board: words.Board, width: Int) -> List(span.Line) {
  list.flatten([
    [counts_line(board, width)],
    [blank(), heading("What each run receives", width)],
    receives_lines(board, width),
    [blank(), heading("Notes", width)],
    notes_lines(board.notes, width),
    [blank(), heading("Approved rules", width)],
    rules_lines(board.rules, width),
    [blank(), heading("Proposals", width)],
    wrapped(
      words.proposals_words(board.proposals, "Alt+p"),
      theme.overlay_plain(),
      width,
    ),
    [blank()],
    wrapped(words.files_words, theme.overlay_quiet(), width),
  ])
}

// The four counts on one row, as a label and its value each.
fn counts_line(board: words.Board, width: Int) -> span.Line {
  let tiles =
    words.tiles(board)
    |> list.map(fn(tile) { tile.0 <> " " <> tile.1 })
    |> string.join(" · ")
  span.line_new([
    span.span_styled(text.truncate(tiles, width, "…"), theme.overlay_current()),
  ])
}

fn receives_lines(board: words.Board, width: Int) -> List(span.Line) {
  list.flatten([
    wrapped(words.inject_words(board), theme.overlay_plain(), width),
    wrapped(words.config_words, theme.overlay_quiet(), width),
    list.flat_map(board.receives, fn(file) {
      let appearance = case file.reach {
        words.Injected -> theme.overlay_plain()
        words.NotInjected
        | words.Missing
        | words.Unreadable(..)
        | words.UnknownReach(..) -> theme.overlay_quiet()
      }
      wrapped(words.receives_words(file), appearance, width)
    }),
  ])
}

fn notes_lines(
  section: words.Section(words.Note),
  width: Int,
) -> List(span.Line) {
  case section {
    words.Unavailable(reason:) ->
      wrapped("Notes unavailable: " <> reason, theme.overlay_signal(), width)
    words.Listed(rows: [], ..) ->
      wrapped(words.notes_empty_words, theme.overlay_plain(), width)
    words.Listed(rows:, omitted:, ..) ->
      list.flatten([
        list.map(rows, fn(note) { note_line(note, width) }),
        omitted_lines(omitted, words.notes_pointer, width),
        wrapped(words.body_words, theme.overlay_quiet(), width),
      ])
  }
}

// One note on one line: its kind and date, a mark when it is legacy, and its
// title with its description. The line is cut to the width and never
// wrapped, so a note stays one row.
fn note_line(note: words.Note, width: Int) -> span.Line {
  let appearance = case note.typing {
    words.Typed -> theme.overlay_plain()
    words.Legacy -> theme.overlay_quiet()
  }
  span.line_new([
    span.span_styled(
      text.truncate(
        "  " <> words.note_head(note) <> "  " <> words.note_text(note),
        width,
        "…",
      ),
      appearance,
    ),
  ])
}

fn rules_lines(
  section: words.Section(words.Rule),
  width: Int,
) -> List(span.Line) {
  case section {
    words.Unavailable(reason:) ->
      wrapped(
        "Approved rules unavailable: " <> reason,
        theme.overlay_signal(),
        width,
      )
    words.Listed(rows: [], ..) ->
      wrapped(words.rules_empty_words, theme.overlay_plain(), width)
    words.Listed(rows:, omitted:, ..) ->
      list.append(
        list.flat_map(rows, fn(rule) { rule_lines(rule, width) }),
        omitted_lines(omitted, words.rules_pointer, width),
      )
  }
}

// A rule is its origin, then its first line beneath.
fn rule_lines(rule: words.Rule, width: Int) -> List(span.Line) {
  let origin =
    span.line_new([
      span.span_styled(
        text.truncate("  " <> words.rule_head(rule), width, "…"),
        theme.overlay_quiet(),
      ),
    ])
  case rule.line {
    "" -> [origin]
    line -> [
      origin,
      span.line_new([
        span.span_styled(
          text.truncate("    " <> line, width, "…"),
          theme.overlay_plain(),
        ),
      ]),
    ]
  }
}

fn omitted_lines(omitted: Int, pointer: String, width: Int) -> List(span.Line) {
  case words.omitted_words(omitted, pointer) {
    "" -> []
    sentence -> wrapped(sentence, theme.overlay_quiet(), width)
  }
}

fn blank() -> span.Line {
  span.line_new([])
}

fn heading(label: String, width: Int) -> span.Line {
  span.line_new([
    span.span_styled(text.truncate(label, width, "…"), theme.overlay_current()),
  ])
}

fn wrapped(
  words: String,
  appearance: style.Style,
  width: Int,
) -> List(span.Line) {
  text_hygiene.multiline(words)
  |> string.split("\n")
  |> list.map(fn(line) { span.line_new([span.span_styled(line, appearance)]) })
  |> span.text_new
  |> span.wrap(width)
  |> fn(done) { done.lines }
}
