//// A bounded authorized catalogue page, not a filesystem session inventory.
////
//// Enter explicitly selects one row. Listing, highlighting a default, and
//// navigating pages cannot start execution. The caller carries the revision
//// when requesting the next page and replaces this page instead of accumulating.

import etui/buffer
import etui/geometry.{type Rect}
import etui/keys
import etui/span
import etui/text
import etui/widgets/block
import etui/widgets/paragraph
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui/daemon/protocol
import tui/text_hygiene
import tui/theme

/// Whether the picker is navigating or holding a destructive question open.
///
/// Deletion is the one selector action with no undo, so the question it asks
/// is part of the picker's state rather than a flag beside it: while a
/// confirmation is open the arrow keys, Enter and `n` all mean nothing, and
/// a variant is what makes that unrepresentable rather than remembered.
pub type Prompt {
  /// Ordinary navigation; every key means what the help line says.
  Browsing

  /// A delete confirmation is open for exactly this identity. The row may
  /// have moved under the cursor since, so the answer names the session it
  /// was asked about rather than whatever is highlighted when `y` arrives.
  ConfirmingDelete(
    /// The session the question was asked about.
    session_id: String,
  )
}

/// One page is the complete retained selector inventory.
pub type State {
  State(
    /// Server revision, continuation and at most one hundred authorized rows.
    page: protocol.Page,
    /// Highlighted row; it does not imply an open.
    selected: Int,
    /// Currently attached session or the saved default before attachment.
    current: String,
    /// Navigation, or an open question about one identity.
    prompt: Prompt,
  )
}

/// Explicit navigation and lifecycle intent from one keystroke.
pub type Action {
  /// Keep the current authorized page and update only local navigation.
  Continue(State)

  /// Enter explicitly selects this row for bounded open and attachment.
  Choose(protocol.Session)

  /// Request explicit creation under the terminal's retained durable key.
  NewSession

  /// Continue only within the same catalogue revision.
  NextPage(after: String, revision: Int)

  /// Restart pagination without retaining rows from the previous revision.
  FirstPage

  /// Return to the old conversation without opening any row.
  Close

  /// The operator confirmed removal of this registration and its database.
  Delete(
    /// The identity the confirmation was asked about.
    session_id: String,
  )
}

/// Highlights the selected/default row if present in this page.
///
/// ## Examples
///
/// ```gleam
/// // session_selector.new(page, default_id)
/// ```
pub fn new(page: protocol.Page, current: String) -> State {
  let selected =
    list.index_fold(page.sessions, 0, fn(found, row, index) {
      case row.session_id == current {
        True -> index
        False -> found
      }
    })
  State(page, selected, current, Browsing)
}

/// Drops the named row from a page after the daemon confirmed its removal.
///
/// The picker does not re-list: the reply proves this identity is gone, and
/// a fresh page would move every other row under the operator's cursor. The
/// highlight is clamped so a deleted last row leaves the cursor on a row
/// that exists.
///
/// ## Examples
///
/// ```gleam
/// // session_selector.without(state, deleted_id)
/// ```
pub fn without(state: State, session_id: String) -> State {
  let sessions =
    list.filter(state.page.sessions, fn(row) { row.session_id != session_id })
  let selected = int.min(state.selected, int.max(0, list.length(sessions) - 1))
  State(
    ..state,
    page: protocol.Page(..state.page, sessions:),
    selected:,
    prompt: Browsing,
  )
}

/// Handles a key without any I/O or implicit selection.
///
/// ## Examples
///
/// ```gleam
/// // session_selector.update(keys.Enter, selector)
/// ```
pub fn update(key: keys.Key, state: State) -> Action {
  case state.prompt {
    Browsing -> browsing(key, state)
    ConfirmingDelete(session_id) -> confirming(key, state, session_id)
  }
}

// While the question is open only its two answers exist. Anything else
// withdraws it, because a stray key must never be read as consent to remove
// a conversation.
fn confirming(key: keys.Key, state: State, session_id: String) -> Action {
  case key {
    keys.Char("y") -> Delete(session_id)
    _other -> Continue(State(..state, prompt: Browsing))
  }
}

fn browsing(key: keys.Key, state: State) -> Action {
  case key {
    keys.Escape -> Close
    keys.Enter ->
      case list.first(list.drop(state.page.sessions, state.selected)) {
        Ok(row) -> Choose(row)
        Error(Nil) -> Continue(state)
      }
    keys.Up ->
      Continue(State(..state, selected: int.max(0, state.selected - 1)))
    keys.Down ->
      Continue(
        State(
          ..state,
          selected: int.max(
            0,
            int.min(list.length(state.page.sessions) - 1, state.selected + 1),
          ),
        ),
      )
    keys.Char("n") -> NewSession
    keys.Char("d") ->
      case list.first(list.drop(state.page.sessions, state.selected)) {
        Ok(row) ->
          Continue(State(..state, prompt: ConfirmingDelete(row.session_id)))
        Error(Nil) -> Continue(state)
      }
    keys.Right ->
      case state.page.after {
        Some(after) -> NextPage(after, state.page.revision)
        None -> Continue(state)
      }
    keys.Left -> FirstPage
    _ -> Continue(state)
  }
}

