//// The vocabulary of a live session page on another orchestrator, between two
//// orchestrators (protocol-change/108).
////
//// A laptop's page can show a relayed session as the full session page. The
//// box attaches to the session's gateway the way a page socket does, holds
//// the frames the gateway writes to that attachment in a numbered queue, and
//// the laptop pulls them with a long poll and sends the lane's frames back one
//// piece at a time. The five operations are revisions of the stable peer
//// exchange (protocol-change/105): `108.attach.1`, `108.feed.1`, `108.send.1`,
//// `108.detach.1` and `108.worktree.1`. This module holds the plain data their
//// bodies and answers carry, the bounds both ends hold, and the total decoders
//// for each.
//// It has no process in it and does no I/O, as `client/remote_top` has none, so
//// both orchestrators compile the same module and the laptop's feed adapter
//// can start from it without reading the box.
////
//// ## What crosses as JSON, and why
////
//// A request body is a JSON array of fixed arity, as 094's are, and an answer
//// is an object, because it has members a reader would otherwise count. Every
//// text is bounded, every number is checked against the range it can take, and
//// a word outside its closed set is refused. A body that fails its decoder is
//// refused whole with the stable exchange's `malformed`, so nothing the other
//// machine sent is read in part. The frames themselves are opaque text here:
//// they are the session endpoint's own frames, byte for byte, and `session_view`
//// reads them on the laptop and the gateway reads them on the box.
////
//// ## The three numbers a frame carries
////
//// The box numbers the frames it queues from one per feed, and `after` is the
//// last number the laptop received. The laptop numbers the frames its lane
//// transmits from one, as `n`, and cuts each into pieces placed by `offset` and
//// `total`, as a `Chunk` of `client/session_move` places a piece in a file. A
//// piece is at most `piece_bytes` of text and a frame at most `frame_bytes`,
//// the page socket's own bound, so a prompt with four pasted images reaches the
//// box in at most 64 pieces. A piece that does not end its frame must carry at
//// least `min_piece_bytes`, so a peer cannot hold the box's memory in cells by
//// sending a frame a byte at a time.
////
//// ## The workspace observation
////
//// `108.worktree.1` asks the box for what its own page's Changes tab draws: the
//// daemon's bounded observation of the session's Git working tree. It touches
//// none of what the other four keep. The feed's queue, cursor, lease and pieces
//// are as they were, and the answer is one object, at most `max_worktree_bytes`
//// of JSON, that the box decides for the feed's own standing. The observation
//// is clipped where it is made (`client/worktree_diff` holds the board to
//// `board_byte_limit` and marks a cut in `extent` and `omitted`), so the answer
//// never needs a piece of its own, and `observed` refuses a board over the bound
//// rather than cutting it again.
////
//// ## Flow
////
//// `is_revision` → `encode_request` → `decode_request` → `encode_attached` →
//// `decode_attached` → `encode_answer` → `decode_answer` → `observed` →
//// `encode_observation` → `decode_observation` → `declining`
////
//// 1. `is_revision` says whether a revision belongs to this vocabulary, so the
////    stable endpoint can route it before it reads a body.
//// 2. `encode_request` and `decode_request` are the two ends of every request
////    body.
//// 3. `encode_attached` and `decode_attached` are the two ends of an attach
////    answer.
//// 4. `encode_answer` and `decode_answer` are the two ends of a poll answer.
//// 5. `observed`, `encode_observation` and `decode_observation` are the bound, the
////    encoding and the total decoder of a workspace observation's answer.
//// 6. `declining` is the host of a daemon that serves no feed.

import client/remote_top.{type FeedEnd, type Placement, type Refusal}
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The revision that opens a feed.
pub const attach_revision = "108.attach.1"

/// The revision that pulls the feed's frames.
pub const feed_revision = "108.feed.1"

/// The revision that carries one piece of one frame the lane transmitted.
pub const send_revision = "108.send.1"

/// The revision that ends a feed.
pub const detach_revision = "108.detach.1"

