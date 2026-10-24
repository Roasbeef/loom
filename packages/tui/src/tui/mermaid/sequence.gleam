//// Sequence diagram drawing: participants across the top, time running down.
////
//// A sequence diagram needs no routing. Every participant owns a column for
//// the whole diagram, every message is one horizontal run between two
//// columns, and every event gets rows of its own, so the layout is a matter
//// of choosing how far apart the columns are. Two participants must be at
//// least far enough apart for their boxes, and for every message, note and
//// self-loop whose text sits between or beside them. Those are lower bounds
//// on the sum of the gaps over a range, so one pass in order of increasing
//// range, growing the last gap of any range that falls short, satisfies them
//// all: a later growth can only add room to a range already satisfied.
////
//// Multi-word labels longer than `model.max_label_cells` wrap onto multiple
//// lines, and when a multi-participant diagram would exceed the caller's
//// terminal width (`draw_within`), participant headers, messages and notes
//// wrap to fit the available column budget.
////
//// A message crosses the lifelines of the participants between its ends and
//// draws `┼` where it does. A note is drawn over the lifelines it spans and
//// clears the cells inside its box, which is how a note reads as sitting on
//// them rather than behind them.
////
//// ## Flow
////
//// `draw_within` → `draw_wrapped` → `column_gaps` → `centres` → `paint_events`
////
//// 1. `draw_within` lays out the diagram with `wrap_sequence` at
////    `model.max_label_cells` and, when the resulting drawing exceeds
////    the target width, re-wraps headers, messages and notes with
////    `column_budget` before calling `draw_wrapped`.
//// 2. `column_gaps` starts from the participant box widths and applies
////    `needs_of` every event in order of increasing range.
//// 3. `centres` turns the gaps into column positions and the shift that keeps
////    the leftmost thing on the canvas.
//// 4. `paint_events` walks the events, drawing each with `paint_message`,
////    `paint_self_message` or `paint_note` and advancing the row.

import etui/text
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import tui/mermaid/canvas.{type Canvas}
import tui/mermaid/model.{
  type Event, type MessageEnd, type NotePlace, type Participant, type Refusal,
  type Sequence, type Stroke,
}
import tui/mermaid/parse

// A lower bound on the distance between two columns: the participants at
// `first` and `last`, and the least their centres may be apart.
type Need {
  Need(first: Int, last: Int, distance: Int)
}

// Where the diagram is laid out: the column centres and the leftmost cell
// anything occupies, so everything can be shifted onto the canvas.
type Columns {
  Columns(centres: Dict(Int, Int), shift: Int)
}

type WrappedMessage {
  WrappedMessage(
    from: Int,
    to: Int,
    stroke: Stroke,
    end: MessageEnd,
    lines: List(String),
  )
}

type WrappedEvent {
  WrappedSaid(WrappedMessage)
  WrappedNoted(place: NotePlace, lines: List(String))
}

type WrappedSequence {
  WrappedSequence(
    participants: List(List(String)),
    header_height: Int,
    events: List(WrappedEvent),
  )
}

type WrapStyle {
  SoftWrap
  CompactWrap
}

// How far a self-message's loop reaches to the right of its lifeline.
const loop_reach = 4

/// Draws a sequence diagram onto a canvas, or says why it cannot.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(canvas) = sequence.draw(diagram)
/// ```
pub fn draw(diagram: Sequence) -> Result(Canvas, Refusal) {
  draw_within(diagram, model.max_canvas_cells)
}

