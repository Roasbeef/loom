//// The box a drawable image occupies in the transcript, and finding it again.
////
//// An image a tool returned is a placeholder row (`render.image_rows`) on
//// every terminal. On a terminal that can draw it, the row grows into a
//// labelled box of cells, and the picture is drawn into the cells. This
//// module owns that box: whether an image earns one (`verdict`), what its
//// rows are (`rows`), and how the rest of the client finds a box in rows it
//// has already built (`found`).
////
//// ## Flow
////
//// `verdict` → `rows` → `found`
////
//// 1. `verdict` decides from the terminal's `Support`, the image's
////    `Picture` and the pane's width. It answers with a `Drawing` (the id,
////    which the cells carry, and the box in cells), with `Keep` (the
////    placeholder row is already right), or with `Refuse` and the sentence
////    the row shows beneath itself saying why the image is not drawn.
//// 2. `rows` builds the box for a `Drawing`: a top border carrying the
////    image's words, one row per box row, and a foot carrying the key that
////    opens the image outside the terminal. On kitty and Ghostty the cells
////    inside the box are Unicode placeholders, ordinary text that scrolls,
////    clips and reflows with the rows around it. On iTerm2 they are blank
////    cells, and the picture is drawn over them after the frame.
//// 3. `found` reads a window of already-built rows and reports every box in
////    it. The rows are the only record of where a box landed, and reading
////    them back means the planner agrees with the frame by construction:
////    whatever scrolled, clipped or was covered by another surface is
////    already reflected in the rows it is handed.
////
//// ## The id is the colour
////
//// kitty's placeholder cells address their image by foreground colour: the
//// low 24 bits of the image id are the cell's true-colour foreground. The
//// id is therefore a function of the image's fingerprint, computed with no
//// state, because a row is built before anything is transmitted and must
//// already carry the colour it will be drawn with. Two different images
//// share an id with probability about n squared over 2 to the 25th for n
//// images in one transcript, and the later one transmitted would then show
//// in both boxes; that is a rare, visible and harmless failure of a picture,
//// and the machinery to rule it out would cost more than it saves.
////
//// The same colour marks an iTerm2 box's blank cells, which are no-break
//// spaces, so `found` reads both protocols with one rule.

import etui/graphics
import etui/graphics/kitty
import etui/span
import etui/style
import etui/text
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/image_header.{type Picture}
import tui/image_support.{type Support}
import tui/theme

/// The widest an image's box is drawn, in cells.
pub const max_columns = 60

/// The tallest an image's picture is drawn, in cells, on a tall pane.
pub const max_rows = 12

/// The fewest rows a picture is given, however short the pane.
pub const min_rows = 3

/// How many rows a picture may take on a terminal `height` rows tall: about
/// half of the transcript it leaves, so a short terminal still shows the text
/// around the image, and never outside `min_rows` to `max_rows`. The box adds
/// two rows of border to this.
///
/// It is taken from the terminal's own height, which moves only when the
/// terminal is resized, and not from the transcript's, which moves whenever
/// the composer wraps or a status row appears. A picture that changed size as
/// a person typed would throw the row cache away on every keystroke. The
/// transcript is about five rows shorter than the terminal (the identity
/// line, the input frame and the footer), which is the five taken off here.
///
/// ## Examples
///
/// ```gleam
/// assert image_box.picture_rows(24) == 9
/// assert image_box.picture_rows(60) == 12
/// ```
pub fn picture_rows(height: Int) -> Int {
  int.clamp({ height - 5 } / 2, min_rows, max_rows)
}

/// The largest image drawn, in decoded bytes. The terminal is sent the whole
/// image, base64 encoded, each time it enters view, and the viewport holds at
/// most a few boxes, so this bounds both one write and the memory the
/// terminal keeps for what is in view.
pub const max_bytes = 4_194_304

/// The cells before a box, which seat it under the text of the call row.
const indent = "   "

/// The no-break space that fills an iTerm2 box. It is blank on screen and
/// unlike an ordinary space, so no other row of the transcript can be
/// mistaken for one.
pub const blank = "\u{00A0}"

/// The key the box's foot offers, which is the same key the placeholder row
/// offers.
const key = "o opens externally"

/// An image earning a box: which image it is on the terminal, and how many
/// cells it covers.
pub type Drawing {
  Drawing(
    /// The id the box's cells carry, derived from the image's fingerprint.
    id: kitty.ImageId,
    /// The box the picture is fitted into, in cells, never larger than
    /// `max_columns` by `max_rows` nor than the pane.
    box: graphics.Box,
  )
}

