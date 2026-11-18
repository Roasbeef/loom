//// The daemon's read of one session's worktree for a review pane
//// (protocol-change/123).
////
//// A review is the diff a finished session left in its workspace, as hunks. The
//// daemon already observes that tree for the Changes tab: the session's own
//// instance holds a closure over its workspace, its base commit and its effect
//// broker, and `worktree_diff.capture_since` runs a fixed set of Git calls
//// through that broker, inside the session's sandbox, with filesystem grants
//// demoted to reads. Repository configuration therefore never runs a process in
//// the harness VM (Rule Zero). This module does not run Git and does not touch
//// the workspace. It decides who may ask, calls the instance's own observation
//// in a run of its own, and turns the board that comes back into a review.
////
//// ## Flow
////
//// `read` → `held` → `resident` → `observed`
////
//// 1. `held` asks the registry for the caller's authority over the session,
////    read afresh. A session the caller does not hold is refused as an unknown
////    one is.
//// 2. `resident` finds the running instance. The daemon never opens a saved
////    session to read its tree, so a saved one is refused as not running.
//// 3. `read` then takes one of the credential's workspace reads, which the web
////    view's Changes tab spends from as well, so many sockets cannot spend the
////    session's helper pool on Git calls.
//// 4. `observed` runs the instance's observation under a deadline that covers
////    its execution and the broker's cleanup grace, and answers nothing for a
////    run that failed, was cancelled or crashed.
//// 5. `read` decodes the board with the terminal's own decoder and builds the
////    bounded review (`web_view/review_feed`).
////
//// ## Who may read
////
//// The owner, and a member holding the session as an Operator. An observer is
//// refused as `forbidden`, for the reason the Changes tab never shows an
//// observer's page the worktree (protocol-change/051, the addendum on the
//// worktree read): an observer link is handed to someone who may only watch,
//// and the tree's bytes are not what they were given. Nothing here stages,
//// sends or writes, and the in-process path for Home hands the page a value
//// and no handle.
////
//// ## What a refusal says
////
//// A failure's own text is never forwarded, because it can carry a repository's
//// words. The refusal names a code and fixed words alone.

import client/daemon/attention_door.{type Refusal, Refusal}
import client/daemon/manager
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option}
import gleam/result
import session_view/worktree_view
import storage/access
import web_view/review_feed
import web_view/review_scan_rule
import weft

/// How long the read waits for the observation before it gives up: the
/// observation's 8 s execution deadline, the broker's 5 s cleanup grace
/// (`worktree_diff.capture_timeout_ms`, `settlement_grace_ms`) and a second. It
/// is the page's own read deadline too (`ui_socket.reading`). A stalled broker
/// can take longer than that, in which case the caller is refused as
/// `unavailable` and the run is cancelled.
pub const deadline_ms = 14_000

/// What the daemon needs to read one session's tree as one caller.
pub type Reach(instance) {
  Reach(
    /// The registry that answers authority and residency.
    registry: manager.Manager(instance),
    /// The caller's credential, whose authority is read afresh.
    digest: access.Digest,
    /// The instance's own observation of its own workspace, when it has one.
    /// It takes nothing from the caller.
    observe: fn(instance) -> Option(fn() -> Result(JsonValue, String)),
    /// Takes one of the credential's workspace reads, or refuses. The place is
    /// not given back, because a read that failed still spent its Git calls.
    reserve: fn() -> Result(Nil, Nil),
  )
}

/// Reads a session's worktree as a review.
///
/// ## Examples
///
/// ```gleam
/// // review_door.read(reach, "0198c0de-0000-7000-8000-000000000001")
/// ```
pub fn read(
  reach: Reach(instance),
  session: String,
) -> Result(review_feed.Review, Refusal) {
  use _authority <- result.try(held(reach, session))
  use observe <- result.try(resident(reach, session))
  use Nil <- result.try(
    reach.reserve()
    |> result.replace_error(Refusal("unavailable", review_scan_rule.busy_words)),
  )
  use board <- result.map(observed(observe))
  review_feed.of_board(board)
}

/// The caller's authority over the session, read from the registry now. The
/// owner and an Operator read; an observer is `forbidden`, and a session the
/// caller does not hold is `not_found`, the word an unknown one gets.
fn held(
  reach: Reach(instance),
  session: String,
) -> Result(access.Authority, Refusal) {
  use held <- result.try(
    manager.session_authority(reach.registry, reach.digest, session)
    |> result.replace_error(Refusal("not_found", "no such session")),
  )

  // The owner and an operator may read the tree; an observer may not.
  case held.1 {
    access.Owner | access.Participant(access.Operator) -> Ok(held.1)
    access.Participant(access.Observer) ->
      Error(Refusal("forbidden", "an observer cannot read a session's worktree"))
  }
}

/// The resident session's observation, or `not_resident`. A session that is
/// saved, opening or stopping, and one with no observation, are the same to a
/// caller: nothing is running that could read its tree.
fn resident(
  reach: Reach(instance),
  session: String,
) -> Result(fn() -> Result(JsonValue, String), Refusal) {
  let none = Refusal("not_resident", "the session is not running")
  use instance <- result.try(
    manager.resolve(reach.registry, session) |> result.replace_error(none),
  )
  reach.observe(instance) |> option.to_result(none)
}

/// Runs the observation in a run of its own and decodes the board it returns.
/// The caller's process is the one that waits, so a slow Git call holds up
/// neither the registry nor the session.
fn observed(
  observe: fn() -> Result(JsonValue, String),
) -> Result(worktree_view.Board, Refusal) {
  let unreadable =
    Refusal("unavailable", "the session's workspace could not be read")
  let outcome =
    weft.new([observe])
    |> weft.deadline(deadline_ms)
    |> weft.start

  // Only a completed observation that is a board is an answer; every other
  // outcome is the same refusal, and none of their text is forwarded.
  case list.first(outcome) {
    Ok(weft.Completed(value: board, ..)) ->
      board_of(board) |> result.replace_error(unreadable)
    Ok(weft.Failed(..))
    | Ok(weft.Crashed(..))
    | Ok(weft.Abandoned(..))
    | Ok(weft.NeverStarted(..))
    | Ok(weft.DrainProofLost(..))
    | Ok(weft.CancellationUnconfirmed(..))
    | Error(Nil) -> Error(unreadable)
  }
}

/// A board from the observation's own encoding, read by the decoder the terminal
/// uses, under the envelope the gateway wraps it in.
fn board_of(value: JsonValue) -> Result(worktree_view.Board, Nil) {
  case value {
    json.Object(fields) ->
      worktree_view.decode(
        json.Object([
          #("status", json.String("ready")),
          #("request_id", json.Int(0)),
          ..fields
        ]),
      )
      |> result.replace_error(Nil)
      |> result.try(ready)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(Nil)
  }
}

/// The board of a ready event; a pending or failed one is not a board.
fn ready(event: worktree_view.Event) -> Result(worktree_view.Board, Nil) {
  case event {
    worktree_view.Ready(board) -> Ok(board)
    worktree_view.Pending(_) | worktree_view.Failed(..) -> Error(Nil)
  }
}