/// Draws a sequence diagram onto a canvas, wrapping labels to fit `max_width`
/// when the unwrapped layout would exceed the terminal width.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(canvas) = sequence.draw_within(diagram, 100)
/// ```
pub fn draw_within(
  diagram: Sequence,
  max_width: Int,
) -> Result(Canvas, Refusal) {
  let soft = wrap_sequence(diagram, model.max_label_cells, SoftWrap)
  let count = list.length(diagram.participants)

  // Attempt soft-wrapped layout, re-wrapping compact if canvas overflows.
  case draw_wrapped(soft) {
    Ok(drawn) ->
      case
        canvas.rows_width(canvas.rows(drawn)) <= max_width
        || max_width < count * 10
      {
        True -> Ok(drawn)
        False -> {
          let col_budget = column_budget(max_width, count)
          draw_wrapped(wrap_sequence(diagram, col_budget, CompactWrap))
        }
      }
    Error(_) if max_width >= count * 10 -> {
      let col_budget = column_budget(max_width, count)
      draw_wrapped(wrap_sequence(diagram, col_budget, CompactWrap))
    }
    Error(refusal) -> Error(refusal)
  }
}

/// Calculates available width per column based on canvas limits and participant count.
fn column_budget(max_width: Int, count: Int) -> Int {
  int.clamp(
    { max_width + 2 } / int.max(1, count) - 6,
    min: 4,
    max: model.max_label_cells,
  )
}

/// Applies text wrapping rules to diagram labels according to wrap style.
fn wrap_sequence(
  diagram: Sequence,
  col_budget: Int,
  style: WrapStyle,
) -> WrappedSequence {
  let participants =
    list.map(diagram.participants, fn(participant: Participant) {
      non_empty_lines(wrap_text(participant.label, col_budget, style))
    })
  let max_header_lines =
    list.fold(participants, 1, fn(best, lines) {
      int.max(best, list.length(lines))
    })
  let events =
    list.map(diagram.events, fn(event: Event) {
      // Transform individual events with appropriate line wrapping.
      case event {
        model.Said(message) -> {
          let span = int.max(1, int.absolute_value(message.to - message.from))

          // Compute label budget based on wrap style and column span.
          let budget = case style {
            SoftWrap -> model.max_label_cells
            CompactWrap ->
              int.min(model.max_label_cells, span * { col_budget + 6 } - 4)
          }

          WrappedSaid(WrappedMessage(
            from: message.from,
            to: message.to,
            stroke: message.stroke,
            end: message.end,
            lines: wrap_message_lines(message.text, budget, style),
          ))
        }
        model.Noted(place:, text: words) -> {
          // Determine participant span covered by note placement.
          let span = case place {
            model.Over(first, last) -> int.max(1, last - first + 1)
            model.LeftOf(_) | model.RightOf(_) -> 1
          }

          // Compute note label budget based on wrap style and note span.
          let budget = case style {
            SoftWrap -> model.max_label_cells
            CompactWrap ->
              int.min(model.max_label_cells, span * { col_budget + 6 } - 4)
          }

          WrappedNoted(
            place:,
            lines: non_empty_lines(wrap_text(words, budget, style)),
          )
        }
      }
    })
  WrappedSequence(participants:, header_height: max_header_lines + 2, events:)
}

/// Wraps message line text within budget constraints.
fn wrap_message_lines(
  text: String,
  budget: Int,
  style: WrapStyle,
) -> List(String) {
  case text {
    "" -> [""]
    _ -> non_empty_lines(wrap_text(text, budget, style))
  }
}

fn non_empty_lines(lines: List(String)) -> List(String) {
  case lines {
    [] -> [""]
    _ -> lines
  }
}

/// Wraps text to lines honoring soft or compact wrapping style.
fn wrap_text(text: String, budget: Int, style: WrapStyle) -> List(String) {
  let limit = int.max(4, budget)
  let by_words = parse.wrap_words(text, limit)

  // Choose token breaking behavior based on wrap style.
  case style {
    SoftWrap -> by_words
    CompactWrap -> list.flat_map(by_words, split_long_token(_, limit))
  }
}

fn split_long_token(line: String, limit: Int) -> List(String) {
  case text.cell_width(line) <= limit {
    True -> [line]
    False -> chunk_graphemes(string.to_graphemes(line), "", 0, [], limit)
  }
}

