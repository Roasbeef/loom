//// A live session feed end to end in one VM (protocol-change/108, slice 2).
////
//// The box is a real registry over a real catalogue, a real `TopHost` and the
//// real stable endpoint (`peer_service`), called with `node.self()` as the peer
//// the way `top_host_test` calls it. The session's gateway is a real hub
//// (`gateway_test.reserved_fixture`) with a real runtime, so a frame the test's
//// lane sends is judged by the gateway's own decoder and every decision goes
//// through the hub's relayed door. Only the session's resident instance is a
//// fake, because the registry publishes it and the feed reaches the gateway
//// through the context.
////
//// Each hostile case of the proposal's test plan is here, with the check that
//// it left the session, the gateway and the other feeds as they were. The
//// refused call that settles in band under a feed with no ceiling, and parks
//// under one with a ceiling, runs the real escalation seam over the feed's own
//// gateway.

import broker/escalation as broker_escalation
import broker/policy.{type Grant}
import client/approval_ceiling
import client/daemon/manager
import client/escalate
import client/gateway
import client/grants
import client/internal/ffi_os
import client/protocol
import client/remote/peer_client
import client/remote_feed
import client/remote_top
import client/spawners
import core/clock
import core/ids
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import runtime/api
import runtime/escalation as durable
import support/addresses
import support/feed_rig.{
  type Rig, configuration, deciding, epoch, paged, prompts, rig, watching,
}
import weft/poll

const answers_within_ms = 7000

// --- the calls --------------------------------------------------------------

fn call(
  rig: Rig,
  revision: String,
  request: remote_feed.Request,
) -> Result(Result(JsonValue, remote_top.Refusal), peer_client.Failure) {
  peer_client.call(
    rig.peer,
    revision,
    remote_feed.encode_request(request),
    answers_within_ms,
  )
}

fn attach_as(
  rig: Rig,
  session: String,
) -> Result(remote_feed.Attached, remote_top.Refusal) {
  let assert Ok(answer) =
    call(
      rig,
      remote_feed.attach_revision,
      remote_feed.AttachRequest(remote_feed.Attach(
        session:,
        principal: "page-1",
        name: "Laptop page",
      )),
    )
    as "the attach is answered"
  use value <- result.map(answer)
  let assert Ok(attached) = remote_feed.decode_attached(value)
    as "the attach answer decodes"
  attached
}

fn attach(rig: Rig) -> remote_feed.Attached {
  let assert Ok(attached) = attach_as(rig, rig.session)
    as "the attach is admitted"
  attached
}

fn poll_feed(
  rig: Rig,
  attached: remote_feed.Attached,
  after: Int,
  wait_ms: Int,
) -> Result(remote_feed.Answer, remote_top.Refusal) {
  let assert Ok(answer) =
    call(
      rig,
      remote_feed.feed_revision,
      remote_feed.PollRequest(remote_feed.Poll(
        feed: attached.feed,
        after:,
        wait_ms:,
      )),
    )
    as "the poll is answered"
  use value <- result.map(answer)
  let assert Ok(decoded) = remote_feed.decode_answer(value)
    as "the poll answer decodes"
  decoded
}

fn send_piece(
  rig: Rig,
  attached: remote_feed.Attached,
  piece: remote_feed.Piece,
) -> Result(Nil, remote_top.Refusal) {
  let assert Ok(answer) =
    call(
      rig,
      remote_feed.send_revision,
      remote_feed.SendRequest(remote_feed.Piece(..piece, feed: attached.feed)),
    )
    as "the send is answered"
  result.map(answer, fn(value) {
    assert value == json.Null
    Nil
  })
}

fn detach(rig: Rig, attached: remote_feed.Attached) -> Nil {
  let assert Ok(Ok(value)) =
    call(
      rig,
      remote_feed.detach_revision,
      remote_feed.DetachRequest(attached.feed),
    )
    as "the detach is answered"
  assert value == json.Null
}

/// A whole frame as one piece.
fn whole(n: Int, text: String) -> remote_feed.Piece {
  remote_feed.Piece(
    feed: "",
    n:,
    offset: 0,
    total: string.byte_size(text),
    text:,
  )
}

