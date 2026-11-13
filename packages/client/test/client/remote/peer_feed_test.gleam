//// The four revisions of the live session page inside the stable peer
//// envelope (protocol-change/108): each reaches the host's function with the node
//// the exchange took from the caller's reply subject and with a body the total
//// decoder read whole, and a body that decoder refuses never reaches the host.

import client/remote/orchestrator_port
import client/remote/peer_codec
import client/remote/peer_top
import client/remote_feed
import client/remote_top
import core/json
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/string

const token = "0123456789abcdef0123456789abcdef"

/// A host whose four functions report what they were handed.
fn recording(seen: Subject(String)) -> orchestrator_port.TopHost {
  orchestrator_port.TopHost(
    ..orchestrator_port.refusing_top(),
    feeds: remote_feed.Host(
      attach: fn(node, attach) {
        process.send(seen, "attach " <> node <> " " <> attach.session)
        Error(remote_top.TopLevelOff)
      },
      poll: fn(node, poll) {
        process.send(seen, "poll " <> node <> " " <> poll.feed)
        Ok(remote_feed.Answer(first: poll.after + 1, frames: [], ended: None))
      },
      send: fn(node, piece) {
        process.send(seen, "send " <> node <> " " <> piece.text)
        Ok(Nil)
      },
      detach: fn(node, feed) {
        process.send(seen, "detach " <> node <> " " <> feed)
        Ok(Nil)
      },
    ),
  )
}

fn dispatch(
  seen: Subject(String),
  revision: String,
  body: json.JsonValue,
) -> Result(Result(json.JsonValue, remote_top.Refusal), String) {
  peer_top.dispatch(recording(seen), "laptop@host", revision, body)
}

fn received(seen: Subject(String)) -> List(String) {
  case process.receive(seen, 0) {
    Ok(line) -> [line, ..received(seen)]
    Error(Nil) -> []
  }
}

pub fn the_four_revisions_are_advertised_and_dispatched_test() {
  list.each(remote_feed.revisions, fn(revision) {
    assert list.contains(peer_codec.revisions, revision)
  })
}

pub fn each_revision_reaches_its_function_with_the_exchanges_node_test() {
  let seen = process.new_subject()
  let assert Ok(Error(remote_top.TopLevelOff)) =
    dispatch(
      seen,
      "108.attach.1",
      json.Array([
        json.String("session-1"),
        json.String("page"),
        json.String("Laptop"),
      ]),
    )
  let assert Ok(Ok(answer)) =
    dispatch(
      seen,
      "108.feed.1",
      json.Array([json.String(token), json.Int(4), json.Int(5000)]),
    )
  assert remote_feed.decode_answer(answer)
    == Ok(remote_feed.Answer(first: 5, frames: [], ended: None))
  assert dispatch(
      seen,
      "108.send.1",
      json.Array([
        json.String(token),
        json.Int(1),
        json.Int(0),
        json.Int(2),
        json.String("{}"),
      ]),
    )
    == Ok(Ok(json.Null))
  assert dispatch(seen, "108.detach.1", json.Array([json.String(token)]))
    == Ok(Ok(json.Null))
  assert received(seen)
    == [
      "attach laptop@host session-1",
      "poll laptop@host " <> token,
      "send laptop@host {}",
      "detach laptop@host " <> token,
    ]
}

pub fn a_body_the_decoder_refuses_never_reaches_the_host_test() {
  let seen = process.new_subject()
  let hostile = [
    #("108.attach.1", json.Array([json.String("only one")])),
    #(
      "108.feed.1",
      json.Array([json.String("short"), json.Int(0), json.Int(0)]),
    ),
    #(
      "108.feed.1",
      json.Array([json.String(token), json.Int(0), json.Int(5001)]),
    ),
    #("108.feed.1", json.Array([json.String(token), json.Int(-1), json.Int(0)])),
    #(
      "108.send.1",
      json.Array([
        json.String(token),
        json.Int(1),
        json.Int(5),
        json.Int(6),
        json.String("too long"),
      ]),
    ),
    #(
      "108.send.1",
      json.Array([
        json.String(token),
        json.Int(0),
        json.Int(0),
        json.Int(1),
        json.String("x"),
      ]),
    ),
    #("108.detach.1", json.Object([])),
    #("108.detach.1", json.Array([json.String(string.uppercase(token))])),
  ]
  list.each(hostile, fn(attempt) {
    let #(revision, body) = attempt
    let assert Error(_) = dispatch(seen, revision, body)
  })
  assert received(seen) == []
}
