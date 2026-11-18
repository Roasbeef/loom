//// The rule that sorts the home page's running sessions into the attention
//// inbox: which group a session belongs to, what kind of thread it is, the
//// words of its one-line head, and whether the page lands on the inbox or on
//// the new-session form.
////
//// The module is pure. It imports no Lustre and reads no clock, so every
//// decision the inbox makes is a function of the activity reports the daemon
//// handed the page (`web_view/sessions.Report`), and a test can state the rule
//// without drawing a page. `web_view/view/inbox` draws what this module
//// decides and decides nothing itself.
////
//// Phase 0 knows only what a report says: an activity, the main strand's last
//// finished message and the strands' glances. It has no times, so no group is
//// ranked by age and no row prints one, and it has no asks, so a session whose
//// last words may be a question is not claimed to hold one. The `Waiting` group
//// is that stand-in: an idle session that said something when it stopped. The
//// page words it as the last thing said and never as a question.
////
//// Everything a report holds is untrusted model text except the activity,
//// which the daemon derives from the session's state. The rule only measures
//// and cuts that text, and the view draws it as text nodes.
////
//// ## Flow
////
//// `kind` → `group` → `grouped` → `selection` → `head`
////
//// 1. `kind` reads one report's activity and last message, and `words` says it.
//// 2. `group` places a kind in one of four groups, and `grouped` collects
////    threads into the groups, each ordered by session name.
//// 3. `selection` names the thread the reading pane shows, and `head` words a
////    thread's one line.
//// 4. `landing` and `headline` summarise every report the page holds.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import web_view/sessions.{type Report}

/// The longest head, in graphemes, including the ellipsis a cut head ends in.
pub const head_graphemes = 120

/// The four groups the inbox lists, in the order it draws them.
pub type Group {
  /// A session that is blocked on the owner: an approval is pending, or its
  /// last run failed and only the owner can fix the cause.
  NeedsYou

  /// An idle session that said something when it stopped. Phase 0 cannot tell
  /// a question from a report, so the group is worded as "waiting" and the
  /// message as the last thing said.
  Waiting

  /// A session that is working now.
  Updates

  /// An idle session that has said nothing: nothing to read, nothing to do.
  Quiet
}

/// What a session's thread is about, derived from its report. The words are
/// what the row's eyebrow and the reading pane's eyebrow say.
pub type Kind {
  /// An approval is pending. The page says so and sends the owner to the
  /// session's own page, where the decision is made.
  ApprovalPending

  /// The main strand's last run failed and nothing is running or pending.
  Failed

  /// Idle with a last message.
  Idle

  /// Working now.
  Working

  /// Idle with nothing said.
  Settled
}

/// Where the page lands: the inbox when something waits or runs, and the
/// new-session form otherwise.
pub type Landing {
  /// Something needs the owner, waits on the owner's reading, or runs.
  Inbox

  /// Every running session is quiet, or none runs: the owner came to start one.
  Form
}

/// One session as the inbox draws it: the catalogue's identity and display
/// name beside the daemon's report. The name is the catalogue's, written by
/// the owner, and orders the thread within its group.
pub type Thread {
  Thread(
    /// The session's identity, which the row's press opens.
    id: String,
    /// The display name the page shows, as `sessions.label` words it.
    name: String,
    /// The catalogue's workspace for the session, or empty when it has none:
    /// the host's own text, a path or an executor's registered name.
    workspace: String,
    /// What the daemon's activity read said of the session.
    report: Report,
  )
}

/// The kind of thread a report makes. `NeedsYou` means an approval is pending
/// (`sessions.activity_from` turns a failed run into `Failed`), and a message
/// that is only whitespace is no message.
///
/// ## Examples
///
/// ```gleam
/// let report = sessions.Report(sessions.Idle, option.Some("Done."), [])
/// assert inbox_rule.kind(report) == inbox_rule.Idle
/// ```
pub fn kind(report: Report) -> Kind {
  case report.activity {
    sessions.NeedsYou -> ApprovalPending
    sessions.Failed -> Failed
    sessions.Working -> Working
    sessions.Idle ->
      case said(report) {
        Some(_) -> Idle
        None -> Settled
      }
  }
}

