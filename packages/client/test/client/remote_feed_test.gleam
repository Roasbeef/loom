//// The vocabulary of a live session page on another orchestrator
//// (protocol-change/108): the four request bodies and the two answers, the
//// refusals they add to 094's, and that every decoder is total.
////
//// A decoder is total when every input is an `Ok` or an `Error` and no input
//// crashes it. The property tests feed each decoder values drawn from a fixed
//// seed: arbitrary JSON, and valid encodings with one member deleted, retyped
//// or replaced. Whatever decodes is checked to encode back to the same value,
//// so a decoder cannot accept something it would not itself produce.

import client/remote/peer_codec
import client/remote_feed.{
  type Attached, Answer, Attach, AttachRequest, Attached, DetachRequest, Label,
  Piece, PollRequest, SendRequest,
}
import client/remote_top
import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import qcheck

const seed = 108

const draws = 200

const token = "0123456789abcdef0123456789abcdef"

fn config() -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_test_count(draws)
  |> qcheck.with_seed(qcheck.seed(seed))
}

fn attached() -> Attached {
  Attached(
    feed: token,
    epoch: "epoch-a",
    incarnation: "incarnation-1",
    label: Label(
      name: "fix the retry test",
      placement: remote_top.Folder(path: "/srv/work"),
    ),
  )
}

fn piece(offset: Int, total: Int, text: String) -> remote_feed.Piece {
  Piece(feed: token, n: 3, offset:, total:, text:)
}

fn requests() -> List(remote_feed.Request) {
  [
    AttachRequest(Attach(session: "s1", principal: "owner-1", name: "Laolu")),
    PollRequest(remote_feed.Poll(feed: token, after: 7, wait_ms: 5000)),
    SendRequest(piece(0, 5, "hello")),
    DetachRequest(feed: token),
  ]
}

// --- the revisions -----------------------------------------------------------------

pub fn the_four_revisions_are_named_once_test() {
  assert remote_feed.revisions
    == [
      remote_feed.attach_revision,
      remote_feed.feed_revision,
      remote_feed.send_revision,
      remote_feed.detach_revision,
    ]
  assert list.all(remote_feed.revisions, remote_feed.is_revision)
  assert !remote_feed.is_revision("108.feed.2")
  assert !remote_feed.is_revision("094.send.1")
  assert list.map(requests(), remote_feed.revision_of) == remote_feed.revisions
}

// --- the requests ------------------------------------------------------------------

pub fn every_request_round_trips_under_its_revision_test() {
  list.each(requests(), fn(request) {
    let revision = remote_feed.revision_of(request)
    assert remote_feed.decode_request(
        revision,
        remote_feed.encode_request(request),
      )
      == Ok(request)
  })
}

pub fn a_revision_does_not_read_another_revisions_body_test() {
  list.each(requests(), fn(request) {
    let body = remote_feed.encode_request(request)
    let own = remote_feed.revision_of(request)
    list.each(remote_feed.revisions, fn(revision) {
      case revision == own {
        True -> Nil
        False -> {
          let assert Error(_) = remote_feed.decode_request(revision, body)
          Nil
        }
      }
    })
  })
  assert remote_feed.decode_request("108.feed.2", json.Array([]))
    == Error("the body is not one the revision takes")
}

pub fn a_token_is_thirty_two_lowercase_hexadecimal_characters_test() {
  assert remote_feed.is_token(token)
  assert !remote_feed.is_token("")
  assert !remote_feed.is_token(string.uppercase(token))
  assert !remote_feed.is_token("0123456789abcdef0123456789abcde")
  assert !remote_feed.is_token("0123456789abcdef0123456789abcdefa")
  assert !remote_feed.is_token("0123456789abcdef0123456789abcdeg")
  assert !remote_feed.is_token("-123456789abcdef0123456789abcdef")
  assert !remote_feed.is_token(string.repeat("é", 16))

  let refused =
    Error("the feed token is not 32 lowercase hexadecimal characters")
  assert remote_feed.decode_request(
      remote_feed.detach_revision,
      json.Array([json.String(string.uppercase(token))]),
    )
    == refused
  assert remote_feed.decode_request(
      remote_feed.detach_revision,
      json.Array([json.Int(1)]),
    )
    == Error("the feed token is not text")
}

