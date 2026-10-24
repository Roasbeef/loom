//// The operator's review of governed evolution (protocol-change/099): the
//// candidates a session proposed, what has been decided about each, and the
//// two decisions a person makes here, approving a candidate and selecting it
//// as the generation the session runs.
////
//// A session writes an extension, a program or a prompt, tests it, and a
//// person approves it and selects it. This overlay lists the candidates by
//// kind, opens one to show its evidence and what is offered for it, asks
//// before it sends, and draws a selection while the daemon stages it. It
//// also shows the history of decisions and the session's core component
//// status, which is read-only here: a core upgrade runs from the command
//// line (`loom evolution core_upgrade`).
////
//// The board is not stored here. It lives in the shared session record
//// (`Shared.evolution`), where the lane's replies and the daemon's
//// `evolution_changed` push replace it, and the selections being staged
//// live in `Shared.evolution_pending`. The overlay keeps only where the
//// reader is, and what a confirmation was asked about. Every draw reads the
//// board again, so a reply redraws the open candidate. A board is drawn only
//// when it describes the attached session, so a board read before a session
//// switch is never shown as the new session's.
////
//// A change is two presses. The first captures what the reader is looking
//// at (the candidate, the evidence its approval rests on, and the generation
//// the board showed as current) and asks; only a lowercase `y` sends it, and
//// any other key goes back without sending. A selection echoes the drawn
//// generation, so a board that moved since is refused by the daemon and not
//// selected over. A row offers only what `session_view/evolution` can
//// describe: a candidate of a kind this client cannot name, one tested under
//// another evaluator, one whose approval this client could not read, and one
//// that is not in a state the action applies to offer nothing. The daemon
//// decides everything, so what the overlay offers is a convenience and never
//// the gate. While a selection is staging, no second one is offered: the
//// daemon holds one active job and refuses another with `Busy:`.
////
//// A reason is required by `select`, `rollback` and `revoke`. The overlay
//// cannot take free text, so it sends a fixed sentence that names the
//// terminal, as the access overlay does for a grant. The daemon records the
//// principal, and `via: terminal` records the surface. The command line
//// remains the way to give a longer reason.
////
//// Every string in a board is text a model wrote or a catalogue it wrote.
//// The panel draws it as text, one row at a time, through
//// `session_view/text_hygiene`.
////
//// ## Flow
////
//// `update` → `listing_key` → `reading_key` → `rolling_key` → `confirming_key` → `render` → `body_lines`
////
//// 1. `update` classifies a key by where the reader is and returns an
////    `Action`: the next state, a close, a read again, or a request to send.
//// 2. `listing_key` moves the selection, opens a candidate and opens the
////    core card.
//// 3. `reading_key` scrolls the open candidate and starts a change, offering
////    only what the board lets a person do to that candidate.
//// 4. `rolling_key` chooses the earlier candidate a rollback selects again.
//// 5. `confirming_key` sends the captured request on a lowercase y and
////    otherwise goes back.
//// 6. `render` draws the frame and the control row, and `body_lines` draws
////    the body from the board and the reader's place.

import core/json
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
import gleam/result
import gleam/string
import session_view/evolution
import session_view/evolution_pending
import session_view/model.{type Shared}
import session_view/proposals
import session_view/text_hygiene
import tui/theme

/// The reason a change sent from this overlay gives, one sentence per
/// action. The daemon records who sent it and that the terminal did.
pub const select_reason = "selected from the terminal"

/// The reason a revocation sent from this overlay gives.
pub const revoke_reason = "revoked from the terminal"

/// The reason a rollback sent from this overlay gives.
pub const rollback_reason = "rolled back from the terminal"

/// What a draw reads: the board for the attached session, the selections
/// being staged, the last opened page, the surface's own news, and the two
/// clocks the ages and the staging countdown are read against.
pub type Facts {
  Facts(
    /// The board, only when it describes the attached session.
    board: Option(evolution.Board),
    /// The selections the lane is tracking.
    tracker: evolution_pending.Tracker,
    /// The last page a reader opened, drawn only when it is the core status.
    opened: Option(evolution.Opened),
    /// The words for the last refusal or outcome, or empty.
    notice: String,
    /// The transport clock, in milliseconds, that staging deadlines use.
    transport_ms: Int,
    /// The wall clock, in milliseconds, that ages are read against.
    wall_ms: Int,
  )
}

/// What a key does to the overlay.
pub type Action {
  /// Keep the overlay open in this state.
  Continue(state: State)

  /// Return focus to the composer.
  Close

  /// Read the board again.
  Refresh

  /// Send this request, then continue in the next state.
  Act(request: evolution.Request, next: State)
}

/// Where the reader is in the overlay.
pub opaque type State {
  State(place: Place, scroll: Int)
}

type Place {
  // The list, with the selected row's position in the ordered candidates.
  Listing(selected: Int)

  // One candidate, by its identity, so a board read again between the press
  // and the draw leaves the reader on the row they opened.
  Reading(id: String)

  // The earlier candidates the open, selected one could roll back to.
  Rolling(id: String, selected: Int)

  // The question before a change, with the request exactly as it was drawn
  // when the question was asked.
  Confirming(id: String, question: evolution.Request)

  // The session's core component status, which only reads.
  Core
}

/// Whether a change is offered for the open candidate.
type Offer {
  Offered
  Withheld
}

/// A review opened on the list's first row.
///
/// ## Examples
///
/// ```gleam
/// assert evolution_panel.on_list(evolution_panel.new())
/// ```
pub fn new() -> State {
  State(place: Listing(selected: 0), scroll: 0)
}