/// The words of a kind: `Approval`, `Failed`, `Waiting`, `Update` or `Quiet`.
///
/// ## Examples
///
/// ```gleam
/// assert inbox_rule.words(inbox_rule.ApprovalPending) == "Approval"
/// ```
pub fn words(kind: Kind) -> String {
  case kind {
    ApprovalPending -> "Approval"
    Failed -> "Failed"
    Idle -> "Waiting"
    Working -> "Update"
    Settled -> "Quiet"
  }
}

/// The group a report belongs to.
///
/// ## Examples
///
/// ```gleam
/// let report = sessions.Report(sessions.Working, option.None, [])
/// assert inbox_rule.group(report) == inbox_rule.Updates
/// ```
pub fn group(report: Report) -> Group {
  case kind(report) {
    ApprovalPending | Failed -> NeedsYou
    Idle -> Waiting
    Working -> Updates
    Settled -> Quiet
  }
}

/// The heading a group is drawn under.
///
/// ## Examples
///
/// ```gleam
/// assert inbox_rule.group_words(inbox_rule.NeedsYou) == "Needs you"
/// ```
pub fn group_words(group: Group) -> String {
  case group {
    NeedsYou -> "Needs you"
    Waiting -> "Waiting"
    Updates -> "Updates"
    Quiet -> "Quiet"
  }
}

/// Where the page lands for these reports: the inbox when any session needs the
/// owner, failed, works, or is idle with something said, and the form when
/// every report is quiet or there are none.
///
/// ## Examples
///
/// ```gleam
/// assert inbox_rule.landing([]) == inbox_rule.Form
/// ```
pub fn landing(reports: List(Report)) -> Landing {
  case list.any(reports, fn(report) { group(report) != Quiet }) {
    True -> Inbox
    False -> Form
  }
}

