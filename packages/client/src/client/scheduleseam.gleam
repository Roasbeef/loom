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
//// Five things, and none of them can honestly live on the other side.
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
//// **Who may schedule onto whom.** A caller may name a target, and the
//// only admitted answers are itself and a strand it spawned — asked of
//// `client/agency.owns`, and so of the durable lineage ledger, because
//// nothing about the shape of a name is evidence: a sibling's looks
//// exactly like a child's. Anything else is `Invalid` before a cell is
//// written, and every failure to read the ledger is a refusal too.
////
//// **What waking is available on a given target.** `WakesIdle` is
//// granted only when the target is not a subagent, whatever the policy
//// permits. That is the one cap the operator does not own, and the
//// reason is structural rather than postural — see "Owner, target, and
//// the lifetime that bounds them" below.
////
//// ## Owner, target, and the lifetime that bounds them
////
//// A schedule belongs to the strand that created it
//// (`client/schedule.Owner`) and fires onto a `target` that may be that
//// strand or a strand it spawned. Both halves of that sentence close a
//// hole.
////
//// **Ownership** makes a schedule retirable. `list` and `cancel` are
//// keyed on the creator, so a parent can cancel a heartbeat it set onto
//// a child that has already settled — where before, a schedule was
//// cancellable only by the strand it fired onto, and a subagent's own
//// heartbeat became uncancellable the moment that subagent finished,
//// holding a session-wide ceiling slot for the rest of the session
//// (issue #163). It also answers "whose text is this" for the fire:
//// `client/schedule.origin_of` reads the owner, and a parent-owned
//// heartbeat firing on a child says so rather than telling the child it
//// scheduled the thing itself.
////
//// **The target's lifetime** makes it bounded. `reaping_hooks` retires
//// every schedule keyed to a strand whose brief has just ended, and
//// `client/schedulescan` refuses to fire onto a target the ledger says
//// is reaped or whose brief has settled — so neither a lost reap nor an
//// operator's `[[schedule]]` can keep a finished child's clock running.
//// That is also why no schedule onto a subagent may wake it: a subagent
//// has exactly one run, so a fresh one after its brief ended would
//// extend a child's life after its work finished and outside the spawn
//// budget its parent was held to.
////
//// What ownership deliberately does *not* move is a schedule's
//// identity, which stays `{target, name}` in every key shape. An
//// occurrence is a fact about the target's timeline, and two schedules
//// sharing that pair would share a fired-mark whoever owned them —
//// which is why `name_is_free` is per target rather than per owner.
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
import client/cron
import client/schedule.{type Policy, type Schedule}
import client/schedulescan
import core/clock
import core/ids.{type OpId}
import core/json.{type JsonValue}
import gleam/bool
import gleam/erlang/process.{type Name}
import gleam/int
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import gleam/string
import runtime/api.{type Runtime}
import runtime/effects
import runtime/lineage
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
    max_in_seconds: schedule.max_in_seconds,
    max_max_fires: schedule.max_max_fires,
    max_expires_after_s: schedule.max_expires_after_s,
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
    cancel: fn(ctx: Ctx, name, target) { door.cancel(ctx.strand, name, target) },
  )
}

