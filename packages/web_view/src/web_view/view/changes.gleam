//// Changes from the session's edits: the files the agent edited and the diff
//// each edit reported, drawn as a collapsed section on both pages.
////
//// The board is `session_view/changes_view`, folded from the records the page
//// already holds, so nothing here reads the worktree and nothing is sent. It
//// is labelled `from this session's edits` because it shows what the agent
//// wrote and not what is in the tree (`changes_view` says what that omits).
//// The tabbed right panel of the web design note will hold this view as its
//// Changes tab; until it exists the section is a `<details>` the page draws
//// below the transcript, and this module is written to move as it is.
////
//// The summary line is `Changes · 2 files · +14 -2`. Under it each file is its
//// own `<details>` with its counts on the line, the first open and the rest
//// collapsed, and the diff as one row per line. The `open` attribute is a
//// fixed literal on the first file, and the server never changes it once
//// drawn, so a reader's choice is left alone by later patches.
////
//// Everything a diff carries is session text: the path and every row. Each is
//// drawn as a text node, never as an attribute, a class or a key. A row's
//// class is chosen from `changes_view.Kind`, a closed type the fold computed
//// from the row's first characters, and every class is a complete literal,
//// so no diff can name one. The view carries no handler, so an observer's
//// page draws it as an operator's does. It is `element.none()` when the
//// session has edited nothing. The board is bounded by the fold
//// (`changes_view.max_files`, `max_file_rows`, `max_rows`), and a cut is
//// drawn as a line saying how much is not shown, so the section's size in
//// every viewer's document has a fixed ceiling.

import gleam/int
import gleam/list
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import session_view/changes_view.{
  type Board, type File, type Kind, type Row, Added, Context, Hunk, Removed,
}

/// The section for `board`.
///
/// It is memoized on the board, so a page whose edits did not change diffs
/// nothing.
///
/// ## Examples
///
/// ```gleam
/// // changes.view(component.changes(model))
/// ```
pub fn view(board: Board) -> Element(message) {
  use <- element.memo([element.ref(board)])
  case board.files {
    [] -> element.none()
    [first, ..rest] ->
      html.details([attribute.class("changes")], [
        html.summary([attribute.class("changes-summary")], [
          html.span([attribute.class("changes-title")], [html.text("Changes")]),
          html.span([attribute.class("changes-total")], [
            html.text(" · " <> changes_view.totals(board)),
          ]),
        ]),
        html.p([attribute.class("changes-label")], [
          html.text(changes_view.label()),
        ]),
        file(first, [attribute.attribute("open", "")]),
        ..list.append(list.map(rest, file(_, [])), [omitted_files(board)])
      ])
  }
}

// One file: its path and counts on the line, its rows under it. `opened`
// is the details' own attributes, which only the first file's `open` fills.
fn file(
  file: File,
  opened: List(attribute.Attribute(message)),
) -> Element(message) {
  html.details([attribute.class("changes-file"), ..opened], [
    html.summary([attribute.class("changes-file-line")], [
      html.span([attribute.class("changes-path")], [html.text(file.path)]),
      html.span([attribute.class("changes-counts")], [
        html.text(
          " +"
          <> int.to_string(file.added)
          <> " -"
          <> int.to_string(file.removed),
        ),
      ]),
    ]),
    html.div(
      [attribute.class("diff")],
      list.append(list.map(file.rows, row), cut(file)),
    ),
  ])
}

// A row: its text as a text node, its class from its kind.
fn row(row: Row) -> Element(message) {
  html.div([attribute.class("diff-row"), kind_class(row.kind)], [
    html.text(row.text),
  ])
}

// The class of a row's kind, a literal from a closed set. It is never
// derived from the row's text or from the kind's name.
fn kind_class(kind: Kind) -> attribute.Attribute(message) {
  case kind {
    Hunk -> attribute.class("diff-hunk")
    Added -> attribute.class("diff-added")
    Removed -> attribute.class("diff-removed")
    Context -> attribute.class("diff-context")
  }
}

// The line that says rows were left out of a file, or nothing.
fn cut(file: File) -> List(Element(message)) {
  case file.cut {
    0 -> []
    left -> [
      html.p([attribute.class("changes-cut")], [
        html.text(int.to_string(left) <> " more lines not shown"),
      ]),
    ]
  }
}

// The line that says files were left out of the board, or nothing.
fn omitted_files(board: Board) -> Element(message) {
  case board.file_count - list.length(board.files) {
    0 -> element.none()
    left ->
      html.p([attribute.class("changes-cut")], [
        html.text(int.to_string(left) <> " more files not shown"),
      ])
  }
}
