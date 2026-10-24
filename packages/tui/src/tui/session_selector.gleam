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
////
//// ## Flow
////
//// `prioritize` → `new` → `observe` → `update` → `browsing` → `render`
////
//// 1. `prioritize` puts this workspace's rows first in a catalogue page, and `new`
////    builds the selector from the page, highlighting the current session.
//// 2. `observe` files the daemon's sessions-activity answer, so `presence` can
////    join what a registration is with what its resident session is doing;
////    `with_filter` and `carry` keep the operator's tab across page replacements.
//// 3. `update` dispatches by prompt: `browsing` for ordinary navigation,
////    `renaming` for a draft, `confirming` for an archive or delete question.
//// 4. Every key answers an `Action` for the shell, which turns it into a control
////    job. `confirming` sends only on y, naming the session
////    the question was asked about rather than the highlighted row.
//// 5. A reply returns through `renamed` and `without`, which reshape the state and
////    `reselect` the row so the highlight follows the identity.
//// 6. `render` picks a layout by width, draws the grouped rows (`list_lines`,
////    `row_lines`, `window`) beside the details pane (`detail_lines`), and ends
////    with `help_lines`; `visible` is the one drawn order the highlight indexes.

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
import gleam/set
import gleam/string
import session_view/agent_roster
import session_view/text_hygiene
import tui/agent_row
import tui/daemon/protocol
import tui/theme
import tui/workspace

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

