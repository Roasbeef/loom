//// The Mermaid reader accepts a stated subset and refuses everything else by
//// name. Each refusal here is a construct a model plausibly writes, because
//// the reason shown under the source block is only useful if it is the right
//// one.

import gleam/int
import gleam/list
import gleam/string
import tui/mermaid/model.{type Diagram, type Refusal}
import tui/mermaid/parse

fn flow(source: String) -> model.Flowchart {
  let assert Ok(model.Flow(chart)) = parse.parse(source)
  chart
}

fn sequence(source: String) -> model.Sequence {
  let assert Ok(model.Sequenced(diagram)) = parse.parse(source)
  diagram
}

fn refusal(source: String) -> Refusal {
  let assert Error(why) = parse.parse(source)
  why
}

fn ids(chart: model.Flowchart) -> List(String) {
  list.map(chart.nodes, fn(node) { node.id })
}

// --- flowcharts --------------------------------------------------------

pub fn header_sets_direction_test() {
  assert flow("graph TD\nA").direction == model.TopDown
  assert flow("graph TB\nA").direction == model.TopDown
  assert flow("flowchart\nA").direction == model.TopDown
  assert flow("flowchart LR\nA").direction == model.LeftRight
  assert flow("flowchart BT\nA").direction == model.BottomUp
  assert flow("graph RL\nA").direction == model.RightLeft
}

pub fn node_shapes_and_labels_test() {
  let chart =
    flow(
      "graph TD\nA[Box] --> B(Round)\nB --> C{Pick}\nC --> D([Pill])\nD --> E",
    )
  assert list.map(chart.nodes, fn(node) { node.shape })
    == [
      model.Rectangle,
      model.Rounded,
      model.Decision,
      model.Rounded,
      model.Rectangle,
    ]
  assert list.map(chart.nodes, fn(node) { node.lines })
    == [["Box"], ["Round"], ["Pick"], ["Pill"], ["E"]]
}

