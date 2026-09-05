//// The model-facing scheduling door against a real session store.
////
//// The seam is where every bound `tools/schedule` merely *states* is
//// actually enforced, so these tests go through the seam's own closures
//// rather than through `client/schedule.build` directly: a bound that is
//// checked in the constructor but never reached from the door would pass
//// a unit test and let anything through in practice.
////
//// A real runtime over an in-memory session, because the door's whole job
//// is writing and reading durable reserved cells. No scanner is started:
//// what the scanner does with these cells is `schedulescan_test`'s
//// subject, and `poke` is deliberately safe to call when no scanner is
//// registered — which is exactly the state these tests run in, and which
//// therefore gets pinned here for free.

import broker/broker
import broker/exec
import broker/policy
import client/cron
import client/schedule
import client/scheduleseam
import core/clock
import core/ids
import core/json
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import machine/strand as machine_strand
import provider/stream
import runtime/api
import runtime/effects
import runtime/lineage
import session/session
import support/addresses
import tools/schedule as schedule_tool
import tools/tool

// --- the rig ---------------------------------------------------------------

type Rig {
  Rig(
    runtime: api.Runtime,
    seam: schedule_tool.Schedules,
    /// Kept so the reaping-hook test can build the same hook wrapper
    /// `client/serve` composes, over the very wiring these calls go
    /// through.
    wiring: scheduleseam.Wiring,
  )
}

fn harness(
  policy_position: schedule.Policy,
  operator: List(schedule.Schedule),
) -> Result(Rig, String) {
  use opened <- result.try(
    session.open_memory(clock.fixed(at: 0))
    |> result.replace_error("the memory session did not open"),
  )
  use entropy <- result.try(start_entropy())
  let configuration =
    machine_strand.StrandConfiguration(
      model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
      thinking_level: machine_strand.ThinkingOff,
      active_tool_names: [],
    )
  use runtime <- result.try(
    api.open(
      opened,
      effects.Effects(
        clock: clock.fixed(at: 0),
        entropy:,
        timers: effects.real_timers(),
        provider: hanging_provider(),
        tools: refusing_tools(),
        hooks: effects.default_hooks(),
      ),
      api.default_options(configuration),
    )
    |> result.map_error(string.inspect),
  )
  // A name nothing is registered under: `poke` must tolerate it, which is
  // the restarting-scanner case in production.
  let scanner = addresses.new()
  let wiring =
    scheduleseam.Wiring(
      runtime: fn() { Ok(runtime) },
      policy: policy_position,
      operator_schedules: operator,
      scanner:,
    )
  Ok(Rig(runtime:, seam: scheduleseam.seam(wiring), wiring:))
}

fn stop(rig: Rig) -> Nil {
  process.kill(rig.runtime.tree.supervisor)
}

fn ctx(strand: String) -> tool.Ctx {
  tool.Ctx(
    workspace: "/tmp/loom-scheduleseam-test",
    strand:,
    op_id: an_op(),
    step_id: "turn-1:tools",
    source_index: 0,
    base_policy: policy.workspace_default("/tmp/loom-scheduleseam-test"),
    grants: [],
    demand: exec.FullEnforcement,
    env: [],
    clock: clock.fixed(at: 0),
    filesystem: dead_filesystem(),
    blob_root: "/tmp/loom-scheduleseam-test/.blobs",
    clear_call: fn(_spec, _events) { Error(broker.BrokerUnavailable) },
    raise_refusal: tool.no_raise(),
  )
}

fn every(
  name: String,
  seconds: Int,
  wake: schedule_tool.Wake,
) -> schedule_tool.Request {
  request(name, schedule_tool.Every(seconds:), wake)
}

// One request with the two expiry arguments left at their defaults,
// which is what every test that is not about the bounds wants.
fn request(
  name: String,
  timing: schedule_tool.RequestedTiming,
  wake: schedule_tool.Wake,
) -> schedule_tool.Request {
  schedule_tool.Request(
    name:,
    target: None,
    timing:,
    max_fires: None,
    expires_after_s: None,
    wake:,
    body: "look at it",
  )
}

// The same request aimed at another strand, which is the only thing the
// ownership rules below actually turn on.
fn every_onto(
  name: String,
  target: String,
  wake: schedule_tool.Wake,
) -> schedule_tool.Request {
  schedule_tool.Request(..every(name, 60, wake), target: Some(target))
}

// A child of `parent`, as the ledger records one. The strand itself is
// never started: the seam asks the ledger who spawned whom and nothing
// else, so a planted cell is the whole of what a descendant is here —
// and a test that had to start a real driver could not exercise the
// after-it-settles cases at all.
fn plant_child(
  rig: Rig,
  child: String,
  parent parent: String,
  brief brief: ids.OpId,
) -> Nil {
  let assert Ok(Nil) =
    api.put_reserved_fact(
      rig.runtime,
      lineage.register_key(child),
      lineage.encode(lineage.Lineage(
        strand: child,
        parent:,
        depth: 1,
        minted_by: lineage.CallSite(
          operation: brief,
          step_id: "turn-1:tools",
          source_index: 0,
        ),
        brief:,
        tools: [],
        deadline: None,
        detached: False,
        reaped: False,
      )),
    )
    as "the ledger must accept a cell written by the harness"
  Nil
}

// --- creating --------------------------------------------------------------