/// Whether the reader is on the list and not inside a candidate.
///
/// ## Examples
///
/// ```gleam
/// assert evolution_panel.on_list(evolution_panel.new())
/// ```
pub fn on_list(state: State) -> Bool {
  case state.place {
    Listing(..) -> True
    Reading(..) | Rolling(..) | Confirming(..) | Core -> False
  }
}

/// Whether the reader is being asked to confirm a change.
///
/// ## Examples
///
/// ```gleam
/// assert !evolution_panel.confirming(evolution_panel.new())
/// ```
pub fn confirming(state: State) -> Bool {
  case state.place {
    Confirming(..) -> True
    Listing(..) | Reading(..) | Rolling(..) | Core -> False
  }
}

/// What a draw reads, taken from the shared record. A board that describes
/// another session than the attached one is left out, so the overlay says it
/// is reading and does not draw a stale session's candidates.
///
/// ## Examples
///
/// ```gleam
/// // evolution_panel.facts(model.shared, model.view.wall_ms)
/// ```
pub fn facts(shared: Shared(a, b, c, d), wall_ms: Int) -> Facts {
  Facts(
    board: attached_board(shared),
    tracker: shared.evolution_pending,
    opened: shared.evolution_open,
    notice: shared.evolution_notice,
    transport_ms: shared.stamp.transport_ms,
    wall_ms:,
  )
}

fn attached_board(shared: Shared(a, b, c, d)) -> Option(evolution.Board) {
  case shared.evolution {
    Some(board) if board.session == shared.session -> Some(board)
    Some(_) | None -> None
  }
}