/// A frame cut at `at` bytes into its two pieces. The frames here are ASCII, so
/// a byte cut is a character cut.
fn halves(
  n: Int,
  text: String,
  at: Int,
) -> #(remote_feed.Piece, remote_feed.Piece) {
  let total = string.byte_size(text)
  let bytes = bit_array.from_string(text)
  let assert Ok(head) = bit_array.slice(bytes, 0, at) as "the head is inside"
  let assert Ok(tail) = bit_array.slice(bytes, at, total - at)
    as "the tail is inside"
  let assert Ok(head) = bit_array.to_string(head) as "ASCII is text"
  let assert Ok(tail) = bit_array.to_string(tail) as "ASCII is text"
  #(
    remote_feed.Piece(feed: "", n:, offset: 0, total:, text: head),
    remote_feed.Piece(feed: "", n:, offset: at, total:, text: tail),
  )
}

fn command_text(id: Int, command: protocol.Command) -> String {
  protocol.encode_command(protocol.CommandEnvelope(id:, command:))
}

/// A prompt of about 450,000 bytes, which takes two pieces because the box
/// refuses a piece shorter than `min_piece_bytes` that does not end its frame.
fn big_prompt(id: Int) -> String {
  command_text(id, protocol.Prompt("main", string.repeat("x", 450_000)))
}

/// The first piece a sender sends of a frame that takes two.
fn head_of(n: Int, text: String) -> remote_feed.Piece {
  halves(n, text, remote_feed.min_piece_bytes).0
}

/// The last piece of a frame that takes two.
fn tail_of(n: Int, text: String) -> remote_feed.Piece {
  halves(n, text, remote_feed.min_piece_bytes).1
}

fn subscribe(rig: Rig) -> String {
  command_text(1, protocol.Subscribe(rig.session, None))
}

// --- reading what the feed queued -----------------------------------------------

/// Polls until a frame satisfies `wanted`, answering every frame seen and the
/// number to resume from. A poll that cannot be answered, or an ended feed, is a
/// failure the test names.
fn until(
  rig: Rig,
  attached: remote_feed.Attached,
  after: Int,
  seen: List(String),
  wanted: fn(String) -> Bool,
) -> #(List(String), Int) {
  case list.any(seen, wanted) {
    True -> #(seen, after)
    False -> {
      let assert poll.Answered(next) =
        poll.until(within: 8000, every: 1, attempt: fn() {
          case poll_feed(rig, attached, after, 500) {
            Ok(remote_feed.Answer(
              frames: [_, ..] as frames,
              first:,
              ended: None,
            )) -> poll.Done(#(frames, first))
            Ok(remote_feed.Answer(ended: Some(why), ..)) ->
              poll.Fail("the feed ended: " <> string.inspect(why))
            Ok(remote_feed.Answer(ended: None, ..)) -> poll.Retry
            Error(refusal) -> poll.Fail(string.inspect(refusal))
          }
        })
        as "the feed answers with frames"
      let #(frames, first) = next
      assert first == after + 1
      until(
        rig,
        attached,
        after + list.length(frames),
        list.append(seen, frames),
        wanted,
      )
    }
  }
}

fn reply_to(id: Int) -> fn(String) -> Bool {
  fn(frame) {
    case protocol.decode_event(frame) {
      Ok(protocol.EventEnvelope(reply_to: Some(found), ..)) -> found == id
      _ -> False
    }
  }
}

fn errors_with(frame: String) -> Option(String) {
  case protocol.decode_event(frame) {
    Ok(protocol.EventEnvelope(event: protocol.ErrorEvent(code:, ..), ..)) ->
      Some(code)
    _ -> None
  }
}

/// The frame that answers request `id`, among `frames`.
fn answer_to(frames: List(String), id: Int) -> String {
  let assert Ok(frame) = list.find(frames, reply_to(id))
    as "the request has an answer among the frames"
  frame
}

/// A feed that has subscribed, with the frames its subscribe produced and the
/// number to poll from next.
fn subscribed(rig: Rig) -> #(remote_feed.Attached, Int) {
  let attached = attach(rig)
  let assert Ok(Nil) = send_piece(rig, attached, whole(1, subscribe(rig)))
    as "the subscribe is admitted"
  let #(_frames, after) = until(rig, attached, 0, [], reply_to(1))
  #(attached, after)
}

// --- the escalation helpers ---------------------------------------------------

fn op_id(seed: Int) -> ids.OpId {
  let #(op, _generator) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed:))
  op
}