pub fn edge_strokes_and_tips_test() {
  let chart = flow("graph LR\nA --> B\nB --- C\nC -.-> D\nD ==> E\nE -.- F")
  assert list.map(chart.edges, fn(edge) { #(edge.stroke, edge.tip) })
    == [
      #(model.Solid, model.Arrow),
      #(model.Solid, model.Open),
      #(model.Dotted, model.Arrow),
      #(model.Thick, model.Arrow),
      #(model.Dotted, model.Open),
    ]
}

pub fn pipe_and_infix_labels_test() {
  let chart = flow("graph TD\nA -->|yes| B\nB -- maybe --> C\nC -. soon .-> D")
  assert list.map(chart.edges, fn(edge) { edge.label })
    == ["yes", "maybe", "soon"]
}

pub fn chains_and_groups_expand_to_edges_test() {
  let chain = flow("graph TD\nA --> B --> C")
  assert list.map(chain.edges, fn(edge) { #(edge.from, edge.to) })
    == [#(0, 1), #(1, 2)]

  let fan = flow("graph TD\nA & B --> C & D")
  assert list.map(fan.edges, fn(edge) { #(edge.from, edge.to) })
    == [#(0, 2), #(0, 3), #(1, 2), #(1, 3)]
}

pub fn comments_blank_lines_and_semicolons_are_skipped_test() {
  let chart = flow("graph TD\n\n%% a comment\nA --> B; B --> C;\n")
  assert ids(chart) == ["A", "B", "C"]
  assert list.length(chart.edges) == 2
}

pub fn later_declaration_relabels_a_node_test() {
  let chart = flow("graph TD\nA --> B\nA[First]")
  assert list.map(chart.nodes, fn(node) { node.lines }) == [["First"], ["B"]]
}

pub fn quoted_labels_hold_delimiters_test() {
  let chart = flow("graph TD\nA[\"a ] b\"] --> B(\"c ) d\")")
  assert list.map(chart.nodes, fn(node) { node.lines })
    == [["a ] b"], ["c ) d"]]
}

pub fn br_breaks_a_node_label_test() {
  let chart = flow("graph TD\nA[one<br/>two] --> B")
  assert list.map(chart.nodes, fn(node) { node.lines })
    == [["one", "two"], ["B"]]
}

// --- flowchart refusals ------------------------------------------------

pub fn unsupported_flowchart_constructs_are_named_test() {
  assert refusal("graph TD\nsubgraph s\nA\nend")
    == model.Unsupported("subgraph statements")
  assert refusal("graph TD\nA\nclassDef x fill:#f00")
    == model.Unsupported("classDef statements")
  assert refusal("graph TD\nA\nstyle A fill:#f00")
    == model.Unsupported("style statements")
  assert refusal("graph TD\nA\nclick A callback")
    == model.Unsupported("click statements")
  assert refusal("graph TD\nA:::hot --> B")
    == model.Unsupported("class shorthand")
  assert refusal("graph TD\nA((circle)) --> B")
    == model.Unsupported("this node shape")
  assert refusal("graph TD\nA <--> B")
    == model.Unsupported("a bidirectional edge")
  assert refusal("graph TD\nA --> A") == model.Unsupported("a self-loop edge")
}

pub fn other_diagram_types_directives_and_front_matter_are_refused_test() {
  assert refusal("pie title Pets\n\"Dogs\" : 5")
    == model.Unsupported("pie diagrams")
  assert refusal("classDiagram\nclass A")
    == model.Unsupported("classDiagram diagrams")
  assert refusal("%%{init: {}}%%\ngraph TD\nA")
    == model.Unsupported("a %%{ directive")
  assert refusal("---\ntitle: x\n---\ngraph TD\nA")
    == model.Unsupported("front matter")
}

pub fn malformed_source_names_its_line_test() {
  assert refusal("graph TD\nA --> B\nA -> B")
    == model.Malformed(3, "an edge such as -->")
  assert refusal("graph TD\nA[unclosed --> B")
    == model.Malformed(2, "a closing ]")
  assert refusal("graph XX\nA")
    == model.Malformed(1, "a direction: TD, TB, BT, LR or RL")
  assert refusal("graph TD") == model.Malformed(1, "at least one node")
  assert refusal("") == model.Malformed(1, "a diagram header")
}

// --- limits ------------------------------------------------------------

// A chain of `edges` edges, which names one more node than that.
fn chain_of(edges: Int) -> String {
  let lines =
    model.indices(edges)
    |> list.map(fn(index) {
      "N" <> int.to_string(index) <> " --> N" <> int.to_string(index + 1)
    })
  "graph TD\n" <> string.join(lines, "\n")
}

pub fn node_and_edge_limits_are_exact_test() {
  // A chain of 32 nodes has 31 edges and is accepted; a 33rd node is refused.
  assert chain_of(31) |> parse.parse |> is_ok
  assert refusal(chain_of(32)) == model.TooLarge(model.Nodes)

  // 49 edges among few nodes is refused; 48 is accepted.
  let fan = fn(count) {
    "graph TD\n" <> string.join(list.repeat("A --> B", count), "\n")
  }
  assert fan(48) |> parse.parse |> is_ok
  assert refusal(fan(49)) == model.TooLarge(model.Edges)
}

pub fn label_width_is_counted_in_cells_test() {
  let forty = string.repeat("a", 40)
  assert parse.parse("graph TD\nA[" <> forty <> "]") |> is_ok
  assert refusal("graph TD\nA[" <> forty <> "a]")
    == model.TooLarge(model.LabelCells)

  // Twenty wide characters fill forty cells; twenty-one do not.
  let wide = string.repeat("漢", 20)
  assert parse.parse("graph TD\nA[" <> wide <> "]") |> is_ok
  assert refusal("graph TD\nA[" <> wide <> "漢]")
    == model.TooLarge(model.LabelCells)
}

pub fn unmeasurable_labels_are_refused_test() {
  assert refusal("graph TD\nA[e\u{0301}]") == model.Unmeasurable("e\u{0301}")
}

pub fn oversize_source_is_refused_before_parsing_test() {
  let big = "graph TD\n" <> string.repeat("%% padding\n", 2000)
  assert refusal(big) == model.TooLarge(model.SourceBytes)
}

fn is_ok(result: Result(Diagram, Refusal)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

// --- sequence diagrams -------------------------------------------------

pub fn participants_aliases_and_implicit_creation_test() {
  let diagram =
    sequence(
      "sequenceDiagram\nparticipant A as Alice\nactor B\nA->>C: hi\nB->>A: yo",
    )
  assert list.map(diagram.participants, fn(who) { #(who.id, who.label) })
    == [#("A", "Alice"), #("B", "B"), #("C", "C")]
}

pub fn message_operators_test() {
  let diagram =
    sequence(
      "sequenceDiagram\nA->>B: one\nA-->>B: two\nA->B: three\nA-->B: four\nA-xB: five\nA--xB: six",
    )
  let shapes =
    list.filter_map(diagram.events, fn(event) {
      case event {
        model.Said(message) -> Ok(#(message.stroke, message.end, message.text))
        model.Noted(..) -> Error(Nil)
      }
    })
  assert shapes
    == [
      #(model.Solid, model.Head, "one"),
      #(model.Dotted, model.Head, "two"),
      #(model.Solid, model.Plain, "three"),
      #(model.Dotted, model.Plain, "four"),
      #(model.Solid, model.Cross, "five"),
      #(model.Dotted, model.Cross, "six"),
    ]
}

pub fn notes_test() {
  let diagram =
    sequence(
      "sequenceDiagram\nA->>B: x\nNote over A,B: both\nNote left of A: l\nNote right of B: r\nNote over B: one",
    )
  let places =
    list.filter_map(diagram.events, fn(event) {
      case event {
        model.Noted(place:, ..) -> Ok(place)
        model.Said(_) -> Error(Nil)
      }
    })
  assert places
    == [model.Over(0, 1), model.LeftOf(0), model.RightOf(1), model.Over(1, 1)]
}

pub fn unsupported_sequence_constructs_are_named_test() {
  assert refusal("sequenceDiagram\nA->>B: x\nloop every day\nend")
    == model.Unsupported("loop in a sequence diagram")
  assert refusal("sequenceDiagram\nA->>B: x\nactivate B")
    == model.Unsupported("activate in a sequence diagram")
  assert refusal("sequenceDiagram\nA->>+B: x")
    == model.Unsupported("message activation")
  assert refusal("sequenceDiagram\nautonumber\nA->>B: x")
    == model.Unsupported("autonumber in a sequence diagram")
}

pub fn malformed_sequence_lines_name_their_line_test() {
  assert refusal("sequenceDiagram\nA->>B: ok\nwhat is this")
    == model.Malformed(3, "a message such as A->>B: text")
  assert refusal("sequenceDiagram")
    == model.Malformed(1, "at least one participant")
}
