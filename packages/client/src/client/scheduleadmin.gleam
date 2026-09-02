//// The operator's side of the scheduling store: one listing that shows
//// every schedule the session holds, and a cancellation that reaches
//// only the ones a strand wrote.
////
//// `client/scheduleseam` is the *model's* door, and it is deliberately
//// narrow: a strand sees the schedules it owns and nothing else, so a
//// caller never learns a sibling's names and never holds a handle it
//// could only fail to cancel. An operator asks the opposite question.
//// They are watching the whole session, they configured half of what is
//// running in it, and the only place a model-created schedule was
//// previously visible at all was the log. So this module answers with
//// everything: the `[[schedule]]` tables from `loom.toml` first, then
//// every live cell a strand created.
////
//// ## Why it lists everything and cancels only what the model wrote
////
//// A `[[schedule]]` table is **configuration**. It is parsed at boot,
//// held in `Wiring.operator_schedules`, and has no durable cell in the
//// store at all — so there is nothing here to delete, and a surface that
//// appeared to delete one would either lie or start writing durable
//// overrides of a file the operator edits by hand. The same posture the
//// project rules take: `client/rulescan` fires the operator's
//// `[[rule]]` tables and never edits them, because the file is the
//// record and a restart is how a change to it lands. Naming a table
//// here is therefore refused with the reason rather than ignored, and
//// the reason names the file.
////
//// What the model wrote is a different kind of thing. It is a durable
//// cell under a reserved prefix, created inside a session by something
//// that is not the operator, and it holds one of a small ceiling of
//// slots. Cancelling it is exactly the operation the model's own door
//// already performs, which is why this module does not perform it
//// twice.
////
//// ## Why cancellation goes back through the seam
////
//// `scheduleseam.retire` removes a schedule's whole durable footprint —
//// fired-marks, then the observation instant, then last the config cell
//// — and the *order* is the crash story: a fault partway through leaves
//// the schedule live with a reset count and a caller told the cancel
//// failed, which a retry finishes. Deleting the config cell first would
//// answer success over a clock still ticking under a name the next
//// schedule inherits. A second deletion order written here would be a
//// second chance to get that wrong, so there is one order for both
//// doors, and the `schedulescan.poke` that follows it is the same poke
//// for the same reason: nothing breaks without it, but a cancelled
//// schedule that fires once more before the scanner re-reads its cells
//// reads to an operator as the cancel having failed.
////
//// ## What this module does not decide
////
//// Nothing about authority. The model's door checks ownership because a
//// strand may only touch its own; an operator is the session's owner by
//// construction, and the transport that carries these calls
//// (`client/gateway` over an authenticated connection) is where "is
//// this the operator" was already answered. The only thing refused here
//// is the operation that has no meaning, not an operation the caller is
//// not entitled to.

import client/schedule.{type Schedule}
import client/schedulescan
import client/scheduleseam.{type Wiring}
import gleam/bool
import gleam/list
import gleam/result
import runtime/api.{type Runtime}
import tools/schedule as schedule_tool

/// One row of the operator's listing: a schedule, rendered.
///
/// Constructor invariants: `name` and `target` are the pair that *is* a
/// schedule's durable identity, and the pair `cancel` takes; `owner` is
/// the string an operator reads — `"operator"` for a `[[schedule]]`
/// table, otherwise the name of the strand that created it; `when` is
/// `scheduleseam.describe_timing`'s rendering, the same words the model
/// is given, so an operator and a strand describe one clock the same
/// way; `fired` counts the occurrences already spent, read off the
/// durable marks; `body` is the text one fire injects.
pub type Row {
  Row(
    name: String,
    target: String,
    owner: String,
    when: String,
    wake: schedule.Wake,
    fired: Int,
    body: String,
  )
}

/// Why a cancellation did nothing.
pub type CancelRefusal {
  /// No live model-created schedule fires onto that target under that
  /// name. A name that never existed and a name already cancelled
  /// answer the same way, because the durable record of a cancelled
  /// schedule is its absence.
  NotFound

  /// The name belongs to an operator `[[schedule]]` table. There is no
  /// cell to remove: the file is the record, and a change to it takes
  /// effect on restart.
  OperatorConfigured

  /// The durable store could not be read or written, or the session's
  /// runtime holder was not up. The caller is told; nothing partial is
  /// left claiming success.
  Unavailable(reason: String)
}

/// The operator-facing scheduling door: list everything, cancel what a
/// strand created.
///
/// Constructor invariants: both functions are total — every failure is
/// a returned value, never a crash — and `cancel` is keyed on
/// `{target, name}` in that order, which is the identity every durable
/// schedule key is built from.
pub type Admin {
  Admin(
    list: fn() -> Result(List(Row), String),
    cancel: fn(String, String) -> Result(Nil, CancelRefusal),
  )
}

