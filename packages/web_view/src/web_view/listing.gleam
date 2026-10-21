//// How the sidebar lists sessions: by what each needs from the person, with
//// a plain tag saying where its agent runs and where its code lives, and a
//// filter by machine (the placement revamp,
//// [`docs/design-notes/placement-revamp.md`](../../../../docs/design-notes/placement-revamp.md)).
////
//// The catalogue's rows say where a session's workspace is: a directory on the
//// daemon's own host, or a name registered on an executor. They do not say
//// what the session is doing; the activity read does, for the running ones. This
//// module joins the two into the three questions a returning person asks:
//// which sessions are waiting on me, which are working, and which are quiet.
//// A session nothing runs is a fourth, folded group, because there is nothing
//// to do for it but resume it.
////
//// Each row also carries a `Place`: the machine that runs the agent and the
//// code it works on. In this slice the agent is always the daemon serving the
//// page, because a page can only create and open sessions on its own daemon,
//// so a row's tag reads `laptop → exec · repo` or `laptop → …/roasbeef/weft`.
//// The agent field is kept anyway, so the day a page can list another
//// orchestrator's sessions only this module's `place` learns it.
////
//// A filter names one machine. A row matches it when its agent or its code is on
//// that machine, so a pill never hides a session that touches the machine. The
//// session on screen is never filtered out: a person should always see where
//// they are. The pills offered are the machines the rows actually use, and the
//// daemon's own is left out when it would match every row, since "All" already
//// says so.
////
//// Nothing here is drawn, and every string is the catalogue's or the
//// operator's configuration, to be drawn as a text node by the view. The one
//// function that builds a class is `bucket_class`, which maps a closed type to
//// complete literals.
////
//// ## Examples
////
//// ```gleam
//// let rows = listing.sorted(entries, activity, "laptop", listing.Everywhere)
//// assert rows.needs == []
//// ```

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/string
import web_view/sessions.{type Activity, type Entry, type Group}

/// How many quiet sessions the list shows before it folds the rest behind
/// "Show more". A person returns for what needs them or is working, so the quiet
/// ones are the tail.
pub const idle_shown = 5

/// Which machine the list is narrowed to.
pub type Filter {
  /// Every session.
  Everywhere

  /// The sessions whose agent or code is on this machine. The name is one the
  /// page drew a pill for; `chosen` is the one place a browser's choice becomes
  /// a `Filter`, and it admits only a drawn name.
  On(
    /// The machine's name: the daemon's own, or an executor's key.
    machine: String,
  )
}

/// Where the code of a session lives.
pub type Code {
  /// A directory on the machine the agent runs on.
  Folder(
    /// The canonical directory, written by the host.
    path: String,
  )

  /// A workspace registered on an executor. The name is not a path.
  Registered(
    /// The executor's `[executors.<name>]` key.
    executor: String,
    /// The workspace's registered name.
    workspace: String,
  )
}

/// Where a session's agent runs and where its code lives.
pub type Place {
  Place(
    /// The machine that runs the agent loop.
    agent: String,
    /// The code the agent works on.
    code: Code,
  )
}

/// What a session needs from the person right now.
pub type Bucket {
  /// An approval waits on the person.
  NeedsYou

  /// A strand is running an operation.
  Working

  /// Running, and nothing is pending. A run that failed is here too, with its own
  /// colour, since nothing waits on the person but a new message.
  Idle

  /// Nothing runs it. Saved, blocked, failed to start, or moving.
  Saved
}

/// One row of the list: the catalogue's entry, what it needs and where it is.
pub type Row {
  Row(
    /// The catalogue's entry, drawn as text by the view.
    entry: Entry,
    /// The group the row sits in.
    bucket: Bucket,
    /// The tag's two halves.
    place: Place,
  )
}

/// The rows of the list, by group, each newest first.
pub type Rows {
  Rows(
    /// Sessions waiting on an approval.
    needs: List(Row),
    /// Sessions running an operation.
    working: List(Row),
    /// Running sessions with nothing pending, and sessions whose run failed.
    idle: List(Row),
    /// Sessions nothing runs.
    saved: List(Row),
  )
}

/// One machine filter pill.
pub type Pill {
  Pill(
    /// The machine's name.
    machine: String,
    /// How many sessions the filter would show.
    count: Int,
  )
}

/// The entries of the page's groups as one list, newest first, ties by
/// identity, which is the order the groups keep inside each project.
///
/// ## Examples
///
/// ```gleam
/// assert listing.entries([]) == []
/// ```
pub fn entries(groups: List(Group)) -> List(Entry) {
  groups
  |> list.flat_map(fn(group) { group.entries })
  |> list.sort(by_recency)
}