/// The revision that reads the box's observation of the session's workspace.
pub const worktree_revision = "108.worktree.1"

/// The five revisions, in the order the exchange advertises them.
pub const revisions = [
  "108.attach.1", "108.feed.1", "108.send.1", "108.detach.1", "108.worktree.1",
]

/// The longest a poll may ask the box to hold it, in milliseconds.
pub const max_wait_ms = 5000

/// How long a feed lives with no poll, in milliseconds. A feed that goes this
/// long unpolled lapses.
pub const lease_ms = 15_000

/// The most bytes of frames a feed holds that the laptop has not acknowledged.
/// A single frame larger than this is still admitted to an empty queue.
pub const queue_bytes = 1_048_576

/// The most frames a feed holds that the laptop has not acknowledged.
pub const queue_frames = 512

/// The most feeds one spawner holds at once.
pub const max_feeds = 8

/// The most bytes of frame text one piece carries. A frame is JSON, so carrying
/// a piece as a JSON string at most doubles it, and the doubled piece fits the
/// stable exchange's envelope.
pub const piece_bytes = 393_216

/// The most bytes one frame the lane transmits may have, which is the page
/// socket's own operator bound.
pub const frame_bytes = 12_582_912

/// The fewest bytes a piece carries unless it ends its frame. A sender sends full
/// pieces and a last piece, so a piece shorter than half the bound that does not
/// end its frame is refused. That keeps the pieces of one frame at `max_pieces`
/// or fewer, so the box never holds millions of one-byte pieces.
pub const min_piece_bytes = 196_608

/// The most pieces one frame may arrive in. The codec does not count pieces, so
/// the bound follows from the rest. The box admits only the piece that begins where
/// the held bytes end, every piece but the last carries at least `min_piece_bytes`,
/// and the last carries at least one byte. A frame of `frame_bytes`, which is 64
/// times `min_piece_bytes`, therefore holds at most 63 whole pieces below the
/// frame bound plus the last, which is 64.
pub const max_pieces = 64

/// The bytes the connection permit of one feed is charged: what the feed can hold
/// at once, from its own bounds. A feed holds an unacknowledged queue
/// (`queue_bytes`, 1,048,576), one partial frame (`frame_bytes`, 12,582,912), one
/// answer being built (the exchange's envelope bound, 1,048,576) and one piece
/// being read, which as JSON may double (twice `piece_bytes`, 786,432). When the
/// last piece arrives `feed_pieces.extend` joins the pieces into the whole frame
/// while the pieces are still referenced, and the command filter then parses that
/// frame in the same process, so a second `frame_bytes` is live at the peak. The
/// sum is 28,049,408 bytes, so the eight feeds of a spawner take 224,395,264 of the
/// daemon's default budget of 536,870,912, about 42 percent, where a page's 64 MiB
/// charge would have taken all of it.
pub const feed_charge_bytes = 28_049_408

/// The most bytes of JSON a workspace observation's board may have. It is the
/// bound `session_view/worktree_view.decode` holds a board to, so a board the
/// answer admits is one the page can read, and it is far below the stable
/// exchange's envelope of 1,048,576 bytes, so an answer is always one frame.
pub const max_worktree_bytes = 48_000

/// The most bytes of one name, identity or label text the decoders accept.
pub const max_text_bytes = 512

/// The most bytes an epoch or an incarnation may have.
pub const max_identity_bytes = 256

/// The number of hexadecimal characters in an attach token, 128 bits.
pub const token_chars = 32

/// What the laptop's page asks when it opens a feed.
pub type Attach {
  Attach(
    /// The relayed session's identity on the box.
    session: String,
    /// The laptop page's principal, kept on the box as plain data for
    /// provenance. It authenticates nothing.
    principal: String,
    /// The laptop page's display name, kept the same way.
    name: String,
  )
}

/// A poll for the frames after the last one the laptop received.
pub type Poll {
  Poll(
    /// The feed's token.
    feed: String,
    /// The number of the last frame the laptop received, or zero.
    after: Int,
    /// How long the box may hold the poll for a first frame, at most
    /// `max_wait_ms`.
    wait_ms: Int,
  )
}

