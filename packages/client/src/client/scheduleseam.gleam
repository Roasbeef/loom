//// The host side of the model-facing scheduling door: the closures
//// `tools/schedule` calls, and every bound it states but does not check.
////
//// `tools` may depend on `core` and `broker` and nothing else, so a tool
//// that needs a session cannot reach one. `tools/schedule` is therefore a
//// value over a seam of closures, and this module fills them in. The
//// split is the same one `client/memory` fills for `tools/remember`, and
//// it falls in the same place: the tool owns the model-facing surface —
//// the schema, the wording, the shape of a refusal — and the host owns
//// everything durable and everything enforced.
////
//// ## What this module is the only enforcer of
////
//// Three things, and none of them can honestly live on the other side.
////
//// **The operator's policy.** `client/schedule.Policy` comes from
//// `loom.toml`, which `tools` cannot read. A `wake` the model asked for
//// is granted only if the policy permits it, and the answer is returned
//// rather than refused, so the tool can tell the model what it actually
//// got. The policy is *not* consulted for whether to register the tools:
//// that decision is `client/serve`'s, made once at boot, and a seam that
//// exists at all has already passed it.
////
//// **The ceiling.** `max_model_schedules` is a count of live cells under
//// one reserved prefix, so answering "is there room" is a durable read
//// this module can make and the tool cannot.
////
//// **The bounds on the schedule itself.** `client/schedule.build` holds
//// a model's request to exactly the limits a `[[schedule]]` table is held
//// to. Checking them here rather than in the tool is what keeps the two
//// creation paths from drifting apart: one constructor, one set of
//// predicates, two sets of words for a reader who needs different ones.
////
//// ## Why the writes are plain cells and not marked commits
////
//// A fired-mark is written once and must never be written twice, so it
//// rides inside the admission's own transaction (`runtime/api.Mark`) —
//// the injection it authorizes and the mark land together or neither
//// does. A config cell has nothing to ride with: it says a schedule
//// *exists*, this module is the only writer of its key, and no entry is
//// admitted alongside it. So each write is a fact commit of its own.
////
//// Being alone is not the same as being blind, and neither of these
//// writes is blind. `create` claims the cell's *absence* through
//// `api.put_reserved_fact_expecting(expected: None)`, so a name belongs
//// to whichever writer commits first and the loser is told rather than
//// erased. `cancel` removes the cell with `api.delete_reserved_fact`
//// instead of overwriting it with a tombstone, so what a reader of this
//// prefix walks is the schedules that are live and not every name the
//// session has ever used (issue #164). The tombstone was there so that
//// "no such key" and "there was one and it is finished" could be told
//// apart by hand, and nothing here ever asked: the scanner and the
//// listing both want the schedules that run today, and a name whose cell
//// is gone is exactly the free name `create` is hoping for.
////
//// The two writes interlock, which is why they changed together. Once
//// `create` commits on the cell's absence, a tombstone left behind by a
//// cancel would hold the name against every later create for the life of
//// the session — `decode` refusing the value is no help, because the
//// claim never looks at it. Retiring the record by deletion is what
//// keeps a cancelled name reusable.
////
//// `schedule_create` stays `replay: Never` all the same. A replay now
//// meets the claim and refuses instead of replacing, which is an
//// improvement rather than a licence — a replayed create whose name was
//// cancelled in between would be admitted honestly, and the model asked
//// for that schedule once.
////
//// ## The check-then-write gap, and what is still open
////
//// `create` checks for a name collision and for room under the ceiling
//// before it writes, and the name check is not what makes a name unique.
//// The write is. `expected: None` commits only while the cell is absent,
//// and the `FactConflict` a loser gets back is reported as `NameTaken`,
//// in the same words the pre-check would have used. It also catches the
//// one collision the pre-check structurally cannot see: a cell
//// `live_schedules` dropped because it would not decode is a name the
//// check reports as free, and the claim refuses it anyway rather than
//// writing over whatever is there.
////
//// That ordering is load-bearing because a whole store round trip
//// separates the checks from the write, and two creates can sit inside
//// that window. Through the **tool** door they cannot today: both
//// writers are `execution_mode: Exclusive`, so the strand driver never
//// runs two in one batch, and a strand runs one batch at a time. Through
//// the **code-mode** door they can, because `codemode/satellite` runs
//// every `ServedHere` plan on its own process, so a program can fan out
//// `schedule.every` calls that all pass the checks before any of them
//// writes. Until the claim landed, that produced two same-name creates
//// both answering `Created` with the last body winning — precisely what
//// "creating never silently replaces" forbids (issue #162). The property
//// now rests on the commit, on both doors, so the tool door's
//// serialization is a scheduling convenience rather than the thing
//// keeping this store honest.
////
//// The pre-checks stay, and not out of caution. `name_is_free` also
//// consults the *operator's* schedules, which live in `loom.toml` and
//// have no cell for a claim to collide with, so it is the only thing
//// that can catch a model shadowing an operator's `{target, name}` and
//// stealing its fired-mark. And a worded refusal reached before any
//// write is what a model can act on; the conflict is the store saying
//// the same thing the hard way.
////
//// What is genuinely still open is the **ceiling**.
//// `room_for_one_more` counts live cells, so N concurrent creates that
//// read the same count all pass it and a program can admit up to
//// `max_outstanding` schedules past `max_model_schedules`. Nothing here
//// rests on the exact count: the ceiling bounds the durable footprint
//// this store can grow to, and each schedule's mandatory expiry bounds
//// what one of them costs, so over-admission by the width of one batch
//// is over-admission rather than a broken invariant. Making it exact
//// needs a durable counter or a claim cell to serialize on — a mechanism
//// rather than a correction — so it stays written down here instead of
//// half-built.

