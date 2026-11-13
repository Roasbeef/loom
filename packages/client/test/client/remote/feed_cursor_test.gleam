//// The laptop's cursor over a live feed under generated sequences, driven by
//// `statem` (protocol-change/108, "Fixed-seed properties").
////
//// `feed_cursor` is a pure value, so the sequences need no process. A command is
//// the box writing frames, the cursor asking a poll, a reply of some shape to the
//// poll in flight or to an older one, or a fresh attach after the feed ended. The
//// replies include the ones a hostile or broken box sends: a repeat of frames the
//// laptop holds, a gap, frames carried with an ending, a refusal, a box that was
//// replaced and an answer that did not read.
////
//// The oracle restates the rules from the module doc of `feed_cursor` and from
//// `protocol/models/live-relay/PSrc/UiFeed.p`, never from the cursor's code, and
//// every rule is checked after every command under its own tag:
////
//// - `prefix`: the frames handed to the page are the frames the box wrote, from
////   the first, in order, with no gap and no repeat, within one feed;
//// - `monotone`: `after` equals the number of frames handed on and never moves
////   backward;
//// - `stray`: a reply to any poll but the one in flight, and any reply after the
////   feed is over, is a stray and changes nothing;
//// - `ended`: an answer that reports an ending, and one that skips a frame, hands
////   on nothing, and the feed is over after it;
//// - `pause`: a poll that goes unanswered is asked again after the pause the
////   oracle computes from the polls in a row that went unanswered;
//// - `redraw`: a fresh attach starts a new cursor at zero, and nothing of the old
////   feed reaches it.
////
//// Every randomized test runs on a fixed, named seed.

import client/remote/feed_cursor
import client/remote_feed
import client/remote_top
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import qcheck
import statem

/// The seed of the campaign over mixed replies.
const campaign_seed = 1084

/// The seed of the campaign weighted toward a link that loses polls, so the
/// pause reaches its longest.
const lossy_seed = 1085

const runs = 200

const longest = 60

fn config(seed: Int) -> statem.Config {
  statem.default_config(seed:)
  |> statem.with_test_count(runs)
  |> statem.with_max_commands(longest)
}

/// The integers from `start` to `stop`, inclusive.
fn numbers(start: Int, stop: Int) -> List(Int) {
  case start > stop {
    True -> []
    False -> [start, ..numbers(start + 1, stop)]
  }
}

// --- commands ----------------------------------------------------------------

/// Which poll a reply is addressed to.
type Target {
  /// The poll most recently asked.
  Newest

  /// The poll asked before it, whether or not that one was answered.
  Older

  /// The newest poll of an earlier feed, whose reply was still in flight when a
  /// fresh attach began this one.
  OldFeed
}

/// What the reply says.
type Shape {
  /// The frames after the poll's `after`, numbered from `after + 1`.
  Honest

  /// The same, but numbered from one less than `after`, repeating a frame the
  /// laptop holds.
  Overlap

  /// No frames, numbered from `after + 1`.
  Empty

  /// A frame numbered `after + 2`, skipping one.
  Gap

  /// An ending, with no frames.
  Ended(FeedEnd)

  /// An ending carried with the frames the box had.
  EndedWithFrames(FeedEnd)

  /// A refusal that is an ending.
  RefusedEnded(FeedEnd)

  /// A refusal that says the feed did not answer in time.
  NotYet

  /// A refusal that is neither.
  Unwelcome

  /// Nothing was heard.
  Quiet

  /// The box was replaced.
  Replaced

  /// The answer did not read.
  Garbled
}

/// How a campaign weights the replies a box can give.
type Weight {
  Mixed
  Lossy
}

type FeedEnd {
  Lapsed
  Stopped
  Revoked
}

type Command {
  Write(count: Int)
  Ask
  Reply(target: Target, shape: Shape)
  Attach
}

fn command(lossy: Weight) -> qcheck.Generator(Command) {
  qcheck.from_weighted_generators(#(25, qcheck.map(count(), Write)), [
    #(25, qcheck.constant(Ask)),
    #(
      45,
      qcheck.map2(target(), shape(lossy), fn(target, shape) {
        Reply(target:, shape:)
      }),
    ),
    #(5, qcheck.constant(Attach)),
  ])
}