/// The footer's badge: how many candidates wait for a person and the command
/// that opens the review, or nothing when none waits or the board was never
/// read for this session. A daemon that refuses the read leaves no board,
/// which is how an attachment that may not use evolution never shows it.
///
/// ## Examples
///
/// ```gleam
/// // evolution_panel.badge(model.shared)
/// ```
pub fn badge(shared: Shared(a, b, c, d)) -> String {
  case attached_board(shared) {
    Some(board) ->
      case evolution.awaiting_approval(board) {
        0 -> ""
        waiting -> "evolution " <> int.to_string(waiting) <> " · /evolution"
      }
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
/// // evolution_panel.update(keys.Down, evolution_panel.new(), facts, area)
/// ```
pub fn update(
  key: keys.Key,
  state: State,
  facts: Facts,
  area: geometry.Rect,
) -> Action {
  case state.place {
    Listing(selected:) -> listing_key(key, state, facts, selected, area)
    Reading(id:) -> reading_key(key, state, facts, id, area)
    Rolling(id:, selected:) -> rolling_key(key, state, facts, id, selected)
    Confirming(id:, question:) -> confirming_key(key, state, id, question)
    Core -> core_key(key)
  }
}

fn listing_key(
  key: keys.Key,
  state: State,
  facts: Facts,
  selected: Int,
  area: geometry.Rect,
) -> Action {
  let rows = ordered(facts.board)
  let last = int.max(0, list.length(rows) - 1)
  let at = int.min(selected, last)
  let step = viewport_rows(area)
  case key {
    keys.Escape -> Close
    keys.Char("R") | keys.Char("r") -> Refresh
    keys.Char("c") -> Act(evolution.CoreStatus, State(place: Core, scroll: 0))
    keys.Up -> Continue(State(place: Listing(int.max(0, at - 1)), scroll: 0))
    keys.Down ->
      Continue(State(place: Listing(int.min(last, at + 1)), scroll: 0))
    keys.PageUp ->
      Continue(State(place: Listing(int.max(0, at - step)), scroll: 0))
    keys.PageDown ->
      Continue(State(place: Listing(int.min(last, at + step)), scroll: 0))
    keys.Home -> Continue(State(place: Listing(0), scroll: 0))
    keys.End -> Continue(State(place: Listing(last), scroll: 0))
    keys.Enter ->
      case list.drop(rows, at) {
        [row, ..] ->
          Continue(State(place: Reading(row.candidate_id), scroll: 0))
        [] -> Continue(state)
      }
    _ -> Continue(state)
  }
}

fn reading_key(
  key: keys.Key,
  state: State,
  facts: Facts,
  id: String,
  area: geometry.Rect,
) -> Action {
  let step = viewport_rows(area)
  let maximum = max_scroll(state, facts, area)
  let scroll = int.min(state.scroll, maximum)
  case key {
    keys.Escape -> back_to_list(facts, id)
    keys.Char("a") -> start_approval(state, facts, id, scroll)
    keys.Char("s") -> start_selection(state, facts, id, scroll)
    keys.Char("r") -> start_revocation(state, facts, id, scroll)
    keys.Char("b") -> start_rollback(state, facts, id)
    keys.Char("c") -> Act(evolution.CoreStatus, State(place: Core, scroll: 0))
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

// An approval is asked only for a candidate with passing, current evidence
// and no approval; the question captures that evidence.
fn start_approval(
  state: State,
  facts: Facts,
  id: String,
  scroll: Int,
) -> Action {
  case open_candidate(facts, id) {
    Ok(candidate) ->
      case evolution.approval_target(candidate) {
        Ok(evidence_id) ->
          asking(id, evolution.Approve(id, evidence_id), scroll)
        Error(Nil) -> Continue(state)
      }
    Error(Nil) -> Continue(state)
  }
}

// A selection is asked only when nothing else is staging, and it captures the
// generation the board showed as current, which the request echoes.
fn start_selection(
  state: State,
  facts: Facts,
  id: String,
  scroll: Int,
) -> Action {
  case open_candidate(facts, id), facts.board, staging_free(facts) {
    Ok(candidate), Some(board), Offered ->
      case evolution.selection_target(board, candidate) {
        Ok(target) ->
          asking(
            id,
            evolution.Select(
              candidate_id: id,
              name: candidate.name,
              evidence_id: target.evidence_id,
              expected_generation: target.expected_generation,
              reason: select_reason,
            ),
            scroll,
          )
        Error(Nil) -> Continue(state)
      }
    _, _, _ -> Continue(state)
  }
}

// A revocation is asked only for a candidate that carries an approval this
// client read, of a kind it can name.
fn start_revocation(
  state: State,
  facts: Facts,
  id: String,
  scroll: Int,
) -> Action {
  case open_candidate(facts, id) {
    Ok(candidate) ->
      case revocable(candidate) {
        Offered -> asking(id, evolution.Revoke(id, revoke_reason), scroll)
        Withheld -> Continue(state)
      }
    Error(Nil) -> Continue(state)
  }
}

fn start_rollback(state: State, facts: Facts, id: String) -> Action {
  case rollback_choices(facts, id) {
    [] -> Continue(state)
    [_, ..] -> Continue(State(place: Rolling(id, 0), scroll: 0))
  }
}

fn asking(id: String, request: evolution.Request, scroll: Int) -> Action {
  Continue(State(place: Confirming(id, request), scroll:))
}

fn rolling_key(
  key: keys.Key,
  state: State,
  facts: Facts,
  id: String,
  selected: Int,
) -> Action {
  let choices = rollback_choices(facts, id)
  let last = int.max(0, list.length(choices) - 1)
  let at = int.min(selected, last)
  case key {
    keys.Escape -> Continue(State(place: Reading(id), scroll: 0))
    keys.Up ->
      Continue(State(place: Rolling(id, int.max(0, at - 1)), scroll: 0))
    keys.Down ->
      Continue(State(place: Rolling(id, int.min(last, at + 1)), scroll: 0))
    keys.Enter -> pick_rollback(state, facts, id, list.drop(choices, at))
    _ -> Continue(state)
  }
}

fn pick_rollback(
  state: State,
  facts: Facts,
  id: String,
  choices: List(evolution.Candidate),
) -> Action {
  case choices, facts.board, staging_free(facts) {
    [choice, ..], Some(board), Offered ->
      case evolution.selection_target(board, choice) {
        Ok(target) ->
          asking(
            id,
            evolution.Rollback(
              candidate_id: choice.candidate_id,
              name: choice.name,
              evidence_id: target.evidence_id,
              expected_generation: target.expected_generation,
              reason: rollback_reason,
            ),
            0,
          )
        Error(Nil) -> Continue(state)
      }
    _, _, _ -> Continue(state)
  }
}

// Only a lowercase y sends. Any other key, Enter included, goes back to the
// candidate without sending, so a press meant for something else never
// commits a change.
fn confirming_key(
  key: keys.Key,
  state: State,
  id: String,
  question: evolution.Request,
) -> Action {
  case key {
    keys.Char("y") ->
      Act(question, State(place: Reading(id), scroll: state.scroll))
    _ -> Continue(State(place: Reading(id), scroll: state.scroll))
  }
}

fn core_key(key: keys.Key) -> Action {
  case key {
    keys.Char("R") | keys.Char("r") ->
      Act(evolution.CoreStatus, State(place: Core, scroll: 0))
    keys.Escape -> Continue(new())
    _ -> Continue(State(place: Core, scroll: 0))
  }
}

// Leaving a candidate returns to the list with that row still selected, so
// the reader who rejects one and goes back is where they were.
fn back_to_list(facts: Facts, id: String) -> Action {
  let position =
    ordered(facts.board)
    |> list.index_map(fn(row, index) { #(row.candidate_id, index) })
    |> list.find(fn(pair) { pair.0 == id })
  case position {
    Ok(#(_, index)) -> Continue(State(place: Listing(index), scroll: 0))
    Error(Nil) -> Continue(new())
  }
}

// Nothing is offered while a selection is moving, because the daemon holds one
// active job and refuses a second with `Busy:`.
fn staging_free(facts: Facts) -> Offer {
  case evolution_pending.active(facts.tracker) {
    0 -> Offered
    _ -> Withheld
  }
}

// A revocation applies to an approved candidate of a kind this client names.
fn revocable(candidate: evolution.Candidate) -> Offer {
  case candidate.approval, candidate.kind {
    Some(_), evolution.Extension
    | Some(_), evolution.Program
    | Some(_), evolution.Prompt
    -> Offered
    Some(_), evolution.UnknownKind(_) | None, _ -> Withheld
  }
}

fn rollback_choices(facts: Facts, id: String) -> List(evolution.Candidate) {
  case facts.board, open_candidate(facts, id), staging_free(facts) {
    Some(board), Ok(candidate), Offered ->
      case candidate.selected {
        Some(_) -> evolution.rollback_choices(board, candidate)
        None -> []
      }
    _, _, _ -> []
  }
}

/// The place a change leaves the reader once it is sent: back on the
/// candidate, whose row the reply redraws with its new state.
///
/// ## Examples
///
/// ```gleam
/// // evolution_panel.after_change(state, "3f9a")
/// ```
pub fn after_change(state: State, id: String) -> State {
  State(place: Reading(id), scroll: state.scroll)
}

// The candidates in the order the list draws them: extensions, programs,
// prompts, then any kind this client cannot name, each in the daemon's order.
// The selected row is a position in this list.
fn ordered(board: Option(evolution.Board)) -> List(evolution.Candidate) {
  case board {
    Some(board) ->
      list.flatten([
        of_kind(board, evolution.Extension),
        of_kind(board, evolution.Program),
        of_kind(board, evolution.Prompt),
        list.filter(board.candidates, fn(candidate) {
          is_unknown(candidate.kind)
        }),
      ])
    None -> []
  }
}

fn is_unknown(kind: evolution.Kind) -> Bool {
  case kind {
    evolution.UnknownKind(_) -> True
    evolution.Extension | evolution.Program | evolution.Prompt -> False
  }
}

fn of_kind(
  board: evolution.Board,
  kind: evolution.Kind,
) -> List(evolution.Candidate) {
  list.filter(board.candidates, fn(candidate) { candidate.kind == kind })
}

fn open_candidate(
  facts: Facts,
  id: String,
) -> Result(evolution.Candidate, Nil) {
  case facts.board {
    Some(board) -> evolution.find(board, id)
    None -> Error(Nil)
  }
}

/// Renders the review over the conversation.
///
/// ## Examples
///
/// ```gleam
/// // evolution_panel.render(buffer, body, state, facts)
/// ```
pub fn render(
  buf: buffer.Buffer,
  area: geometry.Rect,
  state: State,
  facts: Facts,
) -> buffer.Buffer {
  use <- bool.guard(area.size.width <= 0 || area.size.height <= 0, buf)
  let #(card, content, controls) = layout_areas(area)
  let frame =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.current, theme.graphite)
    |> block.with_bg_fill
    |> block.with_title(title(facts), block.Top)
  let #(rows, cursor) = body_lines(state, facts, content)
  let maximum = int.max(0, list.length(rows) - content.size.height)
  let offset = case state.place {
    Listing(..) ->
      int.min(maximum, int.max(0, cursor + 1 - content.size.height))
    Reading(..) | Rolling(..) | Confirming(..) | Core ->
      int.min(maximum, state.scroll)
  }
  let cleared = buf |> buffer.clear(area)
  let framed = case card.size.height >= 8 && card.size.width >= 20 {
    True -> block.render(cleared, card, frame)
    False -> cleared
  }
  framed
  |> paragraph.render_styled(content, list.drop(rows, offset))
  |> paragraph.render_styled(controls, [
    control_line(state, facts, controls.size.width),
  ])
}

fn title(facts: Facts) -> String {
  case facts.board {
    Some(board) ->
      " Evolution · session "
      <> evolution.short_id(text_hygiene.single_line(board.session))
      <> " · Esc back "
    None -> " Evolution · Esc back "
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

fn max_scroll(state: State, facts: Facts, area: geometry.Rect) -> Int {
  let #(_, content, _) = layout_areas(area)
  let #(rows, _) = body_lines(state, facts, content)
  int.max(0, list.length(rows) - content.size.height)
}

fn control_line(state: State, facts: Facts, width: Int) -> span.Line {
  let words = case state.place {
    Listing(..) -> "↑/↓ select · Enter open · c core · R read again · Esc back"
    Reading(id:) -> reading_controls(facts, id)
    Rolling(..) -> "↑/↓ choose · Enter pick · Esc back"
    Confirming(..) -> "y sends · any other key goes back"
    Core -> "R read again · Esc back"
  }
  span.line_new([
    span.span_styled(text.truncate(words, width, "…"), theme.overlay_signal()),
  ])
}

// The keys a candidate offers, then the keys every candidate has. A candidate
// that offers nothing says only how to scroll and leave.
fn reading_controls(facts: Facts, id: String) -> String {
  case open_candidate(facts, id) {
    Ok(candidate) -> {
      let offered = offered_keys(facts, candidate)
      string.join(
        list.append(offered, ["c core", "↑/↓ PgUp/PgDn scroll", "Esc back"]),
        " · ",
      )
    }
    Error(Nil) -> "Esc back"
  }
}

fn offered_keys(facts: Facts, candidate: evolution.Candidate) -> List(String) {
  let approve = case evolution.approval_target(candidate) {
    Ok(_) -> ["a approve"]
    Error(Nil) -> []
  }
  let select = case facts.board, staging_free(facts) {
    Some(board), Offered ->
      case evolution.selection_target(board, candidate) {
        Ok(_) -> ["s select"]
        Error(Nil) -> []
      }
    _, _ -> []
  }
  let revoke = case revocable(candidate) {
    Offered -> ["r revoke"]
    Withheld -> []
  }
  let rollback = case rollback_choices(facts, candidate.candidate_id) {
    [] -> []
    [_, ..] -> ["b rollback"]
  }
  list.flatten([approve, select, revoke, rollback])
}

// The body and where the list's cursor sits in it, which the list's scroll
// follows. Only the list has a cursor; the other places report zero.
fn body_lines(
  state: State,
  facts: Facts,
  content: geometry.Rect,
) -> #(List(span.Line), Int) {
  let width = int.max(1, content.size.width)
  let lead = notice_lines(facts.notice, width)
  let #(body, cursor) = case state.place {
    Listing(selected:) -> list_lines(facts, selected, width)
    Reading(id:) -> #(candidate_lines(facts, id, None, width), 0)
    Rolling(id:, selected:) -> #(rolling_lines(facts, id, selected, width), 0)
    Confirming(id:, question:) -> #(
      candidate_lines(facts, id, Some(question), width),
      0,
    )
    Core -> #(core_lines(facts, width), 0)
  }
  #(list.append(lead, body), cursor + list.length(lead))
}

fn notice_lines(notice: String, width: Int) -> List(span.Line) {
  case notice {
    "" -> []
    words ->
      wrapped(text_hygiene.single_line(words), theme.overlay_signal(), width)
  }
}

// --- the list ---------------------------------------------------------------

fn list_lines(
  facts: Facts,
  selected: Int,
  width: Int,
) -> #(List(span.Line), Int) {
  case facts.board {
    None -> #(wrapped(evolution.loading_words, theme.overlay_quiet(), width), 0)
    Some(board) -> {
      let rows = ordered(Some(board))
      let at = int.min(selected, int.max(0, list.length(rows) - 1))
      let live = live_lines(board, width)
      let #(group_rows, cursor) = group_lines(facts, board, at, width)
      let lines =
        list.flatten([
          live,
          [blank()],
          group_rows,
          [blank()],
          history_lines(facts, board, width),
          [blank()],
          wrapped(
            "CORE c opens the session's core status. " <> evolution.core_words,
            theme.overlay_quiet(),
            width,
          ),
          unread_lines(board, width),
        ])
      #(lines, list.length(live) + 1 + cursor)
    }
  }
}

// Where the list's cursor is.
type Cursor {
  Here
  Elsewhere
}

// The list's lines, each tagged with the candidate it draws (empty for a
// heading), so the line the cursor sits on is found by identity and the
// list's scroll can follow it.
type Tagged {
  Tagged(id: String, line: span.Line)
}

fn group_lines(
  facts: Facts,
  board: evolution.Board,
  at: Int,
  width: Int,
) -> #(List(span.Line), Int) {
  let selected_id = case list.drop(ordered(Some(board)), at) {
    [row, ..] -> row.candidate_id
    [] -> ""
  }
  let unknown =
    list.filter(board.candidates, fn(candidate) { is_unknown(candidate.kind) })
  let groups = [
    #("EXTENSIONS", of_kind(board, evolution.Extension)),
    #("PROGRAMS", of_kind(board, evolution.Program)),
    #("PROMPTS", of_kind(board, evolution.Prompt)),
    #("OTHER", unknown),
  ]
  let tagged =
    list.flat_map(groups, fn(group) {
      group_block(facts, board, group.0, group.1, selected_id, width)
    })
  let cursor =
    list.index_map(tagged, fn(entry, index) { #(entry.id, index) })
    |> list.find(fn(pair) { pair.0 == selected_id && pair.0 != "" })
    |> result.map(fn(pair) { pair.1 })
    |> result.unwrap(0)
  #(list.map(tagged, fn(entry) { entry.line }), cursor)
}

// One kind's heading and rows. A kind with no candidates is drawn as none,
// except the catch-all for kinds this client cannot name, which is left out
// when it is empty.
fn group_block(
  facts: Facts,
  board: evolution.Board,
  heading_words: String,
  rows: List(evolution.Candidate),
  selected_id: String,
  width: Int,
) -> List(Tagged) {
  let head =
    Tagged(
      "",
      span.line_new([span.span_styled(heading_words, theme.overlay_quiet())]),
    )
  case rows, heading_words {
    [], "OTHER" -> []
    [], _ -> [
      head,
      Tagged(
        "",
        span.line_new([span.span_styled("  (none)", theme.overlay_quiet())]),
      ),
    ]
    _, _ -> [
      head,
      ..list.map(rows, fn(row) {
        let cursor = case row.candidate_id == selected_id {
          True -> Here
          False -> Elsewhere
        }
        Tagged(row.candidate_id, row_line(facts, board, row, cursor, width))
      })
    ]
  }
}

// One candidate on one line: the cursor, its name and short identity, its
// state, and the newest evidence. The line is cut to the width and never
// wrapped, so a row stays one row.
fn row_line(
  facts: Facts,
  board: evolution.Board,
  row: evolution.Candidate,
  cursor: Cursor,
  width: Int,
) -> span.Line {
  let mark = case cursor {
    Here -> "▸ "
    Elsewhere -> "  "
  }
  let words =
    mark
    <> text_hygiene.single_line(row.name)
    <> "  "
    <> evolution.short_id(row.candidate_id)
    <> "  "
    <> state_words(facts, board, row)
    <> "  "
    <> evidence_summary(facts, row)
  let appearance = case cursor {
    Here -> theme.overlay_current()
    Elsewhere -> theme.overlay_plain()
  }
  span.line_new([
    span.span_styled(text.truncate(words, width, "…"), appearance),
  ])
}

// What has been decided about a candidate, as a row says it. A selection that
// is staging reads as the staging, because that is the part still changing.
fn state_words(
  facts: Facts,
  board: evolution.Board,
  row: evolution.Candidate,
) -> String {
  case staging_for(facts, row) {
    Some(tracked) -> staging_words(tracked, facts.transport_ms)
    None -> settled_words(board, row)
  }
}

fn settled_words(board: evolution.Board, row: evolution.Candidate) -> String {
  case row.selected {
    Some(chosen) ->
      evolution.generation_words(chosen.generation, liveness(board, row))
    None -> approval_words(row)
  }
}

fn approval_words(row: evolution.Candidate) -> String {
  case row.approval, evolution.approval_target(row) {
    Some(_), _ -> "approved"
    None, Ok(_) -> "tests passed"
    None, Error(Nil) -> "candidate"
  }
}

fn liveness(
  board: evolution.Board,
  row: evolution.Candidate,
) -> evolution.Liveness {
  list.find(board.selections, fn(selection) {
    selection.candidate_id == row.candidate_id
  })
  |> result.map(fn(selection) { selection.liveness })
  |> result.unwrap(evolution.NotLive)
}

// The request the lane is tracking for a candidate, only while it is moving.
fn staging_for(
  facts: Facts,
  row: evolution.Candidate,
) -> Option(evolution_pending.Tracked) {
  case evolution_pending.for_candidate(facts.tracker, row.candidate_id) {
    Some(tracked) ->
      case evolution_pending.settled(tracked.stage) {
        True -> None
        False -> Some(tracked)
      }
    None -> None
  }
}

// How far a selection has got and how long the lane waits for it, in the
// words the row shows. The identity of the request is never drawn.
fn staging_words(tracked: evolution_pending.Tracked, now_ms: Int) -> String {
  let left = int.to_string(int.max(0, tracked.deadline_ms - now_ms) / 1000)
  case tracked.stage {
    evolution_pending.Submitted -> "sending…"
    evolution_pending.Staging(evolution.Queued) -> "queued… " <> left <> " s"
    evolution_pending.Staging(evolution.Running) -> "staging… " <> left <> " s"
    evolution_pending.Staging(evolution.UnknownPhase(phase:)) ->
      text_hygiene.single_line(phase) <> "… " <> left <> " s"
    evolution_pending.Publishing -> "committed, publishing… " <> left <> " s"
    evolution_pending.Landed(..)
    | evolution_pending.Refused(..)
    | evolution_pending.Vanished
    | evolution_pending.TimedOut -> "settled"
  }
}

// The newest evidence: why it was made, what it found and how long ago.
fn evidence_summary(facts: Facts, row: evolution.Candidate) -> String {
  case row.evidence {
    [newest, ..] ->
      evolution.purpose_words(newest.purpose)
      <> " "
      <> evolution.verdict_words(newest.verdict, "")
      <> " "
      <> proposals.age(newest.at_ms, facts.wall_ms)
    [] -> "no evidence"
  }
}

// The generations the session runs now, one line.
fn live_lines(board: evolution.Board, width: Int) -> List(span.Line) {
  let live =
    list.filter(board.selections, fn(selection) {
      selection.liveness == evolution.Live
    })
    |> list.map(fn(selection) {
      text_hygiene.single_line(selection.name)
      <> " "
      <> kind_of(board, selection.candidate_id)
      <> " generation "
      <> int.to_string(selection.generation)
    })
  let words = case live {
    [] -> "LIVE nothing selected is live in this session"
    _ -> "LIVE " <> string.join(live, " · ")
  }
  wrapped(words, theme.overlay_current(), width)
}

fn kind_of(board: evolution.Board, candidate_id: String) -> String {
  case evolution.find(board, candidate_id) {
    Ok(candidate) -> evolution.kind_words(candidate.kind)
    Error(Nil) -> "candidate"
  }
}

// The newest few decisions, then how many older ones the board holds or the
// daemon left out.
fn history_lines(
  facts: Facts,
  board: evolution.Board,
  width: Int,
) -> List(span.Line) {
  let shown = 5
  let rows = list.take(board.history, shown)
  let older =
    int.max(0, list.length(board.history) - shown) + board.omitted_history
  let body = case rows {
    [] -> [
      span.line_new([span.span_styled("  (none)", theme.overlay_quiet())]),
    ]
    _ ->
      list.flat_map(rows, fn(event) {
        wrapped(
          "  " <> event_words(event, facts.wall_ms),
          theme.overlay_plain(),
          width,
        )
      })
  }
  let tail = case older {
    0 -> []
    count ->
      wrapped(
        "  " <> int.to_string(count) <> " older entries not shown",
        theme.overlay_quiet(),
        width,
      )
  }
  list.flatten([
    [span.line_new([span.span_styled("HISTORY", theme.overlay_quiet())])],
    body,
    tail,
  ])
}

fn event_words(event: evolution.Event, wall_ms: Int) -> String {
  let what =
    evolution.decision_words(event.decision)
    <> " "
    <> text_hygiene.single_line(event.name)
    <> case event.generation {
      Some(generation) -> " → generation " <> int.to_string(generation)
      None -> " " <> evolution.short_id(event.candidate_id)
    }
  let who = case event.principal, evolution.surface_words(event.via) {
    "", "" -> ""
    principal, "" -> " (" <> text_hygiene.single_line(principal) <> ")"
    "", surface -> " (" <> surface <> ")"
    principal, surface ->
      " (" <> text_hygiene.single_line(principal) <> ", " <> surface <> ")"
  }
  proposals.age(event.at_ms, wall_ms) <> "  " <> what <> who
}

// What the daemon left out of the board and what this client could not read,
// so the reader knows the list is not the whole catalogue.
fn unread_lines(board: evolution.Board, width: Int) -> List(span.Line) {
  let left_out = case board.omitted_candidates {
    0 -> []
    count -> [
      int.to_string(count) <> " candidates were left out by the daemon.",
    ]
  }
  let unread = case board.unread {
    0 -> []
    count -> [
      int.to_string(count) <> " rows could not be read by this client.",
    ]
  }
  case list.append(left_out, unread) {
    [] -> []
    words -> wrapped(string.join(words, " "), theme.overlay_quiet(), width)
  }
}

// --- a candidate ------------------------------------------------------------

fn candidate_lines(
  facts: Facts,
  id: String,
  question: Option(evolution.Request),
  width: Int,
) -> List(span.Line) {
  case open_candidate(facts, id), facts.board {
    Ok(candidate), Some(board) ->
      list.append(
        detail_lines(facts, board, candidate, width),
        question_lines(question, board, width),
      )
    Error(Nil), None ->
      wrapped(evolution.loading_words, theme.overlay_quiet(), width)
    Error(Nil), Some(_) | Ok(_), None ->
      wrapped(
        "That candidate is no longer listed. Esc goes back to the list.",
        theme.overlay_quiet(),
        width,
      )
  }
}

fn detail_lines(
  facts: Facts,
  board: evolution.Board,
  candidate: evolution.Candidate,
  width: Int,
) -> List(span.Line) {
  let head =
    text_hygiene.single_line(candidate.name)
    <> " · "
    <> evolution.kind_words(candidate.kind)
    <> " · "
    <> state_words(facts, board, candidate)
  let ids = "candidate " <> text_hygiene.single_line(candidate.candidate_id)
  let scope =
    "Applies to "
    <> text_hygiene.single_line(evolution.scope_words(
      candidate.scope,
      board.session,
    ))
    <> parent_words(candidate)
  let from =
    "Proposed by session "
    <> text_hygiene.single_line(candidate.origin.session)
    <> ", strand "
    <> text_hygiene.single_line(candidate.origin.strand)
  list.flatten([
    wrapped(head, theme.overlay_current(), width),
    wrapped(ids, theme.overlay_quiet(), width),
    wrapped(scope, theme.overlay_quiet(), width),
    wrapped(from, theme.overlay_quiet(), width),
    [heading("What it does", width)],
    wrapped(candidate.description, theme.overlay_plain(), width),
    [heading("Evidence", width)],
    evidence_lines(facts, candidate, width),
    [heading("Decision", width)],
    decision_lines(candidate, width),
    staging_lines(facts, candidate, width),
  ])
}

fn parent_words(candidate: evolution.Candidate) -> String {
  case candidate.parent {
    Some(parent) -> " · proposed from " <> evolution.short_id(parent)
    None -> ""
  }
}

fn evidence_lines(
  facts: Facts,
  candidate: evolution.Candidate,
  width: Int,
) -> List(span.Line) {
  case candidate.evidence {
    [] ->
      wrapped("No evidence is retained for it.", theme.overlay_quiet(), width)
    rows ->
      list.flat_map(rows, fn(row) {
        let evaluator = case row.identity {
          evolution.Current -> ""
          evolution.Outdated -> " · under an older evaluator"
        }
        wrapped(
          evolution.purpose_words(row.purpose)
            <> " · "
            <> evolution.verdict_words(row.verdict, row.reason)
            <> " · "
            <> proposals.age(row.at_ms, facts.wall_ms)
            <> evaluator
            <> " · "
            <> evolution.short_id(row.evidence_id),
          theme.overlay_plain(),
          width,
        )
      })
  }
}

fn decision_lines(
  candidate: evolution.Candidate,
  width: Int,
) -> List(span.Line) {
  let approval = case candidate.approval {
    Some(approval) -> {
      let via = case evolution.surface_words(approval.via) {
        "" -> ""
        surface -> " from the " <> surface
      }
      "Approved by "
      <> text_hygiene.single_line(approval.by)
      <> via
      <> " on evidence "
      <> evolution.short_id(approval.evidence_id)
      <> "."
    }
    None -> "Not approved."
  }
  let identity = case candidate.identity {
    evolution.Current -> ""
    evolution.Outdated ->
      " It was tested under an older evaluator, so it needs new evidence."
  }
  wrapped(approval <> identity, theme.overlay_plain(), width)
}

// The selection the lane is staging for this candidate, in words, so the
// detail shows it moving.
fn staging_lines(
  facts: Facts,
  candidate: evolution.Candidate,
  width: Int,
) -> List(span.Line) {
  case staging_for(facts, candidate) {
    Some(tracked) ->
      wrapped(
        evolution_pending.words(tracked, facts.transport_ms),
        theme.overlay_signal(),
        width,
      )
    None -> []
  }
}

// --- the question -----------------------------------------------------------

fn question_lines(
  question: Option(evolution.Request),
  board: evolution.Board,
  width: Int,
) -> List(span.Line) {
  case question {
    Some(request) ->
      list.append(
        [heading(question_heading(request, board), width)],
        wrapped(question_words(request, board), theme.overlay_signal(), width),
      )
    None -> []
  }
}

fn question_heading(
  request: evolution.Request,
  board: evolution.Board,
) -> String {
  case request {
    evolution.Approve(candidate_id:, ..) ->
      "Approve " <> named(board, candidate_id) <> "?"
    evolution.Revoke(candidate_id:, ..) ->
      "Revoke the approval of " <> named(board, candidate_id) <> "?"
    evolution.Select(name:, candidate_id:, expected_generation:, ..) ->
      "Select "
      <> evolution.short_id(candidate_id)
      <> " as "
      <> next_generation(name, expected_generation)
      <> "?"
    evolution.Rollback(name:, candidate_id:, expected_generation:, ..) ->
      "Roll back to "
      <> evolution.short_id(candidate_id)
      <> " as "
      <> next_generation(name, expected_generation)
      <> "?"
    evolution.Inspect(..) | evolution.ReadEvidence(..) | evolution.CoreStatus ->
      ""
  }
}

// The generation a selection creates, from the generation the board drew as
// current, which is the echo the request carries.
fn next_generation(name: String, expected: Int) -> String {
  case expected {
    0 -> "the first generation of " <> text_hygiene.single_line(name)
    _ ->
      "generation "
      <> int.to_string(expected + 1)
      <> " of "
      <> text_hygiene.single_line(name)
      <> ", replacing generation "
      <> int.to_string(expected)
  }
}

fn question_words(
  request: evolution.Request,
  board: evolution.Board,
) -> String {
  case request {
    evolution.Approve(candidate_id:, evidence_id:) ->
      "Evidence "
      <> evolution.short_id(evidence_id)
      <> " ("
      <> evidence_words(board, candidate_id, evidence_id)
      <> ") is what the approval rests on. An approval makes the candidate selectable. It does not run it; selecting does."
    evolution.Revoke(reason:, ..) ->
      "The candidate can no longer be selected until it is approved again. reason: "
      <> reason
    evolution.Select(evidence_id:, reason:, ..) ->
      "Evidence "
      <> evolution.short_id(evidence_id)
      <> " carries the approval. The session switches to it once it is staged, and a rollback selects an earlier approved generation again. reason: "
      <> reason
    evolution.Rollback(evidence_id:, reason:, ..) ->
      "Evidence "
      <> evolution.short_id(evidence_id)
      <> " carries its approval. The earlier candidate becomes the newest generation. reason: "
      <> reason
    evolution.Inspect(..) | evolution.ReadEvidence(..) | evolution.CoreStatus ->
      ""
  }
}

fn evidence_words(
  board: evolution.Board,
  candidate_id: String,
  evidence_id: String,
) -> String {
  case evolution.find(board, candidate_id) {
    Ok(candidate) ->
      list.find(candidate.evidence, fn(row) { row.evidence_id == evidence_id })
      |> result.map(fn(row) {
        evolution.purpose_words(row.purpose)
        <> ", "
        <> evolution.verdict_words(row.verdict, "")
      })
      |> result.unwrap("evidence")
    Error(Nil) -> "evidence"
  }
}

fn named(board: evolution.Board, candidate_id: String) -> String {
  case evolution.find(board, candidate_id) {
    Ok(candidate) ->
      text_hygiene.single_line(candidate.name)
      <> " "
      <> evolution.short_id(candidate_id)
    Error(Nil) -> evolution.short_id(candidate_id)
  }
}

// --- the rollback chooser and the core card ---------------------------------

fn rolling_lines(
  facts: Facts,
  id: String,
  selected: Int,
  width: Int,
) -> List(span.Line) {
  let choices = rollback_choices(facts, id)
  let at = int.min(selected, int.max(0, list.length(choices) - 1))
  let intro =
    wrapped(
      "Select an earlier approved generation again. It becomes the newest generation.",
      theme.overlay_quiet(),
      width,
    )
  let rows = case facts.board {
    Some(board) ->
      list.index_map(choices, fn(choice, index) {
        let mark = case index == at {
          True -> "▸ "
          False -> "  "
        }
        let appearance = case index == at {
          True -> theme.overlay_current()
          False -> theme.overlay_plain()
        }
        let words =
          mark
          <> text_hygiene.single_line(choice.name)
          <> "  "
          <> evolution.short_id(choice.candidate_id)
          <> "  "
          <> earlier_words(board, choice, facts.wall_ms)
        span.line_new([
          span.span_styled(text.truncate(words, width, "…"), appearance),
        ])
      })
    None -> []
  }
  list.append(intro, rows)
}

// When the journal last selected an earlier candidate, and as which
// generation.
fn earlier_words(
  board: evolution.Board,
  choice: evolution.Candidate,
  wall_ms: Int,
) -> String {
  let found =
    list.find(board.history, fn(event) {
      event.decision == evolution.Selected
      && event.candidate_id == choice.candidate_id
    })
  case found {
    Ok(event) ->
      case event.generation {
        Some(generation) ->
          "was generation "
          <> int.to_string(generation)
          <> ", "
          <> proposals.age(event.at_ms, wall_ms)
        None -> "selected " <> proposals.age(event.at_ms, wall_ms)
      }
    Error(Nil) -> "selected before"
  }
}

fn core_lines(facts: Facts, width: Int) -> List(span.Line) {
  let status = case facts.opened {
    Some(evolution.Opened(action: "core_status", page: evolution.Whole(value))) ->
      flattened(value)
      |> list.flat_map(fn(row) { wrapped(row, theme.overlay_plain(), width) })
    Some(evolution.Opened(action: "core_status", page: evolution.Large(..))) ->
      wrapped(
        "The core status is too large to draw here. Use loom evolution core_status.",
        theme.overlay_plain(),
        width,
      )
    Some(_) | None ->
      wrapped("Reading the core status...", theme.overlay_quiet(), width)
  }
  list.flatten([
    [heading("CORE", width)],
    status,
    [blank()],
    wrapped(evolution.core_words, theme.overlay_quiet(), width),
  ])
}

// The status as `name: value` rows, nested objects joined by dots, at most
// forty rows. The status is the daemon's own JSON, so each name and value
// passes through text hygiene when it is drawn.
fn flattened(value: json.JsonValue) -> List(String) {
  flatten_into("", value, 0)
  |> list.take(40)
}

fn flatten_into(
  prefix: String,
  value: json.JsonValue,
  depth: Int,
) -> List(String) {
  case value {
    json.Object(fields) if depth < 3 ->
      list.flat_map(fields, fn(field) {
        let name = case prefix {
          "" -> field.0
          _ -> prefix <> "." <> field.0
        }
        flatten_into(name, field.1, depth + 1)
      })
    json.Array(items) -> [
      leaf(prefix, int.to_string(list.length(items)) <> " items"),
    ]
    json.String(words) -> [leaf(prefix, words)]
    other -> [leaf(prefix, json.to_string(other))]
  }
}

fn leaf(name: String, value: String) -> String {
  case name {
    "" -> text_hygiene.single_line(value)
    _ ->
      text_hygiene.single_line(name) <> ": " <> text_hygiene.single_line(value)
  }
}

// --- drawing helpers --------------------------------------------------------

fn blank() -> span.Line {
  span.line_new([])
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
