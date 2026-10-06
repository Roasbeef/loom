//// A replacement stays provisional until the terminal validates its first cut.
////
//// The attachment's worker is a background job (`job.Attach`), started by
//// the runtime after the step that asked for it, and a `Status` is the
//// reducer's view of that one job: its key, and what the runtime has
//// admitted for it. The worker resolves the route, connects a socket to the
//// frames subject the runtime created, publishes the socket as a
//// `job.Prepared`, and stays alive while the terminal consumes credit, until
//// the terminal acknowledges the initial cut. The terminal learns its
//// frames inbox from that `Prepared` and from nowhere else, so the step
//// creates no subject. A normal acknowledged task exit permits guardian
//// adoption. Failure leaves the old connection untouched and cancels only
//// this attempt.
////
//// An attempt moves through three stages. It is `Resolving` until its
//// `Prepared` is admitted, `Published` until the next poll starts the
//// candidate lane on the socket, and `Connecting` while that lane captures
//// its initial cut and waits for the worker's outcome. Each stage holds only
//// what exists at that point, so a lane without a frames inbox, or a frames
//// inbox without the socket that feeds it, cannot be expressed.

import gleam/erlang/process.{type Selector, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/attempt
import session_view/connection_event
import session_view/protocol
import session_view/session_channel as channel
import session_view/snapshot
import session_view/snapshot_view
import tui/buffered.{type Inbox}
import tui/connection
import tui/job
import tui/recording
import tui/terminal_lane
import tui/workspace
import weft

// The job's key, the relay outcomes the runtime admitted for it, oldest
// first, and the recorder the attempt's notes name.
type Run {
  Run(outcomes: job.Awaiting(Settlement), trace: Option(recording.Trace))
}

// What the attempt holds of its job's end, in the order it arrived: the
// relay's messages about the worker, and the end the host checked the
// socket for.
type Settlement {
  Relayed(weft.Pulled(Nil, String))

  Ended(job.SocketLiveness)
}

// A candidate's frames are drained at most this many per step, and the
// runtime receives no more than this many ahead of the step.
const frame_batch = 40

type Candidate {
  Candidate(
    channel: terminal_lane.Lane,
    acknowledgement: Subject(Nil),
    captured: Option(#(snapshot.Captured, snapshot_view.View)),
    workspace: workspace.Context,
    /// Display name from the authorized catalogue, adopted with this identity.
    session_name: String,
    creation_key: Option(String),
  )
}

// How far the attempt has got. The frames inbox appears with the
// `Prepared` that names it and moves with the attempt from then on; it
// holds what the runtime received from the socket and the attempt has not
// reduced.
type Stage {
  // No `Prepared` has been admitted.
  Resolving

  // A `Prepared` is admitted; the next poll starts the lane on its socket.
  Published(prepared: job.Prepared, frames: Inbox(connection_event.Message))

  // The candidate lane exists and captures its initial cut.
  Connecting(candidate: Candidate, frames: Inbox(connection_event.Message))
}

/// One provisional lifetime, named by its job key.
///
/// What the runtime received for the attempt before a step stays with the
/// attempt: it is adopted with the frames inbox, or dropped with the status
/// when the attempt fails.
pub opaque type Status {
  Idle
  Opening(run: Run, stage: Stage)
}

/// Only Adopted is allowed to replace the visible connection and transcript.
pub type Outcome {
  /// Initial capture and original worker completion have both been observed.
  Adopted(
    channel: terminal_lane.Lane,
    cut: snapshot.Captured,
    view: snapshot_view.View,
    /// The frames inbox together with the frames already received from it
    /// and not reduced, which are older than anything still in its mailbox.
    inbox: Inbox(connection_event.Message),
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

/// The attempt that waits for the attachment job started under `key`.
///
/// The reducer queues `effect.StartJob(key, job.Attach(route, within_ms))`
/// in the same step; this value only records the key and the recorder the
/// attempt's notes will name, and starts nothing.
///
/// ## Examples
///
/// ```gleam
/// let #(model, key) = tui_model.start_job(model, job.Attach(route, 90_000))
/// let candidate = attachment.opening(key, trace)
/// ```
pub fn opening(key: job.Key, trace: Option(recording.Trace)) -> Status {
  Opening(Run(job.awaiting(key), trace), Resolving)
}

/// The key of the job this attempt waits for, if there is an attempt.
///
/// ## Examples
///
/// ```gleam
/// attachment.job_key(attachment.idle())
/// // -> None
/// ```
pub fn job_key(status: Status) -> Option(job.Key) {
  case status {
    Idle -> None
    Opening(run, _) -> Some(job.key(run.outcomes))
  }
}

/// The socket this attempt's lane would adopt, or why there is none.
///
/// The host asks for it when the attachment job ends, reads whether the
/// socket's actor is alive, and hands the attempt the answer as
/// `job.Finished`. An attempt whose lane has no socket is a replay lane,
/// which is never adopted as a live one. An attempt with no lane yet has no
/// socket to check; its adoption fails on its stage whatever the answer.
///
/// ## Examples
///
/// ```gleam
/// assert attachment.adoptable_socket(attachment.idle()) |> result.is_error
/// ```
@internal
pub fn adoptable_socket(
  status: Status,
) -> Result(connection.Connection, String) {
  case status {
    Opening(_, Connecting(candidate, _)) ->
      channel.socket(candidate.channel)
      |> option.to_result("replay channels cannot be adopted as live sockets")
    Idle | Opening(_, Resolving) | Opening(_, Published(..)) ->
      Error("replacement task ended without a validated initial cut")
  }
}

/// Binds the recorder after launch but before any terminal poll can consume data.
///
/// A worker may already have published its `Prepared`; only a poll
/// constructs the channel, so even a fast local server cannot consume an
/// unrecorded first cut.
///
/// ## Examples
///
/// ```gleam
/// // attachment.with_trace(pending, trace)
/// ```
pub fn with_trace(status: Status, trace: Option(recording.Trace)) -> Status {
  case status {
    Opening(run, Resolving as stage) | Opening(run, Published(..) as stage) ->
      Opening(Run(..run, trace: trace), stage)
    Idle | Opening(_, Connecting(..)) -> status
  }
}

/// Admits one message from an attachment job into the attempt waiting for
/// it.
///
/// The error is the fence. A message whose key is not this attempt's
/// belongs to a job nobody waits for, and so does a second `Prepared`; the
/// runtime drops what this refuses, and closes the socket a refused
/// `Prepared` carries. An admitted `Prepared` brings the frames inbox the
/// attempt reads from then on.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(status) =
///   attachment.admit(status, key, job.Finished(job.SocketAlive))
/// ```
pub fn admit(
  status: Status,
  key: job.Key,
  reply: job.AttachReply,
) -> Result(Status, Nil) {
  case status, reply {
    Idle, _ -> Error(Nil)
    Opening(run, stage), job.Settled(outcome) ->
      job.admit(run.outcomes, key, Relayed(outcome))
      |> result.map(fn(outcomes) { Opening(Run(..run, outcomes:), stage) })
    Opening(run, stage), job.Finished(liveness) ->
      job.admit(run.outcomes, key, Ended(liveness))
      |> result.map(fn(outcomes) { Opening(Run(..run, outcomes:), stage) })
    Opening(run, Resolving), job.Published(prepared) ->
      case job.key(run.outcomes) == key {
        True ->
          Ok(Opening(run, Published(prepared, buffered.new(prepared.frames))))
        False -> Error(Nil)
      }
    Opening(_, Published(..)), job.Published(_)
    | Opening(_, Connecting(..)), job.Published(_)
    -> Error(Nil)
  }
}

/// Advances at most forty credited messages during one terminal tick.
///
/// The poll reads only what the runtime admitted and received before the
/// step, and it performs nothing it decided. Everything comes back as
/// outputs, oldest first, for the caller to queue: the provisional
/// channel's writes and recording notes, the worker's acknowledgement, and
/// a failed attempt's failure note and cleanup. Nothing stays queued inside
/// the status, so the order of the returned list is the order the attempt
/// decided it. `now` is the transport reading the candidate channel's
/// deadlines are measured against, as for the adopted channel.
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
    Opening(run, stage) -> {
      let stage = prepare(stage, run.trace, now)
      let #(stage, started) = release(stage)
      let advanced = case progress(stage, now) {
        Error(broken) -> discard(Opening(run, stage), broken)
        Ok(advanced) -> {
          let #(advanced, progressed) = release(advanced)
          settle(Opening(run, advanced))
          |> acknowledging(stage, advanced)
          |> preceded_by(progressed)
        }
      }
      preceded_by(advanced, started)
    }
  }
}

/// The frames subject the host should read for this attempt, and how many
/// messages the next step has room for, when the attempt still reads
/// frames.
///
/// The host reads at most that many before every step and delivers them
/// as `msg.Frame` arrivals, after it has delivered the job's own messages,
/// so a `Prepared` admitted in the same receive has its first frames read
/// with it. Frames are read until the initial cut is captured, forty held
/// at most; frames that arrive after the capture stay in the mailbox for
/// the adopted lane, as they always have. The `Prepared` and the worker's
/// outcomes are job messages, which admission files through `admit`.
///
/// After the capture this gives no room, so a host that delivers
/// `msg.Arrived` from a selector of its own has no number to enforce for
/// the attempt's frames and must bound them itself. In the terminal that
/// window lasts at most the two ticks between the acknowledgement and the
/// adoption, and the terminal's host reads nothing from the frames subject
/// during it.
///
/// ## Examples
///
/// ```gleam
/// case attachment.frame_room(pending) {
///   Ok(#(subject, room)) -> buffered.waiting(subject, room)
///   Error(Nil) -> []
/// }
/// ```
@internal
pub fn frame_room(
  status: Status,
) -> Result(#(Subject(connection_event.Message), Int), Nil) {
  case status {
    Opening(_, Published(_, frames))
    | Opening(_, Connecting(Candidate(captured: None, ..), frames)) ->
      Ok(#(buffered.sender(frames), frame_batch - buffered.held(frames)))
    Idle
    | Opening(_, Resolving)
    | Opening(_, Connecting(Candidate(captured: Some(_), ..), _)) -> Error(Nil)
  }
}

/// Files one frame the host received from `source` into this attempt's
/// frames inbox, behind the frames it already holds.
///
/// The error means the frame is not this attempt's: the attempt has no
/// frames inbox yet, or the inbox is another subject. A frame is filed
/// whatever the attempt's stage, so one that arrives after the capture is
/// kept for the adopted lane, which the adoption hands the inbox to.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(pending) = attachment.push_frame(pending, source, message)
/// ```
@internal
pub fn push_frame(
  status: Status,
  source: Subject(connection_event.Message),
  message: connection_event.Message,
) -> Result(Status, Nil) {
  case status {
    Opening(run, Published(prepared, frames)) ->
      case buffered.sender(frames) == source {
        True ->
          Ok(Opening(run, Published(prepared, buffered.push(frames, message))))
        False -> Error(Nil)
      }
    Opening(run, Connecting(candidate, frames)) ->
      case buffered.sender(frames) == source {
        True ->
          Ok(Opening(run, Connecting(candidate, buffered.push(frames, message))))
        False -> Error(Nil)
      }
    Idle | Opening(_, Resolving) -> Error(Nil)
  }
}

/// Adds this attempt's frames inbox, once it has one, to an existing
/// selector.
///
/// A test driver hosted in an actor selects it between scripts, because an
/// actor discards a message its selector does not match, and that includes
/// frames that arrive after the capture, which the shipped loop leaves in
/// the mailbox for the adopted lane. The attempt's `Prepared` and outcomes
/// are job messages, which the driver selects through
/// `job_runner.selector`. The selector reads the mailbox, so it cannot
/// return what the runtime already received; `accept` puts a selected
/// frame behind the held ones.
///
/// ## Examples
///
/// ```gleam
/// // attachment.select(pending, process.new_selector(), CandidateFrame)
/// ```
pub fn select(
  status: Status,
  selector: Selector(a),
  tag: fn(connection_event.Message) -> a,
) -> Selector(a) {
  case status {
    Idle | Opening(_, Resolving) -> selector
    Opening(_, Published(frames:, ..)) | Opening(_, Connecting(frames:, ..)) ->
      process.select_map(selector, buffered.sender(frames), tag)
  }
}

/// Applies an already selected frame before draining any later mailbox
/// message.
///
/// The selected frame joins the held ones. While the lane captures, the
/// same drain the poll runs takes them in order, stopping at the capture.
/// Before the lane exists, and after the capture, the frame is only held:
/// the next poll drains it, or the adoption hands the inbox with it to the
/// adopted lane, which is where the interactive loop's receive would have
/// put it. Like `poll`, it returns what it
/// decided rather than performing it, and it measures the candidate
/// channel's deadlines against `now`.
///
/// ## Examples
///
/// ```gleam
/// // let #(pending, outcome, outputs) = attachment.accept(pending, frame, now:)
/// ```
pub fn accept(
  status: Status,
  message: connection_event.Message,
  now now: Int,
) -> #(Status, Option(Outcome), List(Out)) {
  case status {
    Opening(run, Connecting(Candidate(captured: None, ..) as candidate, frames)) -> {
      let frames = buffered.push(frames, message)
      case drain(candidate, frames, buffered.held(frames), now) {
        Ok(#(advanced, frames)) -> {
          let before = Connecting(candidate, frames)
          let #(advanced, progressed) = release(Connecting(advanced, frames))
          settle(Opening(run, advanced))
          |> acknowledging(before, advanced)
          |> preceded_by(progressed)
        }
        Error(broken) -> discard(status, broken)
      }
    }

    // Held without a drain. What the driver holds here is what the
    // interactive loop would leave in the mailbox for the same wait, and
    // the attempt's deadline bounds that wait.
    Opening(run, Published(prepared, frames)) -> #(
      Opening(run, Published(prepared, buffered.push(frames, message))),
      None,
      [],
    )

    // Held for the adopted lane after the capture, with no bound here:
    // `frame_room` gives none after the capture, so a host that selects
    // frames itself must bound them. In the terminal this lasts at most the
    // two ticks between the acknowledgement and the adoption.
    Opening(
      run,
      Connecting(Candidate(captured: Some(_), ..) as candidate, frames),
    ) -> #(
      Opening(run, Connecting(candidate, buffered.push(frames, message))),
      None,
      [],
    )

    // `select` offers no frames inbox for these, so nothing selected can
    // name one.
    Idle | Opening(_, Resolving) -> #(status, None, [])
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
  before: Stage,
  after: Stage,
) -> #(Status, Option(Outcome), List(Out)) {
  let #(status, outcome, outputs) = settled
  case before, after {
    Connecting(Candidate(captured: None, ..), _),
      Connecting(Candidate(captured: Some(_), acknowledgement:, ..), _)
    -> #(status, outcome, [Acknowledge(acknowledgement), ..outputs])
    Resolving, _
    | Published(..), _
    | Connecting(Candidate(captured: Some(_), ..), _), _
    | Connecting(Candidate(captured: None, ..), _), Resolving
    | Connecting(Candidate(captured: None, ..), _), Published(..)
    | Connecting(Candidate(captured: None, ..), _),
      Connecting(Candidate(captured: None, ..), _)
    -> settled
  }
}

