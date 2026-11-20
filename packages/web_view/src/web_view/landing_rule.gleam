//// The first round of reads that decides which centre the home page opens on.
////
//// The page asks the daemon several independent questions after it loads: the
//// session list, what the running sessions are doing, what the saved sessions
//// hold, the projects' boards and the feed of open asks and finds. Each is its
//// own daemon task, so the order they answer in is not the page's to choose.
//// A centre decided on the first answer would depend on that order: a quiet
//// running session whose activity read arrived first would land the new-session
//// form over a saved session with an approval pending, and the person would
//// see the inbox only if the summary happened to come first.
////
//// The module removes the order from the decision. The page keeps a `Round`,
//// which records for each first read whether it is still `Due`, has
//// `Answered` or was never due (`NotDue`). The centre is decided when the last
//// due read answers, once, from everything the round gathered (`landing`). Any
//// kind of answer counts, since the page cannot wait for a read that failed:
//// an unreadable, overtaken or empty answer marks its read `Answered` as a
//// good one does. A read may wait up to the timeouts of the daemon calls it
//// makes. A task that crashes delivers nothing, so its read stays due until
//// the next readable list, which is read every refresh interval (30 s) and
//// releases any read it no longer starts (`relisted`). The round needs no
//// timer of its own.
////
//// The module is pure. It imports no Lustre and reads no clock, so every
//// arrival order is a test of a function over a record, with no page to draw.
//// `web_view/home` owns the round, feeds it the answers and asks it for the
//// landing; a centre it has decided, or the person has chosen, is never moved
//// by a later read.
////
//// ## Flow
////
//// `open` → `listed` / `relisted` / `answer` → `landing`
////
//// 1. `open` starts a round with the list due, and the boards due on a page
////    that lists projects.
//// 2. `listed` takes the first list that was read, and with it which of the activity,
////    summary and feed reads that list started, since a page asks a read only
////    for a session of the matching kind.
//// 3. `answer` records each later first answer, and says whether it was the
////    last one due. `relisted` takes every later readable list and releases a
////    due read the list no longer starts, since its task may have crashed.
//// 4. `landing` reads the gathered picture once the round has closed.
////
//// ## Transitions
////
//// <!-- transitions: landing_rule.Reading -->
////
//// | state | the read's first answer | the read answers again | the first list is read |
//// | --- | --- | --- | --- |
//// | `Due` | `Answered` | not reachable | the list's own field becomes `Answered`; the others are set by it |
//// | `Answered` | not reachable | stays `Answered` | stays `Answered` |
//// | `NotDue` | stays `NotDue`, the read is ignored | stays `NotDue` | may become `Due`, if the list started that read |

import gleam/list
import web_view/inbox_rule
import web_view/sessions.{type Report}

/// Where one first read stands.
pub type Reading {
  /// The page asked the read, or will, and its first answer has not come.
  Due

  /// The read's first answer has come. Whatever it held, it counts.
  Answered

  /// The page asks no such read, so the round does not wait for one.
  NotDue
}

/// The first reads the round holds, each named for the daemon read it stands for.
pub type Source {
  /// The principal's session list.
  ListSource

  /// What the running sessions are doing.
  ActivitySource

  /// The catalogue's summaries of the saved sessions.
  SummarySource

  /// The projects' boards.
  BoardsSource

  /// The feed of open asks and finds of the running sessions.
  FeedSource
}

/// Which first reads a page has had answered and which it is still owed. The
/// round is a value the page replaces, never mutated, so a test states an
/// arrival order as a fold.
pub type Round {
  Round(
    /// The session list. It is due until it first answers, and the other
    /// reads are not known to be due before then.
    list: Reading,
    /// The activity of the running sessions, due when the list holds one.
    activity: Reading,
    /// The catalogue's summaries, due when the page reads them and the list
    /// holds a saved session.
    summary: Reading,
    /// The boards, due when the page lists projects.
    boards: Reading,
    /// The feed's rows, due when the page reads the feed and the list holds a
    /// running session.
    feed: Reading,
  )
}

/// Whether an answer was the one that completed the round.
pub type Close {
  /// This answer was the last one due, so the page decides now, once.
  Closes

  /// A read is still due, or the round had completed before this answer.
  Continues
}

/// What the round gathered, as the page counts it: the activity reports of the
/// running sessions and the number of things that wait on a person.
pub type Picture {
  Picture(
    /// The reports the activity read gave, one for each running session.
    reports: List(Report),
    /// The approvals, asks and stuck strands across running and saved sessions.
    needing: Int,
    /// The open finds across running and saved sessions.
    finds: Int,
    /// The project tickets waiting on a person.
    tickets: Int,
  )
}

/// A round with the list due and nothing else known. `boards` is `Due` on a
/// page that lists projects and `NotDue` on one that does not, because the list
/// says nothing about boards and the page knows its own capabilities at the start.
///
/// ## Examples
///
/// ```gleam
/// let round = landing_rule.open(landing_rule.NotDue)
/// assert round.list == landing_rule.Due
/// ```
pub fn open(boards: Reading) -> Round {
  Round(list: Due, activity: NotDue, summary: NotDue, boards:, feed: NotDue)
}

