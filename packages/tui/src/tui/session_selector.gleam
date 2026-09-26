//// A bounded authorized catalogue page, not a filesystem session inventory.
////
//// Enter explicitly selects one row. Listing, highlighting a default, and
//// navigating pages cannot start execution. The caller carries the revision
//// when requesting the next page and replaces this page instead of accumulating.
////
//// The picker is also the operator's view across sessions. It answers "which
//// of my sessions needs me, and which are still working" without opening any
//// of them. Two observations feed it, and they stay separate. The catalogue
//// page says what each registration is: its workspace, name and lifecycle.
//// The daemon's `sessions.activity` reply says what each *resident* session
//// is doing, and it is asked of resident sessions only, because a saved
//// session has no running actor to ask and discovery must never open one.
//// A row's `Presence` joins the two, and the filter tabs, the glyph beside
//// each row and the details pane all read that one join.
////
//// Rows are drawn grouped by workspace in the order the page gives them, so
//// the prioritized page (this workspace first) still leads. The highlight is
//// an index into that drawn order, `visible`, never into the raw page, so
//// what Enter opens is always the row the marker is on.

import etui/buffer
import etui/geometry.{type Rect}
import etui/keys
import etui/span
import etui/style
import etui/text
import etui/widgets/block
import etui/widgets/paragraph
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
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

/// Which rows the picker draws, chosen with Tab and Shift+Tab.
///
/// Each variant but `AllSessions` admits exactly one `Presence`, so a tab's
/// count and the rows it shows cannot disagree. `Unobserved` rows appear
/// only under `AllSessions`: until the daemon has answered, the picker does
/// not know which of the other tabs they belong to.
pub type Filter {
  /// Every row on the page.
  AllSessions

  /// Resident sessions with a pending approval or a failed last run.
  NeedsYouSessions

  /// Resident sessions with at least one strand running.
  WorkingSessions

  /// Resident sessions with nothing running and nothing pending.
  IdleSessions

  /// Registrations with no running session behind them.
  InactiveSessions
}

