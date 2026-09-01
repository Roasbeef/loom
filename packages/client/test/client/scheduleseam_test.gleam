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
import client/schedule
import client/scheduleseam
import core/clock
import core/ids
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import machine/strand as machine_strand
import provider/stream
import runtime/api
import runtime/effects
import session/session
import tools/schedule as schedule_tool
import tools/tool

// --- the rig ---------------------------------------------------------------

type Rig {
  Rig(runtime: api.Runtime, seam: schedule_tool.Schedules)
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
  let scanner = process.new_name(prefix: "loom_scheduleseam_test")
  let seam =
    scheduleseam.seam(scheduleseam.Wiring(
      runtime: fn() { Ok(runtime) },
      policy: policy_position,
      operator_schedules: operator,
      scanner:,
    ))
  Ok(Rig(runtime:, seam:))
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

fn every(name: String, seconds: Int, wake: Bool) -> schedule_tool.Request {
  schedule_tool.Request(
    name:,
    timing: schedule_tool.Every(seconds:),
    wake:,
    body: "look at it",
  )
}

// --- creating --------------------------------------------------------------

pub fn a_created_schedule_is_durable_and_listed_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Ok(created) =
    rig.seam.create(ctx("main"), every("poll", 300, True))
    as "an ordinary schedule must be created"
  assert created.name == "poll"
  assert created.wake

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
    rig.seam.create(ctx("main"), every("mine", 60, False))
    as "main must be able to schedule"

  assert rig.seam.list(ctx("review")) == Ok([])
  let assert Ok([_own]) = rig.seam.list(ctx("main"))
    as "the creating strand still sees it"
  stop(rig)
}

// --- a subagent may not schedule -------------------------------------------

// The lifetime mismatch, not a trust one: a schedule is cancellable only
// by the strand that made it, and a subagent settles while the schedule
// outlives it. Nobody can cancel it afterwards, it holds a session-wide
// ceiling slot for good, and a `wake = true` one keeps re-opening runs on
// a driver whose task ended. A subagent inherits `schedule_create` by
// default (`agency.child_tools` passes on every tool but `agent_spawn`),
// so this is the ordinary path rather than a corner.
pub fn a_subagent_cannot_schedule_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"

  let assert Error(schedule_tool.Invalid(reason:)) =
    rig.seam.create(ctx("sub:main/worker-1"), every("poll", 60, True))
    as "a subagent must be refused"
  assert string.contains(reason, "subagent")

  // Nothing was written: the refusal is before the store, not after it.
  let assert Ok([]) =
    api.reserved_facts(rig.runtime, prefix: schedule.config_key_prefix)
    as "a refused create must leave no cell"

  // And the ordinary strand is unaffected.
  let assert Ok(_created) =
    rig.seam.create(ctx("main"), every("poll", 60, True))
    as "a top-level strand must still schedule"
  stop(rig)
}

// --- the policy ------------------------------------------------------------

// The sharp half of the argument: under `steer` a model may schedule, but
// nothing it schedules can start a run on an idle strand. The call is
// honoured rather than refused, and the result tells the truth.
pub fn a_steer_policy_grants_the_schedule_but_not_the_waking_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesSteer, [])
    as "the harness must boot"
  let assert Ok(created) = rig.seam.create(ctx("main"), every("poll", 60, True))
    as "asking to wake under a steer policy must not refuse the call"
  assert !created.wake

  let assert Ok(cells) =
    api.reserved_facts(rig.runtime, prefix: schedule.config_key_prefix)
    as "the config prefix must be readable"
  let assert [#(_key, value)] = cells as "one cell must have been written"
  let assert Ok(stored) = schedule.decode(value) as "the cell must decode"
  // The durable cell, not merely the reply, carries the capped answer:
  // the scanner reads the cell and would otherwise wake anyway.
  assert !stored.wake
  stop(rig)
}

pub fn a_wake_policy_grants_the_waking_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Ok(created) = rig.seam.create(ctx("main"), every("poll", 60, True))
    as "asking to wake under a wake policy must be granted"
  assert created.wake
  stop(rig)
}

// --- the bounds ------------------------------------------------------------

pub fn the_door_enforces_the_shared_bounds_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Error(schedule_tool.Invalid(..)) =
    rig.seam.create(ctx("main"), every("a/b", 60, False))
    as "a name that breaks the fired-mark key must be refused at the door"
  let assert Error(schedule_tool.Invalid(..)) =
    rig.seam.create(
      ctx("main"),
      every("hot", schedule.min_interval_s - 1, False),
    )
    as "an interval under the floor must be refused at the door"
  let assert Error(schedule_tool.Invalid(..)) =
    rig.seam.create(
      ctx("main"),
      schedule_tool.Request(
        name: "when",
        timing: schedule_tool.At(instant: "tomorrow"),
        wake: False,
        body: "b",
      ),
    )
    as "prose where RFC3339 belongs must be refused at the door"
  stop(rig)
}

