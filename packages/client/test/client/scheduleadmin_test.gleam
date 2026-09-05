//// The operator-facing scheduling door against a real session store.
////
//// The door's whole job is durable: it walks the reserved config prefix,
//// counts fired-marks, and retires a schedule's footprint through the
//// seam. So these tests run over a real runtime on an in-memory session
//// and assert on the cells, not on the closures. What the *hub* does with
//// the answers — which error code each refusal becomes, and that a
//// successful cancel replies with the listing that remains — is
//// `gateway_test`'s subject over a scripted door.
////
//// No scanner is registered, which is production's restarting-scanner
//// case: `schedulescan.poke` must tolerate a name nothing is registered
//// under, and every cancel here calls it.

import client/schedule
import client/scheduleadmin
import client/scheduleseam
import core/clock
import core/json
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import machine/strand as machine_strand
import provider/stream
import runtime/api
import runtime/effects
import session/session
import support/addresses
import weft/actor

// --- the rig ---------------------------------------------------------------

type Rig {
  Rig(runtime: api.Runtime, admin: scheduleadmin.Admin)
}

fn harness(operator: List(schedule.Schedule)) -> Result(Rig, String) {
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

  // A scanner name nothing is registered under: the poke every cancel
  // performs must tolerate it.
  let scanner = addresses.new()
  let wiring =
    scheduleseam.Wiring(
      runtime: fn() { Ok(runtime) },
      policy: schedule.ModelSchedulesWake,
      operator_schedules: operator,
      scanner:,
    )
  Ok(Rig(runtime:, admin: scheduleadmin.admin(wiring)))
}

fn stop(rig: Rig) -> Nil {
  process.kill(rig.runtime.tree.supervisor)
}

fn start_entropy() -> Result(fn() -> Int, String) {
  use counter <- result.try(
    actor.new(1)
    |> actor.on_message(fn(next, reply) {
      process.send(reply, next)
      actor.continue(next + 1)
    })
    |> actor.start
    |> result.replace_error("the entropy counter did not start"),
  )
  Ok(fn() {
    7_000_000
    + process.call(counter.data, waiting: 1000, sending: fn(reply) { reply })
    * 7919
  })
}

// A provider that never answers: nothing here starts a run, and a
// surface that could would make a durable read race a turn.
fn hanging_provider() -> effects.ProviderSurface {
  effects.ProviderSurface(timeout_ms: 50, request: fn(_spec) {
    stream.immediate(events: process.new_subject(), cancel: fn() { Nil })
  })
}

fn refusing_tools() -> effects.ToolSurface {
  effects.ToolSurface(
    clear: fn(_query) { effects.ClearanceRefused(reason: "no tools here") },
    run: fn(_run) { effects.ToolFailed(reason: "no tools here") },
    replay_still_safe: fn(_name) { False },
    execution_mode: fn(_name) { effects.ExclusiveExecution },
  )
}

// --- the schedules the tests are about -------------------------------------

fn operator_schedule() -> schedule.Schedule {
  schedule.Schedule(
    name: "nightly",
    target: "main",
    owner: schedule.OperatorOwned,
    timing: schedule.Interval(
      seconds: 3600,
      expiry: schedule.Expiry(max_fires: 24, expires_after_s: 604_800),
    ),
    wake: schedule.WakesIdle,
    body: "summarize what changed today",
  )
}

fn model_schedule(name: String, target: String) -> schedule.Schedule {
  schedule.Schedule(
    name:,
    target:,
    owner: schedule.StrandOwned(strand: "main"),
    timing: schedule.Interval(
      seconds: 300,
      expiry: schedule.Expiry(max_fires: 20, expires_after_s: 86_400),
    ),
    wake: schedule.SteersOnly,
    body: "report where the review has got to",
  )
}

// A cell planted rather than created through the model's door: the
// ownership and policy checks that door enforces are its own tests'
// subject, and planting is what lets a schedule owned by one strand and
// aimed at another exist here without starting either.
fn plant(rig: Rig, sched: schedule.Schedule) -> Nil {
  let assert Ok(Nil) =
    api.put_reserved_fact(
      rig.runtime,
      schedule.config_key(strand: sched.target, name: sched.name),
      scheduleseam.cell(sched),
    )
    as "a config cell must be plantable"
  Nil
}

fn plant_marks(
  rig: Rig,
  sched: schedule.Schedule,
  occurrences: List(Int),
) -> Nil {
  occurrences
  |> list.each(fn(occurrence) {
    let assert Ok(Nil) =
      api.put_reserved_fact(
        rig.runtime,
        schedule.fired_key(strand: sched.target, name: sched.name, occurrence:),
        json.String(sched.name),
      )
      as "a fired-mark must be plantable"
    Nil
  })
  let assert Ok(Nil) =
    api.put_reserved_fact(
      rig.runtime,
      schedule.seen_key(strand: sched.target, name: sched.name),
      schedule.seen_value(since_s: 0),
    )
    as "the observation instant must be plantable"
  Nil
}

fn cells(rig: Rig, prefix: String) -> Int {
  api.reserved_facts(rig.runtime, prefix:)
  |> result.map(list.length)
  |> result.unwrap(-1)
}

// --- listing ---------------------------------------------------------------