/// Ranks path distance relative to current workspace directory.
fn workspace_rank(path: String, workspace: String) -> Int {
  let path = trim_slash(path)

  // Rank exact match, subdirectory, or unrelated path.
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
    | protocol.FailedStart(..)
    | protocol.Saved
    | protocol.Moving(_)
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

/// Where a group's sessions live: a directory on the daemon's host, or a
/// workspace registered on an executor (protocol-change/078).
///
/// The two are different kinds of text, and the executor is part of the
/// identity of a registered workspace: two executors may each register a
/// workspace called `app`, and their sessions are not one project. Grouping on
/// the workspace text alone would merge them, and would draw a registered name
/// with the path arithmetic that only a directory deserves.
pub type Place {
  /// A canonical directory on the daemon's own host.
  Directory(path: String)

  /// A name registered on this executor, kept as the daemon sent it.
  Registered(executor: String, workspace: String)
}

/// The place a row's session lives.
///
/// ## Examples
///
/// ```gleam
/// // session_selector.place(row) == session_selector.Directory("/work/loom")
/// ```
pub fn place(row: protocol.Session) -> Place {
  case row.executor {
    Some(executor) -> Registered(executor, row.workspace)
    None -> Directory(trim_slash(row.workspace))
  }
}

/// The rows the filter admits, grouped by place.
///
/// Groups appear in the order their first row appears on the page, and rows
/// keep page order within a group, so the prioritized page's own ordering
/// survives grouping.
///
/// ## Examples
///
/// ```gleam
/// // session_selector.groups(state)
/// //   == [#(session_selector.Directory("/work/loom"), [first, second])]
/// ```
pub fn groups(state: State) -> List(#(Place, List(protocol.Session))) {
  state.page.sessions
  |> list.filter(fn(row) { admits(state.filter, presence(state, row)) })
  |> list.fold([], fn(groups, row) {
    let here = place(row)

    // Append row to matching place group.
    case list.key_find(groups, here) {
      Ok(rows) -> list.key_set(groups, here, [row, ..rows])
      Error(Nil) -> [#(here, [row]), ..groups]
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
      | protocol.FailedStart(..)
      | protocol.Saved
      | protocol.Moving(_)
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
/// that is absent from it was not running when the daemon's registry was
/// asked, so its old answer is dropped rather than kept. Answers about identities not on this page are
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

/// Recomputes selected row index after state mutation.
fn reselect(before: State, after: State) -> State {
  let rows = visible(after)

  // Preserve previous row identity if present.
  let selected = case selected_row(before) {
    Some(row) -> index_of(rows, row.session_id)
    None -> None
  }

  // Fall back to clamped index.
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

/// Handles key events while renaming a session row.
fn renaming(key: keys.Key, state: State, id: String, draft: String) -> Action {
  // Handle renaming keyboard actions.
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

      // Check byte budget for rename draft.
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

/// Handles key navigation and actions during session browsing.
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
          // Confirm delete or archive action depending on collection.
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

/// Cycles to next filter tab.
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

/// Cycles to previous filter tab.
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

/// Action to link selected session if eligible.
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

/// The widest the picker grows. Past this a wider terminal only spreads the
/// columns apart, so a 200-column screen draws the picker at the size a
/// 120-column one does and the rows stay easy to follow across.
const widest = 116

/// The cells of the state-word column: the longest word, `needs you`, and
/// one spare, so the column after it always starts in the same cell.
const state_width = 10

/// The cells of the age column, right-aligned: `12m`, `2d`, `now`.
const age_width = 3

// Whether the highlighted row's details have a pane of their own. Without
// one, the highlighted row carries its reason and last message on a second
// line instead.
type Arrangement {
  ListOnly
  WithDetails
}

// The list's width and the cells its two flexible columns get. Everything
// else in a row has a fixed width, so these numbers are the whole layout:
// marker 2, glyph 2, name, gap 1, state 10, gap 1, summary, age 3, and a
// one-cell margin before the divider. Without a pane there is no summary
// column (`summary` is zero), and the age follows the state word directly;
// the highlighted bar still spans the full `width`.
type Columns {
  Columns(width: Int, name: Int, summary: Int)
}

/// Computes column widths for list arrangement.
fn columns(width: Int, arrangement: Arrangement) -> Columns {
  // Size name and summary columns depending on details pane.
  case arrangement {
    WithDetails -> {
      let name = int.clamp(width - 37, min: 12, max: 40)
      Columns(width:, name:, summary: int.max(0, width - name - 20))
    }
    ListOnly ->
      Columns(
        width:,
        name: int.clamp({ width - 20 } / 2, min: 12, max: 28),
        summary: 0,
      )
  }
}

/// Renders only one bounded page and its explicit action hints.
///
/// The picker owns the whole of `screen`: it clears it before drawing, so
/// nothing of the transcript shows in the margins beside the frame. The
/// caller hands it the screen below the identity line.
///
/// `now_ms` is the host's wall clock, and it is used for one thing: the age
/// column, which is the row's creation age because the page carries no
/// last-activity time.
///
/// ## Examples
///
/// ```gleam
/// // session_selector.render(buffer, screen, selector, model.view.wall_ms)
/// ```
pub fn render(
  buf: buffer.Buffer,
  screen: Rect,
  state: State,
  now_ms: Int,
) -> buffer.Buffer {
  let width = int.max(1, int.min(widest, screen.size.width - 4))

  // The inner width is the frame's less its border and padding. Knowing it
  // before the frame is placed is what lets the height fit the content.
  let inner_width = int.max(0, width - 4)

  // Choose arrangement mode based on available width.
  let arrangement = case inner_width >= details_width {
    True -> WithDetails
    False -> ListOnly
  }

  // Determine column widths for list and details.
  let #(list_width, detail_width) = case arrangement {
    WithDetails -> {
      let detail = int.min(56, inner_width * 2 / 5)
      #(inner_width - detail - 3, detail)
    }
    ListOnly -> #(inner_width, 0)
  }

  // Both columns are laid out before the frame is placed, since the taller
  // of the two decides the frame's height.
  let list_lines = list_lines(state, list_width, arrangement, now_ms)

  // Format details column lines if arrangement permits.
  let detail_lines = case arrangement, selected_row(state) {
    WithDetails, Some(row) -> detail_lines(state, row, detail_width)
    WithDetails, None | ListOnly, _ -> []
  }

  // Small catalogues need no empty scroll area. Eight rows are chrome: the
  // border's two, the top padding, the tabs and their rule, and the blank
  // line and two hint rows below the body.
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
            Active -> " SESSIONS · Left from an empty composer "
            Archived -> " SESSIONS · archived "
          },
          theme.overlay_signal(),
        ),
      ],
      block.Top,
    )
    |> block.with_padding(1, 0, 1, 1)

  // The tabs and their rule take the top two rows of the inside, and the
  // blank line and the two hint rows the bottom three; the body is what is
  // left between.
  let inside = block.inner(area, frame)
  let body_height = int.max(0, inside.size.height - 5)
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
      3,
    )

  // etui's background fill covers the area inside the padding only, so
  // the padding cells are given the modal background first; without it a
  // column of terminal background runs down each side inside the border.
  let painted =
    buf
    |> buffer.clear(screen)
    |> buffer.set_style(area, theme.overlay_plain())
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
      ..help_lines(state, inside.size.width)
    ])

  // An empty page has no row to describe, so it gets no pane and no divider
  // beside its one line of advice.
  case arrangement, detail_lines {
    ListOnly, _ | WithDetails, [] -> painted
    WithDetails, [_, ..] -> {
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
// the window can keep the highlighted row on screen and count what it hides.
type ListLine {
  ListLine(row: Option(Int), line: span.Line)
}

/// Formats list lines for session groups in drawn order.
fn list_lines(
  state: State,
  width: Int,
  arrangement: Arrangement,
  now_ms: Int,
) -> List(ListLine) {
  let groups = groups(state)
  let columns = columns(width, arrangement)
  let twins = twin_names(state)

  // Check whether groups list is empty.
  case groups {
    [] -> [
      ListLine(
        None,
        span.line_new([
          span.span_styled(
            text.truncate(" " <> empty_message(state), width, "…"),
            theme.overlay_quiet(),
          ),
        ]),
      ),
    ]
    _ -> {
      let #(lines, _) =
        list.fold(groups, #([], 0), fn(acc, group) {
          let #(lines, first) = acc
          let #(place, rows) = group
          let header =
            ListLine(None, group_header(place, list.length(rows), width))
          let drawn =
            rows
            |> list.index_map(fn(row, offset) {
              let label = row_label(row, twins)
              row_lines(state, row, label, first + offset, columns, now_ms)
              |> list.map(ListLine(Some(first + offset), _))
            })
            |> list.flatten

          // Insert blank gap line between groups.
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
    [], _ -> "No saved sessions. Press n to create one."
    _, _ -> "No sessions match this filter. Tab shows the next one."
  }
}

/// Identifies duplicate session names that need disambiguation IDs.
fn twin_names(state: State) -> set.Set(String) {
  let #(_, twins) =
    list.fold(state.page.sessions, #(set.new(), set.new()), fn(acc, row) {
      let #(seen, twins) = acc

      // Detect duplicate name collision.
      case set.contains(seen, row.name) {
        True -> #(seen, set.insert(twins, row.name))
        False -> #(set.insert(seen, row.name), twins)
      }
    })
  twins
}

// The label a row draws: its name, and for a twin its short identity, which
// a truncation must keep, so the name is cut first.
type Label {
  Plain(name: String)
  Twin(name: String, identity: String)
}

/// Creates plain or disambiguated twin label for session row.
fn row_label(row: protocol.Session, twins: set.Set(String)) -> Label {
  let name = text_hygiene.single_line(row.name)

  // Check whether session name collides with another row.
  case set.contains(twins, row.name) {
    True -> Twin(name, short_identity(row.session_id))
    False -> Plain(name)
  }
}

/// Truncates label to fit within target cell width.
fn fit_label(label: Label, width: Int) -> String {
  // Truncate plain name or twin with identity suffix.
  case label {
    Plain(name) -> text.truncate(name, width, "…")
    Twin(name, identity) -> {
      let suffix = " · " <> identity
      let room = width - text.cell_width(suffix)

      // Fit name and identity suffix into target width.
      case room >= 4 {
        True -> text.truncate(name, room, "…") <> suffix
        False -> text.truncate(identity, width, "…")
      }
    }
  }
}

// One workspace heading: its last path segment in capitals, the path
/// Formats group header line showing workspace name and session count.
fn group_header(place: Place, count: Int, width: Int) -> span.Line {
  // Format workspace location string.
  let #(name, location) = case place {
    Directory(path) -> #(workspace_name(path), home_relative(path))
    Registered(executor:, workspace:) -> #(
      text_hygiene.single_line(workspace),
      "on " <> text_hygiene.single_line(executor),
    )
  }

  let label =
    text.truncate(" " <> string.uppercase(name), int.max(4, width / 3), "…")
  let tally = int.to_string(count) <> " "
  let room = width - text.cell_width(label) - 2 - text.cell_width(tally) - 1
  let path = fit_tail(location, int.max(0, room))
  let used =
    text.cell_width(label) + 2 + text.cell_width(path) + text.cell_width(tally)
  span.line_new([
    span.span_styled(
      label,
      style.new(theme.quiet, theme.graphite, style.bold()),
    ),
    span.span_styled("  " <> path, theme.overlay_quiet()),
    span.span_styled(
      string.repeat(" ", int.max(0, width - used)),
      theme.overlay_quiet(),
    ),
    span.span_styled(tally, theme.overlay_quiet()),
  ])
}

/// Extracts basename of workspace directory path.
fn workspace_name(workspace: String) -> String {
  let name =
    workspace
    |> text_hygiene.single_line
    |> string.split("/")
    |> list.last
    |> result.unwrap("")

  // Fallback to full string if trailing element was empty.
  case name {
    "" -> text_hygiene.single_line(workspace)
    name -> name
  }
}

// A path under a conventional home root reads as `~/…`, as the terminal
// writes its own workspace (`workspace.path_label`). The shortening is
// presentation only: no path drawn here is ever used for routing.
fn home_relative(path: String) -> String {
  workspace.path_label(text_hygiene.single_line(path))
}

// One row. The first line is the marker, the glyph, the label, the state
// word, a short reason and the age, each in a column of its own. Without a
// details pane the highlighted row gets a second line with the longer
// reason and the session's last message, which the pane would otherwise
// show. The highlighted row is painted on the raised background across the
// list's full width, so it reads as one bar.
/// Formats one or two lines representing a single session row.
fn row_lines(
  state: State,
  row: protocol.Session,
  label: Label,
  index: Int,
  columns: Columns,
  now_ms: Int,
) -> List(span.Line) {
  let presence = presence(state, row)
  let activity = option.from_result(dict.get(state.activity, row.session_id))

  // The cursor's mark is amber and bold; the attached session's is quiet,
  // so one column never shows two marks that both read as a selection.
  let #(marker, background, name_weight, mark_look) = case
    index == state.selected,
    row.session_id == state.current
  {
    True, _ -> #(
      "▸ ",
      theme.raised,
      style.bold(),
      #(theme.signal, style.bold()),
    )
    False, True -> #(
      "› ",
      theme.graphite,
      style.none(),
      #(theme.quiet, style.none()),
    )
    False, False -> #(
      "  ",
      theme.graphite,
      style.none(),
      #(theme.quiet, style.none()),
    )
  }

  let tone = tone(presence, row.status)
  let name = text.pad_right(fit_label(label, columns.name), columns.name)
  let word = text.pad_right(state_word(presence, row.status), state_width)

  // The summary column is one cell narrower than its width, so a summary
  // that fills it still leaves a space before the age.
  let summary = case columns.summary {
    0 -> ""
    cells ->
      text.pad_right(
        text.truncate(summary_phrase(presence, row, activity), cells - 1, "…"),
        cells,
      )
  }

  let first =
    span.line_new([
      span.span_styled(marker, style.new(mark_look.0, background, mark_look.1)),
      span.span_styled(
        glyph(presence, row.status) <> " ",
        style.new(tone.0, background, tone.1),
      ),
      span.span_styled(
        name <> " ",
        style.new(theme.paper, background, name_weight),
      ),
      span.span_styled(word <> " ", style.new(tone.0, background, style.none())),
      span.span_styled(
        summary,
        style.new(theme.quiet, background, style.none()),
      ),
      span.span_styled(
        text.pad_left(age(now_ms, row.created_at), age_width) <> " ",
        style.new(theme.quiet, background, style.none()),
      ),
    ])
  let width = columns.width
  let first = pad_line(first, width, background)

  // Render secondary expansion line if selected without summary pane.
  case index == state.selected, columns.summary {
    True, 0 -> [
      first,
      pad_line(
        span.line_new([
          span.span_styled(
            "    " <> cut(expansion(state, presence, row, activity), width - 5),
            style.new(theme.quiet, background, style.none()),
          ),
        ]),
        width,
        background,
      ),
    ]
    True, _ | False, _ -> [first]
  }
}

