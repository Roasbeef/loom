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
////    found changes. `to_review` names the sessions the inbox lists under "To
////    review": those, and every session not yet read, so a session moves to
////    "Waiting" only when a successful read says its tree is clean and never
////    jumps the other way as the scan works through the list. `checking` names
////    the ones still unread.

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

/// The words the daemon refuses a read with when the credential has spent its
/// allowance of workspace reads (`client/daemon/review_door`). A read refused
/// for that reason says nothing about the session, so the scan does not count
/// it as an attempt.
pub const busy_words = "too many workspace reads; try again shortly"

/// Whether a worktree holds anything to review.
pub type Changes {
  /// The review holds files, or says that it left some out.
  Changed

  /// A checkout with nothing changed, or no checkout.
  Unchanged
}

/// What a successful read found for one message.
pub type Verdict {
  Verdict(
    /// The last message the session said when the read was made.
    message: String,
    /// Whether the worktree held anything to review.
    changes: Changes,
    /// What changed, in numbers, as the read counted it. The row words it
    /// (`stat_words`), so a reader sees the size of the change before opening it.
    stat: review_feed.Stat,
  )
}

/// What is outstanding for a session beside its verdict.
pub type Pending {
  /// Nothing is out and nothing has failed since the verdict.
  NoRead

  /// A read is out, begun at `since` (Unix milliseconds). `failed` is how many
  /// reads of this message failed before it began, which the next failure adds
  /// one to, so `max_attempts` counts across the restarts a read goes through.
  Reading(message: String, since: Int, failed: Int)

  /// The read was failed `attempts` times in a row.
  Failed(message: String, attempts: Int)
}

/// What the page knows of one session's worktree.
///
/// The verdict is the last successful read and outlives everything that
/// happens after it: a read that is out, a read that failed and a refusal for
/// the credential's allowance all replace `pending` and leave `verdict`
/// alone. Only a read that answers replaces a verdict, so a session does not
/// move between "To review" and "Waiting" because the daemon was busy. A
/// verdict counts for the message it was read for and no other, and a session
/// whose message moves on is not ready until the new message is read, but one
/// whose message returns to the read one is ready again at once.
pub type Seen {
  Seen(verdict: Option(Verdict), pending: Pending)
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

/// The statistics a session's last read counted, for the message it was read for
/// and no other: nothing for a session not yet read, or read at an older message.
///
/// ## Examples
///
/// ```gleam
/// assert review_scan_rule.stat_of(dict.new(), "a", "m") == None
/// ```
pub fn stat_of(
  seen: Dict(String, Seen),
  session: String,
  message: String,
) -> Option(review_feed.Stat) {
  case verdict_of(seen, session) {
    Some(Verdict(message: read, changes: Changed, stat:)) if read == message ->
      Some(stat)
    Some(_) | None -> None
  }
}

/// A review's size as a row says it: `+412 −88, 7 files · 2 finds attached`. The
/// count of finds is left out when the session has none.
///
/// ## Examples
///
/// ```gleam
/// assert review_scan_rule.stat_words(Stat(7, 412, 88), 2)
///   == "+412 −88, 7 files · 2 finds attached"
/// assert review_scan_rule.stat_words(Stat(1, 3, 0), 0) == "+3 −0, 1 file"
/// ```
pub fn stat_words(stat: review_feed.Stat, finds: Int) -> String {
  // One file is "1 file", and the plural is every other count.
  let files = case stat.files {
    1 -> "1 file"
    many -> int.to_string(many) <> " files"
  }

  let size =
    "+"
    <> int.to_string(stat.added)
    <> " −"
    <> int.to_string(stat.removed)
    <> ", "
    <> files

  // The finds are named only when there are some, in the singular for one.
  case finds {
    0 -> size
    1 -> size <> " · 1 find attached"
    many -> size <> " · " <> int.to_string(many) <> " finds attached"
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
      case each.pending {
        Reading(since:, ..) -> now - since < stale_ms
        NoRead | Failed(..) -> False
      }
    })

  // A read that is out holds the line, and otherwise the session with the fewest attempts is next.
  case busy {
    True -> None
    False ->
      candidates
      |> list.filter_map(fn(candidate) {
        let #(session, message) = candidate

        // A message already read, or out, or out of tries is not due.
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
  dict.insert(
    seen,
    session,
    Seen(
      verdict: verdict_of(seen, session),
      pending: Reading(
        message:,
        since: now,
        failed: failures(seen, session, message),
      ),
    ),
  )
}

/// Records what a read of `session` for `message` found. A read that failed
/// counts as one more attempt for that message, and a refusal for the
/// credential's allowance counts as none; either leaves the session's verdict
/// as it was.
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
  let before = verdict_of(seen, session)

  // Only a read that answered replaces the verdict. A refusal for the allowance
  // and a failure change what is pending and leave the verdict alone.
  case read {
    Ok(review) ->
      dict.insert(
        seen,
        session,
        Seen(
          verdict: Some(Verdict(
            message:,
            changes: changes_in(review),
            stat: review.stat,
          )),
          pending: NoRead,
        ),
      )

    // The refusal says nothing about the session: a session with no verdict is
    // as if unread, and one with a verdict keeps it.
    Error(words) if words == busy_words ->
      case before {
        Some(_) ->
          dict.insert(seen, session, Seen(verdict: before, pending: NoRead))
        None -> dict.delete(seen, session)
      }

    Error(_) ->
      dict.insert(
        seen,
        session,
        Seen(
          verdict: before,
          pending: Failed(
            message:,
            attempts: failures(seen, session, message) + 1,
          ),
        ),
      )
  }
}

/// How many reads of `message` have failed for the session so far: the count a
/// failed or restarted read carries, and none for any other message.
fn failures(seen: Dict(String, Seen), session: String, message: String) -> Int {
  case dict.get(seen, session) {
    Ok(Seen(pending: Failed(message: failed, attempts:), ..))
      if failed == message
    -> attempts
    Ok(Seen(pending: Reading(message: failed, failed: attempts, ..), ..))
      if failed == message
    -> attempts
    Ok(_) | Error(Nil) -> 0
  }
}

/// The verdict a session holds, if it has one.
fn verdict_of(seen: Dict(String, Seen), session: String) -> Option(Verdict) {
  case dict.get(seen, session) {
    Ok(Seen(verdict:, ..)) -> verdict
    Error(Nil) -> None
  }
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

    // Only a verdict for the current message that found changes is ready.
    case verdict_of(seen, session) {
      Some(Verdict(message: read, changes: Changed, ..)) if read == message ->
        Ok(session)
      Some(_) | None -> Error(Nil)
    }
  })
}

