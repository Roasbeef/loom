//// The laptop's feed client against the box's own code, in one VM
//// (protocol-change/108, slice 3).
////
//// The box is `support/feed_rig`: a real registry, a real `TopHost`, the real
//// stable endpoint and a real gateway for one relayed session, exactly as
//// `feed_host_test` builds them. The laptop is the production `top_relay` and
//// `peer_client`, and `ui_feed` as the page's transport. Nothing between the
//// lane's frames and the gateway is restated: a frame the test transmits is
//// cut, sent, filtered, judged by the gateway's decoder and answered, and the
//// answer is polled, numbered, decoded and handed to the component's inbox.
////
//// The link between the two is a dial a test can cut and restore. A drop shorter
//// than the box's lease is invisible to the page; a drop the lane gives up on
//// shows the waiting state, and a fresh attach after the link is restored reads
//// the same session.

import client/daemon/ui_feed
import client/protocol
import client/remote/peer_client
import client/remote/top_relay
import client/remote_feed
import client/remote_top
import core/json
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import session_view/connection_event
import support/feed_rig.{type Rig}
import web_view/ending
import weft/actor

type Link {
  Up
  Down
}

type LinkMessage {
  Cut
  Restore
  Ask(reply: Subject(Link))
  Refusals(reply: Subject(Int))
}

