//// Distillation cadence for standalone sessions and shared workspace domains.
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
//// # The standalone adapter
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
//// This adapter does not retry during the session. Interruption does not
//// roll back committed work: the next pass resumes from durable head/cursor
//// state and reconciles the digest sidecar. Failure after that commit must
//// never be reported as though no progress occurred.
////
//// # Shared-domain cadence and retirement
////
//// `start_domain` uses the owned `distill.prepare` pipeline. First authorized
//// admission starts one pass, and each pass resolves its explicit catalogue
//// sources afresh. Clean-close triggers during a pass coalesce into one
//// follow-up. Failure discards that pending trigger; a later explicit trigger
//// may retry. There is no timer or automatic failure retry.
////
//// A domain re-arms only after its managed retirement account and terminal
//// delivery, plus the original linked cancellation witness's normal exit.
//// Delivery alone is not resource retirement. Proof loss permanently blocks
//// the worker, and its temporary supervision policy forbids automatic
//// replacement. The daemon must preserve the corresponding reservation if
//// this original worker dies unexpectedly.
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
//// A standalone pass killed mid-flight — a shutdown, a fatal child, `SIGKILL` —
//// cannot release the memory session's lease, which it holds under the
//// run-scale TTL (`client/memory.run_lease_ttl_ms`, ten minutes). The
//// store is consistent, because the write order says so, but a boot
//// arriving inside that window finds the lease held and says so in one
//// line rather than distilling. That is a freshness cost measured in
//// minutes and never a lost row, which is why this module carries no
//// machinery to shorten it: releasing a lease from outside the process
//// that took it is exactly the theft the run-scale TTL exists to
//// prevent. Owned domain passes instead retain cleanup with adopted holders;
//// caller timeout is neither cancellation nor permission to reopen a store.

import broker/internal/call
import client/distill
import client/memory
import core/clock.{type Clock}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import provider/gateway
import provider/model
import telemetry/field
import telemetry/log.{type Logger}
import tom
import weft
import weft/actor
import weft/registry as address
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

/// How long one pass may take before the deadline reaps it, and the
/// ceiling a configured one is held to.
///
/// It is the memory session's own run lease
/// (`client/memory.run_lease_ttl_ms`) rather than a number that happens
/// to equal it, and that is the whole argument for the value. **Nothing
/// renews that lease but a commit**, so a pass cannot usefully outlive
/// it: one running past the TTL has already had its lease stolen by
/// whatever opened the store next, and its next commit fails. Cutting
/// it cleanly at the deadline costs the same work and reports it
/// honestly, so raising the wall past the lease buys nothing and hides
/// a failure behind a different one — which is why `parse` refuses a
/// larger value rather than accepting it.
///
/// Generous within that bound, on purpose: a pass costs one extraction
/// turn per eligible session plus one consolidation, each bounded by
/// the pipeline's own five-minute provider timeout, and the price of
/// cutting a pass off is that everything it had already paid for is
/// thrown away.
pub const default_wall_ms = memory.run_lease_ttl_ms

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

/// The opted-out posture: no worker, no pass, no model turn.
///
/// A named constructor rather than the record written out, because a
/// host that wants no distillation says one thing — the deadline it
/// carries is meaningless and every site that spelled it out had to
/// pick a number anyway.
///
/// ## Examples
///
/// ```gleam
/// assert distillpass.no_pass().cadence == distillpass.DistillsOff
/// ```
///
pub fn no_pass() -> Options {
  Options(cadence: DistillsOff, wall_ms: default_wall_ms)
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
        <> "runs at domain admission and coalesces successful-close passes, "
        <> "while \"off\" runs "
        <> "none at all and leaves remembered notes for a hand-run "
        <> "`loom-distill`",
      )
  }
}

