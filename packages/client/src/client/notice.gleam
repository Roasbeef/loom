//// Harness notices about work that outlives the tool call that started
//// it: the completion notice a finished job or async execution sends its
//// owner, and the heartbeat an idle owner of still-running work receives.
////
//// Both answer the same failure. A model that started a background job
//// or launched an async execution learns what became of it only by
//// asking, and a model that ended its run while the work was still going
//// never asks. The owning service therefore tells it: once when the work
//// ends, and periodically while the owner sits idle and the work does
//// not. `docs/design-notes/async-completion-wake.md` has the whole design
//// and the table of which terminal states stay silent.
////
//// ## Why the services call this rather than the strand's own machinery
////
//// A notice is an ordinary queue admission through `runtime/api`, the door
//// `client/schedulescan` and `client/peer_mail` already use: a steer when
//// the owner has an open run, a fresh run when it is idle. Neither the
//// jobs actor nor the execution service learns anything about the
//// strand's turn machinery by sending one, which is what the jobs design
//// meant to keep when it ruled that a job wakes nobody. What that ruling
//// cost was a model that never heard about its work, and this module is
//// the smallest thing that pays it back.
////
//// ## At most once, and what may be lost
////
//// A completion notice spends a reserved mark under `client/notice/` in
//// the same transaction that admits it, so a service that re-derives the
//// same notice after a restart meets `FactConflict` rather than
//// delivering a second copy. The terminal state and the notice are still
//// two commits, so a crash between them loses the notice; the design note
//// weighs that window against the scan that would close it.
////
//// A heartbeat carries no mark. Its idle clock is volatile by design, and
//// the restart that forgets the clock also kills every job it counted.
////
//// ## Never a fresh run on a subagent
////
//// A subagent has one run. A notice that opened a second one after its
//// work ended would extend a child's life outside its parent's spawn
//// budget, which is the rule `client/schedulescan` and the Agency's
//// upward reports already keep. So a notice to a subagent only ever
//// steers a run it already has open, and an idle subagent is left idle:
//// its job's end is still on the record for a poll, and its parent
//// reads the child's result, not the child's jobs. A heartbeat to an idle
//// subagent is skipped for the same reason.
////
//// The advisor strand is held to the same rule for a different reason:
//// `client/advisor` alone decides when it runs, rationing its reviews, so
//// a run it did not open would be a review nobody asked for.

import client/agency
import core/clock
import core/json
import core/message.{type AgentMessage}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import machine/acceptance
import machine/queue
import runtime/api.{type Runtime}
import session/session

/// The reserved prefix every completion mark lives under. Inside
/// `client/`, which `runtime/api.reserved_fact_key` already reserves, so
/// no model-supplied `put_fact` can spend or forge a mark.
pub const key_prefix = "client/notice/"

/// How often an owning service samples its owners for the heartbeat, in
/// milliseconds.
///
/// A minute, for two reasons. The heartbeat interval is minutes, so a
/// sample a minute late is noise. And a jobs actor that ticked more often
/// than `runtime/residency.hibernate_after_ms` would never hibernate,
/// which is a memory cost paid by every idle session to buy precision no
/// reader needs.
pub const heartbeat_tick_ms = 60_000

/// The heartbeat interval a host with no `[jobs].heartbeat_s` serves, in
/// milliseconds: ten minutes, the interval unreal-agent's coordinator
/// uses for the same wake.
pub const default_heartbeat_ms = 600_000

/// The work a completion notice is about. The variant is part of the
/// mark's key, so a job and an execution that happened to share an id
/// could never spend each other's mark.
pub type Work {
  /// A background job, by its `job/<id>` handle.
  Job(id: String)

  /// An async code-mode execution, by its launch handle.
  Execution(id: String)
}

/// What a completion delivery did.
pub type Delivered {
  /// The notice was admitted, as a steer or as a fresh run.
  Delivered

  /// The mark was already spent: an earlier incarnation, or a concurrent
  /// attempt, delivered this notice. Nothing was written.
  AlreadyDelivered

  /// The owner is an idle subagent, which a notice may not wake. Nothing
  /// was written, and the mark stays unspent.
  Withheld
}

/// Whether a strand has an open run.
///
/// A two-variant type rather than a `Bool`, so the idle clock's arms read
/// as what they are about.
pub type Activity {
  /// The strand has an open operation.
  Busy

  /// The strand has no open operation.
  Idle
}

/// Whether a heartbeat is due for one strand on this sample.
pub type Due {
  /// The strand has been idle for the whole interval: beat now.
  Due

  /// The strand is busy, or has not been idle long enough.
  NotDue
}