/// A link a test cuts and restores, read by every dial. It counts the dials it
/// refused while cut, so a test waits for the feed to have met the cut and does
/// not guess with a sleep.
fn link() -> Subject(LinkMessage) {
  let assert Ok(started) =
    actor.new(#(Up, 0))
    |> actor.on_message(fn(state: #(Link, Int), message: LinkMessage) {
      case message {
        Cut -> actor.continue(#(Down, state.1))
        Restore -> actor.continue(#(Up, state.1))
        Ask(reply:) -> {
          process.send(reply, state.0)
          case state.0 {
            Up -> actor.continue(state)
            Down -> actor.continue(#(Down, state.1 + 1))
          }
        }
        Refusals(reply:) -> {
          process.send(reply, state.1)
          actor.continue(state)
        }
      }
    })
    |> actor.start
    as "the link starts"
  started.data
}

/// Waits until the link has refused at least `count` dials, which is the feed
/// having met the cut at least that many times.
fn met_the_cut(through: Subject(LinkMessage), count: Int, tries: Int) -> Nil {
  case process.call(through, waiting: 1000, sending: Refusals) >= count {
    True -> Nil
    False ->
      case tries {
        0 -> panic as "the feed never met the cut"
        _ -> {
          process.sleep(50)
          met_the_cut(through, count, tries - 1)
        }
      }
  }
}

fn relay_over(rig: Rig, through: Subject(LinkMessage)) -> top_relay.Relay {
  top_relay.through(
    fn(_name) {
      case process.call(through, waiting: 1000, sending: Ask) {
        Up -> Ok(rig.peer)
        Down -> Error(top_relay.Unreachable)
      }
    },
    top_relay.production(),
  )
}

type Page {
  Page(
    feed: ui_feed.Feed,
    inbox: Subject(connection_event.Message),
    ended: Subject(ending.Ending),
  )
}

/// Attaches a feed on the rig's session as the laptop's page would and starts the
/// feed client over it.
fn open(relay: top_relay.Relay, rig: Rig) -> Page {
  let assert Ok(attached) =
    top_relay.attach(
      relay,
      "box",
      remote_feed.Attach(
        session: rig.session,
        principal: "page-1",
        name: "Laptop page",
      ),
    )
    as "the attach is admitted"
  let inbox = process.new_subject()
  let ended = process.new_subject()
  let opened = process.new_subject()
  ui_feed.start(
    ui_feed.Settings(
      relay:,
      orchestrator: "box",
      attached:,
      open: fn() { Ok(Nil) },
      inbox:,
      component: process.self(),
      ended: fn(why) { process.send(ended, why) },
    ),
    opened,
  )
  let assert Ok(Ok(feed)) = process.receive(opened, 2000)
    as "the feed client opens"
  Page(feed:, inbox:, ended:)
}

fn command(id: Int, command: protocol.Command) -> String {
  protocol.encode_command(protocol.CommandEnvelope(id:, command:))
}

/// Whether a frame is the reply to request `id`.
fn reply_to(id: Int) -> fn(String) -> Bool {
  fn(frame) {
    case protocol.decode_event(frame) {
      Ok(protocol.EventEnvelope(reply_to: Some(found), ..)) -> found == id
      Ok(protocol.EventEnvelope(reply_to: None, ..)) | Error(_) -> False
    }
  }
}

/// The frames the page's inbox receives, up to and including the first that
/// satisfies `wanted`, or what arrived before `within_ms` ran out with nothing
/// more.
fn until(
  page: Page,
  wanted: fn(String) -> Bool,
  within_ms: Int,
) -> Option(List(String)) {
  case process.receive(page.inbox, within_ms) {
    Ok(connection_event.Incoming(text:)) ->
      case wanted(text) {
        True -> Some([text])
        False ->
          until(page, wanted, within_ms)
          |> option.map(fn(rest) { [text, ..rest] })
      }
    Ok(_) | Error(Nil) -> None
  }
}

/// Receives whatever the box has already pushed to the page, until the inbox has
/// been quiet for a moment. The gateway pushes presence and the like on its own,
/// so a test that asserts the page is quiet during a cut first lets those land.
fn settled(page: Page) -> Nil {
  case process.receive(page.inbox, 300) {
    Ok(_) -> settled(page)
    Error(Nil) -> Nil
  }
}

// --- the page reaches the session ---------------------------------------------

pub fn a_frame_the_page_sends_reaches_the_session_and_its_reply_reaches_the_page_test() {
  let rig = feed_rig.rig("page", feed_rig.watching, remote_feed.lease_ms)
  let page = open(relay_over(rig, link()), rig)

  // The lane subscribes, as a page does when its component opens.
  ui_feed.transmit(page.feed, command(1, protocol.Subscribe(rig.session, None)))
  let assert Some(_) = until(page, reply_to(1), 6000)
    as "the subscribe is answered through the feed"

  // A prompt the page sends is the box session's, and is answered once.
  ui_feed.transmit(page.feed, command(2, protocol.Prompt("main", "hello")))
  let assert Some(frames) = until(page, reply_to(2), 6000)
    as "the prompt is answered through the feed"
  assert list.count(frames, reply_to(2)) == 1
  assert feed_rig.prompts(rig) == ["hello"]
}

// --- the link ------------------------------------------------------------------

pub fn a_drop_shorter_than_the_lease_is_invisible_to_the_page_test() {
  let rig = feed_rig.rig("short-drop", feed_rig.watching, remote_feed.lease_ms)
  let through = link()
  let page = open(relay_over(rig, through), rig)
  ui_feed.transmit(page.feed, command(1, protocol.Subscribe(rig.session, None)))
  let assert Some(_) = until(page, reply_to(1), 6000)
    as "the subscribe is answered before the drop"

  // The link is down while polls fail and the page shows nothing at all.
  settled(page)
  process.send(through, Cut)
  met_the_cut(through, 2, 200)
  assert process.receive(page.inbox, 300) == Error(Nil)
  assert process.receive(page.ended, 0) == Error(Nil)

  // When it comes back the same feed carries the next frame, with no new attach
  // and no ending.
  process.send(through, Restore)
  ui_feed.transmit(page.feed, command(2, protocol.Prompt("main", "back")))
  let assert Some(_) = until(page, reply_to(2), 8000)
    as "the prompt is answered after the link healed"
  assert feed_rig.prompts(rig) == ["back"]
  assert process.receive(page.ended, 0) == Error(Nil)
}

pub fn a_drop_the_lane_gives_up_on_ends_the_feed_and_a_fresh_attach_reads_the_same_session_test() {
  let rig = feed_rig.rig("long-drop", feed_rig.watching, remote_feed.lease_ms)
  let through = link()
  let relay = relay_over(rig, through)
  let page = open(relay, rig)
  ui_feed.transmit(page.feed, command(1, protocol.Subscribe(rig.session, None)))
  let assert Some(_) = until(page, reply_to(1), 6000)
    as "the subscribe is answered before the drop"
  ui_feed.transmit(page.feed, command(2, protocol.Prompt("main", "kept")))
  let assert Some(_) = until(page, reply_to(2), 6000)
    as "the prompt is answered before the drop"

  // The link goes down and the lane gives up on a request in flight. The page
  // ends the feed with a retry, and the component has drawn the waiting page.
  settled(page)
  process.send(through, Cut)
  met_the_cut(through, 1, 200)
  assert process.receive(page.inbox, 300) == Error(Nil)
  ui_feed.shut(page.feed)
  assert process.receive(page.inbox, 3000)
    == Ok(connection_event.Closed(ending.reason(ending.ConnectionFailed)))
  assert process.receive(page.ended, 1000) == Ok(ending.ConnectionFailed)

  // While the link is down a fresh attach fails, which is the socket's
  // waiting page.
  assert top_relay.attach(
      relay,
      "box",
      remote_feed.Attach(session: rig.session, principal: "page-1", name: "x"),
    )
    == Error(top_relay.Unreachable)

  // When it is restored the new page's feed reads the session as it was.
  process.send(through, Restore)
  let again = open(relay, rig)
  ui_feed.transmit(
    again.feed,
    command(1, protocol.Subscribe(rig.session, None)),
  )
  let assert Some(_) = until(again, reply_to(1), 6000)
    as "the subscribe is answered through the new feed"
  assert feed_rig.prompts(rig) == ["kept"]
}

// A frame the lane queued when its feed ended was never sent, and the next feed
// does not send it: the outbox belongs to the feed client process, which dies
// with the feed, and nothing resends it. The lane learns it was not sent because
// the feed ended, and its own rule for a command with no reply applies.
pub fn a_prompt_queued_when_the_feed_ends_is_not_sent_by_the_next_feed_test() {
  let rig = feed_rig.rig("no-resend", feed_rig.watching, remote_feed.lease_ms)
  let through = link()
  let relay = relay_over(rig, through)
  let page = open(relay, rig)
  ui_feed.transmit(page.feed, command(1, protocol.Subscribe(rig.session, None)))
  let assert Some(_) = until(page, reply_to(1), 6000)
    as "the subscribe is answered before the cut"

  // With the link cut the prompt cannot be sent, so it waits in this feed's
  // outbox and its send meets the cut with the polls.
  settled(page)
  process.send(through, Cut)
  met_the_cut(through, 1, 200)
  ui_feed.transmit(page.feed, command(2, protocol.Prompt("main", "never")))
  met_the_cut(through, 3, 200)
  ui_feed.shut(page.feed)
  assert process.receive(page.inbox, 3000)
    == Ok(connection_event.Closed(ending.reason(ending.ConnectionFailed)))

  // The next feed starts with an empty outbox, and the session never sees it.
  process.send(through, Restore)
  let again = open(relay, rig)
  ui_feed.transmit(
    again.feed,
    command(1, protocol.Subscribe(rig.session, None)),
  )
  let assert Some(_) = until(again, reply_to(1), 6000)
    as "the subscribe is answered through the new feed"
  process.sleep(1500)
  assert feed_rig.prompts(rig) == []
}

// --- the fence -----------------------------------------------------------------

pub fn a_call_against_another_epoch_is_stale_and_never_reaches_a_feed_test() {
  let rig = feed_rig.rig("stale", feed_rig.watching, remote_feed.lease_ms)
  let body =
    remote_feed.encode_request(remote_feed.DetachRequest(
      "0123456789abcdef0123456789abcdef",
    ))
  assert peer_client.call_at(
      rig.peer,
      "an-epoch-the-box-does-not-serve",
      remote_feed.detach_revision,
      body,
      3000,
    )
    == Error(peer_client.Stale)

  // The epoch the box serves is accepted, with no discovery first, and a token
  // the box does not hold is answered as a detach of a feed that is gone.
  assert peer_client.call_at(
      rig.peer,
      feed_rig.epoch,
      remote_feed.detach_revision,
      body,
      3000,
    )
    == Ok(Ok(json.Null))
}

pub fn a_poll_for_a_feed_the_box_forgot_is_refused_as_ended_test() {
  let rig = feed_rig.rig("forgot", feed_rig.watching, remote_feed.lease_ms)
  let body =
    remote_feed.encode_request(
      remote_feed.PollRequest(remote_feed.Poll(
        feed: "0123456789abcdef0123456789abcdef",
        after: 0,
        wait_ms: 0,
      )),
    )
  assert peer_client.call_at(
      rig.peer,
      feed_rig.epoch,
      remote_feed.feed_revision,
      body,
      3000,
    )
    == Ok(Error(remote_top.FeedEnded(remote_top.FeedLapsed)))
}
