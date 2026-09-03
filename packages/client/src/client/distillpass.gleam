//// The distillation pass in the session lifecycle: one supervised
//// worker that runs `client/distill` once per boot and then idles.
////
//// # Why a resident at all
////
//// `client/distill` is a command, and for most of memory stage M2 that
//// was the whole producer: an operator ran it from a source checkout,
//// out of cron or a post-session hook. A shipped release has neither a
//// checkout nor that cron job, so `remember` notes accumulated and no
//// session ever read a digest back (#149). This module is the missing
//// half — the pipeline unchanged, started by the server that already
//// consumes what it writes.
////
//// # One pass, at boot, and then nothing
////
//// The worker starts under the host's restartable service tier, beside
//// the search-index holder, and its whole life is three steps: run one
//// pass on a weft scope bounded by a wall deadline, log what it did,
//// and idle. It never re-arms. There is no per-turn distillation and no
//// timer, because the pipeline's own rules make a session boundary the
//// only sensible cadence: a live session holds its writer lease, so a
//// pass can never read the session it runs inside, and the material
//// that *is* readable — the sessions closed since the last boot, and
//// the notes the `remember` door wrote — does not change while this
//// server runs.
////
//// That is also the whole retry policy. A pass that fails, or that the
//// deadline cuts off, leaves every cursor where it was and is not
//// retried in this session; the next boot reads the same material
//// again. Nothing is lost by that: the pipeline's crash contract is the
//// write order (rows, then the head-and-cursors CAS, then the sidecar),
//// so an interrupted pass leaves a store that the next pass reads as if
//// it had never run.
////
//// # Why it starts after the boot rather than during it
////
//// The pass dispatches model turns, which is why it must not sit inside
//// `assemble`: a repository with ten closed sessions would delay the
//// server's first turn by however long extraction takes. Starting it as
//// a supervised child buys the ordering the pipeline needs for free —
//// by the time this child starts, the host has held its own session's
//// writer lease since early in the boot, so the pass meets that lease
//// and skips the live session by the rule the pipeline already has.
////
//// # What the digest it writes is visible to
////
//// The sidecar is read at *run start*, by the hook `client/serve`
//// installs, so a digest this pass writes is carried by the next run of
//// this session and by every later session. It never reaches a run
//// already open: injection happens once, when a run is accepted, and
//// nothing here touches a live prompt.
////
//// # The one cost of an interruption
////
//// A pass killed mid-flight — a shutdown, a fatal child, `SIGKILL` —
//// cannot release the memory session's lease, which it holds under the
//// run-scale TTL (`client/memory.run_lease_ttl_ms`, ten minutes). The
//// store is consistent, because the write order says so, but a boot
//// arriving inside that window finds the lease held and says so in one
//// line rather than distilling. That is a freshness cost measured in
//// minutes and never a lost row, which is why this module carries no
//// machinery to shorten it: releasing a lease from outside the process
//// that took it is exactly the theft the run-scale TTL exists to
//// prevent.

import client/distill
import core/clock.{type Clock}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import runtime/internal/ffi_sup
import telemetry/field
import telemetry/log.{type Logger}
import tom
import weft
import weft/state_machine as sm

// --- the operator's configuration ------------------------------------------

/// Whether this host distils at all, from the `[memory]` table's
/// `distill` key.
///
/// A two-variant type rather than a flag, because `distill = "off"` is a
/// posture an operator takes deliberately — a repository whose sessions
/// must never be read by a summarization model — and a `Bool` field
/// would leave every reader carrying the polarity of its name.
pub type Cadence {
  /// The default: one pass per session boot.
  DistillsOnBoot

  /// No pass, no child, no model turn. The `remember` door still works
  /// and notes still accumulate; nothing consolidates them until an
  /// operator runs `client/distill` by hand.
  DistillsOff
}

/// The `[memory]` table, decoded.
///
/// Constructor invariants: `wall_ms` is positive, which `parse`
/// enforces; it bounds one whole pass rather than one model turn, which
/// `client/distill.default_timeout_ms` bounds.
pub type Options {
  Options(cadence: Cadence, wall_ms: Int)
}

