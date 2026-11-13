//// The laptop's feed client at the process (protocol-change/108, "Hostile frames,
//// toward the laptop").
////
//// The box in these tests is a real stable endpoint on this node, served by a
//// `TopHost` whose four feed functions a test scripts, reached through the
//// production `top_relay` and `peer_client.call_at`, so the encoding, the
//// decoders and the epoch fence are the real ones. A test that needs a box that
//// answers garbage points the relay at a fake endpoint that replies with
//// whatever text the test chose. The relay's timing is shortened so a lost
//// answer is noticed inside a test.
////
//// What each test shows is stated in its name, and every one ends with the
//// page told why, through the component's inbox and through the page socket's
//// `ended` callback, because those two are all a feed client has to say.

import client/daemon/ui_feed
import client/remote/address.{type Address}
import client/remote/orchestrator_port
import client/remote/peer_codec
import client/remote/peer_service.{type Message as PeerMessage}
import client/remote/top_relay
import client/remote_feed
import client/remote_top
import core/json
import gleam/erlang/node
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/connection_event
import web_view/ending.{type Ending}
import weft/actor

const token = "0123456789abcdef0123456789abcdef"

fn quick() -> top_relay.Timing {
  top_relay.Timing(
    retry_window_ms: 1200,
    create_ms: 150,
    call_ms: 150,
    first_pause_ms: 10,
    longest_pause_ms: 40,
  )
}

fn attached() -> remote_feed.Attached {
  remote_feed.Attached(
    feed: token,
    epoch: "epoch-test",
    incarnation: "incarnation-1",
    label: remote_feed.Label(
      name: "work",
      placement: remote_top.Workspace(executor: "exec", name: "repo"),
    ),
  )
}

// --- a scripted box -------------------------------------------------------------

type Reply =
  Result(remote_feed.Answer, remote_top.Refusal)

/// The next scripted reply to a poll, then empty answers paced so a test box does
/// not spin.
fn script(replies: List(Reply)) -> fn(remote_feed.Poll) -> Reply {
  let assert Ok(started) =
    actor.new(replies)
    |> actor.on_message(fn(left, reply_to: Subject(Option(Reply))) {
      case left {
        [next, ..rest] -> {
          process.send(reply_to, Some(next))
          actor.continue(rest)
        }
        [] -> {
          process.send(reply_to, None)
          actor.continue([])
        }
      }
    })
    |> actor.start
    as "the script starts"
  fn(poll: remote_feed.Poll) {
    case
      process.call(started.data, waiting: 1000, sending: fn(reply) { reply })
    {
      Some(next) -> next
      None -> {
        process.sleep(30)
        Ok(remote_feed.Answer(first: poll.after + 1, frames: [], ended: None))
      }
    }
  }
}

fn answer(first: Int, frames: List(String)) -> Reply {
  Ok(remote_feed.Answer(first:, frames:, ended: None))
}

fn host(
  poll: fn(remote_feed.Poll) -> Reply,
  seen: Subject(String),
) -> orchestrator_port.TopHost {
  orchestrator_port.TopHost(
    ..orchestrator_port.refusing_top(),
    feeds: remote_feed.Host(
      attach: fn(_node, _attach) { Error(remote_top.TopLevelOff) },
      poll: fn(_node, polled: remote_feed.Poll) {
        process.send(seen, "poll " <> string.inspect(polled.after))
        poll(polled)
      },
      send: fn(_node, piece: remote_feed.Piece) {
        process.send(
          seen,
          "send "
            <> string.inspect(piece.n)
            <> " "
            <> string.inspect(piece.offset)
            <> " "
            <> piece.text,
        )
        Ok(Nil)
      },
      detach: fn(_node, _feed) {
        process.send(seen, "detach")
        Ok(Nil)
      },
    ),
  )
}

fn serving(top: orchestrator_port.TopHost) -> Address(PeerMessage) {
  let name = process.new_name("orchestrator_port")
  let assert Ok(_) = peer_service.start(name, "epoch-test", "build-test", top)
    as "the peer service starts"
  address.Address(node: node.self(), name:)
}

/// A fake endpoint that answers every exchange with `reply(payload)`.
fn replying(reply: fn(String) -> String) -> Address(PeerMessage) {
  let name = process.new_name("hostile_port")
  let assert Ok(_) =
    actor.new(Nil)
    |> actor.on_message(fn(state, message: PeerMessage) {
      let peer_service.Exchange(payload, reply_to) = message
      process.send(reply_to, reply(payload))
      actor.continue(state)
    })
    |> actor.named(name)
    |> actor.start
    as "the hostile endpoint starts"
  address.Address(node: node.self(), name:)
}