/// Files a pending request the way `client/escalate` does.
fn claim(rig: Rig, id: String, wanted: List(Grant)) -> Int {
  let denial =
    grants.encode_denial(
      reason: "tool requirements exceed the session policy",
      source: broker_escalation.PolicyDenial,
      wanted:,
    )
  let assert Ok(durable.Claimed(_record)) =
    api.claim_escalation(
      rig.harness.runtime,
      id,
      denial,
      action: durable.Action(tool: "bash", digest: "d1", preview: "{}"),
      scope: durable.CallScope(
        operation: op_id(5),
        strand: "main",
        step_id: "turn-1:tools",
        source_index: 0,
        call_id: "call-main",
      ),
      max_asks: 3,
    )
    as "the request is filed"
  let assert Ok(cell) = api.escalation_cell(rig.harness.runtime, id)
    as "the request is readable"
  cell.seq
}

fn stored_status(rig: Rig, id: String) -> durable.Status {
  let assert Ok(record) = api.escalation(rig.harness.runtime, id)
    as "the record is readable"
  record.status
}

fn env(name: String) -> Grant {
  policy.GrantEnv(name)
}

/// The one network grant a session can remember.
fn full_network() -> Grant {
  policy.GrantNetwork(policy.NetworkFull)
}

/// The strands the session's store holds.
fn strands(rig: Rig) -> List(String) {
  let assert Ok(names) = api.strands(rig.harness.runtime)
    as "the strands are readable"
  list.sort(names, string.compare)
}

// --- attaching ----------------------------------------------------------------

pub fn an_attach_answers_a_token_the_epoch_the_incarnation_and_a_heading_test() {
  let rig = rig("attach", deciding, remote_feed.lease_ms)
  let attached = attach(rig)
  assert remote_feed.is_token(attached.feed)
  assert attached.epoch == epoch
  let assert Ok(manager.View(status: manager.Resident(incarnation), ..)) =
    manager.get(rig.registry, rig.session)
  assert attached.incarnation == incarnation
  assert attached.label.name == "laptop session"
  assert attached.label.placement
    == remote_top.Workspace(executor: "exec", name: "repo")

  // The feed is a gateway attachment, and it counts as someone being there.
  assert gateway.attached(rig.harness.hub) == rig.baseline + 1
}

pub fn a_session_that_is_not_the_spawners_is_refused_and_takes_no_place_test() {
  let rig = rig("not-relayed", deciding, remote_feed.lease_ms)
  assert attach_as(rig, "0198c0de-0000-7000-8000-00000000dead")
    == Error(remote_top.NotRelayed)
  assert gateway.attached(rig.harness.hub) == rig.baseline
}

pub fn a_table_that_serves_the_paged_page_refuses_the_attach_test() {
  let rig = rig("paged", paged, remote_feed.lease_ms)
  assert attach_as(rig, rig.session)
    == Error(remote_top.NotOffered(remote_top.OfferedPage, "live"))
  assert gateway.attached(rig.harness.hub) == rig.baseline
}

pub fn an_attach_beyond_the_feed_cap_is_refused_and_leaves_the_others_test() {
  let rig = rig("cap", deciding, remote_feed.lease_ms)
  let feeds = list.map(numbers(1, remote_feed.max_feeds), fn(_) { attach(rig) })
  let assert [first, ..] = feeds
  assert attach_as(rig, rig.session)
    == Error(remote_top.CapReached(
      cap: remote_top.MaxFeeds,
      limit: remote_feed.max_feeds,
    ))

  // Every feed still answers, and a place frees when one detaches.
  list.each(feeds, fn(feed) {
    let assert Ok(remote_feed.Answer(ended: None, ..)) =
      poll_feed(rig, feed, 0, 0)
      as "a feed is untouched by the refused attach"
    Nil
  })
  detach(rig, first)
  let assert poll.Answered(_) =
    poll.until(within: 5000, every: 20, attempt: fn() {
      case attach_as(rig, rig.session) {
        Ok(_) -> poll.Done(Nil)
        Error(_) -> poll.Retry
      }
    })
    as "a detached feed gives its place back"
}

// --- the lane's frames reach the gateway -------------------------------------------

pub fn a_prompt_sent_in_two_pieces_is_answered_in_a_poll_test() {
  let rig = rig("pieces", deciding, remote_feed.lease_ms)
  let #(attached, after) = subscribed(rig)
  let prompt = big_prompt(2)
  let assert Ok(Nil) = send_piece(rig, attached, head_of(2, prompt))
    as "the first piece is admitted"

  // Half a frame is not a frame, so the gateway has been told nothing of it.
  let assert Ok(remote_feed.Answer(frames:, ended: None, ..)) =
    poll_feed(rig, attached, after, 0)
    as "the feed answers"
  assert !list.any(frames, reply_to(2))
  assert prompts(rig) == []
  let assert Ok(Nil) = send_piece(rig, attached, tail_of(2, prompt))
    as "the last piece is admitted"
  let #(frames, _after) = until(rig, attached, after, [], reply_to(2))
  let assert Ok(_) = protocol.decode_event(answer_to(frames, 2))
    as "the reply is the gateway's own frame"
}