// A server booted with no [schedules] table runs the default policy, and
// under it a model's request to wake is honoured as far as the operator
// allowed: the schedule is created, it steers, and the result says so.
// This is the seam's half of the #161 ruling — the default never hands a
// model a schedule that can start a run on an idle strand.
pub fn the_default_policy_caps_a_wake_request_to_steer_test() {
  let assert Ok(rig) = harness(schedule.default_policy, [])
    as "the harness must boot"
  let assert Ok(created) =
    rig.seam.create(ctx("main"), every("poll", 300, schedule_tool.WakesIdle))
    as "a wake request under the default must still be created"
  assert created.wake == schedule_tool.SteersOnly
  let assert Ok([listed]) = rig.seam.list(ctx("main"))
    as "the capped schedule must be listed"
  assert listed.wake == schedule_tool.SteersOnly
}

pub fn a_created_schedule_is_durable_and_listed_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Ok(created) =
    rig.seam.create(ctx("main"), every("poll", 300, schedule_tool.WakesIdle))
    as "an ordinary schedule must be created"
  assert created.name == "poll"
  assert created.wake == schedule_tool.WakesIdle

  // Durable: the reserved cell is there, under the config prefix, and
  // decodes back to a schedule targeting the creating strand.
  let assert Ok(cells) =
    api.reserved_facts(rig.runtime, prefix: schedule.config_key_prefix)
    as "the config prefix must be readable"
  let assert [#(key, value)] = cells
    as "exactly one cell must have been written"
  assert key == schedule.config_key(strand: "main", name: "poll")
  let assert Ok(stored) = schedule.decode(value)
    as "the stored cell must decode"
  assert stored.target == "main"

  let assert Ok([listed]) = rig.seam.list(ctx("main"))
    as "the creating strand must see its own schedule"
  assert listed.name == "poll"
  assert listed.fired == 0
  stop(rig)
}

// The door has no `target` argument, so a strand can only ever schedule
// onto itself — and therefore only ever sees its own.
pub fn a_schedule_is_private_to_the_strand_that_made_it_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesSteer, [])
    as "the harness must boot"
  let assert Ok(_created) =
    rig.seam.create(ctx("main"), every("mine", 60, schedule_tool.SteersOnly))
    as "main must be able to schedule"

  assert rig.seam.list(ctx("review")) == Ok([])
  let assert Ok([_own]) = rig.seam.list(ctx("main"))
    as "the creating strand still sees it"
  stop(rig)
}

// --- who may schedule onto whom --------------------------------------------

// The case the design ruling named as the motivating one for `wake` and
// could not reach until ownership existed (#154): a parent watching a
// subagent it started. The child is a descendant per the ledger, so the
// target is admitted; the schedule is the *parent's*, so the parent sees
// it in its own listing with the target named.
pub fn a_parent_schedules_onto_a_child_and_owns_it_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let child = "sub:main/reviewer-abc123"
  plant_child(rig, child, parent: "main", brief: an_op())

  let assert Ok(created) =
    rig.seam.create(
      ctx("main"),
      every_onto("watch", child, schedule_tool.SteersOnly),
    )
    as "a parent must be able to schedule onto a child it spawned"
  assert created.target == child

  // The cell is keyed on the *target*, which is what keeps a fired-mark
  // a fact about the strand the occurrence lands on.
  let assert Ok([#(key, value)]) =
    api.reserved_facts(rig.runtime, prefix: schedule.config_key_prefix)
    as "exactly one cell must have been written"
  assert key == schedule.config_key(strand: child, name: "watch")
  let assert Ok(stored) = schedule.decode(value) as "the cell must decode"
  assert stored.target == child
  assert stored.owner == schedule.StrandOwned(strand: "main")

  // Listed by owner, not by target: the parent is the only strand that
  // can cancel it, so it is the only strand that may see it.
  let assert Ok([listed]) = rig.seam.list(ctx("main"))
    as "the owner must see the schedule it made"
  assert listed.name == "watch"
  assert listed.target == child
  assert rig.seam.list(ctx(child)) == Ok([])
  stop(rig)
}

// The lineage check is the whole authorization, and it fails closed: a
// strand that merely *looks* like a subagent, or one spawned by somebody
// else, is refused. Nothing is written, because the refusal happens
// before the store is touched.
pub fn a_target_that_is_not_a_descendant_is_refused_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"

  // A sibling: spawned by `other`, not by `main`. Its name is shaped
  // exactly like a child of `main`'s would be, which is precisely why
  // the answer comes from the ledger rather than from the name.
  let sibling = "sub:main/impostor-abc123"
  plant_child(rig, sibling, parent: "other", brief: an_op())
  let assert Error(schedule_tool.Invalid(reason:)) =
    rig.seam.create(
      ctx("main"),
      every_onto("steal", sibling, schedule_tool.SteersOnly),
    )
    as "a strand nobody here spawned must not be schedulable onto"
  assert string.contains(reason, "spawned")

  // And a strand with no lineage cell at all: no fact, no permission.
  let assert Error(schedule_tool.Invalid(..)) =
    rig.seam.create(
      ctx("main"),
      every_onto("steal", "review", schedule_tool.SteersOnly),
    )
    as "a root strand is nobody's descendant"

  // Upward is refused too: a child may not put text in its parent.
  let child = "sub:main/worker-abc123"
  plant_child(rig, child, parent: "main", brief: an_op())
  let assert Error(schedule_tool.Invalid(..)) =
    rig.seam.create(
      ctx(child),
      every_onto("up", "main", schedule_tool.SteersOnly),
    )
    as "a child must not schedule onto its parent"

  let assert Ok([]) =
    api.reserved_facts(rig.runtime, prefix: schedule.config_key_prefix)
    as "a refused create must leave no cell"
  stop(rig)
}