pub fn an_attach_names_a_session_and_a_page_within_the_text_bound_test() {
  let attach = fn(session, principal, name) {
    remote_feed.decode_request(
      remote_feed.attach_revision,
      json.Array([
        json.String(session),
        json.String(principal),
        json.String(name),
      ]),
    )
  }
  let long = string.repeat("x", remote_feed.max_text_bytes + 1)
  assert attach("s", "p", "") == Ok(AttachRequest(Attach("s", "p", "")))
  assert attach("", "p", "n") == Error("session is not within its size bounds")
  assert attach("s", "", "n")
    == Error("principal is not within its size bounds")
  assert attach(long, "p", "n")
    == Error("session is not within its size bounds")
  assert attach("s", "p", long) == Error("name is not within its size bounds")
  assert remote_feed.decode_request(
      remote_feed.attach_revision,
      json.Array([json.String("s"), json.String("p"), json.Int(1)]),
    )
    == Error("name is not text")
}

pub fn a_poll_waits_at_most_five_seconds_and_names_a_frame_that_exists_test() {
  let poll = fn(after, wait) {
    remote_feed.decode_request(
      remote_feed.feed_revision,
      json.Array([json.String(token), json.Int(after), json.Int(wait)]),
    )
  }
  assert poll(0, 0)
    == Ok(PollRequest(remote_feed.Poll(feed: token, after: 0, wait_ms: 0)))
  assert poll(0, 5000)
    == Ok(PollRequest(remote_feed.Poll(feed: token, after: 0, wait_ms: 5000)))
  assert poll(0, 5001) == Error("wait_ms is out of range")
  assert poll(0, -1) == Error("wait_ms is out of range")
  assert poll(-1, 0) == Error("after is out of range")
  assert poll(9_007_199_254_740_992, 0) == Error("after is out of range")
}

pub fn a_piece_lies_inside_its_frame_and_inside_the_piece_bound_test() {
  let send = fn(n, offset, total, text) {
    remote_feed.decode_request(
      remote_feed.send_revision,
      json.Array([
        json.String(token),
        json.Int(n),
        json.Int(offset),
        json.Int(total),
        json.String(text),
      ]),
    )
  }
  assert send(1, 0, 5, "hello")
    == Ok(SendRequest(Piece(token, 1, 0, 5, "hello")))
  assert send(1, 3, 5, "lo") == Ok(SendRequest(Piece(token, 1, 3, 5, "lo")))

  // A piece that runs past the end of its frame is refused, as is one the
  // frame could never hold.
  assert send(1, 4, 5, "lo") == Error("the piece does not lie inside its frame")
  assert send(0, 0, 5, "hello") == Error("n is out of range")
  assert send(1, -1, 5, "hello") == Error("offset is out of range")
  assert send(1, 0, 0, "hello") == Error("total is out of range")
  assert send(1, 0, remote_feed.frame_bytes + 1, "hello")
    == Error("total is out of range")
  assert send(1, 0, 5, "") == Error("piece is not within its size bounds")
}

pub fn a_piece_is_at_most_393216_bytes_and_a_frame_at_most_twelve_mebibytes_test() {
  let whole = string.repeat("a", remote_feed.piece_bytes)
  let over = whole <> "a"
  let send = fn(text) {
    remote_feed.decode_request(
      remote_feed.send_revision,
      json.Array([
        json.String(token),
        json.Int(1),
        json.Int(0),
        json.Int(remote_feed.frame_bytes),
        json.String(text),
      ]),
    )
  }
  assert send(whole) == Ok(SendRequest(Piece(token, 1, 0, 12_582_912, whole)))
  assert send(over) == Error("piece is not within its size bounds")

  // Twelve mebibytes is thirty-two pieces of 393,216 bytes.
  assert remote_feed.frame_bytes / remote_feed.piece_bytes == 32
}

fn decode_send(
  offset: Int,
  total: Int,
  text: String,
) -> Result(remote_feed.Request, String) {
  remote_feed.decode_request(
    remote_feed.send_revision,
    json.Array([
      json.String(token),
      json.Int(1),
      json.Int(offset),
      json.Int(total),
      json.String(text),
    ]),
  )
}

