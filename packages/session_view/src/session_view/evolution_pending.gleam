//// The selections a person has asked for that have not finished: the request
//// identity the lane mints, the polling it owes, and the words a host draws
//// while they stage (protocol-change/099).
////
//// Selecting an extension for the running session is not instant. The daemon
//// answers a `select` with `queued` and finishes minutes later, after it has
//// retired the running native generation and staged the new one, and it
//// reports the end only to a caller that asks `status` with the request's
//// identity. A person should never see that identity. The lane therefore owns
//// it: this module mints one per request, remembers which candidate it was
//// for, says when the next `status` poll is due, and decides when the lane
//// stops waiting.
////
//// The tracker is data and the functions are pure, so the cadence and the
//// deadline are checked without a socket. `session_view/surfaces` sends what
//// `poll` names, `session_view/event_fold` feeds the replies to `answered` and
//// `refused`, and the board's own `pending` list repairs the tracker through
//// `restore` after a reconnect.
////
//// ## Flow
////
//// `begin` mints the identity and tracks the request as `Submitted`, which is
//// the interval before the daemon's first reply. `answered` moves the request
//// the lane is waiting on from that reply, and from each later status reply,
//// into `Staging`, `Publishing` or one of the four settled stages. `poll` names
//// the next request whose status is due and marks it awaiting; `expire` stops
//// the wait once a request's own deadline has passed. A settled request stays
//// in the tracker so a host can draw it until the next board arrives, and
//// `restore` is that arrival: it drops the settled requests and adopts the
//// board's waiting transitions that the tracker does not hold.
////
//// ## Transitions
////
//// | Stage | `answered` | `poll` | `expire` | `restore` |
//// | --- | --- | --- | --- | --- |
//// | `Submitted` | `Staging`, `Publishing` or a settled stage | never | `TimedOut` | kept |
//// | `Staging` | `Staging`, `Publishing` or a settled stage | due after the cadence | `TimedOut` | phase taken from the board |
//// | `Publishing` | `Publishing` or a settled stage | due after the cadence | `TimedOut` | kept |
//// | settled | unchanged | never | unchanged | dropped |
////
//// A reconnect loses the tracker's requests (`reset`) and keeps its counter, so
//// an identity is never minted twice by one lane. The next board lists the
//// transitions the daemon still holds, and `restore` tracks them again.

import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/evolution

/// How long after one reply the next `status` poll is due, in milliseconds.
pub const poll_ms = 2000

/// How long the lane waits for a selection, in milliseconds. The lane asks the
/// daemon for the same deadline in the request, so the daemon stops waiting
/// when the lane does. The daemon's bound is 120 seconds.
pub const window_ms = 60_000

/// The most requests tracked at once. The daemon holds one active job and
/// refuses a second with `Busy:`, so a lane reaches one unsettled request of its
/// own and at most one adopted from a board. The bound only keeps the tracker
/// finite under a daemon that is ahead of this client.
pub const limit = 16

/// The requests a lane is tracking.
pub type Tracker {
  Tracker(
    /// The tracked requests, oldest first.
    requests: List(Tracked),
    /// The request whose reply the lane is waiting for, whether the first
    /// reply to its `select` or the answer to one `status` poll. The lane has
    /// one command out at a time, so a reply belongs to this request.
    awaiting: Option(String),
    /// How many identities this lane has minted. It survives a reconnect, so a
    /// later request cannot reuse an earlier one's identity.
    minted: Int,
  )
}

/// One tracked request.
pub type Tracked {
  Tracked(
    /// The identity the lane minted and sent.
    request_id: String,
    /// The candidate being selected.
    candidate_id: String,
    /// The name it runs under, for the words.
    name: String,
    /// Where the request stands.
    stage: Stage,
    /// When the lane stops waiting, on the transport clock.
    deadline_ms: Int,
    /// When the next `status` poll is due, on the transport clock.
    next_poll_ms: Int,
  )
}

/// Where a tracked request stands.
pub type Stage {
  /// Sent, and the daemon has not answered yet.
  Submitted

  /// The daemon accepted it and has not finished.
  Staging(phase: evolution.Phase)

  /// Committed and durable, with the new generation not live yet.
  Publishing

  /// Done. The generation is the committed selection's, when the daemon named
  /// one.
  Landed(generation: Option(Int))

  /// The daemon reported that it failed, for this reason.
  Refused(reason: String)

  /// The daemon holds no record of the request.
  Vanished

  /// The lane's own deadline passed before the daemon finished.
  TimedOut
}