pub fn creating_never_silently_replaces_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Ok(_first) = rig.seam.create(ctx("main"), every("poll", 60, False))
    as "the first must be created"
  let assert Error(schedule_tool.NameTaken(name: "poll")) =
    rig.seam.create(ctx("main"), every("poll", 120, False))
    as "reusing a name must refuse rather than overwrite"

  // The original survives untouched.
  let assert Ok([listed]) = rig.seam.list(ctx("main")) as "one schedule remains"
  assert string.contains(listed.when, "60")
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
      timing: schedule.Interval(
        seconds: 3600,
        expiry: schedule.Expiry(max_fires: 24, expires_after_s: 604_800),
      ),
      wake: True,
      body: "operator's own",
    )
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [operator])
    as "the harness must boot"
  let assert Error(schedule_tool.NameTaken(name: "nightly")) =
    rig.seam.create(ctx("main"), every("nightly", 60, False))
    as "a model must not shadow an operator's schedule on the same strand"

  // The same name on a different strand is a different fired-mark, so it
  // is free. A second top-level strand rather than a subagent, which the
  // lifetime gate refuses for its own reasons.
  let assert Ok(_elsewhere) =
    rig.seam.create(ctx("review"), every("nightly", 60, False))
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
        every("poll-" <> int_to_string(n), 60, False),
      )
      as "every schedule up to the ceiling must be created"
  })
  let assert Error(schedule_tool.CeilingReached(limit:)) =
    rig.seam.create(ctx("main"), every("one-too-many", 60, False))
    as "the schedule past the ceiling must be refused"
  assert limit == schedule.max_model_schedules

  // Cancelling one makes room again: the ceiling counts live schedules,
  // not schedules ever created.
  let assert Ok(Nil) = rig.seam.cancel(ctx("main"), "poll-1")
    as "cancelling must succeed"
  let assert Ok(_now_fits) =
    rig.seam.create(ctx("main"), every("one-too-many", 60, False))
    as "a cancelled schedule must free its slot"
  stop(rig)
}

// --- cancelling ------------------------------------------------------------

pub fn cancelling_removes_it_from_the_listing_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Ok(_created) =
    rig.seam.create(ctx("main"), every("poll", 60, False))
    as "the schedule must be created"
  let assert Ok(Nil) = rig.seam.cancel(ctx("main"), "poll")
    as "cancelling must succeed"
  assert rig.seam.list(ctx("main")) == Ok([])
  stop(rig)
}

pub fn cancelling_something_absent_says_so_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Error(schedule_tool.NotFound(name: "ghost")) =
    rig.seam.cancel(ctx("main"), "ghost")
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
      timing: schedule.OneShot(at: 100),
      wake: True,
      body: "operator's own",
    )
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [operator])
    as "the harness must boot"
  let assert Error(schedule_tool.NotFound(name: "nightly")) =
    rig.seam.cancel(ctx("main"), "nightly")
    as "an operator's schedule must not be cancellable through this door"
  stop(rig)
}

// A strand may only cancel what it created, which follows from the key
// being built from its own name.
pub fn a_strand_cannot_cancel_another_strands_schedule_test() {
  let assert Ok(rig) = harness(schedule.ModelSchedulesWake, [])
    as "the harness must boot"
  let assert Ok(_created) =
    rig.seam.create(ctx("main"), every("poll", 60, False))
    as "main must be able to schedule"
  let assert Error(schedule_tool.NotFound(name: "poll")) =
    rig.seam.cancel(ctx("review"), "poll")
    as "another strand must not be able to cancel it"
  let assert Ok([_still_there]) = rig.seam.list(ctx("main"))
    as "the schedule must survive the attempt"
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
      scanner: process.new_name(prefix: "loom_scheduleseam_absent"),
    ))
  let assert Error(schedule_tool.Unavailable(..)) =
    seam.create(ctx("main"), every("poll", 60, False))
    as "a create with no runtime must refuse rather than crash"
  let assert Error(schedule_tool.Unavailable(..)) = seam.list(ctx("main"))
    as "a list with no runtime must refuse rather than crash"
  let assert Error(schedule_tool.Unavailable(..)) =
    seam.cancel(ctx("main"), "poll")
    as "a cancel with no runtime must refuse rather than crash"
}

// --- fixtures --------------------------------------------------------------

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
