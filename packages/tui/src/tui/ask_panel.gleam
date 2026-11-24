//// The card that shows an agent's open asks above the composer.
////
//// The card is drawn in the rows between the transcript and the input frame.
//// It is not a dialog: the transcript keeps the rest of the screen, and the
//// composer keeps the keyboard until the owner presses the key the card's last
//// row names. The card shows each open ask the way the web view's ask card
//// does: who asked and since when, then each question with the choices its
//// kind offers, so an ask is readable as a question and not as the raw tool
//// call.
////
//// This module draws and measures. `tui/ask_form` decides what a key does and
//// `tui/ask_board` decides which asks exist, so a frame is a function of the
//// board alone.
////
//// ## Flow
////
//// `height` → `render` → `lines` → `form_lines` → `question_lines`
////
//// 1. `height` says how many rows the card takes, bounded by the room the
////    layout offers, so the transcript's height can be decided before it is
////    drawn.
//// 2. `render` clears the card's rows and draws the window of `lines` that
////    holds the cursor, with the key hints pinned in the last row.
//// 3. `lines` joins the drawn forms, then the count of asks not drawn.
//// 4. `form_lines` draws one ask's heading and why, and `question_lines` its
////    questions, each row marked when the cursor stands on it.
////
//// ## What the rows say
////
//// A choice row reads `(•)` for the picked option of a `confirm` or `choice`
//// and `[x]` for a toggled option of a `multiple` or `checklist`. The option
//// the model recommends says so after its label, and its note follows. An
//// Other row shows its text as it is typed, and a fill row shows its text or a
//// prompt to type. Every word the model wrote is single-lined before it is
//// drawn, so a control character in a label cannot move the cursor.

import core/attention
import etui/buffer
import etui/geometry.{type Rect}
import etui/span
import etui/style
import etui/widgets/paragraph
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/text_hygiene
import tui/ask_board.{type Board}
import tui/ask_form.{type Form}
import tui/theme

/// A drawn line, and the form row it belongs to when the cursor can stand on
/// it, so the window can follow the cursor.
pub type Drawn {
  Drawn(
    /// The index of the form row the line draws, or none for a line the cursor
    /// cannot stand on.
    row: Option(Int),
    /// The line as it is painted.
    line: span.Line,
  )
}

/// Whether a card has the keyboard.
type Keyboard {
  /// The card does, so the cursor's row is marked.
  Here

  /// The composer does, so no row is marked.
  Away
}

/// Whether an option is chosen in the draft.
type Chosen {
  Picked
  Unpicked
}

/// Whether the card shows all of its lines or only a window of them.
type Extent {
  Whole
  Cut
}

/// The key that gives the card the keyboard, as the hint names it.
pub const focus_key_name = "Alt+A"

/// The rows the card takes: none when there is no ask or the room is under
/// three rows, and otherwise as many as the card has, up to `room`.
///
/// ## Examples
///
/// ```gleam
/// assert ask_panel.height(ask_board.empty(), 80, option.None, 10) == 0
/// ```
pub fn height(
  board: Board,
  width: Int,
  clock_offset: Option(Int),
  room: Int,
) -> Int {
  // Nothing is reserved for a board with no ask or a screen too short to hold
  // a heading, one row and the hint.
  case ask_board.has_asks(board), room >= 3 {
    True, True ->
      int.min(room, list.length(lines(board, width, clock_offset)) + 1)
    True, False | False, True | False, False -> 0
  }
}

/// Draws the card into `area`, clearing it first.
///
/// ## Examples
///
/// ```gleam
/// // ask_panel.render(buffer, area, board, option.Some(0))
/// ```
pub fn render(
  buf: buffer.Buffer,
  area: Rect,
  board: Board,
  clock_offset: Option(Int),
) -> buffer.Buffer {
  let drawn = lines(board, area.size.width, clock_offset)
  let content_rows = int.max(0, area.size.height - 1)
  let start = window_start(drawn, board, content_rows)
  let shown =
    drawn
    |> list.drop(start)
    |> list.take(content_rows)
    |> list.map(fn(entry) { entry.line })

  // The hint says so when lines below the window are not drawn.
  let extent = case list.length(drawn) > start + content_rows {
    True -> Cut
    False -> Whole
  }

  let rows = list.append(shown, [hints(board, extent, area.size.width)])

  buf
  |> buffer.clear(area)
  |> paragraph.render_styled(area, rows)
}