/// How long one pass may take before the deadline reaps it.
///
/// Generous on purpose. A pass costs one extraction turn per eligible
/// session plus one consolidation, each bounded by the pipeline's own
/// five-minute provider timeout, and the price of cutting a pass off is
/// that everything it had already paid for is thrown away. Ten minutes
/// is long enough that only a wedged provider reaches it.
pub const default_wall_ms = 600_000

/// The posture of a host whose configuration says nothing: one pass per
/// boot, ten minutes.
///
/// ## Examples
///
/// ```gleam
/// assert distillpass.default_options().cadence == distillpass.DistillsOnBoot
/// ```
///
pub fn default_options() -> Options {
  Options(cadence: DistillsOnBoot, wall_ms: default_wall_ms)
}

/// Decodes the `[memory]` table out of a `loom.toml` document.
///
/// Total, and strict about what it will accept: an unknown key in the
/// table is a refusal rather than a silently ignored line, because a
/// typoed opt-out that distilled anyway is the one failure an operator
/// cannot see. An absent table is the default posture.
///
/// The top-level key `memory` must also be in `client/catalog`'s allowed
/// list, which is where this document's table names are checked; that is
/// the same obligation `[[rule]]` and `[schedules]` carry.
///
/// ## Examples
///
/// ```gleam
/// assert distillpass.parse("") == Ok(distillpass.default_options())
/// ```
///
/// ```gleam
/// assert distillpass.parse("[memory]\ndistill = \"off\"\n")
///   == Ok(distillpass.Options(
///     cadence: distillpass.DistillsOff,
///     wall_ms: distillpass.default_wall_ms,
///   ))
/// ```
///
pub fn parse(text: String) -> Result(Options, String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(fn(error) {
      "the configuration is not valid TOML: " <> string.inspect(error)
    }),
  )
  case dict.get(document, "memory") {
    Error(Nil) -> Ok(default_options())
    Ok(tom.Table(fields)) -> memory_table(fields)
    Ok(_other) -> Error("[memory] must be a table")
  }
}

fn memory_table(fields: Dict(String, tom.Toml)) -> Result(Options, String) {
  use Nil <- result.try(known_keys(fields))
  use cadence <- result.try(cadence_of(fields))
  use wall_ms <- result.map(wall_of(fields))
  Options(cadence:, wall_ms:)
}

fn known_keys(fields: Dict(String, tom.Toml)) -> Result(Nil, String) {
  let allowed = ["distill", "distill_wall_ms"]
  case list.find(dict.keys(fields), fn(key) { !list.contains(allowed, key) }) {
    Error(Nil) -> Ok(Nil)
    Ok(unknown) ->
      Error(
        "unknown key `"
        <> unknown
        <> "` in the [memory] table (allowed: "
        <> string.join(allowed, ", ")
        <> ")",
      )
  }
}

fn cadence_of(fields: Dict(String, tom.Toml)) -> Result(Cadence, String) {
  case dict.get(fields, "distill") {
    Error(Nil) -> Ok(DistillsOnBoot)
    Ok(tom.String("on-boot")) -> Ok(DistillsOnBoot)
    Ok(tom.String("off")) -> Ok(DistillsOff)
    Ok(_other) ->
      Error(
        "memory.distill must be one of \"on-boot\" or \"off\": \"on-boot\" "
        <> "runs one distillation pass per session boot, and \"off\" runs "
        <> "none at all and leaves remembered notes for a hand-run "
        <> "`loom-distill`",
      )
  }
}

fn wall_of(fields: Dict(String, tom.Toml)) -> Result(Int, String) {
  case dict.get(fields, "distill_wall_ms") {
    Error(Nil) -> Ok(default_wall_ms)
    Ok(tom.Int(ms)) if ms > 0 -> Ok(ms)
    Ok(_other) ->
      Error(
        "memory.distill_wall_ms must be a positive integer: it is how many "
        <> "milliseconds one whole pass may take before it is cut off",
      )
  }
}

// --- what a pass came to ---------------------------------------------------