import client/agency
import client/schedule.{type Policy, type Schedule}
import client/schedulescan
import core/json.{type JsonValue}
import gleam/erlang/process.{type Name}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import runtime/api.{type Runtime}
import tools/schedule as schedule_tool
import tools/tool.{type Ctx}

/// Everything the seam needs from the host, as one value rather than a
/// growing parameter list.
///
/// `operator_schedules` is here for a reason that is easy to miss: a
/// model-created schedule and an operator's `[[schedule]]` derive their
/// fire-marks from the same `{target, name}` pair, so two schedules
/// sharing both would share a mark and silently suppress each other's
/// fires. The operator's list is fixed at boot and the model's is
/// checked against it, which is the only place that collision can be
/// caught — neither `client/schedule.parse` (which never sees a model's
/// names) nor the scanner (which by then has two indistinguishable
/// schedules) can.
pub type Wiring {
  Wiring(
    /// Borrows the live runtime. A function rather than the runtime
    /// itself because this seam is built before `api.open` has returned
    /// one: the registry it joins is threaded *into* the open, so a
    /// closure over the runtime would be a value cycle. `client/serve`
    /// supplies `agency.borrow_runtime`, which reads the session's one
    /// holder actor by name. `Error(Nil)` — the holder not up yet, or
    /// gone — becomes an in-band `Unavailable`, never a crash.
    runtime: fn() -> Result(Runtime, Nil),
    policy: Policy,
    operator_schedules: List(Schedule),
    scanner: Name(schedulescan.Message),
  )
}

/// The bounds this build states to the model, read off `client/schedule`
/// so the description and the check cannot disagree.
///
/// ## Examples
///
/// ```gleam
/// // tools/schedule.tools(scheduleseam.seam(runtime, policy),
/// //   scheduleseam.limits())
/// ```
///
pub fn limits() -> schedule_tool.Limits {
  schedule_tool.Limits(
    min_interval_seconds: schedule.min_interval_s,
    default_max_fires: schedule.default_max_fires,
    max_schedules: schedule.max_model_schedules,
  )
}