/// Breaks grapheme list into fixed-width chunks.
fn chunk_graphemes(
  rest: List(String),
  current: String,
  current_width: Int,
  done: List(String),
  limit: Int,
) -> List(String) {
  // Process remaining graphemes or finish chunk collection.
  case rest {
    [] ->
      case current {
        "" -> list.reverse(done)
        _ -> list.reverse([current, ..done])
      }
    [g, ..more] -> {
      let gw = int.max(1, text.grapheme_cell_width(g))

      // Check whether adding grapheme exceeds chunk width limit.
      case current != "" && current_width + gw > limit {
        True -> chunk_graphemes(rest, "", 0, [current, ..done], limit)
        False ->
          chunk_graphemes(more, current <> g, current_width + gw, done, limit)
      }
    }
  }
}

/// Draws a sequence diagram whose participants and events have been wrapped.
fn draw_wrapped(diagram: WrappedSequence) -> Result(Canvas, Refusal) {
  let widths = list.map(diagram.participants, box_width)
  let gaps = column_gaps(diagram, widths)
  let columns = centres(diagram, widths, gaps)
  let rows = body_rows(diagram.events)
  let height = diagram.header_height + rows
  let width = canvas_width(diagram, widths, columns)

  // Reject diagrams exceeding maximum canvas cell limit.
  case width * height > model.max_canvas_cells {
    True -> Error(model.TooLarge(model.CanvasCells))
    False -> {
      let blank = canvas.new(width, height)
      let headed = paint_headers(blank, diagram, widths, columns)
      let lifelines = paint_lifelines(headed, diagram, columns, height)
      Ok(paint_events(lifelines, diagram, columns))
    }
  }
}

fn box_width(lines: List(String)) -> Int {
  widest_line(lines) + 4
}

fn widest_line(lines: List(String)) -> Int {
  list.fold(lines, 0, fn(best, line) { int.max(best, text.cell_width(line)) })
}

// ---------------------------------------------------------------------------
// Columns
// ---------------------------------------------------------------------------

/// The gap between each participant's centre and the next one's. A gap starts
fn column_gaps(diagram: WrappedSequence, widths: List(Int)) -> Dict(Int, Int) {
  let count = list.length(widths)
  let base =
    list.zip(widths, list.drop(widths, 1))
    |> list.index_fold(dict.new(), fn(table, neighbours, index) {
      let #(left, right) = neighbours
      dict.insert(table, index, left - left / 2 + right / 2 + 2)
    })
  diagram.events
  |> list.flat_map(needs_of)
  |> list.filter(fn(need) { need.first >= 0 && need.last < count })
  |> list.sort(fn(a, b) { int.compare(a.last - a.first, b.last - b.first) })
  |> list.fold(base, fn(table, need) { satisfy(table, need) })
}

/// Grows the last gap in a range until the range is wide enough.
fn satisfy(table: Dict(Int, Int), need: Need) -> Dict(Int, Int) {
  let current =
    list.fold(canvas.between(need.first, need.last - 1), 0, fn(total, index) {
      total + result.unwrap(dict.get(table, index), 0)
    })

  // Expand gap if current width falls short of requirement.
  case current >= need.distance || need.last <= need.first {
    True -> table
    False -> {
      let last = need.last - 1
      dict.insert(
        table,
        last,
        result.unwrap(dict.get(table, last), 0) + need.distance - current,
      )
    }
  }
}

/// Extracts column width requirement for an event.
fn needs_of(event: WrappedEvent) -> List(Need) {
  case event {
    WrappedSaid(message) -> message_needs(message)
    WrappedNoted(place:, lines:) -> note_needs(place, lines)
  }
}

/// Returns column spacing requirements for a message event.
fn message_needs(message: WrappedMessage) -> List(Need) {
  let label = widest_line(message.lines)

  // Distinguish self-messages from normal peer-to-peer messages.
  case message.from == message.to {
    True -> [
      Need(message.from, message.from + 1, int.max(label + 4, loop_reach + 2)),
    ]
    False -> [
      Need(
        int.min(message.from, message.to),
        int.max(message.from, message.to),
        int.max(label + 4, 4),
      ),
    ]
  }
}