pub fn a_frame_may_not_arrive_a_byte_at_a_time_test() {
  let rig = rig("one-byte", deciding, remote_feed.lease_ms)
  let attached = attach(rig)

  // The decoder refuses the first one-byte piece, so the box holds none.
  let tiny =
    remote_feed.Piece(feed: "", n: 1, offset: 0, total: 450_000, text: "x")
  let assert Error(peer_client.Unreadable) =
    result.map(
      call(
        rig,
        remote_feed.send_revision,
        remote_feed.SendRequest(remote_feed.Piece(..tiny, feed: attached.feed)),
      ),
      fn(_) { Nil },
    )
    as "a one-byte piece that does not end its frame is malformed"
  let assert Ok(remote_feed.Answer(ended: None, ..)) =
    poll_feed(rig, attached, 0, 0)
    as "the feed is untouched"
  Nil
}

pub fn a_piece_resent_after_a_lost_answer_reaches_the_gateway_once_test() {
  let rig = rig("resend", deciding, remote_feed.lease_ms)
  let #(attached, after) = subscribed(rig)
  let prompt = command_text(2, protocol.Prompt("main", "hello"))
  let assert Ok(Nil) = send_piece(rig, attached, whole(2, prompt))
    as "the prompt is admitted"

  // The answer to the send was lost, so the laptop sends the same piece again.
  let assert Ok(Nil) = send_piece(rig, attached, whole(2, prompt))
    as "a repeated piece is answered again"
  let #(frames, _after) = until(rig, attached, after, [], reply_to(2))

  // The gateway saw one prompt, and answered it once.
  assert list.count(frames, reply_to(2)) == 1
  assert prompts(rig) == ["hello"]
}

pub fn the_frames_of_a_poll_are_numbered_from_one_and_acknowledged_by_after_test() {
  let rig = rig("numbers", deciding, remote_feed.lease_ms)
  let attached = attach(rig)
  let assert Ok(Nil) = send_piece(rig, attached, whole(1, subscribe(rig)))
    as "the subscribe is admitted"
  let #(frames, after) = until(rig, attached, 0, [], reply_to(1))

  // The same cursor again is answered with the same frames, which is how a
  // lost answer is recovered, and the next cursor acknowledges them.
  let assert Ok(again) = poll_feed(rig, attached, 0, 0)
    as "the poll is repeated"
  assert again.first == 1
  assert list.take(again.frames, list.length(frames)) == frames
  let assert Ok(done) = poll_feed(rig, attached, after, 0)
    as "the cursor advances"
  assert done.first == after + 1

  // What a poll acknowledged is gone, so the old cursor can no longer be honoured.
  let assert Error(remote_top.InvalidArgument(_)) =
    poll_feed(rig, attached, 0, 0)
    as "an acknowledged frame is not answered again"
}

// --- hostile frames, toward the box ----------------------------------------------

pub fn a_command_outside_the_table_is_forbidden_and_never_reaches_the_gateway_test() {
  let rig = rig("forbidden", deciding, remote_feed.lease_ms)
  let #(attached, after) = subscribed(rig)
  let fork = command_text(3, protocol.Fork("main", protocol.ScopeBranch, None))
  let assert Ok(Nil) = send_piece(rig, attached, whole(2, fork))
    as "the frame is admitted"
  let #(frames, after) = until(rig, attached, after, [], reply_to(3))
  assert errors_with(answer_to(frames, 3)) == Some("forbidden")

  // The session has the one strand it began with, and the feed lives on.
  assert strands(rig) == ["main"]
  let assert Ok(remote_feed.Answer(ended: None, ..)) =
    poll_feed(rig, attached, after, 0)
    as "the feed is untouched"
}

pub fn an_approval_outside_the_ceiling_is_refused_and_the_request_stays_pending_test() {
  let rig = rig("outside", deciding, remote_feed.lease_ms)
  let #(attached, after) = subscribed(rig)
  let seq = claim(rig, "esc-1", [env("OTHER")])
  let approve =
    command_text(
      4,
      protocol.Approve("esc-1", [env("OTHER")], "d1", expected_seq: seq),
    )
  let assert Ok(Nil) = send_piece(rig, attached, whole(2, approve))
    as "the frame is admitted"
  let #(frames, _after) = until(rig, attached, after, [], reply_to(4))
  assert errors_with(answer_to(frames, 4)) == Some("bad_request")
  assert stored_status(rig, "esc-1") == durable.Pending
}

