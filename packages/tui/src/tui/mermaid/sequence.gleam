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
//// A message crosses the lifelines of the participants between its ends and
//// draws `┼` where it does. A note is drawn over the lifelines it spans and
//// clears the cells inside its box, which is how a note reads as sitting on
//// them rather than behind them.
////
//// ## Flow
////
//// `draw` → `column_gaps` → `centres` → `paint_events`
////
//// 1. `column_gaps` starts from the participant box widths and applies
////    `needs_of` every event in order of increasing range.
//// 2. `centres` turns the gaps into column positions and the shift that keeps
////    the leftmost thing on the canvas.
//// 3. `paint_events` walks the events, drawing each with `paint_message`,
////    `paint_self_message` or `paint_note` and advancing the row.

import etui/text
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import tui/mermaid/canvas.{type Canvas}
import tui/mermaid/model.{
  type Event, type Message, type NotePlace, type Participant, type Refusal,
  type Sequence,
}

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

// The height of a participant box and of a note box.
const box_height = 3

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
  let widths = list.map(diagram.participants, box_width)
  let gaps = column_gaps(diagram, widths)
  let columns = centres(diagram, widths, gaps)
  let rows = body_rows(diagram.events)
  let height = box_height + rows
  let width = canvas_width(diagram, widths, columns)
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

fn box_width(participant: Participant) -> Int {
  text.cell_width(participant.label) + 4
}

// ---------------------------------------------------------------------------
// Columns
// ---------------------------------------------------------------------------

