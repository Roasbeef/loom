//// Which idle sessions are "To review": the sessions that stopped with a last
//// message and whose worktree holds changes (the attention inbox,
//// `docs/design-notes/attention-inbox/README.md` section 2.1).
////
//// Whether a worktree holds changes is known only by reading it, and a read is
//// about twenty-six jailed Git calls on the session's helper pool, which the
//// agent's own tools share. The daemon allows a credential two in four seconds
//// (`ui_sessions.worktree_read_limit`). The page therefore reads one session
//// at a time, only for an idle session with a last message, and only once for
//// each last message: a session whose message has not changed since it was
//// read is not read again, and one that said something new is read afresh,
//// since it may have changed files since.
////
//// The rule keeps a small value for each session, never the review itself, so
//// the model holds a verdict and not forty kilobytes of hunks for each
//// session. The review of the thread that is open is kept apart
//// (`web_view/review_pane`).
////
//// A read that failed is tried again, at most `max_attempts` times for the
//// same message, and only after every session that was never read has had its
//// turn. A read that never answered, because the page's task was lost, stops
//// holding the line after `stale_ms`.
////
//// The module is pure and holds no Lustre and no clock: the page hands it the
//// time.
////
//// ## Flow
////
//// `due` → `started` → `answered` → `ready`
////
//// 1. `due` picks the one session to read next, or nothing.
//// 2. `started` records that its read is out, and `answered` records what the
////    read found.
//// 3. `ready` names the sessions whose last read, at their current message,
////    found changes.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import web_view/review_feed.{type Review}

/// How long a read may be out before the page stops waiting for it, in
/// milliseconds. The daemon's own read gives up after 14 seconds
/// (`review_door.deadline_ms`), so this is past it.
pub const stale_ms = 30_000

/// How many times one message's read is tried when it keeps failing.
pub const max_attempts = 3

/// Whether a worktree holds anything to review.
pub type Changes {
  /// The review holds files, or says that it left some out.
  Changed

  /// A checkout with nothing changed, or no checkout.
  Unchanged
}

/// What the page knows of one session's worktree, for the message the session
/// last said.
pub type Seen {
  /// A read is out, begun at `since` (Unix milliseconds).
  Reading(message: String, since: Int)

  /// A read answered.
  Checked(message: String, changes: Changes)

  /// The read was refused or failed `attempts` times in a row.
  Failed(message: String, attempts: Int)
}

/// Whether a review holds anything to read. A repository that is not a
/// checkout holds nothing; otherwise a file, or a file left out, is something.
///
/// ## Examples
///
/// ```gleam
/// // review_scan_rule.changes_in(review) == review_scan_rule.Changed
/// ```
pub fn changes_in(review: Review) -> Changes {
  case review.repository, review.files, review.omitted {
    review_feed.NotRepository, _, _ -> Unchanged
    review_feed.Head, [], 0 | review_feed.Unborn, [], 0 -> Unchanged
    review_feed.Head, _, _ | review_feed.Unborn, _, _ -> Changed
  }
}

/// The one session to read next, as its identity and the message it was read
/// for, or nothing when none is due or a read is still out. `candidates` are
/// the idle sessions with a last message, in the order the page lists them.
///
/// ## Examples
///
/// ```gleam
/// assert review_scan_rule.due([], dict.new(), 0) == None
/// ```
pub fn due(
  candidates: List(#(String, String)),
  seen: Dict(String, Seen),
  now: Int,
) -> Option(#(String, String)) {
  // A read that is out and not stale holds the line.
  let busy =
    list.any(dict.values(seen), fn(each) {
      case each {
        Reading(since:, ..) -> now - since < stale_ms
        Checked(..) | Failed(..) -> False
      }
    })

  case busy {
    True -> None
    False ->
      candidates
      |> list.filter_map(fn(candidate) {
        let #(session, message) = candidate

        case attempts(dict.get(seen, session), message) {
          Some(count) -> Ok(#(count, candidate))
          None -> Error(Nil)
        }
      })
      |> list.sort(fn(left, right) { int.compare(left.0, right.0) })
      |> list.first
      |> option.from_result
      |> option.map(fn(entry) { entry.1 })
  }
}

/// Records that a read of `session` is out for `message`.
///
/// ## Examples
///
/// ```gleam
/// assert dict.size(review_scan_rule.started(dict.new(), "a", "done", 5)) == 1
/// ```
pub fn started(
  seen: Dict(String, Seen),
  session: String,
  message: String,
  now: Int,
) -> Dict(String, Seen) {
  dict.insert(seen, session, Reading(message:, since: now))
}

/// Records what a read of `session` for `message` found. A read that failed
/// counts as one more attempt for that message.
///
/// ## Examples
///
/// ```gleam
/// assert dict.size(review_scan_rule.answered(dict.new(), "a", "done", Error("no"))) == 1
/// ```
pub fn answered(
  seen: Dict(String, Seen),
  session: String,
  message: String,
  read: Result(Review, String),
) -> Dict(String, Seen) {
  dict.insert(seen, session, case read {
    Ok(review) -> Checked(message:, changes: changes_in(review))
    Error(_) ->
      Failed(message:, attempts: case dict.get(seen, session) {
        Ok(Failed(message: before, attempts:)) if before == message ->
          attempts + 1
        Ok(_) | Error(Nil) -> 1
      })
  })
}

/// The sessions whose last read was at the message they say now and found
/// changes, in the order of `candidates`.
///
/// ## Examples
///
/// ```gleam
/// assert review_scan_rule.ready([], dict.new()) == []
/// ```
pub fn ready(
  candidates: List(#(String, String)),
  seen: Dict(String, Seen),
) -> List(String) {
  list.filter_map(candidates, fn(candidate) {
    let #(session, message) = candidate

    case dict.get(seen, session) {
      Ok(Checked(message: read, changes: Changed)) if read == message ->
        Ok(session)
      Ok(_) | Error(Nil) -> Error(Nil)
    }
  })
}

/// How many attempts the session's message has had, when it is due another:
/// none for a message never read, and the count so far for a failed one that
/// has tries left. A message that was read, is being read, or has used its
/// tries is not due.
fn attempts(held: Result(Seen, Nil), message: String) -> Option(Int) {
  case held {
    Error(Nil) -> Some(0)
    Ok(Reading(message: read, ..)) if read != message -> Some(0)
    Ok(Checked(message: read, ..)) if read != message -> Some(0)
    Ok(Failed(message: read, ..)) if read != message -> Some(0)
    Ok(Failed(attempts:, ..)) if attempts < max_attempts -> Some(attempts)
    Ok(Reading(..)) | Ok(Checked(..)) | Ok(Failed(..)) -> None
  }
}