/// The reserved key a completion notice for `work` spends.
///
/// ## Examples
///
/// ```gleam
/// assert notice.key(notice.Job("01JQ8")) == "client/notice/job/01JQ8"
/// assert notice.key(notice.Execution("x1"))
///   == "client/notice/execution/x1"
/// ```
///
pub fn key(work: Work) -> String {
  case work {
    Job(id:) -> key_prefix <> "job/" <> id
    Execution(id:) -> key_prefix <> "execution/" <> id
  }
}

/// Sends `text` to `owner` as a completion notice for `work`: a steer if
/// the owner has an open run, a fresh run if it is idle, and the mark for
/// `work` spent in the same transaction either way. An idle subagent is
/// never given a fresh run; see the module doc.
///
/// ## Examples
///
/// ```gleam
/// // notice.deliver(runtime, "main", notice.Job(id), text)
/// //   -> Ok(notice.Delivered)
/// ```
///
pub fn deliver(
  runtime: Runtime,
  owner: String,
  work: Work,
  text: String,
) -> Result(Delivered, String) {
  let mark = api.Mark(key: key(work), value: json.Null)
  let message = harness_message(runtime, text)
  let admitted = case may_wake(owner) {
    False -> steer_only(runtime, owner, message, mark)
    True ->
      api.send_to_strand_marking(runtime, to: owner, message:, mark:)
      |> result.replace(Delivered)
  }
  case admitted {
    Ok(delivered) -> Ok(delivered)
    Error(api.FactConflict(_)) -> Ok(AlreadyDelivered)
    Error(error) -> Error(string.inspect(error))
  }
}

// A notice to a subagent: onto its open run, or nowhere. The steer is
// quiet by design, so the doorbell is rung here, as `client/peer_mail`
// rings it after the same call.
fn steer_only(
  runtime: Runtime,
  owner: String,
  message: AgentMessage,
  mark: api.Mark,
) -> Result(Delivered, api.ApiError) {
  let target = api.on_strand(runtime, owner)
  case api.steer_marking(target, message, mark:) {
    Ok(_entry) -> {
      api.nudge(target)
      Ok(Delivered)
    }
    Error(api.QueueRejected(reason: queue.NoActiveRun)) -> Ok(Withheld)
    Error(error) -> Error(error)
  }
}

/// Whether `strand` has an open run, read from its durable state.
///
/// A strand with no state register has never run, which is idle.
///
/// ## Examples
///
/// ```gleam
/// // notice.activity(runtime, "main") -> Ok(notice.Idle)
/// ```
///
pub fn activity(runtime: Runtime, strand: String) -> Result(Activity, String) {
  use cell <- result.try(
    session.strand_state(runtime.session, strand)
    |> result.map_error(string.inspect),
  )
  case cell {
    Some(cell) ->
      case cell.value.current_operation {
        Some(_) -> Ok(Busy)
        None -> Ok(Idle)
      }
    None -> Ok(Idle)
  }
}

/// Starts a run on an idle `strand` carrying `text`, and rings its
/// doorbell. An idle subagent is skipped, for the reason a notice never
/// wakes one.
///
/// A strand that opened a run between the sample and this call is
/// already awake, so `StrandBusy` is a success: the heartbeat's whole job
/// was to make the model look, and something else already has.
///
/// ## Examples
///
/// ```gleam
/// // notice.beat(runtime, "main", listing) -> Ok(Nil)
/// ```
///
pub fn beat(
  runtime: Runtime,
  strand: String,
  text: String,
) -> Result(Nil, String) {
  use <- bool.guard(when: !may_wake(strand), return: Ok(Nil))
  let target = api.on_strand(runtime, strand)
  case api.prompt(target, [harness_message(runtime, text)]) {
    Ok(_operation) -> Ok(Nil)
    Error(api.AcceptRejected(reason: acceptance.StrandBusy)) -> Ok(Nil)
    Error(error) -> Error(string.inspect(error))
  }
}

/// The advisor strand's name, restated rather than imported:
/// `client/advisor` reaches `client/jobs` through `client/goalcheck`, and
/// `client/jobs` reaches this module, so an import would be a cycle.
/// `notice_test` pins the two spellings together.
pub const advisor_strand = "advisor"

/// Whether a notice or a heartbeat may open a fresh run on `strand`. A
/// subagent has one run, and the advisor's runs are its actor's to open;
/// every other strand may be woken.
///
/// ## Examples
///
/// ```gleam
/// assert notice.may_wake("main")
/// assert !notice.may_wake("sub:main/x-01")
/// assert !notice.may_wake("advisor")
/// ```
///
pub fn may_wake(strand: String) -> Bool {
  !agency.is_subagent(strand) && strand != advisor_strand
}

