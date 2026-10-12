//// The owner's review of the standing rules a model has proposed
//// (protocol-change/086).
////
//// A model that notices a correction worth keeping queues a proposal with its
//// `propose` tool, and the daemon writes nothing until a person approves it.
//// This overlay is where the person does that. It lists the proposals newest
//// first, shows one as the exact edit it would make, in red for the removed
//// text and green for the added, and approves or rejects it.
////
//// The board is not stored here. It lives in the shared session record
//// (`Shared.proposals`), where the lane's reply to a read or a decision, and
//// the daemon's `proposals_changed` push, replace it. The overlay keeps only
//// where the reader is: which row is selected, which proposal is open, and
//// whether an approval is being confirmed. Because every draw reads the board
//// again, a decision's reply redraws the open proposal with its new state,
//// which is also how a `stale` answer reaches the reader.
////
//// Approving is two presses. The first shows what an approval does and
//// asks; only `y` sends. A rejection writes nothing and is one press. A row
//// that is no longer pending shows what became of it and offers no action,
//// and so does a row of a kind or state this client does not know. The
//// daemon decides everything, and it refuses a decision from anyone but the
//// owner, so what the overlay offers is a convenience and never the gate.
////
//// Every string in a proposal is text a model wrote. The panel draws it as
//// text, one row at a time, through `session_view/text_hygiene`.
////
//// ## Flow
////
//// `update` → `listing_key` → `reading_key` → `confirming_key` → `render` → `list_lines` → `detail_lines`
////
//// 1. `update` classifies a key by where the reader is and returns an
////    `Action`: the next state, a close, a read again or a decision.
//// 2. `listing_key` moves the selection and opens a row.
//// 3. `reading_key` scrolls the open proposal and starts a decision, offering
////    one only for a pending row (`session_view/proposals.decidable`).
//// 4. `confirming_key` sends an approval on a lowercase y and otherwise goes
////    back.
//// 5. `render` draws the frame and the control row, and `list_lines` or
////    `detail_lines` draw the body from the board and the reader's place.

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
import session_view/diff_view
import session_view/proposals
import session_view/text_hygiene
import tui/theme

/// The key that opens the review from the composer, in the words the footer
/// and the help use for it.
pub const open_key = "Alt+p"

/// What a key does to the review.
pub type Action {
  /// Keep the review open in this state.
  Continue(state: State)

  /// Return focus to the composer.
  Close

  /// Read the board again.
  Refresh

  /// Send a decision on one pending proposal.
  Decide(id: String, decision: proposals.Decision)
}

/// Where the reader is in the review.
pub opaque type State {
  State(place: Place, scroll: Int)
}

type Place {
  // The list, with the selected row's position in the board.
  Listing(selected: Int)

  // One proposal, by its identity, so a board read again between the press
  // and the draw leaves the reader on the row they opened.
  Reading(id: String)

  // The question before an approval, for the same row.
  Confirming(id: String)
}

/// A review opened on the list's first row.
///
/// ## Examples
///
/// ```gleam
/// assert proposal_panel.on_list(proposal_panel.new())
/// ```
pub fn new() -> State {
  State(place: Listing(selected: 0), scroll: 0)
}

/// Whether the reader is on the list and not inside a proposal.
///
/// ## Examples
///
/// ```gleam
/// assert proposal_panel.on_list(proposal_panel.new())
/// ```
pub fn on_list(state: State) -> Bool {
  case state.place {
    Listing(..) -> True
    Reading(..) | Confirming(..) -> False
  }
}

/// The footer's badge for the board: the pending count and the key that opens
/// the review, or nothing when no proposal waits or the board was never read.
/// A refused read leaves no board, which is how a terminal that is not the
/// owner's never shows it.
///
/// ## Examples
///
/// ```gleam
/// assert proposal_panel.badge(None) == ""
/// ```
pub fn badge(board: Option(proposals.Board)) -> String {
  case proposals.badge(board) {
    Some(pending) -> "proposals " <> int.to_string(pending) <> " · " <> open_key
    None -> ""
  }
}

/// Handles one key.
///
/// The area is the panel's actual geometry, so paging in a small terminal
/// never skips the lines a larger layout would have shown.
///
/// ## Examples
///
/// ```gleam
/// // proposal_panel.update(keys.Down, proposal_panel.new(), board, area)
/// ```
pub fn update(
  key: keys.Key,
  state: State,
  board: Option(proposals.Board),
  area: geometry.Rect,
) -> Action {
  case state.place {
    Listing(selected:) -> listing_key(key, state, board, selected)
    Reading(id:) -> reading_key(key, state, board, id, area)
    Confirming(id:) -> confirming_key(key, state, id)
  }
}

