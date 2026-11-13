//// The laptop's end of a live session page for a session on another
//// orchestrator: the stand-in for `ui_relay` when the gateway is not in this VM
//// (protocol-change/108, "The laptop's socket adapter").
////
//// A page's component talks to a `Transport` of three functions: `connect`,
//// `transmit` and `shut`. For a session of this daemon they start a `ui_relay`,
//// which attaches to the session's gateway and carries frames both ways. Here
//// the gateway is on the box, and nothing may be pushed across a link that can
//// drop, so this process pulls. It holds one feed that the socket already
//// attached (`top_relay.attach`), keeps one long poll open, hands the frames each
//// answer carries to the component's inbox as `connection_event.Incoming` exactly
//// as a local relay does, and sends the lane's own frames to the box in pieces.
//// The page, the strip, the approvals dock and the top bar are the existing code
//// paths. They see the same frames in the same order.
////
//// ## Where the rules are
////
//// Every decision about a poll is `feed_cursor`'s and every decision about what
//// to send next is `feed_outbox`'s. They are pure values, tested under fixed
//// seeds, and checked against the box's feed host by the P model
//// `protocol/models/live-relay` (`UiFeed.p`). This module owns only what a pure
//// value cannot: the mailbox, the monitors, the timers and the calls.
////
//// ## Calls run in tasks of their own
////
//// A poll is held at the box for up to five seconds, and the lane must be able to
//// transmit and shut meanwhile, so no call runs in this process. Each poll and
//// each piece is one weft run that returns its reply to a sink this process
//// selects. A run that is lost, or that outlives its deadline, is reported to
//// the same sink as nothing heard. Each exchange has a reply subject owned by its
//// own task, so an answer that arrives after the task is gone is delivered to a
//// process that no longer exists, and a late answer can neither reorder frames
//// nor fill this mailbox. At most one poll and one send are in flight, so this
//// mailbox holds at most the lane's own messages and two replies.
////
//// ## What the page is told when the link drops
////
//// A drop shorter than the box's lease costs nothing: polls fail, `feed_cursor`
//// asks again with the same `after` after a pause of 250 ms doubling to two
//// seconds, and the first answer after the link heals carries every frame the box
//// queued. If the lane gives up first, because a request it sent has had no reply
//// for ten seconds, it shuts its transport. A feed that last heard nothing ends
//// with `PeerUnreachable`, which draws a waiting page the browser reconnects, and
//// one that last heard the box ends with `ConnectionFailed`. A box that says the
//// feed is gone ends it with the ending it gave: a lapse is `ConnectionFailed`,
//// since the page redraws from a fresh attach, a stopped session is
//// `SessionStopped` and a revoked page is `AccessRevoked`.
////
//// ## Bounds
////
//// - One answer carries at most 512 frames and 1,048,576 bytes (`remote_feed`'s
////   decoder and the stable exchange's envelope), and one poll is in flight, so
////   at most that much is handed to the component's inbox per round trip.
//// - The outbox holds at most `feed_outbox.max_frames` frames and
////   `feed_outbox.max_bytes` bytes. A lane that transmits past that ends the feed.
//// - The feed's token is a secret of this process. It is never logged or drawn.
////
//// ## Flow
////
//// `start` → `initialise` → `handle` → `polled` → `sent` → `finish`
////
//// 1. `start` returns a handle at once and `initialise` answers the component's
////    open, well inside its one-second start budget.
//// 2. `handle` is the one transition function.
//// 3. `polled` turns a poll task's reply into the cursor's step and acts on it.
//// 4. `sent` does the same for a piece task's reply and the outbox.
//// 5. `finish` tells the component and the page's socket why the feed ended.

import client/remote/feed_cursor
import client/remote/feed_outbox
import client/remote/top_relay
import client/remote_feed
import client/remote_top
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{None, Some}
import gleam/otp/actor as otp
import session_view/connection_event
import web_view/ending.{type Ending}
import weft
import weft/state_machine as sm

/// How long a poll asks the box to hold it, in milliseconds.
const wait_ms = 5000

/// How long past `top_relay`'s own call budget a task may run before it is
/// abandoned, in milliseconds. The call has a deadline of its own, so this only
/// covers a task that never returns.
const task_slack_ms = 4000