/// Builds the operator's door over the same `Wiring` the model's door
/// is built from, so the two cannot disagree about what this session's
/// schedules are.
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_schedules(options, scheduleadmin.admin(wiring))
/// ```
///
pub fn admin(wiring: Wiring) -> Admin {
  Admin(list: fn() { listing(wiring) }, cancel: fn(target, name) {
    cancellation(wiring, target, name)
  })
}

// --- listing ---------------------------------------------------------------

// The operator's tables first, then the live cells, and the order is the
// answer to "what is standing configuration and what did this session
// grow". Both halves are rendered by the same `row`, so an operator's
// heartbeat and a strand's read as one table rather than two.
fn listing(wiring: Wiring) -> Result(List(Row), String) {
  use runtime <- result.try(borrow(wiring))
  use live <- result.try(
    scheduleseam.live_schedules(runtime)
    |> result.map_error(reason_of),
  )
  let operator = list.map(wiring.operator_schedules, row(runtime, _))
  let created =
    list.map(live, fn(pair) {
      let #(_key, sched) = pair
      row(runtime, sched)
    })
  Ok(list.append(operator, created))
}

fn row(runtime: Runtime, sched: Schedule) -> Row {
  Row(
    name: sched.name,
    target: sched.target,
    owner: owner_label(sched.owner),
    when: scheduleseam.describe_timing(sched.timing),
    wake: sched.wake,
    fired: scheduleseam.fire_count(runtime, sched),
    body: sched.body,
  )
}

// A strand's own name is what an operator needs to know — it is who to
// ask about the schedule, and the strand `cancel` on the model's door
// would have to be called as. The operator's own schedules answer with
// the word rather than a name, because no strand asked for them.
fn owner_label(owner: schedule.Owner) -> String {
  case owner {
    schedule.OperatorOwned -> "operator"
    schedule.StrandOwned(strand:) -> strand
  }
}

// --- cancelling ------------------------------------------------------------

// The operator table check comes first and needs no store at all, so a
// name the file owns is answered with the file's own reason even while
// the durable side is unreachable. Everything after it is the model
// door's cancel with the ownership test removed and nothing else
// changed.
fn cancellation(
  wiring: Wiring,
  target: String,
  name: String,
) -> Result(Nil, CancelRefusal) {
  use <- bool.guard(
    when: operator_named(wiring, target, name),
    return: Error(OperatorConfigured),
  )
  use runtime <- result.try(
    borrow(wiring)
    |> result.map_error(Unavailable),
  )
  use live <- result.try(
    scheduleseam.live_schedules(runtime)
    |> result.map_error(unavailable),
  )

  // A cell that is not there is the whole of `NotFound`: the store keeps
  // no tombstone, so a name already cancelled and a name never used are
  // the same absence, and both mean the same thing to the asker.
  use _sched <- result.try(
    list.key_find(live, schedule.config_key(strand: target, name:))
    |> result.replace_error(NotFound),
  )
  use Nil <- result.try(
    scheduleseam.retire(runtime, target, name)
    |> result.map_error(unavailable),
  )
  schedulescan.poke(wiring.scanner)
  Ok(Nil)
}

fn operator_named(wiring: Wiring, target: String, name: String) -> Bool {
  list.any(wiring.operator_schedules, fn(sched) {
    sched.target == target && sched.name == name
  })
}

// --- borrowing and wording -------------------------------------------------

// The runtime is borrowed per call for the reason `Wiring.runtime`
// exists: this seam is built before `api.open` has returned one, and a
// holder that is not up is an in-band answer rather than a crash in the
// hub process that asked.
fn borrow(wiring: Wiring) -> Result(Runtime, String) {
  wiring.runtime()
  |> result.replace_error("the session runtime is not available")
}

fn unavailable(refusal: schedule_tool.Refusal) -> CancelRefusal {
  Unavailable(reason: reason_of(refusal))
}

// The seam speaks the model's refusal vocabulary, and only one of its
// variants can reach an operator through these two calls — a store that
// could not be read. The rest are spelled out anyway rather than swept
// into a catch-all, so a future seam refusal arrives as a sentence
// instead of as someone else's words.
fn reason_of(refusal: schedule_tool.Refusal) -> String {
  case refusal {
    schedule_tool.Unavailable(reason:) -> reason
    schedule_tool.Invalid(reason:) -> reason
    schedule_tool.CeilingReached(limit: _) ->
      "this session already holds every schedule it may"
    schedule_tool.NameTaken(name:) ->
      "a schedule named " <> name <> " already fires onto that strand"
    schedule_tool.NotFound(name:) -> "no schedule named " <> name
  }
}