/// A fake endpoint that never answers.
fn silent() -> Address(PeerMessage) {
  let name = process.new_name("silent_port")
  let assert Ok(_) =
    actor.new(Nil)
    |> actor.on_message(fn(state, _message: PeerMessage) {
      actor.continue(state)
    })
    |> actor.named(name)
    |> actor.start
    as "the silent endpoint starts"
  address.Address(node: node.self(), name:)
}

// --- the feed under test ----------------------------------------------------------

type Rig {
  Rig(
    feed: ui_feed.Feed,
    inbox: Subject(connection_event.Message),
    ended: Subject(Ending),
  )
}

/// Starts a feed client over the given way of dialling. `open` is what the page's
/// own check says.
fn start(dial: top_relay.Dial, open: fn() -> Result(Nil, Ending)) -> Rig {
  let inbox = process.new_subject()
  let ended = process.new_subject()
  let opened = process.new_subject()
  ui_feed.start(
    ui_feed.Settings(
      relay: top_relay.through(dial, quick()),
      orchestrator: "box",
      attached: attached(),
      open:,
      inbox:,
      component: process.self(),
      ended: fn(why) { process.send(ended, why) },
    ),
    opened,
  )
  let assert Ok(Ok(feed)) = process.receive(opened, 2000)
    as "the feed client opens"
  Rig(feed:, inbox:, ended:)
}

fn to(port: Address(PeerMessage)) -> top_relay.Dial {
  fn(_name) { Ok(port) }
}

fn always_open() -> Result(Nil, Ending) {
  Ok(Nil)
}

/// The frames the component's inbox receives, in order, until `count` have come
/// or a message other than a frame arrives.
fn frames(rig: Rig, count: Int) -> List(String) {
  case count {
    0 -> []
    _ ->
      case process.receive(rig.inbox, 2000) {
        Ok(connection_event.Incoming(text:)) -> [text, ..frames(rig, count - 1)]
        Ok(_) | Error(Nil) -> []
      }
  }
}

/// Every frame the inbox receives up to its close, and the close's reason.
fn until_closed(rig: Rig) -> #(List(String), Option(String)) {
  case process.receive(rig.inbox, 3000) {
    Ok(connection_event.Incoming(text:)) -> {
      let #(held, why) = until_closed(rig)
      #([text, ..held], why)
    }
    Ok(connection_event.Closed(reason:)) -> #([], Some(reason))
    Ok(connection_event.Connected)
    | Ok(connection_event.NetworkFault(_))
    | Error(Nil) -> #([], None)
  }
}

/// The reason the component's inbox is closed with, if it is.
fn closed(rig: Rig) -> Option(String) {
  case process.receive(rig.inbox, 3000) {
    Ok(connection_event.Closed(reason:)) -> Some(reason)
    Ok(connection_event.Incoming(_)) -> closed(rig)
    Ok(connection_event.Connected)
    | Ok(connection_event.NetworkFault(_))
    | Error(Nil) -> None
  }
}

/// A counter a test reads and any process bumps.
fn counter() -> Subject(Subject(Int)) {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(fn(count, reply: Subject(Int)) {
      process.send(reply, count)
      actor.continue(count + 1)
    })
    |> actor.start
    as "the counter starts"
  started.data
}

/// How many times the counter was asked before this ask.
fn tick(counted: Subject(Subject(Int))) -> Int {
  process.call(counted, waiting: 1000, sending: fn(reply) { reply })
}

/// The first `count` lines the box logs, waiting a second for each.
fn collected(seen: Subject(String), count: Int) -> List(String) {
  case count {
    0 -> []
    _ ->
      case process.receive(seen, 1000) {
        Ok(line) -> [line, ..collected(seen, count - 1)]
        Error(Nil) -> []
      }
  }
}

fn lines(seen: Subject(String)) -> List(String) {
  case process.receive(seen, 0) {
    Ok(line) -> [line, ..lines(seen)]
    Error(Nil) -> []
  }
}

/// Waits for the box to have seen a line that starts with `prefix`.
fn awaited(seen: Subject(String), prefix: String, tries: Int) -> Bool {
  case tries {
    0 -> False
    _ ->
      case process.receive(seen, 100) {
        Ok(line) ->
          string.starts_with(line, prefix) || awaited(seen, prefix, tries - 1)
        Error(Nil) -> awaited(seen, prefix, tries - 1)
      }
  }
}

// --- frames reach the page in order, once -----------------------------------------

pub fn frames_reach_the_page_in_order_and_each_poll_names_the_last_one_held_test() {
  let seen = process.new_subject()
  let box = host(script([answer(1, ["a", "b"]), answer(3, ["c"])]), seen)
  let rig = start(to(serving(box)), always_open)
  assert frames(rig, 3) == ["a", "b", "c"]

  // The polls the box saw name the last frame the laptop held at each ask.
  assert collected(seen, 3) == ["poll 0", "poll 2", "poll 3"]
}

