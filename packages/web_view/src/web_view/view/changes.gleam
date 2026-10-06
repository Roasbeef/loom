//// Changes from the session's edits: the files the agent edited and the diff
//// each edit reported, drawn as the Changes tab of the strand panel on both
//// pages.
////
//// This module chooses between two sources. When the page holds the daemon's
//// observation of a Git checkout (`web_view/worktrees`) the pane is
//// `view/worktree`: the workspace's diff, which includes what a shell command
//// or an editor changed. Otherwise it is the board below, and when the page
//// may have read the workspace and could not (the workspace is not a checkout,
//// the daemon refused, the read failed) one sentence says why the tab lists
//// only the agent's edits. An observer's page is never given the read.
////
//// The edit board is `session_view/changes_view`, folded from the records the
//// page already holds, so nothing here reads the worktree and nothing is sent.
//// It is labelled `from this session's edits` because it shows what the agent
//// wrote and not what is in the tree (`changes_view` says what that omits).
//// The pane is one of the panel's three (`view/panel`), and the shell shows it
//// while its tab is chosen; the pane is drawn whether or not it shows, and the
//// tab's button is the shell's.
////
//// The heading is `Changes · 2 files · +14 -2`. Under it each file is a
//// `<details>` with its counts on the line, the first open and the rest
//// collapsed, and the diff as one row per line. The `open` attribute is a
//// fixed literal on the first file, and the server never changes it once
//// drawn, so a reader's choice is left alone by later patches. A session that
//// has edited nothing draws the heading and one line saying so, so the pane's
//// place in the panel does not move and the tab never opens on nothing. The
//// board only sees the rows the page holds, so when older rows exist the line
//// says the edits were looked for in the loaded part and points at Load older
//// (`Window`). A muted line under it says which edits the tab lists: those the
//// edit and write tools made, and not those a shell command or an editor made.
////
//// The pane's children are keyed, each file by its path, so a `details` a
//// reader opened stays the same element when a file is edited that sorts
//// before it. Everything a diff carries is session text: the path and every
//// row. Each is drawn as a text node, never as an attribute or a class; the
//// path is also the file's key, as a single line with no separator
//// character, and no handler sits beneath it. Each diff is drawn by
//// `view/diff`, in colour, which chooses a line's class from a closed kind and
//// never from its text. The view carries no handler, so an observer's page
//// draws it as an operator's does. The board is bounded by the fold
//// (`changes_view.max_files`, `max_file_rows`, `max_rows`), and a cut is
//// drawn as a line saying how much is not shown, so the pane's size in
//// every viewer's document has a fixed ceiling.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import session_view/changes_view.{type Board, type File}
import session_view/diff_view
import web_view/view/diff
import web_view/view/worktree
import web_view/worktrees

/// How much of the session the board was folded from.
pub type Window {
  /// The page holds the session's first row, so the board saw every edit.
  Whole

  /// Older rows exist that the page does not hold, so an edit in them is not
  /// on the board.
  Partial
}