/// The threads collected into the groups that hold any, in the order the inbox
/// draws them. A thread is placed by its report, and the threads of a group are
/// ordered by session name and then by identity, because phase 0 has no times
/// to rank by and the order must not move between two reads of the same
/// reports.
///
/// ## Examples
///
/// ```gleam
/// assert inbox_rule.grouped([]) == []
/// ```
pub fn grouped(threads: List(Thread)) -> List(#(Group, List(Thread))) {
  [NeedsYou, Waiting, Updates, Quiet]
  |> list.filter_map(fn(wanted) {
    let members =
      threads
      |> list.filter(fn(thread) { group(thread.report) == wanted })
      |> list.sort(by_name)

    // A group with no thread is not listed, so the page draws no empty header.
    case members {
      [] -> Error(Nil)
      [_, ..] -> Ok(#(wanted, members))
    }
  })
}

/// The identity of the thread the reading pane shows: the chosen one when the
/// groups hold it, and otherwise the first thread of the first group. A choice
/// of a session that is no longer listed falls back to the first thread, so a
/// stale selection never leaves the pane empty while threads exist.
///
/// ## Examples
///
/// ```gleam
/// assert inbox_rule.selection([], None) == None
/// ```
pub fn selection(
  groups: List(#(Group, List(Thread))),
  chosen: Option(String),
) -> Option(String) {
  let threads = list.flat_map(groups, fn(entry) { entry.1 })

  let listed =
    option.map(chosen, fn(id) {
      list.any(threads, fn(thread) { thread.id == id })
    })

  // A choice the groups still hold stands, and any other falls back to the
  // first thread, so a stale choice never leaves the pane empty.
  case listed {
    Some(True) -> chosen
    Some(False) | None -> first_of(threads)
  }
}

/// A thread's one-line head: the first line of the last message with any
/// words, else the newest glance's summary, else the words of its kind. The
/// line is cut to `head_graphemes` graphemes on a grapheme boundary, and a cut
/// line ends in an ellipsis within that count, so a combined character is
/// never split.
///
/// ## Examples
///
/// ```gleam
/// let report = sessions.Report(sessions.Idle, option.Some("Done.\nMore."), [])
/// assert inbox_rule.head(report) == "Done."
/// ```
pub fn head(report: Report) -> String {
  // The message's words come first, then what a strand says it is doing, and
  // the kind's own words when neither says anything.
  let line = case first_line(report) {
    Some(line) -> line
    None ->
      case newest_summary(report) {
        Some(summary) -> summary
        None -> words(kind(report))
      }
  }

  cut(line)
}

/// The headline over the list: how many sessions need the owner, and what the
/// count read. `running` is how many running sessions the page lists and
/// `reports` is what the daemon answered for, which may be fewer, since the read
/// has a deadline and a bound. Saved sessions are never read, and the line says
/// so, so no count claims more than it looked at.
///
/// ## Examples
///
/// ```gleam
/// assert inbox_rule.headline([], 0)
///   == "Nothing needs you · in 0 running sessions; saved sessions not checked"
/// ```
pub fn headline(reports: List(Report), running: Int) -> String {
  let needing = list.count(reports, fn(report) { group(report) == NeedsYou })
  let answered = list.length(reports)

  // The count is worded for one and for many, and for none.
  let first = case needing {
    0 -> "Nothing needs you"
    1 -> "1 needs you"
    many -> int.to_string(many) <> " need you"
  }

  // The line says how many sessions answered only when some did not, so a
  // count never claims more than the daemon read.
  let read = case answered < running {
    True -> ", " <> int.to_string(answered) <> " answered"
    False -> ""
  }

  first
  <> " · in "
  <> int.to_string(running)
  <> case running {
    1 -> " running session"
    _ -> " running sessions"
  }
  <> read
  <> "; saved sessions not checked"
}

/// The last message when it has any words in it, so a message of whitespace is
/// no message and the session is not offered as having said something.
fn said(report: Report) -> Option(String) {
  case report.last_message {
    Some(text) ->
      case string.trim(text) {
        "" -> None
        _ -> Some(text)
      }
    None -> None
  }
}

/// The first line of the message that has words in it, trimmed.
fn first_line(report: Report) -> Option(String) {
  case said(report) {
    Some(text) ->
      string.split(text, "\n")
      |> list.map(string.trim)
      |> list.find(fn(line) { line != "" })
      |> option.from_result
    None -> None
  }
}

/// The newest glance's summary, when the glances are newest first (as the daemon
/// writes them) and that one says something.
fn newest_summary(report: Report) -> Option(String) {
  case report.glances {
    [newest, ..] ->
      case string.trim(newest.summary) {
        "" -> None
        summary -> Some(summary)
      }
    [] -> None
  }
}

/// Cuts a line to `head_graphemes`, ending in an ellipsis inside the count.
fn cut(line: String) -> String {
  let graphemes = string.to_graphemes(line)

  // A line within the cap is untouched, and a longer one loses its tail.
  case list.drop(graphemes, head_graphemes) {
    [_, ..] ->
      graphemes
      |> list.take(head_graphemes - 1)
      |> string.concat
      |> string.append("…")
    [] -> line
  }
}

/// Orders threads by name, and a tie by identity, so two reads of the same
/// reports list the same order.
fn by_name(left: Thread, right: Thread) -> order.Order {
  case string.compare(left.name, right.name) {
    order.Eq -> string.compare(left.id, right.id)
    order.Lt -> order.Lt
    order.Gt -> order.Gt
  }
}

/// The identity of the first thread, or nothing when there is none.
fn first_of(threads: List(Thread)) -> Option(String) {
  case threads {
    [thread, ..] -> Some(thread.id)
    [] -> None
  }
}