fn count() -> qcheck.Generator(Int) {
  qcheck.bounded_int(1, 4)
}

fn target() -> qcheck.Generator(Target) {
  qcheck.from_weighted_generators(#(80, qcheck.constant(Newest)), [
    #(15, qcheck.constant(Older)),
    #(5, qcheck.constant(OldFeed)),
  ])
}

fn ending() -> qcheck.Generator(FeedEnd) {
  qcheck.from_weighted_generators(#(40, qcheck.constant(Lapsed)), [
    #(30, qcheck.constant(Stopped)),
    #(30, qcheck.constant(Revoked)),
  ])
}

/// The weights of a reply's shape. The lossy campaign loses most polls and
/// rarely ends the feed, so the pause grows.
fn shape(lossy: Weight) -> qcheck.Generator(Shape) {
  let quiet = case lossy {
    Lossy -> 60
    Mixed -> 8
  }
  let ends = case lossy {
    Lossy -> 1
    Mixed -> 4
  }
  qcheck.from_weighted_generators(#(35, qcheck.constant(Honest)), [
    #(8, qcheck.constant(Overlap)),
    #(8, qcheck.constant(Empty)),
    #(4, qcheck.constant(Gap)),
    #(ends, qcheck.map(ending(), Ended)),
    #(ends, qcheck.map(ending(), EndedWithFrames)),
    #(ends, qcheck.map(ending(), RefusedEnded)),
    #(6, qcheck.constant(NotYet)),
    #(2, qcheck.constant(Unwelcome)),
    #(quiet, qcheck.constant(Quiet)),
    #(2, qcheck.constant(Replaced)),
    #(2, qcheck.constant(Garbled)),
  ])
}

fn describe(command: Command) -> String {
  string.inspect(command)
}

// --- the oracle ---------------------------------------------------------------

