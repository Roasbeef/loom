//// The laptop's place in a live session feed: which frame it holds last, which
//// poll it is waiting on, and what each thing the box can answer to a poll
//// means (protocol-change/108, "The laptop's socket adapter").
////
//// `client/daemon/ui_feed` is the process that sends polls and hands frames to
//// the page. This module is every decision that process makes about a poll, kept
//// apart from it as a pure value: it holds no process and reads no clock, so the
//// rules are tested under fixed-seed generated sequences of answers, losses,
//// supersedes and lapses (`feed_cursor_test`), and the P model
//// `protocol/models/live-relay` (`UiFeed.p`) checks the same rules against the
//// box's feed host. A rule that changes here changes there first.
////
//// ## The rules
////
//// - The cursor's `after` is the number of the last frame it handed to the page.
////   It starts at zero, moves only forward, and moves only past a frame handed
////   on, one frame at a time, so the page sees each frame once and in order.
//// - A poll asks for the frames after `after`. Each poll has a number of its own,
////   and only an answer to the poll in flight is read. An answer to any other
////   poll, a second copy of an answer, and an answer after the feed is over are
////   strays and change nothing, so a reply the link delayed can neither reorder
////   frames nor reach the page twice.
//// - An answer's frames are numbered from `first`. A frame numbered `after` or
////   less is dropped, which is how a box that repeats what the laptop already
////   holds is harmless. The first frame left must be numbered `after + 1`. A
////   frame numbered beyond that is a gap, which an honest box never produces,
////   because it drops a frame only after a poll acknowledged it: the feed is
////   broken and nothing of the answer is handed on.
//// - An answer that reports the feed ended hands on no frame, whatever it
////   carries. The page redraws from a fresh attach, which starts a new cursor,
////   rather than continuing from frames of a feed that is gone.
//// - A poll with no answer is asked again with the same `after`, after a pause
////   that starts at `first_pause_ms` and doubles to `longest_pause_ms` for each
////   poll in a row that went unanswered. A box heard from resets the pause.
////
//// ## Flow
////
//// `new` → `ask` → `heard` → `after` → `silent_for`
////
//// 1. `new` starts a cursor for a feed the laptop holds nothing of.
//// 2. `ask` numbers the next poll and says what to ask.
//// 3. `heard` reads the reply to a poll and says what to do about it.
//// 4. `after` and `silent_for` are what the page's status and the process's
////    timers read.

import client/remote_feed.{type Answer}
import client/remote_top.{type FeedEnd, type Refusal}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// The first pause before asking again after a poll went unanswered, in
/// milliseconds. It is shorter than `top_relay`'s resend pause because a poll
/// changes nothing on the box and the lease is fifteen seconds.
pub const first_pause_ms = 250

/// The longest pause between polls that go unanswered, in milliseconds.
pub const longest_pause_ms = 2000

/// A place in a feed. It is opaque so that every change goes through a rule of
/// this module.
pub opaque type Cursor {
  Cursor(
    /// The number of the last frame handed to the page, or zero.
    after: Int,
    /// The number the next poll takes.
    next_poll: Int,
    /// The poll whose answer is awaited, if any.
    waiting: Option(Int),
    /// How many polls in a row went unanswered.
    silent: Int,
    /// Whether the cursor still reads answers.
    run: Run,
  )
}

/// Whether a cursor reads answers.
type Run {
  /// The feed is live as far as the laptop knows.
  Running

  /// The feed ended or broke, and every later reply is a stray.
  Finished
}

/// What to ask the box.
pub type Order {
  Order(
    /// The poll's number, which its reply must carry back.
    poll: Int,
    /// The number of the last frame the laptop holds.
    after: Int,
  )
}