/// The timer names. Each belongs to a piece of work and not to a phase.
const poll_timer = "poll"

const send_timer = "send"

/// Everything a feed client needs, fixed when it starts.
pub type Settings {
  Settings(
    /// The laptop's way of reaching orchestrators.
    relay: top_relay.Relay,
    /// The `[orchestrators.<name>]` key the session lives on.
    orchestrator: String,
    /// What the box answered to the attach: the token, epoch and incarnation.
    /// The token is a secret of this process.
    attached: remote_feed.Attached,
    /// Whether the page is still the owner's open operating page. It is read
    /// before every poll, and the `Error` carries the ending the page draws.
    open: fn() -> Result(Nil, Ending),
    /// The component's inbox, which receives every frame and the close.
    inbox: Subject(connection_event.Message),
    /// The component's process, which this process monitors.
    component: Pid,
    /// Called once when the feed ends, so the page's socket can close with the
    /// code the ending calls for.
    ended: fn(Ending) -> Nil,
  )
}

/// A running feed client: the handle the component's transport holds.
pub opaque type Feed {
  Feed(subject: Subject(Message))
}

/// The feed client's phase. A feed has none of its own beyond being live, and
/// whether the link is up is `feed_cursor`'s count of polls that went unanswered.
type Phase {
  Live
}

/// What a send task reports.
type Sent {
  /// The box admitted the piece.
  Admitted

  /// Nothing was heard, so the same piece is sent again.
  Unheard

  /// The feed is over for this reason.
  Gone(why: remote_top.FeedEnd)

  /// The box refused or garbled the send, or is not the box that was attached.
  Failed
}

