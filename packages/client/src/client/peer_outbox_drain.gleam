//// The outbox drainer: one machine per resident session that keeps
//// attempting what the session owes another party.
////
//// `peers.send` writes an outbox row before it asks the recipient. When the
//// recipient's owner is unreachable, or answers that the recipient is saved
//// and not open, the row stays pending and the send returns `queued`; this
//// machine is what delivers it later. It lives in the
//// session's restartable service tier, so a crash costs the pass in flight
//// and nothing else: every pass recomputes what is owed from the session's
//// own store, and a session that is opened again starts with a pass.
////
//// ## What a machine drains
////
//// The machine owns the timing and nothing else. What is owed, and how to
//// attempt it, is one function, the `pass` in its `Options`, which answers
//// whether anything is still owed. `options` makes the instance that drains peer
//// mail (`client/peer_outbox`), and `over` makes one over any other pass. The
//// session runs a second instance over the records of its subagents on other
//// orchestrators (`client/remote_drain`), which are not peer-mail rows and so
//// cannot go through `peers.resend` or be refused after an hour, but which owe
//// the same thing: a durable record written before the first attempt, retried
//// at a fixed interval until the other side answers.
////
//// ## Flow
////
//// `start` → `builder` → `entered` → `handle` → `after_pass` → `peer_pass` → `drain_rows`
////
//// 1. `start` (or `supervised`) builds the machine with `builder`, wired to
////    the session's own timer source, and `entered` arms the pass that runs
////    at session open.
//// 2. `handle` runs the instance's pass on each `Tick`, and wakes an idle
////    machine on `Queued`, which `poke` sends after a row is left pending.
//// 3. `after_pass` leaves the machine armed for another pass while anything is
////    still owed, and idle with no timer when nothing is.
//// 4. `peer_pass` is the peer-mail instance's pass. It asks the sender's Agency
////    for the rows that are due, which also refuses the rows that have waited
////    an hour, and hands each to `drain_rows`.
//// 5. `drain_rows` attempts each row through `peers.resend`, which resolves
////    the recipient through the same `Directory.resolve` seam `peers.send`
////    uses and records the outcome. A session that did not answer is not asked
////    again in the same pass.
////
//// ## One named timeout, and no timer when there is nothing owed
////
//// The machine's whole liveness is one named timeout, `drain_timer`. While any
//// owed row waits on an owner that did not answer, it is fixed at
//// `retry_interval_ms`: a recipient that is down for an hour costs 720
//// attempts, each a single bounded call, and a fixed interval means the moment
//// the owner returns is the next tick and not the end of a growing delay.
//// When every owed row instead waits for its recipient to be opened, the
//// owner is up and answering, and only the owner's decision to open the
//// session ends the wait. Nothing the sender does hastens it, so each such pass
//// doubles the interval, up to `max_retry_interval_ms`, and a message waiting
//// an hour costs about seventeen attempts. The interval returns to
//// `retry_interval_ms` as soon as a pass finds an owner that did not answer,
//// and when the machine goes idle. When a pass finds nothing owed the timeout
//// is cancelled and the machine is `Idle`, so a session that never queues a
//// message never has a timer. `Queued` is the only thing that wakes it, and
//// the row it announces is already durable when the message is sent.
////
//// A message queued while the interval is long is attempted at the next tick,
//// which is at most `max_retry_interval_ms` away. The doorbell cannot say
//// which row it announces: the machine's own attempts ring it too, and a
//// doorbell that reset the interval would undo the backoff on every pass.
////
//// The timeout is armed on the session's own timer source
//// (`runtime/effects.Timers`), the seam `client/schedulescan` uses, so a
//// simulated session steps the drainer on logical time and a test drives it
//// with a fake wheel. That source cannot cancel an arming, so a superseded
//// wake still rings and is dropped by the timer book's generation check.
////
//// ## Exactly once, and what a lost message looks like
////
//// The machine adds no protocol. A message is delivered when the recipient's
//// `peer_mail.deliver` commits it with its receipt. If the reply is lost the
//// row stays pending, the next pass asks again, and the recipient answers the
//// repeat with the receipt it stored (`same_receipt`), so the message is in
//// the recipient exactly once. The pending row, not this machine, is what
//// makes a restart safe: it carries the text and the target.
////
//// <!-- transitions: peer_outbox_drain.Phase -->
////
//// | state | Tick | Queued |
//// | --- | --- | --- |
//// | `Idle` | a pass; `Waiting` if a row is still owed, else unchanged | `Waiting`, armed for one interval |
//// | `Waiting` | a pass; armed again if a row is still owed (after `retry_interval_ms`, or after twice the last interval if every owed row waits for an open), else `Idle` with the timeout cancelled | ignored, the timeout is already armed |

