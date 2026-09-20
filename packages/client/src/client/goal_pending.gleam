//// The goal status observation, read the way `client/advisor_pending`
//// reads the nudge queue: one exact cell, the codec's own decoder, and
//// no conversation with the actor.
////
//// A read that spoke to the actor could not answer while the actor is
//// busy scanning a branch, and an observation is not entitled to wait:
//// the panel wants the current state, not the state after the loop's
//// next step. The cell is durable and single-written, so the exact-key
//// read is always the freshest committed state. A malformed cell is
//// `unavailable` rather than an empty board, because an empty board is
//// the positive claim that no goal is pinned and an unreadable cell is
//// not evidence for it — the same asymmetry protocol 039 states for
//// the guard cell.
////
//// Purity: one projection of one storage cut. `now` is caller-supplied
//// so the module reads no clock.

import client/advisor
import client/goalloop
import client/goalstate
import core/json
import core/register
import gleam/option.{None, Some}
import gleam/result
import session/session.{type Session}
import storage/snapshot

/// What the read can fail on. Kept as a type rather than a string for the
/// reason `client/advisor_pending` keeps one: a storage failure and a
/// this-question failure are different facts to the gateway, and it
/// answers them with different codes.
pub type Error {
  /// The store would not answer.
  Unreadable(error: snapshot.Error)

  /// The cell is present and does not decode. The actor's own reader
  /// falls back to "no goal" — it must keep steering whatever it finds —
  /// but an observer may say that it cannot tell.
  Malformed(reason: String)
}

/// Reads the session's goal, as the `goal_get` command's board.
///
/// The board carries the whole goal when one is pinned, or `status:
/// "none"` when no cell exists. The observed stamp is the caller's, so
/// the panel can render an age without a terminal clock.
pub fn read(session: Session, now: Int) -> Result(json.JsonValue, Error) {
  // One exact key, never a prefix: the reserved namespace holds only
  // this cell today, but the discipline costs nothing and a later cell
  // under the same prefix is not this observation's business.
  let plan =
    snapshot.Plan(
      [snapshot.ExactKey(register.FactCustom, advisor.goal_key)],
      [],
      0,
    )

  use cut <- result.try(
    session.snapshot_reader.capture(plan, 5000)
    |> result.map_error(Unreadable),
  )

  use goal <- result.try(case cut.cells {
    // No cell is no goal: a real state, answered as one.
    [] -> Ok(None)

    [cell, ..] ->
      case goalstate.decode(cell.register.value.payload) {
        Ok(goal) -> Ok(Some(goal))
        Error(reason) -> Error(Malformed(reason:))
      }
  })

  Ok(board(goal, now))
}

fn board(goal: option.Option(goalstate.Goal), now: Int) -> json.JsonValue {
  case goal {
    None ->
      json.Object([
        #("status", json.String("none")),
        #("observed_at_ms", json.Int(now)),
      ])

    Some(goal) ->
      json.Object([
        #("status", json.String(goalstate.encode_status(goal.status))),
        // The status word alone names four different pauses and two
        // different limits, so the cause rides beside it: the operator
        // reading a held goal needs to know whether they paused it,
        // whether their abort did, or whether the harness stopped a loop
        // that was producing nothing.
        #("reason", encode_note(goalstate.encode_reason(goal.status))),
        #("because", json.String(goalloop.stopped_because(goal.status))),
        #("objective", json.String(goal.objective)),
        #("token_budget", json.Int(goal.token_budget)),
        #("tokens_used", json.Int(goal.tokens_used)),
        #("cost_used", json.Float(goal.cost_used)),
        #("continuations", json.Int(goal.continuations)),
        #("created_ms", json.Int(goal.created_ms)),
        #("updated_ms", json.Int(goal.updated_ms)),
        #("reviewer_note", encode_note(goal.reviewer_note)),
        // The operator's check and what it last did. The panel shows both,
        // because a check the operator pinned and never sees the result of
        // is a check they cannot tell is running — and the result is the
        // same evidence the reviewer was shown, from the same cell, so the
        // two cannot be told different stories.
        #("check", encode_note(goal.check)),
        #("last_check", goalstate.encode_last_check(goal.last_check)),
        #("observed_at_ms", json.Int(now)),
      ])
  }
}

// The nullable strings are null rather than absent, the cell's own
// always-present-sometimes-null discipline, so the panel's decoder can
// trust one shape.
fn encode_note(note: option.Option(String)) -> json.JsonValue {
  case note {
    option.None -> json.Null
    option.Some(text) -> json.String(text)
  }
}
