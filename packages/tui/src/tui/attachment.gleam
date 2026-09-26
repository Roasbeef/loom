//// A replacement stays provisional until the terminal validates its first cut.
////
//// The Weft task owns connection startup and remains alive while the terminal
//// consumes credit. The terminal owns both input subjects from the beginning;
//// the worker only creates an acknowledgement subject which the terminal
//// writes. A normal acknowledged task exit permits guardian adoption. Failure
//// leaves the old connection untouched and cancels only this attempt.

import gleam/erlang/process.{type Selector, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tui/attempt
import tui/connection
import tui/protocol
import tui/session_channel as channel
import tui/sessions
import tui/snapshot
import tui/snapshot_view
import tui/workspace
import weft

/// Authenticated selection resolved by explicit control open, never by listing.
pub type Target {
  Target(
    /// V2 conversation route for exactly the selected session.
    address: String,
    /// Bearer credential, never included in diagnostics.
    token: String,
    /// Expected session, daemon epoch and runtime incarnation.
    expected: snapshot.Expected,
    /// Canonical workspace returned by the authorized catalogue record.
    workspace: workspace.Context,
    /// Display name from the authorized catalogue, adopted with this identity.
    session_name: String,
    /// Only successful adoption of this creation may clear its retained key.
    creation_key: Option(String),
  )
}

type Prepared {
  Prepared(
    connection.Connection,
    snapshot.Expected,
    workspace.Context,
    String,
    Option(String),
    Subject(Nil),
  )
}

/// Typed selected traffic for a terminal hosted by a Weft actor test driver.
///
/// The source subject identifies its attempt; stale events cannot advance a
/// replacement with coincidentally equal transport request identifiers.
pub opaque type Event {
  Preparation(source: Subject(Prepared), message: Prepared)
  Frame(source: Subject(connection.Message), message: connection.Message)
  Settled(
    source: Subject(weft.Pulled(Nil, String)),
    outcome: weft.Pulled(Nil, String),
  )
}

type Run {
  Run(
    cancel: weft.Cancel,
    outcomes: Subject(weft.Pulled(Nil, String)),
    trace: Option(attempt.Trace),
  )
}

type Candidate {
  Candidate(
    channel: channel.Channel,
    acknowledgement: Subject(Nil),
    captured: Option(#(snapshot.Captured, snapshot_view.View)),
    workspace: workspace.Context,
    /// Display name from the authorized catalogue, adopted with this identity.
    session_name: String,
    creation_key: Option(String),
  )
}

/// One provisional lifetime, with terminal-owned mailboxes and no extra actor.
pub opaque type Status {
  Idle
  Opening(
    run: Run,
    prepared: Subject(Prepared),
    frames: Subject(connection.Message),
    candidate: Option(Candidate),
  )
}

/// Only Adopted is allowed to replace the visible connection and transcript.
pub type Outcome {
  /// Initial capture and original worker completion have both been observed.
  Adopted(
    channel: channel.Channel,
    cut: snapshot.Captured,
    view: snapshot_view.View,
    inbox: Subject(connection.Message),
    workspace: workspace.Context,
    /// Display name from the authorized catalogue, adopted with this identity.
    session_name: String,
    creation_key: Option(String),
  )

  /// No visible state should be replaced on failure.
  Failed(reason: String)
}

/// The absence of a replacement attempt.
///
/// ## Examples
///
/// ```gleam
/// let pending = attachment.idle()
/// ```
pub fn idle() -> Status {
  Idle
}

/// Reports whether a single candidate already owns the switch slot.
///
/// ## Examples
///
/// ```gleam
/// assert !attachment.busy(attachment.idle())
/// ```
pub fn busy(status: Status) -> Bool {
  status != Idle
}

/// Starts bounded explicit selection; resolve runs outside the terminal.
///
/// The same deadline includes control open, socket handshake and initial cut.
///
/// ## Examples
///
/// ```gleam
/// // attachment.start(fn() { select_session(control, id) }, 90_000)
/// ```
pub fn start(
  resolve: fn() -> Result(Target, String),
  within_ms: Int,
) -> Status {
  start_recorded(resolve, within_ms, None)
}

/// Associates recorder custody before the terminal can consume prepared frames.
///
/// ## Examples
///
/// ```gleam
/// // attachment.start_recorded(resolve, 90_000, trace)
/// ```
pub fn start_recorded(
  resolve: fn() -> Result(Target, String),
  within_ms: Int,
  trace: Option(attempt.Trace),
) -> Status {
  let frames = connection.new_inbox()
  let prepared = process.new_subject()
  let cancel = weft.cancel_signal()
  let outcomes = process.new_subject()
  let _relay =
    weft.new([
      fn() {
        use target <- result.try(resolve())
        use socket <- result.try(connection.connect(
          target.address,
          target.token,
          frames,
        ))
        let acknowledged = process.new_subject()
        process.send(
          prepared,
          Prepared(
            socket,
            target.expected,
            target.workspace,
            target.session_name,
            target.creation_key,
            acknowledged,
          ),
        )
        case process.receive(acknowledged, within_ms) {
          Ok(Nil) -> Ok(Nil)
          Error(Nil) -> {
            connection.close(socket)
            Error("initial conversation capture was not acknowledged")
          }
        }
      },
    ])
    |> weft.deadline(within_ms)
    |> weft.cancel_with(cancel)
    |> weft.start_relayed(outcomes)
  Opening(Run(cancel, outcomes, trace), prepared, frames, None)
}

/// Binds the recorder after launch but before any terminal poll can consume data.
///
/// A worker may already have queued Prepared; only the terminal constructs the
/// channel, so even a fast local server cannot consume an unrecorded first cut.
///
/// ## Examples
///
/// ```gleam
/// // attachment.with_trace(pending, trace)
/// ```
pub fn with_trace(status: Status, trace: Option(attempt.Trace)) -> Status {
  case status {
    Opening(run, prepared, frames, None) ->
      Opening(Run(..run, trace: trace), prepared, frames, None)
    Idle | Opening(_, _, _, Some(_)) -> status
  }
}

/// Advances at most forty credited messages during one terminal tick.
///
/// The poll still receives from the attempt's own mailboxes, but it performs
/// nothing it decided: the worker's acknowledgement and a failed attempt's
/// cleanup come back as outputs, oldest first, for the caller to queue. The
/// provisional channel's writes stay on it until `take_outputs`. `now` is
/// the transport reading the candidate channel's deadlines are measured
/// against, as for the adopted channel.
///
/// ## Examples
///
/// ```gleam
/// // let #(pending, outcome, outputs) = attachment.poll(pending, now:)
/// ```
pub fn poll(
  status: Status,
  now now: Int,
) -> #(Status, Option(Outcome), List(Out)) {
  case status {
    Idle -> #(Idle, None, [])
    Opening(run, prepared, frames, candidate) -> {
      let candidate = prepare(prepared, candidate, run.trace, now)
      case progress(candidate, frames, now) {
        Error(reason) ->
          failed(Opening(run, prepared, frames, candidate), reason)
        Ok(advanced) ->
          settle(Opening(run, prepared, frames, advanced))
          |> acknowledging(candidate, advanced)
      }
    }
  }
}

/// Adds only this attempt's terminal-owned inputs to an existing selector.
///
/// ## Examples
///
/// ```gleam
/// // attachment.select(pending, process.new_selector(), CandidateEvent)
/// ```
pub fn select(
  status: Status,
  selector: Selector(a),
  tag: fn(Event) -> a,
) -> Selector(a) {
  case status {
    Idle -> selector
    Opening(run, prepared, frames, _) ->
      selector
      |> process.select_map(prepared, fn(message) {
        tag(Preparation(prepared, message))
      })
      |> process.select_map(frames, fn(message) { tag(Frame(frames, message)) })
      |> process.select_map(run.outcomes, fn(outcome) {
        tag(Settled(run.outcomes, outcome))
      })
  }
}

/// Applies already selected traffic before draining any later mailbox message.
///
/// Like `poll`, it returns what it decided rather than performing it, and
/// it measures the candidate channel's deadlines against `now`.
///
/// ## Examples
///
/// ```gleam
/// // let #(pending, outcome, outputs) = attachment.accept(pending, event, now:)
/// ```
pub fn accept(
  status: Status,
  event: Event,
  now now: Int,
) -> #(Status, Option(Outcome), List(Out)) {
  case status, event {
    Opening(run, _, _, _), Settled(source, outcome) if source == run.outcomes ->
      apply_outcome(status, outcome)
    Opening(run, prepared, frames, None),
      Preparation(source, Prepared(socket, expected, workspace, name, key, ack))
      if prepared == source
    ->
      settle(Opening(
        run,
        prepared,
        frames,
        Some(Candidate(
          channel.start_recorded(socket, expected, run.trace, now:),
          ack,
          None,
          workspace,
          name,
          key,
        )),
      ))

    // The same guard `progress` and `drain` apply: once the initial cut is
    // captured the channel is `Ready`, and handing it another frame makes it
    // answer "unsolicited conversation response" and abort an attempt the
    // interactive loop would have adopted. The interactive loop leaves such a
    // frame queued for the adopted terminal; a driver has already taken it out
    // of the mailbox, so here it is dropped instead — the adopted channel's
    // 250 ms credited `catch_up` is what makes that lossless.
    Opening(
      run,
      prepared,
      frames,
      Some(Candidate(captured: None, ..) as candidate),
    ),
      Frame(source, message)
      if frames == source
    -> {
      let #(next, updates) = channel.receive(candidate.channel, message, now:)
      case apply_updates(Candidate(..candidate, channel: next), updates) {
        Ok(advanced) ->
          settle(Opening(run, prepared, frames, Some(advanced)))
          |> acknowledging(Some(candidate), Some(advanced))
        Error(reason) -> failed(status, reason)
      }
    }
    _, Preparation(_, Prepared(socket, _, _, _, _, _)) -> #(status, None, [
      CloseStray(socket),
    ])
    _, Frame(_, _) | _, Settled(_, _) -> #(status, None, [])
  }
}