/// What an image row becomes on this terminal.
pub type Verdict {
  /// The row grows into a box.
  Draw(drawing: Drawing)

  /// The placeholder row stays exactly as it is.
  Keep

  /// The placeholder row stays, with `note` beneath it saying why the image
  /// is not drawn.
  Refuse(note: String)
}

/// Decides what an image row becomes.
///
/// The terminal's support comes first: nothing is drawn on a terminal that
/// did not say it could. Then the image itself (`refusal`), and last the
/// room the pane leaves for a box: its width, and the terminal's `height`,
/// of which the picture takes about half the transcript (`picture_rows`).
///
/// ## Examples
///
/// ```gleam
/// assert image_box.verdict(image_support.TextOnly(image_support.NotProbed),
///     picture, 80, 24) == image_box.Keep
/// ```
pub fn verdict(
  support: Support,
  picture: Picture,
  width: Int,
  height: Int,
) -> Verdict {
  case support {
    image_support.TextOnly(..) -> Keep
    image_support.KittyPlaceholders(cell:)
    | image_support.Iterm2Inline(cell:) ->
      case refusal(support, picture) {
        Some(note) -> Refuse(note)
        None -> sized(cell, picture, width, height)
      }
  }
}

/// The sentence that says why this terminal will not draw this image, or
/// `None` when the image is no obstacle.
///
/// kitty's transmission carries a PNG as it is and cannot carry the other
/// formats, and every image is held to `max_bytes`.
///
/// ## Examples
///
/// ```gleam
/// assert image_box.refusal(image_support.TextOnly(image_support.NotProbed), picture)
///   == option.None
/// ```
pub fn refusal(support: Support, picture: Picture) -> Option(String) {
  case support {
    image_support.TextOnly(..) -> None
    image_support.KittyPlaceholders(..) ->
      case picture.mime_type {
        "image/png" -> over_budget(picture)
        _ -> Some("this terminal draws PNG images only")
      }
    image_support.Iterm2Inline(..) -> over_budget(picture)
  }
}

fn over_budget(picture: Picture) -> Option(String) {
  case picture.bytes > max_bytes {
    True ->
      Some(
        "too large to draw in the terminal (limit "
        <> image_header.size_text(max_bytes)
        <> ")",
      )
    False -> None
  }
}

// The room the pane leaves for a box, once the terminal and the image are
// settled.
fn sized(
  cell: graphics.CellSize,
  picture: Picture,
  width: Int,
  height: Int,
) -> Verdict {
  let room = width - string.length(indent) - 4
  let box =
    graphics.fit(
      picture.width,
      picture.height,
      cell,
      graphics.Box(
        columns: int.min(max_columns, room),
        rows: picture_rows(height),
      ),
    )
  case box.columns < 1 || box.rows < 1 {
    True -> Keep
    False ->
      case kitty.image_id(id_of(picture.fingerprint)) {
        Ok(id) -> Draw(Drawing(id:, box:))
        Error(Nil) -> Keep
      }
  }
}

/// The image id a fingerprint stands for: its FNV-1a hash folded to 24 bits,
/// which is what a placeholder cell's colour can carry, and never zero,
/// which the protocol reserves for "no id".
///
/// ## Examples
///
/// ```gleam
/// assert image_box.id_of("4:aGk=:aGk=:aGk=") == image_box.id_of("4:aGk=:aGk=:aGk=")
/// ```
pub fn id_of(fingerprint: String) -> Int {
  let hash = fnv(bit_array.from_string(fingerprint), 2_166_136_261)
  let folded =
    int.bitwise_and(
      int.bitwise_exclusive_or(int.bitwise_shift_right(hash, 24), hash),
      0xFFFFFF,
    )
  case folded {
    0 -> 1
    other -> other
  }
}

// FNV-1a over the bytes, kept to 32 bits at each step.
fn fnv(bytes: BitArray, hash: Int) -> Int {
  case bytes {
    <<byte, rest:bits>> ->
      fnv(
        rest,
        int.bitwise_and(
          int.bitwise_exclusive_or(hash, byte) * 16_777_619,
          0xFFFFFFFF,
        ),
      )
    _ -> hash
  }
}