/// Renders only one bounded page and its explicit action hints.
///
/// ## Examples
///
/// ```gleam
/// // session_selector.render(buffer, screen, selector)
/// ```
pub fn render(buf: buffer.Buffer, screen: Rect, state: State) -> buffer.Buffer {
  let area =
    geometry.centered_rect(
      int.max(1, int.min(144, screen.size.width - 4)),
      int.max(1, int.min(22, screen.size.height - 4)),
      screen,
    )
  let frame =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.signal, theme.graphite)
    |> block.with_bg_fill
    |> block.with_title_styled(
      [
        span.span_styled(
          " SESSIONS · daemon catalogue ",
          theme.overlay_signal(),
        ),
      ],
      block.Top,
    )
    |> block.with_padding(1, 1, 1, 1)
  let inside = block.inner(area, frame)
  let count = int.max(1, { inside.size.height - 3 } / 2)
  let start = int.max(0, state.selected - count + 1)
  let rows =
    state.page.sessions
    |> list.drop(start)
    |> list.take(count)
    |> list.index_map(fn(row, offset) {
      let #(marker, selected_style) = case start + offset == state.selected {
        True -> #("▸ ", theme.overlay_signal())
        False -> #("  ", theme.overlay_plain())
      }
      let current = case row.session_id == state.current {
        True -> "● "
        False -> "  "
      }

      // Reserve the markers before sizing fields. Two fixed lines keep a long
      // workspace from erasing the name, lifecycle or navigation indicator.
      let width = int.max(0, inside.size.width - 4)
      let status =
        text.truncate(
          " [" <> lifecycle(row.status) <> "]",
          int.max(0, width - 8),
          "…",
        )
      let name =
        text.truncate(
          text_hygiene.single_line(row.name),
          width - text.cell_width(status),
          "…",
        )
      let identity =
        text.truncate(" · " <> short_identity(row.session_id), width, "…")
      let workspace =
        fit_workspace(row.workspace, width - text.cell_width(identity))
      [
        span.line_new([
          span.span_styled(marker, selected_style),
          span.span_styled(current, theme.overlay_current()),
          span.span_styled(name <> status, selected_style),
        ]),
        span.line_new([
          span.span_styled(
            "    " <> workspace <> identity,
            theme.overlay_quiet(),
          ),
        ]),
      ]
    })
    |> list.flatten
  let rows = case rows {
    [] -> [
      span.line_new([
        span.span_styled(
          text.truncate(
            "No saved sessions. Press n to create one explicitly.",
            inside.size.width,
            "…",
          ),
          theme.overlay_quiet(),
        ),
      ]),
    ]
    rows -> rows
  }
  let help = help_line(state, inside.size.width)
  buf
  |> buffer.clear(area)
  |> block.render(area, frame)
  |> paragraph.render_styled(
    inside,
    list.append(rows, [span.line_new([]), help]),
  )
}

// The timestamp fields distinguish catalogue UUIDs whose random suffix is
// shared by the same generator. Keep both fields rather than just the tail.
fn short_identity(identity: String) -> String {
  string.slice(identity, 0, 13)
}

// Path tails distinguish worktrees. Reverse only for cell-aware truncation;
// markers and the compact identity are separate spans and cannot be clipped.
fn fit_workspace(workspace: String, width: Int) -> String {
  workspace
  |> text_hygiene.single_line
  |> string.reverse
  |> text.truncate(width, "…")
  |> string.reverse
}

// The last line is either the key legend or the open question. Replacing it
// rather than adding a line keeps the question where the reader's eye already
// is, and leaves no doubt about which keys are live.
fn help_line(state: State, width: Int) {
  case state.prompt {
    Browsing ->
      span.line_new([
        span.span_styled(
          text.truncate(
            "↑↓ select · Enter open · n new · d delete · → next page · ← first · Esc close",
            width,
            "…",
          ),
          theme.overlay_quiet(),
        ),
      ])

    // A canonical identity is bounded by the wire at 64 bytes, so this line
    // needs no truncation of its own; hygiene still applies because the text
    // reaches a terminal.
    ConfirmingDelete(session_id) ->
      span.line_new([
        span.span_styled(
          text_hygiene.single_line(
            "delete " <> session_id <> "? y/n · any other key cancels",
          ),
          theme.overlay_signal(),
        ),
      ])
  }
}

fn lifecycle(status) {
  case status {
    protocol.Reserved -> "reserved"
    protocol.Saved -> "saved"
    protocol.Opening(_) -> "opening"
    protocol.Resident(_) -> "resident"
    protocol.Stopping(_) -> "stopping"
    protocol.RecoveryBlocked -> "recovery blocked"
  }
}