/// Where an entry's agent and code are, for a page served by `machine`.
///
/// ## Examples
///
/// ```gleam
/// let entry = sessions.Entry("a", "", "repo", 0, sessions.Saved, None, None, None, Some("exec"))
/// assert listing.place(entry, "laptop")
///   == listing.Place("laptop", listing.Registered("exec", "repo"))
/// ```
pub fn place(entry: Entry, machine: String) -> Place {
  case entry.executor {
    Some(executor) ->
      Place(machine, Registered(executor, workspace: entry.workspace))
    None -> Place(machine, Folder(entry.workspace))
  }
}

/// The words for where the code is: a folder as its last two directories
/// behind an ellipsis, a registered workspace as `executor · name`.
///
/// ## Examples
///
/// ```gleam
/// assert listing.code_words(listing.Folder("/Users/a/src/loom")) == "…/src/loom"
/// assert listing.code_words(listing.Registered("exec", "repo")) == "exec · repo"
/// ```
pub fn code_words(code: Code) -> String {
  case code {
    Folder(path:) -> short_path(path)
    Registered(executor:, workspace:) -> executor <> " · " <> workspace
  }
}

/// The words for where an entry's code is. A session in a git worktree names the
/// repository and the worktree (`btcd · hungry-euclid`), since the last two
/// directories of a worktree's path are `worktrees/<name>` and say nothing of the
/// repository; every other place is `code_words`.
///
/// ## Examples
///
/// ```gleam
/// let entry = sessions.Entry("a", "", "/w/.claude/worktrees/x", 0, sessions.Saved, None, None, Some("/w"), None)
/// assert listing.entry_words(entry, listing.place(entry, "laptop")) == "w · x"
/// ```
pub fn entry_words(entry: Entry, place: Place) -> String {
  case place.code, sessions.worktree(entry) {
    Folder(_), Some(directory) ->
      sessions.base_name(sessions.project_of(entry)) <> " · " <> directory
    Folder(_), None | Registered(..), _ -> code_words(place.code)
  }
}

/// A path as its last two directories behind an ellipsis, or the path itself
/// when it has no more than two.
///
/// ## Examples
///
/// ```gleam
/// assert listing.short_path("/a/b/c") == "…/b/c"
/// assert listing.short_path("/a/b") == "/a/b"
/// ```
pub fn short_path(path: String) -> String {
  let segments =
    string.split(path, "/")
    |> list.filter(fn(segment) { segment != "" })

  case list.length(segments) > 2 {
    True ->
      "…/" <> string.join(list.drop(segments, list.length(segments) - 2), "/")
    False -> path
  }
}

/// The machine a place's code is on: the agent's own for a folder, the executor
/// for a registered workspace.
///
/// ## Examples
///
/// ```gleam
/// assert listing.code_machine(listing.Place("laptop", listing.Folder("/w"))) == "laptop"
/// ```
pub fn code_machine(place: Place) -> String {
  case place.code {
    Folder(_) -> place.agent
    Registered(executor:, ..) -> executor
  }
}

/// Whether a row's agent or code is on the machine the filter names.
///
/// ## Examples
///
/// ```gleam
/// let place = listing.Place("laptop", listing.Registered("exec", "repo"))
/// assert listing.matches(place, listing.On("exec"))
/// assert !listing.matches(place, listing.On("box"))
/// ```
pub fn matches(place: Place, filter: Filter) -> Bool {
  case filter {
    Everywhere -> True
    On(machine:) -> place.agent == machine || code_machine(place) == machine
  }
}

/// What a session needs, from its residency and what the activity read said of
/// it. A running session the read has not named is idle until it does, so a row
/// never claims work it has no evidence of.
///
/// ## Examples
///
/// ```gleam
/// let entry = sessions.Entry("a", "", "/w", 0, sessions.Live, None, None, None, None)
/// assert listing.bucket(entry, dict.from_list([#("a", sessions.NeedsYou)])) == listing.NeedsYou
/// ```
pub fn bucket(entry: Entry, activity: Dict(String, Activity)) -> Bucket {
  case entry.residency, dict.get(activity, entry.id) {
    sessions.Live, Ok(sessions.NeedsYou) -> NeedsYou
    sessions.Live, Ok(sessions.Working) -> Working
    sessions.Live, Ok(sessions.Idle) -> Idle
    sessions.Live, Ok(sessions.Failed) -> Idle
    sessions.Live, Error(Nil) -> Idle
    sessions.Saved, _
    | sessions.Blocked, _
    | sessions.FailedStart(_), _
    | sessions.Moving(_), _
    -> Saved
  }
}