/// The operator sees everything, and the `owner` column is what tells
/// the two kinds apart: the word for a `[[schedule]]` table, the owning
/// strand's name for one a strand created. The order is configuration
/// first, then what the session grew.
pub fn the_listing_names_the_operator_and_the_owning_strand_test() {
  let assert Ok(rig) = harness([operator_schedule()]) as "the harness must boot"
  let child = "sub:main/reviewer-abc123"
  plant(rig, model_schedule("heartbeat", child))

  let assert Ok(rows) = rig.admin.list() as "the listing must be readable"
  assert list.map(rows, fn(row) { #(row.name, row.owner, row.target) })
    == [
      #("nightly", "operator", "main"),
      #("heartbeat", "main", child),
    ]

  // The timing rendering is the seam's own, so an operator and a strand
  // describe one clock in the same words.
  assert list.map(rows, fn(row) { row.when })
    == [
      "every 3600s, at most 24 times",
      "every 300s, at most 20 times",
    ]
  stop(rig)
}

/// The fire count is read off the durable marks rather than remembered,
/// which is what makes it true after a restart.
pub fn the_listing_counts_the_occurrences_already_spent_test() {
  let assert Ok(rig) = harness([]) as "the harness must boot"
  let sched = model_schedule("heartbeat", "main")
  plant(rig, sched)
  plant_marks(rig, sched, [0, 300, 600])

  let assert Ok([row]) = rig.admin.list() as "the one schedule must be listed"
  assert row.fired == 3
  assert row.wake == schedule.SteersOnly
  stop(rig)
}

/// A store the door cannot borrow a runtime for is a reported failure,
/// not an empty listing: "there are none" and "I could not look" are
/// different answers, and only one of them should reach an operator as a
/// table.
pub fn a_listing_without_a_runtime_says_so_test() {
  let scanner = addresses.new()
  let admin =
    scheduleadmin.admin(scheduleseam.Wiring(
      runtime: fn() { Error(Nil) },
      policy: schedule.ModelSchedulesWake,
      operator_schedules: [operator_schedule()],
      scanner:,
    ))
  let assert Error(reason) = admin.list()
    as "a borrow failure must not answer with a table"
  assert reason == "the session runtime is not available"
}

// --- cancelling ------------------------------------------------------------

/// The whole footprint goes, in the seam's order: marks, then the
/// observation instant, then the config cell. A surviving clock under a
/// reusable name is the bug `scheduleseam.retire` exists to prevent, and
/// this door reaches it rather than issuing a second deletion order.
pub fn cancelling_retires_marks_seen_and_the_config_cell_test() {
  let assert Ok(rig) = harness([]) as "the harness must boot"
  let sched = model_schedule("heartbeat", "main")
  plant(rig, sched)
  plant_marks(rig, sched, [0, 300, 600])
  assert cells(
      rig,
      schedule.fired_key_prefix(strand: "main", name: "heartbeat"),
    )
    == 3

  let assert Ok(Nil) = rig.admin.cancel("main", "heartbeat")
    as "cancelling a model schedule must succeed"
  assert cells(
      rig,
      schedule.fired_key_prefix(strand: "main", name: "heartbeat"),
    )
    == 0
  assert api.fact(
      rig.runtime,
      schedule.seen_key(strand: "main", name: "heartbeat"),
    )
    == Ok(None)
  assert cells(rig, schedule.config_key_prefix) == 0
  assert rig.admin.list() == Ok([])
  stop(rig)
}

/// A cancellation reaches only the schedule it names, including when the
/// neighbour shares a string prefix with it — the shape a prefix delete
/// gets wrong if it does not stop at a path segment.
pub fn cancelling_leaves_the_other_schedules_alone_test() {
  let assert Ok(rig) = harness([]) as "the harness must boot"
  let kept = model_schedule("heartbeat-2", "main")
  plant(rig, model_schedule("heartbeat", "main"))
  plant(rig, kept)
  plant_marks(rig, kept, [0, 300])

  let assert Ok(Nil) = rig.admin.cancel("main", "heartbeat")
    as "cancelling the named schedule must succeed"
  let assert Ok([row]) = rig.admin.list() as "the neighbour must survive"
  assert row.name == "heartbeat-2"
  assert row.fired == 2
  stop(rig)
}

/// An operator's `[[schedule]]` has no cell to remove: the file is the
/// record, and the refusal says which file rather than pretending the
/// name was never there.
pub fn cancelling_an_operator_table_is_refused_test() {
  let assert Ok(rig) = harness([operator_schedule()]) as "the harness must boot"
  assert rig.admin.cancel("main", "nightly")
    == Error(scheduleadmin.OperatorConfigured)

  // And the listing is untouched — a refusal is not a partial cancel.
  let assert Ok([row]) = rig.admin.list()
    as "the operator's schedule must still be listed"
  assert row.owner == "operator"
  stop(rig)
}

/// A name that never existed and one already cancelled are the same
/// absence, because the store keeps no tombstone — and both mean the
/// same thing to the asker.
pub fn cancelling_a_name_that_is_not_there_is_not_found_test() {
  let assert Ok(rig) = harness([]) as "the harness must boot"
  plant(rig, model_schedule("heartbeat", "main"))
  assert rig.admin.cancel("main", "ghost") == Error(scheduleadmin.NotFound)

  // The same name on another target is a different schedule, so it is
  // absent too: `{target, name}` is the identity, not the name alone.
  assert rig.admin.cancel("sub:main/reviewer-abc123", "heartbeat")
    == Error(scheduleadmin.NotFound)

  let assert Ok(Nil) = rig.admin.cancel("main", "heartbeat")
    as "the schedule that is there must cancel"
  assert rig.admin.cancel("main", "heartbeat") == Error(scheduleadmin.NotFound)
  stop(rig)
}