/// How one pass ended — the answer `settled` gives and the thing the
/// worker's closing line reports.
pub type Pass {
  /// The pipeline ran to completion. The report is the operator's
  /// account: how many sources contributed, how many were skipped, how
  /// many rows the head now carries, and whether the sidecar moved.
  Completed(report: distill.Report)

  /// The pipeline refused, or the process running it died. Every cursor
  /// is where it was, and the next boot reads the same material again.
  Refused(reason: String)

  /// The wall deadline reaped the pass. Work was done and thrown away;
  /// like a refusal, the next boot starts over.
  Expired(after_ms: Int)
}

// --- the worker ------------------------------------------------------------

/// Everything the worker needs: where to distil, what to ask, and how
/// long it may take.
///
/// Constructor invariants: `directory` is the session directory the host
/// keeps its memory store in — the same fold `client/serve` protects, so
/// that the digest this pass writes is the file the host's run-start
/// hook reads; `distiller` has already chosen its dispatch target
/// (`client/distill.target`); `wall_ms` is positive.
pub type Config {
  Config(
    name: Name(Message),
    directory: String,
    distiller: distill.Distiller,
    clock: Clock,
    entropy: fn() -> Int,
    wall_ms: Int,
    logger: Logger,
  )
}

/// What the worker is asked. Opaque: `settled` is the only question, and
/// the other two variants are the machine talking to itself.
pub opaque type Message {
  /// Injected by the initialiser, handled before anything external: the
  /// pass begins here rather than inside the initialiser so that the
  /// supervisor's start is never blocked by it.
  Begin

  /// The weft scope's account of the run, relayed onto this machine's
  /// own subject.
  Reported(pulled: weft.Pulled(distill.Report, String))

  /// Somebody wants the outcome. Postponed while the pass is running,
  /// which is what makes this a wait rather than a poll.
  Awaited(reply_with: Subject(Pass))
}

/// The two phases of the worker's life.
type Phase {
  /// The pass is running under its own weft scope.
  Running

  /// The pass has settled, once and for the life of this boot. The
  /// payload never changes while the machine is here, which is the rule
  /// a weft state carries (`docs/weft.md`, rule 1).
  Idle(pass: Pass)
}

/// What the machine carries across the transition.
///
/// Constructor invariants: `outcomes` is created in the initialiser and
/// selected on, so it is owned by the machine's own process and nothing
/// else may receive on it.
type Book {
  Book(config: Config, outcomes: Subject(weft.Pulled(distill.Report, String)))
}

/// The event name the pass opens with. An operator watching a release
/// sees this one and then exactly one closing line, per boot: the five
/// names below are the whole of what a shipped server says about
/// memory, and `client/serve` logs the last of them in place of
/// starting a worker at all.
pub const started_event = "memory.distill.started"

/// The closing line of a pass that ran: counts, and whether the sidecar
/// moved.
pub const completed_event = "memory.distill.completed"

/// The closing line of a pass that did not run to completion — a held
/// lease, a provider failure, a dead worker.
pub const failed_event = "memory.distill.failed"

/// The closing line of a pass the wall deadline reaped.
pub const expired_event = "memory.distill.expired"

/// The line a host logs instead of starting a worker at all.
pub const off_event = "memory.distill.off"

/// Starts the worker under its configured name and begins its one pass.
///
/// The initialiser returns at once and the pass is injected with
/// `continuing`, so the supervisor's start is never held behind a
/// provider turn and no external message can be handled before the pass
/// has begun.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(_started) = distillpass.start(config)
/// ```
///
pub fn start(config: Config) -> sm.StartResult(Subject(Message)) {
  sm.new_with_initialiser(1000, fn(subject) {
    let outcomes = process.new_subject()

    // The default selector covers only the machine's own subject, so
    // the scope's relayed outcomes need one of their own; both are
    // received on this process and nowhere else.
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_map(outcomes, Reported)
    sm.initialised(Running, Book(config:, outcomes:))
    |> sm.selecting(selector)
    |> sm.returning(subject)
    |> sm.continuing(Begin)
    |> Ok
  })
  |> sm.named(config.name)
  |> sm.on_event(handle)
  |> sm.start
}