pub fn an_approval_inside_the_ceiling_is_judged_by_the_relayed_door_test() {
  let rig = rig("inside", deciding, remote_feed.lease_ms)
  let #(attached, after) = subscribed(rig)
  let seq = claim(rig, "esc-1", [env("TOKEN")])
  let approve =
    command_text(
      4,
      protocol.Approve("esc-1", [env("TOKEN")], "d1", expected_seq: seq),
    )
  let assert Ok(Nil) = send_piece(rig, attached, whole(2, approve))
    as "the frame is admitted"
  let #(frames, _after) = until(rig, attached, after, [], reply_to(4))
  assert errors_with(answer_to(frames, 4)) == None
  assert stored_status(rig, "esc-1") == durable.Approved
}

pub fn a_feed_with_no_ceiling_decides_nothing_test() {
  let rig = rig("no-ceiling", watching, remote_feed.lease_ms)
  let #(attached, after) = subscribed(rig)
  let seq = claim(rig, "esc-1", [env("TOKEN")])
  let deny = command_text(4, protocol.Deny("esc-1", expected_seq: seq))
  let assert Ok(Nil) = send_piece(rig, attached, whole(2, deny))
    as "the frame is admitted"
  let #(frames, _after) = until(rig, attached, after, [], reply_to(4))
  assert errors_with(answer_to(frames, 4)) == Some("bad_request")
  assert stored_status(rig, "esc-1") == durable.Pending
}

pub fn an_approval_of_a_request_this_session_does_not_hold_is_refused_test() {
  // A remote child's request lives on a third machine, so its identity is no
  // record of this session's register, and the hub cannot judge it.
  let rig = rig("remote-child", deciding, remote_feed.lease_ms)
  let #(attached, after) = subscribed(rig)
  let approve =
    command_text(
      4,
      protocol.Approve("elsewhere-1", [env("TOKEN")], "d1", expected_seq: 1),
    )
  let assert Ok(Nil) = send_piece(rig, attached, whole(2, approve))
    as "the frame is admitted"
  let #(frames, _after) = until(rig, attached, after, [], reply_to(4))
  assert errors_with(answer_to(frames, 4)) == Some("bad_request")
}

pub fn a_forget_of_everything_is_refused_and_a_forget_of_one_grant_redraws_the_board_test() {
  let rig = rig("forget", deciding, remote_feed.lease_ms)
  let #(attached, after) = subscribed(rig)

  // Everything the session remembers is not the spawner's to forget.
  let all =
    command_text(
      4,
      protocol.PermissionForget(protocol.ForgetAll, expected_seq: None),
    )
  let assert Ok(Nil) = send_piece(rig, attached, whole(2, all))
    as "the frame is admitted"
  let #(frames, after) = until(rig, attached, after, [], reply_to(4))
  assert errors_with(answer_to(frames, 4)) == Some("bad_request")

  // A grant the spawner approved for the session is its to withdraw, and the
  // reply is the permissions board read afterwards.
  let seq = claim(rig, "esc-1", [full_network()])
  let session =
    command_text(
      5,
      protocol.ApproveForSession(
        "esc-1",
        [full_network()],
        "d1",
        expected_seq: seq,
      ),
    )
  let assert Ok(Nil) = send_piece(rig, attached, whole(3, session))
    as "the approval is admitted"
  let #(frames, after) = until(rig, attached, after, [], reply_to(5))
  assert errors_with(answer_to(frames, 5)) == None
  let forget =
    command_text(
      6,
      protocol.PermissionForget(
        protocol.ForgetGrant(full_network()),
        expected_seq: None,
      ),
    )
  let assert Ok(Nil) = send_piece(rig, attached, whole(4, forget))
    as "the forget is admitted"
  let #(frames, _after) = until(rig, attached, after, [], reply_to(6))
  let assert Ok(protocol.EventEnvelope(
    event: protocol.SnapshotEvent(protocol.PermissionsSnapshot(..)),
    ..,
  )) = protocol.decode_event(answer_to(frames, 6))
    as "the reply is the permissions board"
  Nil
}

