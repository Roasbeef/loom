//// Production scratch actors execute BEAM compiled only after they start.
//// The deliberate hold fixture supplies an observed overlap barrier; production
//// release migrations are pure and contain no hold instrumentation.

import client/scratch
import client/upgrade/controller
import client/upgrade/slots
import client/upgrade/source
import client/upgrade/state as abi
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import support/addresses
import support/harness_upgrade as fixture
import weft/poll
import weft/registry

type Store {
  Store(
    name: registry.Address(scratch.Message),
    pid: Pid,
    seam: scratch.Scratch,
  )
}

fn store() -> Store {
  let name = addresses.new()
  let assert Ok(started) = scratch.start(name, scratch.default_bounds())
    as "the real production scratch actor starts"
  Store(name, started.pid, scratch.seam(name, timeout_ms: 1000))
}

fn stop(store: Store) -> Nil {
  let watch = process.monitor(store.pid)
  scratch.stop(store.name)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_) { Nil })
  process.selector_receive(selector, 1000) |> should.equal(Ok(Nil))
}

fn request(
  id: String,
  expected: abi.Identity,
  target: String,
) -> controller.Request {
  controller.Request(
    id,
    "scratch",
    expected.version,
    expected.digest,
    target,
    source.digest(<<id:utf8>>),
    1000,
  )
}

fn observed(store: Store) -> abi.Observation {
  let assert Ok(observed) = scratch.inspect(store.name, 1000)
    as "the original actor answers its native diagnostic"
  observed
}

fn overlap(
  store: Store,
  unrelated: Store,
  id: String,
  artifact: source.Artifact,
  key: String,
) -> controller.Receipt {
  let before = observed(store)
  let asked = request(id, before.identity, "fixture")
  let owner = process.self()
  let reply = process.new_subject()
  let _upgrade =
    process.spawn(fn() {
      process.send(
        reply,
        controller.apply_on(store.name, asked, owner, fn(_, _) { Ok(artifact) }),
      )
    })
  let migration = fixture.paused()
  let migration_watch = process.monitor(migration)
  let written = process.new_subject()
  let _writer =
    process.spawn(fn() {
      process.send(written, store.seam.set(key, <<"queued":utf8>>))
    })
  poll.until(100, 1, fn() {
    case fixture.queued(store.pid, key) {
      True -> poll.Done(Nil)
      False -> poll.Retry
    }
  })
  |> should.equal(poll.Answered(Nil))

  // These complete while the observed migration worker is still held.
  unrelated.seam.set("other", <<"independent":utf8>>) |> should.equal(Ok(Nil))
  unrelated.seam.get("other") |> should.equal(Ok(Some(<<"independent":utf8>>)))
  process.receive(written, 0) |> should.equal(Error(Nil))
  fixture.continue_worker(migration)
  let assert Ok(Ok(receipt)) = process.receive(reply, 2000)
    as "the held transition resumes and returns its receipt"
  let completed_worker =
    process.new_selector()
    |> process.select_specific_monitor(migration_watch, fn(_) { Nil })
  process.selector_receive(completed_worker, 1000) |> should.equal(Ok(Nil))
  process.receive(written, 1000) |> should.equal(Ok(Ok(Nil)))
  store.seam.get(key) |> should.equal(Ok(Some(<<"queued":utf8>>)))
  receipt.pid |> should.equal(store.pid)
  receipt.status |> should.equal("installed")
  receipt.observation.identity |> should.equal(source.identity(artifact))
  receipt.observation.reported_version
  |> should.equal(source.identity(artifact).version)
  receipt
}

pub fn real_compiled_stateful_upgrade_failure_and_current_state_downgrade_test() -> Nil {
  let target = store()
  let unrelated = store()
  target.seam.set("before", <<"retained":utf8>>) |> should.equal(Ok(Nil))
  let first = observed(target)
  first.identity |> should.equal(abi.builtin())

  // Compilation happens after startup and population, creating new BEAM bytes.
  let v2 = fixture.artifact(abi.SlotA, "v2", "hold", process.self())
  let upgraded = overlap(target, unrelated, "upgrade-v2", v2, "queued-up")
  upgraded.observation.entries |> should.equal(2)
  target.seam.set("after", <<"post-upgrade":utf8>>) |> should.equal(Ok(Nil))
  target.seam.get("before") |> should.equal(Ok(Some(<<"retained":utf8>>)))

  // Each failure loads an inactive candidate but keeps the full old actor.
  use mode <- list.each(["reject", "crash", "timeout", "badabi", "hang_version"])
  let artifact = fixture.artifact(abi.SlotB, mode, mode, process.self())
  let asked = request(mode, source.identity(v2), "fixture")
  let result =
    controller.apply_on(target.name, asked, process.self(), fn(_, _) {
      Ok(artifact)
    })
  case result {
    Ok(receipt) -> {
      receipt.pid |> should.equal(target.pid)
      receipt.status |> should.equal("retained")
      receipt.error |> should.not_equal(None)
    }
    Error(_) -> Nil
  }
  observed(target).identity |> should.equal(source.identity(v2))
  target.seam.get("after") |> should.equal(Ok(Some(<<"post-upgrade":utf8>>)))
  case mode {
    "hang_version" -> finish(target, unrelated, v2)
    _ -> Nil
  }
}