/// The class a bucket gives a row's dot: complete literals, so the stylesheet
/// finds them.
///
/// ## Examples
///
/// ```gleam
/// assert listing.bucket_class(listing.NeedsYou) == "needs-you"
/// ```
pub fn bucket_class(bucket: Bucket) -> String {
  case bucket {
    NeedsYou -> "needs-you"
    Working -> "working"
    Idle -> "idle"
    Saved -> "saved"
  }
}

/// The rows the list shows: every entry that matches the filter, plus the
/// session on screen (`current`) whatever the filter says, placed in its group.
///
/// ## Examples
///
/// ```gleam
/// let rows = listing.sorted([], dict.new(), "laptop", listing.Everywhere, "")
/// assert rows.working == []
/// ```
pub fn sorted(
  all: List(Entry),
  activity: Dict(String, Activity),
  machine: String,
  filter: Filter,
  current: String,
) -> Rows {
  let rows =
    list.filter_map(all, fn(entry) {
      let place = place(entry, machine)
      case matches(place, filter) || entry.id == current {
        True ->
          Ok(Row(entry:, bucket: placed(entry, activity, current), place:))
        False -> Error(Nil)
      }
    })

  Rows(
    needs: in_bucket(rows, NeedsYou),
    working: in_bucket(rows, Working),
    idle: in_bucket(rows, Idle),
    saved: in_bucket(rows, Saved),
  )
}

/// The pills the list offers: one for each executor some session uses, in
/// name order, and the daemon's own only when it would not match every row.
/// With nothing to tell apart there is no pill at all.
///
/// ## Examples
///
/// ```gleam
/// assert listing.pills([], "laptop") == []
/// ```
pub fn pills(all: List(Entry), machine: String) -> List(Pill) {
  let places = list.map(all, place(_, machine))
  let machines =
    places
    |> list.flat_map(fn(place) { [place.agent, code_machine(place)] })
    |> list.unique
    |> list.sort(string.compare)
  let counted =
    list.map(machines, fn(name) {
      Pill(
        machine: name,
        count: list.count(places, fn(place) { matches(place, On(name)) }),
      )
    })

  // A pill that matches every row says what "All" says.
  list.filter(counted, fn(pill) { pill.count < list.length(all) })
}

/// A filter from the name a pill was drawn with, or none when no such pill is
/// offered. The page calls it with the machine a click's message carries, so a
/// forged name never becomes a filter.
///
/// ## Examples
///
/// ```gleam
/// assert listing.chosen([], "laptop", "box") == Error(Nil)
/// ```
pub fn chosen(
  all: List(Entry),
  machine: String,
  name: String,
) -> Result(Filter, Nil) {
  pills(all, machine)
  |> list.find(fn(pill) { pill.machine == name })
  |> result.map(fn(pill) { On(pill.machine) })
}

/// The sessions waiting on an approval, newest first. The phone's menu button
/// counts them and its banner names the first.
///
/// ## Examples
///
/// ```gleam
/// assert listing.waiting([], dict.new()) == []
/// ```
pub fn waiting(
  all: List(Entry),
  activity: Dict(String, Activity),
) -> List(Entry) {
  list.filter(all, fn(entry) { bucket(entry, activity) == NeedsYou })
}

/// The count of rows in the group, as text.
///
/// ## Examples
///
/// ```gleam
/// assert listing.count_words([]) == "0"
/// ```
pub fn count_words(rows: List(Row)) -> String {
  int.to_string(list.length(rows))
}

// The group an entry is listed in. The session on screen is always among the
// running ones, saved or not, so the person sees where they are; its own row still
// says "saved".
fn placed(
  entry: Entry,
  activity: Dict(String, Activity),
  current: String,
) -> Bucket {
  case bucket(entry, activity), entry.id == current {
    Saved, True -> Idle
    other, _ -> other
  }
}

// The rows of one group, in the order they arrived, which is newest first.
fn in_bucket(rows: List(Row), wanted: Bucket) -> List(Row) {
  list.filter(rows, fn(row) { row.bucket == wanted })
}

// Newest first, and by identity when two were created in the same millisecond,
// as the groups order their own.
fn by_recency(left: Entry, right: Entry) -> order.Order {
  case int.compare(right.created_at, left.created_at) {
    order.Eq -> string.compare(left.id, right.id)
    other -> other
  }
}