pub fn a_piece_out_of_order_or_of_another_frame_is_refused_and_changes_nothing_test() {
  let rig = rig("order", deciding, remote_feed.lease_ms)
  let attached = attach(rig)
  let prompt = big_prompt(1)
  let tail = tail_of(1, prompt)
  let assert Ok(Nil) = send_piece(rig, attached, head_of(1, prompt))
    as "the head is admitted"

  // A full piece that skips ahead of what was admitted is out of order.
  assert result.is_error(send_piece(
    rig,
    attached,
    remote_feed.Piece(
      ..tail,
      offset: tail.offset + 50_000,
      text: string.repeat("x", remote_feed.min_piece_bytes),
    ),
  ))
  assert result.is_error(send_piece(rig, attached, whole(3, subscribe(rig))))

  // The refusals changed nothing, so the rest of the frame still completes it.
  let assert Ok(Nil) = send_piece(rig, attached, tail) as "the tail is admitted"
  let #(_frames, _after) = until(rig, attached, 0, [], reply_to(1))
  Nil
}

pub fn an_after_ahead_of_what_was_sent_is_refused_test() {
  let rig = rig("ahead", deciding, remote_feed.lease_ms)
  let attached = attach(rig)
  let assert Error(remote_top.InvalidArgument(_)) =
    poll_feed(rig, attached, 99, 0)
    as "a cursor ahead of the queue is refused"
  let assert Ok(remote_feed.Answer(ended: None, ..)) =
    poll_feed(rig, attached, 0, 0)
    as "the feed is untouched"
  Nil
}

pub fn a_poll_with_an_unknown_token_is_answered_feed_ended_test() {
  let rig = rig("unknown", deciding, remote_feed.lease_ms)
  let attached = attach(rig)
  let stranger =
    remote_feed.Attached(..attached, feed: "0123456789abcdef0123456789abcdef")
  assert poll_feed(rig, stranger, 0, 0)
    == Error(remote_top.FeedEnded(remote_top.FeedLapsed))
  assert send_piece(rig, stranger, whole(1, subscribe(rig)))
    == Error(remote_top.FeedEnded(remote_top.FeedLapsed))

  // A detach of a feed the box does not hold is not a refusal.
  detach(rig, stranger)
  let assert Ok(remote_feed.Answer(ended: None, ..)) =
    poll_feed(rig, attached, 0, 0)
    as "the real feed is untouched"
  Nil
}

pub fn a_second_concurrent_poll_supersedes_the_first_test() {
  let rig = rig("supersede", deciding, remote_feed.lease_ms)
  let attached = attach(rig)
  let answers = process.new_subject()
  let _asker =
    process.spawn(fn() {
      process.send(answers, poll_feed(rig, attached, 0, 5000))
    })

  // The first poll is held, so asking again releases it at once with no frames.
  let assert poll.Answered(released) =
    poll.until(within: 3000, every: 25, attempt: fn() {
      case process.receive(answers, 0) {
        Ok(first) -> poll.Done(first)
        Error(Nil) -> {
          let _ = poll_feed(rig, attached, 0, 0)
          poll.Retry
        }
      }
    })
    as "the held poll is released by a later one"
  assert released == Ok(remote_feed.Answer(first: 1, frames: [], ended: None))
  let assert Ok(remote_feed.Answer(ended: None, ..)) =
    poll_feed(rig, attached, 0, 0)
    as "the feed is untouched"
  Nil
}

// --- the feed ends --------------------------------------------------------------

// The lease the lease tests run under, in milliseconds. It is long enough that a
// loaded machine does not lapse a feed a test polls, and short enough to wait for.
const short_lease_ms = 2000

