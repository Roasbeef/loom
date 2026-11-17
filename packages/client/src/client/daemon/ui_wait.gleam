//// How a live page of a session on another orchestrator waits out a dropped
//// link without ending its socket (protocol-change/108, "When the link
//// drops, and what the page shows").
////
//// A page's component keeps the last cut it drew when its lane ends, and draws
//// the waiting notice over it. The browser used to reconnect the moment the
//// socket closed, and a reconnect starts a fresh component with nothing in it,
//// so the page lost every panel to say it was waiting. It also made one
//// abnormal socket exit per attempt, because mist ends a socket with the close
//// code that asks for a retry only by exiting abnormally, and the supervisor
//// logs each such exit as a crash report.
////
//// This module is the other order of events. The socket stays open, so the page
//// keeps what it drew, and one run asks the orchestrator whether it answers
//// again, pausing between asks and doubling the pause up to a limit. The socket
//// closes with the retry code once, when the orchestrator answers, and the
//// browser's reconnect then finds an orchestrator that can take the attach.
////
//// ## What the question is
////
//// The caller supplies it as `Reach`. It is a read the orchestrator answers
//// without making anything on its box (`top_relay.placements`), so asking it
//// repeatedly leaves no feed behind. An answer of any kind, including a
//// refusal, means the box is reachable, and the next attach decides what the
//// page draws.
////
//// ## Bounds
////
//// The run stops asking after `max_wait_ms`, which is the length of a UI
//// session, and then closes the socket as an answer would, so the reconnect
//// meets the page's real standing. It is linked to the process that started it,
//// the page's socket, so a page that goes away takes the run with it.
////
//// ## Flow
////
//// `start` → `start_with` → `attempt` → `reach_of`
////
//// 1. `start` waits with the production timing.
//// 2. `start_with` runs the polling loop in a weft run and reports the end of
////    the wait once.
//// 3. `attempt` turns one answer of the question into the loop's step, and
////    `reach_of` words a relay call's result as that answer.

import client/remote/top_relay
import weft
import weft/poll

/// The first pause between two asks, in milliseconds.
pub const first_pause_ms = 1000

/// The longest pause between two asks, in milliseconds. A box that stays down
/// is asked about once in this long, which is far fewer reports than the
/// browser's own retries made.
pub const longest_pause_ms = 8000

/// The longest a page waits for its orchestrator before it closes anyway, in
/// milliseconds. It is the eight hours a UI session lasts.
pub const max_wait_ms = 28_800_000

/// How long past `max_wait_ms` the run may take before it is abandoned. One ask
/// may run for the relay's whole call budget after the last pause.
const slack_ms = 20_000

/// Whether the orchestrator answered the question.
pub type Reach {
  /// The orchestrator answered, whatever it said.
  Answering

  /// The orchestrator did not answer: it could not be connected to, or it was
  /// connected and said nothing.
  Silent
}

/// How a wait paces itself and how long it lasts.
pub type Timing {
  Timing(
    /// The pause before the second ask. The first ask is made at once, since a
    /// feed that lapsed on a box that is up needs no waiting.
    first_pause_ms: Int,
    /// The longest pause the doubling reaches.
    longest_pause_ms: Int,
    /// How long the run asks before it gives up and reports as if answered.
    max_wait_ms: Int,
  )
}

/// The timing a daemon uses.
///
/// ## Examples
///
/// ```gleam
/// assert ui_wait.production().first_pause_ms == 1000
/// ```
pub fn production() -> Timing {
  Timing(first_pause_ms:, longest_pause_ms:, max_wait_ms:)
}

/// Waits for the orchestrator with the production timing: asks `awaiting` at
/// once and then at doubling pauses, and calls `done` once when it answers or
/// the wait is over. `done` is called from the run, so it must only hand the
/// news to the socket's mailbox.
///
/// ## Examples
///
/// ```gleam
/// // ui_wait.start(fn() { ui_wait.Answering }, fn() { process.send(signals, Stop(Retry)) })
/// ```
pub fn start(awaiting: fn() -> Reach, done: fn() -> Nil) -> Nil {
  start_with(production(), awaiting, done)
}

/// `start` with the timing a test shortens.
///
/// ## Examples
///
/// ```gleam
/// // ui_wait.start_with(Timing(10, 40, 1000), fn() { ui_wait.Silent }, notify)
/// ```
pub fn start_with(
  timing: Timing,
  awaiting: fn() -> Reach,
  done: fn() -> Nil,
) -> Nil {
  let _ =
    weft.new([
      fn() {
        let _ =
          poll.until_on(
            clock: poll.monotonic(),
            within: timing.max_wait_ms,
            every: poll.Doubling(
              from: timing.first_pause_ms,
              to: timing.longest_pause_ms,
            ),
            attempt: fn() { attempt(awaiting()) },
          )
        done()
        Ok(Nil)
      },
    ])
    |> weft.deadline(timing.max_wait_ms + slack_ms)
    |> weft.start_witnessed
  Nil
}

/// One answer of the question as a step of the loop.
///
/// ## Examples
///
/// ```gleam
/// assert ui_wait.attempt(ui_wait.Answering) == poll.Done(Nil)
/// ```
pub fn attempt(reach: Reach) -> poll.Attempt(Nil, Nil) {
  case reach {
    Answering -> poll.Done(Nil)
    Silent -> poll.Retry
  }
}

/// What a call to the orchestrator says about whether it is reachable. A
/// connection that could not be made, an answer that never came and a peer that
/// changed under the call are silence. Everything else, a refusal included, is
/// an answer, since the box spoke and the next attach decides what the page
/// draws.
///
/// ## Examples
///
/// ```gleam
/// assert ui_wait.reach_of(Error(top_relay.Unreachable)) == ui_wait.Silent
/// assert ui_wait.reach_of(Error(top_relay.Unsupported)) == ui_wait.Answering
/// ```
pub fn reach_of(answer: Result(a, top_relay.Failure)) -> Reach {
  case answer {
    Ok(_)
    | Error(top_relay.NotConfigured(_))
    | Error(top_relay.OlderBuild)
    | Error(top_relay.Refused(_))
    | Error(top_relay.Unsupported)
    | Error(top_relay.InvalidPeer)
    | Error(top_relay.RequestTooLarge)
    | Error(top_relay.Unreadable(_)) -> Answering
    Error(top_relay.Unreachable)
    | Error(top_relay.Silent)
    | Error(top_relay.PeerChanged) -> Silent
  }
}
