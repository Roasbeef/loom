//// The box's half of a live session page on another orchestrator
//// (protocol-change/108): one process per feed that attaches to a relayed
//// session's gateway the way a page socket does, queues what the gateway writes,
//// and answers the laptop's polls and sends.
////
//// `client/daemon/ui_relay` does this for a page on the same daemon: it holds the
//// gateway attachment and hands each frame to the component. A page on another
//// machine cannot be handed frames, because nothing bounds a pushed mailbox
//// across a link that may drop (protocol-change/107's review). The feed host
//// therefore sends nothing on its own. The laptop pulls with a long poll, and the
//// box answers only polls, sends and detaches. The gateway writes replies and
//// pushes to this process's sink, and this process does no work on a push except
//// count it and queue it (`client/remote/feed_queue`), so a laptop that stops
//// polling becomes a lapse and a detach rather than a growing mailbox.
////
//// ## Who judges what
////
//// The gateway judges every frame it is forwarded as an Operator attachment of
//// the box's owner, and the hub judges every decision. This module judges only
//// which frames reach them. `client/remote/feed_filter` is the closed table: a
//// frame is forwarded as the lane wrote it, answered `forbidden` without the
//// gateway seeing it, or turned into a decision. A decision never reaches the
//// gateway's own `approve` door, which would judge it as the box owner's with no
//// ceiling. It goes through `gateway.decide_relayed` with the spawner's name and
//// `approval_ceiling`, the door `TopResolve` uses, and the hub judges it with
//// `remote_decision.admit_relayed`.
////
//// ## What ends a feed
////
//// A feed ends in one of three ways, and keeps the first. It **lapses** when the
//// queue passes its bound or no poll arrives for a whole lease. It is
//// **stopped** when the session's run ends and the gateway goes. It is
//// **revoked** when the gateway closes the attachment because its check no longer
//// passes, which is how an archive and a changed table reach it. An ended feed
//// detaches from the gateway at once, drops its queue and any partly received
//// frame, answers every later poll with its ending, and exits one lease after it
//// ended, which is long enough for a late poll to learn why.
////
//// A gateway call made for the lane (`gateway.connection_request`, a decision)
//// blocks this process, as `ui_relay`'s does, for at most the gateway's own six
//// seconds. A laptop that sends faster than the gateway answers waits behind its
//// own frame, and no other feed is affected.
////
//// ## Flow
////
//// `start` → `initialise` → `handle` → `poll_live` → `released` → `piece_live` →
//// `dispatch` → `finish`
////
//// 1. `start` runs `initialise` in the new process: it takes the connection
////    permit's custody and attaches to the gateway, so a refusal of either is
////    the start's refusal.
//// 2. `handle` is the one transition function. A message the current phase
////    cannot act on is answered with the phase's ending or ignored, and each such
////    arm says which.
//// 3. `poll_live` acknowledges the poll's cursor, renews the lease and answers
////    at once or holds the poll for the first frame. A second poll supersedes a
////    held one, and `released` answers a held poll when a frame arrives or its
////    wait passes.
//// 4. `piece_live` admits one piece of the lane's frame and, when the frame is
////    whole, answers the send and hands the frame to `dispatch`.
//// 5. `dispatch` applies the filter's verdict and queues the reply frame.
//// 6. `finish` ends the feed.
////
//// ## Transitions
////
//// <!-- transitions: feed_host.Phase -->
////
//// | state | `Poll` | `Piece` | `Detach` | `Pushed` | gateway ended | timers |
//// | --- | --- | --- | --- | --- | --- | --- |
//// | `Live` | answers or holds; supersedes a held poll; renews the lease | admits the piece; a whole frame is dispatched | detaches from the gateway, answers and exits | queues the frame, or lapses the feed when the queue is over its bound | `finish` with `stopped`, or `revoked` when the check refuses | the poll timer releases a held poll; the lease timer lapses the feed |
//// | `Ended` | answers the ending and no frames | refused with the ending | answers and exits | dropped, because nothing reads it | ignored, already ended | the forget timer exits one lease after the ending |