/// The scheduling seam over one runtime and one operator policy.
///
/// ## Examples
///
/// ```gleam
/// // scheduleseam.seam(runtime, schedule.ModelSchedulesSteer)
/// ```
///
pub fn seam(wiring: Wiring) -> schedule_tool.Schedules {
  let door = door(wiring)
  schedule_tool.Schedules(
    create: fn(ctx: Ctx, request) { door.create(ctx.strand, request) },
    list: fn(ctx: Ctx) { door.list(ctx.strand) },
    cancel: fn(ctx: Ctx, name) { door.cancel(ctx.strand, name) },
  )
}

/// The same three operations keyed on a strand name rather than on a
/// `tools/tool.Ctx`.
///
/// Two doors reach this store — the `schedule_*` tools and the
/// `schedule.*` code-mode capabilities — and a code-mode call has no
/// `Ctx` to offer, only the strand its execution belongs to. The strand
/// is in fact all either door ever needed: a schedule targets the strand
/// that created it and no other, which is the whole of the authority
/// question here. So the shared implementation is keyed on that, and
/// `seam` is the thin adapter for callers that happen to hold a `Ctx`.
///
/// ## Examples
///
/// ```gleam
/// // scheduleseam.door(wiring).list("main")
/// ```
///
pub type Door {
  Door(
    create: fn(String, schedule_tool.Request) ->
      Result(schedule_tool.Created, schedule_tool.Refusal),
    list: fn(String) ->
      Result(List(schedule_tool.Listed), schedule_tool.Refusal),
    cancel: fn(String, String) -> Result(Nil, schedule_tool.Refusal),
  )
}

/// The scheduling door over one runtime and one operator policy.
///
/// ## Examples
///
/// ```gleam
/// // scheduleseam.door(wiring).create("main", request)
/// ```
///
pub fn door(wiring: Wiring) -> Door {
  Door(
    create: fn(strand, request) {
      use runtime <- with_runtime(wiring)
      create(wiring, runtime, strand, request)
    },
    list: fn(strand) {
      use runtime <- with_runtime(wiring)
      listing(runtime, strand)
    },
    cancel: fn(strand, name) {
      use runtime <- with_runtime(wiring)
      cancel(wiring, runtime, strand, name)
    },
  )
}

// Every call borrows the runtime first, and a holder that is not up
// refuses in band rather than crashing the effect process.
fn with_runtime(
  wiring: Wiring,
  then: fn(Runtime) -> Result(a, schedule_tool.Refusal),
) -> Result(a, schedule_tool.Refusal) {
  case wiring.runtime() {
    Error(Nil) ->
      Error(schedule_tool.Unavailable(
        reason: "the session runtime is not available",
      ))
    Ok(runtime) -> then(runtime)
  }
}

// --- create ---------------------------------------------------------------