/// The first drawn line the window shows: the top, unless the cursor's line
/// would fall below the window, in which case the cursor's line is the last.
fn window_start(drawn: List(Drawn), board: Board, rows: Int) -> Int {
  // Only a form that has the keyboard has a cursor to follow.
  case ask_board.focused(board) {
    None -> 0
    Some(#(_, form)) -> {
      let at =
        list.index_map(drawn, fn(entry, index) { #(index, entry.row) })
        |> list.find(fn(entry) { entry.1 == Some(form.cursor) })
        |> option.from_result

      // The window ends on the cursor's line once that line is past the end.
      case at {
        Some(#(index, _)) -> int.max(0, index - rows + 2)
        None -> 0
      }
    }
  }
}

/// Every line of every drawn ask, then the count of asks not drawn.
///
/// ## Examples
///
/// ```gleam
/// assert ask_panel.lines(ask_board.empty(), 80, option.None) == []
/// ```
pub fn lines(
  board: Board,
  width: Int,
  clock_offset: Option(Int),
) -> List(Drawn) {
  // Which card, if any, has the keyboard.
  let focused = case ask_board.focused(board) {
    Some(#(index, _)) -> Some(index)
    None -> None
  }

  let cards =
    list.index_map(board.forms, fn(form, index) {
      // Only the focused card marks its cursor row.
      let keyboard = case focused == Some(index) {
        True -> Here
        False -> Away
      }

      form_lines(
        form,
        index,
        keyboard,
        list.length(board.forms),
        width,
        clock_offset,
      )
    })

  list.flatten([
    rule(width),
    list.flatten(list.intersperse(cards, [Drawn(None, span.line_new([]))])),
    more_line(board),
  ])
}

/// The rule above the card.
fn rule(width: Int) -> List(Drawn) {
  [
    Drawn(
      None,
      span.line_new([
        span.span_styled(
          string.repeat("─", width),
          style.new(theme.divider, style.Default, style.none()),
        ),
      ]),
    ),
  ]
}

/// The line that counts the asks not drawn.
fn more_line(board: Board) -> List(Drawn) {
  // Asks beyond the drawn limit are counted and drawn as they are answered.
  case ask_board.more(board) {
    0 -> []
    1 -> [Drawn(None, quiet_line(" 1 more open ask"))]
    count -> [
      Drawn(None, quiet_line(" " <> int.to_string(count) <> " more open asks")),
    ]
  }
}

/// One ask: its heading, why, questions, the Send row and any refusal.
fn form_lines(
  form: Form,
  index: Int,
  keyboard: Keyboard,
  drawn: Int,
  width: Int,
  clock_offset: Option(Int),
) -> List(Drawn) {
  // The heading says which ask this is only when more than one is drawn.
  let place = case drawn > 1 {
    True -> " · " <> int.to_string(index + 1) <> " of " <> int.to_string(drawn)
    False -> ""
  }

  list.flatten([
    [Drawn(None, heading(form, place, width, clock_offset))],
    why_lines(form, width),
    list.flatten(
      list.index_map(form.ask.questions, fn(question, at) {
        question_lines(form, question, at, keyboard, width)
      }),
    ),
    send_lines(form, keyboard, width),
    refusal_lines(form, width),
  ])
}

/// The heading: `Ask · waiting since 13:40 · main`.
fn heading(
  form: Form,
  place: String,
  width: Int,
  clock_offset: Option(Int),
) -> span.Line {
  let strand = text_hygiene.single_line(form.ask.header.strand)
  let words =
    "waiting since "
    <> time_words(form.ask.header.created_at, clock_offset)
    <> " · "
    <> strand
    <> place

  span.line_new([
    span.span_styled(
      " Ask",
      style.new(theme.signal, style.Default, style.bold()),
    ),
    span.span_styled(
      " · " <> fit(words, int.max(1, width - 8)),
      style.new(theme.paper, style.Default, style.bold()),
    ),
  ])
}

/// The clock time of a Unix millisecond reading: local when the host knows its
/// offset from UTC, and marked UTC when it does not.
///
/// ## Examples
///
/// ```gleam
/// assert ask_panel.time_words(0, option.Some(0)) == "00:00"
/// ```
pub fn time_words(at: Int, clock_offset: Option(Int)) -> String {
  let offset = option.unwrap(clock_offset, 0)
  let minutes = at / 60_000 + offset

  // A time before the epoch's midnight wraps to the day before.
  let day_minute = case minutes % 1440 {
    negative if negative < 0 -> negative + 1440
    positive -> positive
  }

  let clock =
    string.pad_start(int.to_string(day_minute / 60), 2, "0")
    <> ":"
    <> string.pad_start(int.to_string(day_minute % 60), 2, "0")

  // A host with no offset cannot say the local time, so it says UTC.
  case clock_offset {
    Some(_) -> clock
    None -> clock <> " UTC"
  }
}

/// The reason the model gave for asking, when it gave one.
fn why_lines(form: Form, width: Int) -> List(Drawn) {
  case form.ask.why {
    None -> []
    Some(why) ->
      wrapped("Why: " <> text_hygiene.single_line(why), quiet(), width - 2)
      |> list.map(fn(line) { Drawn(None, indent(line)) })
  }
}

/// One question: its prompt, then a row for each thing the owner can pick or
/// type.
fn question_lines(
  form: Form,
  question: attention.Question,
  index: Int,
  keyboard: Keyboard,
  width: Int,
) -> List(Drawn) {
  let prompt =
    int.to_string(index + 1)
    <> ". "
    <> text_hygiene.single_line(question.prompt)
    <> kind_words(question.kind)
  let heading =
    wrapped(
      prompt,
      style.new(theme.paper, style.Default, style.bold()),
      width - 2,
    )
    |> list.map(fn(line) { Drawn(None, indent(line)) })

  let rows =
    ask_form.rows(form)
    |> list.index_map(fn(row, at) { #(at, row) })
    |> list.filter(fn(entry) { belongs(entry.1, index) })
    |> list.map(fn(entry) {
      let #(at, row) = entry
      let under = under_cursor(keyboard, form, at)
      Drawn(Some(at), row_line(form, question, row, under, width))
    })

  list.append(heading, rows)
}

/// Whether the cursor stands on the row at `at` of a card that has the
/// keyboard.
fn under_cursor(keyboard: Keyboard, form: Form, at: Int) -> Keyboard {
  case keyboard, form.cursor == at {
    Here, True -> Here
    Here, False | Away, True | Away, False -> Away
  }
}

/// Whether a row belongs to the question at `index`.
fn belongs(row: ask_form.Row, index: Int) -> Bool {
  case row {
    ask_form.Pick(question:, ..)
    | ask_form.OtherRow(question:)
    | ask_form.FillRow(question:) -> question == index
    ask_form.SendRow -> False
  }
}

/// What a question asks for, in a few words after its prompt.
fn kind_words(kind: attention.Kind) -> String {
  case kind {
    attention.Confirm -> "  (yes or no)"
    attention.Choice -> "  (pick one)"
    attention.Multiple(min:, max:) ->
      "  (pick " <> int.to_string(min) <> " to " <> int.to_string(max) <> ")"
    attention.Checklist -> "  (pick any)"
    attention.Fill(format:) ->
      case format {
        attention.ShortText -> "  (text)"
        attention.LongText -> "  (a paragraph)"
        attention.FilePath -> "  (a file path)"
        attention.Number -> "  (a number)"
        attention.Url -> "  (a URL)"
      }
  }
}

/// One row the cursor can stand on.
fn row_line(
  form: Form,
  question: attention.Question,
  row: ask_form.Row,
  under: Keyboard,
  width: Int,
) -> span.Line {
  let #(mark, words, tail) = row_parts(form, question, row)

  // The row under the cursor is raised and pointed at.
  let ground = case under {
    Here -> theme.raised
    Away -> style.Default
  }

  // The pointer marks the same row the raised ground does.
  let pointer = case under {
    Here -> " › "
    Away -> "   "
  }

  // The words take the room the mark leaves, and the quiet tail what is left.
  let used = string.length(pointer) + string.length(mark) + 1
  let room = int.max(1, width - used - 1)
  let shown = fit(words, room)
  let quiet_room = int.max(0, room - string.length(shown))

  span.line_new([
    span.span_styled(pointer, style.new(theme.signal, ground, style.bold())),
    span.span_styled(mark <> " ", style.new(theme.signal, ground, style.bold())),
    span.span_styled(shown, style.new(theme.paper, ground, style.none())),
    span.span_styled(
      fit(tail, quiet_room),
      style.new(theme.quiet, ground, style.none()),
    ),
    span.span_styled(
      string.repeat(
        " ",
        int.max(0, quiet_room - string.length(fit(tail, quiet_room))),
      ),
      style.new(theme.paper, ground, style.none()),
    ),
  ])
}

/// The mark, the words and the quiet tail of a row.
fn row_parts(
  form: Form,
  question: attention.Question,
  row: ask_form.Row,
) -> #(String, String, String) {
  let choosing = box(question.kind)

  // Each kind of row says what it holds and whether the draft has it chosen.
  case row {
    ask_form.Pick(question: at, option:) -> {
      let alternative =
        ask_form.options(question)
        |> list.drop(option)
        |> list.first

      // The draft says whether this option is chosen.
      let picked = case
        list.contains(ask_form.draft_of(form, at).picked, option)
      {
        True -> Picked
        False -> Unpicked
      }

      // An option the question no longer has draws as an empty row.
      case alternative {
        Ok(found) -> #(
          mark(choosing, picked),
          text_hygiene.single_line(found.label),
          option_tail(found),
        )
        Error(Nil) -> #(mark(choosing, picked), "", "")
      }
    }
    ask_form.OtherRow(question: at) -> {
      let draft = ask_form.draft_of(form, at)
      let cursor = typing_cursor(form, row)

      // Other shows its text once it is chosen, and only its name before.
      case draft.other {
        Some(text) -> #(
          mark(choosing, Picked),
          "Other: " <> text_hygiene.single_line(text) <> cursor,
          "",
        )
        None -> #(mark(choosing, Unpicked), "Other", "")
      }
    }
    ask_form.FillRow(question: at) -> {
      let draft = ask_form.draft_of(form, at)

      // An empty field offers to be typed into; one with text shows it.
      case draft.text, form.entry {
        "", ask_form.Browsing -> #("[ ]", "type an answer", "  Enter to type")
        text, _ -> #(
          "[•]",
          text_hygiene.single_line(text) <> typing_cursor(form, row),
          "",
        )
      }
    }
    ask_form.SendRow -> #("[ ]", "Send answer", "")
  }
}

/// A block cursor after text being typed into the row under the cursor.
fn typing_cursor(form: Form, row: ask_form.Row) -> String {
  // Only the row being typed into shows the cursor.
  case form.entry, ask_form.row_at(form) == row {
    ask_form.Typing, True -> "▏"
    ask_form.Typing, False
    | ask_form.Browsing, True
    | ask_form.Browsing, False
    -> ""
  }
}

/// Whether a kind's options are drawn as radio marks or as boxes.
type Box {
  Radio
  Boxes
}

/// The kind of mark a question's options take.
fn box(kind: attention.Kind) -> Box {
  case kind {
    attention.Multiple(..) | attention.Checklist -> Boxes
    attention.Confirm | attention.Choice | attention.Fill(..) -> Radio
  }
}

/// The mark of an option row.
fn mark(box: Box, picked: Chosen) -> String {
  case box, picked {
    Radio, Picked -> "(•)"
    Radio, Unpicked -> "( )"
    Boxes, Picked -> "[x]"
    Boxes, Unpicked -> "[ ]"
  }
}

/// What follows an option's label: its note and whether the model recommends
/// it.
fn option_tail(option: attention.Alternative) -> String {
  // The note is the model's words about what choosing the option does.
  let note = case option.note {
    Some(text) -> "  " <> text_hygiene.single_line(text)
    None -> ""
  }

  // Only the model's one suggestion carries the mark.
  let recommended = case option.emphasis {
    attention.Recommended -> "  (recommended)"
    attention.Plain -> ""
  }

  recommended <> note
}

/// The Send row.
fn send_lines(form: Form, keyboard: Keyboard, width: Int) -> List(Drawn) {
  // An observer's card has no controls, and a card that does not have the
  // keyboard offers none yet, so only the focused card draws a Send row.
  case form.standing, keyboard {
    ask_form.ObserverOnly, Here
    | ask_form.ObserverOnly, Away
    | ask_form.MayAnswer, Away
    -> []
    ask_form.MayAnswer, Here -> {
      let at = list.length(ask_form.rows(form)) - 1
      let under = under_cursor(keyboard, form, at)
      [
        Drawn(
          Some(at),
          row_line(form, empty_question(), ask_form.SendRow, under, width),
        ),
      ]
    }
  }
}

/// A question with nothing in it, for the rows that belong to none.
fn empty_question() -> attention.Question {
  attention.Question("", "", attention.Choice, [])
}

/// Why the last send did not go, when it did not.
fn refusal_lines(form: Form, width: Int) -> List(Drawn) {
  case form.refusal {
    None -> []
    Some(words) ->
      wrapped(
        words,
        style.new(theme.danger, style.Default, style.none()),
        width - 2,
      )
      |> list.map(fn(line) { Drawn(None, indent(line)) })
  }
}

/// The key hints in the card's last row.
fn hints(board: Board, extent: Extent, width: Int) -> span.Line {
  // While an answer is on its way the card says so and offers no keys.
  let items = case board.phase, ask_board.focused(board) {
    ask_board.Sending(..), _ -> ["Sending your answer…"]
    ask_board.ReadDue, Some(#(_, form))
    | ask_board.Reading, Some(#(_, form))
    | ask_board.Resting(..), Some(#(_, form))
    -> focused_hints(form)
    ask_board.ReadDue, None
    | ask_board.Reading, None
    | ask_board.Resting(..), None
    -> idle_hints(board, extent)
  }

  span.line_new([
    span.span_styled(
      joined(items, width),
      style.new(theme.quiet, style.Default, style.none()),
    ),
  ])
}

/// The hints joined by dots, dropping the ones that would overflow `width`, so
/// a narrow terminal loses the last hints and never half of one.
fn joined(items: List(String), width: Int) -> String {
  list.fold(items, "", fn(drawn, item) {
    // The first hint opens the line; each later one follows a dot.
    let next = case drawn {
      "" -> " " <> item
      _ -> drawn <> " · " <> item
    }

    // A hint that would overflow is dropped whole.
    case string.length(next) <= width {
      True -> next
      False -> drawn
    }
  })
}

/// The hints while the card has the keyboard.
fn focused_hints(form: Form) -> List(String) {
  case form.entry {
    ask_form.Typing -> [
      "typing",
      "Enter done",
      "Ctrl+S sends",
      "Esc stops typing",
    ]
    ask_form.Browsing -> [
      "↑↓ move",
      "Space picks",
      "Enter types",
      "Tab next question",
      "Ctrl+S sends",
      "Esc composer",
      "PgDn next ask",
    ]
  }
}

/// The hints while the composer has the keyboard.
fn idle_hints(board: Board, extent: Extent) -> List(String) {
  let answerable =
    list.any(board.forms, fn(form) { form.standing == ask_form.MayAnswer })

  // A cut card says there is more of it below.
  let read_more = case extent {
    Cut -> ["more below"]
    Whole -> []
  }

  // The notice, when there is one, replaces the key hint.
  let first = case answerable, board.notice {
    _, Some(notice) -> [notice]
    True, None -> [focus_key_name <> " answers"]
    False, None -> ["You can read this ask but not answer it"]
  }

  list.append(first, read_more)
}

/// A quiet line of plain words.
fn quiet_line(words: String) -> span.Line {
  span.line_new([span.span_styled(words, quiet())])
}

/// The quiet style.
fn quiet() -> style.Style {
  style.new(theme.quiet, style.Default, style.none())
}

/// A line pushed in two cells.
fn indent(line: span.Line) -> span.Line {
  span.line_new([span.span_plain(" "), ..line.spans])
}

/// `text` cut to `width` cells with an ellipsis when it is longer.
fn fit(text: String, width: Int) -> String {
  case string.length(text) <= width {
    True -> text
    False -> string.slice(text, 0, int.max(0, width - 1)) <> "…"
  }
}

/// `text` wrapped to `width` and styled as one style.
fn wrapped(text: String, look: style.Style, width: Int) -> List(span.Line) {
  let wrapped =
    [span.line_new([span.span_styled(text, look)])]
    |> span.text_new
    |> span.wrap(int.max(1, width))

  wrapped.lines
}