import broker/internal/call
import client/approval_ceiling.{type Ceiling}
import client/gateway
import client/protocol
import client/remote/feed_filter
import client/remote/feed_pieces
import client/remote/feed_queue
import client/remote_escalation.{type Decider}
import client/remote_feed.{type Answer, type Piece, type Poll}
import client/remote_top.{type FeedEnd, type Refusal}
import core/json
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor as otp
import gleam/result
import host/bootstrap
import storage/access
import weft/state_machine as sm

/// How long `start` may spend attaching to the gateway and taking custody of the
/// connection permit, in milliseconds. The gateway's own attach waits up to five
/// seconds.
const start_budget_ms = 6000

/// How long a poll's caller waits beyond the wait the poll asked for, in
/// milliseconds. The slack covers a gateway call that is holding the feed.
const poll_slack_ms = 7000

/// How long a send or a detach waits for the feed's answer, in milliseconds. A
/// send's answer is written before the frame reaches the gateway, so the wait is
/// for the mailbox and not for the gateway.
const answer_ms = 7000

/// The timer names. Each belongs to a piece of work and not to a phase, so each
/// is a named timeout.
const poll_timer = "poll"

const lease_timer = "lease"

const forget_timer = "forget"

/// Everything a feed needs from the daemon, fixed when the feed starts.
pub type Settings {
  Settings(
    /// The session's gateway, resolved from the resident instance.
    hub: gateway.Gateway,
    /// The attachment's identity: the box owner at the Operator authority, with
    /// the spawner's door.
    binding: gateway.Binding,
    /// Re-authorizes the attachment on every request and push. It refuses once
    /// the session is archived or no longer relayed for the spawner.
    check: fn() -> Result(#(access.Principal, access.Authority), String),
    /// Asks the registry to stop an incarnation whose reader failed.
    failed_reader: fn() -> Nil,
    /// The `[spawners.<name>]` key, which a decision carries as provenance.
    spawner: String,
    /// What a decision may grant, or `None` when the spawner has no
    /// `approval_ceiling` and every decision is refused.
    ceiling: Option(Ceiling),
    /// The laptop page's identity, kept as plain data on each decision.
    decider: Decider,
    /// Takes custody of one of the box's connection permits for the calling
    /// process. It runs in the feed's own process, so the permit is released
    /// when the feed exits.
    admit: fn() -> Result(Nil, String),
    /// Called once when the feed ends, so the directory stops counting it
    /// toward its spawner's cap while it is kept for a late poll.
    ended: fn() -> Nil,
    /// How long a feed lives with no poll, and how long an ended feed is kept,
    /// in milliseconds. `remote_feed.lease_ms` in the daemon.
    lease_ms: Int,
  )
}

/// A running feed.
pub opaque type Feed {
  Feed(subject: Subject(Message), pid: Pid)
}

/// Whether the feed is serving, or why it is not.
pub type Phase {
  /// The feed is attached to the gateway and answers polls and sends.
  Live

  /// The feed ended and has detached. It answers polls with its ending until it
  /// is forgotten.
  Ended(
    /// Why it ended.
    why: FeedEnd,
  )
}

/// A poll that arrived with nothing to answer, waiting for a first frame.
type Held {
  Held(reply: Subject(Result(Answer, Refusal)), after: Int)
}

type Message {
  /// One poll.
  Poll(poll: Poll, reply: Subject(Result(Answer, Refusal)))

  /// One piece of a frame the lane transmitted.
  Piece(piece: Piece, reply: Subject(Result(Nil, Refusal)))

  /// The laptop ends the feed.
  Detach(reply: Subject(Nil))

  /// One frame the gateway pushed. The sink runs on a gateway process and only
  /// hands the frame over, because a sink must not block.
  Pushed(frame: String)

  /// The gateway's flush marker, acknowledged once earlier pushes are out.
  Flushed(reply: Subject(Nil))

  /// The gateway closed the attachment.
  Closed

  /// The gateway process went down.
  GatewayDown(down: process.Down)

  /// A held poll's wait has passed.
  PollWaited

  /// No poll has arrived for a whole lease.
  LeaseElapsed

  /// An ended feed has been kept one lease.
  Forgotten

  /// The first message a feed handles, which arms its lease.
  Begun
}

type Data {
  Data(
    settings: Settings,
    self: Subject(Message),
    connection: Option(gateway.ConnectionHandle),
    queue: feed_queue.Queue,
    pieces: feed_pieces.Pieces,
    held: Option(Held),
  )
}

/// Starts a feed: takes custody of a connection permit, attaches to the
/// gateway, and answers a handle. Either failure is the refusal, with the words
/// that say which.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(feed) = feed_host.start(settings)
/// ```
pub fn start(settings: Settings) -> Result(Feed, String) {
  let started =
    sm.new_with_initialiser(start_budget_ms, initialise(settings, _))
    |> sm.on_event(handle)
    |> sm.unlinked
    |> sm.start

  // Each way the initialiser can fail is words the refused attach carries.
  case started {
    Ok(started) -> Ok(Feed(subject: started.data, pid: started.pid))
    Error(otp.InitFailed(reason)) -> Error(reason)
    Error(otp.InitTimeout) -> Error("the feed did not start in time")
    Error(otp.InitExited(_)) -> Error("the feed exited while starting")
  }
}

/// Takes the permit's custody, attaches, and watches the gateway. Both steps run
/// here and not in the caller, because the permit must belong to the process that
/// holds it, and the gateway monitors the attachment's socket, which is this
/// process.
fn initialise(
  settings: Settings,
  self: Subject(Message),
) -> Result(sm.Initialised(Phase, Data, Message, Subject(Message)), String) {
  use Nil <- result.try(settings.admit())
  use connection <- result.try(gateway.attach_authenticated_flushing(
    settings.hub,
    settings.binding,
    settings.check,
    fn(frame) { process.send(self, Pushed(frame)) },
    fn() { process.send(self, Closed) },
    settings.failed_reader,
    fn(reply) { process.send(self, Flushed(reply)) },
    process.self(),
  ))
  let watch = process.monitor(gateway.connection_pid(connection))
  let selector =
    process.new_selector()
    |> process.select(self)
    |> process.select_specific_monitor(watch, GatewayDown)
  let data =
    Data(
      settings:,
      self:,
      connection: Some(connection),
      queue: feed_queue.new(bootstrap.monotonic_time_ms()),
      pieces: feed_pieces.new(),
      held: None,
    )

  // The lease begins when the feed does, so a laptop that attaches and never
  // polls does not hold a gateway attachment and a permit forever.
  sm.initialised(Live, data)
  |> sm.selecting(selector)
  |> sm.returning(self)
  |> sm.continuing(Begun)
  |> Ok
}

// --- the handle the daemon holds -----------------------------------------------

/// The feed's process, which the directory monitors.
///
/// ## Examples
///
/// ```gleam
/// // process.monitor(feed_host.pid(feed))
/// ```
pub fn pid(feed: Feed) -> Pid {
  feed.pid
}

/// Answers a poll, waiting at most the poll's own wait and a little more. A feed
/// that does not answer is `NotYetOpen`, which the laptop polls again about.
///
/// ## Examples
///
/// ```gleam
/// // feed_host.poll(feed, remote_feed.Poll(token, 0, 5000))
/// ```
pub fn poll(feed: Feed, poll: Poll) -> Result(Answer, Refusal) {
  call.try_call(
    feed.subject,
    waiting: poll.wait_ms + poll_slack_ms,
    sending: Poll(poll, _),
  )
  |> result.map_error(unanswered)
  |> result.flatten
}

/// Admits one piece of a frame the lane transmitted.
///
/// ## Examples
///
/// ```gleam
/// // feed_host.send(feed, piece)
/// ```
pub fn send(feed: Feed, piece: Piece) -> Result(Nil, Refusal) {
  call.try_call(feed.subject, waiting: answer_ms, sending: Piece(piece, _))
  |> result.map_error(unanswered)
  |> result.flatten
}

/// Ends the feed and waits for it to have detached. A feed that is already gone
/// is ended.
///
/// ## Examples
///
/// ```gleam
/// // feed_host.detach(feed)
/// ```
pub fn detach(feed: Feed) -> Nil {
  case call.try_call(feed.subject, waiting: answer_ms, sending: Detach) {
    Ok(Nil) | Error(call.CalleeGone) | Error(call.NoReply) -> Nil
  }
}

/// What a call that got no answer means to the laptop. A feed that is gone ended,
/// and one that is merely slow is asked again.
fn unanswered(fault: call.CallFault) -> Refusal {
  case fault {
    call.CalleeGone -> remote_top.FeedEnded(remote_top.FeedLapsed)
    call.NoReply -> remote_top.NotYetOpen("the feed did not answer in time")
  }
}

// --- the transitions -----------------------------------------------------------

/// The one transition function: every phase and message pair is written.
fn handle(
  state: Phase,
  data: Data,
  message: Message,
) -> sm.Next(Phase, Data, Message) {
  case state, message {
    // The first message arms the lease, which no poll precedes.
    Live, Begun -> sm.keep(data) |> with_lease(data)
    Ended(_), Begun -> sm.keep(data)

    Live, Poll(poll:, reply:) -> poll_live(data, poll, reply)
    Ended(why), Poll(reply:, ..) -> {
      process.send(reply, Ok(ending_answer(data, why)))
      sm.keep(data)
    }

    Live, Piece(piece:, reply:) -> piece_live(data, piece, reply)
    Ended(why), Piece(reply:, ..) -> {
      process.send(reply, Error(remote_top.FeedEnded(why)))
      sm.keep(data)
    }

    Live, Detach(reply:) | Ended(_), Detach(reply:) -> {
      detached(data)
      process.send(reply, Nil)
      sm.stop()
    }

    Live, Pushed(frame:) -> queued(data, frame)

    // Nothing reads an ended feed's frames, and the attachment is gone.
    Ended(_), Pushed(_) -> sm.keep(data)

    Live, Flushed(reply:) | Ended(_), Flushed(reply:) -> {
      process.send(reply, Nil)
      sm.keep(data)
    }

    // The gateway closed the attachment, or the gateway itself went. The
    // attachment's own check says which: a check that still passes means the
    // session's run ended.
    Live, Closed -> finish(data, closing_reason(data))
    Live, GatewayDown(_) -> finish(data, remote_top.FeedStopped)
    Ended(_), Closed | Ended(_), GatewayDown(_) -> sm.keep(data)

    Live, PollWaited -> released(data)
    Live, LeaseElapsed -> lapsed_unless_renewed(data)

    // The timers of a live feed are cancelled on the way into `Ended`, and a
    // fire already in flight is dropped by the timer book, so these two are
    // unreachable. They keep the feed as it is.
    Ended(_), PollWaited | Ended(_), LeaseElapsed -> sm.keep(data)

    Live, Forgotten -> sm.keep(data)
    Ended(_), Forgotten -> sm.stop()
  }
}

// --- polls ---------------------------------------------------------------------

/// A poll to a live feed. It first releases a poll that is still held, because
/// the laptop that asked again has given up on the first. Then it acknowledges
/// `after`, which renews the lease, and either answers or holds.
fn poll_live(
  data: Data,
  poll: Poll,
  reply: Subject(Result(Answer, Refusal)),
) -> sm.Next(Phase, Data, Message) {
  let data = supersede(data)

  // A cursor the queue cannot honour is refused and changes nothing. Otherwise
  // the poll is answered with what the queue holds beyond `after`.
  case feed_queue.read(data.queue, poll.after, bootstrap.monotonic_time_ms()) {
    Error(cursor) -> {
      process.send(reply, Error(cursor_refusal(cursor)))
      sm.keep(data) |> sm.cancel_timeout(name: poll_timer)
    }
    Ok(reading) -> {
      let data = Data(..data, queue: reading.queue)

      // With no frame to answer and a wait to spend, the poll is held for the
      // first frame. A frame, or a wait of zero, answers it now.
      case reading.frames, poll.wait_ms {
        [], wait if wait > 0 ->
          sm.keep(Data(..data, held: Some(Held(reply:, after: poll.after))))
          |> sm.with_named_timeout(
            name: poll_timer,
            after: wait,
            sending: PollWaited,
          )
          |> with_lease(data)
        frames, _ -> {
          process.send(
            reply,
            Ok(remote_feed.Answer(first: reading.first, frames:, ended: None)),
          )
          sm.keep(data)
          |> sm.cancel_timeout(name: poll_timer)
          |> with_lease(data)
        }
      }
    }
  }
}

/// Answers a held poll with no frames, so that a laptop which gave up on a poll
/// the link delayed is never refused for asking again.
fn supersede(data: Data) -> Data {
  // A held poll is answered empty, and its `after` plus one is the number of the
  // frame it was still waiting for.
  case data.held {
    Some(Held(reply:, after:)) -> {
      process.send(
        reply,
        Ok(remote_feed.Answer(first: after + 1, frames: [], ended: None)),
      )
      Data(..data, held: None)
    }
    None -> data
  }
}

/// Answers the held poll with the frames that arrived, or with none when its
/// wait has passed. Acknowledgement and renewal happen again here, because the
/// laptop is still polling while it waits.
fn released(data: Data) -> sm.Next(Phase, Data, Message) {
  case data.held {
    None -> sm.keep(data)
    Some(Held(reply:, after:)) ->
      case feed_queue.read(data.queue, after, bootstrap.monotonic_time_ms()) {
        Ok(reading) -> {
          process.send(
            reply,
            Ok(remote_feed.Answer(
              first: reading.first,
              frames: reading.frames,
              ended: reading.ended,
            )),
          )
          let data = Data(..data, queue: reading.queue, held: None)
          sm.keep(data)
          |> sm.cancel_timeout(name: poll_timer)
          |> with_lease(data)
        }

        // The cursor was checked when the poll was held and nothing moves the
        // floor since, so this arm cannot be reached. It answers the poll anyway
        // rather than leave its caller to time out.
        Error(cursor) -> {
          process.send(reply, Error(cursor_refusal(cursor)))
          sm.keep(Data(..data, held: None))
          |> sm.cancel_timeout(name: poll_timer)
        }
      }
  }
}

/// What a poll whose `after` the queue cannot honour is told.
fn cursor_refusal(cursor: feed_queue.Cursor) -> Refusal {
  case cursor {
    feed_queue.AheadOfQueue ->
      remote_top.InvalidArgument("after is ahead of the frames this feed holds")
    feed_queue.BehindFloor ->
      remote_top.InvalidArgument("after is behind what was acknowledged")
  }
}

/// The answer an ended feed gives every poll: its ending and no frames.
fn ending_answer(data: Data, why: FeedEnd) -> Answer {
  remote_feed.Answer(
    first: feed_queue.last(data.queue) + 1,
    frames: [],
    ended: Some(why),
  )
}

/// Re-arms the lease after a poll, which is the only thing that renews it.
fn with_lease(
  step: sm.Next(Phase, Data, Message),
  data: Data,
) -> sm.Next(Phase, Data, Message) {
  sm.with_named_timeout(
    step,
    name: lease_timer,
    after: data.settings.lease_ms,
    sending: LeaseElapsed,
  )
}

/// The lease timer fired. The queue decides whether the lease has really run
/// out, so the rule lives in one place; a fire that came a moment early re-arms.
fn lapsed_unless_renewed(data: Data) -> sm.Next(Phase, Data, Message) {
  let queue =
    feed_queue.expire(
      data.queue,
      bootstrap.monotonic_time_ms(),
      data.settings.lease_ms,
    )

  // A queue that lapsed ends the feed. One that did not, because the timer fired
  // a moment early, waits out the rest of the lease.
  case feed_queue.ending(queue) {
    Some(why) -> finish(Data(..data, queue:), why)
    None -> sm.keep(Data(..data, queue:)) |> with_lease(data)
  }
}

// --- frames from the gateway -----------------------------------------------------

/// Queues one frame the gateway wrote. A frame that passes the queue's bound ends
/// the feed, and a frame that a held poll was waiting for releases it.
fn queued(data: Data, frame: String) -> sm.Next(Phase, Data, Message) {
  let queue = feed_queue.push(data.queue, frame, bootstrap.monotonic_time_ms())
  let data = Data(..data, queue:)

  // A frame that ended the feed is the end of it. A frame a held poll was waiting
  // for releases that poll, and any other frame waits in the queue for the next.
  case feed_queue.ending(queue), data.held {
    Some(why), _ -> finish(data, why)
    None, Some(Held(after:, ..)) ->
      case feed_queue.has_after(queue, after) {
        True -> released(data)
        False -> sm.keep(data)
      }
    None, None -> sm.keep(data)
  }
}

// --- frames from the lane --------------------------------------------------------

/// One piece of a frame the lane transmitted. The answer to the send is written
/// before a whole frame reaches the gateway, so the laptop's next poll and this
/// answer travel together.
fn piece_live(
  data: Data,
  piece: Piece,
  reply: Subject(Result(Nil, Refusal)),
) -> sm.Next(Phase, Data, Message) {
  // The answer to every outcome is written first. Only a frame that became whole
  // goes on to the filter.
  case feed_pieces.admit(data.pieces, piece) {
    feed_pieces.Held(pieces:) -> {
      process.send(reply, Ok(Nil))
      sm.keep(Data(..data, pieces:))
    }
    feed_pieces.Repeated -> {
      process.send(reply, Ok(Nil))
      sm.keep(data)
    }
    feed_pieces.Refused(why:) -> {
      process.send(reply, Error(remote_top.InvalidArgument(piece_words(why))))
      sm.keep(data)
    }
    feed_pieces.Completed(pieces:, frame:) -> {
      process.send(reply, Ok(Nil))
      dispatch(Data(..data, pieces:), frame)
    }
  }
}

/// What a refused piece is told.
fn piece_words(why: feed_pieces.Refusal) -> String {
  case why {
    feed_pieces.OutOfOrder -> "the piece does not follow the pieces admitted"
    feed_pieces.WrongFrame -> "the piece is not of the next frame"
    feed_pieces.Inconsistent -> "the piece names another size for its frame"
  }
}

/// Applies the filter's verdict to a whole frame.
fn dispatch(data: Data, frame: String) -> sm.Next(Phase, Data, Message) {
  case feed_filter.judge(frame) {
    feed_filter.Forward -> forwarded(data, frame)
    feed_filter.Forbid(id:) ->
      queued(data, error_frame(id, "forbidden", feed_filter.forbidden_words))
    feed_filter.Refuse(id:, words:) ->
      queued(data, error_frame(id, protocol.code_bad_request, words))
    feed_filter.Decide(id:, escalation:, decision:, expected_seq:) ->
      queued(
        data,
        outcome_frame(id, decided(data, escalation, decision, expected_seq)),
      )
    feed_filter.Withdraw(id:, decision:, expected_seq:) ->
      case decided(data, "", decision, expected_seq) {
        // The grant is gone, so the page is given the board as it now stands,
        // read by the gateway and encoded as the gateway encodes it.
        Ok(remote_escalation.Forgotten) ->
          forwarded(
            data,
            protocol.encode_command(protocol.CommandEnvelope(
              id:,
              command: protocol.PermissionsGet,
            )),
          )
        outcome -> queued(data, outcome_frame(id, outcome))
      }
  }
}

/// Hands a frame to the gateway as the lane wrote it and queues the reply. A
/// reply that does not come is the lane's unknown outcome, which its own deadline
/// reports, so nothing is queued and nothing is resent.
fn forwarded(data: Data, frame: String) -> sm.Next(Phase, Data, Message) {
  case data.connection {
    None -> sm.keep(data)
    Some(connection) ->
      case gateway.connection_request(connection, frame) {
        Ok(reply) -> queued(data, reply)
        Error(_) -> sm.keep(data)
      }
  }
}

/// Asks the hub to judge a decision through its relayed door, with the spawner's
/// name and ceiling.
fn decided(
  data: Data,
  escalation: String,
  decision: remote_escalation.Decision,
  expected_seq: Int,
) -> Result(remote_escalation.Answer, gateway.DecisionFailure) {
  let settings = data.settings
  gateway.decide_relayed(
    settings.hub,
    settings.spawner,
    settings.ceiling,
    escalation,
    decision,
    expected_seq,
    settings.decider,
  )
}

/// The reply frame for a hub's answer, in the gateway's own shape.
fn outcome_frame(
  id: Int,
  outcome: Result(remote_escalation.Answer, gateway.DecisionFailure),
) -> String {
  case outcome {
    Ok(remote_escalation.Decided(..)) | Ok(remote_escalation.Forgotten) ->
      reply_frame(
        id,
        protocol.MutationOutcome(
          json.Object([#("status", json.String("committed"))]),
        ),
      )
    Ok(remote_escalation.Stale(record:, reason:)) ->
      reply_frame(
        id,
        protocol.ErrorEvent(
          code: protocol.code_stale_approval,
          message: reason,
          details: Some(protocol.stale_approval_details(record)),
        ),
      )
    Ok(remote_escalation.Refused(reason:)) ->
      error_frame(id, protocol.code_bad_request, reason)

    // The outcome of a decision the hub did not answer is unknown, and the page
    // treats `internal` as unknown.
    Error(gateway.HubUnavailable) ->
      error_frame(
        id,
        protocol.code_internal,
        "the session's hub is unavailable",
      )
    Error(gateway.DecisionUnknown(reason:)) ->
      error_frame(
        id,
        protocol.code_internal,
        "the decision may not have been applied: " <> reason,
      )
  }
}

fn error_frame(id: Int, code: String, message: String) -> String {
  reply_frame(id, protocol.ErrorEvent(code:, message:, details: None))
}

/// The frame the box writes for the lane's request `id`: an event in the
/// gateway's own envelope, encoded by the box's `client/protocol`, so the page
/// reads it as it reads the gateway's reply.
fn reply_frame(id: Int, event: protocol.Event) -> String {
  protocol.encode_event(protocol.EventEnvelope(
    reply_to: Some(id),
    seq: None,
    event:,
  ))
}

// --- endings ---------------------------------------------------------------------

/// Why the gateway closed the attachment: its own check says. A check that
/// refuses is a revoked page, and one that still passes means the run ended.
fn closing_reason(data: Data) -> FeedEnd {
  case data.settings.check() {
    Error(_) -> remote_top.FeedRevoked
    Ok(_) -> remote_top.FeedStopped
  }
}

/// Detaches from the gateway, if still attached.
fn detached(data: Data) -> Nil {
  case data.connection {
    Some(connection) -> gateway.connection_detach(connection)
    None -> Nil
  }
}

/// Ends the feed: detaches, drops the queue and any partly received frame,
/// answers a held poll with the ending, and keeps the token for one more lease.
fn finish(data: Data, why: FeedEnd) -> sm.Next(Phase, Data, Message) {
  detached(data)
  let queue = feed_queue.end(data.queue, why, bootstrap.monotonic_time_ms())

  // A poll held for a frame learns why none will come.
  case data.held {
    Some(Held(reply:, ..)) ->
      process.send(
        reply,
        Ok(remote_feed.Answer(
          first: feed_queue.last(queue) + 1,
          frames: [],
          ended: Some(why),
        )),
      )
    None -> Nil
  }

  let data =
    Data(
      ..data,
      connection: None,
      queue:,
      pieces: feed_pieces.drop(data.pieces),
      held: None,
    )

  data.settings.ended()

  sm.transition(to: Ended(why), data:)
  |> sm.cancel_timeout(name: poll_timer)
  |> sm.cancel_timeout(name: lease_timer)
  |> sm.with_named_timeout(
    name: forget_timer,
    after: data.settings.lease_ms,
    sending: Forgotten,
  )
}