/// Whether `expire` stopped any wait, which is when the lane owes one more
/// read of the board.
pub type Expiry {
  /// At least one request ran out of time.
  Expired

  /// None did.
  NoneExpired
}

/// What the notice says when a wait ran out. The lane has read the board again,
/// so the row shows whatever the daemon holds now.
pub const timeout_words =
  "A selection did not finish in time. The board has been read again."

/// A tracker with nothing in it.
///
/// ## Examples
///
/// ```gleam
/// assert evolution_pending.new().requests == []
/// ```
pub fn new() -> Tracker {
  Tracker(requests: [], awaiting: None, minted: 0)
}

/// Forgets every request, as a reconnect does, and keeps the counter. The next
/// board lists the transitions the daemon still holds.
///
/// ## Examples
///
/// ```gleam
/// assert evolution_pending.reset(tracker).requests == []
/// ```
pub fn reset(tracker: Tracker) -> Tracker {
  Tracker(requests: [], awaiting: None, minted: tracker.minted)
}

/// Mints an identity and tracks a new request as `Submitted`. The lane then
/// waits for the daemon's first reply to it.
///
/// The identity is the session, the candidate, the transport clock and the
/// counter. The clock keeps a second lane on the same session from minting what
/// an earlier one did, and the counter keeps two requests in one millisecond
/// apart. A tracker already holding `limit` requests drops its oldest settled
/// request to make room, and refuses when none has settled.
///
/// A tracker that is still waiting for a reply refuses a new request, because
/// the reply that arrives belongs to the request it was awaited for and
/// `awaiting` names exactly one.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(#(tracker, id)) =
///   evolution_pending.begin(tracker, "0198c0de-0000", 5000, "3f9a0c2e1b", "fmt_check")
/// assert string.starts_with(id, "ui-0198c0de-")
/// ```
pub fn begin(
  tracker: Tracker,
  session_id: String,
  now_ms: Int,
  candidate_id: String,
  name: String,
) -> Result(#(Tracker, String), String) {
  use <- bool.guard(
    tracker.awaiting != None,
    Error("a reply is still awaited; wait for it"),
  )
  use room <- result.try(make_room(tracker.requests))
  let minted = tracker.minted + 1
  let request_id =
    string.join(
      [
        "ui",
        string.slice(session_id, 0, 8),
        int.to_string(int.absolute_value(now_ms)),
        string.slice(candidate_id, 0, 8),
        int.to_string(minted),
      ],
      "-",
    )
  let tracked =
    Tracked(
      request_id:,
      candidate_id:,
      name:,
      stage: Submitted,
      deadline_ms: now_ms + window_ms,
      next_poll_ms: now_ms + window_ms,
    )
  Ok(#(
    Tracker(
      requests: list.append(room, [tracked]),
      awaiting: Some(request_id),
      minted:,
    ),
    request_id,
  ))
}

/// Room for one more request. The oldest settled request goes first, since a
/// host has had the longest to draw it; when every request is still moving the
/// lane refuses rather than forget one it owes a poll.
fn make_room(requests: List(Tracked)) -> Result(List(Tracked), String) {
  case list.drop(requests, limit - 1) {
    [] -> Ok(requests)
    _ ->
      case list.find(requests, fn(tracked) { settled(tracked.stage) }) {
        Ok(oldest) ->
          Ok(list.filter(requests, fn(tracked) { tracked != oldest }))
        Error(Nil) -> Error("too many selections are staging; wait for one")
      }
  }
}

/// Whether a stage is the end of a request.
///
/// ## Examples
///
/// ```gleam
/// assert evolution_pending.settled(evolution_pending.TimedOut)
/// assert !evolution_pending.settled(evolution_pending.Submitted)
/// ```
pub fn settled(stage: Stage) -> Bool {
  case stage {
    Landed(..) | Refused(..) | Vanished | TimedOut -> True
    Submitted | Staging(..) | Publishing -> False
  }
}