/// Takes the first list, and with it which of the reads that depend on the list
/// are due. A list that was read starts an activity read only if it holds a
/// running session, a summary read only if it holds a saved one and the page
/// reads summaries, and a feed read only if it holds a running one and the page
/// reads the feed. Only a list that was read is passed here: an unreadable one
/// tells the round nothing, so the round keeps waiting for the next. Only the
/// first list sets the reads: a later list changes nothing in the round, since
/// the round has closed or is waiting on reads the first list already started.
///
/// ## Examples
///
/// ```gleam
/// let #(round, close) =
///   landing_rule.listed(
///     landing_rule.open(landing_rule.NotDue),
///     activity: landing_rule.NotDue,
///     summary: landing_rule.NotDue,
///     feed: landing_rule.NotDue,
///   )
/// assert close == landing_rule.Closes
/// assert round.list == landing_rule.Answered
/// ```
pub fn listed(
  round: Round,
  activity activity: Reading,
  summary summary: Reading,
  feed feed: Reading,
) -> #(Round, Close) {
  case round.list {
    Due -> answer(Round(..round, activity:, summary:, feed:), ListSource)
    Answered | NotDue -> relisted(round, activity:, summary:, feed:)
  }
}

/// Takes a later readable list. A read that is still due but that the list no
/// longer starts, because its session stopped or was resumed or deleted, will
/// not answer if its task crashed, so it is marked `Answered`, and the answer is
/// `Closes` if that leaves no read due. A read the list still starts keeps its
/// reading, and a read that was not due is not made due.
///
/// ## Examples
///
/// ```gleam
/// let round = landing_rule.open(landing_rule.NotDue)
/// let #(round, _) =
///   landing_rule.listed(round, activity: landing_rule.Due, summary: landing_rule.NotDue, feed: landing_rule.NotDue)
/// let #(_, close) =
///   landing_rule.relisted(round, activity: landing_rule.NotDue, summary: landing_rule.NotDue, feed: landing_rule.NotDue)
/// assert close == landing_rule.Closes
/// ```
pub fn relisted(
  round: Round,
  activity activity: Reading,
  summary summary: Reading,
  feed feed: Reading,
) -> #(Round, Close) {
  let next =
    Round(
      ..round,
      activity: released(round.activity, activity),
      summary: released(round.summary, summary),
      feed: released(round.feed, feed),
    )

  // Only a round that was waiting can close, and only by releasing its last read.
  case owed(round), owed(next) {
    0, _ -> #(next, Continues)
    _, 0 -> #(next, Closes)
    _, _ -> #(next, Continues)
  }
}

/// A read after a later list: a due read the list no longer starts is released.
fn released(held: Reading, started: Reading) -> Reading {
  case held, started {
    Due, NotDue -> Answered
    Due, Due | Due, Answered | Answered, _ | NotDue, _ -> held
  }
}

/// Records a read's first answer. A read that is not due, or that answered
/// before, changes nothing. The close says whether this answer left no read due
/// after one had been, so exactly one answer in any order closes the round.
///
/// ## Examples
///
/// ```gleam
/// let round = landing_rule.open(landing_rule.Due)
/// let #(round, close) = landing_rule.answer(round, landing_rule.BoardsSource)
/// assert close == landing_rule.Continues
/// ```
pub fn answer(round: Round, source: Source) -> #(Round, Close) {
  // The answer marks the one read it belongs to, and no other.
  let next = case source {
    ListSource -> Round(..round, list: arrived(round.list))
    ActivitySource -> Round(..round, activity: arrived(round.activity))
    SummarySource -> Round(..round, summary: arrived(round.summary))
    BoardsSource -> Round(..round, boards: arrived(round.boards))
    FeedSource -> Round(..round, feed: arrived(round.feed))
  }

  // The round closes on the answer that takes the due reads from some to none.
  case owed(round), owed(next) {
    0, _ -> #(next, Continues)
    _, 0 -> #(next, Closes)
    _, _ -> #(next, Continues)
  }
}

/// Where the page lands for what the round gathered: the inbox when any running
/// session needs the owner, waits on the owner's reading or works
/// (`inbox_rule.landing`), or when any approval, ask, stuck strand, find or
/// ticket waits, and the new-session form when nothing does. A running session
/// that is quiet does not count, so a person who comes back to a quiet session
/// and a saved one with an approval pending lands on the inbox, and one with
/// nothing pending lands on the form.
///
/// ## Examples
///
/// ```gleam
/// let picture = landing_rule.Picture(reports: [], needing: 0, finds: 0, tickets: 0)
/// assert landing_rule.landing(picture) == inbox_rule.Form
/// ```
pub fn landing(picture: Picture) -> inbox_rule.Landing {
  case inbox_rule.landing(picture.reports) {
    inbox_rule.Inbox -> inbox_rule.Inbox
    inbox_rule.Form ->
      case picture.needing + picture.finds + picture.tickets {
        0 -> inbox_rule.Form
        _ -> inbox_rule.Inbox
      }
  }
}

/// A read's reading after an answer arrives: a due read has now answered.
fn arrived(reading: Reading) -> Reading {
  case reading {
    Due -> Answered
    Answered | NotDue -> reading
  }
}

/// How many reads the round is still owed.
fn owed(round: Round) -> Int {
  list.count(
    [round.list, round.activity, round.summary, round.boards, round.feed],
    fn(reading) { reading == Due },
  )
}