/// One heartbeat sample of `owner`: read whether its strand has an open
/// run, fold that into the idle clock, and wake it with `lines` when a
/// whole interval has passed. `lines` is a function so the listing is
/// built only on the sample that uses it.
///
/// An unreadable strand is left out of the sample and keeps whatever
/// stretch it had, so one bad read neither fires a beat nor resets one.
///
/// ## Examples
///
/// ```gleam
/// // let idle = notice.sample(runtime, idle, "main", now:,
/// //   interval_ms: 600_000, lines: fn() { ["job 01: make"] })
/// ```
///
pub fn sample(
  runtime: Runtime,
  idle: IdleClock,
  owner: String,
  now now: Int,
  interval_ms interval_ms: Int,
  lines lines: fn() -> List(String),
) -> IdleClock {
  case activity(runtime, owner) {
    Error(_unreadable) -> idle

    Ok(activity) -> {
      let #(idle, due) = observe(idle, owner, activity, now:, interval_ms:)
      case due {
        Due -> {
          let _woken =
            beat(runtime, owner, heartbeat_text(interval_ms, lines()))
          idle
        }
        NotDue -> idle
      }
    }
  }
}

// A user-role entry because that is the only shape a provider has for
// context the harness supplies, with no origin because none of the
// existing ones is true: this is neither a human nor a peer. The text's
// own `[loom]` first line is what names it, on the standing agreement a
// scheduled injection already relies on.
fn harness_message(runtime: Runtime, text: String) -> AgentMessage {
  let #(now, _clock) = clock.read(runtime.effects.clock)
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: now,
    origin: None,
  )
}

// --- the idle clock -------------------------------------------------------

/// When each sampled strand was first seen idle, with no busy sample
/// since. Volatile by design; see the module doc.
pub opaque type IdleClock {
  IdleClock(quiet_since: Dict(String, Int))
}

/// A clock that has sampled nothing.
///
/// ## Examples
///
/// ```gleam
/// let clock = notice.idle_clock()
/// ```
///
pub fn idle_clock() -> IdleClock {
  IdleClock(quiet_since: dict.new())
}

/// Folds one sample of `strand` into the clock and says whether a
/// heartbeat is due.
///
/// A busy sample forgets the strand, so its next idle stretch is measured
/// from the first idle sample after it rather than from before the turn
/// it just finished. A due beat restarts the stretch at `now`, which is
/// what makes a beat repeat every interval rather than on every sample
/// once the first interval has passed.
///
/// ## Examples
///
/// ```gleam
/// let #(clock, due) =
///   notice.observe(notice.idle_clock(), "main", notice.Idle, now: 0,
///     interval_ms: 600_000)
/// assert due == notice.NotDue
/// let #(_clock, due) =
///   notice.observe(clock, "main", notice.Idle, now: 600_000,
///     interval_ms: 600_000)
/// assert due == notice.Due
/// ```
///
pub fn observe(
  clock: IdleClock,
  strand: String,
  activity: Activity,
  now now: Int,
  interval_ms interval_ms: Int,
) -> #(IdleClock, Due) {
  let quiet = clock.quiet_since
  case activity, dict.get(quiet, strand) {
    Busy, _since -> #(IdleClock(dict.delete(quiet, strand)), NotDue)
    Idle, Error(Nil) -> #(IdleClock(dict.insert(quiet, strand, now)), NotDue)

    Idle, Ok(since) if now - since >= interval_ms -> #(
      IdleClock(dict.insert(quiet, strand, now)),
      Due,
    )

    Idle, Ok(_since) -> #(clock, NotDue)
  }
}

/// Drops every strand not in `owners`, so a strand whose work all ended
/// starts from nothing if it ever owns work again.
///
/// ## Examples
///
/// ```gleam
/// let clock = notice.retain(clock, ["main"])
/// ```
///
pub fn retain(clock: IdleClock, owners: List(String)) -> IdleClock {
  IdleClock(quiet_since: dict.take(clock.quiet_since, owners))
}

/// The heartbeat's text: the owner's live work, one line each, and what
/// to do about it.
///
/// ## Examples
///
/// ```gleam
/// // notice.heartbeat_text(600_000, ["job 01JQ8: running for 12m: make"])
/// ```
///
pub fn heartbeat_text(interval_ms: Int, lines: List(String)) -> String {
  "[loom] idle heartbeat: background work is still running\n\n"
  <> "You have been idle for "
  <> minutes(interval_ms)
  <> " while work you started is still running:\n\n"
  <> string.join(list.map(lines, fn(line) { "- " <> line }), "\n")
  <> "\n\nEach one sends you a notice when it finishes. If one looks "
  <> "stuck, inspect or stop it; otherwise end your turn to keep waiting."
}

/// A duration in whole minutes, for a notice a person may also read.
///
/// ## Examples
///
/// ```gleam
/// assert notice.minutes(600_000) == "10m"
/// assert notice.minutes(59_000) == "0m"
/// ```
///
pub fn minutes(ms: Int) -> String {
  int.to_string(ms / 60_000) <> "m"
}