// The blunt gate is gone: a subagent may schedule onto itself, because
// the schedule now dies with it rather than outliving it uncancellably.
// What it cannot get is waking — one run, and a fresh one after that run
// ended is the security-shaped half of #163 — so `wake` comes back
// `SteersOnly` even under the most permissive policy an operator has.
pub fn a_subagent_may_schedule_onto_itself_but_never_wakes_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let child = "sub:main/worker-abc123"
  plant_child(rig, child, parent: "main", brief: an_op())

  let assert Ok(created) =
    rig.seam.create(ctx(child), every("poll", 60, schedule_tool.WakesIdle))
    as "a subagent must be able to schedule onto itself"
  assert created.wake == schedule_tool.SteersOnly

  // The durable cell carries the capped answer, not merely the reply:
  // the scanner reads the cell and would otherwise wake anyway.
  let assert Ok([#(_key, value)]) =
    api.reserved_facts(rig.runtime, prefix: schedule.config_key_prefix)
    as "one cell must have been written"
  let assert Ok(stored) = schedule.decode(value) as "the cell must decode"
  assert stored.wake == schedule.SteersOnly
  assert stored.owner == schedule.StrandOwned(strand: child)
  stop(rig)
}

// The same cap from the other side, which is the one an operator's
// `wake` policy would otherwise reach: a parent asking to wake a child
// gets a steering schedule, because the property is about the target's
// single run and not about who asked.
pub fn a_child_targeting_schedule_never_wakes_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let child = "sub:main/reviewer-abc123"
  plant_child(rig, child, parent: "main", brief: an_op())

  let assert Ok(created) =
    rig.seam.create(
      ctx("main"),
      every_onto("watch", child, schedule_tool.WakesIdle),
    )
    as "the call must be honoured rather than refused"
  assert created.wake == schedule_tool.SteersOnly

  let assert Ok([#(_key, value)]) =
    api.reserved_facts(rig.runtime, prefix: schedule.config_key_prefix)
    as "one cell must have been written"
  let assert Ok(stored) = schedule.decode(value) as "the cell must decode"
  assert stored.wake == schedule.SteersOnly
  stop(rig)
}

// Cancellation is keyed on the owner and addressed by the target. The
// child cannot cancel what its parent set onto it — it could not tidy
// up if it tried, and a listing that offered it the name would be a
// promise the door cannot keep.
pub fn cancelling_a_child_targeting_schedule_needs_the_owner_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let child = "sub:main/reviewer-abc123"
  plant_child(rig, child, parent: "main", brief: an_op())
  let assert Ok(_created) =
    rig.seam.create(
      ctx("main"),
      every_onto("watch", child, schedule_tool.SteersOnly),
    )
    as "the parent must be able to schedule onto the child"

  // The target itself is not the owner.
  let assert Error(schedule_tool.NotFound(name: "watch")) =
    rig.seam.cancel(ctx(child), "watch", Some(child))
    as "the target must not be able to cancel its owner's schedule"

  // Nor is a name without its target the same schedule: `{caller, name}`
  // names nothing here.
  let assert Error(schedule_tool.NotFound(name: "watch")) =
    rig.seam.cancel(ctx("main"), "watch", None)
    as "a cancellation must address the strand the schedule fires onto"

  let assert Ok(Nil) = rig.seam.cancel(ctx("main"), "watch", Some(child))
    as "the owner must be able to cancel it, target named"
  assert rig.seam.list(ctx("main")) == Ok([])
  stop(rig)
}

// --- the policy ------------------------------------------------------------

// The sharp half of the argument: under `steer` a model may schedule, but
// nothing it schedules can start a run on an idle strand. The call is
// honoured rather than refused, and the result tells the truth.
pub fn a_steer_policy_grants_the_schedule_but_not_the_waking_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesSteer, [])
    as "the harness must boot"
  let assert Ok(created) =
    rig.seam.create(ctx("main"), every("poll", 60, schedule_tool.WakesIdle))
    as "asking to wake under a steer policy must not refuse the call"
  assert created.wake == schedule_tool.SteersOnly

  let assert Ok(cells) =
    api.reserved_facts(rig.runtime, prefix: schedule.config_key_prefix)
    as "the config prefix must be readable"
  let assert [#(_key, value)] = cells as "one cell must have been written"
  let assert Ok(stored) = schedule.decode(value) as "the cell must decode"
  // The durable cell, not merely the reply, carries the capped answer:
  // the scanner reads the cell and would otherwise wake anyway.
  assert stored.wake == schedule.SteersOnly
  stop(rig)
}

pub fn a_wake_policy_grants_the_waking_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Ok(created) =
    rig.seam.create(ctx("main"), every("poll", 60, schedule_tool.WakesIdle))
    as "asking to wake under a wake policy must be granted"
  assert created.wake == schedule_tool.WakesIdle
  stop(rig)
}

// --- the bounds ------------------------------------------------------------

pub fn the_door_enforces_the_shared_bounds_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Error(schedule_tool.Invalid(..)) =
    rig.seam.create(ctx("main"), every("a/b", 60, schedule_tool.SteersOnly))
    as "a name that breaks the fired-mark key must be refused at the door"
  let assert Error(schedule_tool.Invalid(..)) =
    rig.seam.create(
      ctx("main"),
      every("hot", schedule.min_interval_s - 1, schedule_tool.SteersOnly),
    )
    as "an interval under the floor must be refused at the door"
  let assert Error(schedule_tool.Invalid(..)) =
    rig.seam.create(
      ctx("main"),
      request(
        "when",
        schedule_tool.At(instant: "tomorrow"),
        schedule_tool.SteersOnly,
      ),
    )
    as "prose where RFC3339 belongs must be refused at the door"
  stop(rig)
}

