//// Replay retains only the visible attachment and one provisional candidate.
////
//// The same channel reducer validates real and recorded bytes. This module
//// contributes only local attempt custody and issued-request ordering; it
//// never manufactures a socket, sends a frame or advances a wall clock.

import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import tui/attempt
import tui/connection
import tui/session_channel
import tui/snapshot
import tui/snapshot_view

type Credit {
  NotIssued
  Issued
}

type Lane {
  Lane(
    id: attempt.Id,
    channel: session_channel.Channel,
    credit: Credit,
    last_request: Int,
    captured: Option(#(snapshot.Captured, snapshot_view.View)),
  )
}

/// At most two protocol buffers; retired identities require no retained map.
pub opaque type State {
  State(current: Option(Lane), candidate: Option(Lane), latest: Int)
}

/// A visible adoption or update from the currently adopted attempt only.
pub type Change {
  /// A fully validated candidate replaces the visible session atomically.
  Adopt(cut: snapshot.Captured, view: snapshot_view.View)

  /// A subsequent response belongs to the still-current attempt.
  Update(update: session_channel.Update)

  /// A local replacement failure does not replace the visible attachment.
  Rejected(reason: String)
}

/// Starts an effect-free replay with no adopted or provisional connection.
///
/// ## Examples
///
/// ```gleam
/// let state = attempt_replay.new()
/// ```
pub fn new() -> State {
  State(None, None, 0)
}

/// Applies one local fact, rejecting overlap and missing request credits.
///
/// Late traffic from an already retired identity is ignored without retaining
/// its transfer. A future or never-started identity is a malformed recording.
///
/// ## Examples
///
/// ```gleam
/// // attempt_replay.apply(state, event)
/// ```
pub fn apply(
  state: State,
  event: attempt.Event,
) -> Result(#(State, List(Change)), String) {
  case event {
    attempt.Started(attempt.Id(id) as key, expected) -> {
      use <- bool.guard(
        id <= state.latest || state.candidate != None,
        Error("overlapping or reused recording attempt"),
      )
      let lane = Lane(key, session_channel.replay(expected), NotIssued, 0, None)
      Ok(#(State(..state, candidate: Some(lane), latest: id), []))
    }
    attempt.Adopted(id) -> adopt(state, id)
    attempt.Closed(id) -> retire(state, id)
    attempt.Failed(attempt.Id(value) as id, reason) -> {
      let next =
        State(
          ..state,
          latest: int.max(state.latest, value),
          candidate: remove(state.candidate, id),
        )
      Ok(#(next, [Rejected(reason)]))
    }
    attempt.Issued(id, _) | attempt.Received(id, _) -> advance(state, id, event)
  }
}

fn adopt(state: State, id) {
  case state.candidate {
    Some(Lane(id: candidate, captured: Some(#(cut, view)), ..) as lane)
      if candidate == id
    -> {
      use <- bool.guard(
        !session_channel.replay_adoptable(lane.channel),
        Error("adoption requires completed nonfailed protocol state"),
      )
      Ok(
        #(State(..state, current: Some(lane), candidate: None), [
          Adopt(cut, view),
        ]),
      )
    }
    Some(_) | None -> Error("adoption precedes a validated candidate cut")
  }
}

fn retire(state: State, id: attempt.Id) {
  let attempt.Id(value) = id
  use <- bool.guard(
    value > state.latest,
    Error("closing an unknown recording attempt"),
  )

  // Only the visible lane can carry an acknowledged local submission. A
  // recorded local close preserves its uncertainty just like live replacement;
  // an unadopted candidate still has no visible command outcome to publish.
  let updates = case state.current {
    Some(lane) if lane.id == id -> {
      let #(_, updates) =
        session_channel.retire(lane.channel, "attachment replaced")
      list.map(updates, Update)
    }
    Some(_) | None -> []
  }
  Ok(#(
    State(
      ..state,
      current: remove(state.current, id),
      candidate: remove(state.candidate, id),
    ),
    updates,
  ))
}

fn remove(lane, id) {
  case lane {
    Some(Lane(id: found, ..)) if found == id -> None
    Some(_) | None -> lane
  }
}

fn advance(state: State, id: attempt.Id, event) {
  case state.current, state.candidate {
    Some(Lane(id: found, ..) as lane), _ if found == id -> {
      use #(lane, updates) <- result.map(advance_lane(lane, event))
      #(State(..state, current: Some(lane)), list.map(updates, Update))
    }
    _, Some(Lane(id: found, ..) as lane) if found == id -> {
      use #(lane, _) <- result.map(advance_lane(lane, event))
      #(State(..state, candidate: Some(lane)), [])
    }
    _, _ -> {
      let attempt.Id(value) = id
      case value <= state.latest {
        True -> Ok(#(state, []))
        False -> Error("traffic from an unknown recording attempt")
      }
    }
  }
}

fn advance_lane(lane: Lane, event) {
  case event {
    attempt.Issued(_, request) -> {
      use <- bool.guard(
        lane.credit == Issued || request.id <= lane.last_request,
        Error("recorded request overlaps an unanswered request"),
      )
      use channel <- result.map(session_channel.replay_issued(
        lane.channel,
        request,
      ))
      #(
        Lane(..lane, channel: channel, credit: Issued, last_request: request.id),
        [],
      )
    }
    attempt.Received(_, connection.Incoming(_) as message) -> {
      use <- bool.guard(
        lane.credit != Issued,
        Error("recorded response has no issued request credit"),
      )
      received(lane, message)
    }
    attempt.Received(_, message) -> received(lane, message)
    attempt.Started(..)
    | attempt.Adopted(_)
    | attempt.Closed(_)
    | attempt.Failed(..) -> Error("unexpected recording lifetime event")
  }
}

fn received(lane: Lane, message) {
  let #(channel, updates) = session_channel.receive(lane.channel, message)
  let captured =
    list.fold(updates, lane.captured, fn(previous, update) {
      case update {
        session_channel.Captured(cut, view, _) -> Some(#(cut, view))
        _ -> previous
      }
    })
  let credit = case message {
    connection.Connected -> lane.credit
    connection.Incoming(_)
    | connection.Closed(_)
    | connection.NetworkFault(_) -> NotIssued
  }
  Ok(#(
    Lane(..lane, channel: channel, credit: credit, captured: captured),
    updates,
  ))
}
