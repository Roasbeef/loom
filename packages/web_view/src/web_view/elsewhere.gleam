//// What the owner's home knows of the sessions on its other orchestrators
//// (protocol-change/085, the `sessions.elsewhere` command).
////
//// A session lives on the orchestrator that created it, and the home lists only
//// the one it is served by. The daemon asks its other orchestrators for a page
//// of what each would list, and hands this package the answer in the words
//// below: for each configured orchestrator, the rows it listed or the fact that
//// it did not answer. The page draws them in a group of their own
//// (`view/elsewhere`) and can open one row's detail, which words the launch that
//// reaches the session on the machine that has it.
////
//// ## What the page is never given
////
//// A group carries the configuration key of the orchestrator, its control
//// address if the configuration has one, and rows. A row names the node of the
//// executor its session is placed on, which the Admin page matches against its
//// machines and the home never draws. A group carries no credential and no pin,
//// and the daemon dials nothing the page names. Every text here is a
//// configuration key, an address or a catalogue field of another daemon, so a
//// page draws it as a text node and builds no class, attribute or key from it.
//// The row's state is a closed type, drawn from its fixed word.
////
//// ## Silence is not an empty group
////
//// A group is `Answered` with its rows, or `Silent`. Silent means the daemon did
//// not hear a page from that orchestrator, and the page says so in one line.
//// An answered group with no rows says it lists none. The two are never merged,
//// because "nothing there" and "could not ask" send a person to different
//// places.
////
//// ## Flow
////
//// `append` → `launch` → `word`
////
//// 1. `append` joins the page a "Show more" asked for onto the rows a group
////    already holds, and stops at the most rows a group may hold so a page that is asked again and
////    again does not grow without bound.
//// 2. `launch` is the command that reaches one row's session.
//// 3. `word` is the fixed word for a row's state.

import gleam/list
import gleam/option.{type Option}
import session_view/launch_words

/// The most rows the page keeps for one group, however many pages were asked.
pub const max_rows = 100

/// The state of a session on its own orchestrator, as that orchestrator lists
/// it. The words are `sessions.list`'s.
pub type Status {
  /// A creation reserved the identity and was never reconciled.
  Reserved

  /// No runtime is held for it.
  Saved

  /// A runtime is being built for it.
  Opening

  /// It is running.
  Resident

  /// Its runtime is being cleaned up.
  Stopping

  /// Cleanup failed and the slot stays reserved.
  Blocked
}

/// One session another orchestrator lists.
pub type Row {
  Row(
    /// The canonical session identity.
    session_id: String,
    /// The workspace, as that orchestrator names it.
    workspace: String,
    /// The display name.
    name: String,
    /// Where the session is in its life on that orchestrator.
    status: Status,
    /// The key of the executor that orchestrator placed the session on, when it
    /// is placed on one.
    executor: Option(String),
    /// The node of that executor, as the orchestrator names it. The Admin page
    /// attributes a row to a machine by it, because two orchestrators may key
    /// the same executor differently.
    executor_node: Option(String),
  )
}

/// Whether the orchestrator has rows beyond the ones the page holds.
pub type More {
  /// The page holds every row there is.
  Last

  /// Rows follow, and the next page begins after the last one held.
  Further
}

/// What the daemon heard from one orchestrator.
pub type Hearing {
  /// A page arrived, possibly with no rows on it.
  Answered(rows: List(Row), more: More)

  /// Nothing arrived in time, or the orchestrator could not read its catalogue.
  Silent
}

/// One configured orchestrator and what it said.
pub type Group {
  Group(
    /// The orchestrator's key in the daemon's configuration.
    name: String,
    /// The control address the configuration gives it, if it gives one.
    address: Option(String),
    /// What it said.
    hearing: Hearing,
  )
}

/// What one read of the other orchestrators gave.
pub type Read {
  /// The groups, in the order the daemon's configuration lists them.
  Heard(groups: List(Group))

  /// The daemon could not ask. The page keeps what it has and says nothing.
  Unread
}

/// Joins a group's next page onto the group the page holds. A page that is
/// `Silent` leaves the group as it was, since a failed ask taught the page
/// nothing about what follows, and a group that was silent takes the page as it
/// is. The rows are kept to `max_rows`; a group cut there reads as `Last`, so
/// the page offers no further press.
///
/// ## Examples
///
/// ```gleam
/// assert elsewhere.append(held, elsewhere.Silent) == held
/// ```
pub fn append(held: Hearing, next: Hearing) -> Hearing {
  case held, next {
    Answered(rows: before, ..), Answered(rows: after, more:) -> {
      let rows = list.append(before, after)
      case list.length(rows) >= max_rows {
        True -> Answered(rows: list.take(rows, max_rows), more: Last)
        False -> Answered(rows:, more:)
      }
    }
    Answered(..), Silent -> held
    Silent, Answered(..) -> next
    Silent, Silent -> Silent
  }
}

/// The command that reaches a row's session on the orchestrator that has it,
/// in the words the terminal uses for the same thing.
///
/// ## Examples
///
/// ```gleam
/// // elsewhere.launch(group, row)
/// ```
pub fn launch(group: Group, row: Row) -> String {
  launch_words.launch_line(group.address, row.session_id)
}

/// The fixed word for a row's state.
///
/// ## Examples
///
/// ```gleam
/// assert elsewhere.word(elsewhere.Resident) == "running"
/// ```
pub fn word(status: Status) -> String {
  case status {
    Reserved -> "reserved"
    Saved -> "saved"
    Opening -> "opening"
    Resident -> "running"
    Stopping -> "stopping"
    Blocked -> "blocked"
  }
}
