//// Domain admission and reclamation use real catalogue metadata and original
//// custody witnesses. Barriers distinguish session drain from shared cleanup.

import client/daemon/domain as domain_service
import client/daemon/manager
import client/internal/instance_owner as custody
import core/clock
import core/ids
import gleam/erlang/process
import gleam/int
import gleam/option
import gleam/string
import storage/catalogue
import storage/domain
import weft/poll

fn create(registry, key, workspace, scope) {
  manager.create_scoped(
    registry,
    manager.Creation(
      int.to_string(key),
      workspace,
      "Session",
      "",
      option.None,
      option.None,
      "",
      "",
    ),
    directory: "/unopened-domain-admission/sessions",
    generator: ids.generator(clock.fixed(1), key),
    scope:,
    configuration: "",
  )
}

fn resident(registry, id) {
  let answer =
    poll.until(within: 2000, every: 1, attempt: fn() {
      case manager.get(registry, id) {
        Ok(manager.View(status: manager.Resident(_), ..)) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(string.inspect(error))
      }
    })
  assert answer == poll.Answered(Nil)
}

fn reserved(registry, id) {
  settles(registry, id, manager.Reserved)
}

fn saved(registry, id) {
  settles(registry, id, manager.Saved)
}

fn settles(registry, id, expected) {
  let answer =
    poll.until(within: 2000, every: 1, attempt: fn() {
      case manager.get(registry, id) {
        Ok(manager.View(status:, ..)) if status == expected -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(string.inspect(error))
      }
    })
  assert answer == poll.Answered(Nil)
}

pub fn two_sessions_share_original_domain_until_last_cleanup_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let builds = process.new_subject()
  let cleanup = process.new_subject()
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(selected, _, owner) {
          process.send(builds, selected.id)
          let assert Ok(Nil) =
            custody.publish(owner, custody.Services, fn() {
              let release = process.new_subject()
              process.send(cleanup, release)
              process.receive_forever(release)
              Ok(Nil)
            })
            as "shared cleanup is published"
          Ok(domain_service.inert())
        },
        build: fn(record, _, _, _, _directory) { Ok(record.id) },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
      epoch: "domain-test",
      limit: 2,
    )
    as "registry starts"
  let assert Ok(first) =
    create(registry, 1, "/workspace", domain.WorkspacePrivate)
    as "first admitted"
  let assert Ok(second) =
    create(registry, 2, "/workspace", domain.WorkspacePrivate)
    as "second shares domain"
  resident(registry, first.registration.id)
  resident(registry, second.registration.id)
  let assert Ok(_) = process.receive(builds, 1000) as "one domain built"
  assert process.receive(builds, 0) == Error(Nil)
  let assert Ok(_) = manager.stop_session(registry, first.registration.id)
    as "first closes"
  saved(registry, first.registration.id)
  assert process.receive(cleanup, 0) == Error(Nil)
  let assert Ok(_) = manager.resolve(registry, second.registration.id)
    as "other session retains shared services"

  let watch = process.monitor(manager.pid(registry))
  manager.shutdown(registry)
  let assert Ok(release) = process.receive(cleanup, 2000)
    as "last session drains before shared cleanup"
  assert process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down.reason })
    |> process.selector_receive(0)
    == Error(Nil)
  process.send(release, Nil)
  assert process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down.reason })
    |> process.selector_receive(2000)
    == Ok(process.Normal)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn closing_domain_counts_capacity_after_session_slot_retires_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let cleanup = process.new_subject()
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, owner) {
          let assert Ok(Nil) =
            custody.publish(owner, custody.Services, fn() {
              let release = process.new_subject()
              process.send(cleanup, release)
              process.receive_forever(release)
              Ok(Nil)
            })
            as "domain cleanup can be delayed"
          Ok(domain_service.inert())
        },
        build: fn(record, _, _, _, _directory) { Ok(record.id) },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
      epoch: "bounded-domains",
      limit: 1,
    )
    as "registry starts"
  let assert Ok(first) = create(registry, 10, "/workspace", domain.SessionOnly)
    as "first admitted"
  resident(registry, first.registration.id)
  let assert Ok(_) = manager.stop_session(registry, first.registration.id)
    as "first stops"
  saved(registry, first.registration.id)
  let assert Ok(release) = process.receive(cleanup, 2000)
    as "domain remains retained"
  let assert Ok(manager.Summary(
    occupied: 0,
    domain_capacity: 1,
    domain_occupied: 1,
    domain_blocked: 0,
    ..,
  )) = manager.summary(registry)
    as "ordinary domain closing consumes capacity without a blocked verdict"
  assert create(registry, 11, "/workspace", domain.SessionOnly)
    == Error(manager.Capacity)
  process.send(release, Nil)
  assert poll.until(within: 2000, every: 1, attempt: fn() {
      case manager.summary(registry) {
        Ok(manager.Summary(domain_occupied: 0, ..)) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(string.inspect(error))
      }
    })
    == poll.Answered(Nil)
  let assert Ok(view) = create(registry, 11, "/workspace", domain.SessionOnly)
    as "one explicit retry succeeds after original domain retirement"
  let second = view.registration.id
  resident(registry, second)
  manager.shutdown(registry)
  let assert Ok(release) = process.receive(cleanup, 2000)
    as "second domain cleanup starts"
  let watch = process.monitor(manager.pid(registry))
  process.send(release, Nil)
  assert process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down.reason })
    |> process.selector_receive(2000)
    == Ok(process.Normal)
  assert catalogue.close(store) == Ok(Nil)
}