// The worker waits for exactly one reply: that the terminal holds its
// initial cut. It is owed at the advance where the cut is first captured, so
// it is read off that transition rather than off the `Captured` update, and
// it goes ahead of whatever the same advance then settled. An advance that
// captured and failed at once owes nothing, since its cleanup cancels the
// worker that was waiting.
fn acknowledging(
  settled: #(Status, Option(Outcome), List(Out)),
  before: Option(Candidate),
  after: Option(Candidate),
) -> #(Status, Option(Outcome), List(Out)) {
  let #(status, outcome, outputs) = settled
  case before, after {
    Some(Candidate(captured: None, ..)),
      Some(Candidate(captured: Some(_), acknowledgement:, ..))
    -> #(status, outcome, [Acknowledge(acknowledgement), ..outputs])
    None, _
    | Some(Candidate(captured: Some(_), ..)), _
    | Some(Candidate(captured: None, ..)), None
    | Some(Candidate(captured: None, ..)), Some(Candidate(captured: None, ..))
    -> settled
  }
}

fn prepare(prepared, candidate, trace, now: Int) {
  case candidate {
    Some(_) -> candidate
    None ->
      case process.receive(prepared, 0) {
        Error(Nil) -> None
        Ok(Prepared(socket, expected, workspace, name, key, acknowledgement)) ->
          Some(Candidate(
            channel.start_recorded(socket, expected, trace, now:),
            acknowledgement,
            None,
            workspace,
            name,
            key,
          ))
      }
  }
}