// The gap between each participant's centre and the next one's. A gap starts
// at what the two boxes need and grows to satisfy each event's needs.
fn column_gaps(diagram: Sequence, widths: List(Int)) -> Dict(Int, Int) {
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

// Grows the last gap in a range until the range is wide enough.
fn satisfy(table: Dict(Int, Int), need: Need) -> Dict(Int, Int) {
  let current =
    list.fold(canvas.between(need.first, need.last - 1), 0, fn(total, index) {
      total + result.unwrap(dict.get(table, index), 0)
    })
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

// What an event asks of the column spacing.
fn needs_of(event: Event) -> List(Need) {
  case event {
    model.Said(message) -> message_needs(message)
    model.Noted(place:, text: words) -> note_needs(place, words)
  }
}

fn message_needs(message: Message) -> List(Need) {
  let label = text.cell_width(message.text)
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

fn note_needs(place: NotePlace, words: String) -> List(Need) {
  let box = text.cell_width(words) + 4
  case place {
    model.Over(first, last) if first == last -> [
      Need(first - 1, first, box / 2 + 3),
      Need(first, first + 1, box / 2 + 3),
    ]
    model.Over(first, last) -> [
      Need(first, last, int.max(0, text.cell_width(words) - 1)),
    ]
    model.LeftOf(index) -> [Need(index - 1, index, box + 3)]
    model.RightOf(index) -> [Need(index, index + 1, box + 3)]
  }
}

// Column centres from the gaps, and the shift that puts the leftmost cell of
// anything at the canvas edge.
fn centres(
  diagram: Sequence,
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
        model.Noted(place: model.LeftOf(index), text: words) ->
          int.min(
            least,
            result.unwrap(dict.get(positions, index), 0)
              - 1
              - { text.cell_width(words) + 4 },
          )
        model.Noted(place: model.Over(first, last), text: words)
          if first == last
        ->
          int.min(
            least,
            result.unwrap(dict.get(positions, first), 0)
              - { text.cell_width(words) + 4 }
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

// A canvas wide enough for the last column, its box, and anything that
// reaches to the right of it. Cropping removes the slack.
fn canvas_width(diagram: Sequence, widths: List(Int), columns: Columns) -> Int {
  let last = list.length(widths) - 1
  let last_width = result.unwrap(list.last(widths), 0)
  let reach =
    list.fold(diagram.events, last_width, fn(widest, event) {
      case event {
        model.Said(message) ->
          int.max(widest, text.cell_width(message.text) + loop_reach + 4)
        model.Noted(text: words, ..) ->
          int.max(widest, text.cell_width(words) + 8)
      }
    })
  centre_of(columns, last) + reach + 2
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

fn paint_headers(
  painted: Canvas,
  diagram: Sequence,
  widths: List(Int),
  columns: Columns,
) -> Canvas {
  list.zip(diagram.participants, widths)
  |> list.index_fold(painted, fn(current, pair, index) {
    let #(participant, width) = pair
    canvas.draw_box(
      current,
      model.Box(
        x: centre_of(columns, index) - width / 2,
        y: 0,
        width:,
        height: box_height,
      ),
      model.Rectangle,
      [participant.label],
    )
  })
}

// A lifeline from the foot of the header to the bottom of the diagram.
fn paint_lifelines(
  painted: Canvas,
  diagram: Sequence,
  columns: Columns,
  height: Int,
) -> Canvas {
  list.index_fold(diagram.participants, painted, fn(current, _, index) {
    list.fold(canvas.between(box_height, height - 1), current, fn(inner, y) {
      canvas.put_ink(inner, centre_of(columns, index), y, "│", canvas.Wire)
    })
  })
}

// The rows the events occupy: three for a message, five for a self-message
// and four for a note, each ending in a blank row.
fn body_rows(events: List(Event)) -> Int {
  list.fold(events, 0, fn(total, event) { total + rows_of(event) })
}

fn rows_of(event: Event) -> Int {
  case event {
    model.Said(message) if message.from == message.to -> 5
    model.Said(_) -> 3
    model.Noted(..) -> 4
  }
}

fn paint_events(
  painted: Canvas,
  diagram: Sequence,
  columns: Columns,
) -> Canvas {
  let #(done, _) =
    list.fold(diagram.events, #(painted, box_height), fn(state, event) {
      let #(current, y) = state
      let drawn = case event {
        model.Said(message) if message.from == message.to ->
          paint_self_message(current, message, columns, y)
        model.Said(message) -> paint_message(current, message, columns, y)
        model.Noted(place:, text: words) ->
          paint_note(current, place, words, columns, y)
      }
      #(drawn, y + rows_of(event))
    })
  done
}

fn horizontal(message: Message) -> String {
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

// One message between two columns: the label on the first row, the line and
// its ends on the second. The line crosses a lifeline with `┼`, the sender's
// end is a tee on its lifeline, and the receiving end is an arrowhead, a
// cross, or a tee on the receiver's lifeline when there is neither.
fn paint_message(
  painted: Canvas,
  message: Message,
  columns: Columns,
  y: Int,
) -> Canvas {
  let from = centre_of(columns, message.from)
  let to = centre_of(columns, message.to)
  let way = case from < to {
    True -> Rightward
    False -> Leftward
  }

  painted
  |> paint_run(message, columns, int.min(from, to), int.max(from, to), y + 1)
  |> canvas.put_text(int.min(from, to) + 2, y, message.text, canvas.Label)
  |> paint_ends(message, way, from, to, y + 1)
}

// The line between two columns, with `┼` where it crosses another lifeline.
fn paint_run(
  painted: Canvas,
  message: Message,
  columns: Columns,
  low: Int,
  high: Int,
  y: Int,
) -> Canvas {
  let centres =
    list.map(dict.values(columns.centres), fn(c) { c + columns.shift })
  list.fold(canvas.between(low + 1, high - 1), painted, fn(current, x) {
    let glyph = case list.contains(centres, x) {
      True -> "┼"
      False -> horizontal(message)
    }
    canvas.put_ink(current, x, y, glyph, canvas.Wire)
  })
}

// The two ends of a message: a tee on the sender's lifeline, and at the
// receiver an arrowhead or cross beside the lifeline, or a tee on it.
fn paint_ends(
  painted: Canvas,
  message: Message,
  way: Way,
  from: Int,
  to: Int,
  y: Int,
) -> Canvas {
  let sender_end = case way {
    Rightward -> "├"
    Leftward -> "┤"
  }
  let sent = canvas.put_ink(painted, from, y, sender_end, canvas.Wire)
  let tip_x = case way {
    Rightward -> to - 1
    Leftward -> to + 1
  }
  case message.end, way {
    model.Head, Rightward -> canvas.put_ink(sent, tip_x, y, "▶", canvas.Head)
    model.Head, Leftward -> canvas.put_ink(sent, tip_x, y, "◀", canvas.Head)
    model.Cross, _ -> canvas.put_ink(sent, tip_x, y, "×", canvas.Head)
    model.Plain, Rightward -> canvas.put_ink(sent, to, y, "┤", canvas.Wire)
    model.Plain, Leftward -> canvas.put_ink(sent, to, y, "├", canvas.Wire)
  }
}

// A message from a participant to itself: a loop out to the right and back,
// drawn over four rows under the label.
fn paint_self_message(
  painted: Canvas,
  message: Message,
  columns: Columns,
  y: Int,
) -> Canvas {
  let x = centre_of(columns, message.from)
  let bar = horizontal(message)
  let out = string.repeat(bar, loop_reach - 1)
  let back = case message.end {
    model.Head -> "◀" <> string.repeat(bar, loop_reach - 2)
    model.Cross -> "×" <> string.repeat(bar, loop_reach - 2)
    model.Plain -> string.repeat(bar, loop_reach - 1)
  }
  let start = case message.end {
    model.Plain -> "┤"
    _ -> "│"
  }
  painted
  |> canvas.put_text(x + 2, y, message.text, canvas.Label)
  |> canvas.put_ink(x, y + 1, "├", canvas.Wire)
  |> canvas.put_text(x + 1, y + 1, out, canvas.Wire)
  |> canvas.put_ink(x + loop_reach, y + 1, "┐", canvas.Wire)
  |> canvas.put_ink(x + loop_reach, y + 2, "│", canvas.Wire)
  |> canvas.put_ink(x, y + 3, start, canvas.Wire)
  |> canvas.put_text(x + 1, y + 3, back, canvas.Wire)
  |> canvas.put_ink(x + loop_reach, y + 3, "┘", canvas.Wire)
}

// A note: a box over the lifelines it names, with its interior cleared so the
// lifelines do not show through the text.
fn paint_note(
  painted: Canvas,
  place: NotePlace,
  words: String,
  columns: Columns,
  y: Int,
) -> Canvas {
  let inner = text.cell_width(words)
  let box = case place {
    model.Over(first, last) if first == last -> {
      let width = inner + 4
      model.Box(
        x: centre_of(columns, first) - width / 2,
        y:,
        width:,
        height: box_height,
      )
    }
    model.Over(first, last) -> {
      let left = centre_of(columns, first) - 2
      let right = centre_of(columns, last) + 2
      model.Box(x: left, y:, width: right - left + 1, height: box_height)
    }
    model.LeftOf(index) -> {
      let width = inner + 4
      model.Box(
        x: centre_of(columns, index) - 1 - width,
        y:,
        width:,
        height: box_height,
      )
    }
    model.RightOf(index) ->
      model.Box(
        x: centre_of(columns, index) + 2,
        y:,
        width: inner + 4,
        height: box_height,
      )
  }
  let cleared =
    list.fold(
      canvas.between(box.y, box.y + box_height - 1),
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
  canvas.draw_box(cleared, box, model.Rectangle, [words])
}