// The release subject holds the original domain's cleanup witness. Receiving
// it proves cancellation has begun, so an open cannot take the idle revival
// path and accidentally make this regression pass without replacement.
fn held_domain_registry() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let cleanup = process.new_subject()
  let builds = process.new_subject()
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, owner) {
          let assert Ok(Nil) =
            custody.publish(owner, custody.Services, fn() {
              let release = process.new_subject()
              process.send(cleanup, release)
              process.receive_forever(release)
            })
            as "the original cleanup witness is held"
          process.send(builds, Nil)
          Ok(domain_service.inert())
        },
        build: fn(record, _, _, _, _directory) { Ok(record.id) },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
      epoch: "closing-admission",
      limit: 2,
    )
    as "registry starts"
  let assert Ok(first) =
    create(registry, 70, "/workspace", domain.WorkspacePrivate)
    as "first session is admitted"
  resident(registry, first.registration.id)
  let assert Ok(Nil) = process.receive(builds, 2000) as "original domain built"
  let assert Ok(_) = manager.stop_session(registry, first.registration.id)
    as "first session stops"
  saved(registry, first.registration.id)
  let assert Ok(release) = process.receive(cleanup, 2000)
    as "original domain cleanup is in progress"
  #(store, registry, first.registration.id, release, cleanup, builds)
}