type Message {
  /// The first message: asks the first poll.
  Begun

  /// One frame the lane transmitted.
  Transmit(frame: String)

  /// The lane closed its transport.
  Shut

  /// A poll task's reply, or the report that it was lost.
  PollReported(pulled: weft.Pulled(#(Int, feed_cursor.Reply), Nil))

  /// A send task's reply, or the report that it was lost.
  SendReported(pulled: weft.Pulled(#(Int, Int, Sent), Nil))

  /// The pause after a poll that went unanswered has passed.
  PollDue

  /// The pause after a piece that went unanswered has passed.
  SendDue

  /// The component exited.
  ComponentDown(down: process.Down)
}

type Data {
  Data(
    settings: Settings,
    cursor: feed_cursor.Cursor,
    outbox: feed_outbox.Outbox,
    polls: Subject(weft.Pulled(#(Int, feed_cursor.Reply), Nil)),
    sends: Subject(weft.Pulled(#(Int, Int, Sent), Nil)),
  )
}

/// Starts a feed client for the component's page and returns at once. The attach
/// already happened, so `opened` is answered with the handle before any call is
/// made, and the first poll goes out from the process's first message.
///
/// ## Examples
///
/// ```gleam
/// // ui_feed.start(settings, opened)
/// ```
pub fn start(settings: Settings, opened: Subject(Result(Feed, String))) -> Nil {
  let started =
    sm.new_with_initialiser(1000, initialise(settings, _))
    |> sm.on_event(handle)
    |> sm.unlinked
    |> sm.start

  // A start that fails is the daemon's failure and not the person's: the page is
  // told that the daemon was not ready, and its socket closes with a retry code.
  case started {
    Ok(started) -> process.send(opened, Ok(Feed(started.data)))
    Error(otp.InitFailed(_))
    | Error(otp.InitTimeout)
    | Error(otp.InitExited(_)) -> {
      process.send(opened, Error(ending.reason(ending.DaemonNotReady)))
      settings.ended(ending.DaemonNotReady)
    }
  }
}

/// Builds the process: the monitor on the component, the two sinks the calls
/// report to, and the selector over them.
fn initialise(
  settings: Settings,
  self: Subject(Message),
) -> Result(sm.Initialised(Phase, Data, Message, Subject(Message)), String) {
  let watch = process.monitor(settings.component)
  let polls = process.new_subject()
  let sends = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(self)
    |> process.select_map(polls, PollReported)
    |> process.select_map(sends, SendReported)
    |> process.select_specific_monitor(watch, ComponentDown)
  let data =
    Data(
      settings:,
      cursor: feed_cursor.new(),
      outbox: feed_outbox.new(),
      polls:,
      sends:,
    )

  // The first poll goes out from the first message, after this initialiser has
  // returned, so the component's start is not held by it.
  sm.initialised(Live, data)
  |> sm.selecting(selector)
  |> sm.returning(self)
  |> sm.continuing(Begun)
  |> Ok
}

/// Writes one frame for the lane. It is queued and sent in pieces, one at a time.
///
/// ## Examples
///
/// ```gleam
/// // ui_feed.transmit(feed, frame)
/// ```
pub fn transmit(feed: Feed, frame: String) -> Nil {
  process.send(feed.subject, Transmit(frame))
}

/// Closes the lane's transport: the feed ends, detaches and exits.
///
/// ## Examples
///
/// ```gleam
/// // ui_feed.shut(feed)
/// ```
pub fn shut(feed: Feed) -> Nil {
  process.send(feed.subject, Shut)
}

// --- the transitions ---------------------------------------------------------

/// The one transition function: every phase and message pair is written.
fn handle(
  state: Phase,
  data: Data,
  message: Message,
) -> sm.Next(Phase, Data, Message) {
  case state, message {
    Live, Begun | Live, PollDue -> poll(data)
    Live, SendDue -> pump(data)
    Live, Transmit(frame:) -> queued(data, frame)
    Live, PollReported(pulled:) -> polled(data, pulled)
    Live, SendReported(pulled:) -> sent(data, pulled)

    // The lane gave up. A feed whose last poll went unanswered is a link that is
    // down, which the page draws as waiting; one that last heard the box failed.
    Live, Shut -> {
      // No answer to the last poll means the box was not heard from.
      let why = case feed_cursor.silent_for(data.cursor) {
        0 -> ending.ConnectionFailed
        _ -> ending.PeerUnreachable
      }

      finish(data, why, Detach)
    }

    // The browser went away. Nobody is left to tell, so only the box is.
    Live, ComponentDown(_) -> {
      detach(data)
      sm.stop()
    }
  }
}

// --- polls ---------------------------------------------------------------------

/// Asks the next poll, unless the page is no longer the owner's open page, which
/// ends the feed with the ending the page's own check names.
fn poll(data: Data) -> sm.Next(Phase, Data, Message) {
  // A page that ended asks nothing more of the box.
  case data.settings.open() {
    Error(why) -> finish(data, why, Detach)
    Ok(Nil) -> {
      let #(cursor, order) = feed_cursor.ask(data.cursor)
      let settings = data.settings

      // The task returns the poll's number with its reply, so a reply can be
      // matched to the poll it answers.
      run(data.polls, fn() {
        Ok(#(
          order.poll,
          poll_reply(top_relay.poll(
            settings.relay,
            settings.orchestrator,
            settings.attached,
            order.after,
            wait_ms,
          )),
        ))
      })
      sm.keep(Data(..data, cursor:)) |> sm.cancel_timeout(name: poll_timer)
    }
  }
}

/// Sorts what a poll call returned into what `feed_cursor` reads.
fn poll_reply(
  returned: Result(remote_feed.Answer, top_relay.Failure),
) -> feed_cursor.Reply {
  case returned {
    Ok(answer) -> feed_cursor.Answered(answer)
    Error(top_relay.Refused(refusal:)) -> feed_cursor.Refused(refusal)
    Error(top_relay.Unreachable) | Error(top_relay.Silent) -> feed_cursor.Silent
    Error(top_relay.Unreadable(_)) | Error(top_relay.RequestTooLarge) ->
      feed_cursor.Garbled
    Error(top_relay.NotConfigured(_))
    | Error(top_relay.OlderBuild)
    | Error(top_relay.Unsupported)
    | Error(top_relay.PeerChanged)
    | Error(top_relay.InvalidPeer) -> feed_cursor.Replaced
  }
}

/// A poll task reported. A reply is read by the cursor, and a task that was lost
/// is the poll in flight that nobody answered.
fn polled(
  data: Data,
  pulled: weft.Pulled(#(Int, feed_cursor.Reply), Nil),
) -> sm.Next(Phase, Data, Message) {
  case pulled {
    weft.PulledOutcome(weft.Completed(value: #(id, reply), ..)) ->
      stepped(data, id, reply)

    // The task died or was cut off by its deadline. Its poll got no answer, and
    // the cursor knows which poll that was.
    weft.PulledOutcome(weft.Failed(..))
    | weft.PulledOutcome(weft.Crashed(..))
    | weft.PulledOutcome(weft.Abandoned(..))
    | weft.PulledOutcome(weft.NeverStarted(..))
    | weft.PulledOutcome(weft.DrainProofLost(..))
    | weft.PulledOutcome(weft.CancellationUnconfirmed(..)) ->
      case feed_cursor.in_flight(data.cursor) {
        Some(id) -> stepped(data, id, feed_cursor.Silent)
        None -> sm.keep(data)
      }

    // The run's bookkeeping messages carry no outcome.
    weft.AllDelivered | weft.NotYet | weft.RunLost(_) -> sm.keep(data)
  }
}

/// Acts on what the cursor says a reply means.
fn stepped(
  data: Data,
  id: Int,
  reply: feed_cursor.Reply,
) -> sm.Next(Phase, Data, Message) {
  let #(cursor, step) = feed_cursor.heard(data.cursor, id, reply)
  let data = Data(..data, cursor:)

  // Each step is one thing for the page: nothing, frames, a pause, or an end.
  case step {
    feed_cursor.Stray -> sm.keep(data)

    // The frames reach the page in the order they were numbered, and the next
    // poll goes out at once, which is how the page keeps receiving.
    feed_cursor.Deliver(frames:) -> {
      handed_on(data, frames)
      poll(data)
    }

    feed_cursor.Retry(pause_ms:) ->
      sm.keep(data)
      |> sm.with_named_timeout(
        name: poll_timer,
        after: pause_ms,
        sending: PollDue,
      )

    // The box said the feed is gone, so there is nothing left to detach.
    feed_cursor.Over(why:) -> finish(data, ending_of(why), Leave)
    feed_cursor.Broken(_) -> finish(data, ending.ConnectionFailed, Detach)
  }
}

/// Hands each frame to the component's inbox, as a local relay does.
fn handed_on(data: Data, frames: List(String)) -> Nil {
  // The frames go in the order the box numbered them.
  case frames {
    [] -> Nil
    [frame, ..rest] -> {
      process.send(data.settings.inbox, connection_event.Incoming(frame))
      handed_on(data, rest)
    }
  }
}

/// The ending the page draws for a feed the box ended.
fn ending_of(why: remote_top.FeedEnd) -> Ending {
  case why {
    // The page redraws from a fresh attach, which is a new feed.
    remote_top.FeedLapsed -> ending.ConnectionFailed
    remote_top.FeedStopped -> ending.SessionStopped
    remote_top.FeedRevoked -> ending.AccessRevoked
  }
}

// --- sends ---------------------------------------------------------------------

/// Queues a frame the lane transmitted and sends the piece that is due. A frame
/// the outbox refuses ends the feed, because the lane has written more than the
/// feed can hold.
fn queued(data: Data, frame: String) -> sm.Next(Phase, Data, Message) {
  case feed_outbox.push(data.outbox, frame) {
    Ok(outbox) -> pump(Data(..data, outbox:))
    Error(_) -> finish(data, ending.ConnectionFailed, Detach)
  }
}

/// Sends the piece that is due, if one is, in a task of its own.
fn pump(data: Data) -> sm.Next(Phase, Data, Message) {
  let #(outbox, due) = feed_outbox.take(data.outbox)
  let data = Data(..data, outbox:)

  // One piece is in flight at a time, so nothing is due while one is out.
  case due {
    None -> sm.keep(data)
    Some(feed_outbox.Due(n:, offset:, total:, text:)) -> {
      let settings = data.settings
      let piece =
        remote_feed.Piece(
          feed: settings.attached.feed,
          n:,
          offset:,
          total:,
          text:,
        )
      run(data.sends, fn() {
        Ok(#(
          n,
          offset,
          send_reply(top_relay.send_piece(
            settings.relay,
            settings.orchestrator,
            settings.attached,
            piece,
          )),
        ))
      })
      sm.keep(data) |> sm.cancel_timeout(name: send_timer)
    }
  }
}

/// Sorts what a send call returned.
fn send_reply(returned: Result(Nil, top_relay.Failure)) -> Sent {
  case returned {
    Ok(Nil) -> Admitted
    Error(top_relay.Refused(remote_top.FeedEnded(why:))) -> Gone(why)
    Error(top_relay.Unreachable) | Error(top_relay.Silent) -> Unheard
    Error(top_relay.Refused(_))
    | Error(top_relay.Unreadable(_))
    | Error(top_relay.RequestTooLarge)
    | Error(top_relay.NotConfigured(_))
    | Error(top_relay.OlderBuild)
    | Error(top_relay.Unsupported)
    | Error(top_relay.PeerChanged)
    | Error(top_relay.InvalidPeer) -> Failed
  }
}

/// A send task reported.
fn sent(
  data: Data,
  pulled: weft.Pulled(#(Int, Int, Sent), Nil),
) -> sm.Next(Phase, Data, Message) {
  case pulled {
    weft.PulledOutcome(weft.Completed(value: #(n, offset, reply), ..)) ->
      sent_reply(data, n, offset, reply)

    // A lost task is a piece nobody answered, which is sent again.
    weft.PulledOutcome(weft.Failed(..))
    | weft.PulledOutcome(weft.Crashed(..))
    | weft.PulledOutcome(weft.Abandoned(..))
    | weft.PulledOutcome(weft.NeverStarted(..))
    | weft.PulledOutcome(weft.DrainProofLost(..))
    | weft.PulledOutcome(weft.CancellationUnconfirmed(..)) -> resend(data)

    weft.AllDelivered | weft.NotYet | weft.RunLost(_) -> sm.keep(data)
  }
}

/// Acts on a send task's reply.
fn sent_reply(
  data: Data,
  n: Int,
  offset: Int,
  reply: Sent,
) -> sm.Next(Phase, Data, Message) {
  case reply {
    // The next piece goes out at once. The box admits a piece once, so the
    // gateway receives the lane's frame at most once however often it was sent.
    Admitted ->
      pump(Data(..data, outbox: feed_outbox.admitted(data.outbox, n, offset)))
    Unheard -> resend(data)
    Gone(why:) -> finish(data, ending_of(why), Leave)
    Failed -> finish(data, ending.ConnectionFailed, Detach)
  }
}

/// Makes the piece in flight due again after a pause.
fn resend(data: Data) -> sm.Next(Phase, Data, Message) {
  let #(outbox, pause) = feed_outbox.unanswered(data.outbox)
  sm.keep(Data(..data, outbox:))
  |> sm.with_named_timeout(name: send_timer, after: pause, sending: SendDue)
}

// --- calls and endings ---------------------------------------------------------

/// Runs one call in a task of its own that reports to `sink` and dies with this
/// process. The deadline is a backstop for a task that never returns, since the
/// call has its own.
fn run(
  sink: Subject(weft.Pulled(a, Nil)),
  call: fn() -> Result(a, Nil),
) -> Nil {
  let _ =
    weft.new([call])
    |> weft.deadline(top_relay.call_ms + top_relay.connect_ms + task_slack_ms)
    |> weft.cancel_when_exits(process.self())
    |> weft.start_relayed(to: sink)
  Nil
}

/// Whether the box still holds the feed, so that ending it should tell the box.
type Holding {
  /// The box may hold the feed, so it is told.
  Detach

  /// The box said the feed is gone.
  Leave
}

/// Ends the feed: the component is told why through its inbox, the page's socket
/// through `ended`, and then the box through a detach if it may still hold the
/// feed. The page is told first, so a box that is slow to answer the detach holds
/// nothing up.
fn finish(
  data: Data,
  why: Ending,
  holding: Holding,
) -> sm.Next(Phase, Data, Message) {
  let settings = data.settings
  process.send(settings.inbox, connection_event.Closed(ending.reason(why)))
  settings.ended(why)

  // A box that said the feed is gone has nothing to detach.
  case holding {
    Detach -> detach(data)
    Leave -> Nil
  }

  sm.stop()
}

/// Tells the box the feed is over. The call has a deadline of its own, and the
/// page has already been told, so this process is held for at most that long
/// while it exits; no other work waits on it.
fn detach(data: Data) -> Nil {
  let settings = data.settings
  let _ =
    top_relay.detach(settings.relay, settings.orchestrator, settings.attached)
  Nil
}
