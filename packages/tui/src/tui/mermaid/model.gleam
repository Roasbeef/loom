//// The shared vocabulary of the Mermaid text renderer.
////
//// The renderer is four stages that hand each other plain data: `parse`
//// reads source into a `Diagram`, `layout` gives every flowchart node a
//// `Box` on a character grid, `draw` routes the edges and paints a
//// `canvas`, and `tui/mermaid` turns the canvas into styled lines. The types
//// every stage needs live here so that no stage imports another only to
//// name a type, and so that the one decision the whole renderer exists to
//// make, whether it can draw a diagram or must refuse, has a single closed
//// type, `Refusal`.
////
//// The limits are declared here for the same reason. A refusal that names
//// the limit it hit is only believable if the limit is one constant that
//// both the check and the message read.

import gleam/int
import gleam/list

/// The largest source accepted, in bytes. The text arrives from a model and is
/// re-parsed on every streamed delta, so the bound caps the work per delta.
pub const max_source_bytes = 16_384

/// The most nodes (flowchart) or participants (sequence) accepted.
pub const max_nodes = 32

/// The most edges (flowchart, after `&` groups are expanded) or messages and
/// notes (sequence) accepted.
pub const max_edges = 48

/// The longest label line accepted, in terminal cells. A longer line is
/// refused rather than truncated: a truncated node name can make two nodes
/// read as the same one, and the source fallback shows the full text.
pub const max_label_cells = 40

/// The largest canvas, in cells, including the margins the router uses. This
/// bounds the router's search space, which is the part of the renderer whose
/// cost grows with area rather than with the input.
pub const max_canvas_cells = 65_536

/// The indices `0` up to but not including `count`, in order. A count of zero
/// or less is empty.
///
/// ## Examples
///
/// ```gleam
/// model.indices(3)
/// // -> [0, 1, 2]
/// ```
pub fn indices(count: Int) -> List(Int) {
  int.range(from: 0, to: int.max(0, count), with: [], run: list.prepend)
  |> list.reverse
}

/// The limit a `TooLarge` refusal names.
pub type Limit {
  SourceBytes
  Nodes
  Edges
  LabelCells
  CanvasCells
}

/// Why a diagram was not drawn. The caller keeps the source and shows
/// `tui/mermaid.reason` beside it; a diagram is never drawn partially.
pub type Refusal {
  /// Valid Mermaid that this renderer does not draw: a diagram type, a
  /// keyword or a construct, named in `what`.
  Unsupported(what: String)

  /// The source is not in the accepted subset. `line` counts from one.
  Malformed(line: Int, expected: String)

  /// An input bound was exceeded.
  TooLarge(limit: Limit)

  /// A label contains a character with no reliable width in a terminal, such
  /// as a control character or a combining mark.
  Unmeasurable(label: String)

  /// The drawing is wider than the room it was given in every direction tried.
  TooWide

  /// The router found no path for an edge, or no room for an edge label.
  Unroutable
}

/// Which way a flowchart reads.
pub type Direction {
  TopDown
  BottomUp
  LeftRight
  RightLeft
}

/// A node's outline.
pub type Shape {
  /// `A[text]` and a bare identifier.
  Rectangle

  /// `A(text)` and `A([text])`.
  Rounded

  /// `A{text}`, drawn as a double-lined box rather than a diamond because a
  /// diamond cannot hold a label in a character grid.
  Decision
}

/// How an edge is stroked.
pub type Stroke {
  Solid
  Dotted
  Thick
}

/// Whether an edge ends in an arrowhead.
pub type Tip {
  Arrow
  Open
}

/// A flowchart node. `lines` is the label, one entry per `<br>`-separated
/// line, each already checked against the cell limit.
pub type Node {
  Node(id: String, lines: List(String), shape: Shape)
}

/// A directed flowchart edge between node indices. `label` is empty for an
/// unlabelled edge.
pub type Edge {
  Edge(from: Int, to: Int, stroke: Stroke, tip: Tip, label: String)
}

/// A parsed flowchart. Nodes are in order of first appearance, and an edge's
/// endpoints index into `nodes`.
pub type Flowchart {
  Flowchart(direction: Direction, nodes: List(Node), edges: List(Edge))
}

/// A sequence diagram's participant: the box at the head of a lifeline.
pub type Participant {
  Participant(id: String, label: String)
}

/// How a message line is stroked and what ends it.
pub type Message {
  Message(from: Int, to: Int, stroke: Stroke, end: MessageEnd, text: String)
}

/// The end of a message line.
pub type MessageEnd {
  /// `->>` and `-->>`.
  Head

  /// `->` and `-->`.
  Plain

  /// `-x` and `--x`.
  Cross
}

/// Where a note sits relative to its participants.
pub type NotePlace {
  /// `Note over A` or `Note over A,B`: centred across the named lifelines.
  Over(first: Int, last: Int)

  /// `Note left of A`.
  LeftOf(Int)

  /// `Note right of A`.
  RightOf(Int)
}

/// One step of a sequence diagram, in chronological order.
pub type Event {
  Said(Message)
  Noted(place: NotePlace, text: String)
}

/// A parsed sequence diagram.
pub type Sequence {
  Sequence(participants: List(Participant), events: List(Event))
}

/// A parsed diagram of either supported family.
pub type Diagram {
  Flow(Flowchart)
  Sequenced(Sequence)
}

/// A node's rectangle on the character grid: its top-left cell and its size
/// in cells, border included.
pub type Box {
  Box(x: Int, y: Int, width: Int, height: Int)
}