/// Pads a line with blank space on the given background color to target width.
fn pad_line(line: span.Line, width: Int, background: style.Color) -> span.Line {
  let used =
    list.fold(line.spans, 0, fn(total, piece) {
      total + text.cell_width(piece.content)
    })

  // Check whether padding spaces are needed.
  case used < width {
    True ->
      span.line_new(
        list.append(line.spans, [
          span.span_styled(
            string.repeat(" ", width - used),
            style.new(theme.quiet, background, style.none()),
          ),
        ]),
      )
    False -> line
  }
}

/// Determines text color and weight for session presence status.
fn tone(
  presence: Presence,
  status: protocol.Lifecycle,
) -> #(style.Color, style.Modifier) {
  case presence, status {
    NeedsYou, _ -> #(theme.danger, style.bold())
    Working, _ -> #(theme.current, style.none())
    Inactive, protocol.RecoveryBlocked -> #(theme.danger, style.none())
    Idle, _ | Unobserved, _ | Inactive, _ -> #(theme.quiet, style.none())
  }
}

/// Determines visual glyph symbol representing session presence.
fn glyph(presence: Presence, status: protocol.Lifecycle) -> String {
  case presence, status {
    NeedsYou, _ -> "!"
    Working, _ -> "●"
    Idle, _ -> "○"
    Unobserved, _ -> "◌"
    Inactive, protocol.RecoveryBlocked -> "×"
    Inactive, _ -> "·"
  }
}