/// Returns column spacing requirements for a note event.
fn note_needs(place: NotePlace, lines: List(String)) -> List(Need) {
  let widest = widest_line(lines)
  let box = widest + 4

  // Map note placement to affected column spans.
  case place {
    model.Over(first, last) if first == last -> [
      Need(first - 1, first, box / 2 + 3),
      Need(first, first + 1, box / 2 + 3),
    ]
    model.Over(first, last) -> [
      Need(first, last, int.max(0, widest - 1)),
    ]
    model.LeftOf(index) -> [Need(index - 1, index, box + 3)]
    model.RightOf(index) -> [Need(index, index + 1, box + 3)]
  }
}

/// Column centres from the gaps, and the shift that puts the leftmost cell of
fn centres(
  diagram: WrappedSequence,
  widths: List(Int),
  gaps: Dict(Int, Int),
) -> Columns {
  let count = list.length(widths)
  let #(positions, _) =
    list.fold(model.indices(count), #(dict.new(), 0), fn(state, index) {
      let #(table, at) = state
      #(
        dict.insert(table, index, at),
        at + result.unwrap(dict.get(gaps, index), 0),
      )
    })
  let reach =
    list.index_fold(widths, 0, fn(least, width, index) {
      let centre = result.unwrap(dict.get(positions, index), 0)
      int.min(least, centre - width / 2)
    })
  let notes =
    list.fold(diagram.events, reach, fn(least, event) {
      case event {
        WrappedNoted(place: model.LeftOf(index), lines:) ->
          int.min(
            least,
            result.unwrap(dict.get(positions, index), 0)
              - 1
              - { widest_line(lines) + 4 },
          )
        WrappedNoted(place: model.Over(first, last), lines:) if first == last ->
          int.min(
            least,
            result.unwrap(dict.get(positions, first), 0)
              - { widest_line(lines) + 4 }
              / 2,
          )
        _ -> least
      }
    })
  Columns(centres: positions, shift: 0 - notes)
}

fn centre_of(columns: Columns, index: Int) -> Int {
  result.unwrap(dict.get(columns.centres, index), 0) + columns.shift
}

