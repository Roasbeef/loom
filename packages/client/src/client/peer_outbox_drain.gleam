//// The outbox drainer: one machine per resident session that keeps
//// attempting the peer messages the session owes (`client/peer_outbox`).
////
//// `peers.send` writes an outbox row before it asks the recipient. When the
//// recipient's owner is unreachable the row stays pending and the send
//// returns `queued`; this machine is what delivers it later. It lives in the
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
//// The machine's whole liveness is one named timeout, `drain_timer`, fixed at
//// `retry_interval_ms`. There is no backoff: a recipient that is down for an
//// hour costs 720 attempts, each a single bounded call, and a fixed interval
//// means the moment the owner returns is the next tick and not the end of a
//// growing delay. When a pass finds nothing owed the timeout is cancelled and
//// the machine is `Idle`, so a session that never queues a message never has
//// a timer. `Queued` is the only thing that wakes it, and the row it
//// announces is already durable when the message is sent.
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
//// | `Waiting` | a pass; armed again if a row is still owed, else `Idle` with the timeout cancelled | ignored, the timeout is already armed |

import client/peer_mail
import client/peer_outbox
import client/peers
import core/json
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/supervision.{type ChildSpecification}
import telemetry/field
import telemetry/log.{type Logger}
import weft/actor
import weft/registry as address
import weft/state_machine as sm
import weft/timer

/// How long the machine waits between passes while any row is owed, in
/// milliseconds. It is fixed on purpose: see the module doc.
pub const retry_interval_ms = 5000

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
// the process; what is owed is read from the store at each pass.
type State {
  State(options: Options)
}

// What a pass found.
type Backlog {
  // At least one row is still pending, or the rows could not be read.
  Owed

  // Nothing is pending.
  Clear
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
    sm.initialised(Waiting, State(options:))
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
// owed re-arms the same name, which supersedes the arming that woke it; a pass
// that leaves none moves to `Idle`, and `entered` cancels the timeout.
fn after_pass(
  phase: Phase,
  data: State,
  backlog: Backlog,
) -> sm.Next(Phase, State, Message) {
  case phase, backlog {
    Waiting, Owed ->
      sm.keep(data)
      |> sm.with_named_timeout(
        name: drain_timer,
        after: retry_interval_ms,
        sending: Tick,
      )
    Waiting, Clear -> sm.transition(to: Idle, data:)
    Idle, Owed -> sm.transition(to: Waiting, data:)
    Idle, Clear -> sm.keep(data)
  }
}

// One pass over the rows that are due. The sender's Agency answers them, and
// refuses any that have waited past the hour before it does, so expiry needs
// no timer of its own. A read that fails is `Owed`: the rows may exist, and
// the next pass reads again.
fn pass(data: State) -> Backlog {
  let options = data.options
  case options.wiring.own.call(peer_mail.OutboxDue) {
    Ok(json.Array(items)) ->
      drain_rows(options, list.filter_map(items, peer_outbox.decode), [], Clear)
    Ok(_) -> {
      log.warn(options.logger, "peer_outbox.unreadable", [
        field.text("reason", "the due rows were not a list"),
      ])
      Owed
    }
    Error(reason) -> {
      log.warn(options.logger, "peer_outbox.unreadable", [
        field.text("reason", reason),
      ])
      Owed
    }
  }
}

// Attempts the rows in order. `silent` holds the sessions that did not answer
// during this pass: the owner of one is the owner of all its rows, so asking
// again would spend a full deadline per row to learn the same thing, and a
// pass over 64 rows to a dead node would last minutes.
fn drain_rows(
  options: Options,
  rows: List(peer_outbox.Row),
  silent: List(String),
  backlog: Backlog,
) -> Backlog {
  case rows {
    [] -> backlog

    [row, ..rest] ->
      case list.contains(silent, row.session) {
        True -> drain_rows(options, rest, silent, Owed)
        False ->
          case peers.resend(options.wiring, row) {
            peer_outbox.Unanswered ->
              drain_rows(options, rest, [row.session, ..silent], Owed)

            peer_outbox.Receipt(..) -> {
              log.info(options.logger, "peer_outbox.admitted", where(row))
              drain_rows(options, rest, silent, backlog)
            }

            peer_outbox.Rejected(reason:) -> {
              log.info(options.logger, "peer_outbox.refused", [
                field.text("reason", reason),
                ..where(row)
              ])
              drain_rows(options, rest, silent, backlog)
            }
          }
      }
  }
}

fn where(row: peer_outbox.Row) -> List(field.Field) {
  [
    field.text("session", row.session),
    field.text("strand", row.strand),
    field.text("message_id", row.message_id),
  ]
}