/// Derives short state text label for presence and lifecycle.
fn state_word(presence: Presence, status: protocol.Lifecycle) -> String {
  case presence {
    NeedsYou -> "needs you"
    Working -> "working"
    Idle -> "idle"
    Unobserved -> "resident"
    Inactive ->
      case status {
        protocol.RecoveryBlocked -> "blocked"
        other -> lifecycle(other)
      }
  }
}

/// Generates a brief summary phrase describing the active session state.
fn summary_phrase(
  presence: Presence,
  row: protocol.Session,
  activity: Option(protocol.Activity),
) -> String {
  case presence, activity {
    NeedsYou, Some(protocol.Activity(approvals:, ..)) if approvals > 0 ->
      plural(approvals, "approval")
    NeedsYou,
      Some(protocol.Activity(last_outcome: Some(protocol.LastFailed), ..))
    -> "last run failed"
    NeedsYou, _ -> ""

    // `strands` counts every strand the session has ever held, finished
    // sub-agents included, so the working count leads.
    Working, Some(protocol.Activity(working:, strands:, ..))
      if strands > working
    -> int.to_string(working) <> " of " <> plural(strands, "strand")
    Working, Some(protocol.Activity(working:, ..)) -> plural(working, "strand")
    Working, None -> ""
    Idle, Some(protocol.Activity(strands:, ..)) if strands > 1 ->
      plural(strands, "strand")
    Idle, Some(protocol.Activity(last_outcome: Some(protocol.LastAborted), ..))
    -> "last run aborted"
    Idle, Some(protocol.Activity(last_outcome: Some(protocol.LastFailed), ..))
    -> "last run failed"
    Idle, _ -> ""
    Unobserved, Some(_) -> "did not answer"
    Unobserved, None -> "not yet observed"
    Inactive, _ ->
      case row.status {
        protocol.RecoveryBlocked -> "recovery blocked"
        protocol.FailedStart(..) -> "failed to start"
        protocol.Reserved
        | protocol.Saved
        | protocol.Moving(_)
        | protocol.Opening(_)
        | protocol.Resident(_)
        | protocol.Stopping(_) -> ""
      }
  }
}

