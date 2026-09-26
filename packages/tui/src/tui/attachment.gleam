//// A replacement stays provisional until the terminal validates its first cut.
////
//// The Weft task owns connection startup and remains alive while the terminal
//// consumes credit. The terminal owns both input subjects from the beginning;
//// the worker only creates an acknowledgement subject which the terminal
//// writes. A normal acknowledged task exit permits guardian adoption. Failure
//// leaves the old connection untouched and cancels only this attempt.

import gleam/bool
import gleam/erlang/process.{type Selector, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tui/attempt
import tui/buffered.{type Inbox}
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
    outcomes: Inbox(weft.Pulled(Nil, String)),
    trace: Option(attempt.Trace),
  )
}

// A candidate's frames are drained at most this many per step, and the
// runtime receives no more than this many ahead of the step.
const frame_batch = 40

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
///
/// Each mailbox is held as a `buffered.Inbox`, so what the runtime received
/// for the attempt before a step stays with the attempt: it is adopted with
/// the frames inbox, or dropped with the status when the attempt fails.
pub opaque type Status {
  Idle
  Opening(
    run: Run,
    prepared: Inbox(Prepared),
    frames: Inbox(connection.Message),
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
    /// The frames inbox together with the frames already received from it
    /// and not reduced, which are older than anything still in its mailbox.
    inbox: Inbox(connection.Message),
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
  Opening(
    Run(cancel, buffered.new(outcomes), trace),
    buffered.new(prepared),
    buffered.new(frames),
    None,
  )
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
/// The poll reads only what `top_up` received before the step, and it
/// performs nothing it decided: the worker's acknowledgement and a failed
/// attempt's cleanup come back as outputs, oldest first, for the caller to
/// queue. The provisional channel's writes stay on it until `take_outputs`.
/// `now` is the transport reading the candidate channel's deadlines are
/// measured against, as for the adopted channel.
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
      let #(prepared, candidate) = prepare(prepared, candidate, run.trace, now)
      case progress(candidate, frames, now) {
        Error(reason) ->
          failed(Opening(run, prepared, frames, candidate), reason)
        Ok(#(advanced, frames)) ->
          settle(Opening(run, prepared, frames, advanced))
          |> acknowledging(candidate, advanced)
      }
    }
  }
}

/// Receives what this attempt's mailboxes hold, up to what the next step
/// can consume, without blocking.
///
/// `runtime.receive` calls it before every step. The bounds are the step's
/// own: one `Prepared`, and only while no candidate exists to take it; up to
/// forty frames, the poll's batch, until the initial cut is captured; and
/// one worker outcome, which is all a poll settles. Frames that arrive
/// after the capture stay in the mailbox for the adopted lane, as they
/// always have.
///
/// ## Examples
///
/// ```gleam
/// let pending = attachment.top_up(pending)
/// ```
pub fn top_up(status: Status) -> Status {
  case status {
    Idle -> Idle
    Opening(run, prepared, frames, candidate) -> {
      let run = Run(..run, outcomes: buffered.top_up(run.outcomes, up_to: 1))
      case candidate {
        None ->
          Opening(
            run,
            buffered.top_up(prepared, up_to: 1),
            buffered.top_up(frames, up_to: frame_batch),
            None,
          )
        Some(Candidate(captured: None, ..)) ->
          Opening(
            run,
            prepared,
            buffered.top_up(frames, up_to: frame_batch),
            candidate,
          )
        Some(Candidate(captured: Some(_), ..)) ->
          Opening(run, prepared, frames, candidate)
      }
    }
  }
}

/// Adds only this attempt's terminal-owned inputs to an existing selector.
///
/// The selector reads the mailboxes, so it cannot return what the runtime
/// already received. `accept` makes up for that: it appends the selected
/// message behind the ones held for the same inbox, which were received
/// earlier, and then advances exactly as the poll does.
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
    Opening(run, prepared, frames, _) -> {
      let prepared = buffered.sender(prepared)
      let frames = buffered.sender(frames)
      let outcomes = buffered.sender(run.outcomes)
      selector
      |> process.select_map(prepared, fn(message) {
        tag(Preparation(prepared, message))
      })
      |> process.select_map(frames, fn(message) { tag(Frame(frames, message)) })
      |> process.select_map(outcomes, fn(outcome) {
        tag(Settled(outcomes, outcome))
      })
    }
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
    Opening(run, prepared, frames, candidate), Settled(source, outcome) -> {
      use <- bool.lazy_guard(!buffered.is_sender(run.outcomes, source), fn() {
        ignore(status, event)
      })
      let outcomes = buffered.push(run.outcomes, outcome)
      settle_held(Opening(Run(..run, outcomes:), prepared, frames, candidate))
    }

    Opening(run, prepared, frames, None), Preparation(source, message) -> {
      use <- bool.lazy_guard(!buffered.is_sender(prepared, source), fn() {
        ignore(status, event)
      })
      let prepared = buffered.push(prepared, message)
      let #(prepared, candidate) = prepare(prepared, None, run.trace, now)
      settle(Opening(run, prepared, frames, candidate))
    }

    // The selected frame joins the held ones and the same drain the poll
    // runs takes them in order, stopping at the capture. A frame after the
    // capture, held or selected, stays in the inbox for the adopted lane,
    // exactly as in the interactive loop.
    Opening(
      run,
      prepared,
      frames,
      Some(Candidate(captured: None, ..) as candidate),
    ),
      Frame(source, message)
    -> {
      use <- bool.lazy_guard(!buffered.is_sender(frames, source), fn() {
        ignore(status, event)
      })
      let frames = buffered.push(frames, message)
      case drain(candidate, frames, buffered.held(frames), now) {
        Ok(#(advanced, frames)) ->
          settle(Opening(run, prepared, frames, Some(advanced)))
          |> acknowledging(Some(candidate), Some(advanced))
        Error(reason) -> failed(status, reason)
      }
    }

    _, _ -> ignore(status, event)
  }
}

