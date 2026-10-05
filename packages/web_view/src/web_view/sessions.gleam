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
//// The list itself is read-only. A page is bound to one session by its key,
//// so opening another is a navigation to a new page, which only an operator's
//// page may ask for (protocol-change/051, the addendum on switching
//// sessions). This module holds the two types that request and its answer
//// are made of, `Answer` and `Reason`, with the fixed words for each refusal.
////
//// Grouping and ordering are a pure function of the entries, so a test can
//// state them without a page: `grouped` puts the workspace of the session
//// on screen first, then the workspaces by their newest session, and orders
//// the sessions of a workspace newest first. Recency is the catalogue's
//// creation time, which is all the catalogue records. The home page also shows
//// what each running session is doing (`Activity`), which the catalogue does
//// not record: the daemon asks the sessions themselves, off the page's runtime,
//// and hands over one state word for each.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option}
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

  /// The session is on disk, nothing runs it, and the daemon would open it on
  /// an operator's request.
  Saved

  /// The session is on disk, nothing runs it, and the daemon will not open it
  /// from a page: its creation was never reconciled, or recovery stopped it
  /// and needs the owner. A row for it is text at every ceiling and says
  /// "needs attention" with a fixed title, and the owner's fresh home draws
  /// Archive and Delete on it. An unreconciled creation holds no registry slot,
  /// so the registry takes both; a recovery that stopped does hold one, and the
  /// registry refuses it as busy.
  Blocked
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
    /// The first line of the first prompt a person sent the session, at most
    /// 60 characters, which the daemon derived once and never changes
    /// (protocol-change/067). It is a person's own words, so a page draws it as
    /// a text node and nowhere else: never an attribute, a class, a key or a
    /// title. A session with no prompt, or one older than the field, has none.
    subtitle: Option(String),
    /// The role the page's principal holds in this session, as the daemon's
    /// membership says. A member is an operator or an observer of each session
    /// it was invited to; the owner holds none, because it owns every session,
    /// and a read that finds no membership leaves it `None`. It is never
    /// something the page sent: the home's read fills it from the catalogue
    /// beside the session list.
    role: Option(Role),
  )
}

/// What a member may do in one session. It is the membership's own role, and
/// not the ceiling of the page, which caps every session at once.
pub type Role {
  /// The member may send prompts and answer approvals.
  Operates

  /// The member may only watch.
  Observes
}

/// The word the home's row says for a role.
///
/// ## Examples
///
/// ```gleam
/// assert sessions.role_words(sessions.Observes) == "observer"
/// ```
pub fn role_words(role: Role) -> String {
  case role {
    Operates -> "operator"
    Observes -> "observer"
  }
}

/// What the page calls an entry: its name, or, for a session with no name,
/// "Session " and the first eight characters of its identity. The sidebar and
/// a peer message's "Open" button use the same words, so a session is
/// called one thing on a page.
///
/// ## Examples
///
/// ```gleam
/// assert sessions.label(Entry("0198a2f4-7c3b", "", "/w", 0, Saved, None, None))
///   == "Session 0198a2f4"
/// ```
pub fn label(entry: Entry) -> String {
  case entry.name {
    "" -> "Session " <> string.slice(entry.id, 0, 8)
    named -> named
  }
}

/// What a running session is doing now, as the daemon's activity read
/// (protocol-change/050) says it. The read says more, and only this word
/// reaches the home page; a state the page does not know is no activity, and
/// the row says nothing about it.
pub type Activity {
  /// An escalation is pending, or the main strand's last run failed and it
  /// has nothing running: the session waits for its operator.
  NeedsYou

  /// A strand has a current operation.
  Working

  /// Nothing is pending and nothing is running.
  Idle
}

/// The activity a state word of the daemon's `sessions.activity` reply names,
/// or nothing for a word this page does not know, including `unknown`.
///
/// ## Examples
///
/// ```gleam
/// assert sessions.activity_of("needs_you") == Ok(sessions.NeedsYou)
/// assert sessions.activity_of("unknown") == Error(Nil)
/// ```
pub fn activity_of(state: String) -> Result(Activity, Nil) {
  case state {
    "needs_you" -> Ok(NeedsYou)
    "working" -> Ok(Working)
    "idle" -> Ok(Idle)
    _ -> Error(Nil)
  }
}