pub fn creating_never_silently_replaces_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Ok(_first) =
    rig.seam.create(ctx("main"), every("poll", 60, schedule_tool.SteersOnly))
    as "the first must be created"
  let assert Error(schedule_tool.NameTaken(name: "poll")) =
    rig.seam.create(ctx("main"), every("poll", 120, schedule_tool.SteersOnly))
    as "reusing a name must refuse rather than overwrite"

  // The original survives untouched.
  let assert Ok([listed]) = rig.seam.list(ctx("main")) as "one schedule remains"
  assert string.contains(listed.when, "60")
  stop(rig)
}

// The refusal above is the pre-check's; this is the store's, and the
// store's is the one the property actually rests on. Reaching it from a
// serialized test needs a cell the pre-check cannot see, and an
// undecodable value under the config key is exactly that: `live_schedules`
// drops it with `filter_map`, so `name_is_free` reports the name free and
// nothing but the `expected: None` claim is left to refuse. That is the
// same state a concurrent create leaves behind — a cell written after
// another create read the prefix and before it wrote — with no second
// process needed to produce it.
pub fn the_claim_refuses_a_name_the_precheck_thinks_is_free_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let key = schedule.config_key(strand: "main", name: "poll")
  let planted = json.String("not a schedule")
  let assert Ok(Nil) = api.put_reserved_fact(rig.runtime, key, planted)
    as "the undecodable cell must be planted"

  // The pre-check really does pass: the listing cannot see this cell.
  assert rig.seam.list(ctx("main")) == Ok([])

  let assert Error(schedule_tool.NameTaken(name: "poll")) =
    rig.seam.create(ctx("main"), every("poll", 60, schedule_tool.SteersOnly))
    as "the claim must refuse a name the pre-check thought was free"

  // Refused, not overwritten: a blind write would have replaced this.
  let assert Ok([#(stored_key, stored)]) =
    api.reserved_facts(rig.runtime, prefix: schedule.config_key_prefix)
    as "exactly the planted cell must remain"
  assert stored_key == key
  assert stored == planted
  stop(rig)
}

// The collision that matters most, because nothing else can catch it: an
// operator schedule and a model schedule sharing {target, name} would
// derive the same fired-mark and suppress each other.
pub fn a_name_the_operator_already_used_is_taken_test() {
  let operator =
    schedule.Schedule(
      name: "nightly",
      target: "main",
      owner: schedule.OperatorOwned,
      timing: schedule.Interval(
        seconds: 3600,
        expiry: schedule.Expiry(max_fires: 24, expires_after_s: 604_800),
      ),
      wake: schedule.WakesIdle,
      body: "operator's own",
    )
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [operator])
    as "the harness must boot"
  let assert Error(schedule_tool.NameTaken(name: "nightly")) =
    rig.seam.create(ctx("main"), every("nightly", 60, schedule_tool.SteersOnly))
    as "a model must not shadow an operator's schedule on the same strand"

  // The same name on a different strand is a different fired-mark, so it
  // is free. A second top-level strand rather than a subagent, which the
  // lifetime gate refuses for its own reasons.
  let assert Ok(_elsewhere) =
    rig.seam.create(
      ctx("review"),
      every("nightly", 60, schedule_tool.SteersOnly),
    )
    as "the collision is per strand, not global"
  stop(rig)
}

pub fn the_ceiling_refuses_the_one_past_it_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  upto(schedule.max_model_schedules)
  |> list.each(fn(n) {
    let assert Ok(_created) =
      rig.seam.create(
        ctx("main"),
        every("poll-" <> int_to_string(n), 60, schedule_tool.SteersOnly),
      )
      as "every schedule up to the ceiling must be created"
  })
  let assert Error(schedule_tool.CeilingReached(limit:)) =
    rig.seam.create(
      ctx("main"),
      every("one-too-many", 60, schedule_tool.SteersOnly),
    )
    as "the schedule past the ceiling must be refused"
  assert limit == schedule.max_model_schedules

  // Cancelling one makes room again: the ceiling counts live schedules,
  // not schedules ever created.
  let assert Ok(Nil) = rig.seam.cancel(ctx("main"), "poll-1", None)
    as "cancelling must succeed"
  let assert Ok(_now_fits) =
    rig.seam.create(
      ctx("main"),
      every("one-too-many", 60, schedule_tool.SteersOnly),
    )
    as "a cancelled schedule must free its slot"
  stop(rig)
}

// --- cancelling ------------------------------------------------------------

pub fn cancelling_removes_it_from_the_listing_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Ok(_created) =
    rig.seam.create(ctx("main"), every("poll", 60, schedule_tool.SteersOnly))
    as "the schedule must be created"
  let assert Ok(Nil) = rig.seam.cancel(ctx("main"), "poll", None)
    as "cancelling must succeed"
  assert rig.seam.list(ctx("main")) == Ok([])
  stop(rig)
}