import client/peer_mail
import client/peer_outbox
import client/peers
import core/json
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/supervision.{type ChildSpecification}
import telemetry/field
import telemetry/log.{type Logger}
import weft/actor
import weft/registry as address
import weft/state_machine as sm
import weft/timer

/// How long the machine waits between passes while any row waits on an owner
/// that did not answer, in milliseconds, and before the first pass after a
/// message is queued. It is fixed on purpose: see the module doc.
pub const retry_interval_ms = 5000

/// The longest the machine waits between passes while every owed row waits for
/// its recipient to be opened, in milliseconds. The interval doubles from
/// `retry_interval_ms` to this: 5, 10, 20, 40, 80, 160 and then 300 seconds.
pub const max_retry_interval_ms = 300_000

/// The one name every arming of this machine's timer uses. Arming a name
/// replaces whatever was armed under it, so a pass's re-arm supersedes the
/// arming that woke it and there is never more than one live chain.
const drain_timer = "peer-outbox-drain"

// The first pass runs as soon as the machine has started. It is an arming
// rather than a message so that a simulated session can hold the first pass
// still and step through it, as `schedulescan` does.
const first_pass_delay_ms = 0

/// What the drainer works with.
pub type Options {
  Options(
    /// Finds what is owed and attempts it, once, and says whether anything is
    /// still owed afterwards. It runs in the machine's own process on each
    /// tick, so it may block for as long as its attempts take, and it must not
    /// crash on a store that cannot be read: such a pass answers `Owed(Quick)`.
    pass: fn() -> Backlog,
    /// The session's timer source (`runtime/effects.Timers.after`), or a
    /// test's fake wheel.
    after: fn(Int, fn() -> Nil) -> Nil,
  )
}

/// The drainer's mailbox.
pub type Message {
  /// The machine's named timeout ringing: a pass is due.
  Tick

  /// `peers.send` left a row pending. An idle machine arms its timer; a
  /// waiting one already has.
  Queued
}

/// Whether a timer is armed.
type Phase {
  /// Nothing is owed and no timer is armed.
  Idle

  /// A row may be owed and the timeout is armed.
  Waiting
}

// What the machine carries between events. The pass is fixed for the life of
// the process; what is owed is read from the store at each pass. The interval
// is the delay of the arming in force, which the next arming doubles while the
// owed rows wait for an open.
type State {
  State(options: Options, interval_ms: Int)
}

/// What a pass found.
pub type Backlog {
  /// At least one record is still pending, or the records could not be read.
  Owed(Pace)

  /// Nothing is pending.
  Clear
}

/// How soon the next pass should be.
pub type Pace {
  /// An owner did not answer, or the records could not be read, and either may
  /// be over by the next pass.
  Quick

  /// Every owed record waits for its recipient to be opened.
  Slow
}

/// Options for the instance that drains peer mail, over a sender's wiring and a
/// timer source, with a silent logger.
///
/// ## Examples
///
/// ```gleam
/// // peer_outbox_drain.options(wiring, runtime.effects.timers.after)
/// ```
pub fn options(
  wiring: peers.Wiring,
  after: fn(Int, fn() -> Nil) -> Nil,
) -> Options {
  Options(pass: peer_pass(wiring, log.discard()), after:)
}

/// Options for an instance that drains something other than peer mail, over the
/// pass that finds and attempts it.
///
/// ## Examples
///
/// ```gleam
/// // peer_outbox_drain.over(remote_drain.pass(runtime_supplier, reach, clock, logger), after)
/// ```
pub fn over(
  pass: fn() -> Backlog,
  after: fn(Int, fn() -> Nil) -> Nil,
) -> Options {
  Options(pass:, after:)
}

/// The peer-mail pass: attempts each row that is due and reports deliveries and
/// failed reads on `logger`.
///
/// ## Examples
///
/// ```gleam
/// // peer_outbox_drain.Options(pass: peer_outbox_drain.peer_pass(wiring, logger), after:)
/// ```
pub fn peer_pass(wiring: peers.Wiring, logger: Logger) -> fn() -> Backlog {
  fn() { due_pass(wiring, logger) }
}

/// Starts the drainer under `name`. Its first pass is armed at once.
///
/// ## Examples
///
/// ```gleam
/// // peer_outbox_drain.start(options, name)
/// ```
pub fn start(
  options: Options,
  name: address.Address(Message),
) -> actor.StartResult(Subject(Message)) {
  builder(options, name) |> sm.start
}