/// The same three operations keyed on a strand name rather than on a
/// `tools/tool.Ctx`.
///
/// Two doors reach this store — the `schedule_*` tools and the
/// `schedule.*` code-mode capabilities — and a code-mode call has no
/// `Ctx` to offer, only the strand its execution belongs to. That strand
/// is the **caller**, and it is the whole of the authority question
/// here: it is who may create, who owns what is created, and who may
/// list and cancel. A target, where one is given, is checked against it.
/// So the shared implementation is keyed on the caller, and `seam` is
/// the thin adapter for callers that happen to hold a `Ctx`.
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
    /// The caller, the schedule's name, and the strand it fires onto —
    /// `None` for the caller's own, which is what every cancellation
    /// meant before a schedule could target anything else.
    cancel: fn(String, String, Option(String)) ->
      Result(Nil, schedule_tool.Refusal),
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
    cancel: fn(strand, name, target) {
      use runtime <- with_runtime(wiring)
      cancel(wiring, runtime, strand, name, on: target)
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
  caller: String,
  request: schedule_tool.Request,
) -> Result(schedule_tool.Created, schedule_tool.Refusal) {
  let Wiring(policy:, operator_schedules:, scanner:, ..) = wiring

  // An absent target means the caller's own strand, which is what every
  // schedule this door could create used to mean. Resolving it here and
  // once is what lets everything below — the ownership check, the key,
  // the collision check, the wake cap — read one strand rather than an
  // `Option` each.
  let target = option.unwrap(request.target, caller)
  use Nil <- result.try(schedulable(runtime, caller, target))
  use timing <- result.try(requested_timing(runtime, request))

  // Two caps on `wake`, in this order, and they answer different
  // questions. The policy is the operator's say over the door; the
  // target's own nature is not negotiable by any policy — a subagent has
  // one run, and waking a settled one re-opens a strand whose task
  // ended. Neither vetoes the call: a model that asked to wake gets a
  // schedule that steers and a result that says so, because refusing
  // instead would teach it to retry against a wall that will not move
  // for anything it can do.
  let wake =
    schedule.wake_under(policy, requested: requested_wake(request.wake))
    |> wake_onto(target)
  use built <- result.try(
    schedule.build(
      name: request.name,
      target:,
      owner: schedule.StrandOwned(strand: caller),
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
    target,
    built.name,
  ))

  // The write is the name's only real claim. `expected: None` commits
  // only while the cell is absent, so two creates racing through the
  // checks above cannot both land: the loser hears `NameTaken` instead
  // of watching its schedule be replaced by the other's body (#162).
  use _seq <- result.try(
    api.put_reserved_fact_expecting(
      runtime,
      schedule.config_key(strand: target, name: built.name),
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
    target:,
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

// Who a caller may schedule onto: itself, or a strand it spawned.
//
// The rule is the Agency's addressing rule — a strand addresses its
// parent or a descendant — narrowed to the half that makes sense for a
// durable schedule, and answered from the same place: the lineage
// ledger, through `client/agency.owns`. Nothing about the *shape* of a
// name is evidence here. `sub:main/worker` says a name was minted by an
// Agency and not by whom, and a sibling's name looks exactly like a
// child's; only the recorded parent edge distinguishes them, which is
// why the check is a ledger read and not a string test.
//
// It fails closed at every step, because `owns` does: an unreadable
// ledger, a target with no cell, a cell that will not decode all answer
// `False` and land here as a refusal. A schedule is durable authority
// over another strand's context, so "we could not tell" has to mean no.
//
// Scheduling *upward* is not admitted, and the asymmetry is deliberate:
// a parent extends a child's liveness, which it already controls and
// pays for, while a child scheduling onto its parent would put text into
// the context of a strand that outranks it — `client/agency`'s "a report
// into a finished parent is refused" is the same ruling one door along.
fn schedulable(
  runtime: Runtime,
  caller: String,
  target: String,
) -> Result(Nil, schedule_tool.Refusal) {
  use <- bool.guard(when: target == caller, return: Ok(Nil))
  case agency.owns(runtime, ancestor: caller, strand: target) {
    True -> Ok(Nil)
    False ->
      Error(schedule_tool.Invalid(
        reason: "a strand may schedule a heartbeat onto itself or onto a "
        <> "strand it spawned, and \""
        <> target
        <> "\" is neither. If you meant a subagent of yours, give the "
        <> "strand name its handle carries; otherwise schedule it here and "
        <> "act on it yourself.",
      ))
  }
}

// What `wake` becomes once the target has had its say.
//
// A subagent is never woken, whatever the operator's policy permits and
// whatever the call asked for. It has exactly one run — the brief its
// parent spawned it with — so there is no idle-and-waiting-for-work
// state for a fresh run to fill: a `WakesIdle` schedule on one would
// re-open a run on a driver whose task had already ended, extending a
// child's life after its work finished and outside the spawn budget its
// parent was held to. That is issue #163's sharp half, and it is a
// property of the target rather than of who asked, so it is capped here
// rather than left to the policy.
//
// What such a schedule can still do is the useful part: steer the
// child's open run while it is working, and hold when it is not. The
// caller reads which it got from `Created.wake`, exactly as it already
// does under a `steer` policy.
fn wake_onto(wake: schedule.Wake, target: String) -> schedule.Wake {
  case agency.is_subagent(target), wake {
    False, schedule.WakesIdle -> schedule.WakesIdle
    False, schedule.SteersOnly -> schedule.SteersOnly
    True, schedule.WakesIdle | True, schedule.SteersOnly -> schedule.SteersOnly
  }
}

// The four shapes a tool argument can carry honestly, turned into the
// one `Timing` the store works in.
//
// This is the seam's job rather than the door's because everything it
// needs is on this side: `client/schedule` owns the single RFC3339
// parser, `client/cron` owns the single cron grammar, the defaulted
// expiry a recurring schedule always gets is `client/schedule`'s pair of
// constants, and the clock a relative one-shot resolves against is the
// session's injected one.
//
// **`In` is the only arm that reads a clock**, and it reads the same
// `runtime/effects.clock` every other instant in the session comes from
// — never a wall-clock call of its own — so a simulated session resolves
// it on logical time exactly as the scanner ticks on logical time. The
// model cannot do this arithmetic itself: the system prompt carries no
// date, which is why `In` exists at all.
fn requested_timing(
  runtime: Runtime,
  request: schedule_tool.Request,
) -> Result(schedule.Timing, schedule_tool.Refusal) {
  case request.timing {
    schedule_tool.Every(seconds:) -> {
      use expiry <- result.try(requested_expiry(request))
      Ok(schedule.Interval(seconds:, expiry:))
    }

    schedule_tool.Cron(expression:) -> {
      use expiry <- result.try(requested_expiry(request))
      use parsed <- result.try(
        cron.parse(expression)
        |> result.map_error(fn(reason) {
          schedule_tool.Invalid(reason: "cron: " <> reason)
        }),
      )
      Ok(schedule.Cron(expression: parsed, expiry:))
    }

    schedule_tool.At(instant:) ->
      schedule.parse_instant(instant)
      |> result.map(fn(at) { schedule.OneShot(at:) })
      |> result.map_error(fn(reason) { schedule_tool.Invalid(reason:) })

    schedule_tool.In(seconds:) -> {
      let #(now_ms, _clock) = clock.read(runtime.effects.clock)
      schedule.relative_instant(now_s: now_ms / 1000, in_seconds: seconds)
      |> result.map(fn(at) { schedule.OneShot(at:) })
      |> result.map_error(fn(reason) { schedule_tool.Invalid(reason:) })
    }
  }
}

// The bounds a recurring schedule expires under: what the request asked
// for, defaulted where it asked for nothing.
//
// Nothing is *checked* here. Both values go on to `schedule.build`,
// whose `checked_expiry` holds them to exactly the ceilings a
// `[[schedule]]` table is held to, through the same constants — so a
// request asking for a wider bound than the build allows is refused by
// the constructor rather than by a second copy of the limit living at
// this door. The tool door has already refused either bound beside a
// one-shot, so an absent value here means "default", never "not
// applicable".
fn requested_expiry(
  request: schedule_tool.Request,
) -> Result(schedule.Expiry, schedule_tool.Refusal) {
  Ok(schedule.Expiry(
    max_fires: option.unwrap(request.max_fires, schedule.default_max_fires),
    expires_after_s: option.unwrap(
      request.expires_after_s,
      schedule.default_expires_after_s,
    ),
  ))
}

fn room_for_one_more(
  existing: List(#(String, Schedule)),
) -> Result(Nil, schedule_tool.Refusal) {
  // "Are there this many or more" needs only the elements up to the
  // bound, not a full walk to count them (lint R5) — the same idiom
  // `client/schedule.recurring_expired` uses for its own ceiling.
  case list.drop(existing, schedule.max_model_schedules - 1) {
    [] -> Ok(Nil)
    [_at_the_limit, ..] ->
      Error(schedule_tool.CeilingReached(limit: schedule.max_model_schedules))
  }
}

// A name is taken if *either* store already has it on the target. The
// operator's half matters as much as the model's: both halves feed one
// scanner, which derives a fire-mark from `{target, name}` alone, so a
// duplicate would make two schedules share a mark and each suppress the
// other's fires. Uniqueness is per *target* and not per owner for
// exactly that reason — the mark is a fact about the target's timeline,
// so two owners cannot be allowed to share one. The model is told the
// name is taken without being told whose it is: an operator's config is
// not the model's to enumerate, and neither is a sibling's.
fn name_is_free(
  existing: List(#(String, Schedule)),
  operator_schedules: List(Schedule),
  target: String,
  name: String,
) -> Result(Nil, schedule_tool.Refusal) {
  let claims = fn(sched: Schedule) {
    sched.target == target && sched.name == name
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

// Every schedule the caller *owns*, wherever it fires.
//
// Owner rather than target, and that is the whole of the change issue
// #163 asked for on this side: a parent that scheduled onto a child has
// to be able to see that schedule, because it is the only strand that
// can cancel it and the child may already have settled. The mirror holds
// too — a child does not see the schedules its parent set onto it. It
// cannot retire them, so listing them would offer it a name it can only
// fail to cancel.
fn listing(
  runtime: Runtime,
  caller: String,
) -> Result(List(schedule_tool.Listed), schedule_tool.Refusal) {
  use live <- result.try(live_schedules(runtime))
  live
  |> list.filter(fn(pair) {
    let #(_key, sched) = pair
    owned_by(sched, caller)
  })
  |> list.map(fn(pair) {
    let #(_key, sched) = pair
    listed(runtime, sched)
  })
  |> Ok
}

// Whether one caller owns one schedule. An operator's is nobody's, which
// is what keeps `[[schedule]]` tables out of every listing and out of
// every cancellation.
fn owned_by(sched: Schedule, caller: String) -> Bool {
  case sched.owner {
    schedule.OperatorOwned -> False
    schedule.StrandOwned(strand:) -> strand == caller
  }
}

fn listed(runtime: Runtime, sched: Schedule) -> schedule_tool.Listed {
  schedule_tool.Listed(
    name: sched.name,
    target: sched.target,
    when: describe_timing(sched.timing),
    wake: granted_wake(sched.wake),
    fired: fire_count(runtime, sched),
    body: sched.body,
  )
}

/// How many times one schedule has fired, counted off its durable marks.
///
/// A failed read reports zero rather than propagating: the count is
/// context for a model deciding what to cancel, and a listing that fails
/// entirely because one counter could not be read is worse than a listing
/// with one optimistic number in it. Nothing branches on this value.
///
/// ## Examples
///
/// ```gleam
/// // scheduleseam.fire_count(runtime, sched)
/// ```
///
pub fn fire_count(runtime: Runtime, sched: Schedule) -> Int {
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
  caller: String,
  name: String,
  on requested_target: Option(String),
) -> Result(Nil, schedule_tool.Refusal) {
  let target = option.unwrap(requested_target, caller)
  let key = schedule.config_key(strand: target, name:)
  use live <- result.try(live_schedules(runtime))

  // Two ways to hear `NotFound`, deliberately indistinguishable: there
  // is no such cell, or there is one and it is not this caller's. A
  // model that misremembers a name should hear about it instead of
  // believing it has tidied up — and one that guesses at a sibling's
  // name must not learn from the answer that the sibling has a schedule
  // by that name. A schedule the *operator* configured has no cell in
  // this store at all, so naming one lands on the first arm, which is
  // the right answer for the right reason.
  use Nil <- result.try(case list.key_find(live, key) {
    Error(Nil) -> Error(schedule_tool.NotFound(name:))
    Ok(sched) ->
      case owned_by(sched, caller) {
        True -> Ok(Nil)
        False -> Error(schedule_tool.NotFound(name:))
      }
  })
  use Nil <- result.try(retire(runtime, target, name))

  // Nothing breaks without this — the next tick would find the cell gone
  // on its own — but a cancelled schedule that fires once more before the
  // scanner notices reads as the cancel having failed.
  schedulescan.poke(wiring.scanner)
  Ok(Nil)
}

/// Retires one schedule's whole durable footprint — its fired-marks, its
/// observation instant and its config cell — as the host does on cancel.
/// Public so an operator-facing surface ends a schedule exactly as the
/// model door does, rather than by a second deletion order that could get
/// the crash story wrong.
///
/// Everything one schedule durably owns, removed: its fired-marks, its
/// observation instant, and last its config cell.
///
/// **All three, because a name is reusable afterwards.** The marks and
/// the seen cell are keyed on `{target, name}` — the schedule's identity,
/// not its creation — so a name recreated over a surviving clock
/// inherits it: a one-shot at the same instant reads as `AlreadyFired`
/// for the life of the session, and a recurring schedule whose 1000
/// marks are still there expires on the first tick that sees it. That is
/// the third leg of issue #163, and cancelling the whole footprint is
/// the ruling rather than minting a per-creation nonce, because the
/// nonce would put a value nobody reads into every key shape in the
/// namespace.
///
/// The order is the crash story. Three commits rather than one, because
/// the keys share no prefix (`config/`, `seen/` and `fired/` are
/// disjoint corners of `schedule/` by construction), so the config cell
/// goes **last**: a fault partway through leaves the schedule live with
/// a reset count and a caller told the cancel failed, which a retry
/// finishes. Deleting the config cell first would answer the caller with
/// a failure over a schedule that was in fact gone, leaving its clock
/// behind for the next schedule to inherit — precisely the bug this
/// function exists to prevent.
///
/// ## Examples
///
/// ```gleam
/// // scheduleseam.retire(runtime, "main", "poll")
/// ```
///
pub fn retire(
  runtime: Runtime,
  target: String,
  name: String,
) -> Result(Nil, schedule_tool.Refusal) {
  use _marks <- result.try(
    api.delete_reserved_prefix(
      runtime,
      prefix: schedule.fired_key_prefix(strand: target, name:),
    )
    |> result.map_error(unavailable),
  )
  use Nil <- result.try(
    api.delete_reserved_fact(runtime, schedule.seen_key(strand: target, name:))
    |> result.map_error(unavailable),
  )
  api.delete_reserved_fact(runtime, schedule.config_key(strand: target, name:))
  |> result.map_error(unavailable)
}

// --- reaping a settled strand's schedules ---------------------------------

/// Wraps a hook record so a run's end retires every schedule that fires
/// onto the strand whose run it was.
///
/// The shape is `client/agency.reaping_hooks` and the constraint is
/// identical: the only work done on the driver process is one
/// `process.spawn_unlinked`, because `Hooks.run_end` fires inside the
/// driver's own loop before any `actor.continue` — a hook that read a
/// register there would be a call from the driver into the writer, and a
/// hook that waited would stop it serving `Nudge`, `RequestAbort` and
/// `PollTick`. Every read and every delete a reap performs happens on
/// the spawned process.
///
/// It composes with the Agency's rather than replacing it: both wrap the
/// `run_end` they are given, so `client/serve` pipes one into the other
/// and the two reaps are independent. This one is deliberately the
/// narrower of the pair — the Agency ends *children*, this one ends
/// *schedules* — and it runs for every strand whose brief a lineage cell
/// records, which is exactly the set of strands that have one run and
/// then stop.
///
/// ## Examples
///
/// ```gleam
/// // effects.Effects(..built, hooks:
/// //   agency.reaping_hooks(built.hooks, agency_config)
/// //   |> scheduleseam.reaping_hooks(wiring))
/// ```
///
pub fn reaping_hooks(hooks: effects.Hooks, wiring: Wiring) -> effects.Hooks {
  effects.Hooks(..hooks, run_end: fn(operation) {
    let _reaper = process.spawn_unlinked(fn() { reap_run(wiring, operation) })
    hooks.run_end(operation)
  })
}

// Why a settled strand's schedules go rather than surviving it.
//
// A subagent has one run. When it ends, every schedule keyed to that
// strand is a standing claim on a timeline that has stopped: the
// scanner would tick for it, a `SteersOnly` one would hold on every
// occurrence forever, and each would hold a `max_model_schedules` slot
// against a session that can never use it again (#163). So the reap is
// how a slot is actually freed, and `client/schedulescan`'s
// settled-target check is the belt to this braces — it stops a fire
// between the run ending and this process finishing, and covers the
// strand whose cells this reap could not read.
//
// Both owners' schedules go, the parent's onto this child included. A
// parent's heartbeat about a child cannot outlive the child's work: the
// occurrence it would inject onto is one nobody will ever read, and the
// parent is told nothing because it is not owed a message — it can see
// the child settled through the handle it already holds.
fn reap_run(wiring: Wiring, operation: OpId) -> Nil {
  case wiring.runtime() {
    Error(Nil) -> Nil
    Ok(runtime) ->
      case ended_strands(runtime, operation) {
        [] -> Nil
        strands -> {
          list.each(strands, fn(strand) { retire_strand(runtime, strand) })

          // The scanner holds no list across ticks, so it needs no
          // telling — but a heartbeat that fires once more after the
          // strand it watches has settled is the visible symptom this
          // reap exists to remove, and the poke is one message.
          schedulescan.poke(wiring.scanner)
        }
      }
  }
}

// Every strand whose *own* brief this operation is.
//
// The ledger is read whole, one bounded prefix scan, exactly as the
// Agency reads it: the session's live strand count bounds it, and one
// listing beats a point read per candidate. The key decides the strand
// rather than the payload's copy of it, because the key is what the
// prefixes below are built from and a disagreement between the two must
// not be able to point a delete at another strand's cells.
//
// A cell that will not decode is dropped, which is this function's
// fail-closed direction: it reaps nothing rather than guessing at a
// strand name, and `client/schedulescan` still refuses to fire onto a
// strand whose cell it cannot read.
fn ended_strands(runtime: Runtime, operation: OpId) -> List(String) {
  case api.reserved_facts(runtime, prefix: lineage.key_prefix) {
    Error(_unreadable) -> []
    Ok(cells) ->
      list.filter_map(cells, fn(pair) {
        let #(key, payload) = pair
        use strand <- result.try(lineage.strand_of_key(key))
        use cell <- result.try(
          lineage.decode(payload) |> result.replace_error(Nil),
        )
        case cell.brief == operation {
          True -> Ok(strand)
          False -> Error(Nil)
        }
      })
  }
}

// One strand's whole scheduling footprint, one commit per prefix.
//
// A failed delete is dropped rather than retried: the reap is a
// best-effort tidy of a strand that has stopped, the scanner refuses to
// fire onto a settled target whether this ran or not, and there is
// nobody to report to on an unlinked process. What it costs is a
// ceiling slot held until the session ends, which is the state this
// whole change improves on rather than the one it must guarantee away.
fn retire_strand(runtime: Runtime, strand: String) -> Nil {
  list.each(schedule.strand_prefixes(strand:), fn(prefix) {
    let _deleted = api.delete_reserved_prefix(runtime, prefix:)
    Nil
  })
}

// --- shared reads ---------------------------------------------------------

/// Every live model-created schedule in the session, each paired with the
/// key of the cell it was read from. Public for the host's own listings;
/// the model door filters this by owner before showing it.
///
/// Every live model-created schedule in the session, keyed by its cell.
/// A cell that does not decode is dropped rather than failing the read:
/// `client/schedule.decode` refuses a schedule an older build stored
/// under bounds this one has since tightened, and anything else that ever
/// appears under this prefix reads the same way. Both are "not a schedule
/// that runs today", which is exactly what every caller here is asking.
///
/// The drop is also why `create` cannot let this read decide a name: a
/// cell dropped here is a name reported free, and only the claiming write
/// sees what is actually in the store.
///
/// ## Examples
///
/// ```gleam
/// // scheduleseam.live_schedules(runtime)
/// ```
///
pub fn live_schedules(
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
/// // scheduleseam.describe_timing(cron_timing)
/// //   == "cron \"0 9 * * 1-5\" UTC, at most 1000 times"
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

    // The expression as it was written, quoted, and `UTC` said out loud:
    // a caller reading `0 9 * * 1-5` back has no other way to know which
    // 09:00 it got, and this module is the last place that can say so
    // before the string reaches a model.
    schedule.Cron(expression:, expiry:) ->
      "cron \""
      <> cron.source(expression)
      <> "\" UTC, at most "
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
