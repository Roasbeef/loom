//// A `mermaid` fence in a transcript is drawn as a diagram when the renderer
//// accepts it and shown as source, with the reason, when it does not. Other
//// fences are untouched.

import etui/span
import gleam/list
import gleam/string
import tui/markdown

fn rows(markdown_text: String, width: Int) -> List(String) {
  markdown.render(markdown_text, width)
  |> markdown.wrap_lines(width)
  |> list.map(fn(line) {
    let span.Line(spans:, ..) = line
    spans |> list.map(fn(piece) { piece.content }) |> string.concat
  })
}

pub fn a_mermaid_fence_is_drawn_under_the_code_gutter_test() {
  assert rows("```mermaid\ngraph TD\nA[Start] --> B[End]\n```", 40)
    == [
      "▎ mermaid",
      "▎ ┌───────┐",
      "▎ │ Start │",
      "▎ └───────┘",
      "▎     │",
      "▎     │",
      "▎     ▼",
      "▎  ┌─────┐",
      "▎  │ End │",
      "▎  └─────┘",
      "",
    ]
}

pub fn a_refused_diagram_falls_back_to_its_source_with_the_reason_test() {
  assert rows("```mermaid\ngraph TD\nsubgraph s\nA\nend\n```", 60)
    == [
      "▎ mermaid",
      "▎ graph TD",
      "▎ subgraph s",
      "▎ A",
      "▎ end",
      "▎ not drawn: unsupported `subgraph` statement",
      "",
    ]
}

pub fn a_diagram_wider_than_the_pane_falls_back_test() {
  let shown = rows("```mermaid\ngraph TD\nA[a long label] --> B\n```", 10)
  assert list.contains(shown, "▎ graph TD")

  // The reason is a code row like the rest, so a pane this narrow wraps it.
  assert list.any(shown, string.starts_with(_, "▎ not"))
}

pub fn drawn_rows_are_not_rewrapped_test() {
  // The diagram is laid out against the width left after the gutter, so the
  // hard wrap that code rows get never splits a drawn row.
  let source = "```mermaid\ngraph LR\nA --> B --> C\n```"
  let unwrapped =
    markdown.render(source, 30)
    |> list.map(fn(line) {
      let span.Line(spans:, ..) = line
      spans |> list.map(fn(piece) { piece.content }) |> string.concat
    })
  assert rows(source, 30) == unwrapped
}

pub fn other_fences_and_unlabelled_fences_are_unchanged_test() {
  assert rows("```text\ngraph TD\nA --> B\n```", 40)
    == ["▎ text", "▎ graph TD", "▎ A --> B", ""]
  assert rows("```\nA --> B\n```", 40) == ["▎ A --> B", ""]
}

pub fn a_sequence_diagram_is_drawn_in_a_transcript_test() {
  let shown =
    rows("```mermaid\nsequenceDiagram\nA->>B: hi\n```", 60)
    |> string.join("\n")
  assert string.contains(shown, "▶")
  assert string.contains(shown, "hi")
}

fn text_rows(lines: List(span.Line)) -> List(String) {
  list.map(lines, fn(line) {
    let span.Line(spans:, ..) = line
    spans |> list.map(fn(piece) { piece.content }) |> string.concat
  })
}

pub fn the_live_tail_shows_a_mermaid_fence_as_source_test() {
  // The live tail renders a growing answer again on every delta, so it leaves
  // the diagram to the settled row.
  let source = "```mermaid\ngraph TD\nA --> B\n```"
  assert text_rows(markdown.render_live(source, 40))
    == ["▎ mermaid", "▎ graph TD", "▎ A --> B", ""]
  assert text_rows(markdown.render_sanitized(source, 40, markdown.ShowSource))
    == text_rows(markdown.render_live(source, 40))
  assert text_rows(markdown.render(source, 40))
    != text_rows(markdown.render_live(source, 40))
}

pub fn the_live_tail_still_shows_a_quoted_mermaid_fence_as_source_test() {
  let quoted = "> ```mermaid\n> graph TD\n> A --> B\n> ```"
  assert list.any(text_rows(markdown.render_live(quoted, 40)), string.contains(
    _,
    "graph TD",
  ))
  assert !list.any(text_rows(markdown.render_live(quoted, 40)), string.contains(
    _,
    "▼",
  ))
}