/// One piece of one frame the lane transmitted.
pub type Piece {
  Piece(
    /// The feed's token.
    feed: String,
    /// The frame's number among the lane's frames, from one.
    n: Int,
    /// How many bytes of the frame precede this piece.
    offset: Int,
    /// The frame's whole size in bytes.
    total: Int,
    /// The frame's text from `offset`.
    text: String,
  )
}

/// A decoded request body, by the revision that carried it.
pub type Request {
  /// `108.attach.1`.
  AttachRequest(attach: Attach)

  /// `108.feed.1`.
  PollRequest(poll: Poll)

  /// `108.send.1`.
  SendRequest(piece: Piece)

  /// `108.detach.1`.
  DetachRequest(
    /// The feed's token.
    feed: String,
  )

  /// `108.worktree.1`.
  WorktreeRequest(
    /// The feed's token.
    feed: String,
  )
}

/// What the box says of a session when it opens a feed on it: the heading's
/// words, in the bounds and the shape of a `TopSessions` row.
pub type Label {
  Label(
    /// The session's name, as its own page's heading draws it.
    name: String,
    /// Where the session's tools run.
    placement: Placement,
  )
}

/// The answer to an attach.
pub type Attached {
  Attached(
    /// The feed's token, 128 bits in hexadecimal, which every later poll, send
    /// and detach carries.
    feed: String,
    /// The box daemon's epoch, which later calls fence against.
    epoch: String,
    /// The session's resident incarnation the feed is bound to.
    incarnation: String,
    /// The heading's words.
    label: Label,
  )
}

/// The answer to a poll.
pub type Answer {
  Answer(
    /// The number of the first frame in `frames`. With no frames it is the
    /// number the next frame will carry.
    first: Int,
    /// The frames after `after`, in number order.
    frames: List(String),
    /// `None` while the feed is live, and why it is not once it is not.
    ended: Option(FeedEnd),
  )
}

/// What the box says of the session's workspace to a feed that asked.
pub type Observation {
  /// The box's observation, the board `client/worktree_diff.to_json` encodes,
  /// which the page reads with `session_view/worktree_view.decode`.
  Observed(
    /// The board, at most `max_worktree_bytes` of JSON.
    board: JsonValue,
  )

  /// The box does not show the workspace to this feed: its standing is an
  /// observer's, or it no longer passes the check. The page lists the agent's
  /// own edits and draws no reason, as it does for a page that holds no read.
  Withheld

  /// The box could not make an observation it would stand behind. The text of
  /// why is never sent, because a repository's own words can be in it.
  Unreadable
}

/// The box's answers to the five operations, as closures the daemon fills. The
/// node is the one the exchange took from the caller's reply subject, never a
/// field of the body, so a body cannot name another spawner.
pub type Host {
  Host(
    /// Opens a feed on a relayed session, given the node and the attach.
    attach: fn(String, Attach) -> Result(Attached, Refusal),
    /// Answers a poll, given the node and the poll. It may wait up to the
    /// poll's `wait_ms`.
    poll: fn(String, Poll) -> Result(Answer, Refusal),
    /// Admits one piece of a frame, given the node and the piece.
    send: fn(String, Piece) -> Result(Nil, Refusal),
    /// Ends a feed, given the node and the token. Ending a feed that is gone
    /// is not a refusal.
    detach: fn(String, String) -> Result(Nil, Refusal),
    /// Observes the session's workspace for a feed, given the node and the
    /// token. It may run Git, so it waits as long as the observation's own
    /// deadline.
    worktree: fn(String, String) -> Result(Observation, Refusal),
  )
}