/// Generates detailed status reason string for session inspection.
fn reason(
  state: State,
  presence: Presence,
  row: protocol.Session,
  activity: Option(protocol.Activity),
) -> String {
  // Describe reason according to presence and activity observation.
  case presence, activity {
    NeedsYou, Some(protocol.Activity(approvals:, ..)) if approvals > 0 ->
      plural(approvals, "approval") <> " pending"
    NeedsYou,
      Some(protocol.Activity(last_outcome: Some(protocol.LastFailed), ..))
    -> "last run failed"
    NeedsYou, _ -> ""
    Working, Some(protocol.Activity(working:, strands:, ..))
      if strands > working
    ->
      int.to_string(working)
      <> " of "
      <> plural(strands, "strand")
      <> " working"
    Working, Some(protocol.Activity(working:, ..)) ->
      plural(working, "strand") <> " working"
    Working, None -> ""
    Idle,
      Some(protocol.Activity(last_outcome: Some(protocol.LastCompleted), ..))
    -> "last run completed"
    Idle, Some(protocol.Activity(last_outcome: Some(protocol.LastAborted), ..))
    -> "last run aborted"
    Idle, Some(protocol.Activity(last_outcome: Some(protocol.LastFailed), ..))
    -> "last run failed"
    Idle, _ -> ""
    Unobserved, Some(_) -> "did not answer"
    Unobserved, None -> "activity not yet observed"
    Inactive, _ -> {
      // Format action text based on collection.
      let enter = case state.collection {
        Active -> "Enter opens"
        Archived -> "Enter restores"
      }

      // Format status reason string based on lifecycle.
      case row.status {
        protocol.RecoveryBlocked -> "recovery blocked · " <> enter

        // The row cannot be opened from here until the move ends, so it offers
        // no Enter.
        protocol.Moving(_) -> "cannot be opened until the move ends"

        // The reason is the daemon's own line, drawn as one row of text.
        protocol.FailedStart(reason:, ..) ->
          "failed to start: " <> text_hygiene.single_line(reason)
        protocol.Reserved
        | protocol.Saved
        | protocol.Opening(_)
        | protocol.Resident(_)
        | protocol.Stopping(_) -> enter
      }
    }
  }
}

/// Formats secondary detail line for narrow viewport expansion.
fn expansion(
  state: State,
  presence: Presence,
  row: protocol.Session,
  activity: Option(protocol.Activity),
) -> String {
  // Extract last message text if activity was observed.
  let message = case activity {
    Some(protocol.Activity(last_message: Some(message), ..)) ->
      text_hygiene.single_line(message)
    Some(protocol.Activity(last_message: None, ..)) | None -> ""
  }

  [reason(state, presence, row, activity), message]
  |> list.filter(fn(part) { part != "" })
  |> string.join(" · ")
}

/// Formats session creation age into a compact time unit string.
fn age(now_ms: Int, created_at: Int) -> String {
  let seconds = int.max(0, now_ms - created_at) / 1000

  // Convert age in seconds to human readable units.
  case seconds {
    seconds if seconds < 60 -> "now"
    seconds if seconds < 3600 -> int.to_string(seconds / 60) <> "m"
    seconds if seconds < 86_400 -> int.to_string(seconds / 3600) <> "h"
    seconds if seconds < 604_800 -> int.to_string(seconds / 86_400) <> "d"
    seconds if seconds < 31_536_000 -> int.to_string(seconds / 604_800) <> "w"
    seconds -> int.to_string(seconds / 31_536_000) <> "y"
  }
}