/// The drainer as a supervision child, in the session's restartable service
/// tier. A restart begins with the pass `entered` arms, which re-derives what
/// is owed from the store.
///
/// ## Examples
///
/// ```gleam
/// // sup.add(builder, peer_outbox_drain.supervised(options, name))
/// ```
pub fn supervised(
  options: Options,
  name: address.Address(Message),
) -> ChildSpecification(Subject(Message)) {
  sm.supervised(builder(options, name))
}

/// Tells the drainer that a row was left pending, so an idle drainer arms its
/// timer. A message sent while the drainer is restarting is lost, which costs
/// nothing: the restart begins with a pass.
///
/// ## Examples
///
/// ```gleam
/// // peer_outbox_drain.poke(name)
/// ```
pub fn poke(name: address.Address(Message)) -> Nil {
  let _sent = address.send(name, Queued)
  Nil
}

/// Asks the drainer for a pass now, where `poke` arms one a retry interval away.
///
/// `poke` is for a message that was just attempted inline and failed, so the
/// first retry is one interval off. A drainer whose first attempt is its pass,
/// such as the delegate session's, has made no inline attempt, and waiting the
/// interval would delay a message for nothing. A `Tick` runs a pass in either
/// phase and the pass arms the next, so ringing a waiting drainer costs one
/// extra pass.
///
/// ## Examples
///
/// ```gleam
/// // peer_outbox_drain.ring(name)
/// ```
pub fn ring(name: address.Address(Message)) -> Nil {
  let _sent = address.send(name, Tick)
  Nil
}

// The machine `start` and `supervised` both describe. It begins `Waiting`, so
// that `entered`'s first call arms the pass that runs at session open.
/// Creates the outbox drain state from its configured dependencies.
fn builder(
  options: Options,
  name: address.Address(Message),
) -> sm.Builder(Phase, State, Message, Subject(Message)) {
  sm.new_with_initialiser(5000, fn(subject) {
    sm.initialised(Waiting, State(options:, interval_ms: retry_interval_ms))
    |> sm.returning(subject)
    |> Ok
  })
  |> sm.with_timer_source(timer.Injected(after: options.after))
  |> sm.addressed(name)
  |> sm.on_enter(entered)
  |> sm.on_event(handle)
}

// Arms or cancels the timeout on each way into a phase. The first call has
// both phases equal, which no later transition does, and that is the pass at
// session open.
/// Starts a drain pass and records the next due time.
fn entered(
  from: Phase,
  to: Phase,
  data: State,
) -> sm.Enter(Phase, State, Message) {
  case from, to {
    Waiting, Waiting ->
      sm.keep(data)
      |> sm.with_named_timeout(
        name: drain_timer,
        after: first_pass_delay_ms,
        sending: Tick,
      )

    // A message was queued while nothing was owed: the first retry is one
    // interval away, because the inline attempt has just failed.
    Idle, Waiting ->
      sm.keep(data)
      |> sm.with_named_timeout(
        name: drain_timer,
        after: retry_interval_ms,
        sending: Tick,
      )

    // Nothing is owed, so no wake is wanted. Cancelling also drops a wake that
    // is already in flight.
    Waiting, Idle -> sm.keep(data) |> sm.cancel_timeout(name: drain_timer)

    Idle, Idle -> sm.keep(data)
  }
}

// A `Tick` runs a pass in either phase, so a wake that arrives after the
// machine has gone idle still delivers whatever is owed. A `Queued` message
// only matters to an idle machine.
/// Applies one drain control message to the running outbox owner.
fn handle(
  phase: Phase,
  data: State,
  message: Message,
) -> sm.Next(Phase, State, Message) {
  case phase, message {
    Idle, Queued -> sm.transition(to: Waiting, data:)
    Waiting, Queued -> sm.keep(data)
    Idle, Tick | Waiting, Tick -> after_pass(phase, data, data.options.pass())
  }
}

// Decides the next arming from what the pass found. A pass that leaves a row
// owed re-arms the same name, which supersedes the arming that woke it, after
// the interval the pace calls for; a pass that leaves none moves to `Idle`, and
// `entered` cancels the timeout. Both ways into `Idle` and `Waiting` start from
// the fixed interval, because `entered` arms it.
/// Updates drain scheduling after a delivery pass completes.
fn after_pass(
  phase: Phase,
  data: State,
  backlog: Backlog,
) -> sm.Next(Phase, State, Message) {
  let fresh = State(..data, interval_ms: retry_interval_ms)

  // The pass outcome determines whether the drain retries or schedules another check.
  case phase, backlog {
    Waiting, Owed(Quick) -> rearmed(fresh)
    Waiting, Owed(Slow) ->
      rearmed(
        State(
          ..data,
          interval_ms: int.min(max_retry_interval_ms, data.interval_ms * 2),
        ),
      )
    Waiting, Clear -> sm.transition(to: Idle, data: fresh)
    Idle, Owed(_) -> sm.transition(to: Waiting, data: fresh)
    Idle, Clear -> sm.keep(data)
  }
}