pub fn frames_a_box_repeats_reach_the_page_once_test() {
  let seen = process.new_subject()
  let box =
    host(
      script([
        answer(1, ["a", "b"]),
        answer(1, ["a", "b", "c"]),
        answer(2, ["b", "c"]),
      ]),
      seen,
    )
  let rig = start(to(serving(box)), always_open)
  assert frames(rig, 3) == ["a", "b", "c"]
  assert process.receive(rig.inbox, 300) == Error(Nil)
}

// --- a box that is not honest -------------------------------------------------------

pub fn a_box_that_skips_a_frame_ends_the_feed_and_the_page_draws_none_of_it_test() {
  let seen = process.new_subject()
  let box = host(script([answer(1, ["a"]), answer(3, ["c"])]), seen)
  let rig = start(to(serving(box)), always_open)

  // The page holds the frame before the gap and nothing of the answer after it.
  let #(held, why) = until_closed(rig)
  assert held == ["a"]
  assert why == Some(ending.reason(ending.ConnectionFailed))
  assert process.receive(rig.ended, 1000) == Ok(ending.ConnectionFailed)
  assert awaited(seen, "detach", 40)
}

pub fn frames_carried_with_an_ending_are_not_delivered_test() {
  let seen = process.new_subject()
  let box =
    host(
      script([
        Ok(remote_feed.Answer(
          first: 1,
          frames: ["a", "b"],
          ended: Some(remote_top.FeedStopped),
        )),
      ]),
      seen,
    )
  let rig = start(to(serving(box)), always_open)
  assert closed(rig) == Some(ending.reason(ending.SessionStopped))
  assert process.receive(rig.ended, 1000) == Ok(ending.SessionStopped)

  // The box said the feed is gone, so nothing is detached.
  process.sleep(100)
  assert list.filter(lines(seen), string.starts_with(_, "detach")) == []
}

pub fn a_refusal_that_the_feed_ended_ends_it_with_the_endings_words_test() {
  let box =
    host(
      script([Error(remote_top.FeedEnded(remote_top.FeedRevoked))]),
      process.new_subject(),
    )
  let rig = start(to(serving(box)), always_open)
  assert closed(rig) == Some(ending.reason(ending.AccessRevoked))
}

pub fn a_lapse_redraws_from_a_fresh_attach_test() {
  let box =
    host(
      script([Error(remote_top.FeedEnded(remote_top.FeedLapsed))]),
      process.new_subject(),
    )
  let rig = start(to(serving(box)), always_open)
  assert closed(rig) == Some(ending.reason(ending.ConnectionFailed))
  assert process.receive(rig.ended, 1000) == Ok(ending.ConnectionFailed)
}

pub fn a_box_that_refuses_a_poll_for_another_reason_ends_the_feed_test() {
  let box =
    host(
      script([Error(remote_top.InvalidArgument("after is ahead"))]),
      process.new_subject(),
    )
  let rig = start(to(serving(box)), always_open)
  assert closed(rig) == Some(ending.reason(ending.ConnectionFailed))
}

pub fn an_answer_that_is_not_json_or_not_an_answer_ends_the_feed_test() {
  let garbage = replying(fn(_payload) { "this is not json" })
  let rig = start(to(garbage), always_open)
  assert closed(rig) == Some(ending.reason(ending.ConnectionFailed))

  // A well-formed envelope that answers another request is not read either.
  let other =
    replying(fn(_payload) {
      peer_codec.encode_response(peer_codec.OperationResponse(
        "another-request",
        json.Null,
      ))
    })
  let again = start(to(other), always_open)
  assert closed(again) == Some(ending.reason(ending.ConnectionFailed))
}

pub fn an_oversized_answer_is_refused_before_it_is_read_test() {
  let huge = replying(fn(_payload) { string.repeat("x", 1_100_000) })
  let rig = start(to(huge), always_open)
  assert closed(rig) == Some(ending.reason(ending.ConnectionFailed))
}