/// The host of a daemon that serves no feed: every operation is refused with
/// `UnknownSpawner`, naming the node it came from, as `refusing_top` refuses the
/// eight messages of 094.
///
/// ## Examples
///
/// ```gleam
/// assert remote_feed.declining().detach("laptop@10.0.0.1", "t")
///   == Error(remote_top.UnknownSpawner("laptop@10.0.0.1"))
/// ```
pub fn declining() -> Host {
  Host(
    attach: fn(node, _attach) { Error(remote_top.UnknownSpawner(node:)) },
    poll: fn(node, _poll) { Error(remote_top.UnknownSpawner(node:)) },
    send: fn(node, _piece) { Error(remote_top.UnknownSpawner(node:)) },
    detach: fn(node, _feed) { Error(remote_top.UnknownSpawner(node:)) },
    worktree: fn(node, _feed) { Error(remote_top.UnknownSpawner(node:)) },
  )
}

/// Whether a revision belongs to this vocabulary.
///
/// ## Examples
///
/// ```gleam
/// assert remote_feed.is_revision("108.feed.1")
/// assert !remote_feed.is_revision("108.feed.2")
/// ```
pub fn is_revision(revision: String) -> Bool {
  list.contains(revisions, revision)
}

/// Whether a text is shaped as an attach token: 32 lowercase hexadecimal
/// characters. It says nothing of whether the box holds that feed.
///
/// ## Examples
///
/// ```gleam
/// assert remote_feed.is_token("0123456789abcdef0123456789abcdef")
/// assert !remote_feed.is_token("0123")
/// ```
pub fn is_token(text: String) -> Bool {
  string.byte_size(text) == token_chars
  && list.all(string.to_graphemes(text), fn(char) {
    string.contains("0123456789abcdef", char)
  })
}

// --- the requests ------------------------------------------------------------------

/// The revision a request is sent under.
///
/// ## Examples
///
/// ```gleam
/// assert remote_feed.revision_of(remote_feed.DetachRequest("t")) == "108.detach.1"
/// ```
pub fn revision_of(request: Request) -> String {
  case request {
    AttachRequest(..) -> attach_revision
    PollRequest(..) -> feed_revision
    SendRequest(..) -> send_revision
    DetachRequest(..) -> detach_revision
    WorktreeRequest(..) -> worktree_revision
  }
}

/// Encodes a request as the JSON array its revision's body is.
///
/// ## Examples
///
/// ```gleam
/// // remote_feed.encode_request(remote_feed.PollRequest(remote_feed.Poll(feed, 4, 5000)))
/// // == ["<feed>", 4, 5000]
/// ```
pub fn encode_request(request: Request) -> JsonValue {
  case request {
    AttachRequest(Attach(session:, principal:, name:)) ->
      json.Array([
        json.String(session),
        json.String(principal),
        json.String(name),
      ])
    PollRequest(Poll(feed:, after:, wait_ms:)) ->
      json.Array([json.String(feed), json.Int(after), json.Int(wait_ms)])
    SendRequest(Piece(feed:, n:, offset:, total:, text:)) ->
      json.Array([
        json.String(feed),
        json.Int(n),
        json.Int(offset),
        json.Int(total),
        json.String(text),
      ])
    DetachRequest(feed:) | WorktreeRequest(feed:) ->
      json.Array([json.String(feed)])
  }
}

/// Reads the body of a request sent under `revision`. Every text is within its
/// bound, a token is shaped as one, a poll waits at most `max_wait_ms`, a piece
/// lies inside its frame and is at most `piece_bytes`, and a body of another
/// arity or with a member of another type is refused. A revision that is not
/// one of the four is refused too, so the caller routes with `is_revision`
/// first.
///
/// ## Examples
///
/// ```gleam
/// assert remote_feed.decode_request("108.detach.1", json.Array([json.String("x")]))
///   == Error("the feed token is not 32 lowercase hexadecimal characters")
/// ```
pub fn decode_request(
  revision: String,
  body: JsonValue,
) -> Result(Request, String) {
  // The revision picks the body's shape, and a body of any other arity or with a
  // member of another type is refused whole.
  case revision, body {
    "108.attach.1", json.Array([session, principal, name]) -> {
      use session <- result.try(bounded(session, "session", 1, max_text_bytes))
      use principal <- result.try(bounded(
        principal,
        "principal",
        1,
        max_text_bytes,
      ))
      use name <- result.map(bounded(name, "name", 0, max_text_bytes))
      AttachRequest(Attach(session:, principal:, name:))
    }
    "108.feed.1", json.Array([feed, after, wait_ms]) -> {
      use feed <- result.try(token(feed))
      use after <- result.try(number(after, "after", 0, max_number))
      use wait_ms <- result.map(number(wait_ms, "wait_ms", 0, max_wait_ms))
      PollRequest(Poll(feed:, after:, wait_ms:))
    }
    "108.send.1", json.Array([feed, n, offset, total, piece]) ->
      decode_piece(feed, n, offset, total, piece)
    "108.detach.1", json.Array([feed]) ->
      token(feed) |> result.map(DetachRequest)
    "108.worktree.1", json.Array([feed]) ->
      token(feed) |> result.map(WorktreeRequest)
    _, _ -> Error("the body is not one the revision takes")
  }
}