// Starts the candidate lane on a published socket. The lane is recorded
// under the attempt's trace from its first note.
fn prepare(stage: Stage, trace: Option(recording.Trace), now: Int) -> Stage {
  case stage {
    Resolving | Connecting(..) -> stage
    Published(prepared, frames) ->
      Connecting(
        Candidate(
          channel.start_recorded(
            prepared.socket,
            prepared.expected,
            trace,
            now:,
          ),
          prepared.acknowledgement,
          None,
          prepared.workspace,
          prepared.session_name,
          prepared.creation_key,
        ),
        frames,
      )
  }
}

fn progress(stage: Stage, now: Int) -> Result(Stage, Broken) {
  case stage {
    Resolving
    | Published(..)
    | Connecting(Candidate(captured: Some(_), ..), _) -> Ok(stage)
    Connecting(candidate, frames) -> {
      use #(candidate, frames) <- result.try(drain(
        candidate,
        frames,
        frame_batch,
        now,
      ))
      let #(next, updates) = channel.tick(candidate.channel, now:)
      apply_updates(Candidate(..candidate, channel: next), updates)
      |> result.map(fn(candidate) { Connecting(candidate, frames) })
    }
  }
}

// Takes held frames until the cut is captured, and no further: a frame
// after the capture belongs to the adopted lane and stays in the inbox,
// which the adoption hands over whole.
fn drain(
  candidate: Candidate,
  frames: Inbox(connection_event.Message),
  remaining: Int,
  now: Int,
) -> Result(#(Candidate, Inbox(connection_event.Message)), Broken) {
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
  message: connection_event.Message,
  now: Int,
) -> Result(Candidate, Broken) {
  let #(next, updates) = channel.receive(candidate.channel, message, now:)
  apply_updates(Candidate(..candidate, channel: next), updates)
}