fn progress(candidate, frames, now: Int) {
  case candidate {
    None -> Ok(None)
    Some(Candidate(captured: Some(_), ..)) -> Ok(candidate)
    Some(candidate) -> {
      use candidate <- result.try(drain(candidate, frames, 40, now))
      let #(next, updates) = channel.tick(candidate.channel, now:)
      apply_updates(Candidate(..candidate, channel: next), updates)
      |> result.map(Some)
    }
  }
}

fn drain(candidate: Candidate, frames, remaining, now: Int) {
  case remaining <= 0, candidate.captured {
    True, _ | _, Some(_) -> Ok(candidate)
    False, None ->
      case process.receive(frames, 0) {
        Error(Nil) -> Ok(candidate)
        Ok(message) -> {
          let #(next, updates) =
            channel.receive(candidate.channel, message, now:)
          use candidate <- result.try(apply_updates(
            Candidate(..candidate, channel: next),
            updates,
          ))
          drain(candidate, frames, remaining - 1, now)
        }
      }
  }
}

fn apply_updates(candidate: Candidate, updates) {
  case updates {
    [] -> Ok(candidate)
    [channel.Captured(cut, view, _), ..rest] ->
      apply_updates(Candidate(..candidate, captured: Some(#(cut, view))), rest)
    [channel.Failed(reason), ..] -> Error(reason)

    // A candidate has no view to stream into yet, and a fragment pushed
    // during its initial capture is superseded by the capture itself. A
    // notice or usage observation says the same thing about durable state
    // and is dropped for the same reason: the candidate's own capture is
    // already fetching it. The adopted lane is where these pushes matter.
    [channel.Streamed(..), ..rest]
    | [channel.ToolStreamed(..), ..rest]
    | [channel.Noticed(_), ..rest]
    | [channel.Auxiliary(protocol.UsageChanged(..)), ..rest] ->
      apply_updates(candidate, rest)
    [channel.Auxiliary(_), ..]
    | [channel.RequestRefused(..), ..]
    | [channel.Submission(_), ..]
    | [channel.HistoryPage(..), ..]
    | [channel.LookedUp(..), ..]
    | [channel.Acknowledged(..), ..]
    | [channel.UnknownOutcome(..), ..] ->
      Error("unexpected command result during initial capture")
  }
}

fn settle(status: Status) -> #(Status, Option(Outcome), List(Out)) {
  case status {
    Idle -> #(Idle, None, [])
    Opening(run, _, _, _) ->
      case process.receive(run.outcomes, 0) {
        Error(Nil) -> #(status, None, [])
        Ok(outcome) -> apply_outcome(status, outcome)
      }
  }
}

fn apply_outcome(
  status: Status,
  outcome,
) -> #(Status, Option(Outcome), List(Out)) {
  case status {
    Idle -> #(Idle, None, [])
    Opening(_, _, frames, candidate) ->
      case outcome {
        weft.NotYet -> #(status, None, [])
        weft.PulledOutcome(weft.Completed(..)) -> #(status, None, [])
        weft.AllDelivered -> adopt(status, candidate, frames)
        weft.PulledOutcome(weft.Failed(error: reason, ..)) ->
          failed(status, reason)
        weft.PulledOutcome(weft.Crashed(reason:, ..))
        | weft.PulledOutcome(weft.DrainProofLost(reason:, ..))
        | weft.RunLost(reason:) -> failed(status, string.inspect(reason))
        weft.PulledOutcome(weft.Abandoned(..))
        | weft.PulledOutcome(weft.NeverStarted(..))
        | weft.PulledOutcome(weft.CancellationUnconfirmed(..)) ->
          failed(
            status,
            "conversation replacement did not complete within its deadline",
          )
      }
  }
}

fn adopt(status, candidate, frames) {
  case candidate {
    Some(Candidate(channel, _, Some(#(cut, view)), workspace, name, key)) ->
      case
        channel.socket(channel)
        |> option.to_result("replay channels cannot be adopted as live sockets")
        |> result.try(connection.adopt)
      {
        Ok(Nil) -> #(
          Idle,
          Some(Adopted(channel, cut, view, frames, workspace, name, key)),
          [],
        )
        Error(reason) -> failed(status, reason)
      }
    Some(Candidate(captured: None, ..)) | None ->
      failed(status, "replacement task ended without a validated initial cut")
  }
}

// The failure's trace note is written now, because a recording orders it
// among the channel traces this step already wrote. The cleanup is only
// decided: the status it cancels travels in the output, and `cancel` closes
// the channel it holds. A write the failing advance itself decided is not
// in that status and is dropped, which is right: the attempt is over and
// its socket is closed exactly once.
fn failed(status, reason) -> #(Status, Option(Outcome), List(Out)) {
  case status {
    Opening(Run(trace: Some(trace), ..), _, _, _) ->
      trace.note(attempt.Failed(trace.id, reason))
    Idle | Opening(Run(trace: None, ..), _, _, _) -> Nil
  }
  #(Idle, Some(Failed(reason)), [Abandon(status)])
}

/// What an attachment attempt asks the runtime to do.
///
/// The provisional channel's writes and closes pass through unchanged,
/// `Acknowledge` is the reply that tells the preparing worker its initial
/// capture has landed, and the other two clean up after an attempt the
/// terminal will not adopt.
pub type Out {
  /// An output of the candidate's own channel.
  FromChannel(channel.Out)

  /// Releases the worker waiting on its acknowledgement subject.
  Acknowledge(to: Subject(Nil))

  /// Cancels an attempt the terminal will not adopt, one that failed or one
  /// abandoned at quit, and closes what it opened, as `cancel` does. The
  /// status carries the attempt's channel, so `cancel` performs what that
  /// channel had queued before its close.
  Abandon(status: Status)

  /// Closes a prepared socket that arrived for an attempt this status no
  /// longer holds.
  CloseStray(socket: connection.Connection)
}

/// Hands over the outputs the provisional channel has queued, oldest first.
///
/// A candidate's channel lives inside this opaque status rather than on the
/// model, so the runtime asks here after every step, as it asks the adopted
/// channel. Without it the candidate's `subscribe` would never be written.
///
/// ## Examples
///
/// ```gleam
/// let #(pending, outputs) = attachment.take_outputs(pending)
/// ```
pub fn take_outputs(status: Status) -> #(Status, List(Out)) {
  case status {
    Opening(run, prepared, frames, Some(candidate)) -> {
      let #(lane, outputs) = channel.take_outputs(candidate.channel)
      #(
        Opening(
          run,
          prepared,
          frames,
          Some(Candidate(..candidate, channel: lane)),
        ),
        list.map(outputs, FromChannel),
      )
    }
    Idle | Opening(_, _, _, None) -> #(status, [])
  }
}

/// Performs one attachment output.
///
/// ## Examples
///
/// ```gleam
/// list.each(outputs, attachment.perform)
/// ```
pub fn perform(output: Out) -> Nil {
  case output {
    FromChannel(output) -> channel.perform(output)
    Acknowledge(to) -> process.send(to, Nil)
    Abandon(status) -> cancel(status)
    CloseStray(socket) -> connection.close(socket)
  }
}

/// Cancels only this attempt; the terminal retains its previously adopted peer.
///
/// ## Examples
///
/// ```gleam
/// attachment.cancel(pending)
/// ```
pub fn cancel(status: Status) -> Nil {
  case status {
    Idle -> Nil
    Opening(run, prepared, frames, candidate) -> {
      weft.cancel(run.cancel)
      case candidate {
        None ->
          case process.receive(prepared, 0) {
            Ok(Prepared(socket, _, _, _, _, _)) -> connection.close(socket)
            Error(Nil) -> Nil
          }
        Some(candidate) ->
          channel.close(candidate.channel)
          |> channel.take_outputs
          |> fn(closed) { list.each(closed.1, channel.perform) }
      }
      sessions.discard(frames)
      sessions.discard(prepared)
    }
  }
}
