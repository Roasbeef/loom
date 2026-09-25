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

/// The selected metadata collection, independent of runtime status.
pub type Collection {
  /// Sessions available for explicit opening.
  Active

  /// Preserved sessions that must be restored before opening.
  Archived
}

/// Whether the picker is navigating, editing a name, or confirming removal.
///
/// Deletion is the one selector action with no undo, so the question it asks
/// is part of the picker's state rather than a flag beside it: while a
/// confirmation is open the arrow keys, Enter and `n` all mean nothing, and
/// a variant is what makes that unrepresentable rather than remembered.
pub type Prompt {
  /// Ordinary navigation; every key means what the help line says.
  Browsing

  /// The selected session must be opened before it can receive a link.
  LinkUnavailable

  /// A draft belongs to the identity selected when editing began.
  Renaming(
    /// Stable identity, independent of the highlighted row.
    session_id: String,
    /// Bounded single-line draft, sent only on Enter.
    draft: String,
  )

  /// Archiving preserves history and is bound to the originally selected row.
  ConfirmingArchive(
    /// The identity whose history will be retained.
    session_id: String,
  )

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
    /// Which collection this page belongs to.
    collection: Collection,
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

  /// Start a directional link to this selected session without opening it.
  Link(protocol.Session)

  /// Request explicit creation under the terminal's retained durable key.
  NewSession

  /// Commit the edited name for the identity that opened the editor.
  Rename(
    /// Stable catalogue identity.
    session_id: String,
    /// Non-empty single-line name within the wire's byte limit.
    name: String,
  )

  /// Continue only within the same catalogue revision.
  NextPage(after: String, revision: Int)

  /// Restart pagination without retaining rows from the previous revision.
  FirstPage

  /// Return to the old conversation without opening any row.
  Close

  /// Request the other collection without opening any session.
  ShowCollection(Collection)

  /// The operator confirmed preserving this session outside the active list.
  Archive(
    /// Canonical identity bound when confirmation opened.
    session_id: String,
  )

  /// Restore a selected archived row without opening it.
  Restore(
    /// Canonical identity selected explicitly by the owner.
    session_id: String,
  )

  /// The operator confirmed permanent removal of this registration and database.
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
  State(page, selected, current, Active, Browsing)
}

/// Moves this workspace's sessions first without changing order within groups.
///
/// ## Examples
///
/// ```gleam
/// let nearby = session_selector.prioritize(page, "/work/project")
/// ```
pub fn prioritize(page: protocol.Page, workspace: String) -> protocol.Page {
  let workspace = trim_slash(workspace)
  let sessions =
    list.sort(page.sessions, fn(left, right) {
      int.compare(
        workspace_rank(left.workspace, workspace),
        workspace_rank(right.workspace, workspace),
      )
    })
  protocol.Page(..page, sessions:)
}

fn trim_slash(path: String) -> String {
  case string.ends_with(path, "/") && string.length(path) > 1 {
    True -> trim_slash(string.drop_end(path, 1))
    False -> path
  }
}

fn workspace_rank(path: String, workspace: String) -> Int {
  let path = trim_slash(path)
  case path == workspace {
    True -> 0
    False ->
      case
        string.starts_with(path, workspace <> "/")
        || string.starts_with(workspace, path <> "/")
      {
        True -> 1
        False -> 2
      }
  }
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
    LinkUnavailable ->
      case key {
        keys.Escape -> Continue(State(..state, prompt: Browsing))
        _ -> browsing(key, State(..state, prompt: Browsing))
      }
    Renaming(id, draft) -> renaming(key, state, id, draft)
    ConfirmingDelete(session_id) -> confirming(key, state, Delete(session_id))
    ConfirmingArchive(session_id) -> confirming(key, state, Archive(session_id))
  }
}

// Editing retains one bounded draft and its original identity. Navigation
// keys cannot move the target, and Escape never sends a metadata mutation.
fn renaming(key: keys.Key, state: State, id: String, draft: String) -> Action {
  case key {
    keys.Escape -> Continue(State(..state, prompt: Browsing))
    keys.Enter ->
      case string.trim(draft) {
        "" -> Continue(state)
        name -> Rename(id, name)
      }
    keys.Backspace ->
      Continue(State(..state, prompt: Renaming(id, string.drop_end(draft, 1))))
    keys.Ctrl("u") -> Continue(State(..state, prompt: Renaming(id, "")))
    keys.Char(character) -> {
      let next = draft <> text_hygiene.single_line(character)
      case string.byte_size(next) <= 256 {
        True -> Continue(State(..state, prompt: Renaming(id, next)))
        False -> Continue(state)
      }
    }
    _ -> Continue(state)
  }
}