/// Applies a reply to the request the lane was waiting on, and says which one
/// that was. A reply with no request awaiting, or one that arrives after the
/// request settled, changes nothing: the lane's one-command-at-a-time rule is
/// what makes a reply belong to `awaiting`, and a late one belongs to nobody.
///
/// ## Examples
///
/// ```gleam
/// let #(tracker, tracked) = evolution_pending.answered(tracker, evolution.Done(Some(4)), 7000)
/// assert tracked.stage == evolution_pending.Landed(Some(4))
/// ```
pub fn answered(
  tracker: Tracker,
  report: evolution.Report,
  now_ms: Int,
) -> #(Tracker, Option(Tracked)) {
  // Check whether a request was awaiting a response.
  case tracker.awaiting {
    None -> #(tracker, None)
    Some(id) -> {
      let cleared = Tracker(..tracker, awaiting: None)

      // Look up the awaited request in tracker state.
      case find(cleared, id) {
        Error(Nil) -> #(cleared, None)
        Ok(tracked) -> move_awaited(cleared, tracked, report, now_ms)
      }
    }
  }
}

/// Moves an awaiting request forward if it has not already settled.
fn move_awaited(
  tracker: Tracker,
  tracked: Tracked,
  report: evolution.Report,
  now_ms: Int,
) -> #(Tracker, Option(Tracked)) {
  // Ignore late replies for settled requests, or advance active stage.
  case settled(tracked.stage) {
    True -> #(tracker, None)
    False -> {
      let moved = advance(tracked, report, now_ms)
      #(replace(tracker, moved), Some(moved))
    }
  }
}

/// Transitions a tracked request stage based on an incoming evolution report.
fn advance(tracked: Tracked, report: evolution.Report, now_ms: Int) -> Tracked {
  let next_poll_ms = now_ms + poll_ms

  // Map report outcome to the appropriate tracking stage.
  case report {
    evolution.InFlight(phase:) ->
      Tracked(..tracked, stage: Staging(phase), next_poll_ms:)
    evolution.DurableOnly(..) ->
      Tracked(..tracked, stage: Publishing, next_poll_ms:)
    evolution.Done(generation:) -> Tracked(..tracked, stage: Landed(generation))
    evolution.Rejected(reason:) -> Tracked(..tracked, stage: Refused(reason))
    evolution.Forgotten -> Tracked(..tracked, stage: Vanished)
  }
}

/// Applies a refusal of the command the lane was waiting on. A refused `select`
/// never reached the queue, so its request is dropped and the host words the
/// refusal. A refused `status` poll leaves the request moving and asks again
/// after the cadence, until the request's own deadline ends the wait.
///
/// ## Examples
///
/// ```gleam
/// assert evolution_pending.refused(tracker, 7000).awaiting == None
/// ```
pub fn refused(tracker: Tracker, now_ms: Int) -> Tracker {
  // Check whether a request is awaiting response before handling refusal.
  case tracker.awaiting {
    None -> tracker
    Some(id) -> {
      let cleared = Tracker(..tracker, awaiting: None)

      // Drop submitted request on refusal or reschedule next poll.
      case find(cleared, id) {
        Error(Nil) -> cleared
        Ok(Tracked(stage: Submitted, ..)) ->
          Tracker(
            ..cleared,
            requests: list.filter(cleared.requests, fn(tracked) {
              tracked.request_id != id
            }),
          )
        Ok(tracked) ->
          replace(cleared, Tracked(..tracked, next_poll_ms: now_ms + poll_ms))
      }
    }
  }
}

/// Names the next request whose `status` is due, and marks it awaiting. Only
/// a request the daemon has answered at least once is polled, and only while
/// no other reply is awaited, since the lane has one command out at a time.
///
/// ## Examples
///
/// ```gleam
/// let assert Some(#(tracker, id)) = evolution_pending.poll(tracker, 9000)
/// ```
pub fn poll(tracker: Tracker, now_ms: Int) -> Option(#(Tracker, String)) {
  case tracker.awaiting {
    Some(_) -> None
    None ->
      case list.find(tracker.requests, fn(tracked) { due(tracked, now_ms) }) {
        Error(Nil) -> None
        Ok(tracked) ->
          Some(#(
            Tracker(..tracker, awaiting: Some(tracked.request_id)),
            tracked.request_id,
          ))
      }
  }
}

fn due(tracked: Tracked, now_ms: Int) -> Bool {
  case tracked.stage {
    Staging(..) | Publishing -> now_ms >= tracked.next_poll_ms
    Submitted | Landed(..) | Refused(..) | Vanished | TimedOut -> False
  }
}

