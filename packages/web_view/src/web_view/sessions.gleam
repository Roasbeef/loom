//// The sessions a page's principal may see, as the operator's session
//// sidebar lists them: what the daemon's catalogue says about each, and how they are
//// grouped and ordered for a reader.
////
//// The list is the catalogue's and not the session's. The daemon reads it
//// through the same authorized read a terminal's session picker uses, with
//// the page's own credential digest, so a member sees only the sessions they
//// hold a membership in and a revoked credential sees none
//// (`client/daemon/ui_socket`, `manager.authorized_page`). Every field here
//// was written by the owner or the host when the session was created, and
//// none by a session's agent, so a name is drawn as a text node and needs no
//// stricter handling than the heading's own.
////
//// The list is read-only. A page is bound to one session by its key, so the
//// sidebar names the principal's other sessions and cannot open one
//// (protocol-change/051, the addendum on the session sidebar, says what
//// opening one would take).
////
//// Grouping and ordering are a pure function of the entries, so a test can
//// state them without a page: `grouped` puts the workspace of the session
//// on screen first, then the workspaces by their newest session, and orders
//// the sessions of a workspace newest first. Recency is the catalogue's
//// creation time, which is all the catalogue records; the daemon's activity
//// read is an owner's control command that a page does not make.

import gleam/dict
import gleam/int
import gleam/list
import gleam/order
import gleam/string

/// The most sessions a page lists: the catalogue's first page, which is
/// its `page_limit`. A principal with more sees the first hundred by
/// identity, and the list says nothing of the rest.
pub const listed_limit = 100

/// Whether a session has a running process behind it, which is the one live
/// fact the catalogue read carries.
pub type Residency {
  /// The daemon holds the session open, or is opening or closing it.
  Live

  /// The session is on disk and nothing runs it.
  Saved
}

/// One session in the sidebar.
pub type Entry {
  Entry(
    /// The canonical session identity. It marks the session on screen and
    /// names an unnamed session by its first eight characters; it is never
    /// an attribute of the page.
    id: String,
    /// The session's display name, which may be empty.
    name: String,
    /// The canonical working directory the session runs in.
    workspace: String,
    /// Creation time in Unix milliseconds.
    created_at: Int,
    /// Whether a process runs the session.
    residency: Residency,
  )
}

/// The sessions of one workspace, newest first.
pub type Group {
  Group(
    /// The canonical working directory the sessions share.
    workspace: String,
    /// The workspace's sessions in the order the sidebar draws them.
    entries: List(Entry),
  )
}

/// The entries grouped by workspace and ordered for the sidebar.
///
/// The group holding the session named `current` comes first, so the reader
/// finds the session they are in without scrolling; the other groups follow
/// by their newest session, newest first, and a tie is broken by the
/// workspace path so the order never depends on the daemon's. Within a group
/// the sessions run newest first, a tie broken by identity.
///
/// ## Examples
///
/// ```gleam
/// assert sessions.grouped([], "a") == []
/// ```
pub fn grouped(entries: List(Entry), current: String) -> List(Group) {
  entries
  |> list.group(fn(entry) { entry.workspace })
  |> dict_to_groups
  |> list.sort(fn(left, right) { by_group(left, right, current) })
}

// The groups of a grouping, each with its entries newest first.
fn dict_to_groups(grouping: dict.Dict(String, List(Entry))) -> List(Group) {
  dict.to_list(grouping)
  |> list.map(fn(pair) {
    Group(workspace: pair.0, entries: list.sort(pair.1, by_recency))
  })
}

// Newest first, and by identity when two were created in the same
// millisecond.
fn by_recency(left: Entry, right: Entry) -> order.Order {
  case int.compare(right.created_at, left.created_at) {
    order.Eq -> string.compare(left.id, right.id)
    other -> other
  }
}

// The current session's group first, then the newest group first.
fn by_group(left: Group, right: Group, current: String) -> order.Order {
  case holds(left, current), holds(right, current) {
    True, False -> order.Lt
    False, True -> order.Gt
    True, True | False, False ->
      case int.compare(newest(right), newest(left)) {
        order.Eq -> string.compare(left.workspace, right.workspace)
        other -> other
      }
  }
}

fn holds(group: Group, current: String) -> Bool {
  list.any(group.entries, fn(entry) { entry.id == current })
}

// A group's newest creation time.
fn newest(group: Group) -> Int {
  list.fold(group.entries, 0, fn(latest, entry) {
    int.max(latest, entry.created_at)
  })
}