fn apply_updates(candidate: Candidate, updates) {
  case updates {
    [] -> Ok(candidate)
    [channel.Captured(cut, view, _), ..rest] ->
      apply_updates(Candidate(..candidate, captured: Some(#(cut, view))), rest)
    [channel.Failed(reason), ..] -> Error(Broken(candidate, reason))

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
    | [channel.LineagePage(..), ..]
    | [channel.LookedUp(..), ..]
    | [channel.Acknowledged(..), ..]
    | [channel.UnknownOutcome(..), ..] ->
      Error(Broken(
        candidate,
        "unexpected command result during initial capture",
      ))
  }
}

// Settles the oldest outcome the runtime admitted, if there is one.
fn settle(status: Status) -> #(Status, Option(Outcome), List(Out)) {
  case status {
    Idle -> #(Idle, None, [])
    Opening(run, stage) ->
      case job.take(run.outcomes) {
        #(_, Error(Nil)) -> #(status, None, [])
        #(outcomes, Ok(outcome)) ->
          apply_outcome(Opening(Run(..run, outcomes:), stage), outcome)
      }
  }
}

fn apply_outcome(
  status: Status,
  settlement: Settlement,
) -> #(Status, Option(Outcome), List(Out)) {
  case settlement {
    Ended(liveness) -> adopt(status, liveness)
    Relayed(outcome) -> apply_relayed(status, outcome)
  }
}

fn apply_relayed(
  status: Status,
  outcome: weft.Pulled(Nil, String),
) -> #(Status, Option(Outcome), List(Out)) {
  case outcome {
    weft.NotYet -> #(status, None, [])
    weft.PulledOutcome(weft.Completed(..)) -> #(status, None, [])

    // The host turns the relay's end into `Ended` with the socket checked
    // (`runtime.hold`), so an unchecked end reaches an attempt only from a
    // caller that bypassed the host. It is refused rather than adopted,
    // because adopting without the check is the one thing it must not do.
    weft.AllDelivered ->
      adopt(
        status,
        job.SocketGone("the socket was not checked before adoption"),
      )
    weft.PulledOutcome(weft.Failed(error: reason, ..)) -> failed(status, reason)
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

// The worker has completed, which it does only after the acknowledgement,
// and the host has read whether the socket's actor is still alive
// (`runtime.hold`, phase 3 of issue #530). An attempt that captured its cut
// adopts on a live socket and fails on a gone one; the check is the host's
// so that the step reads no process.
fn adopt(
  status: Status,
  liveness: job.SocketLiveness,
) -> #(Status, Option(Outcome), List(Out)) {
  case status {
    Opening(
      _,
      Connecting(
        Candidate(channel, _, Some(#(cut, view)), workspace, name, key),
        frames,
      ),
    ) ->
      case liveness {
        job.SocketAlive -> #(
          Idle,
          Some(Adopted(channel, cut, view, frames, workspace, name, key)),
          [],
        )
        job.SocketGone(reason:) -> failed(status, reason)
      }
    Idle
    | Opening(_, Resolving)
    | Opening(_, Published(..))
    | Opening(_, Connecting(Candidate(captured: None, ..), _)) ->
      failed(status, "replacement task ended without a validated initial cut")
  }
}

// The failure note is queued ahead of the cleanup, behind every note the
// attempt queued before it. It is a note in the attempt's lane recording,
// so it travels as the lane's own notes do, even when the attempt failed
// before it had a lane. The cleanup is only decided: the status it cancels
// travels in the output, and `cancel` closes what it holds when the
// runtime performs it, after the job itself is cancelled by its key.
fn failed(status, reason) -> #(Status, Option(Outcome), List(Out)) {
  let noted = case status {
    Opening(Run(trace: Some(attempt.Trace(recorder:, id:)), ..), _) -> [
      FromChannel(channel.Note(recorder, attempt.Failed(id, reason))),
    ]
    Idle | Opening(Run(trace: None, ..), _) -> []
  }
  #(Idle, Some(Failed(reason)), list.append(noted, [Abandon(status)]))
}

// An advance that failed part way: the candidate as the failing advance
// left it, and the reason.
type Broken {
  Broken(candidate: Candidate, reason: String)
}

// Fails the attempt in `status`, which is as it stood before the advance
// that broke. That advance is discarded: its channel state and the writes
// it decided go with it, and `cancel` closes the attempt's socket from the
// status, once. Its notes are kept and queued ahead of the failure, because
// they record frames the terminal did receive, in the order it received
// them, and the recording has always held them.
fn discard(
  status: Status,
  broken: Broken,
) -> #(Status, Option(Outcome), List(Out)) {
  let #(_, outputs) = channel.take_outputs(broken.candidate.channel)
  let notes =
    list.filter_map(outputs, fn(output) {
      case output {
        channel.Note(..) -> Ok(FromChannel(output))
        channel.Transmit(..) | channel.Shut(..) -> Error(Nil)
      }
    })
  failed(status, broken.reason) |> preceded_by(notes)
}