// Arms the one timeout for the interval the state holds.
/// Rearms the outbox timer after a scheduled retry.
fn rearmed(data: State) -> sm.Next(Phase, State, Message) {
  sm.keep(data)
  |> sm.with_named_timeout(
    name: drain_timer,
    after: data.interval_ms,
    sending: Tick,
  )
}

// One pass over the rows that are due. The sender's Agency answers them, and
// refuses any that have waited past the hour before it does, so expiry needs
// no timer of its own. A read that fails is `Owed(Quick)`: the rows may exist,
// and the next pass reads again.
/// Starts a pass for rows whose retry time has arrived.
fn due_pass(wiring: peers.Wiring, logger: Logger) -> Backlog {
  // The due-row state determines which outbox entries can be attempted now.
  case wiring.own.call(peer_mail.OutboxDue) {
    Ok(json.Array(items)) ->
      drain_rows(
        wiring,
        logger,
        list.filter_map(items, peer_outbox.decode),
        [],
        [],
      )
      |> backlog_of
    Ok(_) -> {
      log.warn(logger, "peer_outbox.unreadable", [
        field.text("reason", "the due rows were not a list"),
      ])
      Owed(Quick)
    }
    Error(failure) -> {
      log.warn(logger, "peer_outbox.unreadable", [
        field.text("reason", peer_mail.reason(failure)),
      ])
      Owed(Quick)
    }
  }
}

// Attempts the rows in order and answers what each attempt found. `waiting`
// holds the sessions that did not answer during this pass, and the ones whose
// owner answered that they are saved. The owner of a silent session is the
// owner of all its rows, so asking again would spend a full deadline per row to
// learn the same thing, and a pass over 64 rows to a dead node would last
// minutes. A saved session answers at once, but every row to it would get the
// same answer, and the pass runs at the fixed interval while another owner is
// silent, so asking for each of 64 rows would make 64 round trips every five
// seconds. If the owner opens the session between two rows, the skipped ones
// wait for the next pass. The row that was asked has said what the pass found,
// so a skipped row adds nothing to it.
/// Claims due rows and delivers each through the authorized peer route.
fn drain_rows(
  wiring: peers.Wiring,
  logger: Logger,
  rows: List(peer_outbox.Row),
  waiting: List(String),
  found: List(peer_outbox.Outcome),
) -> List(peer_outbox.Outcome) {
  case rows {
    [] -> found

    [row, ..rest] ->
      case list.contains(waiting, row.session) {
        True -> drain_rows(wiring, logger, rest, waiting, found)
        False -> {
          let outcome = peers.resend(wiring, row)
          report(logger, row, outcome)

          // The claimed rows determine which delivery attempts are run in this pass.
          let waiting = case outcome {
            peer_outbox.Unanswered | peer_outbox.NotOpen -> [
              row.session,
              ..waiting
            ]
            peer_outbox.Receipt(..) | peer_outbox.Rejected(..) -> waiting
          }

          drain_rows(wiring, logger, rest, waiting, [outcome, ..found])
        }
      }
  }
}

// What the pass found decides how soon the next one is, whatever order the
// rows were attempted in. An owner that did not answer calls for the fixed
// interval, because it may be back by the next pass. Failing that, a recipient
// that is saved calls for the backed-off one, because only its owner's
// decision ends the wait. Nothing owed leaves nothing to wait for.
/// Projects the pending outbox backlog from the drain state.
fn backlog_of(found: List(peer_outbox.Outcome)) -> Backlog {
  case
    list.contains(found, peer_outbox.Unanswered),
    list.contains(found, peer_outbox.NotOpen)
  {
    True, _ -> Owed(Quick)
    False, True -> Owed(Slow)
    False, False -> Clear
  }
}

// The log line for an attempt that ended a row. A row that stays pending says
// nothing: it is attempted again.
/// Builds the public status report for the running drain.
fn report(
  logger: Logger,
  row: peer_outbox.Row,
  outcome: peer_outbox.Outcome,
) -> Nil {
  case outcome {
    peer_outbox.Receipt(..) ->
      log.info(logger, "peer_outbox.admitted", where(row))
    peer_outbox.Rejected(reason:) ->
      log.info(logger, "peer_outbox.refused", [
        field.text("reason", reason),
        ..where(row)
      ])
    peer_outbox.Unanswered | peer_outbox.NotOpen -> Nil
  }
}

/// Describes where the outbox drain is currently operating.
fn where(row: peer_outbox.Row) -> List(field.Field) {
  [
    field.text("session", row.session),
    field.text("strand", row.strand),
    field.text("message_id", row.message_id),
  ]
}
