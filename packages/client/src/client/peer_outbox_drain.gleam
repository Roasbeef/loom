//// The outbox drainer: one machine per resident session that keeps
//// attempting the peer messages the session owes (`client/peer_outbox`).
////
//// `peers.send` writes an outbox row before it asks the recipient. When the
//// recipient's owner is unreachable, or answers that the recipient is saved
//// and not open, the row stays pending and the send returns `queued`; this
//// machine is what delivers it later. It lives in the
//// session's restartable service tier, so a crash costs the pass in flight
//// and nothing else: every pass recomputes what is owed from the session's
//// own store, and a session that is opened again starts with a pass.
////
//// ## Flow
////
//// `start` → `builder` → `entered` → `handle` → `pass` → `drain_rows` → `after_pass`
////
//// 1. `start` (or `supervised`) builds the machine with `builder`, wired to
////    the session's own timer source, and `entered` arms the pass that runs
////    at session open.
//// 2. `handle` runs a pass on each `Tick`, and wakes an idle machine on
////    `Queued`, which `poke` sends after `peers.send` leaves a row pending.
//// 3. `pass` asks the sender's Agency for the rows that are due, which also
////    refuses the rows that have waited an hour, and hands each to
////    `drain_rows`.
//// 4. `drain_rows` attempts each row through `peers.resend`, which resolves
////    the recipient through the same `Directory.resolve` seam `peers.send`
////    uses and records the outcome. A session that did not answer is not asked
////    again in the same pass.
//// 5. `after_pass` leaves the machine armed for another pass while any row is
////    still owed, and idle with no timer when none is.
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
    /// The sender's endpoint and peer directory. The drainer reads the due
    /// rows through `own` and resolves each recipient through `directory`,
    /// exactly as `peers.send` does.
    wiring: peers.Wiring,
    /// The session's timer source (`runtime/effects.Timers.after`), or a
    /// test's fake wheel.
    after: fn(Int, fn() -> Nil) -> Nil,
    logger: Logger,
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

// What the machine carries between events. The wiring is fixed for the life of
// the process; what is owed is read from the store at each pass. The interval
// is the delay of the arming in force, which the next arming doubles while the
// owed rows wait for an open.
type State {
  State(options: Options, interval_ms: Int)
}

// What a pass found.
type Backlog {
  // At least one row is still pending, or the rows could not be read.
  Owed(Pace)

  // Nothing is pending.
  Clear
}

// How soon the next pass should be.
type Pace {
  // An owner did not answer, or the rows could not be read, and either may be
  // over by the next pass.
  Quick

  // Every owed row waits for its recipient to be opened.
  Slow
}

/// Options over a sender's wiring and a timer source, with a silent logger.
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
  Options(wiring:, after:, logger: log.discard())
}

/// Sets the logger the drainer reports deliveries and failed reads on.
///
/// ## Examples
///
/// ```gleam
/// // peer_outbox_drain.options(wiring, after) |> peer_outbox_drain.with_logger(logger)
/// ```
pub fn with_logger(options: Options, logger: Logger) -> Options {
  Options(..options, logger:)
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

// The machine `start` and `supervised` both describe. It begins `Waiting`, so
// that `entered`'s first call arms the pass that runs at session open.
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
fn handle(
  phase: Phase,
  data: State,
  message: Message,
) -> sm.Next(Phase, State, Message) {
  case phase, message {
    Idle, Queued -> sm.transition(to: Waiting, data:)
    Waiting, Queued -> sm.keep(data)
    Idle, Tick | Waiting, Tick -> after_pass(phase, data, pass(data))
  }
}

// Decides the next arming from what the pass found. A pass that leaves a row
// owed re-arms the same name, which supersedes the arming that woke it, after
// the interval the pace calls for; a pass that leaves none moves to `Idle`, and
// `entered` cancels the timeout. Both ways into `Idle` and `Waiting` start from
// the fixed interval, because `entered` arms it.
fn after_pass(
  phase: Phase,
  data: State,
  backlog: Backlog,
) -> sm.Next(Phase, State, Message) {
  let fresh = State(..data, interval_ms: retry_interval_ms)
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
fn pass(data: State) -> Backlog {
  let options = data.options
  case options.wiring.own.call(peer_mail.OutboxDue) {
    Ok(json.Array(items)) ->
      drain_rows(options, list.filter_map(items, peer_outbox.decode), [], [])
      |> backlog_of
    Ok(_) -> {
      log.warn(options.logger, "peer_outbox.unreadable", [
        field.text("reason", "the due rows were not a list"),
      ])
      Owed(Quick)
    }
    Error(failure) -> {
      log.warn(options.logger, "peer_outbox.unreadable", [
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
fn drain_rows(
  options: Options,
  rows: List(peer_outbox.Row),
  waiting: List(String),
  found: List(peer_outbox.Outcome),
) -> List(peer_outbox.Outcome) {
  case rows {
    [] -> found

    [row, ..rest] ->
      case list.contains(waiting, row.session) {
        True -> drain_rows(options, rest, waiting, found)
        False -> {
          let outcome = peers.resend(options.wiring, row)
          report(options, row, outcome)
          let waiting = case outcome {
            peer_outbox.Unanswered | peer_outbox.NotOpen -> [
              row.session,
              ..waiting
            ]
            peer_outbox.Receipt(..) | peer_outbox.Rejected(..) -> waiting
          }
          drain_rows(options, rest, waiting, [outcome, ..found])
        }
      }
  }
}

// What the pass found decides how soon the next one is, whatever order the
// rows were attempted in. An owner that did not answer calls for the fixed
// interval, because it may be back by the next pass. Failing that, a recipient
// that is saved calls for the backed-off one, because only its owner's
// decision ends the wait. Nothing owed leaves nothing to wait for.
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
fn report(
  options: Options,
  row: peer_outbox.Row,
  outcome: peer_outbox.Outcome,
) -> Nil {
  case outcome {
    peer_outbox.Receipt(..) ->
      log.info(options.logger, "peer_outbox.admitted", where(row))
    peer_outbox.Rejected(reason:) ->
      log.info(options.logger, "peer_outbox.refused", [
        field.text("reason", reason),
        ..where(row)
      ])
    peer_outbox.Unanswered | peer_outbox.NotOpen -> Nil
  }
}

fn where(row: peer_outbox.Row) -> List(field.Field) {
  [
    field.text("session", row.session),
    field.text("strand", row.strand),
    field.text("message_id", row.message_id),
  ]
}