/// The rows of a box: a top border carrying `label`, `box.rows` rows of
/// cells, and a foot carrying the key that opens the image.
///
/// The frame is as wide as the box needs, and wider only when the label
/// does not fit; a label wider than `width` is cut. Every row is built from
/// spans and is never wrapped, so the cells of a box stay where the layout
/// put them.
///
/// ## Examples
///
/// ```gleam
/// let rows = image_box.rows(support, drawing, "image 1 · image/png", 80)
/// ```
pub fn rows(
  support: Support,
  drawing: Drawing,
  label: String,
  width: Int,
) -> List(span.Line) {
  // The room is what the pane leaves after the indent, and a label wider
  // than the room less its corners and spaces is cut to fit.
  let room = int.max(1, width - string.length(indent))
  let label = text.truncate(label, int.max(1, room - 6), "…")

  // The frame is as wide as the box needs, or as the label needs when the
  // label is wider, but never wider than the room.
  let frame =
    int.min(room, int.max(drawing.box.columns + 4, text.cell_width(label) + 6))
  let inside = frame - 4
  let edge = style.new(theme.divider, style.Default, style.none())
  let top = border("╭─ ", label, "╮", frame, edge)
  let foot = border("╰─ ", key, "╯", frame, edge)

  // One row of cells per row of the box, built newest first and turned over.
  let body =
    int.range(from: 0, to: drawing.box.rows, with: [], run: fn(acc, row) {
      [cell_row(support, drawing, row, inside, edge), ..acc]
    })
    |> list.reverse
  [top, ..list.append(body, [foot])]
}

// A border row: the corner and its dash, the words, and dashes to the far
// corner. `frame` is the whole width including both corners.
fn border(
  open: String,
  words: String,
  close: String,
  frame: Int,
  edge: style.Style,
) -> span.Line {
  let fill = int.max(1, frame - text.cell_width(open <> words) - 2)
  span.line_new([
    span.span_plain(indent),
    span.span_styled(open, edge),
    span.span_styled(words, theme.quiet_text()),
    span.span_styled(" " <> string.repeat("─", fill) <> close, edge),
  ])
}

// One interior row: the side, the cells the picture is drawn through,
// centred between padding, and the far side. Placeholder cells are text
// the terminal fills; blank cells are the marked blanks the picture is
// drawn over.
fn cell_row(
  support: Support,
  drawing: Drawing,
  row: Int,
  inside: Int,
  edge: style.Style,
) -> span.Line {
  let columns = int.min(drawing.box.columns, inside)
  let left = { inside - columns } / 2
  let cells = case support {
    image_support.KittyPlaceholders(..) ->
      int.range(from: 0, to: columns, with: [], run: fn(acc, column) {
        [kitty.cell_symbol(drawing.id, row, column), ..acc]
      })
      |> list.reverse
      |> string.concat
    image_support.Iterm2Inline(..) | image_support.TextOnly(..) ->
      string.repeat(blank, columns)
  }
  span.line_new([
    span.span_plain(indent),
    span.span_styled("│ ", edge),
    span.span_plain(string.repeat(" ", left)),
    span.span_styled(cells, kitty.id_style(drawing.id)),
    span.span_plain(string.repeat(" ", inside - columns - left)),
    span.span_styled(" │", edge),
  ])
}

/// What a box's cells are, which says how the picture reaches them.
pub type Cells {
  /// Unicode placeholders: the terminal fills them from the transmitted
  /// image, wherever they are drawn.
  Placeholders

  /// Marked blanks: the picture is drawn over them after the frame.
  Blanks
}

/// Whether the whole box is in the window the rows came from.
pub type Extent {
  /// The top border, every row and the foot are all in view.
  Whole

  /// The window cuts the box: its top border or its foot is not in view.
  Clipped
}

/// A box read back from rows.
pub type Found {
  Found(
    /// The id the box's cells carry.
    id: kitty.ImageId,
    /// How the picture reaches the cells.
    cells: Cells,
    /// The column of the box's first cell, counted from the window's left.
    column: Int,
    /// The window row of the box's first cell row, counted from the top.
    row: Int,
    /// How many cell rows of the box are in the window.
    rows: Int,
    /// Whether the window holds the whole box.
    extent: Extent,
  )
}

// What one row says about boxes: the marked cells it holds, and whether it
// is a border.
type Reading {
  Reading(marker: Option(Marker), edge: Edge)
}

type Marker {
  Marker(id: kitty.ImageId, cells: Cells, column: Int)
}

type Edge {
  TopBorder
  FootBorder
  Interior
}