pub fn a_poll_answered_with_something_that_is_not_poll_json_ends_the_feed_test() {
  let wrong =
    replying(fn(payload) {
      peer_codec.encode_response(peer_codec.OperationResponse(
        peer_codec.request_id(payload),
        json.Object([#("first", json.String("one"))]),
      ))
    })
  let rig = start(to(wrong), always_open)
  assert closed(rig) == Some(ending.reason(ending.ConnectionFailed))
}

// --- a link that is down -------------------------------------------------------------

pub fn a_box_that_never_answers_is_asked_again_and_a_shut_page_waits_test() {
  let rig = start(to(silent()), always_open)

  // Nothing reaches the page while the box is silent, and the lane giving up
  // shows the waiting state and never a failure.
  assert process.receive(rig.inbox, 500) == Error(Nil)
  ui_feed.shut(rig.feed)
  assert closed(rig) == Some(ending.reason(ending.PeerUnreachable))
  assert process.receive(rig.ended, 1000) == Ok(ending.PeerUnreachable)
}

pub fn a_shut_page_whose_box_was_heard_last_has_failed_test() {
  let seen = process.new_subject()
  let rig =
    start(to(serving(host(script([answer(1, ["a"])]), seen))), always_open)
  assert frames(rig, 1) == ["a"]
  ui_feed.shut(rig.feed)
  assert closed(rig) == Some(ending.reason(ending.ConnectionFailed))
}

pub fn a_link_that_drops_and_heals_loses_no_frame_and_shows_no_ending_test() {
  let seen = process.new_subject()
  let up = serving(host(script([answer(1, ["a"]), answer(2, ["b"])]), seen))
  let dials = counter()

  // The first three dials fail at once, which is an unreachable box. The fourth
  // finds the link healed.
  let dial = fn(_name) {
    case tick(dials) < 3 {
      True -> Error(top_relay.Unreachable)
      False -> Ok(up)
    }
  }
  let rig = start(dial, always_open)
  assert frames(rig, 2) == ["a", "b"]
  assert process.receive(rig.inbox, 200) == Error(Nil)
  assert process.receive(rig.ended, 0) == Error(Nil)
}

// --- the page's own standing ---------------------------------------------------------

pub fn a_page_that_is_no_longer_open_ends_the_feed_with_its_own_ending_test() {
  let seen = process.new_subject()
  let rig =
    start(to(serving(host(script([]), seen))), fn() { Error(ending.PageEnded) })
  assert closed(rig) == Some(ending.reason(ending.PageEnded))
  assert process.receive(rig.ended, 1000) == Ok(ending.PageEnded)
}

// --- the lane's frames --------------------------------------------------------------

pub fn a_lane_frame_reaches_the_box_as_a_piece_test() {
  let seen = process.new_subject()
  let rig = start(to(serving(host(script([]), seen))), always_open)
  ui_feed.transmit(rig.feed, "{\"cmd\":1}")
  assert awaited(seen, "send 1 0 {\"cmd\":1}", 30)
}

pub fn a_piece_whose_answer_is_late_is_sent_again_unchanged_test() {
  let seen = process.new_subject()
  let sends = counter()
  let box =
    orchestrator_port.TopHost(
      ..orchestrator_port.refusing_top(),
      feeds: remote_feed.Host(
        ..remote_feed.declining(),
        poll: fn(_node, polled: remote_feed.Poll) {
          process.sleep(30)
          Ok(remote_feed.Answer(
            first: polled.after + 1,
            frames: [],
            ended: None,
          ))
        },
        send: fn(_node, piece: remote_feed.Piece) {
          // The first answer comes after the laptop stopped waiting for it.
          case tick(sends) {
            0 -> process.sleep(400)
            _ -> Nil
          }
          process.send(seen, "piece " <> piece.text)
          Ok(Nil)
        },
        detach: fn(_node, _feed) { Ok(Nil) },
      ),
    )
  let rig = start(to(serving(box)), always_open)
  ui_feed.transmit(rig.feed, "{}")
  assert awaited(seen, "piece {}", 60)

  // The first call was cut off at the box when the laptop stopped waiting for
  // it, and the same piece was asked for again.
  assert tick(sends) >= 2
}

pub fn a_component_that_exits_detaches_the_feed_test() {
  let seen = process.new_subject()
  let box = serving(host(script([]), seen))
  let inbox = process.new_subject()
  let opened = process.new_subject()
  let component = process.spawn(fn() { process.sleep(150) })
  ui_feed.start(
    ui_feed.Settings(
      relay: top_relay.through(to(box), quick()),
      orchestrator: "box",
      attached: attached(),
      open: always_open,
      inbox:,
      component:,
      ended: fn(_) { Nil },
    ),
    opened,
  )
  let assert Ok(Ok(_)) = process.receive(opened, 2000)
  assert awaited(seen, "detach", 30)
}

pub fn a_lane_that_writes_past_the_outbox_bound_ends_the_feed_test() {
  // A silent box admits nothing, so the outbox fills.
  let rig = start(to(silent()), always_open)
  list.each(list.repeat("{}", 40), fn(frame) {
    ui_feed.transmit(rig.feed, frame)
  })
  assert closed(rig) == Some(ending.reason(ending.ConnectionFailed))
}