fn listing_key(
  key: keys.Key,
  state: State,
  board: Option(proposals.Board),
  selected: Int,
) -> Action {
  let rows = case board {
    Some(board) -> board.proposals
    None -> []
  }
  let last = int.max(0, list.length(rows) - 1)
  let at = int.min(selected, last)
  case key {
    keys.Escape -> Close
    keys.Char("r") -> Refresh
    keys.Up -> Continue(State(place: Listing(int.max(0, at - 1)), scroll: 0))
    keys.Down ->
      Continue(State(place: Listing(int.min(last, at + 1)), scroll: 0))
    keys.Home -> Continue(State(place: Listing(0), scroll: 0))
    keys.End -> Continue(State(place: Listing(last), scroll: 0))
    keys.Enter ->
      case list.drop(rows, at) {
        [row, ..] -> Continue(State(place: Reading(row.id), scroll: 0))
        [] -> Continue(state)
      }
    _ -> Continue(state)
  }
}

fn reading_key(
  key: keys.Key,
  state: State,
  board: Option(proposals.Board),
  id: String,
  area: geometry.Rect,
) -> Action {
  let pending = case open_row(board, id) {
    Ok(row) -> proposals.decidable(row)
    Error(Nil) -> False
  }
  let step = viewport_rows(area)
  let maximum = max_scroll(state, board, area)
  let scroll = int.min(state.scroll, maximum)
  case key {
    keys.Escape -> back_to_list(board, id)
    keys.Char("a") if pending ->
      Continue(State(place: Confirming(id), scroll: scroll))
    keys.Char("r") if pending -> Decide(id, proposals.Reject)
    keys.Up -> Continue(State(..state, scroll: int.max(0, scroll - 1)))
    keys.Down -> Continue(State(..state, scroll: int.min(maximum, scroll + 1)))
    keys.PageUp -> Continue(State(..state, scroll: int.max(0, scroll - step)))
    keys.PageDown ->
      Continue(State(..state, scroll: int.min(maximum, scroll + step)))
    keys.Home -> Continue(State(..state, scroll: 0))
    keys.End -> Continue(State(..state, scroll: maximum))
    _ -> Continue(State(..state, scroll: scroll))
  }
}