// Cancelling deletes the cell rather than writing a marker over it, so
// create-and-cancel churn under fresh names cannot grow the config prefix
// — which every tick of the scanner and every seam call reads whole
// (#164). The re-create at the end is the other half of the same ruling:
// `create` now commits on the cell's absence, so a marker left in place
// would hold the name for the life of the session however unreadable it
// was. This test asserts the representation, deliberately: an earlier
// build wrote a `json.Null` tombstone into the cell here and passed
// every test above it.
pub fn cancelling_leaves_no_cell_behind_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Ok(_created) =
    rig.seam.create(ctx("main"), every("poll", 60, schedule_tool.SteersOnly))
    as "the schedule must be created"
  let assert Ok(Nil) = rig.seam.cancel(ctx("main"), "poll", None)
    as "cancelling must succeed"

  assert api.reserved_facts(rig.runtime, prefix: schedule.config_key_prefix)
    == Ok([])

  let assert Ok(again) =
    rig.seam.create(ctx("main"), every("poll", 120, schedule_tool.SteersOnly))
    as "the freed name must be claimable again"
  assert again.name == "poll"
  stop(rig)
}

// Cancelling clears the schedule's whole durable footprint, not just the
// cell that says it exists. The marks and the observation instant are
// keyed on `{target, name}` — the schedule's identity rather than its
// creation — so a surviving clock would be inherited by the next
// schedule of the same name: a recurring one whose 1000 marks were still
// there would expire on the first tick that saw it, and a one-shot at the
// same instant would read `AlreadyFired` for the life of the session.
// That is the third leg of issue #163, and this test plants the marks by
// hand because reaching 1000 fires through the scanner is not a unit
// test.
pub fn cancelling_clears_the_marks_and_the_observation_instant_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Ok(_created) =
    rig.seam.create(ctx("main"), every("poll", 60, schedule_tool.SteersOnly))
    as "the schedule must be created"

  // The state a schedule that has been running for a while is in: marks
  // for the occurrences it spent, and the instant its window opened.
  [0, 60, 120]
  |> list.each(fn(occurrence) {
    let assert Ok(Nil) =
      api.put_reserved_fact(
        rig.runtime,
        schedule.fired_key(strand: "main", name: "poll", occurrence:),
        json.String("poll"),
      )
      as "a fired-mark must be plantable"
    Nil
  })
  let assert Ok(Nil) =
    api.put_reserved_fact(
      rig.runtime,
      schedule.seen_key(strand: "main", name: "poll"),
      schedule.seen_value(since_s: 0),
    )
    as "the observation instant must be plantable"
  assert marks(rig, "poll") == 3

  let assert Ok(Nil) = rig.seam.cancel(ctx("main"), "poll", None)
    as "cancelling must succeed"
  assert marks(rig, "poll") == 0
  assert api.fact(rig.runtime, schedule.seen_key(strand: "main", name: "poll"))
    == Ok(None)
  assert api.reserved_facts(rig.runtime, prefix: schedule.config_key_prefix)
    == Ok([])

  // And the recreated name starts from nothing: no marks, so the fire
  // count a model reads is zero rather than the dead schedule's three.
  let assert Ok(_again) =
    rig.seam.create(ctx("main"), every("poll", 60, schedule_tool.SteersOnly))
    as "the freed name must be claimable again"
  let assert Ok([listed]) = rig.seam.list(ctx("main"))
    as "the recreated schedule must be listed"
  assert listed.fired == 0
  stop(rig)
}

// A cancellation reaches only the schedule it names. The neighbouring
// name shares a string prefix with it (`poll` and `poll-2`), which is
// exactly the shape a prefix delete gets wrong if it does not stop at a
// path segment.
pub fn cancelling_leaves_a_similarly_named_schedules_marks_alone_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  [#("poll", 0), #("poll-2", 60)]
  |> list.each(fn(pair) {
    let #(name, occurrence) = pair
    let assert Ok(_created) =
      rig.seam.create(ctx("main"), every(name, 60, schedule_tool.SteersOnly))
      as "both schedules must be created"
    let assert Ok(Nil) =
      api.put_reserved_fact(
        rig.runtime,
        schedule.fired_key(strand: "main", name:, occurrence:),
        json.String(name),
      )
      as "a fired-mark must be plantable"
    Nil
  })

  let assert Ok(Nil) = rig.seam.cancel(ctx("main"), "poll", None)
    as "cancelling must succeed"
  assert marks(rig, "poll") == 0
  assert marks(rig, "poll-2") == 1
  let assert Ok([survivor]) = rig.seam.list(ctx("main"))
    as "the neighbour must survive"
  assert survivor.name == "poll-2"
  stop(rig)
}

// --- reaping a settled strand's schedules ----------------------------------