/// Ends the wait of every request whose deadline has passed. When the awaited
/// request is one of them the lane stops expecting its reply, and a reply that
/// still arrives changes nothing. The lane reads the board once more when any
/// wait ended, so the host draws what the daemon holds now.
///
/// ## Examples
///
/// ```gleam
/// let #(tracker, expiry) = evolution_pending.expire(tracker, 70_000)
/// assert expiry == evolution_pending.Expired
/// ```
pub fn expire(tracker: Tracker, now_ms: Int) -> #(Tracker, Expiry) {
  let overdue = fn(tracked: Tracked) {
    !settled(tracked.stage) && now_ms >= tracked.deadline_ms
  }

  // Transition overdue requests to TimedOut if any reached deadline.
  case list.any(tracker.requests, overdue) {
    False -> #(tracker, NoneExpired)
    True -> {
      let requests =
        list.map(tracker.requests, fn(tracked) {
          case overdue(tracked) {
            True -> Tracked(..tracked, stage: TimedOut)
            False -> tracked
          }
        })

      // Clear awaiting request if it timed out.
      let awaiting = case tracker.awaiting {
        Some(id) ->
          case list.find(requests, fn(tracked) { tracked.request_id == id }) {
            Ok(Tracked(stage: TimedOut, ..)) | Error(Nil) -> None
            Ok(_) -> Some(id)
          }
        None -> None
      }

      #(Tracker(..tracker, requests:, awaiting:), Expired)
    }
  }
}

/// Repairs the tracker from a board that has just arrived. The board is the
/// daemon's current word, so settled requests are dropped, a request the board
/// lists takes its phase, and a waiting transition the tracker does not hold
/// (one this lane never saw, or one a reconnect made it forget) is tracked from
/// now with a fresh deadline. The board's own clock is never compared with the
/// lane's.
///
/// ## Examples
///
/// ```gleam
/// let tracker = evolution_pending.restore(evolution_pending.new(), board, 1000)
/// assert list.length(tracker.requests) == list.length(board.pending)
/// ```
pub fn restore(
  tracker: Tracker,
  board: evolution.Board,
  now_ms: Int,
) -> Tracker {
  let kept =
    tracker.requests
    |> list.filter(fn(tracked) { !settled(tracked.stage) })
    |> list.map(fn(tracked) { phase_from_board(tracked, board) })
  let adopted =
    board.pending
    |> list.filter(fn(waiting) {
      !list.any(kept, fn(tracked) { tracked.request_id == waiting.request_id })
    })
    |> list.map(fn(waiting) { adopt(waiting, board, now_ms) })
  let requests = list.take(list.append(kept, adopted), limit)

  // Retain awaiting request only if present in restored requests.
  let awaiting = case tracker.awaiting {
    Some(id) ->
      case list.any(requests, fn(tracked) { tracked.request_id == id }) {
        True -> Some(id)
        False -> None
      }
    None -> None
  }

  Tracker(..tracker, requests:, awaiting:)
}

/// A request the board lists takes the phase the board gives it. A request in
/// `Staging` that the board no longer lists has left the queue, and the board
/// says how it ended: if the candidate is now the selected one, the selection
/// committed, and it is live or still publishing as the board's selection says.
/// A candidate that is not selected is left as it was for the next status poll
/// to explain, since the board cannot say whether the request failed or is in
/// flight on a queue the board predates. `Submitted` and `Publishing` are never
/// moved backward by a board.
fn phase_from_board(tracked: Tracked, board: evolution.Board) -> Tracked {
  case
    list.find(board.pending, fn(row) { row.request_id == tracked.request_id }),
    tracked.stage
  {
    Ok(row), Submitted | Ok(row), Staging(..) ->
      Tracked(..tracked, stage: Staging(row.phase))
    Error(Nil), Staging(..) -> settled_by_board(tracked, board)
    _, _ -> tracked
  }
}

/// Reconciles completed staging requests against current selections on the board.
fn settled_by_board(tracked: Tracked, board: evolution.Board) -> Tracked {
  case evolution.find(board, tracked.candidate_id) {
    Ok(evolution.Candidate(selected: option.Some(chosen), ..)) ->
      case
        list.find(board.selections, fn(selection) {
          selection.candidate_id == tracked.candidate_id
        })
      {
        Ok(evolution.Selection(liveness: evolution.Live, ..)) ->
          Tracked(..tracked, stage: Landed(Some(chosen.generation)))
        _ -> Tracked(..tracked, stage: Publishing)
      }
    _ -> tracked
  }
}