/// Reads the five members of a `108.send.1` body and checks the piece lies
/// inside its frame.
fn decode_piece(
  feed: JsonValue,
  n: JsonValue,
  offset: JsonValue,
  total: JsonValue,
  piece: JsonValue,
) -> Result(Request, String) {
  use feed <- result.try(token(feed))
  use n <- result.try(number(n, "n", 1, max_number))
  use offset <- result.try(number(offset, "offset", 0, frame_bytes))
  use total <- result.try(number(total, "total", 1, frame_bytes))

  // The piece is the one text that may run to `piece_bytes`.
  use text <- result.try(bounded(piece, "piece", 1, piece_bytes))
  let size = string.byte_size(text)

  // A piece stays inside its frame, and either ends it or is a full piece, so a
  // frame arrives in at most `max_pieces` pieces.
  case offset + size <= total {
    False -> Error("the piece does not lie inside its frame")
    True ->
      case offset + size == total || size >= min_piece_bytes {
        True -> Ok(SendRequest(Piece(feed:, n:, offset:, total:, text:)))
        False -> Error("a piece that does not end its frame is a full piece")
      }
  }
}

// --- the answers -------------------------------------------------------------------

/// Encodes the answer to an attach.
///
/// ## Examples
///
/// ```gleam
/// // remote_feed.encode_attached(attached)
/// // == {"attach": "<token>", "epoch": "...", "incarnation": "...", "label": {...}}
/// ```
pub fn encode_attached(attached: Attached) -> JsonValue {
  let Attached(feed:, epoch:, incarnation:, label:) = attached
  json.Object([
    #("attach", json.String(feed)),
    #("epoch", json.String(epoch)),
    #("incarnation", json.String(incarnation)),
    #(
      "label",
      json.Object([
        #("name", json.String(label.name)),
        #("placement", remote_top.encode_placement(label.placement)),
      ]),
    ),
  ])
}

/// Reads the answer to an attach. The token is shaped as one, the epoch and the
/// incarnation are within `max_identity_bytes`, and the label's texts are within
/// `max_text_bytes`, so a heading is never drawn from text the page did not
/// bound.
///
/// ## Examples
///
/// ```gleam
/// // remote_feed.decode_attached(remote_feed.encode_attached(attached)) == Ok(attached)
/// ```
pub fn decode_attached(value: JsonValue) -> Result(Attached, String) {
  use fields <- result.try(object(value, "the attach answer"))
  use feed <- result.try(member(fields, "attach") |> result.try(token))
  use epoch <- result.try(
    member(fields, "epoch") |> result.try(identity(_, "epoch")),
  )
  use incarnation <- result.try(
    member(fields, "incarnation") |> result.try(identity(_, "incarnation")),
  )
  use label <- result.map(member(fields, "label") |> result.try(decode_label))
  Attached(feed:, epoch:, incarnation:, label:)
}