fn create(
  wiring: Wiring,
  runtime: Runtime,
  strand: String,
  request: schedule_tool.Request,
) -> Result(schedule_tool.Created, schedule_tool.Refusal) {
  let Wiring(policy:, operator_schedules:, scanner:, ..) = wiring
  use Nil <- result.try(schedulable(strand))
  use timing <- result.try(requested_timing(request.timing))

  // The policy caps `wake`; it does not veto the call. A model under a
  // `steer` policy that asked to wake gets a schedule that steers, and
  // the tool says so — refusing instead would teach it to retry against
  // a wall that will not move for anything it can do.
  let wake =
    schedule.wake_under(policy, requested: requested_wake(request.wake))
  use built <- result.try(
    schedule.build(
      name: request.name,
      target: strand,
      timing:,
      wake:,
      body: request.body,
    )
    |> result.map_error(fn(reason) { schedule_tool.Invalid(reason:) }),
  )
  use existing <- result.try(live_schedules(runtime))
  use Nil <- result.try(room_for_one_more(existing))
  use Nil <- result.try(name_is_free(
    existing,
    operator_schedules,
    strand,
    built.name,
  ))

  // The write is the name's only real claim. `expected: None` commits
  // only while the cell is absent, so two creates racing through the
  // checks above cannot both land: the loser hears `NameTaken` instead
  // of watching its schedule be replaced by the other's body (#162).
  use _seq <- result.try(
    api.put_reserved_fact_expecting(
      runtime,
      schedule.config_key(strand:, name: built.name),
      schedule.encode(built),
      expected: None,
    )
    |> result.map_error(fn(error) { claim_refused(error, built.name) }),
  )

  // The cell is durable now; the scanner has no reason to look at it
  // until its next armed deadline, which may be a long way off or absent
  // entirely. Ringing it here is what makes a schedule the model just
  // created start on time rather than whenever the floor comes round.
  schedulescan.poke(scanner)
  Ok(schedule_tool.Created(
    name: built.name,
    when: describe_timing(built.timing),
    wake: granted_wake(built.wake),
  ))
}

// What a failed claim means to the model. `FactConflict` is the arm
// this door exists for: the cell is there, so somebody holds the name,
// and the answer is the refusal `name_is_free` would have worded had it
// been able to see the cell. Every other arm is a store that could not
// answer at all, which is nothing the model can act on beyond asking
// again later.
fn claim_refused(error: api.ApiError, name: String) -> schedule_tool.Refusal {
  case error {
    api.FactConflict(..) -> schedule_tool.NameTaken(name:)
    api.AcceptRejected(..)
    | api.QueueRejected(..)
    | api.ReadFailed(..)
    | api.CommitFailed(..)
    | api.SessionStolen(..)
    | api.RaceLost
    | api.ReservedFactKey(..)
    | api.UnreservedFactKey(..)
    | api.EscalationExists(..)
    | api.EscalationNotFound(..)
    | api.EscalationWrongStatus(..) -> unavailable(error)
  }
}

// `tools` may not depend on `client`, so the door states the two wake
// postures in its own type and this seam translates, exactly as it does
// for a refusal. Two functions rather than one reversible pair, because
// the directions are read by different sides: `requested_wake` carries
// what the model asked into the store's vocabulary, and `granted_wake`
// carries what the store settled on back out.
fn requested_wake(wake: schedule_tool.Wake) -> schedule.Wake {
  case wake {
    schedule_tool.WakesIdle -> schedule.WakesIdle
    schedule_tool.SteersOnly -> schedule.SteersOnly
  }
}

fn granted_wake(wake: schedule.Wake) -> schedule_tool.Wake {
  case wake {
    schedule.WakesIdle -> schedule_tool.WakesIdle
    schedule.SteersOnly -> schedule_tool.SteersOnly
  }
}

// A subagent may not schedule, and the reason is a lifetime mismatch
// rather than a trust one.
//
// A schedule is keyed to the strand that created it and is cancellable
// only by that strand. A subagent settles; the schedule does not. Nobody
// can cancel it afterwards — the parent's `schedule_cancel` correctly
// answers `NotFound`, because it is not the parent's — so it holds a
// session-wide ceiling slot for the rest of the session, and a
// `wake = true` one keeps re-opening runs on a driver whose task ended,
// spending budget nobody is watching and outside the spawn budget the
// parent was held to. A subagent inherits `schedule_create` by default:
// `client/agency.child_tools` hands a child every tool the parent has
// except `agent_spawn`, so this is the ordinary path, not a corner.
//
// Refusing outright is deliberately blunter than the problem. The right
// answer is an ownership model where a parent's schedules can outlive a
// child and a child's cannot outlive itself, which is what #154 and #163
// are for. Until one exists, the door that spends money unobserved stays
// shut, and the refusal says which issue to read.
fn schedulable(strand: String) -> Result(Nil, schedule_tool.Refusal) {
  case agency.is_subagent(strand) {
    False -> Ok(Nil)
    True ->
      Error(schedule_tool.Invalid(
        reason: "a subagent cannot schedule a heartbeat: a schedule is "
        <> "cancellable only by the strand that created it, and this "
        <> "strand will settle while the schedule outlives it. Ask the "
        <> "strand that spawned you to schedule it instead, or do the "
        <> "work now.",
      ))
  }
}

