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
//// rides inside the admission's own transaction (`runtime/api.Mark`). A
//// config cell is different: it says a schedule *exists*, it is the only
//// writer of its own key, and writing it twice with the same value is
//// indistinguishable from writing it once. So it is an ordinary
//// `put_reserved_fact`, and the tool is `replay: Never` for the one thing
//// that ordering cannot fix — a replayed create silently replacing a
//// schedule the model believes it already has.
////
//// ## The read-your-writes question
////
//// `create` checks for a name collision and for room under the ceiling,
//// then writes. Two calls cannot race for that gap: both writers are
//// `execution_mode: Exclusive`, so the strand driver never runs two of
//// them in one batch, and a strand runs one batch at a time. Across
//// strands the keys are disjoint by construction, since a strand may only
//// schedule onto itself. The ceiling is the one genuinely session-wide
//// count, and the worst a lost race there could do is admit one schedule
//// over the limit — which the next call refuses and which no invariant
//// rests on.

import client/schedule.{type Policy, type Schedule}
import client/schedulescan
import core/json.{type JsonValue}
import gleam/erlang/process.{type Name}
import gleam/int
import gleam/list
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
  use timing <- result.try(requested_timing(request.timing))

  // The policy caps `wake`; it does not veto the call. A model under a
  // `steer` policy that asked to wake gets a schedule that steers, and
  // the tool says so — refusing instead would teach it to retry against
  // a wall that will not move for anything it can do.
  let wake = request.wake && schedule.policy_permits_wake(policy)
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
  use Nil <- result.try(
    api.put_reserved_fact(
      runtime,
      schedule.config_key(strand:, name: built.name),
      schedule.encode(built),
    )
    |> result.map_error(unavailable),
  )

  // The cell is durable now; the scanner has no reason to look at it
  // until its next armed deadline, which may be a long way off or absent
  // entirely. Ringing it here is what makes a schedule the model just
  // created start on time rather than whenever the floor comes round.
  schedulescan.poke(scanner)
  Ok(schedule_tool.Created(
    name: built.name,
    when: describe_timing(built.timing),
    wake: built.wake,
  ))
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
    wake: sched.wake,
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
  use Nil <- result.try(
    api.put_reserved_fact(runtime, key, schedule.cancelled_value)
    |> result.map_error(unavailable),
  )

  // Nothing breaks without this — the next tick would find the tombstone
  // on its own — but a cancelled schedule that fires once more before the
  // scanner notices reads as the cancel having failed.
  schedulescan.poke(wiring.scanner)
  Ok(Nil)
}

// --- shared reads ---------------------------------------------------------

// Every live model-created schedule in the session, keyed by its cell.
// A cell that does not decode is dropped rather than failing the read:
// `client/schedule.decode` refuses a cancellation tombstone by design,
// and it also refuses a schedule stored by an older build under bounds
// this one has since tightened. Both are "not a schedule that runs
// today", which is exactly what every caller here is asking.
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