fn wall_of(fields: Dict(String, tom.Toml)) -> Result(Int, String) {
  case dict.get(fields, "distill_wall_ms") {
    Error(Nil) -> Ok(default_wall_ms)
    Ok(tom.Int(ms)) if ms > 0 && ms <= default_wall_ms -> Ok(ms)

    // Refused rather than clamped. A clamp would make the file say one
    // thing and the server do another, and the operator who wrote the
    // larger number is at a terminal reading this message — which is
    // exactly the moment to explain that the ceiling is the memory
    // lease and not a taste.
    Ok(tom.Int(ms)) if ms > default_wall_ms ->
      Error(
        "memory.distill_wall_ms is "
        <> int.to_string(ms)
        <> ", above the "
        <> int.to_string(default_wall_ms)
        <> "ms the memory session's writer lease lasts. Nothing renews "
        <> "that lease but a commit, so a pass cannot outlive it: past "
        <> "the TTL its lease is stealable and its next commit fails. "
        <> "Lower the wall, or leave the key out for the ceiling itself",
      )
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

  /// The pipeline refused, or its worker died. Earlier commits may stand;
  /// this outcome does not assert rollback.
  Refused(reason: String)

  /// The wall deadline cancelled the pass. A later pass resumes from durable
  /// head/cursor state, which may already include this pass's commit.
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
    name: address.Address(Message),
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
  |> sm.addressed(config.name)
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
  name: address.Address(Message),
  timeout_ms timeout_ms: Int,
) -> Result(Pass, String) {
  case address.lookup(name) {
    Error(Nil) -> Error(no_worker)
    Ok(subject) -> {
      use pid <- result.try(
        process.subject_owner(subject)
        |> result.replace_error(no_worker),
      )
      let reply = process.new_subject()
      let monitor = process.monitor(pid)

      // Sent to the pid the monitor describes, for the reason
      // `client/history.ask` gives: re-resolving the name could ask a
      // replacement while watching its predecessor.
      process.send(subject, Awaited(reply_with: reply))
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
    // died before the task reported. Already committed progress still stands.
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

const retry_note = "committed head/cursor state is retained; a later authorized "
  <> "trigger or session boot resumes from durable progress"

/// A domain's owner-selected policy and fresh catalogue source resolver.
/// This worker always uses `distill.prepare`, never an arbitrary leaf task.
pub type DomainConfig {
  DomainConfig(
    /// Stable address owned by daemon domain admission.
    name: address.Address(DomainMessage),
    /// Memory/digest destinations, clock, entropy, and logger.
    pipeline: distill.Config,
    /// Resolves authorized explicit sources afresh inside each managed pass.
    sources: fn() -> Result(List(distill.Source), String),
    /// Provider configuration belonging to the domain's explicit owner.
    gateway: gateway.Gateway,
    /// The owner's resolved distillation route.
    target: model.RequestTarget,
    /// Per-request deadline, distinct from the pass wall deadline.
    request_timeout_ms: Int,
    /// Explicit opt-out and maximum pass duration.
    options: Options,
  )
}

/// Domain messages are private to the bounded command functions below.
pub opaque type DomainMessage {
  DomainBegin
  DomainTrigger(Subject(Result(Nil, String)))
  DomainNotify
  DomainAwait(Subject(Pass))
  DomainQuiesce(Subject(Pass))
  DomainStop(Subject(String))
  DomainWitness(Subject(Option(process.Pid)))
  DomainReported(weft.Pulled(distill.Report, String))
  WitnessRetired(process.ExitReason)
}

type DomainPhase {
  Dormant
  Active
  Settled(Pass)
  RecoveryBlocked(String)
}

type Pending {
  NoFollowUp
  FollowUp
}

type Admission {
  Accepting
  Quiescing
  Stopping
}

type Delivery {
  WaitingForDelivery
  Delivered
}

type WitnessStop {
  WitnessRunning
  WitnessStopRequested
}

type DomainBook {
  DomainBook(
    config: DomainConfig,
    subject: Subject(DomainMessage),
    reports: Subject(weft.Pulled(distill.Report, String)),
    witness: Option(#(Subject(Nil), process.Pid, process.Monitor)),
    witness_stop: WitnessStop,
    delivery: Delivery,
    account: Option(Pass),
    pending: Pending,
    admission: Admission,
  )
}

/// Starts one pass at first authorized domain admission, then waits for triggers.
/// Opted-out domains refuse before creating a pass or cancellation witness.
///
/// ## Examples
///
/// ```gleam
/// // distillpass.start_domain(config)
/// ```
@internal
pub fn start_domain(
  config: DomainConfig,
) -> sm.StartResult(Subject(DomainMessage)) {
  prepare_domain(config)
  |> result.map(fn(started) {
    begin_domain(started.data)
    started
  })
}

/// Starts parked, retaining the creator link without opening any resource.
/// The domain custodian publishes cleanup before unlinking and calling begin.
///
/// ## Examples
///
/// ```gleam
/// // let parked = distillpass.prepare_domain(config)
/// ```
@internal
pub fn prepare_domain(
  config: DomainConfig,
) -> sm.StartResult(Subject(DomainMessage)) {
  sm.new_with_initialiser(1000, fn(subject) {
    use <- bool.guard(
      when: config.options.cadence == DistillsOff,
      return: Error("distillation is disabled for this domain"),
    )
    use <- bool.guard(
      when: config.options.wall_ms <= 0
        || config.options.wall_ms > default_wall_ms
        || config.request_timeout_ms <= 0,
      return: Error(
        "domain distillation deadlines must be positive and bounded",
      ),
    )
    let reports = process.new_subject()
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_map(reports, DomainReported)
    sm.initialised(
      Dormant,
      DomainBook(
        config,
        subject,
        reports,
        None,
        WitnessRunning,
        WaitingForDelivery,
        None,
        NoFollowUp,
        Accepting,
      ),
    )
    |> sm.selecting(selector)
    |> sm.returning(subject)
    |> Ok
  })
  |> sm.addressed(config.name)
  |> sm.on_event(domain_handle)
  |> sm.start
}

/// Releases the original parked worker after cleanup publication succeeds.
/// Duplicate releases during an active run cannot allocate another run.
///
/// ## Examples
///
/// ```gleam
/// // distillpass.begin_domain(parked.data)
/// ```
@internal
pub fn begin_domain(subject: Subject(DomainMessage)) -> Nil {
  process.send(subject, DomainBegin)
}

/// Supervision must not replace an owner whose unexpected death lost custody.
/// The daemon must separately retain its original monitor and blocked reservation.
///
/// ## Examples
///
/// ```gleam
/// // sup.add(builder, distillpass.supervised_domain(config))
/// ```
@internal
pub fn supervised_domain(
  config: DomainConfig,
) -> ChildSpecification(Subject(DomainMessage)) {
  supervision.worker(fn() { start_domain(config) })
  |> supervision.restart(supervision.Temporary)
}

/// Coalesces a clean-close notification into at most one follow-up pass.
/// A timeout does not withdraw a queued trigger. No trigger retries proof loss.
///
/// ## Examples
///
/// ```gleam
/// // distillpass.trigger(domain, waiting_ms: 1000)
/// ```
@internal
pub fn trigger(
  name: address.Address(DomainMessage),
  waiting_ms waiting: Int,
) -> Result(Nil, String) {
  use answer <- result.try(domain_call(name, waiting, DomainTrigger))
  answer
}

/// Sends a clean-close hint without waiting inside daemon admission.
/// A fenced or unstarted worker ignores hints. Send before quiesce to request
/// the final clean-close pass without introducing an automatic retry.
///
/// ## Examples
///
/// ```gleam
/// // distillpass.notify_domain(domain)
/// ```
@internal
pub fn notify_domain(
  name: address.Address(DomainMessage),
) -> Result(Nil, String) {
  use subject <- result.try(
    address.lookup(name) |> result.replace_error("domain worker is unavailable"),
  )
  process.send(subject, DomainNotify)
  Ok(Nil)
}

/// Waits for the active pass, or returns the most recently completed account.
/// Postponed callers are answered before any ordinary-mailbox follow-up begins.
///
/// ## Examples
///
/// ```gleam
/// // distillpass.domain_settled(domain, waiting_ms: 1000)
/// ```
@internal
pub fn domain_settled(
  name: address.Address(DomainMessage),
  waiting_ms waiting: Int,
) -> Result(Pass, String) {
  domain_call(name, waiting, domain_await)
}

/// Requests the current account on a caller-owned typed reply subject.
/// The caller owns its receive deadline; expiry does not withdraw the request,
/// and a late account may still arrive on that subject. This uses the same
/// dispatch as `domain_settled`, without inspecting private mailbox envelopes.
///
/// ## Examples
///
/// ```gleam
/// // distillpass.request_domain_settled(domain, reply)
/// ```
@internal
pub fn request_domain_settled(
  name: address.Address(DomainMessage),
  reply: Subject(Pass),
) -> Result(Nil, String) {
  use subject <- result.try(
    address.lookup(name) |> result.replace_error("domain worker is unavailable"),
  )
  process.send(subject, domain_await(reply))
  Ok(Nil)
}

fn domain_await(reply: Subject(Pass)) -> DomainMessage {
  DomainAwait(reply)
}

/// Fences new triggers and waits for current and already-coalesced work.
/// Failure discards the pending pass as usual. The caller owns its receive
/// deadline; the worker remains alive for custody's original stop request.
///
/// ## Examples
///
/// ```gleam
/// // distillpass.request_quiesce(domain, reply)
/// ```
@internal
pub fn request_quiesce(
  name: address.Address(DomainMessage),
  reply: Subject(Pass),
) -> Result(Nil, String) {
  use subject <- result.try(
    address.lookup(name) |> result.replace_error("domain worker is unavailable"),
  )
  process.send(subject, DomainQuiesce(reply))
  Ok(Nil)
}

/// Reports the currently owned cancellation witness for custody diagnostics.
///
/// ## Examples
///
/// ```gleam
/// // distillpass.active_witness(domain, waiting_ms: 1000)
/// ```
@internal
pub fn active_witness(
  name: address.Address(DomainMessage),
  waiting_ms waiting: Int,
) -> Result(Option(process.Pid), String) {
  domain_call(name, waiting, DomainWitness)
}

fn domain_call(
  name: address.Address(DomainMessage),
  waiting: Int,
  message: fn(Subject(answer)) -> DomainMessage,
) -> Result(answer, String) {
  use <- bool.guard(
    when: waiting <= 0,
    return: Error("domain call deadline expired"),
  )
  use subject <- result.try(
    address.lookup(name) |> result.replace_error("domain worker is unavailable"),
  )
  call.try_call(subject, waiting: int.min(waiting, 5000), sending: message)
  |> result.map_error(fn(fault) {
    "domain worker did not answer: " <> string.inspect(fault)
  })
}

/// Fences new work and waits for the original domain worker's normal exit.
/// Timeout or abnormal exit is not retirement proof. A blocked worker stays alive.
///
/// ## Examples
///
/// ```gleam
/// // distillpass.stop_domain(domain, waiting_ms: 1000)
/// ```
@internal
pub fn stop_domain(
  name: address.Address(DomainMessage),
  waiting_ms waiting: Int,
) -> Result(Nil, String) {
  use <- bool.guard(
    when: waiting <= 0,
    return: Error("domain stop deadline expired"),
  )
  use subject <- result.try(
    address.lookup(name) |> result.replace_error("domain worker is unavailable"),
  )
  use pid <- result.try(
    process.subject_owner(subject)
    |> result.replace_error("domain worker is unavailable"),
  )
  let watch = process.monitor(pid)
  let refused = process.new_subject()
  process.send(subject, DomainStop(refused))
  let observed =
    process.new_selector()
    |> process.select_map(refused, Error)
    |> process.select_specific_monitor(watch, fn(down) {
      case down.reason {
        process.Normal -> Ok(Nil)
        reason ->
          Error("domain retirement lost proof: " <> string.inspect(reason))
      }
    })
    |> process.selector_receive(int.min(waiting, 5000))
  process.demonitor_process(watch)
  observed |> result.unwrap(Error("domain retirement remains unconfirmed"))
}

fn domain_handle(
  phase: DomainPhase,
  book: DomainBook,
  message: DomainMessage,
) -> sm.Next(DomainPhase, DomainBook, DomainMessage) {
  case phase, message {
    Dormant, DomainBegin ->
      case book.admission {
        Accepting -> domain_begin(book)
        Quiescing | Stopping -> sm.keep(book)
      }
    Active, DomainBegin -> sm.keep(book)
    Settled(_), DomainBegin ->
      case book.pending {
        FollowUp -> domain_begin(book)
        NoFollowUp -> sm.keep(book)
      }
    RecoveryBlocked(_), DomainBegin -> sm.keep(book)
    Active, DomainReported(report) -> domain_reported(book, report)
    Dormant, DomainReported(_)
    | Settled(_), DomainReported(_)
    | RecoveryBlocked(_), DomainReported(_)
    -> sm.keep(book)
    Dormant, DomainAwait(reply) -> {
      process.send(reply, Refused("domain worker has not begun"))
      sm.keep(book)
    }
    Active, DomainAwait(_) -> sm.keep(book) |> sm.postpone
    Active, DomainQuiesce(_) -> {
      let admission = case book.admission {
        Stopping -> Stopping
        Accepting | Quiescing -> Quiescing
      }
      sm.keep(DomainBook(..book, admission:)) |> sm.postpone
    }
    Settled(pass), DomainQuiesce(reply) -> {
      let book = DomainBook(..book, admission: Quiescing)
      case book.pending {
        FollowUp -> sm.keep(book) |> sm.postpone
        NoFollowUp -> {
          process.send(reply, pass)
          sm.keep(book)
        }
      }
    }
    Dormant, DomainQuiesce(reply) -> {
      process.send(reply, Refused("domain worker has not begun"))
      sm.keep(DomainBook(..book, admission: Quiescing))
    }
    RecoveryBlocked(reason), DomainQuiesce(reply) -> {
      process.send(reply, Refused(reason))
      sm.keep(book)
    }
    Settled(pass), DomainAwait(reply) -> {
      process.send(reply, pass)
      sm.keep(book)
    }
    RecoveryBlocked(reason), DomainAwait(reply) -> {
      process.send(reply, Refused(reason))
      sm.keep(book)
    }
    RecoveryBlocked(reason), DomainTrigger(reply) -> {
      process.send(reply, Error(reason))
      sm.keep(book)
    }
    Dormant, DomainTrigger(reply) -> {
      process.send(reply, Error("domain worker has not begun"))
      sm.keep(book)
    }
    _, DomainTrigger(reply) -> domain_trigger(phase, book, Some(reply))
    Dormant, DomainNotify | RecoveryBlocked(_), DomainNotify -> sm.keep(book)
    _, DomainNotify -> domain_trigger(phase, book, None)
    Active, DomainStop(_) -> {
      let book = request_witness_stop(book)
      sm.keep(DomainBook(..book, admission: Stopping, pending: NoFollowUp))
      |> sm.postpone
    }
    Dormant, DomainStop(_) | Settled(_), DomainStop(_) -> {
      sm.stop()
    }
    RecoveryBlocked(reason), DomainStop(reply) -> {
      process.send(reply, reason)
      sm.keep(book)
    }
    _, DomainWitness(reply) -> {
      process.send(reply, option.map(book.witness, fn(witness) { witness.1 }))
      sm.keep(book)
    }
    _, WitnessRetired(reason) -> witness_retired(phase, book, reason)
  }
}

fn domain_trigger(
  phase: DomainPhase,
  book: DomainBook,
  reply: Option(Subject(Result(Nil, String))),
) -> sm.Next(DomainPhase, DomainBook, DomainMessage) {
  case book.admission {
    Quiescing | Stopping -> {
      answer_trigger(reply, Error("domain worker is stopping"))
      sm.keep(book)
    }
    Accepting -> {
      case phase, book.pending {
        Settled(_), NoFollowUp -> process.send(book.subject, DomainBegin)
        Dormant, _ | Active, _ | Settled(_), FollowUp | RecoveryBlocked(_), _ ->
          Nil
      }
      answer_trigger(reply, Ok(Nil))
      sm.keep(DomainBook(..book, pending: FollowUp))
    }
  }
}

fn answer_trigger(reply, answer) {
  case reply {
    Some(reply) -> process.send(reply, answer)
    None -> Nil
  }
}

fn domain_begin(
  book: DomainBook,
) -> sm.Next(DomainPhase, DomainBook, DomainMessage) {
  let started =
    actor.new(Nil)
    |> actor.on_message(fn(_state, _stop: Nil) { actor.stop() })
    |> actor.start
  case started {
    Error(error) ->
      domain_block(
        book,
        "cancellation witness failed: " <> string.inspect(error),
      )
    Ok(witness) -> {
      let monitor = process.monitor(witness.pid)
      let config = book.config
      let _relay =
        weft.new_prepared([
          distill.prepare(
            config.pipeline,
            config.sources,
            config.gateway,
            config.target,
            config.request_timeout_ms,
          ),
        ])
        |> weft.deadline(config.options.wall_ms)
        |> weft.cancel_when_exits(witness.pid)
        |> weft.start_relayed(to: book.reports)
      log.info(config.pipeline.logger, started_event, [
        field.text("memory", config.pipeline.memory_path),
      ])
      let book =
        DomainBook(
          ..book,
          witness: Some(#(witness.data, witness.pid, monitor)),
          witness_stop: WitnessRunning,
          delivery: WaitingForDelivery,
          account: None,
          pending: NoFollowUp,
        )
      sm.transition(Active, book)
      |> sm.with_selector(domain_selector(book))
    }
  }
}

fn domain_reported(
  book: DomainBook,
  report: weft.Pulled(distill.Report, String),
) -> sm.Next(DomainPhase, DomainBook, DomainMessage) {
  case report {
    weft.PulledOutcome(weft.Completed(value:, ..)) ->
      domain_account(book, Completed(value))
    weft.PulledOutcome(weft.Failed(error:, ..)) ->
      domain_account(book, Refused(error))
    weft.PulledOutcome(weft.Crashed(reason:, ..)) ->
      domain_account(book, Refused(string.inspect(reason)))
    weft.PulledOutcome(weft.Abandoned(..)) ->
      case book.admission {
        Accepting | Quiescing ->
          domain_account(book, Expired(book.config.options.wall_ms))
        Stopping ->
          domain_account(book, Refused("domain shutdown cancelled the pass"))
      }
    weft.PulledOutcome(weft.NeverStarted(..)) ->
      domain_account(book, Refused("pass never started"))
    weft.PulledOutcome(weft.DrainProofLost(reason:, ..)) ->
      domain_block(book, "pass lost drain proof: " <> string.inspect(reason))
    weft.PulledOutcome(weft.CancellationUnconfirmed(..)) ->
      domain_block(book, "pass cancellation is unconfirmed")
    weft.RunLost(reason) ->
      domain_block(book, "pass scope lost: " <> string.inspect(reason))
    weft.NotYet -> sm.keep(book)
    weft.AllDelivered -> {
      let book = request_witness_stop(DomainBook(..book, delivery: Delivered))
      case book.witness {
        None -> domain_finish(book)
        Some(_) -> sm.keep(book)
      }
    }
  }
}

// Only the fixed managed pipeline may supply this account. Weft withholds it
// until its worker and every adopted owner retire, replacing it on proof loss.
fn domain_account(
  book: DomainBook,
  pass: Pass,
) -> sm.Next(DomainPhase, DomainBook, DomainMessage) {
  sm.keep(DomainBook(..book, account: Some(pass)))
}

fn domain_finish(
  book: DomainBook,
) -> sm.Next(DomainPhase, DomainBook, DomainMessage) {
  case book.account {
    None -> domain_block(book, "pass delivered no retirement account")
    Some(pass) -> {
      announce(book.config.pipeline.logger, pass)
      let pending = case pass, book.admission, book.pending {
        Completed(_), Accepting, FollowUp | Completed(_), Quiescing, FollowUp -> {
          // Mailbox delivery is deliberate: postponed Awaited calls replay first.
          process.send(book.subject, DomainBegin)
          FollowUp
        }
        _, _, _ -> NoFollowUp
      }
      sm.transition(Settled(pass), DomainBook(..book, witness: None, pending:))
    }
  }
}

fn domain_block(
  book: DomainBook,
  reason: String,
) -> sm.Next(DomainPhase, DomainBook, DomainMessage) {
  let book = request_witness_stop(book)
  announce(book.config.pipeline.logger, Refused(reason))
  sm.transition(
    RecoveryBlocked(reason),
    DomainBook(..book, pending: NoFollowUp),
  )
}

fn request_witness_stop(book: DomainBook) -> DomainBook {
  case book.witness {
    Some(#(subject, _, _)) -> process.send(subject, Nil)
    None -> Nil
  }
  DomainBook(..book, witness_stop: WitnessStopRequested)
}

fn domain_selector(book: DomainBook) -> process.Selector(DomainMessage) {
  let selector =
    process.new_selector()
    |> process.select(book.subject)
    |> process.select_map(book.reports, DomainReported)
  case book.witness {
    None -> selector
    Some(#(_, _, monitor)) ->
      selector
      |> process.select_specific_monitor(monitor, fn(down) {
        WitnessRetired(down.reason)
      })
  }
}

// A new run cannot allocate its witness until the original one exits normally.
fn witness_retired(
  phase: DomainPhase,
  book: DomainBook,
  reason: process.ExitReason,
) -> sm.Next(DomainPhase, DomainBook, DomainMessage) {
  let book = DomainBook(..book, witness: None)
  case phase, book.witness_stop, reason {
    RecoveryBlocked(_), _, _ -> sm.keep(book)
    _, WitnessStopRequested, process.Normal ->
      case book.delivery {
        WaitingForDelivery -> sm.keep(book)
        Delivered -> domain_finish(book)
      }
    _, _, _ ->
      domain_block(
        book,
        "cancellation witness retired unexpectedly: " <> string.inspect(reason),
      )
  }
}

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