/// The worker as a supervisable child, which is how a host wires it.
///
/// It belongs in the restartable tier because it is addressed by name
/// and holds nothing durable: a crash — which only a bug in this module
/// could cause, since the pass itself runs on a weft worker whose death
/// is an outcome rather than an exit — costs a restart and one more
/// pass, which is work the pipeline is already idempotent about.
///
/// ## Examples
///
/// ```gleam
/// // sup.add(builder, distillpass.supervised(config))
/// ```
///
pub fn supervised(config: Config) -> ChildSpecification(Subject(Message)) {
  supervision.worker(fn() { start(config) })
}

/// Waits for this boot's pass to settle and says how it ended.
///
/// The deterministic counterpart to the log lines, and the door a test
/// drives the lifecycle through: a question asked while the pass is
/// running is *postponed* by the machine and answered the moment it
/// settles, so this is a wait rather than a poll. A worker that is not
/// running, or that does not answer inside `timeout_ms`, is a worded
/// `Error` and never a dead caller.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(distillpass.Completed(report)) =
/// //   distillpass.settled(name, timeout_ms: 30_000)
/// ```
///
pub fn settled(
  name: Name(Message),
  timeout_ms timeout_ms: Int,
) -> Result(Pass, String) {
  case process.named(name) {
    Error(Nil) -> Error(no_worker)
    Ok(pid) -> {
      let reply = process.new_subject()
      let monitor = process.monitor(pid)

      // Sent to the pid the monitor describes, for the reason
      // `client/history.ask` gives: re-resolving the name could ask a
      // replacement while watching its predecessor.
      ffi_sup.send_to_pid(pid, #(name, Awaited(reply_with: reply)))
      let answered =
        process.new_selector()
        |> process.select_map(reply, Some)
        |> process.select_specific_monitor(monitor, fn(_down) { None })
        |> process.selector_receive(within: timeout_ms)
      process.demonitor_process(monitor)
      case answered {
        Ok(Some(pass)) -> Ok(pass)
        Ok(None) | Error(Nil) -> Error(wedged)
      }
    }
  }
}

const no_worker = "this host runs no distillation pass"

const wedged = "the distillation pass did not answer in time"

// --- the machine -----------------------------------------------------------

fn handle(
  phase: Phase,
  book: Book,
  message: Message,
) -> sm.Next(Phase, Book, Message) {
  case phase, message {
    Running, Begin -> {
      begin(book)
      sm.keep(book)
    }

    // The scope's account. Everything terminal moves the machine to
    // `Idle`, which is what releases the questions waiting behind it.
    Running, Reported(pulled:) -> reported(book, pulled)

    // The whole reason this is a state machine: a question asked before
    // the pass settled waits inside the machine and is replayed on the
    // transition, so a caller sees one answer rather than a poll loop.
    Running, Awaited(..) -> sm.keep(book) |> sm.postpone

    // `Begin` is injected exactly once, by the initialiser, and the
    // machine is in `Running` when it is handled; this arm exists so the
    // pair is written rather than because it can happen.
    Idle(..), Begin -> sm.keep(book)

    // The relay follows the outcome with `AllDelivered`, and that
    // arrives after the transition. Nothing is left to record.
    Idle(..), Reported(..) -> sm.keep(book)

    Idle(pass:), Awaited(reply_with:) -> {
      process.send(reply_with, pass)
      sm.keep(book)
    }
  }
}

// Starts the pass on its own weft scope, bounded by the wall deadline.
//
// One task, relayed rather than awaited: the machine must stay able to
// answer while the pass runs, and a deadline that kills *and joins* is
// what makes "the pass is over" a fact rather than a hope.
fn begin(book: Book) -> Nil {
  let config = book.config
  log.info(config.logger, started_event, [
    field.text(key: "directory", value: config.directory),
    field.count(key: "wall_ms", value: config.wall_ms),
  ])
  let pass = fn() { distill.run(pipeline(config)) }
  let _relay =
    weft.new([pass])
    |> weft.deadline(config.wall_ms)
    |> weft.start_relayed(to: book.outcomes)
  Nil
}

// The pipeline's own configuration, over the host's session directory.
// `config_for` derives the store and the sidecar from the directory, so
// this is the same pair `client/serve` protected at boot.
fn pipeline(config: Config) -> distill.Config {
  distill.config_for(
    config.directory,
    config.distiller,
    clock: config.clock,
    entropy: config.entropy,
  )
  |> distill.with_logger(config.logger)
}

// One relayed message, turned into the pass's ending.
//
// All seven `Outcome` variants are written out (`docs/weft.md`, rule 9):
// this run has no managed owners, so two of them cannot occur, and
// saying so here is cheaper than discovering it the day the run grows
// one.
fn reported(
  book: Book,
  pulled: weft.Pulled(distill.Report, String),
) -> sm.Next(Phase, Book, Message) {
  case pulled {
    weft.PulledOutcome(outcome: weft.Completed(value: report, ..)) ->
      settle(book, Completed(report:))
    weft.PulledOutcome(outcome: weft.Failed(error: reason, ..)) ->
      settle(book, Refused(reason:))
    weft.PulledOutcome(outcome: weft.Crashed(reason:, ..)) ->
      settle(book, Refused(reason: "the pass died: " <> string.inspect(reason)))

    // The deadline. `Abandoned` means the task was started and then
    // cancelled, and the only thing that cancels this run is its own
    // deadline.
    weft.PulledOutcome(outcome: weft.Abandoned(..)) ->
      settle(book, Expired(after_ms: book.config.wall_ms))
    weft.PulledOutcome(outcome: weft.NeverStarted(..)) ->
      settle(book, Refused(reason: "the pass never got a slot"))
    weft.PulledOutcome(outcome: weft.DrainProofLost(reason:, ..)) ->
      settle(
        book,
        Refused(
          reason: "the pass lost its drain proof: " <> string.inspect(reason),
        ),
      )
    weft.PulledOutcome(outcome: weft.CancellationUnconfirmed(..)) ->
      settle(book, Refused(reason: "the pass did not confirm cancellation"))

    // The run ended without delivering an outcome, which means the scope
    // died before the task reported. Every cursor is where it was.
    weft.AllDelivered ->
      settle(book, Refused(reason: "the pass ended without an account"))
    weft.RunLost(reason:) ->
      settle(
        book,
        Refused(reason: "the pass scope died: " <> string.inspect(reason)),
      )

    // `NotYet` answers a `pull` that timed out, and nothing here pulls.
    weft.NotYet -> sm.keep(book)
  }
}

// The transition every ending goes through: one line, then idle.
fn settle(book: Book, pass: Pass) -> sm.Next(Phase, Book, Message) {
  announce(book.config.logger, pass)
  sm.transition(to: Idle(pass:), data: book)
}

// The operator's account of the pass, and the whole of what a shipped
// server says about memory unless something went wrong.
fn announce(logger: Logger, pass: Pass) -> Nil {
  case pass {
    Completed(report:) ->
      log.info(logger, completed_event, [
        field.count(key: "sources", value: report.sources),
        field.count(key: "skipped", value: report.skipped),
        field.count(key: "candidates", value: report.candidates),
        field.count(key: "rows", value: report.rows),
        field.text(key: "digest", value: digest_word(report.digest)),
      ])
    Refused(reason:) ->
      log.warn(logger, failed_event, [
        field.text(key: "reason", value: reason),
        field.text(key: "effect", value: retry_note),
      ])
    Expired(after_ms:) ->
      log.warn(logger, expired_event, [
        field.count(key: "after_ms", value: after_ms),
        field.text(key: "effect", value: retry_note),
      ])
  }
}

const retry_note = "no cursor moved; the next session boot reads the same "
  <> "material again"

// Whether the sidecar moved, in the vocabulary
// `client/memory.reconcile_digest` answers in: `None` is a file this
// pass never touched, and `Some(0)` is one it emptied.
fn digest_word(written: Option(Int)) -> String {
  case written {
    None -> "unchanged"
    Some(0) -> "emptied"
    Some(bytes) -> "written:" <> int.to_string(bytes)
  }
}