/// The rules as plain data beside the cursor, for one feed.
type Oracle {
  Oracle(
    /// The frames the box wrote, in order.
    written: List(String),
    /// The frames handed to the page, in order.
    delivered: List(String),
    /// The polls asked, newest first, each with the `after` it carried.
    asked: List(#(Int, Int)),
    /// The poll whose reply is awaited.
    waiting: Option(Int),
    /// How many polls in a row went unanswered.
    silent: Int,
    /// Whether the feed is over.
    over: Over,
    /// Which feed this is, so that a frame names its feed.
    generation: Int,
  )
}

type Over {
  Live
  Done
}

type Sut {
  Sut(
    cursor: feed_cursor.Cursor,
    oracle: Oracle,
    /// The polls of the feeds before this one, whose replies may still be in
    /// flight when a fresh attach starts a new feed.
    old_polls: List(Int),
  )
}

fn fresh(generation: Int) -> Sut {
  Sut(
    cursor: feed_cursor.new(generation * 1000 + 1),
    old_polls: [],
    oracle: Oracle(
      written: [],
      delivered: [],
      asked: [],
      waiting: None,
      silent: 0,
      over: Live,
      generation:,
    ),
  )
}

fn violation(tag: String, detail: String) -> statem.Violation {
  statem.Violation(tag:, detail:)
}

fn frame(oracle: Oracle, number: Int) -> String {
  "g" <> int.to_string(oracle.generation) <> "-" <> int.to_string(number)
}

// --- running a command --------------------------------------------------------

fn execute(sut: Sut, command: Command) -> Result(Sut, statem.Violation) {
  use stepped <- result.try(case command {
    Write(count:) -> Ok(written(sut, count))
    Ask -> Ok(asked(sut))
    Reply(target:, shape:) -> replied(sut, target, shape)
    Attach -> attached(sut)
  })
  use Nil <- result.try(agrees(stepped))
  Ok(stepped)
}

fn written(sut: Sut, count: Int) -> Sut {
  let oracle = sut.oracle
  let have = list.length(oracle.written)
  let more = numbers(have + 1, have + count) |> list.map(frame(oracle, _))
  Sut(
    ..sut,
    oracle: Oracle(..oracle, written: list.append(oracle.written, more)),
  )
}

fn asked(sut: Sut) -> Sut {
  let #(cursor, order) = feed_cursor.ask(sut.cursor)
  let oracle = sut.oracle

  // A cursor that finished still numbers polls, but its replies are strays.
  Sut(
    ..sut,
    cursor:,
    oracle: Oracle(
      ..oracle,
      asked: [#(order.poll, order.after), ..oracle.asked],
      waiting: Some(order.poll),
    ),
  )
}

/// The poll a reply is addressed to, and the `after` that poll carried.
fn addressed(sut: Sut, target: Target) -> Option(#(Int, Int)) {
  case target, sut.oracle.asked, list.last(sut.old_polls) {
    Newest, [newest, ..], _ -> Some(newest)
    Older, [_, older, ..], _ -> Some(older)
    OldFeed, _, Ok(poll) -> Some(#(poll, 0))
    Newest, [], _ | Older, _, _ | OldFeed, _, Error(Nil) -> None
  }
}

fn replied(
  sut: Sut,
  target: Target,
  shape: Shape,
) -> Result(Sut, statem.Violation) {
  case addressed(sut, target) {
    // No such poll was asked: a reply to poll 999 is a stray.
    None -> stray(sut, 999, reply_for(sut.oracle, 0, shape))
    Some(#(poll, after)) -> {
      let reply = reply_for(sut.oracle, after, shape)
      case sut.oracle.over, sut.oracle.waiting == Some(poll) {
        Live, True -> live(sut, poll, after, shape, reply)
        Live, False | Done, _ -> stray(sut, poll, reply)
      }
    }
  }
}

/// A reply to anything but the poll in flight changes nothing.
fn stray(
  sut: Sut,
  poll: Int,
  reply: feed_cursor.Reply,
) -> Result(Sut, statem.Violation) {
  let #(cursor, step) = feed_cursor.heard(sut.cursor, poll, reply)
  case
    step == feed_cursor.Stray
    && feed_cursor.after(cursor) == feed_cursor.after(sut.cursor)
  {
    True -> Ok(Sut(..sut, cursor:))
    False ->
      Error(violation(
        "stray",
        "a reply to poll "
          <> int.to_string(poll)
          <> " was read as "
          <> string.inspect(step),
      ))
  }
}

/// A reply to the poll in flight. The oracle says which step the rules give.
fn live(
  sut: Sut,
  poll: Int,
  after: Int,
  shape: Shape,
  reply: feed_cursor.Reply,
) -> Result(Sut, statem.Violation) {
  let oracle = sut.oracle
  let #(cursor, step) = feed_cursor.heard(sut.cursor, poll, reply)
  let expected = expectation(oracle, after, shape)
  use Nil <- result.try(case step == expected.step {
    True -> Ok(Nil)
    False ->
      Error(violation(
        expected.tag,
        "the cursor read "
          <> string.inspect(shape)
          <> " as "
          <> string.inspect(step)
          <> ", the oracle expected "
          <> string.inspect(expected.step),
      ))
  })
  let handed = case step {
    feed_cursor.Deliver(frames:) -> frames
    feed_cursor.Stray
    | feed_cursor.Retry(_)
    | feed_cursor.Over(_)
    | feed_cursor.Broken(_) -> []
  }
  Ok(
    Sut(
      ..sut,
      cursor:,
      oracle: Oracle(
        ..oracle,
        delivered: list.append(oracle.delivered, handed),
        waiting: None,
        silent: expected.silent,
        over: expected.over,
      ),
    ),
  )
}

/// What the rules say a live reply does.
type Expected {
  Expected(tag: String, step: feed_cursor.Step, silent: Int, over: Over)
}

fn expectation(oracle: Oracle, after: Int, shape: Shape) -> Expected {
  let beyond = list.drop(oracle.written, after)
  let keep = Expected("answer", feed_cursor.Deliver(beyond), 0, Live)
  case shape {
    Honest | Overlap -> keep
    Empty -> Expected(..keep, step: feed_cursor.Deliver([]))
    Gap ->
      Expected(
        "ended",
        feed_cursor.Broken(feed_cursor.Skipped(
          expected: after + 1,
          found: after + 2,
        )),
        0,
        Done,
      )
    Ended(why) | EndedWithFrames(why) | RefusedEnded(why) ->
      Expected("ended", feed_cursor.Over(top(why)), 0, Done)
    NotYet | Quiet ->
      Expected(
        "pause",
        feed_cursor.Retry(pause_ms: pause(oracle.silent)),
        oracle.silent + 1,
        Live,
      )
    Unwelcome ->
      Expected(
        "ended",
        feed_cursor.Broken(
          feed_cursor.Unwelcome(remote_top.InvalidArgument("no")),
        ),
        0,
        Done,
      )
    Replaced ->
      Expected("ended", feed_cursor.Broken(feed_cursor.Changed), 0, Done)
    Garbled ->
      Expected("ended", feed_cursor.Broken(feed_cursor.Unreadable), 0, Done)
  }
}

/// The pause the proposal gives: 250 ms, doubling, to two seconds.
fn pause(silent: Int) -> Int {
  case silent {
    0 -> 250
    1 -> 500
    2 -> 1000
    _ -> 2000
  }
}

fn top(why: FeedEnd) -> remote_top.FeedEnd {
  case why {
    Lapsed -> remote_top.FeedLapsed
    Stopped -> remote_top.FeedStopped
    Revoked -> remote_top.FeedRevoked
  }
}

/// The reply a shape stands for, given the poll's `after` and what the box wrote.
fn reply_for(oracle: Oracle, after: Int, shape: Shape) -> feed_cursor.Reply {
  let beyond = list.drop(oracle.written, after)
  case shape {
    Honest -> answer(after + 1, beyond, None)
    Overlap -> {
      let from = int.max(1, after - 1)
      answer(from, list.drop(oracle.written, from - 1), None)
    }
    Empty -> answer(after + 1, [], None)
    Gap -> answer(after + 2, [frame(oracle, after + 2)], None)
    Ended(why) -> answer(after + 1, [], Some(top(why)))
    EndedWithFrames(why) -> answer(after + 1, beyond, Some(top(why)))
    RefusedEnded(why) -> feed_cursor.Refused(remote_top.FeedEnded(top(why)))
    NotYet -> feed_cursor.Refused(remote_top.NotYetOpen("slow"))
    Unwelcome -> feed_cursor.Refused(remote_top.InvalidArgument("no"))
    Quiet -> feed_cursor.Silent
    Replaced -> feed_cursor.Replaced
    Garbled -> feed_cursor.Garbled
  }
}

fn answer(
  first: Int,
  frames: List(String),
  ended: Option(remote_top.FeedEnd),
) -> feed_cursor.Reply {
  feed_cursor.Answered(remote_feed.Answer(first:, frames:, ended:))
}

/// A fresh attach: a new cursor at zero over a feed that has written nothing.
/// Nothing of the old feed is carried over, which is the redraw.
fn attached(sut: Sut) -> Result(Sut, statem.Violation) {
  let next =
    Sut(
      ..fresh(sut.oracle.generation + 1),
      old_polls: list.append(
        sut.old_polls,
        list.map(sut.oracle.asked, fn(asked) { asked.0 }),
      ),
    )
  case feed_cursor.after(next.cursor) == 0 {
    True -> Ok(next)
    False -> Error(violation("redraw", "a fresh cursor did not start at zero"))
  }
}

// --- the checks after every command -------------------------------------------

fn agrees(sut: Sut) -> Result(Nil, statem.Violation) {
  let oracle = sut.oracle
  let held = list.length(oracle.delivered)
  use Nil <- result.try(
    case list.take(oracle.written, held) == oracle.delivered {
      True -> Ok(Nil)
      False ->
        Error(violation(
          "prefix",
          "the page holds "
            <> string.inspect(oracle.delivered)
            <> " of "
            <> string.inspect(oracle.written),
        ))
    },
  )
  case feed_cursor.after(sut.cursor) == held {
    True -> Ok(Nil)
    False ->
      Error(violation(
        "monotone",
        "after is "
          <> int.to_string(feed_cursor.after(sut.cursor))
          <> " with "
          <> int.to_string(held)
          <> " frames handed on",
      ))
  }
}

// --- the properties -----------------------------------------------------------

fn spec(lossy: Weight) -> statem.Spec(Nil, Command, Sut) {
  statem.Spec(
    initial: Nil,
    command: fn(_) { command(lossy) },
    precondition: fn(_, _) { statem.Admit },
    next_model: fn(_, _) { Nil },
    new_sut: fn() { fresh(0) },
    execute: fn(sut, _, command) { execute(sut, command) },
    finish: fn(_, _) { Ok(Nil) },
    teardown: fn(_) { Nil },
  )
}

fn checked(seed: Int, lossy: Weight) -> Nil {
  case statem.check(spec(lossy), config(seed)) {
    Ok(Nil) -> Nil

    // EUnit clips a long panic message, so the whole report also goes to
    // standard error, which EUnit does not capture.
    Error(failure) -> {
      let report = statem.report(failure, describe)
      io.println_error(report)
      panic as report
    }
  }
}

pub fn the_cursor_keeps_its_rules_under_mixed_replies_test() {
  checked(campaign_seed, Mixed)
}

pub fn the_cursor_keeps_its_rules_when_the_link_loses_polls_test() {
  checked(lossy_seed, Lossy)
}

// --- the cases the rules talk about ---------------------------------------------

pub fn the_commands_reach_the_cases_the_rules_name_test() {
  let shapes =
    numbers(0, runs - 1)
    |> list.flat_map(fn(run) {
      statem.commands(spec(Mixed), config(campaign_seed), run)
    })
  let wanted = [
    fn(c) { c == Attach },
    fn(c) { c == Reply(Newest, Gap) },
    fn(c) { c == Reply(Newest, Overlap) },
    fn(c) { c == Reply(Older, Honest) },
    fn(c) { c == Reply(OldFeed, Honest) },
    fn(c) { c == Reply(Newest, Quiet) },
    fn(c) { c == Reply(Newest, Garbled) },
  ]
  let missing = list.filter(wanted, fn(seen) { !list.any(shapes, seen) })
  assert missing == []
}

// --- direct cases ---------------------------------------------------------------

fn answered(first: Int, frames: List(String)) -> feed_cursor.Reply {
  answer(first, frames, None)
}

pub fn a_gap_hands_on_nothing_and_ends_the_feed_test() {
  let #(cursor, order) = feed_cursor.ask(feed_cursor.new(1))
  let #(cursor, step) =
    feed_cursor.heard(cursor, order.poll, answered(3, ["c", "d"]))
  assert step == feed_cursor.Broken(feed_cursor.Skipped(expected: 1, found: 3))
  assert feed_cursor.after(cursor) == 0
  let #(cursor, order) = feed_cursor.ask(cursor)
  let #(_, later) = feed_cursor.heard(cursor, order.poll, answered(1, ["a"]))
  assert later == feed_cursor.Stray
}

pub fn an_answer_that_reports_an_ending_hands_on_no_frame_test() {
  let #(cursor, order) = feed_cursor.ask(feed_cursor.new(1))
  let reply = answer(1, ["a", "b"], Some(remote_top.FeedStopped))
  let #(cursor, step) = feed_cursor.heard(cursor, order.poll, reply)
  assert step == feed_cursor.Over(remote_top.FeedStopped)
  assert feed_cursor.after(cursor) == 0
}

pub fn the_pause_doubles_to_two_seconds_and_a_heard_box_resets_it_test() {
  let first = feed_cursor.new(1)
  let #(c1, o1) = feed_cursor.ask(first)
  let #(c1, s1) = feed_cursor.heard(c1, o1.poll, feed_cursor.Silent)
  let #(c2, o2) = feed_cursor.ask(c1)
  let #(c2, s2) = feed_cursor.heard(c2, o2.poll, feed_cursor.Silent)
  assert [s1, s2] == [feed_cursor.Retry(250), feed_cursor.Retry(500)]
  assert feed_cursor.silent_for(c2) == 2

  let #(c3, o3) = feed_cursor.ask(c2)
  let #(c3, _) = feed_cursor.heard(c3, o3.poll, answered(1, []))
  assert feed_cursor.silent_for(c3) == 0
  assert feed_cursor.pause_ms(40) == 2000
}

pub fn a_poll_asked_again_forgets_the_one_it_replaces_test() {
  let #(cursor, old) = feed_cursor.ask(feed_cursor.new(1))
  let #(cursor, new) = feed_cursor.ask(cursor)
  assert new.poll != old.poll
  let #(cursor, late) = feed_cursor.heard(cursor, old.poll, answered(1, ["a"]))
  assert late == feed_cursor.Stray
  let #(_, step) = feed_cursor.heard(cursor, new.poll, answered(1, ["a"]))
  assert step == feed_cursor.Deliver(["a"])
}
