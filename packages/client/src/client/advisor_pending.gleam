//// The advisor's undelivered nudge queue, read as a bounded observation.
////
//// A queued nudge is not an entry. It lives in one field of the emission
//// guard cell (`advisor/guard`, written by the advisor actor alone) and
//// reaches the primary when that strand next stops, or waits for the
//// operator's next prompt once the turn's one unsolicited delivery is
//// spent, so no ordinary transcript capture carries it to an operator.
//// This module is the one read that does, and it exists because the
//// operator's useful moment is exactly the one the transcript cannot
//// describe: the primary is idle, the advice is already written, and
//// the turn that would have delivered it is spent, so nothing will show
//// it until the operator types again.
////
//// Two properties shape the code. The read never speaks to the advisor actor
//// and never calls `take_pending`: the drain belongs to the run-start hook,
//// and an observation that took the queue would deliver the advice to
//// nobody. And a cell that is present but will not decode is refused rather
//// than reported as an empty queue, because an empty board is the positive
//// claim that the advisor has nothing waiting. The advisor actor's own
//// fallback differs — it carries on from the empty guard — because it must
//// keep reviewing whatever it finds under that key; an observer is free to
//// say that it cannot tell.

import client/advisor
import client/advisorguard
import core/json.{type JsonValue}
import core/register
import gleam/list
import gleam/result
import session/session.{type Session}
import storage/snapshot

/// Why one pending-nudge observation produced no board.
///
/// The two variants are told apart rather than flattened into one reason
/// string because they have different consumers. An unreadable store is
/// evidence about the storage actor and is handled the way the gateway
/// handles any failed capture of its own; a malformed cell refuses this one
/// question and touches nothing else.
pub type Error {
  /// The bounded reader refused, expired, or was gone.
  Unreadable(error: snapshot.Error)

  /// The cell exists and the guard's own decoder rejected it.
  Malformed(reason: String)
}

/// Reads the nudges still waiting to reach the primary, oldest first.
///
/// `now` is the observing instant the board is stamped with. The caller
/// supplies it so this function stays one projection of one storage cut and
/// reads no clock of its own. A missing cell is an empty board rather than
/// an error: a session whose advisor never ran, or never queued anything,
/// genuinely has nothing pending.
///
/// The queue needs no omission accounting. `advisorguard` admits at most
/// `pending_cap` nudges totalling `pending_bytes`, currently eight and four
/// kilobytes, so the whole queue fits inside the response bound and the board
/// never reports a truncated view of itself.
///
/// ## Examples
///
/// ```gleam
/// // advisor_pending.read(session, 1_726_000_000_000)
/// ```
///
pub fn read(session: Session, now: Int) -> Result(JsonValue, Error) {
  // One exact key, never a prefix. A scan of the reserved namespace would
  // also return the feed cursor, which this observation has no business
  // reading and which moves on every review.
  let plan =
    snapshot.Plan(
      [snapshot.ExactKey(register.FactCustom, advisor.guard_key)],
      [],
      0,
    )

  use cut <- result.try(
    session.snapshot_reader.capture(plan, 5000)
    |> result.map_error(Unreadable),
  )

  // An exact-key selection contributes at most one cell, and contributes
  // none at all when the key is absent.
  use pending <- result.try(case cut.cells {
    [] -> Ok([])
    [cell, ..] -> queued(cell)
  })

  Ok(board(pending, now))
}

// The guard's own decoder is the only reader of this payload, so a shape it
// rejects is refused here rather than reinterpreted. `pending` reads the
// queue without draining it, which is the whole discipline of this module.
fn queued(cell: snapshot.Cell) -> Result(List(String), Error) {
  advisorguard.decode(cell.register.value.payload)
  |> result.map(advisorguard.pending)
  |> result.map_error(Malformed)
}

// The board names the strand the queue drains into rather than one a caller
// chose. There is one advisor per session and one primary it advises, so a
// strand parameter could only be right or wrong.
fn board(pending: List(String), now: Int) -> JsonValue {
  json.Object([
    #("strand", json.String(advisor.primary)),
    #("observed_at_ms", json.Int(now)),
    #("pending", json.Array(list.map(pending, json.String))),
    #("total", json.Int(list.length(pending))),
  ])
}