fn finish(target: Store, unrelated: Store, v2: source.Artifact) -> Nil {
  // A different session cannot overwrite v2's fixed namespace while it is live.
  let intruder =
    fixture.artifact(abi.SlotA, "intruder", "normal", process.self())
  let asked = request("occupied", abi.builtin(), "fixture")
  controller.apply_on(unrelated.name, asked, process.self(), fn(_, _) {
    Ok(intruder)
  })
  |> should.be_error
  observed(target).identity |> should.equal(source.identity(v2))

  cancelled_owner(target, v2)
  let v1 = fixture.artifact(abi.SlotB, "v1", "hold", process.self())
  let downgraded = overlap(target, unrelated, "downgrade-v1", v1, "queued-down")
  downgraded.observation.entries |> should.equal(4)
  target.seam.get("after") |> should.equal(Ok(Some(<<"post-upgrade":utf8>>)))
  target.seam.get("before") |> should.equal(Ok(Some(<<"retained":utf8>>)))
  unrelated.seam.get("other") |> should.equal(Ok(Some(<<"independent":utf8>>)))
  let builtin =
    controller.Request(
      "restore-builtin",
      "scratch",
      "v1",
      source.identity(v1).digest,
      "builtin",
      "builtin",
      1000,
    )
  let assert Ok(receipt) =
    controller.apply(target.name, builtin, process.self())
    as "builtin downgrade migrates current state"
  receipt.observation.entries |> should.equal(4)
  receipt.observation.identity |> should.equal(abi.builtin())
  receipt.pid |> should.equal(target.pid)
  stop(target)
  stop(unrelated)
}

fn cancelled_owner(target: Store, current: source.Artifact) -> Nil {
  let baseline_monitors = fixture.monitor_count(target.pid)
  let candidate =
    fixture.artifact(abi.SlotB, "cancelled", "hold", process.self())
  let asked = request("owner-loss", source.identity(current), "fixture")
  let observer = process.self()
  let caller =
    process.spawn(fn() {
      let _ =
        controller.apply_on(target.name, asked, observer, fn(_, _) {
          Ok(candidate)
        })
      Nil
    })
  let migration = fixture.paused()
  let worker_watch = process.monitor(migration)
  let caller_watch = process.monitor(caller)
  process.unlink(caller)
  process.kill(caller)
  let caller_down =
    process.new_selector()
    |> process.select_specific_monitor(caller_watch, fn(_) { Nil })
  process.selector_receive(caller_down, 1000) |> should.equal(Ok(Nil))
  let worker_down =
    process.new_selector()
    |> process.select_specific_monitor(worker_watch, fn(_) { Nil })
  process.selector_receive(worker_down, 2000) |> should.equal(Ok(Nil))
  target.seam.get("after") |> should.equal(Ok(Some(<<"post-upgrade":utf8>>)))
  observed(target).identity |> should.equal(source.identity(current))
  poll.until(1000, 5, fn() {
    case fixture.monitor_count(target.pid) == baseline_monitors {
      True -> poll.Done(Nil)
      False -> poll.Retry
    }
  })
  |> should.equal(poll.Answered(Nil))
}

fn await_controls(pid: Pid, kind: String, count: Int) -> Nil {
  poll.until(4000, 1, fn() {
    case fixture.queued_controls(pid, kind) >= count {
      True -> poll.Done(Nil)
      False -> poll.Retry
    }
  })
  |> should.equal(poll.Answered(Nil))
}

fn start_builtin(target: Store, id: String) {
  let reply = process.new_subject()
  let owner = process.self()
  let asked =
    controller.Request(
      id,
      "scratch",
      "builtin",
      "builtin",
      "builtin",
      "builtin",
      1000,
    )
  let _caller =
    process.spawn(fn() {
      process.send(reply, controller.apply(target.name, asked, owner))
    })
  reply
}