// The model writes an interval in plain seconds and a one-shot as an
// RFC3339 string, because those are the two shapes a tool argument can
// carry honestly. Turning them into a `Timing` is this module's job
// because `client/schedule` owns the one RFC3339 parser and the defaulted
// expiry a recurring schedule always gets.
fn requested_timing(
  requested: schedule_tool.RequestedTiming,
) -> Result(schedule.Timing, schedule_tool.Refusal) {
  case requested {
    schedule_tool.Every(seconds:) ->
      Ok(schedule.Interval(
        seconds:,
        expiry: schedule.Expiry(
          max_fires: schedule.default_max_fires,
          expires_after_s: schedule.default_expires_after_s,
        ),
      ))
    schedule_tool.At(instant:) ->
      schedule.parse_instant(instant)
      |> result.map(fn(at) { schedule.OneShot(at:) })
      |> result.map_error(fn(reason) { schedule_tool.Invalid(reason:) })
  }
}

fn room_for_one_more(
  existing: List(#(String, Schedule)),
) -> Result(Nil, schedule_tool.Refusal) {
  // "Are there this many or more" needs only the elements up to the
  // bound, not a full walk to count them (lint R5) — the same idiom
  // `client/schedule.interval_expired` uses for its own ceiling.
  case list.drop(existing, schedule.max_model_schedules - 1) {
    [] -> Ok(Nil)
    [_at_the_limit, ..] ->
      Error(schedule_tool.CeilingReached(limit: schedule.max_model_schedules))
  }
}

// A name is taken if *either* store already has it on this strand. The
// operator's half matters as much as the model's: both halves feed one
// scanner, which derives a fire-mark from `{target, name}` alone, so a
// duplicate would make two schedules share one mark and each suppress the
// other's fires. The model is told the name is taken without being told
// whose it is — an operator's config is not the model's to enumerate.
fn name_is_free(
  existing: List(#(String, Schedule)),
  operator_schedules: List(Schedule),
  strand: String,
  name: String,
) -> Result(Nil, schedule_tool.Refusal) {
  let claims = fn(sched: Schedule) {
    sched.target == strand && sched.name == name
  }
  let taken =
    list.any(existing, fn(pair) {
      let #(_key, sched) = pair
      claims(sched)
    })
    || list.any(operator_schedules, claims)
  case taken {
    True -> Error(schedule_tool.NameTaken(name:))
    False -> Ok(Nil)
  }
}

// --- list -----------------------------------------------------------------

fn listing(
  runtime: Runtime,
  strand: String,
) -> Result(List(schedule_tool.Listed), schedule_tool.Refusal) {
  use live <- result.try(live_schedules(runtime))
  live
  |> list.filter(fn(pair) {
    let #(_key, sched) = pair
    sched.target == strand
  })
  |> list.map(fn(pair) {
    let #(_key, sched) = pair
    listed(runtime, sched)
  })
  |> Ok
}

fn listed(runtime: Runtime, sched: Schedule) -> schedule_tool.Listed {
  schedule_tool.Listed(
    name: sched.name,
    when: describe_timing(sched.timing),
    wake: granted_wake(sched.wake),
    fired: fire_count(runtime, sched),
    body: sched.body,
  )
}

// A failed read reports zero rather than propagating: the count is
// context for a model deciding what to cancel, and a listing that fails
// entirely because one counter could not be read is worse than a listing
// with one optimistic number in it. Nothing branches on this value.
fn fire_count(runtime: Runtime, sched: Schedule) -> Int {
  api.reserved_facts(
    runtime,
    prefix: schedule.fired_key_prefix(strand: sched.target, name: sched.name),
  )
  |> result.map(list.length)
  |> result.unwrap(0)
}

// --- cancel ---------------------------------------------------------------

fn cancel(
  wiring: Wiring,
  runtime: Runtime,
  strand: String,
  name: String,
) -> Result(Nil, schedule_tool.Refusal) {
  let key = schedule.config_key(strand:, name:)
  use live <- result.try(live_schedules(runtime))

  // Cancelling something that is not there is an error rather than a
  // no-op, because a model that misremembers a name should hear about it
  // instead of believing it has tidied up. A schedule the *operator*
  // configured is not in this list at all, so naming one lands here too,
  // which is the right answer: it is not the model's to cancel.
  use Nil <- result.try(case list.key_find(live, key) {
    Ok(_sched) -> Ok(Nil)
    Error(Nil) -> Error(schedule_tool.NotFound(name:))
  })

  // Deleted rather than overwritten with a tombstone: no reader of this
  // prefix asks whether a name was once used, and a marker that said so
  // would sit in every later scan of it for the life of the session
  // (#164). A cell that is already gone is a delete that succeeds, so a
  // second cancel racing this one is refused by the `NotFound` check
  // above or lands harmlessly.
  use Nil <- result.try(
    api.delete_reserved_fact(runtime, key)
    |> result.map_error(unavailable),
  )

  // Nothing breaks without this — the next tick would find the cell gone
  // on its own — but a cancelled schedule that fires once more before the
  // scanner notices reads as the cancel having failed.
  schedulescan.poke(wiring.scanner)
  Ok(Nil)
}

// --- shared reads ---------------------------------------------------------

// Every live model-created schedule in the session, keyed by its cell.
// A cell that does not decode is dropped rather than failing the read:
// `client/schedule.decode` refuses a schedule an older build stored
// under bounds this one has since tightened, and anything else that ever
// appears under this prefix reads the same way. Both are "not a schedule
// that runs today", which is exactly what every caller here is asking.
//
// The drop is also why `create` cannot let this read decide a name: a
// cell dropped here is a name reported free, and only the claiming write
// sees what is actually in the store.
fn live_schedules(
  runtime: Runtime,
) -> Result(List(#(String, Schedule)), schedule_tool.Refusal) {
  use cells <- result.try(
    api.reserved_facts(runtime, prefix: schedule.config_key_prefix)
    |> result.map_error(unavailable),
  )
  cells
  |> list.filter_map(fn(pair) {
    let #(key, value) = pair
    schedule.decode(value) |> result.map(fn(sched) { #(key, sched) })
  })
  |> Ok
}

fn unavailable(error: api.ApiError) -> schedule_tool.Refusal {
  schedule_tool.Unavailable(reason: string.inspect(error))
}

/// How a schedule's timing reads to the model — the one rendering, used
/// by both `create`'s confirmation and `list`'s rows.
///
/// ## Examples
///
/// ```gleam
/// // scheduleseam.describe_timing(schedule.OneShot(at: 0))
/// //   == "once at 1970-01-01T00:00:00Z"
/// ```
///
pub fn describe_timing(timing: schedule.Timing) -> String {
  case timing {
    schedule.Interval(seconds:, expiry:) ->
      "every "
      <> int.to_string(seconds)
      <> "s, at most "
      <> int.to_string(expiry.max_fires)
      <> " times"
    schedule.OneShot(at:) -> "once at " <> schedule.render_instant(at)
  }
}

/// The JSON one config cell holds, exposed for tests that need to plant
/// or inspect one without going through the tool.
///
/// ## Examples
///
/// ```gleam
/// // scheduleseam.cell(sched)
/// ```
///
pub fn cell(sched: Schedule) -> JsonValue {
  schedule.encode(sched)
}