// The other half of the lifetime story. A subagent's run ends and every
// schedule keyed to that strand goes with it: its own, and the ones its
// parent set onto it. Without this the cells sit under the config prefix
// for the life of the session, holding ceiling slots against a timeline
// that has stopped (#163).
//
// The hook is called the way the driver calls it — with the operation
// that just ended — and does its work on a process it spawns, so the
// assertions poll rather than assuming the reap has already run.
pub fn a_run_end_reaps_that_strands_schedules_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let child = "sub:main/worker-abc123"
  let brief = an_op()
  plant_child(rig, child, parent: "main", brief:)

  // One the child made for itself, one the parent made onto it, and one
  // of the parent's own — which must survive, since the parent's run has
  // not ended.
  let assert Ok(_own) =
    rig.seam.create(ctx(child), every("mine", 60, schedule_tool.SteersOnly))
    as "the child must be able to schedule onto itself"
  let assert Ok(_watch) =
    rig.seam.create(
      ctx("main"),
      every_onto("watch", child, schedule_tool.SteersOnly),
    )
    as "the parent must be able to schedule onto the child"
  let assert Ok(_parents) =
    rig.seam.create(ctx("main"), every("own", 60, schedule_tool.SteersOnly))
    as "the parent must be able to schedule onto itself"

  // The child's schedules leave marks and an observation instant behind
  // too, and all of it is part of the footprint that goes.
  let assert Ok(Nil) =
    api.put_reserved_fact(
      rig.runtime,
      schedule.fired_key(strand: child, name: "mine", occurrence: 0),
      json.String("mine"),
    )
    as "a fired-mark must be plantable"
  let assert Ok(Nil) =
    api.put_reserved_fact(
      rig.runtime,
      schedule.seen_key(strand: child, name: "mine"),
      schedule.seen_value(since_s: 0),
    )
    as "the observation instant must be plantable"

  let hooks = scheduleseam.reaping_hooks(effects.default_hooks(), rig.wiring)
  let _injected = hooks.run_end(brief)

  assert await_true(
    fn() {
      list.all(schedule.strand_prefixes(strand: child), fn(prefix) {
        api.reserved_facts(rig.runtime, prefix:) == Ok([])
      })
    },
    2000,
  )
    as "every cell keyed to the settled strand must be gone"

  // The parent's own schedule is untouched: its run has not ended.
  let assert Ok([listed]) = rig.seam.list(ctx("main"))
    as "the parent must keep the schedule on itself"
  assert listed.name == "own"
  stop(rig)
}

pub fn cancelling_something_absent_says_so_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Error(schedule_tool.NotFound(name: "ghost")) =
    rig.seam.cancel(ctx("main"), "ghost", None)
    as "cancelling a name that was never created must be an error"
  stop(rig)
}

// An operator's schedule is not in the model's store at all, so naming one
// lands on NotFound — which is the right answer for the right reason: it
// is not the model's to cancel.
pub fn a_model_cannot_cancel_an_operators_schedule_test() {
  let operator =
    schedule.Schedule(
      name: "nightly",
      target: "main",
      owner: schedule.OperatorOwned,
      timing: schedule.OneShot(at: 100),
      wake: schedule.WakesIdle,
      body: "operator's own",
    )
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [operator])
    as "the harness must boot"
  let assert Error(schedule_tool.NotFound(name: "nightly")) =
    rig.seam.cancel(ctx("main"), "nightly", None)
    as "an operator's schedule must not be cancellable through this door"
  stop(rig)
}

// A strand may only cancel what it created, which follows from the key
// being built from its own name.
pub fn a_strand_cannot_cancel_another_strands_schedule_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Ok(_created) =
    rig.seam.create(ctx("main"), every("poll", 60, schedule_tool.SteersOnly))
    as "main must be able to schedule"
  let assert Error(schedule_tool.NotFound(name: "poll")) =
    rig.seam.cancel(ctx("review"), "poll", None)
    as "another strand must not be able to cancel it"
  let assert Ok([_still_there]) = rig.seam.list(ctx("main"))
    as "the schedule must survive the attempt"
  stop(rig)
}

// --- the four timings ------------------------------------------------------
//
// The rig's clock is `clock.fixed(at: 0)`, so `now_s` is zero for every
// call below and a relative one-shot resolves to exactly its own delay.

// `In` is the arm that reads a clock, and it is the reason the argument
// exists: the model is told no date, so this is the only way it can ask
// for a one-shot at all.
pub fn a_relative_one_shot_resolves_against_the_session_clock_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Ok(created) =
    rig.seam.create(
      ctx("main"),
      request(
        "recheck",
        schedule_tool.In(seconds: 2700),
        schedule_tool.SteersOnly,
      ),
    )
    as "a relative one-shot must be created"

  // The rig's clock is fixed at zero, so now + 2700 is 2700 exactly.
  assert created.when == "once at " <> schedule.render_instant(2700)
  let assert Ok(cells) =
    api.reserved_facts(rig.runtime, prefix: schedule.config_key_prefix)
    as "the config prefix must be readable"
  let assert [#(_key, value)] = cells as "exactly one cell must be written"
  let assert Ok(stored) = schedule.decode(value) as "the cell must decode"
  assert stored.timing == schedule.OneShot(at: 2700)
  stop(rig)
}

pub fn a_relative_one_shot_outside_its_bounds_is_refused_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Error(schedule_tool.Invalid(reason: too_soon)) =
    rig.seam.create(
      ctx("main"),
      request("now", schedule_tool.In(seconds: 0), schedule_tool.SteersOnly),
    )
    as "a zero delay must be refused at the door"
  assert string.contains(too_soon, "at least")

  let assert Error(schedule_tool.Invalid(reason: too_far)) =
    rig.seam.create(
      ctx("main"),
      request(
        "later",
        schedule_tool.In(seconds: schedule.max_in_seconds + 1),
        schedule_tool.SteersOnly,
      ),
    )
    as "a delay past the horizon must be refused at the door"
  assert string.contains(too_far, "at most")
  stop(rig)
}

pub fn a_cron_schedule_is_created_and_listed_with_its_rendering_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Ok(created) =
    rig.seam.create(
      ctx("main"),
      request(
        "standup",
        schedule_tool.Cron(expression: "0 9 * * 1-5", utc_offset: None),
        schedule_tool.SteersOnly,
      ),
    )
    as "a cron schedule must be created"
  assert created.when == "cron \"0 9 * * 1-5\" UTC, at most 1000 times"

  let assert Ok([listed]) = rig.seam.list(ctx("main"))
    as "the cron schedule must be listed"
  assert listed.when == created.when

  // The cell holds the source text and decodes back to a Cron timing.
  let assert Ok(cells) =
    api.reserved_facts(rig.runtime, prefix: schedule.config_key_prefix)
    as "the config prefix must be readable"
  let assert [#(_key, value)] = cells as "exactly one cell must be written"
  let assert Ok(stored) = schedule.decode(value) as "the cell must decode"
  let assert schedule.Cron(expression:, ..) = stored.timing
    as "the stored timing must be a Cron"
  assert cron.source(expression) == "0 9 * * 1-5"
  stop(rig)
}