/// Reads a label, whose placement is read by 094's own total decoder and whose
/// texts are then held to the label's bound.
fn decode_label(value: JsonValue) -> Result(Label, String) {
  use fields <- result.try(object(value, "the label"))
  use name <- result.try(
    member(fields, "name") |> result.try(bounded(_, "name", 0, max_text_bytes)),
  )
  use placement <- result.try(
    member(fields, "placement") |> result.try(remote_top.decode_placement),
  )
  Ok(Label(name:, placement:))
}

/// Encodes the answer to a poll.
///
/// ## Examples
///
/// ```gleam
/// // remote_feed.encode_answer(remote_feed.Answer(3, ["{}"], option.None))
/// // == {"first": 3, "frames": ["{}"], "ended": null}
/// ```
pub fn encode_answer(answer: Answer) -> JsonValue {
  json.Object([
    #("first", json.Int(answer.first)),
    #("frames", json.Array(list.map(answer.frames, json.String))),
    #("ended", case answer.ended {
      Some(why) -> json.String(end_word(why))
      None -> json.Null
    }),
  ])
}

/// Reads the answer to a poll. `first` is at least one, there are at most
/// `queue_frames` frames, and `ended` is `null` or one of the three words.
///
/// ## Examples
///
/// ```gleam
/// // remote_feed.decode_answer(remote_feed.encode_answer(answer)) == Ok(answer)
/// ```
pub fn decode_answer(value: JsonValue) -> Result(Answer, String) {
  use fields <- result.try(object(value, "the poll answer"))
  use first <- result.try(
    member(fields, "first") |> result.try(number(_, "first", 1, max_number)),
  )
  use frames <- result.try(member(fields, "frames") |> result.try(frames_of))
  use ended <- result.map(member(fields, "ended") |> result.try(ended_of))
  Answer(first:, frames:, ended:)
}

/// Reads the frames of an answer: strings, at most `queue_frames` of them.
fn frames_of(value: JsonValue) -> Result(List(String), String) {
  case value {
    json.Array(items) ->
      case list.length(items) <= queue_frames {
        True ->
          list.try_map(items, fn(item) {
            case item {
              json.String(frame) -> Ok(frame)
              _ -> Error("a frame is not text")
            }
          })
        False -> Error("the answer holds more frames than a feed queues")
      }
    _ -> Error("frames is not an array")
  }
}

/// Reads the ending of an answer.
fn ended_of(value: JsonValue) -> Result(Option(FeedEnd), String) {
  case value {
    json.Null -> Ok(None)
    json.String("lapsed") -> Ok(Some(remote_top.FeedLapsed))
    json.String("stopped") -> Ok(Some(remote_top.FeedStopped))
    json.String("revoked") -> Ok(Some(remote_top.FeedRevoked))
    _ -> Error("ended is not null or a known word")
  }
}

/// The word a feed's ending takes in a poll answer.
fn end_word(why: FeedEnd) -> String {
  case why {
    remote_top.FeedLapsed -> "lapsed"
    remote_top.FeedStopped -> "stopped"
    remote_top.FeedRevoked -> "revoked"
  }
}

// --- the workspace observation -----------------------------------------------------

/// The answer for a board the box observed: `Observed` when its JSON is within
/// `max_worktree_bytes`, and `Unreadable` when it is not. A board is never cut
/// here, because the observation was already clipped to its own budget where it
/// was made, and cutting JSON again would leave a board that does not read.
///
/// ## Examples
///
/// ```gleam
/// assert remote_feed.observed(json.Object([])) == remote_feed.Observed(json.Object([]))
/// ```
pub fn observed(board: JsonValue) -> Observation {
  case within_worktree_bound(board) {
    True -> Observed(board:)
    False -> Unreadable
  }
}

/// Whether a board's JSON is within `max_worktree_bytes`.
fn within_worktree_bound(board: JsonValue) -> Bool {
  string.byte_size(json.to_string(board)) <= max_worktree_bytes
}