/// Replaces only the acknowledged catalogue row, preserving cursor and page.
///
/// ## Examples
///
/// ```gleam
/// // session_selector.renamed(selector, acknowledged_row)
/// ```
pub fn renamed(state: State, row: protocol.Session) -> State {
  let sessions =
    list.map(state.page.sessions, fn(previous) {
      case previous.session_id == row.session_id {
        True -> row
        False -> previous
      }
    })
  State(..state, page: protocol.Page(..state.page, sessions:), prompt: Browsing)
}

// While the question is open only its two answers exist. Anything else
// withdraws it, because a stray key must never be read as consent to remove
// a conversation.
fn confirming(key: keys.Key, state: State, action: Action) -> Action {
  case key {
    keys.Char("y") -> action
    _other -> Continue(State(..state, prompt: Browsing))
  }
}

fn browsing(key: keys.Key, state: State) -> Action {
  case key {
    keys.Escape -> Close
    keys.Enter ->
      case list.first(list.drop(state.page.sessions, state.selected)) {
        Ok(row) ->
          case state.collection {
            Active -> Choose(row)
            Archived -> Restore(row.session_id)
          }
        Error(Nil) -> Continue(state)
      }
    keys.Char("l") -> link_selected(state)
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
    keys.Char("a") ->
      case state.collection {
        Active -> ShowCollection(Archived)
        Archived -> ShowCollection(Active)
      }
    keys.Char("n") -> NewSession
    keys.Char("r") ->
      case list.first(list.drop(state.page.sessions, state.selected)) {
        Ok(row) ->
          Continue(State(..state, prompt: Renaming(row.session_id, row.name)))
        Error(Nil) -> Continue(state)
      }
    keys.Char("d") ->
      case list.first(list.drop(state.page.sessions, state.selected)) {
        Ok(row) -> {
          let prompt = case state.collection {
            Active -> ConfirmingArchive(row.session_id)
            Archived -> ConfirmingDelete(row.session_id)
          }
          Continue(State(..state, prompt:))
        }
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

// A saved or archived row cannot become a peer target through selection.
fn link_selected(state: State) -> Action {
  case list.first(list.drop(state.page.sessions, state.selected)) {
    Ok(row) ->
      case state.collection {
        Active ->
          case row.status {
            protocol.Resident(_) -> Link(row)
            _ -> Continue(State(..state, prompt: LinkUnavailable))
          }
        Archived -> Continue(state)
      }
    Error(Nil) -> Continue(state)
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
  // Small catalogues need no empty scroll area; full pages retain seven rows.
  let row_count = int.min(7, list.length(state.page.sessions))
  let desired_height = int.max(7, row_count * 2 + 7)
  let area =
    geometry.centered_rect(
      int.max(1, int.min(144, screen.size.width - 4)),
      int.max(1, int.min(desired_height, screen.size.height - 4)),
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
          case state.collection {
            Active -> " SESSIONS · active "
            Archived -> " SESSIONS · archived "
          },
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
            case state.collection {
              Active ->
                "↑↓ select · Enter open · l link · n new · r rename · d archive · a archived · ←→ pages · Esc close"
              Archived ->
                "↑↓ select · Enter restore · r rename · d delete · a active · ←→ pages · Esc close"
            },
            width,
            "…",
          ),
          theme.overlay_quiet(),
        ),
      ])

    LinkUnavailable ->
      span.line_new([
        span.span_styled(
          text.truncate(
            "Open this saved session before linking it · Esc back",
            width,
            "…",
          ),
          theme.overlay_signal(),
        ),
      ])

    Renaming(_, draft) ->
      span.line_new([
        span.span_styled(
          text.truncate(
            "Name: "
              <> text_hygiene.single_line(draft)
              <> "▏ · Enter save · Ctrl+U clear · Esc cancel",
            width,
            "…",
          ),
          theme.overlay_signal(),
        ),
      ])

    // A canonical identity is bounded by the wire at 64 bytes, so this line
    // needs no truncation of its own; hygiene still applies because the text
    // reaches a terminal.
    ConfirmingArchive(session_id) ->
      span.line_new([
        span.span_styled(
          text_hygiene.single_line(
            "stop and archive " <> session_id <> "? history is kept · y/n",
          ),
          theme.overlay_signal(),
        ),
      ])

    ConfirmingDelete(session_id) ->
      span.line_new([
        span.span_styled(
          text_hygiene.single_line(
            "permanently delete " <> session_id <> " and its history? y/n",
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