/// The Changes pane: the daemon's observation of the workspace when the page
/// holds one of a Git checkout (`view/worktree`), and otherwise `board`, the
/// agent's own edits, folded from `window` of the session. When the page may
/// have read the workspace and could not, one sentence says why the tab lists
/// only the agent's edits.
///
/// It is memoized on all three, so a page whose edits and workspace did not
/// change diffs nothing.
///
/// ## Examples
///
/// ```gleam
/// // changes.view(component.changes(model), changes.Whole, worktrees.Withheld)
/// ```
pub fn view(
  board: Board,
  window: Window,
  read: worktrees.Read,
) -> Element(message) {
  use <- element.memo([element.ref(#(board, window, read))])
  case read {
    worktrees.Seen(observed) ->
      case observed.repository {
        "head" | "unborn" -> worktree.view(observed)
        _ ->
          edits(
            board,
            window,
            Some(
              "This workspace is not a git checkout, so the tab lists only "
              <> "the edits the agent made.",
            ),
          )
      }
    worktrees.Declined ->
      edits(
        board,
        window,
        Some(
          "This page may not read the workspace, so the tab lists only the "
          <> "edits the agent made.",
        ),
      )
    worktrees.Unreadable ->
      edits(
        board,
        window,
        Some(
          "The workspace could not be read just now, so the tab lists only "
          <> "the edits the agent made.",
        ),
      )
    worktrees.Withheld | worktrees.Unread | worktrees.Throttled ->
      edits(board, window, None)
  }
}

// The pane of the agent's own edit records, with `reason` under the heading
// when the workspace's changes were looked for and are not shown.
fn edits(
  board: Board,
  window: Window,
  reason: Option(String),
) -> Element(message) {
  let why = case reason {
    Some(words) -> [
      #("reason", html.p([attribute.class("pane-empty")], [html.text(words)])),
    ]
    None -> []
  }
  keyed.element(
    "section",
    [
      attribute.class("pane"),
      attribute.class("pane-changes"),
      attribute.aria_label("Changes"),
    ],
    case board.files {
      [] ->
        list.flatten([
          [
            #(
              "title",
              html.h2([attribute.class("panel-title")], [html.text("Changes")]),
            ),
          ],
          why,
          [
            #("empty", empty_line(window)),
            #(
              "scope",
              html.p([attribute.class("pane-empty")], [
                html.text(
                  "This tab lists edits made through the edit and write tools. "
                  <> "Changes made through shell commands or editors are not shown.",
                ),
              ]),
            ),
          ],
        ])
      [first, ..rest] ->
        list.flatten([
          [
            #(
              "title",
              html.h2([attribute.class("panel-title")], [
                html.span([attribute.class("changes-title")], [
                  html.text("Changes"),
                ]),
                html.span([attribute.class("changes-total")], [
                  html.text(" · " <> changes_view.totals(board)),
                ]),
              ]),
            ),
          ],
          why,
          [
            #(
              "label",
              html.p([attribute.class("changes-label")], [
                html.text(changes_view.label()),
              ]),
            ),
            #(file_key(first), file(first, [attribute.attribute("open", "")])),
          ],
          list.map(rest, fn(next) { #(file_key(next), file(next, [])) }),
          [#("omitted", omitted_files(board))],
        ])
    },
  )
}

// The line an empty board draws, which says whether the whole session was
// searched.
fn empty_line(window: Window) -> Element(message) {
  html.p([attribute.class("pane-empty")], [
    case window {
      Whole -> html.text("No edits in this session yet.")
      Partial ->
        html.text(
          "No edits in the loaded part of this session. "
          <> "Use Load older in the transcript to look further back.",
        )
    },
  ])
}

// A file's key is its path. A `details` keeps the reader's choice of open or
// closed in the browser, and an unkeyed list would hand that state to
// whichever file now sits at its index when a file appears before it. The
// path is one line (`changes_view` fits and single-lines it), so it holds
// none of the tab, carriage return or newline that separate a path's
// segments. Nothing beneath a file has a handler either.
fn file_key(file: File) -> String {
  "file:" <> file.path
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
        html.text(" " <> changes_view.counts_words(file)),
      ]),
    ]),
    diff.view(diff_view.of_lines(diff_lines(file)), file.cut),
  ])
}

// The lines the shared diff reader is given. An edit's rows are headerless
// hunks, which the reader takes as they are. A file the session only wrote has
// no hunk header at all, and the reader reads lines before the first hunk as
// plain context, so its added lines would be drawn uncoloured; a header that
// opens the new file at line one puts them inside a hunk, in green and with
// their line numbers.
fn diff_lines(file: File) -> List(String) {
  let rows = list.map(file.rows, fn(row) { row.text })
  case file.origin {
    changes_view.Written -> ["@@ -0,0 +1 @@", ..rows]
    changes_view.Edited -> rows
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