// Cuts a frame of `total` bytes into pieces of `size` and one last piece, as a
// sender that sends full pieces does, decodes each, and counts them.
fn pieces_accepted(total: Int, size: Int, offset: Int, count: Int) -> Int {
  let take = int.min(size, total - offset)
  let assert Ok(_) = decode_send(offset, total, string.repeat("a", take))
    as "a full piece or the last piece is accepted"
  case offset + take >= total {
    True -> count + 1
    False -> pieces_accepted(total, size, offset + take, count + 1)
  }
}

pub fn no_accepted_sequence_of_pieces_for_one_frame_passes_the_count_bound_test() {
  qcheck.default_config()
  |> qcheck.with_test_count(20)
  |> qcheck.with_seed(qcheck.seed(seed))
  |> qcheck.run(
    qcheck.map2(
      qcheck.bounded_int(
        remote_feed.frame_bytes - 1_000_000,
        remote_feed.frame_bytes,
      ),
      qcheck.bounded_int(remote_feed.min_piece_bytes, remote_feed.piece_bytes),
      fn(total, size) { #(total, size) },
    ),
    fn(shape) {
      let #(total, size) = shape
      assert pieces_accepted(total, size, 0, 0) <= remote_feed.max_pieces
    },
  )
}

pub fn a_piece_shorter_than_the_floor_that_does_not_end_its_frame_is_refused_test() {
  qcheck.default_config()
  |> qcheck.with_test_count(draws)
  |> qcheck.with_seed(qcheck.seed(seed))
  |> qcheck.run(
    qcheck.bounded_int(1, remote_feed.min_piece_bytes - 1),
    fn(size) {
      assert decode_send(0, remote_feed.frame_bytes, string.repeat("a", size))
        == Error("a piece that does not end its frame is a full piece")
    },
  )
}

pub fn one_byte_pieces_of_a_large_frame_are_refused_and_a_last_byte_is_not_test() {
  // A peer that sends a twelve mebibyte frame a byte at a time is refused at the
  // first byte, so the box never holds millions of pieces.
  assert decode_send(0, remote_feed.frame_bytes, "a")
    == Error("a piece that does not end its frame is a full piece")
  assert decode_send(5, remote_feed.frame_bytes, "a")
    == Error("a piece that does not end its frame is a full piece")

  // The last byte of a frame ends it, so it is a piece however short.
  assert decode_send(remote_feed.frame_bytes - 1, remote_feed.frame_bytes, "a")
    == Ok(
      SendRequest(Piece(
        token,
        1,
        remote_feed.frame_bytes - 1,
        remote_feed.frame_bytes,
        "a",
      )),
    )

  // Twelve mebibytes is at most sixty-five pieces.
  assert remote_feed.frame_bytes / remote_feed.min_piece_bytes + 1
    == remote_feed.max_pieces
}

// --- the answers -------------------------------------------------------------------

pub fn an_attach_answer_round_trips_with_every_placement_test() {
  let placements = [
    remote_top.Folder(path: "/srv/work"),
    remote_top.Workspace(executor: "build", name: "app"),
    remote_top.Pooled(pool: "gpu", name: "app"),
  ]
  list.each(placements, fn(placement) {
    let answer =
      Attached(
        ..attached(),
        label: Label(name: "a session", placement: placement),
      )
    assert remote_feed.decode_attached(remote_feed.encode_attached(answer))
      == Ok(answer)
  })
}

pub fn an_attach_answer_that_breaks_a_bound_is_refused_whole_test() {
  let refused = fn(answer) {
    case remote_feed.decode_attached(remote_feed.encode_attached(answer)) {
      Ok(_) -> False
      Error(_) -> True
    }
  }
  let long = string.repeat("x", remote_feed.max_text_bytes + 1)
  let wide = string.repeat("x", remote_feed.max_identity_bytes + 1)
  assert refused(Attached(..attached(), feed: "short"))
  assert refused(Attached(..attached(), epoch: ""))
  assert refused(Attached(..attached(), epoch: wide))
  assert refused(Attached(..attached(), incarnation: ""))
  assert refused(Attached(..attached(), incarnation: wide))
  assert refused(
    Attached(
      ..attached(),
      label: Label(name: long, placement: remote_top.Folder("/w")),
    ),
  )
  assert refused(
    Attached(
      ..attached(),
      label: Label(name: "n", placement: remote_top.Folder("/" <> long)),
    ),
  )
  assert remote_feed.decode_attached(json.Null)
    == Error("the attach answer is not an object")
  assert remote_feed.decode_attached(json.Object([]))
    == Error("attach is missing")
}

pub fn a_poll_answer_round_trips_with_every_ending_test() {
  let endings = [
    None,
    Some(remote_top.FeedLapsed),
    Some(remote_top.FeedStopped),
    Some(remote_top.FeedRevoked),
  ]
  list.each(endings, fn(ended) {
    let answer = Answer(first: 4, frames: ["{\"a\":1}", "", "é\"\\"], ended:)
    assert remote_feed.decode_answer(remote_feed.encode_answer(answer))
      == Ok(answer)
  })
}

pub fn a_poll_answer_that_breaks_a_bound_is_refused_whole_test() {
  let member = fn(first, frames, ended) {
    json.Object([
      #("first", first),
      #("frames", frames),
      #("ended", ended),
    ])
  }
  let full =
    json.Array(list.repeat(json.String("{}"), remote_feed.queue_frames))
  let over =
    json.Array(list.repeat(json.String("{}"), remote_feed.queue_frames + 1))
  assert remote_feed.decode_answer(member(json.Int(1), full, json.Null))
    == Ok(Answer(first: 1, frames: list.repeat("{}", 512), ended: None))
  assert remote_feed.decode_answer(member(json.Int(1), over, json.Null))
    == Error("the answer holds more frames than a feed queues")
  assert remote_feed.decode_answer(member(
      json.Int(0),
      json.Array([]),
      json.Null,
    ))
    == Error("first is out of range")
  assert remote_feed.decode_answer(member(
      json.Int(1),
      json.Array([json.Int(1)]),
      json.Null,
    ))
    == Error("a frame is not text")
  assert remote_feed.decode_answer(member(
      json.Int(1),
      json.Array([]),
      json.String("gone"),
    ))
    == Error("ended is not null or a known word")
  assert remote_feed.decode_answer(member(
      json.Int(1),
      json.String("[]"),
      json.Null,
    ))
    == Error("frames is not an array")
  assert remote_feed.decode_answer(json.Object([#("first", json.Int(1))]))
    == Error("frames is missing")
}

// --- the refusals ------------------------------------------------------------------

pub fn the_three_new_refusals_survive_the_stable_exchange_test() {
  let refusals = [
    remote_top.FeedEnded(remote_top.FeedLapsed),
    remote_top.FeedEnded(remote_top.FeedStopped),
    remote_top.FeedEnded(remote_top.FeedRevoked),
    remote_top.CapReached(remote_top.MaxFeeds, 8),
    remote_top.NotOffered(remote_top.OfferedPage, "live"),
  ]
  list.each(refusals, fn(refusal) {
    let text =
      peer_codec.encode_response(peer_codec.RefusalResponse("r", refusal))
    assert peer_codec.decode_response(text, "r", peer_codec.operation_bytes)
      == Ok(peer_codec.RefusalResponse("r", refusal))
  })
}

pub fn a_feed_refusal_has_the_wire_form_the_proposal_names_test() {
  let wire = fn(refusal) {
    peer_codec.encode_response(peer_codec.RefusalResponse("r", refusal))
  }
  assert string.contains(
    wire(remote_top.FeedEnded(remote_top.FeedLapsed)),
    "[\"feed_ended\",\"lapsed\",0]",
  )
  assert string.contains(
    wire(remote_top.CapReached(remote_top.MaxFeeds, 8)),
    "[\"cap_reached\",\"feeds\",8]",
  )
  assert string.contains(
    wire(remote_top.NotOffered(remote_top.OfferedPage, "live")),
    "[\"not_offered\",\"page:live\",0]",
  )
}

pub fn an_unknown_feed_ending_on_the_wire_is_unreadable_test() {
  let text =
    "{\"v\":1,\"request_id\":\"r\",\"kind\":\"refused\","
    <> "\"body\":[\"feed_ended\",\"gone\",0]}"
  assert peer_codec.decode_response(text, "r", peer_codec.operation_bytes)
    == Error("invalid feed ending")
}

pub fn a_feed_that_ended_is_not_worth_asking_again_test() {
  assert !remote_top.retryable(remote_top.FeedEnded(remote_top.FeedLapsed))
  assert remote_top.describe_refusal(remote_top.FeedEnded(
      remote_top.FeedStopped,
    ))
    == "the session's run ended"
  assert remote_top.describe_refusal(remote_top.CapReached(
      remote_top.MaxFeeds,
      8,
    ))
    == "your orchestrator already has 8 live session pages open there"
  assert remote_top.describe_refusal(remote_top.NotOffered(
      remote_top.OfferedPage,
      "live",
    ))
    == "this orchestrator does not offer the page live to your orchestrator"
}

pub fn a_daemon_that_serves_no_feed_refuses_every_operation_test() {
  let host = remote_feed.declining()
  let refusal = remote_top.UnknownSpawner("laptop@10.0.0.1")
  assert host.attach("laptop@10.0.0.1", Attach("s", "p", "n")) == Error(refusal)
  assert host.poll("laptop@10.0.0.1", remote_feed.Poll(token, 0, 0))
    == Error(refusal)
  assert host.send("laptop@10.0.0.1", piece(0, 1, "x")) == Error(refusal)
  assert host.detach("laptop@10.0.0.1", token) == Error(refusal)
}

// --- totality ----------------------------------------------------------------------

fn json_text() -> qcheck.Generator(String) {
  qcheck.bounded_int(0, 5)
  |> qcheck.map(fn(pick) {
    case pick {
      0 -> ""
      1 -> token
      2 -> "lapsed"
      3 -> "folder"
      4 -> "hello"
      _ -> "x"
    }
  })
}

fn json_value(depth: Int) -> qcheck.Generator(JsonValue) {
  let leaf =
    qcheck.from_generators(qcheck.return(json.Null), [
      qcheck.return(json.Bool(True)),
      qcheck.map(qcheck.bounded_int(-3, 6000), json.Int),
      qcheck.map(json_text(), json.String),
    ])
  case depth {
    0 -> leaf
    _ ->
      qcheck.from_generators(leaf, [
        qcheck.map(
          qcheck.generic_list(
            elements_from: json_value(depth - 1),
            length_from: qcheck.bounded_int(0, 5),
          ),
          json.Array,
        ),
        qcheck.map(
          qcheck.generic_list(
            elements_from: qcheck.tuple2(
              qcheck.from_generators(
                qcheck.return("attach"),
                list.map(
                  [
                    "epoch", "incarnation", "label", "name", "placement", "kind",
                    "path", "first", "frames", "ended",
                  ],
                  qcheck.return,
                ),
              ),
              json_value(depth - 1),
            ),
            length_from: qcheck.bounded_int(0, 6),
          ),
          json.Object,
        ),
      ])
  }
}

// A valid encoding with one member removed, retyped or replaced, found by
// walking to the nth member in document order. Arrays count their items, so a
// request body, which is an array, is mutated too.
fn mutate(value: JsonValue, target: Int, how: Int) -> JsonValue {
  let #(mutated, _) = walk(value, target, how)
  mutated
}

fn walk(value: JsonValue, target: Int, how: Int) -> #(JsonValue, Int) {
  case value {
    json.Object(members) -> {
      let #(rebuilt, left) =
        list.fold(members, #([], target), fn(state, member) {
          let #(done, left) = state
          let #(key, inner) = member
          case left {
            0 -> #(list.append(done, replaced(key, inner, how)), -1)
            _ -> {
              let #(inner, left) = walk(inner, left - 1, how)
              #(list.append(done, [#(key, inner)]), left)
            }
          }
        })
      #(json.Object(rebuilt), left)
    }
    json.Array(items) -> {
      let #(rebuilt, left) =
        list.fold(items, #([], target), fn(state, item) {
          let #(done, left) = state
          case left {
            0 -> #(list.append(done, retyped(item, how)), -1)
            _ -> {
              let #(item, left) = walk(item, left - 1, how)
              #(list.append(done, [item]), left)
            }
          }
        })
      #(json.Array(rebuilt), left)
    }
    other -> #(other, target)
  }
}

fn replaced(
  key: String,
  inner: JsonValue,
  how: Int,
) -> List(#(String, JsonValue)) {
  case how {
    0 -> []
    1 -> [#(key, json.Null)]
    2 -> [#(key, json.String("x"))]
    3 -> [#(key, json.Int(-1))]
    4 -> [#(key, json.Array([inner]))]
    _ -> [#(key, json.Object([]))]
  }
}

fn retyped(item: JsonValue, how: Int) -> List(JsonValue) {
  case how {
    0 -> []
    1 -> [json.Null]
    2 -> [json.String("x")]
    3 -> [json.Int(-1)]
    4 -> [json.Array([item])]
    _ -> [json.Object([])]
  }
}

pub fn the_request_decoder_is_total_test() {
  qcheck.run(config(), json_value(3), fn(value) {
    list.each(remote_feed.revisions, fn(revision) {
      case remote_feed.decode_request(revision, value) {
        Ok(found) -> {
          assert remote_feed.revision_of(found) == revision
          assert remote_feed.decode_request(
              revision,
              remote_feed.encode_request(found),
            )
            == Ok(found)
        }
        Error(_) -> Nil
      }
    })
  })
  qcheck.run(
    config(),
    qcheck.tuple2(qcheck.bounded_int(0, 6), qcheck.bounded_int(0, 5)),
    fn(drawn) {
      let #(target, how) = drawn
      list.each(requests(), fn(request) {
        let revision = remote_feed.revision_of(request)
        let body = remote_feed.encode_request(request)
        case remote_feed.decode_request(revision, mutate(body, target, how)) {
          Ok(found) -> {
            assert remote_feed.decode_request(
                revision,
                remote_feed.encode_request(found),
              )
              == Ok(found)
          }
          Error(_) -> Nil
        }
      })
    },
  )
}

pub fn the_attach_answer_decoder_is_total_test() {
  qcheck.run(config(), json_value(3), fn(value) {
    case remote_feed.decode_attached(value) {
      Ok(found) -> {
        assert remote_feed.decode_attached(remote_feed.encode_attached(found))
          == Ok(found)
      }
      Error(_) -> Nil
    }
  })
  qcheck.run(
    config(),
    qcheck.tuple2(qcheck.bounded_int(0, 12), qcheck.bounded_int(0, 5)),
    fn(drawn) {
      let #(target, how) = drawn
      case
        remote_feed.decode_attached(mutate(
          remote_feed.encode_attached(attached()),
          target,
          how,
        ))
      {
        Ok(found) -> {
          assert remote_feed.decode_attached(remote_feed.encode_attached(found))
            == Ok(found)
        }
        Error(_) -> Nil
      }
    },
  )
}

pub fn the_poll_answer_decoder_is_total_test() {
  let sample =
    Answer(
      first: 2,
      frames: ["{}", "{\"a\":1}"],
      ended: Some(remote_top.FeedLapsed),
    )
  qcheck.run(config(), json_value(3), fn(value) {
    case remote_feed.decode_answer(value) {
      Ok(found) -> {
        assert remote_feed.decode_answer(remote_feed.encode_answer(found))
          == Ok(found)
      }
      Error(_) -> Nil
    }
  })
  qcheck.run(
    config(),
    qcheck.tuple2(qcheck.bounded_int(0, 8), qcheck.bounded_int(0, 5)),
    fn(drawn) {
      let #(target, how) = drawn
      case
        remote_feed.decode_answer(mutate(
          remote_feed.encode_answer(sample),
          target,
          how,
        ))
      {
        Ok(found) -> {
          assert remote_feed.decode_answer(remote_feed.encode_answer(found))
            == Ok(found)
        }
        Error(_) -> Nil
      }
    },
  )
}