/// Every box in a window of rows, topmost first.
///
/// The window is the transcript rows as the frame shows them, top first. A
/// box is a run of consecutive rows whose cells carry one id in one column.
/// Its extent is `Whole` when the row above the run is a top border and the
/// row below it is a foot, which is how a box scrolled partly out of the
/// window, or cut by the pane's edge, is told from one drawn complete.
///
/// ## Examples
///
/// ```gleam
/// assert image_box.found([]) == []
/// ```
pub fn found(window: List(span.Line)) -> List(Found) {
  window
  |> list.map(read)
  |> list.index_map(fn(reading, row) { #(row, reading) })
  |> group(Interior, None, [])
  |> list.reverse
}

// A run of marked rows still being extended, and the kind of row that sat
// above its first row.
type Open {
  Open(run: Found, above: Edge)
}

// Walks the readings once. A row extends the open run while its marker
// repeats; any other row closes it, and that row's own edge is the edge
// below the run. `previous` is the edge of the row just walked, which is
// what sits above a run that begins on this one.
fn group(
  readings: List(#(Int, Reading)),
  previous: Edge,
  open: Option(Open),
  closed: List(Found),
) -> List(Found) {
  case readings, open {
    [], None -> closed
    [], Some(Open(run:, above:)) -> [seal(run, above, Interior), ..closed]
    [#(row, reading), ..rest], None ->
      case reading.marker {
        Some(marker) ->
          group(
            rest,
            reading.edge,
            Some(Open(begin(marker, row), above: previous)),
            closed,
          )
        None -> group(rest, reading.edge, None, closed)
      }
    [#(row, reading), ..rest], Some(Open(run:, above:)) ->
      case reading.marker {
        Some(marker) if marker.id == run.id && marker.column == run.column ->
          group(
            rest,
            reading.edge,
            Some(Open(Found(..run, rows: run.rows + 1), above:)),
            closed,
          )
        Some(marker) ->
          group(
            rest,
            reading.edge,
            Some(Open(begin(marker, row), above: Interior)),
            [seal(run, above, reading.edge), ..closed],
          )
        None ->
          group(rest, reading.edge, None, [
            seal(run, above, reading.edge),
            ..closed
          ])
      }
  }
}

fn begin(marker: Marker, row: Int) -> Found {
  Found(
    id: marker.id,
    cells: marker.cells,
    column: marker.column,
    row:,
    rows: 1,
    extent: Clipped,
  )
}

// A run is whole when it opened under a top border and closed above a foot.
fn seal(run: Found, above: Edge, below: Edge) -> Found {
  case above, below {
    TopBorder, FootBorder -> Found(..run, extent: Whole)
    TopBorder, TopBorder | TopBorder, Interior | FootBorder, _ | Interior, _ ->
      run
  }
}

// What one row holds.
fn read(line: span.Line) -> Reading {
  Reading(marker: marker_of(line.spans, 0), edge: edge_of(line))
}

// The first marked span of a row and the column it starts at. A span is
// marked when its colour is a true-colour id and it is made wholly of
// placeholders or wholly of no-break spaces. A span that merely starts with
// one is text, such as a pasted line indented with no-break spaces.
fn marker_of(spans: List(span.Span), column: Int) -> Option(Marker) {
  case spans {
    [] -> None
    [first, ..rest] ->
      case cells_of(first) {
        Some(#(id, cells)) -> Some(Marker(id:, cells:, column:))
        None -> marker_of(rest, column + span.span_width(first))
      }
  }
}

fn cells_of(sp: span.Span) -> Option(#(kitty.ImageId, Cells)) {
  case sp.style.fg {
    style.Rgb(red, green, blue) -> {
      let marks = string.to_graphemes(sp.content)
      let cells = case
        marks != [] && list.all(marks, string.starts_with(_, kitty.placeholder)),
        marks != [] && list.all(marks, fn(mark) { mark == blank })
      {
        True, _ -> Some(Placeholders)
        False, True -> Some(Blanks)
        False, False -> None
      }
      case cells {
        Some(cells) ->
          kitty.image_id(red * 65_536 + green * 256 + blue)
          |> result.map(fn(id) { #(id, cells) })
          |> option.from_result
        None -> None
      }
    }
    style.Default | style.Indexed(_) -> None
  }
}

fn edge_of(line: span.Line) -> Edge {
  let words =
    line.spans
    |> list.map(fn(sp) { sp.content })
    |> string.concat
    |> string.trim_start
  case string.starts_with(words, "╭"), string.starts_with(words, "╰") {
    True, _ -> TopBorder
    False, True -> FootBorder
    False, False -> Interior
  }
}