/// The words a row shows for an activity.
///
/// ## Examples
///
/// ```gleam
/// assert sessions.activity_words(sessions.NeedsYou) == "needs you"
/// ```
pub fn activity_words(activity: Activity) -> String {
  case activity {
    NeedsYou -> "needs you"
    Working -> "working"
    Idle -> "idle"
  }
}

/// How long ago `then` was, as `now` sees it, both in Unix milliseconds: "just
/// now" under a minute, then whole minutes, hours and days, and "over a month
/// ago" from thirty days, where the row's `title` has the exact UTC time. A `then` after `now`, as a clock that stepped back gives,
/// is "just now" too. The creation time the catalogue records is the only
/// instant a row has, so this is what "recent" means on the home page.
///
/// ## Examples
///
/// ```gleam
/// assert sessions.ago(7_300_000, 100_000) == "2h ago"
/// ```
pub fn ago(now: Int, then: Int) -> String {
  let seconds = int.max(now - then, 0) / 1000
  case seconds {
    _ if seconds < 60 -> "just now"
    _ if seconds < 3600 -> int.to_string(seconds / 60) <> "m ago"
    _ if seconds < 86_400 -> int.to_string(seconds / 3600) <> "h ago"
    _ if seconds < 2_592_000 -> int.to_string(seconds / 86_400) <> "d ago"
    _ -> "over a month ago"
  }
}

/// What the daemon answers when a page asks to open another session
/// (protocol-change/051, the addendum on switching sessions), to resume a saved
/// one or to go home (protocol-change/065, the second and third pull
/// requests).
pub type Answer {
  /// The daemon minted a ticket. `path` is the ticket's exchange,
  /// `/ui/sessions/<id>?ticket=<ticket>` or `/ui/home?ticket=<ticket>`, which
  /// the browser navigates to. The ticket is single use and lives 60 seconds.
  Ticketed(path: String)

  /// The daemon minted nothing. Every page shows the fixed words for the
  /// reason (`reason_words`) and never the daemon's own text.
  Declined(reason: Reason)
}

/// Why the daemon declined to mint a ticket.
pub type Reason {
  /// The principal holds no membership in that session, the identity is not a
  /// session's, or the page is an observer's, which may not switch. The
  /// answer is the same for each, so a page learns nothing about sessions it
  /// cannot open.
  NotHeld

  /// The principal holds the session but no process runs it, so a page
  /// opened for it would have nothing to show.
  NotRunning

  /// The daemon could not answer: it was starting, stopping or slow.
  Unavailable

  /// The principal holds the session, but only as an observer, so the daemon
  /// will not run it for them. The control command makes the same refusal
  /// (`OpenSession` needs Operator or Owner on the target), and the page's
  /// words are its, not a claim about the session.
  NotOperator

  /// The daemon tried to open a saved session and it did not become resident
  /// in time, or the registry refused the open (capacity, an archived or
  /// blocked session). The page says one thing for each, and no text from the
  /// open reaches it; the daemon logs the class.
  NotOpened

  /// The daemon could not mint a ticket for the home page: the page's own
  /// standing had ended or its credential no longer authenticates. It is the
  /// one reason a request to go home has, so it has its own words rather than
  /// the switch's, which speak of a session.
  NoHome

  /// The daemon could not mint a ticket for the admin page: the home page's own
  /// standing had ended, its credential no longer authenticates as the owner,
  /// or it was not a home an admin page may be opened from. One reason for all,
  /// so a page learns nothing about which (protocol-change/065, the fifth pull
  /// request).
  NoAdmin
}

/// The words a page shows for a declined switch. They are fixed here, one per
/// reason, so nothing the daemon or a session wrote reaches a browser.
///
/// ## Examples
///
/// ```gleam
/// assert sessions.reason_words(sessions.NotRunning)
///   == "That session is not running. Resume it from a terminal, then open it here."
/// ```
pub fn reason_words(reason: Reason) -> String {
  case reason {
    NotHeld -> "That session is not available to you."
    NotRunning ->
      "That session is not running. Resume it from a terminal, then open it here."
    Unavailable -> "The daemon could not open that session. Try again."
    NotOperator -> "Ask an operator to resume it."
    NotOpened -> "That session did not open. Resume it from a terminal."
    NoHome -> "The daemon could not open the home page. Try again."
    NoAdmin -> "The daemon could not open the admin page. Run loom ui again."
  }
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