/// What the picker knows a row's session is doing.
pub type Presence {
  /// A resident session is waiting on the operator.
  NeedsYou

  /// A resident session has work running.
  Working

  /// A resident session is quiet.
  Idle

  /// A resident session the daemon has not yet described, or which did not
  /// answer when asked.
  Unobserved

  /// A saved, reserved, opening, stopping or blocked registration. Nothing
  /// is running behind it that could be asked.
  Inactive
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
    /// Highlighted position in `visible`; it does not imply an open.
    selected: Int,
    /// Currently attached session or the saved default before attachment.
    current: String,
    /// Which collection this page belongs to.
    collection: Collection,
    /// Navigation, or an open question about one identity.
    prompt: Prompt,
    /// Which rows are drawn.
    filter: Filter,
    /// The latest activity reply for each resident identity on this page.
    activity: Dict(String, protocol.Activity),
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
  let state = State(page, 0, current, Active, Browsing, AllSessions, dict.new())
  State(
    ..state,
    selected: index_of(visible(state), current) |> option.unwrap(0),
  )
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

/// What a row's session is doing, joining its lifecycle with the latest
/// activity reply.
///
/// Only a resident row is ever `NeedsYou`, `Working` or `Idle`, and only on
/// the daemon's word; every other lifecycle is `Inactive`, whatever an old
/// reply said, because a session that stopped since cannot still be working.
///
/// ## Examples
///
/// ```gleam
/// // session_selector.presence(state, saved_row) == session_selector.Inactive
/// ```
pub fn presence(state: State, row: protocol.Session) -> Presence {
  case row.status {
    protocol.Resident(_) ->
      case dict.get(state.activity, row.session_id) {
        Ok(protocol.Activity(state: protocol.NeedsYou, ..)) -> NeedsYou
        Ok(protocol.Activity(state: protocol.Working, ..)) -> Working
        Ok(protocol.Activity(state: protocol.Idle, ..)) -> Idle
        Ok(protocol.Activity(state: protocol.Unknown, ..)) | Error(Nil) ->
          Unobserved
      }
    protocol.Reserved
    | protocol.Saved
    | protocol.Opening(_)
    | protocol.Stopping(_)
    | protocol.RecoveryBlocked -> Inactive
  }
}

/// Reports whether a filter admits a presence.
///
/// ## Examples
///
/// ```gleam
/// assert session_selector.admits(session_selector.AllSessions, session_selector.Idle)
/// ```
pub fn admits(filter: Filter, presence: Presence) -> Bool {
  case filter, presence {
    AllSessions, _ -> True
    NeedsYouSessions, NeedsYou -> True
    WorkingSessions, Working -> True
    IdleSessions, Idle -> True
    InactiveSessions, Inactive -> True
    _, _ -> False
  }
}

/// The rows the filter admits, grouped by workspace.
///
/// Groups appear in the order their first row appears on the page, and rows
/// keep page order within a group, so the prioritized page's own ordering
/// survives grouping.
///
/// ## Examples
///
/// ```gleam
/// // session_selector.groups(state) == [#("/work/loom", [first, second])]
/// ```
pub fn groups(state: State) -> List(#(String, List(protocol.Session))) {
  state.page.sessions
  |> list.filter(fn(row) { admits(state.filter, presence(state, row)) })
  |> list.fold([], fn(groups, row) {
    let workspace = trim_slash(row.workspace)
    case list.key_find(groups, workspace) {
      Ok(rows) -> list.key_set(groups, workspace, [row, ..rows])
      Error(Nil) -> [#(workspace, [row]), ..groups]
    }
  })
  |> list.reverse
  |> list.map(fn(group) { #(group.0, list.reverse(group.1)) })
}

/// The rows in the order they are drawn, which is the order `selected`
/// indexes.
///
/// ## Examples
///
/// ```gleam
/// // list.length(session_selector.visible(state)) <= list.length(state.page.sessions)
/// ```
pub fn visible(state: State) -> List(protocol.Session) {
  state |> groups |> list.flat_map(fn(group) { group.1 })
}

/// The highlighted row, if the filter leaves any.
///
/// ## Examples
///
/// ```gleam
/// // session_selector.selected_row(state) == Some(row)
/// ```
pub fn selected_row(state: State) -> Option(protocol.Session) {
  visible(state)
  |> list.drop(state.selected)
  |> list.first
  |> option.from_result
}

fn index_of(rows: List(protocol.Session), session_id: String) -> Option(Int) {
  rows
  |> list.index_map(fn(row, index) { #(row.session_id, index) })
  |> list.key_find(session_id)
  |> option.from_result
}

/// The resident identities worth asking the daemon about, in page order and
/// at most `protocol.activity_limit` of them.
///
/// The daemon refuses a larger request, which keeps its reply inside the
/// control frame budget. The page is prioritized, so the rows cut by the
/// limit are the ones farthest from this workspace; they stay `Unobserved`.
/// More than that many resident sessions at once is not worth batching for.
///
/// ## Examples
///
/// ```gleam
/// // session_selector.resident_ids(state) == ["resident-a", "resident-b"]
/// ```
pub fn resident_ids(state: State) -> List(String) {
  state.page.sessions
  |> list.filter_map(fn(row) {
    case row.status {
      protocol.Resident(_) -> Ok(row.session_id)
      protocol.Reserved
      | protocol.Saved
      | protocol.Opening(_)
      | protocol.Stopping(_)
      | protocol.RecoveryBlocked -> Error(Nil)
    }
  })
  |> list.take(protocol.activity_limit)
}

/// Adopts one activity reply for the identities it was asked about.
///
/// The reply is a fresh observation of exactly the `asked` identities: one
/// that is absent from it is no longer resident, so its old answer is
/// dropped rather than kept. Answers about identities not on this page are
/// ignored. The highlighted identity stays highlighted if the filter still
/// shows it, since an answer arriving must not move the row under the
/// operator's cursor to a different session.
///
/// ## Examples
///
/// ```gleam
/// // session_selector.observe(state, asked, reply_rows)
/// ```
pub fn observe(
  state: State,
  asked: List(String),
  rows: List(protocol.Activity),
) -> State {
  let on_page = list.map(state.page.sessions, fn(row) { row.session_id })
  let activity =
    rows
    |> list.filter(fn(row) {
      list.contains(asked, row.session_id)
      && list.contains(on_page, row.session_id)
    })
    |> list.fold(dict.drop(state.activity, asked), fn(activity, row) {
      dict.insert(activity, row.session_id, row)
    })
  reselect(state, State(..state, activity:))
}

/// Applies a filter, keeping the highlighted identity if it is still drawn.
///
/// ## Examples
///
/// ```gleam
/// // session_selector.with_filter(state, session_selector.WorkingSessions)
/// ```
pub fn with_filter(state: State, filter: Filter) -> State {
  reselect(state, State(..state, filter:))
}

/// Carries the operator's filter and the last activity answers onto a fresh
/// page of the same collection.
///
/// A reload or a page turn replaces the rows, but it is the same view to
/// the operator: the tab they chose stays chosen, and a resident row that
/// is still on the page keeps its last answer until the next one arrives
/// rather than flickering back to unobserved. Answers for identities no
/// longer on the page are dropped with them.
///
/// ## Examples
///
/// ```gleam
/// // session_selector.carry(open_picker, freshly_loaded)
/// ```
pub fn carry(previous: State, next: State) -> State {
  let on_page = list.map(next.page.sessions, fn(row) { row.session_id })
  let activity = dict.take(previous.activity, on_page)
  let carried = State(..next, activity:)
  reselect(carried, State(..carried, filter: previous.filter))
}

// Keeps the highlighted identity when the drawn rows change underneath it,
// and otherwise clamps the index into the new rows.
fn reselect(before: State, after: State) -> State {
  let rows = visible(after)
  let selected = case selected_row(before) {
    Some(row) -> index_of(rows, row.session_id)
    None -> None
  }
  let selected = case selected {
    Some(index) -> index
    None -> int.max(0, int.min(before.selected, list.length(rows) - 1))
  }
  State(..after, selected:)
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
  let after =
    State(
      ..state,
      page: protocol.Page(..state.page, sessions:),
      activity: dict.delete(state.activity, session_id),
      prompt: Browsing,
    )
  let selected =
    int.min(state.selected, int.max(0, list.length(visible(after)) - 1))
  State(..after, selected:)
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
      case selected_row(state) {
        Some(row) ->
          case state.collection {
            Active -> Choose(row)
            Archived -> Restore(row.session_id)
          }
        None -> Continue(state)
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
            int.min(list.length(visible(state)) - 1, state.selected + 1),
          ),
        ),
      )

    // The filter only narrows what is drawn, so it is local state: no page
    // is fetched and the activity already observed is kept.
    keys.Tab -> Continue(with_filter(state, next(state)))
    keys.BackTab -> Continue(with_filter(state, previous(state)))
    keys.Char("a") ->
      case state.collection {
        Active -> ShowCollection(Archived)
        Archived -> ShowCollection(Active)
      }
    keys.Char("n") -> NewSession
    keys.Char("r") ->
      case selected_row(state) {
        Some(row) ->
          Continue(State(..state, prompt: Renaming(row.session_id, row.name)))
        None -> Continue(state)
      }
    keys.Char("d") ->
      case selected_row(state) {
        Some(row) -> {
          let prompt = case state.collection {
            Active -> ConfirmingArchive(row.session_id)
            Archived -> ConfirmingDelete(row.session_id)
          }
          Continue(State(..state, prompt:))
        }
        None -> Continue(state)
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

// An archived page holds only inactive rows, so its tabs would all be empty
// but one; Tab leaves it on `AllSessions`.
fn next(state: State) -> Filter {
  case state.collection, state.filter {
    Archived, _ -> AllSessions
    Active, AllSessions -> NeedsYouSessions
    Active, NeedsYouSessions -> WorkingSessions
    Active, WorkingSessions -> IdleSessions
    Active, IdleSessions -> InactiveSessions
    Active, InactiveSessions -> AllSessions
  }
}

fn previous(state: State) -> Filter {
  case state.collection, state.filter {
    Archived, _ -> AllSessions
    Active, AllSessions -> InactiveSessions
    Active, NeedsYouSessions -> AllSessions
    Active, WorkingSessions -> NeedsYouSessions
    Active, IdleSessions -> WorkingSessions
    Active, InactiveSessions -> IdleSessions
  }
}

// A saved or archived row cannot become a peer target through selection.
fn link_selected(state: State) -> Action {
  case selected_row(state) {
    Some(row) ->
      case state.collection {
        Active ->
          case row.status {
            protocol.Resident(_) -> Link(row)
            _ -> Continue(State(..state, prompt: LinkUnavailable))
          }
        Archived -> Continue(state)
      }
    None -> Continue(state)
  }
}

/// How many rows on the page each filter would show, in tab order.
///
/// Counts are of this page, not of the whole catalogue: the picker holds
/// one page and never accumulates, so a count past it would be a guess.
///
/// ## Examples
///
/// ```gleam
/// // session_selector.counts(state)
/// //   == [#(AllSessions, 3), #(NeedsYouSessions, 1), ...]
/// ```
pub fn counts(state: State) -> List(#(Filter, Int)) {
  let presences =
    list.map(state.page.sessions, fn(row) { presence(state, row) })
  [
    AllSessions,
    NeedsYouSessions,
    WorkingSessions,
    IdleSessions,
    InactiveSessions,
  ]
  |> list.map(fn(filter) {
    #(filter, list.count(presences, fn(presence) { admits(filter, presence) }))
  })
}

/// The narrowest inner width that gets a details pane beside the list.
const details_width = 96

// Whether the highlighted row's details have a pane of their own. Without
// one, each row carries its status and identity on a second line.
type Arrangement {
  ListOnly
  WithDetails
}

/// Renders only one bounded page and its explicit action hints.
///
/// ## Examples
///
/// ```gleam
/// // session_selector.render(buffer, screen, selector)
/// ```
pub fn render(buf: buffer.Buffer, screen: Rect, state: State) -> buffer.Buffer {
  let width = int.max(1, int.min(160, screen.size.width - 4))

  // The inner width is the frame's less its border and padding. Knowing it
  // before the frame is placed is what lets the height fit the content.
  let inner_width = int.max(0, width - 4)
  let arrangement = case inner_width >= details_width {
    True -> WithDetails
    False -> ListOnly
  }
  let #(list_width, detail_width) = case arrangement {
    WithDetails -> {
      let detail = int.min(56, inner_width * 2 / 5)
      #(inner_width - detail - 3, detail)
    }
    ListOnly -> #(inner_width, 0)
  }

  // Both columns are laid out before the frame is placed, since the taller
  // of the two decides the frame's height.
  let list_lines = list_lines(state, list_width, arrangement)
  let detail_lines = case arrangement, selected_row(state) {
    WithDetails, Some(row) -> detail_lines(state, row, detail_width)
    WithDetails, None | ListOnly, _ -> []
  }

  // Small catalogues need no empty scroll area. Six rows are chrome: the
  // tabs, their rule, the blank line and help below the body, and the top
  // and bottom padding; the border adds two more.
  let body_rows =
    int.max(1, int.max(list.length(list_lines), list.length(detail_lines)))
  let area =
    geometry.centered_rect(
      width,
      int.max(1, int.min(body_rows + 8, screen.size.height - 4)),
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

  // The tabs and their rule take the top two rows of the inside, and the
  // blank line and help the bottom two; the body is what is left between.
  let inside = block.inner(area, frame)
  let body_height = int.max(0, inside.size.height - 4)
  let body_y = inside.position.y + 2
  let list_area =
    geometry.rect_new(inside.position.x, body_y, list_width, body_height)
  let rule =
    span.line_new([
      span.span_styled(
        string.repeat("─", inside.size.width),
        style.new(theme.divider, theme.graphite, style.none()),
      ),
    ])
  let footer =
    geometry.rect_new(
      inside.position.x,
      body_y + body_height,
      inside.size.width,
      2,
    )
  let painted =
    buf
    |> buffer.clear(area)
    |> block.render(area, frame)
    |> paragraph.render_styled(inside, [
      tabs_line(state, inside.size.width),
      rule,
    ])
    |> paragraph.render_styled(
      list_area,
      window(list_lines, state, body_height),
    )
    |> paragraph.render_styled(footer, [
      span.line_new([]),
      help_line(state, inside.size.width),
    ])
  case arrangement {
    ListOnly -> painted
    WithDetails -> {
      let divider =
        geometry.rect_new(
          inside.position.x + list_width + 1,
          body_y,
          1,
          body_height,
        )
      let details =
        geometry.rect_new(
          inside.position.x + list_width + 3,
          body_y,
          detail_width,
          body_height,
        )
      painted
      |> paragraph.render_styled(
        divider,
        list.repeat(
          span.line_new([
            span.span_styled(
              "│",
              style.new(theme.divider, theme.graphite, style.none()),
            ),
          ]),
          body_height,
        ),
      )
      |> paragraph.render_styled(details, list.take(detail_lines, body_height))
    }
  }
}

// A drawn list line, tagged with the visible-row index it draws, if any, so
// the window can keep the highlighted row on screen.
type ListLine {
  ListLine(row: Option(Int), line: span.Line)
}

// Group headers, rows and the blank lines between groups, in drawn order.
fn list_lines(
  state: State,
  width: Int,
  arrangement: Arrangement,
) -> List(ListLine) {
  let groups = groups(state)
  case groups {
    [] -> [
      ListLine(
        None,
        span.line_new([
          span.span_styled(
            text.truncate(empty_message(state), width, "…"),
            theme.overlay_quiet(),
          ),
        ]),
      ),
    ]
    _ -> {
      let #(lines, _) =
        list.fold(groups, #([], 0), fn(acc, group) {
          let #(lines, first) = acc
          let #(workspace, rows) = group
          let count = " " <> int.to_string(list.length(rows))
          let header =
            ListLine(
              None,
              span.line_new([
                span.span_styled(
                  fit_workspace(workspace, width - text.cell_width(count))
                    <> count,
                  theme.overlay_quiet(),
                ),
              ]),
            )
          let drawn =
            rows
            |> list.index_map(fn(row, offset) {
              row_lines(state, row, first + offset, width, arrangement)
              |> list.map(ListLine(Some(first + offset), _))
            })
            |> list.flatten
          let gap = case lines {
            [] -> []
            _ -> [ListLine(None, span.line_new([]))]
          }
          #(
            list.flatten([lines, gap, [header], drawn]),
            first + list.length(rows),
          )
        })
      lines
    }
  }
}

fn empty_message(state: State) -> String {
  case state.page.sessions, state.filter {
    [], _ -> "No saved sessions. Press n to create one explicitly."
    _, _ -> "No sessions match this filter. Tab shows the next one."
  }
}

// One row. The first line is the marker, the presence glyph, the name and
// the current-session tag. A wide picker adds the lifecycle tag and short
// identity on the same line and leaves the rest to the details pane. A
// narrow one has no pane, so it gives them a second line of their own:
// two sessions can share a name, and a row that cut its identity to keep
// the name, or the reverse, would leave the operator unable to tell them
// apart.
fn row_lines(
  state: State,
  row: protocol.Session,
  index: Int,
  width: Int,
  arrangement: Arrangement,
) -> List(span.Line) {
  let #(marker, name_style) = case index == state.selected {
    True -> #("▸ ", theme.overlay_signal())
    False -> #("  ", theme.overlay_plain())
  }
  let presence = presence(state, row)
  let identity = short_identity(row.session_id)
  let tag = case row.status {
    protocol.Resident(_) -> ""
    status -> " [" <> lifecycle(status) <> "]"
  }
  let suffix = case arrangement {
    WithDetails -> tag <> " · " <> identity
    ListOnly -> ""
  }
  let current = case row.session_id == state.current {
    True -> " current"
    False -> ""
  }

  // The name gets whatever the fixed pieces leave, and the current tag is
  // pushed to the right edge by padding after it.
  let fixed =
    text.cell_width(marker)
    + 2
    + text.cell_width(suffix)
    + text.cell_width(current)
  let name =
    text.truncate(
      text_hygiene.single_line(row.name),
      int.max(0, width - fixed),
      "…",
    )
  let used = fixed + text.cell_width(name)
  let first =
    span.line_new([
      span.span_styled(marker, name_style),
      span.span_styled(glyph(presence) <> " ", presence_style(presence)),
      span.span_styled(name, name_style),
      span.span_styled(suffix, theme.overlay_quiet()),
      span.span_styled(string.repeat(" ", int.max(0, width - used)), name_style),
      span.span_styled(current, theme.overlay_current()),
    ])
  case arrangement {
    WithDetails -> [first]
    ListOnly -> [
      first,
      span.line_new([
        span.span_styled(
          text.truncate(
            "    " <> short_status(presence, row) <> " · " <> identity,
            width,
            "…",
          ),
          theme.overlay_quiet(),
        ),
      ]),
    ]
  }
}

// The one or two words a narrow row has room for.
fn short_status(presence: Presence, row: protocol.Session) -> String {
  case presence {
    NeedsYou -> "needs you"
    Working -> "working"
    Idle -> "idle"
    Unobserved -> "resident"
    Inactive -> lifecycle(row.status)
  }
}

// Scrolls so every line of the highlighted row is on screen, by bringing
// its last line to the bottom when it would otherwise fall below.
fn window(lines: List(ListLine), state: State, height: Int) -> List(span.Line) {
  let position =
    lines
    |> list.index_map(fn(line, index) { #(line.row, index) })
    |> list.filter(fn(pair) { pair.0 == Some(state.selected) })
    |> list.last
    |> result.map(fn(pair) { pair.1 })
    |> result.unwrap(0)
  let start = int.max(0, position - height + 1)
  lines
  |> list.drop(start)
  |> list.take(height)
  |> list.map(fn(line) { line.line })
}

// The tab row. A narrow picker drops the Tab hint before it drops a tab.
fn tabs_line(state: State, width: Int) -> span.Line {
  case state.collection {
    Archived ->
      span.line_new([
        span.span_styled(
          text.truncate(
            "Archived sessions are restored before they can be opened.",
            width,
            "…",
          ),
          theme.overlay_quiet(),
        ),
      ])
    Active -> {
      let tabs =
        list.map(counts(state), fn(pair) {
          let #(filter, count) = pair
          let label = filter_label(filter) <> " " <> int.to_string(count)
          case filter == state.filter {
            True ->
              span.span_styled(
                " " <> label <> " ",
                style.new(theme.graphite, theme.signal, style.bold()),
              )
            False ->
              span.span_styled(" " <> label <> " ", theme.overlay_quiet())
          }
        })
      let hint = "Tab filter"
      let used =
        list.fold(tabs, 0, fn(total, tab) {
          total + text.cell_width(tab.content)
        })
      let hint_spans = case used + text.cell_width(hint) + 2 <= width {
        True -> [
          span.span_styled(
            string.repeat(" ", width - used - text.cell_width(hint)),
            theme.overlay_quiet(),
          ),
          span.span_styled(hint, theme.overlay_quiet()),
        ]
        False -> []
      }
      span.line_new(list.append(tabs, hint_spans))
    }
  }
}

fn filter_label(filter: Filter) -> String {
  case filter {
    AllSessions -> "All"
    NeedsYouSessions -> "Needs you"
    WorkingSessions -> "Working"
    IdleSessions -> "Idle"
    InactiveSessions -> "Inactive"
  }
}

// Every presence has a glyph as well as a color, so the list reads without
// color.
fn glyph(presence: Presence) -> String {
  case presence {
    NeedsYou -> "!"
    Working -> "●"
    Idle -> "○"
    Unobserved -> "◌"
    Inactive -> "·"
  }
}

fn presence_style(presence: Presence) -> style.Style {
  case presence {
    NeedsYou -> style.new(theme.danger, theme.graphite, style.bold())
    Working -> theme.overlay_current()
    Idle -> style.new(theme.added, theme.graphite, style.none())
    Unobserved | Inactive -> theme.overlay_quiet()
  }
}

// The details pane for the highlighted row: what it is doing and why, the
// daemon's last word from it and its agents, then where it lives. Every
// line is pre-wrapped to the pane, because an overlay row never wraps.
fn detail_lines(
  state: State,
  row: protocol.Session,
  width: Int,
) -> List(span.Line) {
  let presence = presence(state, row)
  let activity = option.from_result(dict.get(state.activity, row.session_id))
  let plain = theme.overlay_plain()
  let quiet = theme.overlay_quiet()

  // The name and the status line say what the row is doing; the sections
  // below appear only when the daemon's answer carries them.
  let heading =
    wrapped(text_hygiene.single_line(row.name), width, theme.overlay_signal())
  let status = [
    span.line_new([
      span.span_styled(glyph(presence) <> " ", presence_style(presence)),
      span.span_styled(
        text.truncate(status_text(presence, row, activity), width - 2, "…"),
        presence_style(presence),
      ),
    ]),
  ]

  let message = case activity {
    Some(protocol.Activity(last_message: Some(message), ..)) ->
      section("Last message", wrapped(message, width, plain) |> list.take(8))
    _ -> []
  }
  let agents = case activity {
    Some(protocol.Activity(glances: [_, ..] as glances, ..)) ->
      section(
        "Agents",
        list.flat_map(glances, fn(glance) {
          list.append(
            wrapped(glance.strand <> " · " <> glance.title, width, plain)
              |> list.take(1),
            wrapped(glance.summary, width, quiet) |> list.take(2),
          )
        }),
      )
    _ -> []
  }
  let model = case activity {
    Some(protocol.Activity(model: Some(model), ..)) ->
      section("Model", wrapped(model, width, plain))
    _ -> []
  }
  list.flatten([
    heading,
    status,
    message,
    agents,
    section("Workspace", wrapped(row.workspace, width, plain)),
    model,
    section("Session", wrapped(row.session_id, width, plain)),
  ])
}

fn section(label: String, body: List(span.Line)) -> List(span.Line) {
  [
    span.line_new([]),
    span.line_new([span.span_styled(label, theme.overlay_quiet())]),
    ..body
  ]
}

fn wrapped(value: String, width: Int, style: style.Style) -> List(span.Line) {
  value
  |> text_hygiene.single_line
  |> text.wrap(int.max(1, width))
  |> list.map(fn(line) { span.line_new([span.span_styled(line, style)]) })
}

// Says why a row is where it is. The reason for `NeedsYou` comes first
// because it is what the operator has to act on.
fn status_text(
  presence: Presence,
  row: protocol.Session,
  activity: Option(protocol.Activity),
) -> String {
  case presence, activity {
    NeedsYou, Some(protocol.Activity(approvals:, ..)) if approvals > 0 ->
      "Needs you · " <> plural(approvals, "approval") <> " pending"
    NeedsYou,
      Some(protocol.Activity(last_outcome: Some(protocol.LastFailed), ..))
    -> "Needs you · last run failed"
    NeedsYou, _ -> "Needs you"
    Working, Some(protocol.Activity(strands:, working:, ..)) if strands > 1 ->
      "Working · "
      <> int.to_string(working)
      <> " of "
      <> plural(strands, "agent")
      <> " running"
    Working, _ -> "Working"
    Idle,
      Some(protocol.Activity(last_outcome: Some(protocol.LastCompleted), ..))
    -> "Idle · last run completed"
    Idle, Some(protocol.Activity(last_outcome: Some(protocol.LastAborted), ..))
    -> "Idle · last run aborted"
    Idle, _ -> "Idle"
    Unobserved, Some(_) -> "Resident · did not answer"
    Unobserved, None -> "Resident · activity not yet observed"
    Inactive, _ -> "Inactive · " <> lifecycle(row.status) <> " · Enter opens"
  }
}

fn plural(count: Int, noun: String) -> String {
  int.to_string(count)
  <> " "
  <> case count == 1 {
    True -> noun
    False -> noun <> "s"
  }
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
                "↑↓ select · Enter open · Tab filter · l link · n new · r rename · d archive · a archived · ←→ pages · Esc close"
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