/// What the laptop heard in reply to a poll, already sorted by who said it: the
/// box answered, the box refused, or nothing usable came back.
pub type Reply {
  /// The box answered with a poll answer.
  Answered(
    /// The answer, decoded by `remote_feed.decode_answer`.
    answer: Answer,
  )

  /// The box refused the poll.
  Refused(
    /// The refusal.
    refusal: Refusal,
  )

  /// Nothing was heard: the link failed, the box was unreachable or did not
  /// answer in time. The poll changed nothing, so it is asked again.
  Silent

  /// The box is not the one that was attached: it restarted, no longer offers
  /// the revisions, or its feature answer did not read. The feed cannot go on.
  Replaced

  /// The box answered and the answer could not be read or was too large. None of
  /// it is used.
  Garbled
}

/// Why the box broke the exchange.
pub type Fault {
  /// An answer skipped a frame the laptop does not hold.
  Skipped(
    /// The number the next frame had to carry.
    expected: Int,
    /// The number the answer's first new frame carried.
    found: Int,
  )

  /// The box refused a poll for a reason that is not an ending.
  Unwelcome(
    /// The refusal.
    refusal: Refusal,
  )

  /// The box was replaced under the feed.
  Changed

  /// An answer did not read.
  Unreadable
}

/// What a reply means.
pub type Step {
  /// The reply was not for the poll in flight, or the feed is over. Nothing
  /// changed.
  Stray

  /// These frames go to the page, in order, and the next poll is asked at once.
  /// The list may be empty: a poll the box released with nothing to say.
  Deliver(
    /// The frames the laptop did not hold, numbered from the old `after` plus
    /// one.
    frames: List(String),
  )

  /// Nothing was heard. The same poll is asked again after the pause.
  Retry(
    /// How long to wait, in milliseconds.
    pause_ms: Int,
  )

  /// The feed is over for this reason, and none of the answer is handed on.
  Over(
    /// Why.
    why: FeedEnd,
  )

  /// The box broke the exchange and the feed is over.
  Broken(
    /// What it did.
    fault: Fault,
  )
}

/// A cursor for a feed the laptop holds nothing of, with no poll in flight. The
/// first poll takes the number `first_poll`, and each takes the next. The feed
/// client gives every feed its own range, so a reply that belongs to an earlier
/// feed never names a poll of a later one, whatever carried it.
///
/// ## Examples
///
/// ```gleam
/// assert feed_cursor.after(feed_cursor.new(1)) == 0
/// ```
pub fn new(first_poll: Int) -> Cursor {
  Cursor(
    after: 0,
    next_poll: first_poll,
    waiting: None,
    silent: 0,
    run: Running,
  )
}

/// The number of the last frame handed to the page.
///
/// ## Examples
///
/// ```gleam
/// assert feed_cursor.after(feed_cursor.new(1)) == 0
/// ```
pub fn after(cursor: Cursor) -> Int {
  cursor.after
}

/// How many polls in a row went unanswered. Zero means the box was heard from
/// last, so the link is up as far as the laptop knows.
///
/// ## Examples
///
/// ```gleam
/// assert feed_cursor.silent_for(feed_cursor.new(1)) == 0
/// ```
pub fn silent_for(cursor: Cursor) -> Int {
  cursor.silent
}

/// The poll whose reply is awaited, if any. A caller whose poll ended without a
/// reply, because the task that made the call was lost, reads it to say which
/// poll went unanswered.
///
/// ## Examples
///
/// ```gleam
/// assert feed_cursor.in_flight(feed_cursor.new(1)) == option.None
/// ```
pub fn in_flight(cursor: Cursor) -> Option(Int) {
  cursor.waiting
}

/// Numbers the next poll and says what to ask. A poll still in flight is
/// forgotten, so its reply, if it comes, is a stray: asking again is how a poll
/// that got no answer is repeated.
///
/// ## Examples
///
/// ```gleam
/// let #(_, order) = feed_cursor.ask(feed_cursor.new(1))
/// assert order == feed_cursor.Order(poll: 1, after: 0)
/// ```
pub fn ask(cursor: Cursor) -> #(Cursor, Order) {
  let order = Order(poll: cursor.next_poll, after: cursor.after)
  let asked =
    Cursor(..cursor, next_poll: cursor.next_poll + 1, waiting: Some(order.poll))
  #(asked, order)
}