// A `utc_offset` beside a cron argument is parsed by
// `client/schedule`'s one `[+-]HH:MM` parser, stored in the cell, and
// said out loud in the rendering — because a caller reading `0 9 * * 1-5`
// back has no other way to know which 09:00 it got.
pub fn a_cron_schedule_accepts_a_utc_offset_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Ok(created) =
    rig.seam.create(
      ctx("main"),
      request(
        "standup",
        schedule_tool.Cron(
          expression: "0 9 * * 1-5",
          utc_offset: Some("+02:00"),
        ),
        schedule_tool.SteersOnly,
      ),
    )
    as "a cron schedule with an offset must be created"
  assert created.when == "cron \"0 9 * * 1-5\" UTC+02:00, at most 1000 times"

  let assert Ok(cells) =
    api.reserved_facts(rig.runtime, prefix: schedule.config_key_prefix)
    as "the config prefix must be readable"
  let assert [#(_key, value)] = cells as "exactly one cell must be written"
  let assert Ok(stored) = schedule.decode(value) as "the cell must decode"
  let assert schedule.Cron(offset_s:, ..) = stored.timing
    as "the stored timing must be a Cron"
  assert offset_s == 7200
  stop(rig)
}

// The refusal is `client/schedule.parse_utc_offset`'s own, so an
// operator's TOML key and a model's argument cannot disagree about what
// `+15:00` means.
pub fn a_cron_offset_the_grammar_refuses_is_refused_at_the_door_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Error(schedule_tool.Invalid(reason:)) =
    rig.seam.create(
      ctx("main"),
      request(
        "standup",
        schedule_tool.Cron(expression: "0 9 * * *", utc_offset: Some("+15:00")),
        schedule_tool.SteersOnly,
      ),
    )
    as "an out-of-range offset must be refused at the door"
  assert string.contains(reason, "utc_offset")
  stop(rig)
}

pub fn a_cron_expression_the_grammar_refuses_is_refused_at_the_door_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Error(schedule_tool.Invalid(reason:)) =
    rig.seam.create(
      ctx("main"),
      request(
        "monday",
        schedule_tool.Cron(expression: "0 9 * * MON", utc_offset: None),
        schedule_tool.SteersOnly,
      ),
    )
    as "a day name must be refused at the door"
  assert string.contains(reason, "cron")
  assert string.contains(reason, "MON")
  stop(rig)
}

// --- the expiry bounds a request may narrow itself to ---------------------

pub fn a_narrower_max_fires_is_stored_and_rendered_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let asked =
    schedule_tool.Request(
      ..every("poll", 300, schedule_tool.SteersOnly),
      max_fires: Some(4),
      expires_after_s: Some(3600),
    )
  let assert Ok(created) = rig.seam.create(ctx("main"), asked)
    as "a narrowed schedule must be created"
  assert string.contains(created.when, "at most 4 times")

  let assert Ok(cells) =
    api.reserved_facts(rig.runtime, prefix: schedule.config_key_prefix)
    as "the config prefix must be readable"
  let assert [#(_key, value)] = cells as "exactly one cell must be written"
  let assert Ok(stored) = schedule.decode(value) as "the cell must decode"
  assert stored.timing
    == schedule.Interval(
      seconds: 300,
      expiry: schedule.Expiry(max_fires: 4, expires_after_s: 3600),
    )
  stop(rig)
}

// The bounds narrow and never widen, and the check is `schedule.build`'s
// — the same `checked_expiry` a `[[schedule]]` table meets — rather than
// a second copy of the ceiling living at this door.
pub fn a_max_fires_above_the_cap_is_refused_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Error(schedule_tool.Invalid(reason: fires)) =
    rig.seam.create(
      ctx("main"),
      schedule_tool.Request(
        ..every("poll", 300, schedule_tool.SteersOnly),
        max_fires: Some(schedule.max_max_fires + 1),
      ),
    )
    as "a max_fires above the cap must be refused"
  assert string.contains(fires, "max_fires must be between")

  let assert Error(schedule_tool.Invalid(reason: window)) =
    rig.seam.create(
      ctx("main"),
      schedule_tool.Request(
        ..every("poll", 300, schedule_tool.SteersOnly),
        expires_after_s: Some(schedule.max_expires_after_s + 1),
      ),
    )
    as "an expires_after_s above the cap must be refused"
  assert string.contains(window, "expires_after_s must be between")
  stop(rig)
}