pub fn a_feed_nobody_polls_lapses_and_drops_a_partial_frame_test() {
  let rig = rig("lapse", deciding, short_lease_ms)
  let attached = attach(rig)
  let other = attach(rig)
  let prompt = big_prompt(1)
  let assert Ok(Nil) = send_piece(rig, attached, head_of(1, prompt))
    as "the head is admitted"
  assert gateway.attached(rig.harness.hub) == rig.baseline + 2

  // Only the other feed is polled, so only the first one lapses.
  let assert poll.Answered(_) =
    poll.until(within: 10_000, every: 100, attempt: fn() {
      let assert Ok(remote_feed.Answer(ended: None, ..)) =
        poll_feed(rig, other, 0, 0)
        as "the polled feed stays live"
      case gateway.attached(rig.harness.hub) == rig.baseline + 1 {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "the lapsed feed detaches from the gateway"
  let assert Ok(remote_feed.Answer(frames: [], ended: Some(why), ..)) =
    poll_feed(rig, attached, 0, 0)
    as "a late poll learns why"
  assert why == remote_top.FeedLapsed
  assert send_piece(rig, attached, tail_of(1, prompt))
    == Error(remote_top.FeedEnded(remote_top.FeedLapsed))
}

pub fn a_polled_feed_outlives_the_lease_and_an_unpolled_one_lapses_test() {
  let rig = rig("boundary", deciding, short_lease_ms)
  let attached = attach(rig)

  // Each poll renews the lease, so polling every half lease for one and a half
  // leases leaves the feed live.
  list.each(numbers(1, 6), fn(_) {
    let assert Ok(remote_feed.Answer(ended: None, ..)) =
      poll_feed(rig, attached, 0, 0)
      as "a polled feed is live past its first lease"
    process.sleep(short_lease_ms / 2)
  })

  // Nobody polls any more, so a whole lease later it lapses. The gateway's count
  // is what shows it without a poll, which would renew the lease.
  let assert poll.Answered(_) =
    poll.until(within: 10_000, every: 100, attempt: fn() {
      case gateway.attached(rig.harness.hub) == rig.baseline {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "an unpolled feed lapses and detaches"
  let assert Ok(remote_feed.Answer(ended: Some(why), ..)) =
    poll_feed(rig, attached, 0, 0)
    as "a late poll learns why"
  assert why == remote_top.FeedLapsed
}

pub fn an_ended_feed_still_counts_toward_the_cap_until_it_is_forgotten_test() {
  let rig = rig("ended-cap", deciding, 3000)
  let feeds = list.map(numbers(1, remote_feed.max_feeds), fn(_) { attach(rig) })
  let assert [lapsing, ..others] = feeds

  // Only the others are polled, so the first lapses, and then holds its place
  // while the box keeps it for a late poll.
  let assert poll.Answered(_) =
    poll.until(within: 15_000, every: 200, attempt: fn() {
      list.each(others, fn(feed) {
        let assert Ok(remote_feed.Answer(ended: None, ..)) =
          poll_feed(rig, feed, 0, 0)
          as "the polled feeds stay live"
        Nil
      })
      case
        gateway.attached(rig.harness.hub) == rig.baseline + list.length(others)
      {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "the unpolled feed ends and detaches"
  let assert Ok(remote_feed.Answer(ended: Some(_), ..)) =
    poll_feed(rig, lapsing, 0, 0)
    as "a late poll learns that it ended"
  assert attach_as(rig, rig.session)
    == Error(remote_top.CapReached(
      cap: remote_top.MaxFeeds,
      limit: remote_feed.max_feeds,
    ))

  // Polling the others keeps them live until the ended feed is forgotten, and
  // then its place is free.
  let assert poll.Answered(_) =
    poll.until(within: 15_000, every: 200, attempt: fn() {
      list.each(others, fn(feed) {
        let assert Ok(remote_feed.Answer(ended: None, ..)) =
          poll_feed(rig, feed, 0, 0)
          as "the polled feeds stay live"
        Nil
      })
      case attach_as(rig, rig.session) {
        Ok(_) -> poll.Done(Nil)
        Error(_) -> poll.Retry
      }
    })
    as "the ended feed's place is free once it is forgotten"
}

pub fn a_detach_with_a_partial_frame_held_drops_it_and_frees_the_attachment_test() {
  let rig = rig("detach", deciding, remote_feed.lease_ms)
  let attached = attach(rig)
  let assert Ok(Nil) = send_piece(rig, attached, head_of(1, big_prompt(1)))
    as "the head is admitted"
  detach(rig, attached)
  let assert poll.Answered(_) =
    poll.until(within: 5000, every: 20, attempt: fn() {
      case gateway.attached(rig.harness.hub) == rig.baseline {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "the attachment leaves the gateway"
  // The detach is idempotent, whatever the box still holds.
  detach(rig, attached)
}

pub fn a_pause_in_polling_shorter_than_the_lease_loses_no_frame_test() {
  let rig = rig("pause", deciding, short_lease_ms)
  let attached = attach(rig)
  let assert Ok(Nil) = send_piece(rig, attached, whole(1, subscribe(rig)))
    as "the subscribe is admitted"

  // Nobody polls for a third of the lease while the gateway answers and pushes.
  process.sleep(short_lease_ms / 3)

  // The first poll after the pause carries everything from the first frame on.
  let assert Ok(remote_feed.Answer(frames:, first: 1, ended: None)) =
    poll_feed(rig, attached, 0, 1000)
    as "the frames written during the pause are all still there"
  assert list.any(frames, reply_to(1))
}

pub fn a_stopped_session_ends_its_feed_stopped_test() {
  let rig = rig("stopped", deciding, remote_feed.lease_ms)
  let attached = attach(rig)

  // The session's run ends, which is the gateway going away.
  let assert Ok(gateway_pid) = addresses.owner(rig.harness.hub.name)
    as "the gateway runs"
  process.unlink(gateway_pid)
  process.kill(gateway_pid)
  let assert poll.Answered(why) =
    poll.until(within: 5000, every: 25, attempt: fn() {
      case poll_feed(rig, attached, 0, 0) {
        Ok(remote_feed.Answer(ended: Some(why), ..)) -> poll.Done(why)
        _ -> poll.Retry
      }
    })
    as "the feed ends"
  assert why == remote_top.FeedStopped
}

pub fn the_feeds_token_is_in_no_pushed_frame_and_no_roster_entry_test() {
  let rig = rig("token-secret", deciding, remote_feed.lease_ms)
  let attached = attach(rig)
  let assert Ok(Nil) = send_piece(rig, attached, whole(1, subscribe(rig)))
    as "the subscribe is admitted"

  // The presence roster and the attachment event name the feed's connection to
  // every subscriber, so they are read, and none holds the token that names the
  // feed to the box.
  let #(frames, _after) =
    until(rig, attached, 0, [], fn(frame) {
      string.contains(frame, "\"presence\"")
    })
  assert list.any(frames, fn(frame) { string.contains(frame, "feed-") })
  assert !list.any(frames, fn(frame) { string.contains(frame, attached.feed) })
}

// --- whether a refused call waits --------------------------------------------------

/// Runs one refused call through the real escalation seam, over the feed's own
/// gateway, and says whether it parked. `interactive` is the daemon's own
/// question (`gateway.attached(hub) > 0`), asked against the count before any
/// feed attached because the fixture's sink is counted.
fn parked(rig: Rig) -> Bool {
  let rests = process.new_subject()
  let system = clock.from_function(ffi_os.system_time_ms)
  let config =
    escalate.Config(
      ..escalate.default_config(addresses.new(), system),
      interactive: fn() { gateway.attached(rig.harness.hub) > rig.baseline },
      park_timeout_ms: 300,
      poll_interval_ms: 20,
      rest: fn(_slice) {
        process.send(rests, Nil)
        process.sleep(20)
      },
    )
  let assert Ok(_holder) = escalate.start(config, rig.harness.runtime)
    as "the escalation holder starts"
  let decision =
    escalate.seam(config).refused(escalate.Refused(
      operation: op_id(9),
      strand: "main",
      step_id: "turn-1:tools",
      source_index: 0,
      call_id: "call-main",
      tool: "bash",
      denial: broker_escalation.Denial(
        reason: "tool requirements exceed the session policy",
        source: broker_escalation.PolicyDenial,
        wanted: [env("TOKEN")],
      ),
      arguments: json.Object([#("command", json.String("true"))]),
      deadline_ms: ffi_os.system_time_ms() + 60_000,
    ))

  // Nobody decides, so the call settles in band whichever way it went. What
  // differs is whether it waited for a decision first.
  assert decision == escalate.Settle
  result.is_ok(process.receive(rests, 0))
}

pub fn a_refused_call_settles_in_band_under_a_feed_with_no_ceiling_test() {
  let rig = rig("in-band", watching, remote_feed.lease_ms)
  let _attached = attach(rig)
  assert parked(rig) == False
}

pub fn a_refused_call_parks_under_a_feed_with_a_ceiling_test() {
  let rig = rig("parks", deciding, remote_feed.lease_ms)
  let _attached = attach(rig)
  assert parked(rig) == True
}

pub fn a_refused_call_settles_in_band_when_no_feed_is_attached_test() {
  let rig = rig("nobody", deciding, remote_feed.lease_ms)
  assert parked(rig) == False
}

// --- helpers ------------------------------------------------------------------

fn numbers(start: Int, stop: Int) -> List(Int) {
  case start > stop {
    True -> []
    False -> [start, ..numbers(start + 1, stop)]
  }
}

// The ceiling is read once from the table, so a test that wants to see it can
// parse the table text it ran under.
pub fn the_deciding_table_has_a_ceiling_and_the_watching_one_has_none_test() {
  let assert Ok([spawner]) = spawners.parse(configuration <> deciding)
  let assert Some(table) = spawner.top_level
  assert option.is_some(table.approval_ceiling)
  assert table.page == spawners.LivePage
  let assert Ok([spawner]) = spawners.parse(configuration <> watching)
  let assert Some(table) = spawner.top_level
  assert table.approval_ceiling == None
  assert approval_ceiling.nothing() == approval_ceiling.nothing()
}