fn next_builtin(target: Store) -> Nil {
  let asked =
    controller.Request(
      "after-timeout",
      "scratch",
      "builtin",
      "builtin",
      "builtin",
      "builtin",
      1000,
    )
  let assert Ok(receipt) = controller.apply(target.name, asked, process.self())
    as "acknowledged cleanup allows the next upgrade"
  receipt.pid |> should.equal(target.pid)
  receipt.status |> should.equal("installed")
  target.seam.get("before") |> should.equal(Ok(Some(<<"retained":utf8>>)))
}

pub fn delayed_arm_acknowledgement_retires_the_late_permit_test() -> Nil {
  let target = store()
  target.seam.set("before", <<"retained":utf8>>) |> should.equal(Ok(Nil))
  let assert Ok(_) = slots.owner() as "global slot owner exists"
  let slot_owner = fixture.pause_slots()
  let reply = start_builtin(target, "late-arm")
  await_controls(slot_owner, "acquire", 1)
  fixture.pause(target.pid)
  fixture.resume(slot_owner)

  // Disarm is sent only after Arm's wait expires. Both remain queued on the
  // same recipient, so resumption exercises the late-admission ordering.
  await_controls(target.pid, "disarm", 1)
  process.receive(reply, 0) |> should.equal(Error(Nil))
  fixture.resume(target.pid)
  let assert Ok(Error(_)) = process.receive(reply, 4000)
    as "failed admission reports only after its late permit has retired"
  next_builtin(target)
  stop(target)
}

pub fn delayed_acquire_acknowledgement_retires_the_late_reservation_test() -> Nil {
  let target = store()
  target.seam.set("before", <<"retained":utf8>>) |> should.equal(Ok(Nil))
  let assert Ok(_) = slots.owner() as "global slot owner exists"
  let slot_owner = fixture.pause_slots()
  let reply = start_builtin(target, "late-acquire")
  await_controls(slot_owner, "acquire", 1)

  // Confirmation queued behind Acquire proves that its caller timed out while
  // retaining custody. Their common sender preserves retirement ordering.
  await_controls(slot_owner, "confirm", 1)
  process.receive(reply, 0) |> should.equal(Error(Nil))
  fixture.resume(slot_owner)
  let assert Ok(Error(_)) = process.receive(reply, 4000)
    as "uncertain slot admission is retired before the caller completes"
  next_builtin(target)
  stop(target)
}

pub fn lost_confirmation_acknowledgement_reconciles_and_drains_test() -> Nil {
  let target = store()
  target.seam.set("before", <<"retained":utf8>>) |> should.equal(Ok(Nil))
  let artifact =
    fixture.artifact(abi.SlotA, "confirm-v2", "hold", process.self())
  let asked = request("late-confirm", abi.builtin(), "fixture")
  let reply = process.new_subject()
  let owner = process.self()
  let _caller =
    process.spawn(fn() {
      process.send(
        reply,
        controller.apply_on(target.name, asked, owner, fn(_, _) { Ok(artifact) }),
      )
    })
  let migration = fixture.paused()
  let slot_owner = fixture.pause_slots()
  fixture.continue_worker(migration)

  // A second confirmation proves the first acknowledgement deadline elapsed.
  // Processing both must settle the same token without losing cleanup custody.
  await_controls(slot_owner, "confirm", 2)
  process.receive(reply, 0) |> should.equal(Error(Nil))
  fixture.resume(slot_owner)
  let assert Ok(Ok(receipt)) = process.receive(reply, 4000)
    as "an installed transition survives a lost completion acknowledgement"
  receipt.pid |> should.equal(target.pid)
  receipt.status |> should.equal("installed")
  target.seam.get("before") |> should.equal(Ok(Some(<<"retained":utf8>>)))
  stop(target)
}

pub fn stale_confirmation_cannot_release_a_successor_reservation_test() -> Nil {
  let target = store()
  let assert Ok(owner) = slots.owner() as "global slot owner exists"
  let identity = abi.builtin()
  let artifact = source.builtin()
  slots.acquire(owner, target.pid, "first", identity, artifact)
  |> should.equal(Ok(Nil))
  slots.confirm(owner, target.pid, "first", identity) |> should.equal(Ok(Nil))
  slots.acquire(owner, target.pid, "second", identity, artifact)
  |> should.equal(Ok(Nil))

  // An old completion may be acknowledged again, but it cannot free the
  // successor's slot or change the identity tracked by that reservation.
  slots.confirm(owner, target.pid, "first", identity) |> should.equal(Ok(Nil))
  slots.acquire(owner, target.pid, "third", identity, artifact)
  |> should.equal(Error("scratch already has a reserved upgrade"))
  slots.confirm(owner, target.pid, "second", identity) |> should.equal(Ok(Nil))
  stop(target)
}