// A cron schedule is held to the identical pair, because both recurring
// shapes carry the same `Expiry`.
pub fn a_cron_schedule_narrows_and_cannot_widen_its_bounds_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let cron_request = fn(name, bounds) {
    let #(max_fires, expires_after_s) = bounds
    schedule_tool.Request(
      ..request(
        name,
        schedule_tool.Cron(expression: "0 9 * * *", utc_offset: None),
        schedule_tool.SteersOnly,
      ),
      max_fires:,
      expires_after_s:,
    )
  }
  let assert Ok(created) =
    rig.seam.create(ctx("main"), cron_request("narrow", #(Some(3), None)))
    as "a narrowed cron schedule must be created"
  assert string.contains(created.when, "at most 3 times")

  let assert Error(schedule_tool.Invalid(..)) =
    rig.seam.create(
      ctx("main"),
      cron_request("wide", #(Some(schedule.max_max_fires + 1), None)),
    )
    as "a cron schedule may not raise max_fires either"
  stop(rig)
}

// The tool door refuses a bound beside a one-shot, and it refuses it
// there rather than here so the message can name the argument the model
// wrote. This pins that the *seam* is not where that refusal lives: a
// bound arriving beside an `At` is simply the default it would have had,
// because a one-shot carries no `Expiry` at all.
pub fn bounds_beside_a_one_shot_reach_no_expiry_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Ok(created) =
    rig.seam.create(
      ctx("main"),
      schedule_tool.Request(
        ..request(
          "window",
          schedule_tool.At(instant: "1970-01-01T00:01:00Z"),
          schedule_tool.SteersOnly,
        ),
        max_fires: Some(4),
      ),
    )
    as "the seam builds a one-shot regardless of the bounds argument"
  assert created.when == "once at 1970-01-01T00:01:00Z"

  let assert Ok(cells) =
    api.reserved_facts(rig.runtime, prefix: schedule.config_key_prefix)
    as "the config prefix must be readable"
  let assert [#(_key, value)] = cells as "exactly one cell must be written"
  let assert Ok(stored) = schedule.decode(value) as "the cell must decode"
  assert stored.timing == schedule.OneShot(at: 60)
  stop(rig)
}

// --- the runtime is borrowed, not held -------------------------------------

// A holder that is not up refuses in band. The tool body runs on a
// monitored effect process, so a crash here would become a fault instead
// of a result the model can read and act on.
pub fn an_unavailable_runtime_refuses_in_band_test() {
  let seam =
    scheduleseam.seam(scheduleseam.Wiring(
      runtime: fn() { Error(Nil) },
      policy: schedule.ModelSchedulesWake,
      operator_schedules: [],
      scanner: addresses.new(),
    ))
  let assert Error(schedule_tool.Unavailable(..)) =
    seam.create(ctx("main"), every("poll", 60, schedule_tool.SteersOnly))
    as "a create with no runtime must refuse rather than crash"
  let assert Error(schedule_tool.Unavailable(..)) = seam.list(ctx("main"))
    as "a list with no runtime must refuse rather than crash"
  let assert Error(schedule_tool.Unavailable(..)) =
    seam.cancel(ctx("main"), "poll", None)
    as "a cancel with no runtime must refuse rather than crash"
}

// --- fixtures --------------------------------------------------------------

// How many fired-marks one of `main`'s schedules has, read through the
// same door the seam counts them through.
fn marks(rig: Rig, name: String) -> Int {
  case
    api.reserved_facts(
      rig.runtime,
      prefix: schedule.fired_key_prefix(strand: "main", name:),
    )
  {
    Ok(cells) -> list.length(cells)
    Error(_unreadable) -> -1
  }
}

// The reaping hook works on a process it spawns, so its effect is
// awaited rather than assumed. Every other assertion in this file is on
// a synchronous door and needs none of this.
fn await_true(check: fn() -> Bool, remaining_ms: Int) -> Bool {
  case check() {
    True -> True
    False ->
      case remaining_ms <= 0 {
        True -> False
        False -> {
          process.sleep(5)
          await_true(check, remaining_ms - 5)
        }
      }
  }
}

fn an_op() -> ids.OpId {
  let #(op, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 7))
  op
}

fn int_to_string(value: Int) -> String {
  int.to_string(value)
}

// `list.range` is not in this Gleam's stdlib; a small unfold keeps the
// ceiling test counting the real constant rather than a hardcoded list.
fn upto(n: Int) -> List(Int) {
  case n <= 0 {
    True -> []
    False -> list.append(upto(n - 1), [n])
  }
}

fn hanging_provider() -> effects.ProviderSurface {
  effects.ProviderSurface(timeout_ms: 30_000, request: fn(_spec) {
    stream.immediate(events: process.new_subject(), cancel: fn() { Nil })
  })
}

fn refusing_tools() -> effects.ToolSurface {
  effects.ToolSurface(
    clear: fn(_query) {
      effects.ClearanceRefused(reason: "no tools in this harness")
    },
    run: fn(_run) { effects.ToolFailed(reason: "no tools in this harness") },
    replay_still_safe: fn(_name) { False },
    execution_mode: fn(_name) { effects.ExclusiveExecution },
  )
}

fn dead_filesystem() -> tool.FileSystem {
  tool.FileSystem(
    read: fn(path) { Error(tool.FsNotFound(path:)) },
    write: fn(path, _bytes) { Error(tool.FsNotFound(path:)) },
    create_directory_all: fn(path) { Error(tool.FsNotFound(path:)) },
    is_file: fn(_path) { Ok(False) },
    read_link: fn(_path) { Ok(tool.LinkMissing) },
    rename: fn(from, _to) { Error(tool.FsNotFound(path: from)) },
  )
}

fn start_entropy() -> Result(fn() -> Int, String) {
  actor.new(1)
  |> actor.on_message(fn(next, reply) {
    process.send(reply, next)
    actor.continue(next + 1)
  })
  |> actor.start
  |> result.map(fn(counter) {
    fn() { process.call(counter.data, waiting: 1000, sending: fn(r) { r }) }
  })
  |> result.replace_error("the entropy counter did not start")
}