/// Adopts an unseen waiting transition from the board into tracked state.
fn adopt(
  waiting: evolution.Waiting,
  board: evolution.Board,
  now_ms: Int,
) -> Tracked {
  // Resolve candidate name from board or fall back to empty string.
  let name = case evolution.find(board, waiting.candidate_id) {
    Ok(candidate) -> candidate.name
    Error(Nil) -> ""
  }

  Tracked(
    request_id: waiting.request_id,
    candidate_id: waiting.candidate_id,
    name:,
    stage: Staging(waiting.phase),
    deadline_ms: now_ms + window_ms,
    next_poll_ms: now_ms + poll_ms,
  )
}

/// The request tracked for a candidate, newest first, if any.
///
/// ## Examples
///
/// ```gleam
/// assert evolution_pending.for_candidate(tracker, "3f9a") == Some(tracked)
/// ```
pub fn for_candidate(
  tracker: Tracker,
  candidate_id: String,
) -> Option(Tracked) {
  tracker.requests
  |> list.reverse
  |> list.find(fn(tracked) { tracked.candidate_id == candidate_id })
  |> option.from_result
}

/// The earliest instant, on the transport clock, at which a tracked request
/// needs the lane's attention: the next poll or the deadline of one that is
/// still moving. `None` when nothing is moving. A host that sleeps between
/// events wakes then (`surfaces.evolution_due`).
///
/// ## Examples
///
/// ```gleam
/// assert evolution_pending.next_due(evolution_pending.new()) == None
/// ```
pub fn next_due(tracker: Tracker) -> Option(Int) {
  list.filter_map(tracker.requests, fn(tracked) {
    case tracked.stage {
      Submitted -> Ok(tracked.deadline_ms)
      Staging(..) | Publishing ->
        Ok(int.min(tracked.next_poll_ms, tracked.deadline_ms))
      Landed(..) | Refused(..) | Vanished | TimedOut -> Error(Nil)
    }
  })
  |> list.reduce(int.min)
  |> option.from_result
}

/// How many requests are still moving.
///
/// ## Examples
///
/// ```gleam
/// assert evolution_pending.active(evolution_pending.new()) == 0
/// ```
pub fn active(tracker: Tracker) -> Int {
  list.count(tracker.requests, fn(tracked) { !settled(tracked.stage) })
}

/// The words for a request's stage, for the row of the candidate it was for.
/// The time left is the lane's own deadline, in whole seconds.
///
/// ## Examples
///
/// ```gleam
/// assert evolution_pending.words(staging_row, 12_000) == "fmt_check: staging, 48 s left"
/// ```
pub fn words(tracked: Tracked, now_ms: Int) -> String {
  // Pick explicit candidate name or fall back to short candidate id.
  let name = case tracked.name {
    "" -> evolution.short_id(tracked.candidate_id)
    name -> name
  }

  let left = int.max(0, tracked.deadline_ms - now_ms) / 1000

  // Format status string based on the current tracking stage.
  case tracked.stage {
    Submitted -> name <> ": sending the request"
    Staging(evolution.Queued) ->
      name <> ": queued, " <> int.to_string(left) <> " s left"
    Staging(evolution.Running) ->
      name <> ": staging, " <> int.to_string(left) <> " s left"
    Staging(evolution.UnknownPhase(phase:)) ->
      name <> ": " <> phase <> ", " <> int.to_string(left) <> " s left"
    Publishing ->
      name <> ": committed, publishing, " <> int.to_string(left) <> " s left"
    Landed(Some(generation)) ->
      name <> ": generation " <> int.to_string(generation) <> " is live"
    Landed(None) -> name <> ": selected"
    Refused(reason:) -> name <> ": the selection failed: " <> reason
    Vanished -> name <> ": the daemon no longer holds this request"
    TimedOut -> name <> ": still not finished; the board has been read again"
  }
}

fn find(tracker: Tracker, id: String) -> Result(Tracked, Nil) {
  list.find(tracker.requests, fn(tracked) { tracked.request_id == id })
}

/// Replaces an existing tracked request in the tracker list by its request_id.
fn replace(tracker: Tracker, moved: Tracked) -> Tracker {
  Tracker(
    ..tracker,
    requests: list.map(tracker.requests, fn(tracked) {
      case tracked.request_id == moved.request_id {
        True -> moved
        False -> tracked
      }
    }),
  )
}