// An event for an inbox this status does not hold, or one it no longer
// needs. A `Prepared` still carries an open socket, which must be closed.
//
// A frame selected once the candidate has already captured its cut is
// dropped rather than held: it is not taken out of the mailbox while the
// attempt waits for its worker, so nothing would bound what a driver
// accumulates here. The adopted channel's 250 ms credited `catch_up` is
// what makes the drop lossless.
fn ignore(
  status: Status,
  event: Event,
) -> #(Status, Option(Outcome), List(Out)) {
  case event {
    Preparation(_, Prepared(socket, _, _, _, _, _)) -> #(status, None, [
      CloseStray(socket),
    ])
    Frame(_, _) | Settled(_, _) -> #(status, None, [])
  }
}

// Settles held outcomes oldest first until one decides the attempt or none
// is left. A driver's selected outcome may sit behind one the runtime
// already received, so there can be two.
fn settle_held(status: Status) -> #(Status, Option(Outcome), List(Out)) {
  case status {
    Opening(run, ..) ->
      case buffered.held(run.outcomes) {
        0 -> #(status, None, [])
        _ -> settle(status) |> and_then(settle_held)
      }
    Idle -> #(Idle, None, [])
  }
}

// Continues with a second advance only while the first left the attempt
// open and undecided; the outputs of both keep their order.
fn and_then(
  settled: #(Status, Option(Outcome), List(Out)),
  next: fn(Status) -> #(Status, Option(Outcome), List(Out)),
) -> #(Status, Option(Outcome), List(Out)) {
  case settled {
    #(Opening(..) as status, None, outputs) -> {
      let #(status, outcome, more) = next(status)
      #(status, outcome, list.append(outputs, more))
    }
    #(Opening(..), Some(_), _) | #(Idle, _, _) -> settled
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

fn prepare(
  prepared: Inbox(Prepared),
  candidate: Option(Candidate),
  trace: Option(attempt.Trace),
  now: Int,
) -> #(Inbox(Prepared), Option(Candidate)) {
  case candidate {
    Some(_) -> #(prepared, candidate)
    None ->
      case buffered.take(prepared) {
        #(prepared, Error(Nil)) -> #(prepared, None)
        #(
          prepared,
          Ok(Prepared(socket, expected, workspace, name, key, acknowledgement)),
        ) -> #(
          prepared,
          Some(Candidate(
            channel.start_recorded(socket, expected, trace, now:),
            acknowledgement,
            None,
            workspace,
            name,
            key,
          )),
        )
      }
  }
}

fn progress(
  candidate: Option(Candidate),
  frames: Inbox(connection.Message),
  now: Int,
) -> Result(#(Option(Candidate), Inbox(connection.Message)), String) {
  case candidate {
    None -> Ok(#(None, frames))
    Some(Candidate(captured: Some(_), ..)) -> Ok(#(candidate, frames))
    Some(candidate) -> {
      use #(candidate, frames) <- result.try(drain(
        candidate,
        frames,
        frame_batch,
        now,
      ))
      let #(next, updates) = channel.tick(candidate.channel, now:)
      apply_updates(Candidate(..candidate, channel: next), updates)
      |> result.map(fn(candidate) { #(Some(candidate), frames) })
    }
  }
}

// Takes held frames until the cut is captured, and no further: a frame
// after the capture belongs to the adopted lane and stays in the inbox,
// which the adoption hands over whole.
fn drain(
  candidate: Candidate,
  frames: Inbox(connection.Message),
  remaining: Int,
  now: Int,
) -> Result(#(Candidate, Inbox(connection.Message)), String) {
  case remaining <= 0, candidate.captured {
    True, _ | _, Some(_) -> Ok(#(candidate, frames))
    False, None ->
      case buffered.take(frames) {
        #(_, Error(Nil)) -> Ok(#(candidate, frames))
        #(frames, Ok(message)) -> {
          use candidate <- result.try(receive_frame(candidate, message, now))
          drain(candidate, frames, remaining - 1, now)
        }
      }
  }
}

fn receive_frame(
  candidate: Candidate,
  message: connection.Message,
  now: Int,
) -> Result(Candidate, String) {
  let #(next, updates) = channel.receive(candidate.channel, message, now:)
  apply_updates(Candidate(..candidate, channel: next), updates)
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
    Opening(run, prepared, frames, candidate) ->
      case buffered.take(run.outcomes) {
        #(_, Error(Nil)) -> #(status, None, [])
        #(outcomes, Ok(outcome)) ->
          apply_outcome(
            Opening(Run(..run, outcomes:), prepared, frames, candidate),
            outcome,
          )
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
/// It runs as an effect after the step, and it reads a `Prepared` through
/// `buffered.receive`: one the runtime already received is in the status,
/// not the mailbox, and its socket must be closed all the same.
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
          case buffered.receive(prepared, 0) {
            #(_, Ok(Prepared(socket, _, _, _, _, _))) ->
              connection.close(socket)
            #(_, Error(Nil)) -> Nil
          }
        Some(candidate) ->
          channel.close(candidate.channel)
          |> channel.take_outputs
          |> fn(closed) { list.each(closed.1, channel.perform) }
      }
      sessions.discard(buffered.sender(frames))
      sessions.discard(buffered.sender(prepared))
    }
  }
}