// Leaving a proposal returns to the list with that row still selected, so
// the reader who rejects one and goes back is where they were.
fn back_to_list(board: Option(proposals.Board), id: String) -> Action {
  let rows = case board {
    Some(board) -> board.proposals
    None -> []
  }
  let position =
    rows
    |> list.index_map(fn(row, index) { #(row.id, index) })
    |> list.find(fn(pair) { pair.0 == id })
  case position {
    Ok(#(_, index)) -> Continue(State(place: Listing(index), scroll: 0))
    Error(Nil) -> Continue(new())
  }
}

fn confirming_key(key: keys.Key, state: State, id: String) -> Action {
  case key {
    keys.Char("y") -> Decide(id, proposals.Approve)
    keys.Escape | keys.Char("n") ->
      Continue(State(place: Reading(id), scroll: state.scroll))
    _ -> Continue(state)
  }
}

/// The place a decision leaves the reader: back on the proposal, whose row the
/// reply will redraw with its new state.
///
/// ## Examples
///
/// ```gleam
/// // proposal_panel.after_decision(state, "prop-0123456789")
/// ```
pub fn after_decision(state: State, id: String) -> State {
  State(place: Reading(id), scroll: state.scroll)
}

fn open_row(
  board: Option(proposals.Board),
  id: String,
) -> Result(proposals.Proposal, Nil) {
  case board {
    Some(board) -> proposals.find(board, id)
    None -> Error(Nil)
  }
}

/// Renders the review over the conversation.
///
/// `notice` is the last refusal's words, empty when there is none, and `now`
/// is the wall clock in milliseconds that the ages are read against.
///
/// ## Examples
///
/// ```gleam
/// // proposal_panel.render(buffer, body, panel, board, "", now)
/// ```
pub fn render(
  buf: buffer.Buffer,
  area: geometry.Rect,
  state: State,
  board: Option(proposals.Board),
  notice: String,
  now: Int,
) -> buffer.Buffer {
  use <- bool.guard(area.size.width <= 0 || area.size.height <= 0, buf)
  let #(card, content, controls) = layout_areas(area)
  let frame =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.current, theme.graphite)
    |> block.with_bg_fill
    |> block.with_title(title(board), block.Top)
  let rows = body_lines(state, board, notice, now, content)
  let maximum = int.max(0, list.length(rows) - content.size.height)
  let offset = case state.place {
    Listing(..) ->
      list_offset(
        state,
        list.length(notice_lines(notice, int.max(1, content.size.width))),
        content.size.height,
      )
    Reading(..) | Confirming(..) -> int.min(maximum, state.scroll)
  }
  let cleared = buf |> buffer.clear(area)
  let framed = case card.size.height >= 8 && card.size.width >= 20 {
    True -> block.render(cleared, card, frame)
    False -> cleared
  }
  framed
  |> paragraph.render_styled(content, list.drop(rows, offset))
  |> paragraph.render_styled(controls, [
    control_line(state, board, controls.size.width),
  ])
}

fn title(board: Option(proposals.Board)) -> String {
  case board {
    Some(board) ->
      " Proposals · " <> proposals.summary(board.pending) <> " · Esc back "
    None -> " Proposals · Esc back "
  }
}

// The frame's inside, split into the body and the one control row beneath it.
// A terminal too small for a frame keeps the body and the row and drops the
// border, as the goal inspector does.
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

fn max_scroll(
  state: State,
  board: Option(proposals.Board),
  area: geometry.Rect,
) -> Int {
  let #(_, content, _) = layout_areas(area)
  int.max(
    0,
    list.length(body_lines(state, board, "", 0, content)) - content.size.height,
  )
}

// The list scrolls to keep the selected row on screen, and only then. The
// refusal's lines sit above the first row, so they count against the height.
fn list_offset(state: State, lead: Int, height: Int) -> Int {
  case state.place {
    Listing(selected:) -> int.max(0, lead + selected + 1 - height)
    Reading(..) | Confirming(..) -> 0
  }
}

fn notice_lines(notice: String, width: Int) -> List(span.Line) {
  case notice {
    "" -> []
    words ->
      wrapped(text_hygiene.single_line(words), theme.overlay_signal(), width)
  }
}

fn control_line(
  state: State,
  board: Option(proposals.Board),
  width: Int,
) -> span.Line {
  let words = case state.place {
    Listing(..) -> "↑/↓ select · Enter review · r reload · Esc back"
    Reading(id:) ->
      case open_row(board, id) {
        Ok(row) ->
          case proposals.decidable(row) {
            True -> "a approve · r reject · ↑/↓ PgUp/PgDn scroll · Esc back"
            False -> "↑/↓ PgUp/PgDn scroll · Esc back"
          }
        Error(Nil) -> "Esc back"
      }
    Confirming(..) -> "y approve · n or Esc go back"
  }
  span.line_new([
    span.span_styled(text.truncate(words, width, "…"), theme.overlay_signal()),
  ])
}

fn body_lines(
  state: State,
  board: Option(proposals.Board),
  notice: String,
  now: Int,
  content: geometry.Rect,
) -> List(span.Line) {
  let width = int.max(1, content.size.width)
  let body = case state.place {
    Listing(selected:) -> list_lines(board, selected, now, width)
    Reading(id:) ->
      detail_lines(open_row(board, id), board, now, width, Browsing)
    Confirming(id:) ->
      detail_lines(open_row(board, id), board, now, width, Asking)
  }
  list.append(notice_lines(notice, width), body)
}

// Whether the list's cursor is on a row.
type Cursor {
  Here
  Elsewhere
}

// How the detail is being read, which decides whether its end is the
// question an approval asks.
type Reader {
  Browsing
  Asking
}

fn list_lines(
  board: Option(proposals.Board),
  selected: Int,
  now: Int,
  width: Int,
) -> List(span.Line) {
  case board {
    None -> wrapped(proposals.loading_words, theme.overlay_quiet(), width)
    Some(board) ->
      case board.proposals {
        [] -> wrapped(proposals.empty_words, theme.overlay_plain(), width)
        rows -> {
          let at = int.min(selected, list.length(rows) - 1)
          let lines =
            list.index_map(rows, fn(row, index) {
              case index == at {
                True -> row_line(row, Here, now, width)
                False -> row_line(row, Elsewhere, now, width)
              }
            })
          list.append(lines, omitted_lines(board.omitted, width))
        }
      }
  }
}

// The one line that says the daemon left older rows out of the board, or no
// line when it left none.
fn omitted_lines(omitted: Int, width: Int) -> List(span.Line) {
  case proposals.omitted_words(omitted) {
    Some(words) -> wrapped(words, theme.overlay_quiet(), width)
    None -> []
  }
}

// One proposal on one line: the cursor, its identity, its age, its state, the
// first line of why, and the session it came from. The line is cut to the
// width and never wrapped, so a row stays one row.
fn row_line(
  row: proposals.Proposal,
  cursor: Cursor,
  now: Int,
  width: Int,
) -> span.Line {
  let mark = case cursor {
    Here -> "▸ "
    Elsewhere -> "  "
  }
  let fixed =
    mark
    <> row.id
    <> "  "
    <> proposals.age(row.created_ms, now)
    <> "  "
    <> proposals.state_words(row.state)
    <> "  "
  let tail = "  " <> proposals.short_session(row.source.session)
  let room = int.max(8, width - text.cell_width(fixed) - text.cell_width(tail))
  let why = proposals.headline(row.rationale, room)
  let words = text.truncate(fixed <> why <> tail, width, "…")
  let appearance = case cursor, row.state {
    Here, _ -> theme.overlay_current()
    Elsewhere, proposals.Pending -> theme.overlay_plain()
    Elsewhere, _ -> theme.overlay_quiet()
  }
  span.line_new([span.span_styled(words, appearance)])
}

fn detail_lines(
  row: Result(proposals.Proposal, Nil),
  board: Option(proposals.Board),
  now: Int,
  width: Int,
  reader: Reader,
) -> List(span.Line) {
  case row, board {
    Ok(row), _ -> proposal_lines(row, now, width, reader)
    Error(Nil), None ->
      wrapped(proposals.loading_words, theme.overlay_quiet(), width)
    Error(Nil), Some(_) ->
      wrapped(
        "That proposal is no longer listed. Esc goes back to the list.",
        theme.overlay_quiet(),
        width,
      )
  }
}

fn proposal_lines(
  row: proposals.Proposal,
  now: Int,
  width: Int,
  reader: Reader,
) -> List(span.Line) {
  let entry = case row.source.entry {
    Some(entry) -> " · entry " <> text_hygiene.single_line(entry)
    None -> ""
  }
  let head =
    row.id
    <> " · "
    <> proposals.state_words(row.state)
    <> " · "
    <> proposals.age(row.created_ms, now)
  let from =
    "From session " <> text_hygiene.single_line(row.source.session) <> entry
  let edit = case row.old {
    "" -> "Adds a " <> proposals.kind_words(row.kind) <> " to " <> row.target
    _ -> "Replaces text in " <> row.target
  }
  list.flatten([
    wrapped(head, theme.overlay_current(), width),
    wrapped(from, theme.overlay_quiet(), width),
    [heading("Why", width)],
    wrapped(row.rationale, theme.overlay_plain(), width),
    [heading(edit, width)],
    diff_lines(row, width),
    [heading("When it applies", width)],
    wrapped(proposals.applies_words, theme.overlay_plain(), width),
    ending(row, reader, width),
  ])
}

// What closes the detail: the question an approval asks, the sentence about
// where an approved rule is written, or what became of a row that can no
// longer change.
fn ending(
  row: proposals.Proposal,
  reader: Reader,
  width: Int,
) -> List(span.Line) {
  case proposals.decidable(row), reader {
    True, Asking ->
      list.append(
        [heading("Approve this rule?", width)],
        wrapped(proposals.approve_words, theme.overlay_signal(), width),
      )
    True, Browsing ->
      wrapped(proposals.approve_words, theme.overlay_quiet(), width)
    False, _ ->
      list.append(
        [heading("Decided", width)],
        wrapped(
          proposals.settled_words(row.state),
          theme.overlay_plain(),
          width,
        ),
      )
  }
}

// The edit, one line per line of text: removed lines in red with a minus and
// added lines in green with a plus, each filled to the width so the colour
// reads as a band. The text is wrapped to the width so a long rule is read
// whole, with the sign repeated only on its first line.
fn diff_lines(row: proposals.Proposal, width: Int) -> List(span.Line) {
  proposals.diff_lines(row)
  |> list.flat_map(fn(line) {
    let #(sign, appearance) = case line.kind {
      diff_view.Removed -> #("- ", theme.diff_removed())
      _ -> #("+ ", theme.diff_added())
    }
    let room = int.max(1, width - 2)
    let pieces = wrapped(text_hygiene.single_line(line.text), appearance, room)
    list.index_map(pieces, fn(piece, index) {
      let lead = case index {
        0 -> sign
        _ -> "  "
      }
      let text_width = span.line_width(piece)
      span.line_new([
        span.span_styled(lead, appearance),
        ..list.append(piece.spans, [
          span.span_styled(
            string.repeat(" ", int.max(0, room - text_width)),
            appearance,
          ),
        ])
      ])
    })
  })
}

fn heading(words: String, width: Int) -> span.Line {
  case list.first(wrapped(words, theme.overlay_quiet(), width)) {
    Ok(line) -> line
    Error(Nil) -> span.line_new([])
  }
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