/// Reads the reply to poll number `poll`. A reply to any poll but the one in
/// flight is a stray, whatever it says.
///
/// ## Examples
///
/// ```gleam
/// let #(cursor, order) = feed_cursor.ask(feed_cursor.new(1))
/// let #(_, step) = feed_cursor.heard(cursor, order.poll, feed_cursor.Silent)
/// assert step == feed_cursor.Retry(pause_ms: 250)
/// ```
pub fn heard(cursor: Cursor, poll: Int, reply: Reply) -> #(Cursor, Step) {
  case cursor.run, cursor.waiting == Some(poll) {
    Running, True -> read(Cursor(..cursor, waiting: None), reply)
    Running, False | Finished, _ -> #(cursor, Stray)
  }
}

/// Reads a reply to the poll in flight, which is no longer in flight.
fn read(cursor: Cursor, reply: Reply) -> #(Cursor, Step) {
  case reply {
    Answered(answer:) -> answered(Cursor(..cursor, silent: 0), answer)
    Silent -> unanswered(cursor)

    // A box that said it has no frame for the laptop yet is still the box, and
    // the poll is asked again.
    Refused(remote_top.NotYetOpen(_)) -> unanswered(cursor)
    Refused(remote_top.FeedEnded(why:)) -> finish(cursor, Over(why))
    Refused(refusal:) -> finish(cursor, Broken(Unwelcome(refusal)))
    Replaced -> finish(cursor, Broken(Changed))
    Garbled -> finish(cursor, Broken(Unreadable))
  }
}

/// Reads an answer. One that reports the feed ended hands on nothing, and
/// otherwise the frames the laptop does not hold are handed on if they begin
/// where its last one ended.
fn answered(cursor: Cursor, answer: Answer) -> #(Cursor, Step) {
  // An ending is final and carries no frame the page may use. A live answer is
  // read against what the laptop holds.
  case answer.ended {
    Some(why) -> finish(cursor, Over(why))
    None -> fresh_frames(cursor, answer)
  }
}

/// Reads the frames of a live answer. Frames numbered `after` or less are the ones
/// the laptop holds, and what is left begins at `max(first, after + 1)`.
fn fresh_frames(cursor: Cursor, answer: Answer) -> #(Cursor, Step) {
  let held = int.max(0, cursor.after + 1 - answer.first)
  let fresh = list.drop(answer.frames, held)
  let begins = int.max(answer.first, cursor.after + 1)

  // Nothing new is not an error, and new frames are handed on only if they begin
  // exactly where the last one ended. Any other beginning is a gap.
  case fresh, begins == cursor.after + 1 {
    [], _ -> #(cursor, Deliver([]))
    _, True -> #(
      Cursor(..cursor, after: cursor.after + list.length(fresh)),
      Deliver(fresh),
    )
    _, False ->
      finish(cursor, Broken(Skipped(expected: cursor.after + 1, found: begins)))
  }
}

/// A poll that went unanswered: ask again after a pause that grows with the polls
/// in a row that did.
fn unanswered(cursor: Cursor) -> #(Cursor, Step) {
  #(
    Cursor(..cursor, silent: cursor.silent + 1),
    Retry(pause_ms: pause_ms(cursor.silent)),
  )
}

/// The pause before asking again, given how many answers in a row did not come:
/// `first_pause_ms`, doubling for each one, up to `longest_pause_ms`.
///
/// ## Examples
///
/// ```gleam
/// assert feed_cursor.pause_ms(0) == 250
/// assert feed_cursor.pause_ms(3) == 2000
/// ```
pub fn pause_ms(silent: Int) -> Int {
  int.min(first_pause_ms * pow2(silent), longest_pause_ms)
}

/// Ends the cursor with the step that says why, so every later reply is a stray.
fn finish(cursor: Cursor, step: Step) -> #(Cursor, Step) {
  #(Cursor(..cursor, run: Finished), step)
}

/// Two to the power of `n`, for a pause that stops growing long before this
/// could be large: `n` is bounded at ten so the product is.
fn pow2(n: Int) -> Int {
  case n <= 0 {
    True -> 1
    False -> 2 * pow2(int.min(n, 10) - 1)
  }
}