/// Encodes the answer to a workspace observation: an object whose `read` is
/// `seen`, `withheld` or `unreadable`, and which carries the `board` only for
/// `seen`.
///
/// ## Examples
///
/// ```gleam
/// // remote_feed.encode_observation(remote_feed.Withheld) == {"read": "withheld"}
/// ```
pub fn encode_observation(observation: Observation) -> JsonValue {
  case observation {
    Observed(board:) ->
      json.Object([#("read", json.String("seen")), #("board", board)])
    Withheld -> json.Object([#("read", json.String("withheld"))])
    Unreadable -> json.Object([#("read", json.String("unreadable"))])
  }
}

/// Reads the answer to a workspace observation. `read` is one of the three
/// words, a `seen` answer carries a `board` object within `max_worktree_bytes`,
/// and anything else is refused whole. The board's own fields are read by the
/// page's decoder (`session_view/worktree_view.decode`), which refuses a board
/// that does not read, so nothing of the box's text is drawn before both agree.
///
/// ## Examples
///
/// ```gleam
/// // remote_feed.decode_observation(remote_feed.encode_observation(observation)) == Ok(observation)
/// ```
pub fn decode_observation(value: JsonValue) -> Result(Observation, String) {
  use fields <- result.try(object(value, "the workspace answer"))
  use read <- result.try(member(fields, "read"))

  // The word picks the answer, and only a `seen` one carries a board.
  case read {
    json.String("seen") -> {
      use board <- result.try(member(fields, "board"))
      seen_board(board)
    }
    json.String("withheld") -> Ok(Withheld)
    json.String("unreadable") -> Ok(Unreadable)
    _ -> Error("read is not a known word")
  }
}

/// Reads the board of a `seen` answer: an object within the bound.
fn seen_board(board: JsonValue) -> Result(Observation, String) {
  case board {
    json.Object(_) ->
      case within_worktree_bound(board) {
        True -> Ok(Observed(board:))
        False -> Error("the workspace board is over its bound")
      }
    _ -> Error("the workspace board is not an object")
  }
}

// --- total reading helpers ---------------------------------------------------------

/// The largest number any member may take. It is the width JSON integers keep
/// exact on the JavaScript target, so a laptop that decodes on either target
/// reads the same value.
const max_number = 9_007_199_254_740_991

type Fields =
  List(#(String, JsonValue))

/// Reads an object, naming what was expected.
fn object(value: JsonValue, place: String) -> Result(Fields, String) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error(place <> " is not an object")
  }
}

/// Reads one required member.
fn member(fields: Fields, key: String) -> Result(JsonValue, String) {
  list.key_find(fields, key)
  |> result.map_error(fn(_) { key <> " is missing" })
}

/// Reads a text of at least `least` bytes and at most `most`.
fn bounded(
  value: JsonValue,
  place: String,
  least: Int,
  most: Int,
) -> Result(String, String) {
  // Only text of an allowed size is read.
  case value {
    json.String(found) -> {
      let size = string.byte_size(found)

      // A text outside the bound is refused whole, never cut.
      case size >= least && size <= most {
        True -> Ok(found)
        False -> Error(place <> " is not within its size bounds")
      }
    }
    _ -> Error(place <> " is not text")
  }
}

/// Reads an epoch or an incarnation: nonempty and within the identity bound.
fn identity(value: JsonValue, place: String) -> Result(String, String) {
  case value {
    json.String(found) ->
      case found != "" && string.byte_size(found) <= max_identity_bytes {
        True -> Ok(found)
        False -> Error(place <> " is not within its size bounds")
      }
    _ -> Error(place <> " is not text")
  }
}

/// Reads an attach token.
fn token(value: JsonValue) -> Result(String, String) {
  case value {
    json.String(found) ->
      case is_token(found) {
        True -> Ok(found)
        False ->
          Error("the feed token is not 32 lowercase hexadecimal characters")
      }
    _ -> Error("the feed token is not text")
  }
}

/// Reads an integer in `[least, most]`.
fn number(
  value: JsonValue,
  place: String,
  least: Int,
  most: Int,
) -> Result(Int, String) {
  case value {
    json.Int(found) if found >= least && found <= most -> Ok(found)
    json.Int(_) -> Error(place <> " is out of range")
    _ -> Error(place <> " is not an integer")
  }
}