pub fn closing_domain_reserves_open_until_original_witness_retires_test() {
  let #(store, registry, first, release, cleanup, builds) =
    held_domain_registry()
  let assert Ok(manager.Opening(operation)) = manager.open(registry, first)
    as "open acknowledges a bounded reservation during cleanup"
  assert manager.open(registry, first) == Ok(manager.Opening(operation))
  let assert Ok(second) =
    create(registry, 71, "/workspace", domain.WorkspacePrivate)
    as "another session may share the pending replacement"
  assert manager.resolve(registry, first) == Error(manager.Unavailable)
  assert create(registry, 72, "/workspace", domain.WorkspacePrivate)
    == Error(manager.Capacity)
  let assert Ok(manager.Summary(occupied: 2, domain_occupied: 1, ..)) =
    manager.summary(registry)
    as "waiters count as sessions, not extra domains"
  assert process.receive(builds, 0) == Error(Nil)

  // Cancelling one accepted operation must not cancel the other waiter or
  // permit the stopped builder to run when shared services become available.
  let assert Ok(_) = manager.stop_session(registry, second.registration.id)
    as "a parked session remains cancellable"
  reserved(registry, second.registration.id)
  process.send(release, Ok(Nil))
  resident(registry, first)
  assert manager.open(registry, first) == Ok(manager.Resident(operation))
  let assert Ok(Nil) = process.receive(builds, 2000) as "one replacement starts"
  assert process.receive(builds, 0) == Error(Nil)
  reserved(registry, second.registration.id)
  let watch = process.monitor(manager.pid(registry))
  manager.shutdown(registry)
  let assert Ok(release) = process.receive(cleanup, 2000)
    as "replacement cleanup starts"
  process.send(release, Ok(Nil))
  assert process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down.reason })
    |> process.selector_receive(2000)
    == Ok(process.Normal)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn shutdown_cancels_open_parked_behind_domain_cleanup_test() {
  let #(store, registry, first, release, _, builds) = held_domain_registry()
  let assert Ok(manager.Opening(_)) = manager.open(registry, first)
    as "open is accepted before shutdown"
  let watch = process.monitor(manager.pid(registry))
  manager.shutdown(registry)
  assert manager.open(registry, first) == Error(manager.Unavailable)
  process.send(release, Ok(Nil))
  assert process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down.reason })
    |> process.selector_receive(2000)
    == Ok(process.Normal)
  assert process.receive(builds, 0) == Error(Nil)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn failed_domain_cleanup_cancels_accepted_open_test() {
  process.trap_exits(True)
  let #(store, registry, first, release, _, builds) = held_domain_registry()
  let assert Ok(manager.Opening(_)) = manager.open(registry, first)
    as "open is accepted while cleanup outcome is unknown"
  process.send(release, Error("held cleanup failed"))
  saved(registry, first)
  assert manager.open(registry, first) == Error(manager.Unavailable)
  let assert Ok(manager.Summary(domain_occupied: 1, domain_blocked: 1, ..)) =
    manager.summary(registry)
    as "failed custody remains reserved"
  assert process.receive(builds, 0) == Error(Nil)

  // This resource-free fixture intentionally has no normal drain proof.
  let watch = process.monitor(manager.pid(registry))
  process.kill(manager.pid(registry))
  assert process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down.reason })
    |> process.selector_receive(2000)
    == Ok(process.Killed)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn cancelled_failed_domain_retires_all_waiting_sessions_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let prepared = process.new_subject()
  let builds = process.new_subject()
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, owner) {
          let release = process.new_subject()
          process.send(prepared, #(owner, release))
          process.receive_forever(release)
          Error("injected domain preparation refusal")
        },
        build: fn(record, _, _, _, _directory) {
          process.send(builds, record.id)
          Ok(record.id)
        },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
      epoch: "cancelled-domain",
      limit: 2,
    )
    as "registry starts"
  let assert Ok(first) =
    create(registry, 20, "/workspace", domain.WorkspacePrivate)
    as "first session waits for shared preparation"
  let assert Ok(#(owner, release)) = process.receive(prepared, 1000)
    as "domain preparation exposes its original custody"
  let assert Ok(second) =
    create(registry, 21, "/workspace", domain.WorkspacePrivate)
    as "second session waits for the same preparation"
  let watch = process.monitor(custody.owner(owner))
  custody.cancel(owner)
  process.send(release, Nil)
  assert process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down.reason })
    |> process.selector_receive(2000)
    == Ok(process.Normal)
  // Cancelled preparation never ran either builder, so neither creation was
  // ever confirmed: these two settle back to their durable reservation, not
  // to the saved state an initialized session retires into.
  reserved(registry, first.registration.id)
  reserved(registry, second.registration.id)
  assert process.receive(builds, 0) == Error(Nil)

  // The result and normal witness have different senders. This exercises the
  // real cancellation path without claiming a deterministic delivery order.
  let watch = process.monitor(manager.pid(registry))
  manager.shutdown(registry)
  assert process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down.reason })
    |> process.selector_receive(2000)
    == Ok(process.Normal)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn failed_domain_cleanup_retains_admission_and_original_witness_test() {
  process.trap_exits(True)
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let owners = process.new_subject()
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, owner) {
          let assert Ok(Nil) =
            custody.publish(owner, custody.Services, fn() {
              Error("injected shared close failure")
            })
            as "failing cleanup is retained before residency"
          process.send(owners, owner)
          Ok(domain_service.inert())
        },
        build: fn(record, _, _, _, _directory) { Ok(record.id) },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
      epoch: "blocked-domain",
      limit: 1,
    )
    as "registry starts"
  let assert Ok(first) = create(registry, 30, "/workspace", domain.SessionOnly)
    as "session admitted"
  resident(registry, first.registration.id)
  let assert Ok(owner) = process.receive(owners, 1000)
    as "the original domain witness is available"
  let assert Ok(_) = manager.stop_session(registry, first.registration.id)
    as "session cleanup starts"
  saved(registry, first.registration.id)
  let assert custody.RecoveryBlocked(custody.Failed(custody.Services, reason)) =
    custody.close(owner, within_ms: 2000)
    as "a failed native-close result is not normal retirement"
  assert reason == "injected shared close failure"
  assert create(registry, 31, "/workspace", domain.SessionOnly)
    == Error(manager.Capacity)
  assert poll.until(within: 2000, every: 1, attempt: fn() {
      case manager.summary(registry) {
        Ok(manager.Summary(
          occupied: 0,
          blocked: 0,
          domain_capacity: 1,
          domain_occupied: 1,
          domain_blocked: 1,
          ..,
        )) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(string.inspect(error))
      }
    })
    == poll.Answered(Nil)
  let watch = process.monitor(manager.pid(registry))
  manager.shutdown(registry)
  let assert Ok(_) = manager.page(registry, after: "")
    as "control metadata remains observable during blocked shutdown"
  assert process.is_alive(custody.owner(owner))
  assert process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down.reason })
    |> process.selector_receive(0)
    == Error(Nil)

  // The intentionally unconfirmed, resource-free fixture remains blocked;
  // terminating its registry must not be mistaken for a successful shutdown.
  process.kill(manager.pid(registry))
  assert process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down.reason })
    |> process.selector_receive(2000)
    == Ok(process.Killed)
  assert catalogue.close(store) == Ok(Nil)
  process.trap_exits(False)
}