/// A canvas wide enough for the last column, its box, and anything that
/// reaches to the right of it. Cropping removes the slack.
fn canvas_width(
  diagram: WrappedSequence,
  widths: List(Int),
  columns: Columns,
) -> Int {
  let last = list.length(widths) - 1
  let last_width = result.unwrap(list.last(widths), 0)
  let reach =
    list.fold(diagram.events, last_width, fn(widest, event) {
      case event {
        WrappedSaid(message) ->
          int.max(widest, widest_line(message.lines) + loop_reach + 4)
        WrappedNoted(lines:, ..) -> int.max(widest, widest_line(lines) + 8)
      }
    })
  centre_of(columns, last) + reach + 2
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

/// Paints participant header boxes along the top row.
fn paint_headers(
  painted: Canvas,
  diagram: WrappedSequence,
  widths: List(Int),
  columns: Columns,
) -> Canvas {
  list.zip(diagram.participants, widths)
  |> list.index_fold(painted, fn(current, pair, index) {
    let #(lines, width) = pair
    canvas.draw_box(
      current,
      model.Box(
        x: centre_of(columns, index) - width / 2,
        y: 0,
        width:,
        height: diagram.header_height,
      ),
      model.Rectangle,
      lines,
    )
  })
}

/// A lifeline from the foot of the header to the bottom of the diagram.
fn paint_lifelines(
  painted: Canvas,
  diagram: WrappedSequence,
  columns: Columns,
  height: Int,
) -> Canvas {
  list.index_fold(diagram.participants, painted, fn(current, _, index) {
    list.fold(
      canvas.between(diagram.header_height, height - 1),
      current,
      fn(inner, y) {
        canvas.put_ink(inner, centre_of(columns, index), y, "│", canvas.Wire)
      },
    )
  })
}

/// The rows the events occupy: label lines plus two for a message, label lines
/// plus four for a self-message, and label lines plus three for a note.
fn body_rows(events: List(WrappedEvent)) -> Int {
  list.fold(events, 0, fn(total, event) { total + rows_of(event) })
}

/// Calculates height rows needed for an individual event.
fn rows_of(event: WrappedEvent) -> Int {
  case event {
    WrappedSaid(message) if message.from == message.to ->
      list.length(message.lines) + 4
    WrappedSaid(message) -> list.length(message.lines) + 2
    WrappedNoted(lines:, ..) -> list.length(lines) + 3
  }
}

/// Paints all diagram events in sequence onto the canvas.
fn paint_events(
  painted: Canvas,
  diagram: WrappedSequence,
  columns: Columns,
) -> Canvas {
  let #(done, _) =
    list.fold(
      diagram.events,
      #(painted, diagram.header_height),
      fn(state, event) {
        let #(current, y) = state

        // Render event according to its kind.
        let drawn = case event {
          WrappedSaid(message) if message.from == message.to ->
            paint_self_message(current, message, columns, y)
          WrappedSaid(message) -> paint_message(current, message, columns, y)
          WrappedNoted(place:, lines:) ->
            paint_note(current, place, lines, columns, y)
        }

        #(drawn, y + rows_of(event))
      },
    )
  done
}

/// Returns the horizontal line stroke glyph.
fn horizontal(message: WrappedMessage) -> String {
  case message.stroke {
    model.Dotted -> "┄"
    _ -> "─"
  }
}

// The way a message runs across the page.
type Way {
  Rightward
  Leftward
}

/// One message between two columns: its label lines above, then the line and
/// its ends on the row below them.
fn paint_message(
  painted: Canvas,
  message: WrappedMessage,
  columns: Columns,
  y: Int,
) -> Canvas {
  let from = centre_of(columns, message.from)
  let to = centre_of(columns, message.to)

  // Determine direction of arrow propagation.
  let way = case from < to {
    True -> Rightward
    False -> Leftward
  }

  let label_x = int.min(from, to) + 2
  let arrow_y = y + list.length(message.lines)
  let with_labels =
    list.index_fold(message.lines, painted, fn(current, line, offset) {
      canvas.put_text(current, label_x, y + offset, line, canvas.Label)
    })

  with_labels
  |> paint_run(message, columns, int.min(from, to), int.max(from, to), arrow_y)
  |> paint_ends(message, way, from, to, arrow_y)
}

/// The line between two columns, with `┼` where it crosses another lifeline.
fn paint_run(
  painted: Canvas,
  message: WrappedMessage,
  columns: Columns,
  low: Int,
  high: Int,
  y: Int,
) -> Canvas {
  let centres =
    list.map(dict.values(columns.centres), fn(c) { c + columns.shift })
  list.fold(canvas.between(low + 1, high - 1), painted, fn(current, x) {
    // Insert junction symbol if line intersects a participant lifeline.
    let glyph = case list.contains(centres, x) {
      True -> "┼"
      False -> horizontal(message)
    }

    canvas.put_ink(current, x, y, glyph, canvas.Wire)
  })
}

/// The two ends of a message: a tee on the sender's lifeline, and at the
/// receiver an arrowhead or cross beside the lifeline, or a tee on it.
fn paint_ends(
  painted: Canvas,
  message: WrappedMessage,
  way: Way,
  from: Int,
  to: Int,
  y: Int,
) -> Canvas {
  // Select sender lifeline tee glyph based on direction.
  let sender_end = case way {
    Rightward -> "├"
    Leftward -> "┤"
  }

  let sent = canvas.put_ink(painted, from, y, sender_end, canvas.Wire)

  // Compute tip coordinate based on direction.
  let tip_x = case way {
    Rightward -> to - 1
    Leftward -> to + 1
  }

  // Paint target endpoint marker or arrowhead.
  case message.end, way {
    model.Head, Rightward -> canvas.put_ink(sent, tip_x, y, "▶", canvas.Head)
    model.Head, Leftward -> canvas.put_ink(sent, tip_x, y, "◀", canvas.Head)
    model.Cross, _ -> canvas.put_ink(sent, tip_x, y, "×", canvas.Head)
    model.Plain, Rightward -> canvas.put_ink(sent, to, y, "┤", canvas.Wire)
    model.Plain, Leftward -> canvas.put_ink(sent, to, y, "├", canvas.Wire)
  }
}

/// A message from a participant to itself: a loop out to the right and back,
fn paint_self_message(
  painted: Canvas,
  message: WrappedMessage,
  columns: Columns,
  y: Int,
) -> Canvas {
  let x = centre_of(columns, message.from)
  let bar = horizontal(message)
  let out = string.repeat(bar, loop_reach - 1)

  // Construct return loop path ending and junction markers.
  let back = case message.end {
    model.Head -> "◀" <> string.repeat(bar, loop_reach - 2)
    model.Cross -> "×" <> string.repeat(bar, loop_reach - 2)
    model.Plain -> string.repeat(bar, loop_reach - 1)
  }

  // Select loop root glyph based on end style.
  let start = case message.end {
    model.Plain -> "┤"
    _ -> "│"
  }

  let base_y = y + list.length(message.lines)
  let with_labels =
    list.index_fold(message.lines, painted, fn(current, line, offset) {
      canvas.put_text(current, x + 2, y + offset, line, canvas.Label)
    })

  with_labels
  |> canvas.put_ink(x, base_y, "├", canvas.Wire)
  |> canvas.put_text(x + 1, base_y, out, canvas.Wire)
  |> canvas.put_ink(x + loop_reach, base_y, "┐", canvas.Wire)
  |> canvas.put_ink(x + loop_reach, base_y + 1, "│", canvas.Wire)
  |> canvas.put_ink(x, base_y + 2, start, canvas.Wire)
  |> canvas.put_text(x + 1, base_y + 2, back, canvas.Wire)
  |> canvas.put_ink(x + loop_reach, base_y + 2, "┘", canvas.Wire)
}

/// A note: a box over the lifelines it names, with its interior cleared so the
/// lifelines do not show through the text.
fn paint_note(
  painted: Canvas,
  place: NotePlace,
  lines: List(String),
  columns: Columns,
  y: Int,
) -> Canvas {
  let inner = widest_line(lines)
  let height = list.length(lines) + 2

  // Construct bounding box based on note placement mode.
  let box = case place {
    model.Over(first, last) if first == last -> {
      let width = inner + 4
      model.Box(x: centre_of(columns, first) - width / 2, y:, width:, height:)
    }
    model.Over(first, last) -> {
      let left = centre_of(columns, first) - 2
      let right = centre_of(columns, last) + 2
      let span_width = int.max(inner + 4, right - left + 1)
      let mid = { left + right } / 2
      model.Box(x: mid - span_width / 2, y:, width: span_width, height:)
    }
    model.LeftOf(index) -> {
      let width = inner + 4
      model.Box(x: centre_of(columns, index) - 1 - width, y:, width:, height:)
    }
    model.RightOf(index) ->
      model.Box(x: centre_of(columns, index) + 2, y:, width: inner + 4, height:)
  }

  let cleared =
    list.fold(
      canvas.between(box.y, box.y + box.height - 1),
      painted,
      fn(current, row) {
        canvas.put_text(
          current,
          box.x,
          row,
          string.repeat(" ", box.width),
          canvas.Plain,
        )
      },
    )
  canvas.draw_box(cleared, box, model.Rectangle, lines)
}
