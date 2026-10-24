//// The last page of an orchestrator's sessions that this daemon read for its
//// pages (protocol-change/094, "When the link drops").
////
//// Nothing about a relayed session is durable on the laptop. The box holds the
//// session, and a page that is open asks for the list again every five seconds
//// (`refresh`). This module is what several open pages share between two asks:
//// the last list that was read, when it was read, and, if the latest ask failed,
//// why and since when. A page that finds the box unreachable draws the last list
//// greyed with "seen 2m ago", and a laptop that restarts loses nothing, because
//// the first ask afterwards reads the box again.
////
//// ## The asking happens in the caller
////
//// `refresh` reads in the calling process, under the relay's own deadlines, and
//// then tells the keeper what it found. The keeper is only a cache: it holds the
//// last good rows and the standing of the latest ask, and answers `latest` at
//// once without waiting for a read that is in flight. Two pages that refresh at
//// the same moment read twice, which costs the box one more page and keeps this
//// module free of a queue of waiters.
////
//// ## A failed ask keeps the rows
////
//// An ask that fails leaves the rows it had, marks them stale, and remembers when
//// the failures began, so the age the page shows is the age of the data and not
//// of the failure. The next ask that succeeds replaces the rows and clears the
//// mark. A box that is simply slow is `Silent`, and is stale in the same way.
////
//// ## Flow
////
//// `start` → `refresh` → `latest`
////
//// 1. `start` begins the keeper for one orchestrator.
//// 2. `refresh` reads every page of the orchestrator's sessions through the
////    relay, records the outcome, and answers what the page should draw.
//// 3. `latest` answers what the keeper holds, without asking the box.

import client/remote/top_relay.{type Failure, type Relay}
import client/remote_top.{type Row}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import weft/actor

/// How the rows in a snapshot stand.
pub type Standing {
  /// The latest ask succeeded, so the rows are what the box said then.
  Current

  /// The latest ask failed. The rows are the last good ones, if there were any.
  Stale(
    /// Why the latest ask failed.
    why: Failure,
    /// When the failures began, in Unix milliseconds, so that the page can say
    /// how long the box has been out of reach.
    since_ms: Int,
  )
}

/// What a page draws.
pub type Snapshot {
  Snapshot(
    /// The last good rows, newest first. Empty before any ask has succeeded.
    rows: List(Row),
    /// When they were read, in Unix milliseconds, or `None` before any ask has
    /// succeeded.
    seen_ms: Option(Int),
    /// How they stand.
    standing: Standing,
  )
}

/// The keeper of one orchestrator's last page.
pub opaque type View {
  View(keeper: Subject(Message))
}

type Message {
  Found(rows: List(Row), at_ms: Int)
  Missed(why: Failure, at_ms: Int)
  Latest(reply: Subject(Snapshot))
}

/// Starts a keeper that has read nothing. Until an ask succeeds its snapshot has
/// no rows and no time, and is `Current`: nothing is known to be wrong.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(view) = top_view.start()
/// ```
pub fn start() -> Result(View, String) {
  let started =
    actor.new(Snapshot(rows: [], seen_ms: None, standing: Current))
    |> actor.on_message(fn(held, message) {
      // This match resolves message before the surrounding protocol step continues.
      // This match resolves message before the enclosing validation continues.
      case message {
        Found(rows:, at_ms:) ->
          actor.continue(Snapshot(
            rows:,
            seen_ms: Some(at_ms),
            standing: Current,
          ))
        Missed(why:, at_ms:) ->
          actor.continue(Snapshot(..held, standing: stale(held, why, at_ms)))
        Latest(reply:) -> {
          process.send(reply, held)
          actor.continue(held)
        }
      }
    })
    |> actor.start

  // This match resolves started before the surrounding protocol step continues.
  // This match resolves started before the enclosing validation continues.
  case started {
    Ok(running) -> Ok(View(keeper: running.data))
    Error(_) -> Error("the relay view did not start")
  }
}

// A failure that follows a failure keeps the time the first one began, so the
// age a page shows is how long the box has been out of reach.
/// Stale keeps this client operation’s decoding or state decision in one place.
fn stale(held: Snapshot, why: Failure, at_ms: Int) -> Standing {
  // This match resolves held.standing before the surrounding protocol step continues.
  // This match resolves held.standing before the enclosing validation continues.
  case held.standing {
    Stale(since_ms:, ..) -> Stale(why:, since_ms:)
    Current -> Stale(why:, since_ms: at_ms)
  }
}

/// Reads every page of the orchestrator's sessions through the relay, in the
/// calling process, records what it found, and answers what a page should draw.
/// `now_ms` is the daemon's clock in Unix milliseconds.
///
/// ## Examples
///
/// ```gleam
/// // top_view.refresh(view, relay, "box", ffi_os.system_time_ms)
/// ```
pub fn refresh(
  view: View,
  relay: Relay,
  orchestrator: String,
  now_ms: fn() -> Int,
) -> Snapshot {
  // This match resolves top_relay.all_sessions(relay, orchestrator) before the surrounding protocol step continues.
  // This match resolves top_relay.all_sessions(relay, orchestrator) before the enclosing validation continues.
  case top_relay.all_sessions(relay, orchestrator) {
    Ok(rows) -> process.send(view.keeper, Found(rows:, at_ms: now_ms()))
    Error(why) -> process.send(view.keeper, Missed(why:, at_ms: now_ms()))
  }

  latest(view)
}

/// What the keeper holds, without asking the box. The answer reflects every
/// outcome `refresh` recorded before the call, because the keeper takes its
/// messages in the order they were sent from one process.
///
/// ## Examples
///
/// ```gleam
/// // top_view.latest(view).rows
/// ```
pub fn latest(view: View) -> Snapshot {
  process.call(view.keeper, waiting: 1000, sending: Latest)
}