/// Windows list lines so the selected row remains visible on screen.
fn window(lines: List(ListLine), state: State, height: Int) -> List(span.Line) {
  let total = list.length(lines)
  let selected =
    lines
    |> list.index_map(fn(line, index) { #(line.row, index) })
    |> list.filter(fn(pair) { pair.0 == Some(state.selected) })
    |> list.map(fn(pair) { pair.1 })
  let first = list.first(selected) |> result.unwrap(0)
  let last = list.last(selected) |> result.unwrap(0)

  // Window rows or use full height slice.
  let shown = case total <= height || height < 4 {
    True ->
      lines |> list.drop(int.max(0, last - height + 1)) |> list.take(height)
    False -> scrolled(lines, total, first, last, height)
  }

  list.map(shown, fn(line) { line.line })
}

/// Computes scrolled window slice over list lines with boundary indicators.
fn scrolled(
  lines: List(ListLine),
  total: Int,
  first: Int,
  last: Int,
  height: Int,
) -> List(ListLine) {
  case last < height - 1, first >= total - { height - 1 } {
    // The top of the list holds the selection: only rows below are cut.
    True, _ -> {
      let shown = list.take(lines, height - 1)
      list.append(shown, [
        more(list.drop(lines, height - 1), shown, "↓", "below"),
      ])
    }

    // The end of the list holds the selection: only rows above are cut.
    False, True -> {
      let shown = list.drop(lines, total - { height - 1 })
      [
        more(list.take(lines, total - { height - 1 }), shown, "↑", "above"),
        ..shown
      ]
    }

    // The selection is in the middle: rows are cut on both sides.
    False, False -> {
      let start = last - { height - 2 } + 1
      let shown = lines |> list.drop(start) |> list.take(height - 2)
      let below = list.drop(lines, start + height - 2)
      [
        more(list.take(lines, start), shown, "↑", "above"),
        ..list.append(shown, [more(below, shown, "↓", "below")])
      ]
    }
  }
}

/// Formats hidden session counts when list overflows viewport.
fn more(
  hidden: List(ListLine),
  shown: List(ListLine),
  arrow: String,
  side: String,
) -> ListLine {
  let drawn =
    list.filter_map(shown, fn(line) { option.to_result(line.row, Nil) })
  let count =
    hidden
    |> list.filter_map(fn(line) { option.to_result(line.row, Nil) })
    |> list.unique
    |> list.filter(fn(index) { !list.contains(drawn, index) })
    |> list.length
  ListLine(
    None,
    span.line_new([
      span.span_styled(
        "  " <> arrow <> " " <> int.to_string(count) <> " more " <> side,
        theme.overlay_quiet(),
      ),
    ]),
  )
}

/// Formats header tab row displaying filter counts.
fn tabs_line(state: State, width: Int) -> span.Line {
  // Render tabs line based on collection state.
  case state.collection {
    Archived ->
      span.line_new([
        span.span_styled(
          text.truncate(
            " Archived sessions are restored before they can be opened.",
            width,
            "…",
          ),
          theme.overlay_quiet(),
        ),
      ])
    Active -> {
      let tabs =
        list.flat_map(counts(state), fn(pair) {
          let #(filter, count) = pair
          let label =
            " " <> filter_label(filter) <> " " <> int.to_string(count) <> " "

          // Style tab based on active selection and non-zero counts.
          let look = case filter == state.filter, filter, count {
            True, _, _ -> style.new(theme.paper, theme.raised, style.bold())
            False, NeedsYouSessions, count if count > 0 ->
              style.new(theme.danger, theme.graphite, style.none())
            False, _, _ -> theme.overlay_quiet()
          }

          [
            span.span_styled(label, look),
            span.span_styled(" ", theme.overlay_quiet()),
          ]
        })
      let hint = "Tab filter"
      let used =
        list.fold(tabs, 0, fn(total, tab) {
          total + text.cell_width(tab.content)
        })

      // Append hint span if width permits.
      let hint_spans = case used + text.cell_width(hint) + 1 <= width {
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

/// Formats display name for session list filter.
fn filter_label(filter: Filter) -> String {
  case filter {
    AllSessions -> "All"
    NeedsYouSessions -> "Needs you"
    WorkingSessions -> "Working"
    IdleSessions -> "Idle"
    InactiveSessions -> "Inactive"
  }
}

/// Formats right-hand detail pane lines for selected session.
fn detail_lines(
  state: State,
  row: protocol.Session,
  width: Int,
) -> List(span.Line) {
  let presence = presence(state, row)
  let activity = option.from_result(dict.get(state.activity, row.session_id))
  let tone = tone(presence, row.status)

  // The heading names the session as the design does, `loom · main`: its
  // workspace, then its name, on one line and cut with an ellipsis.
  let heading = [
    span.line_new([
      span.span_styled(
        cut(
          workspace_name(row.workspace)
            <> " · "
            <> text_hygiene.single_line(row.name),
          width,
        ),
        style.new(theme.paper, theme.graphite, style.bold()),
      ),
    ]),
  ]

  // Compose status line reason text.
  let reason = case reason(state, presence, row, activity) {
    "" -> ""
    reason -> " · " <> reason
  }

  let status = [
    span.line_new([
      span.span_styled(
        glyph(presence, row.status) <> " " <> state_word(presence, row.status),
        style.new(tone.0, theme.graphite, style.bold()),
      ),
      span.span_styled(
        text.truncate(
          reason,
          int.max(
            0,
            width - 2 - text.cell_width(state_word(presence, row.status)),
          ),
          "…",
        ),
        theme.overlay_quiet(),
      ),
    ]),
  ]

  // Extract last message section.
  let message = case activity {
    Some(protocol.Activity(last_message: Some(message), ..)) ->
      section(
        [label("LAST MESSAGE")],
        wrapped_at_most(message, 4, width, theme.overlay_plain()),
      )
    _ -> []
  }

  // Format strands section.
  let strands = case activity {
    Some(protocol.Activity(strands:, working:, glances:, ..)) if strands > 0 ->
      section(
        [
          label("STRANDS"),
          span.span_styled(
            " · "
              <> int.to_string(strands)
              <> case working {
              0 -> ""
              working -> ", " <> int.to_string(working) <> " working"
            },
            theme.overlay_quiet(),
          ),
        ],
        list.flat_map(glances, glance_lines(_, width)),
      )
    _ -> []
  }

  // Format model section.
  let model = case activity {
    Some(protocol.Activity(model: Some(model), ..)) ->
      table_row("MODEL", model, width, theme.overlay_plain())
    _ -> []
  }

  // Format session identifier string.
  let identity = case text.cell_width(row.session_id) <= width - 11 {
    True -> row.session_id
    False -> short_identity(row.session_id)
  }

  // A registered workspace is a name on an executor, so it gets that row and
  // its name as given, and is not shortened as a path would be.
  let located = case row.executor {
    Some(executor) ->
      list.flatten([
        table_row(
          "EXECUTOR",
          text.truncate(text_hygiene.single_line(executor), width - 11, "…"),
          width,
          theme.overlay_plain(),
        ),
        table_row(
          "WORKSPACE",
          text.truncate(
            text_hygiene.single_line(row.workspace),
            width - 11,
            "…",
          ),
          width,
          theme.overlay_plain(),
        ),
      ])
    None ->
      table_row(
        "WORKSPACE",
        fit_tail(home_relative(row.workspace), int.max(0, width - 11)),
        width,
        theme.overlay_plain(),
      )
  }

  let place =
    list.flatten([
      model,
      located,
      table_row("ID", identity, width, theme.overlay_quiet()),
    ])

  list.flatten([heading, status, message, strands, [span.line_new([]), ..place]])
}

/// Formats glance summary line for an active strand.
fn glance_lines(glance: protocol.GlanceLine, width: Int) -> List(span.Line) {
  // Prefer summary over title if present.
  let doing = case glance.summary {
    "" -> glance.title
    summary -> summary
  }

  [
    span.line_new([
      span.span_styled("· ", theme.overlay_quiet()),
      span.span_styled(
        text.truncate(
          agent_roster.short_name(text_hygiene.single_line(glance.strand)),
          int.max(0, width - 2),
          "…",
        ),
        theme.overlay_plain(),
      ),
    ]),
    span.line_new([
      span.span_styled(
        "    " <> cut(text_hygiene.single_line(doing), width - 4),
        theme.overlay_quiet(),
      ),
    ]),
  ]
}

// A dim bold label, the one style every pane heading and table key shares.
fn label(value: String) -> span.Span {
  span.span_styled(value, style.new(theme.quiet, theme.graphite, style.bold()))
}

fn section(heading: List(span.Span), body: List(span.Line)) -> List(span.Line) {
  [span.line_new([]), span.line_new(heading), ..body]
}

/// Formats a key-value row for the session details summary table.
fn table_row(
  key: String,
  value: String,
  width: Int,
  look: style.Style,
) -> List(span.Line) {
  [
    span.line_new([
      label(text.pad_right(key, 11)),
      span.span_styled(
        text.truncate(
          text_hygiene.single_line(value),
          int.max(0, width - 11),
          "…",
        ),
        look,
      ),
    ]),
  ]
}

/// Wraps text to target width up to a maximum number of rows.
fn wrapped_at_most(
  value: String,
  rows: Int,
  width: Int,
  look: style.Style,
) -> List(span.Line) {
  let lines = value |> text_hygiene.single_line |> text.wrap(int.max(1, width))

  // Truncate lines exceeding maximum row count.
  let kept = case list.drop(lines, rows) {
    [] -> lines
    [_, ..] ->
      list.append(list.take(lines, rows - 1), [
        cut(string.join(list.drop(lines, rows - 1), " "), width),
      ])
  }

  list.map(kept, fn(line) { span.line_new([span.span_styled(line, look)]) })
}

/// Formats integer count with singular or plural noun.
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

/// Truncates string keeping the tail graphemes up to target cell width.
fn fit_tail(value: String, width: Int) -> String {
  value
  |> text_hygiene.single_line
  |> string.reverse
  |> text.truncate(width, "…")
  |> string.reverse
}

/// Formats bottom key navigation hints for session selector.
fn help_lines(state: State, width: Int) -> List(span.Line) {
  // Format more pages indicator.
  let more = case state.page.after {
    Some(_) -> ["→ more"]
    None -> []
  }

  // Display context hints based on prompt status.
  case state.prompt {
    Browsing ->
      case state.collection {
        Active -> [
          hints(["↑↓ move", "Enter open", "Tab filter", "n new"], width),
          hints(
            list.flatten([
              ["l link", "r rename", "d archive", "a archived"],
              more,
              ["Esc close"],
            ]),
            width,
          ),
        ]
        Archived -> [
          hints(["↑↓ move", "Enter restore", "a active"], width),
          hints(
            list.flatten([["r rename", "d delete"], more, ["Esc close"]]),
            width,
          ),
        ]
      }

    LinkUnavailable -> [
      question("Open this saved session before linking it.", width),
      hints(["Esc back"], width),
    ]

    Renaming(_, draft) -> [
      question(
        "Name: " <> fit_tail(text_hygiene.single_line(draft) <> "▏", width - 6),
        width,
      ),
      hints(["Enter save", "Ctrl+U clear", "Esc cancel"], width),
    ]

    // The question names the session the way its row does, so the operator
    // can check it against the list; the answer keys get a row of their own
    // so a long name can never push them out of the frame.
    ConfirmingArchive(session_id) -> [
      question(
        "Stop and archive "
          <> named(state, session_id)
          <> "? Its history is kept.",
        width,
      ),
      hints(["y archive", "any other key keeps it"], width),
    ]

    ConfirmingDelete(session_id) -> [
      question(
        "Permanently delete " <> named(state, session_id) <> " and its history?",
        width,
      ),
      hints(["y delete", "any other key keeps it"], width),
    ]
  }
}

/// Formats session name with identity for confirmation prompts.
fn named(state: State, session_id: String) -> String {
  let identity = short_identity(text_hygiene.single_line(session_id))

  // Look up session row name from page.
  case
    list.find(state.page.sessions, fn(row) { row.session_id == session_id })
  {
    Ok(row) -> text_hygiene.single_line(row.name) <> " (" <> identity <> ")"
    Error(Nil) -> identity
  }
}

/// Joins keyboard shortcut hints into a formatted line.
fn hints(items: List(String), width: Int) -> span.Line {
  let joined =
    list.fold(items, "", fn(line, item) {
      // Append hint item with separator.
      let next = case line {
        "" -> item
        _ -> line <> " · " <> item
      }

      // Check whether hint fits within available width.
      case text.cell_width(next) <= width {
        True -> next
        False -> line
      }
    })
  span.line_new([span.span_styled(joined, theme.overlay_quiet())])
}

// The picker cuts text as every agent surface does, at a word with an
// ellipsis, or inside a last word too long to end before
// (`agent_row.cut`).
fn cut(value: String, width: Int) -> String {
  agent_row.cut(value, width)
}

fn question(value: String, width: Int) -> span.Line {
  span.line_new([
    span.span_styled(cut(value, width), theme.overlay_signal()),
  ])
}

/// Maps lifecycle state variant to display word.
fn lifecycle(status) {
  case status {
    protocol.Reserved -> "reserved"
    protocol.FailedStart(..) -> "failed to start"
    protocol.Saved -> "saved"
    protocol.Moving(to) -> "moving to " <> to
    protocol.Opening(_) -> "opening"
    protocol.Resident(_) -> "resident"
    protocol.Stopping(_) -> "stopping"
    protocol.RecoveryBlocked -> "recovery blocked"
  }
}