// Moves what the candidate's channel queued into the attempt's outputs, so
// nothing an advance decided is left inside the status. An adopted channel
// therefore arrives with an empty queue, and an abandoned one holds only
// what `cancel` decides when it closes it.
fn release(stage: Stage) -> #(Stage, List(Out)) {
  case stage {
    Resolving | Published(..) -> #(stage, [])
    Connecting(candidate, frames) -> {
      let #(lane, outputs) = channel.take_outputs(candidate.channel)
      #(
        Connecting(Candidate(..candidate, channel: lane), frames),
        list.map(outputs, FromChannel),
      )
    }
  }
}

// Puts outputs decided earlier in the advance ahead of the ones `settled`
// carries.
fn preceded_by(
  settled: #(Status, Option(Outcome), List(Out)),
  earlier: List(Out),
) -> #(Status, Option(Outcome), List(Out)) {
  let #(status, outcome, outputs) = settled
  #(status, outcome, list.append(earlier, outputs))
}

/// What an attachment attempt asks the runtime to do.
///
/// The provisional channel's writes, closes and notes pass through
/// unchanged, `Acknowledge` is the reply that tells the preparing worker its
/// initial capture has landed, and `Abandon` cleans up after an attempt the
/// terminal will not adopt.
pub type Out {
  /// An output of the candidate's channel, or the attempt's failure note,
  /// which is recorded as one of that lane's notes.
  FromChannel(terminal_lane.Output)

  /// Releases the worker waiting on its acknowledgement subject.
  Acknowledge(to: Subject(Nil))

  /// Closes what an attempt the terminal will not adopt holds, one that
  /// failed or one abandoned at quit, as `cancel` does. The status carries
  /// the attempt's channel, and `cancel` performs the close it decides for
  /// that channel, its recorded close included. The job itself is cancelled
  /// by `effect.CancelJob`, which `tui_model.emit_attachment` queues ahead
  /// of this.
  Abandon(status: Status)
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
    FromChannel(output) -> terminal_lane.perform(output)
    Acknowledge(to) -> process.send(to, Nil)
    Abandon(status) -> cancel(status)
  }
}

/// Closes what this attempt holds; the terminal retains its previously
/// adopted peer.
///
/// It runs as an effect after the step. A `Prepared` the attempt admitted
/// but has not started a lane on still holds its socket, which is closed; a
/// lane is closed through the channel, with its recorded close; and the
/// frames inbox is emptied. Stopping the worker, and closing a socket whose
/// `Prepared` the runtime had not yet admitted, is the job cancel's part
/// (`job_runner.cancel`).
///
/// ## Examples
///
/// ```gleam
/// attachment.cancel(pending)
/// ```
pub fn cancel(status: Status) -> Nil {
  case status {
    Idle | Opening(_, Resolving) -> Nil
    Opening(_, Published(prepared, frames)) -> {
      connection.close(prepared.socket)
      buffered.discard(buffered.sender(frames))
    }
    Opening(_, Connecting(candidate, frames)) -> {
      channel.close(candidate.channel)
      |> channel.take_outputs
      |> fn(closed) { list.each(closed.1, terminal_lane.perform) }
      buffered.discard(buffered.sender(frames))
    }
  }
}