/// The sessions the inbox lists under "To review": every candidate except one
/// whose verdict for its current message says the tree is clean. A session not
/// yet read is listed, since the scan reads one at a time within the daemon's
/// allowance and a session that moved to "Waiting" only to jump back when its
/// turn came would shuffle the list on every load. A refused or failed read
/// changes no verdict, so it leaves the session where it was.
///
/// ## Examples
///
/// ```gleam
/// assert review_scan_rule.to_review([#("a", "m")], dict.new()) == ["a"]
/// ```
pub fn to_review(
  candidates: List(#(String, String)),
  seen: Dict(String, Seen),
) -> List(String) {
  list.filter_map(candidates, fn(candidate) {
    let #(session, message) = candidate

    // Only a clean verdict for the current message sends a session to Waiting.
    case verdict_of(seen, session) {
      Some(Verdict(message: read, changes: Unchanged, ..)) if read == message ->
        Error(Nil)
      Some(_) | None -> Ok(session)
    }
  })
}

/// The sessions listed under "To review" whose current message has no verdict
/// yet, which the row words as being checked.
///
/// ## Examples
///
/// ```gleam
/// assert review_scan_rule.checking([#("a", "m")], dict.new()) == ["a"]
/// ```
pub fn checking(
  candidates: List(#(String, String)),
  seen: Dict(String, Seen),
) -> List(String) {
  list.filter_map(candidates, fn(candidate) {
    let #(session, message) = candidate

    // A verdict for another message is no verdict for this one.
    case verdict_of(seen, session) {
      Some(Verdict(message: read, ..)) if read == message -> Error(Nil)
      Some(_) | None -> Ok(session)
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
    Ok(Seen(verdict: Some(Verdict(message: read, ..)), ..)) if read == message ->
      None
    Ok(Seen(pending: NoRead, ..)) -> Some(0)
    Ok(Seen(pending: Reading(message: read, ..), ..)) if read != message ->
      Some(0)
    Ok(Seen(pending: Failed(message: read, ..), ..)) if read != message ->
      Some(0)
    Ok(Seen(pending: Failed(attempts:, ..), ..)) if attempts < max_attempts ->
      Some(attempts)
    Ok(Seen(pending: Reading(..), ..)) | Ok(Seen(pending: Failed(..), ..)) ->
      None
  }
}
