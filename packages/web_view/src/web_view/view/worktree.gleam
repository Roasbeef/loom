//// The Changes tab drawn from the daemon's observation of the session's Git
//// working tree: the files that differ from HEAD and the commits made since
//// the session started, including changes a shell command or an editor made.
////
//// `view/changes` chooses this pane when the page holds a board of a real
//// checkout (`web_view/worktrees`), and draws the agent's own edit records
//// otherwise. The board is the daemon's bounded observation
//// (`client/worktree_diff`): at most twenty-four files, a patch cut at sixteen
//// kilobytes, the whole board under forty, and a count of what did not fit.
//// This pane draws every bound it was handed. A file whose patch was cut says
//// so under its diff, and files left out are counted and not named, because
//// the daemon's census keeps their number and not their names.
////
//// The pane says what it compares against. The files are the working tree
//// against HEAD, so an agent that commits its work moves a file out of the
//// list; the commits it made since the session started are a second section,
//// from the session's recorded starting commit when it has one and with the
//// daemon's own words when it has not.
////
//// Each file is a `<details>` keyed by its path, the first open, as the edit
//// board draws them, and each diff is the shared drawer (`view/diff`), in
//// colour, with the sign gutter. The path and every diff line are repository
//// text and are drawn as text nodes, and the path is also the element's key,
//// which Lustre escapes; it is never a class, and no handler sits beneath the
//// pane. What the pane says
//// of a file's status and kind is chosen from closed sets here, and none of it
//// is taken from the observation's text.

import gleam/int
import gleam/list
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import session_view/diff_view
import session_view/worktree_view.{type Board, type File}
import web_view/view/diff

/// The Changes pane for a `board` of a Git checkout.
///
/// ## Examples
///
/// ```gleam
/// // worktree.view(observed)
/// ```
pub fn view(board: Board) -> Element(message) {
  keyed.element(
    "section",
    [
      attribute.class("pane"),
      attribute.class("pane-changes"),
      attribute.aria_label("Changes"),
    ],
    case board.files {
      [] -> [
        #("title", title(board)),
        #("label", label(board)),
        #(
          "empty",
          html.p([attribute.class("pane-empty")], [
            html.text("No uncommitted changes in the workspace."),
          ]),
        ),
        #("committed", committed(board)),
      ]
      [first, ..rest] -> [
        #("title", title(board)),
        #("label", label(board)),
        #(file_key(first), file(first, [attribute.attribute("open", "")])),
        ..list.append(
          list.map(rest, fn(next) { #(file_key(next), file(next, [])) }),
          [#("omitted", omitted(board)), #("committed", committed(board))],
        )
      ]
    },
  )
}

// `Changes · 3 files`, counting every changed file the daemon found, held or
// not.
fn title(board: Board) -> Element(message) {
  html.h2([attribute.class("panel-title")], [
    html.span([attribute.class("changes-title")], [html.text("Changes")]),
    html.span([attribute.class("changes-total")], [
      html.text(" · " <> count(board.total, "file", "files")),
    ]),
  ])
}

// What the files are compared against, so a reader does not take the list for
// the session's own edits or for a pull request's diff.
fn label(board: Board) -> Element(message) {
  html.p([attribute.class("changes-label")], [
    html.text(case board.repository {
      "unborn" -> "from the workspace's git status, before its first commit"
      _ -> "from the workspace's git diff against HEAD"
    }),
  ])
}

// A file's key is its path, for the reason `view/changes` keys the edit board
// by it: a `details` keeps the reader's choice in the browser, and a list keyed
// by position would hand it to whichever file now sits at that index.
fn file_key(file: File) -> String {
  "file:" <> file.path
}

// One file: its path and what happened to it on the line, its diff under it.
fn file(
  file: File,
  opened: List(attribute.Attribute(message)),
) -> Element(message) {
  html.details([attribute.class("changes-file"), ..opened], [
    html.summary([attribute.class("changes-file-line")], [
      html.span([attribute.class("changes-path")], [html.text(file.path)]),
      html.span([attribute.class("changes-counts")], [
        html.text(" " <> counts(file)),
      ]),
    ]),
    body(file),
  ])
}

// What the file's patch draws. A text patch is the shared diff drawer and a
// cut one says so. A file with no text patch says why in one fixed phrase.
fn body(file: File) -> Element(message) {
  case file.kind, file.extent {
    "text", "complete" -> diff.of_text(file.patch)
    "text", _ ->
      html.div([], [
        diff.of_text(file.patch),
        html.p([attribute.class("changes-cut")], [
          html.text("This diff is cut at the size limit."),
        ]),
      ])
    "binary", _ -> note("Binary file, not shown.")
    "metadata_only", _ -> note("A directory or nested repository, not shown.")
    _, _ -> note("No net change.")
  }
}

fn note(words: String) -> Element(message) {
  html.p([attribute.class("changes-cut")], [html.text(words)])
}

// The words on a file's line: what happened to it and the lines it added and
// removed in the part of the patch held. A cut patch counts only what it
// holds, which the line says with a plus sign.
fn counts(file: File) -> String {
  let status = status_words(file)
  case file.kind {
    "text" -> {
      let lines = diff_view.parse(file.patch).lines
      let added = list.count(lines, fn(line) { line.kind == diff_view.Added })
      let removed =
        list.count(lines, fn(line) { line.kind == diff_view.Removed })
      let more = case file.extent {
        "complete" -> ""
        _ -> "+"
      }
      status
      <> " · +"
      <> int.to_string(added)
      <> more
      <> " -"
      <> int.to_string(removed)
      <> more
    }
    _ -> status
  }
}

// The status as one of a few fixed words, from the two porcelain letters.
fn status_words(file: File) -> String {
  case file.index_status, file.worktree_status {
    "?", _ -> "new"
    _, "D" | "D", _ -> "deleted"
    "A", _ -> "added"
    _, _ -> "modified"
  }
}

// The line that says files were left out of the board.
fn omitted(board: Board) -> Element(message) {
  case board.omitted {
    0 -> element.none()
    left ->
      html.p([attribute.class("changes-cut")], [
        html.text(
          int.to_string(left)
          <> case left {
            1 -> " more file not shown"
            _ -> " more files not shown"
          },
        ),
      ])
  }
}

// The commits made since the session started: the daemon's words for what was
// compared, and the commit patches when there are any. A host that records no
// starting commit gives its reason here instead, which is the pane's way of
// saying the commits cannot be listed.
fn committed(board: Board) -> Element(message) {
  case string.trim(board.committed.message), board.committed.patch {
    "", "" -> element.none()
    message, patch ->
      html.div([attribute.class("changes-committed")], [
        html.p([attribute.class("changes-label")], [html.text(message)]),
        case patch {
          "" -> element.none()
          _ -> diff.of_text(patch)
        },
        case board.committed.extent {
          "complete" -> element.none()
          _ -> note("The commit patches are cut at the size limit.")
        },
      ])
  }
}

fn count(number: Int, one: String, many: String) -> String {
  int.to_string(number)
  <> case number {
    1 -> " " <> one
    _ -> " " <> many
  }
}
