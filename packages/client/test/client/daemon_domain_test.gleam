//// Domain admission and reclamation use real catalogue metadata and original
//// custody witnesses. Barriers distinguish session drain from shared cleanup.

import client/daemon/domain as domain_service
import client/daemon/manager
import client/distill
import client/distillpass
import client/distillpass_domain_test
import client/history
import client/internal/instance_owner as custody
import client/owned_assembly_test
import core/clock
import core/ids
import filepath
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import host/bootstrap
import storage/catalogue
import storage/domain
import weft/poll

fn create(registry, key, workspace, scope) {
  manager.create_scoped(
    registry,
    manager.Creation(int.to_string(key), workspace, "Session", ""),
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
        build: fn(record, _, _, _) { Ok(record.id) },
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
        build: fn(record, _, _, _) { Ok(record.id) },
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
        build: fn(record, _, _, _) {
          process.send(builds, record.id)
          Ok(record.id)
        },
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
        build: fn(record, _, _, _) { Ok(record.id) },
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

/// Closing the last session in a workspace fences that domain's maintenance,
/// and the next open takes it back — cadence included — rather than waiting
/// the fence out.
///
/// The pass is parked inside its own source resolver for the whole of this
/// test, so the fence cannot settle by itself: without revival the second
/// admission is refused `Unavailable` until the pass wall expires, which by
/// default is ten minutes, and the ordinary close-and-reopen loop is exactly
/// the path that hits it.
///
/// Revival that handed the services back with the cadence still fenced would
/// pass every assertion up to the last close, because a fenced worker refuses
/// hints silently. So the test closes the revived session too and requires
/// that close to produce a pass: that is the maintenance a reopened workspace
/// would otherwise never run again.
pub fn a_fenced_idle_domain_is_revived_by_the_next_open_test() {
  let settings = owned_assembly_test.settings()
  let directory = filepath.directory_name(settings.session_path)
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "the joined fixture owns a private domain directory"
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let arrivals = process.new_subject()
  let assert Ok(registry) =
    manager.start(
      store,
      cadenced_assembly(arrivals, "manager-revive"),
      epoch: "domain-revival",
      limit: 2,
    )
    as "registry starts"
  let admit = fn(key) {
    manager.create_scoped(
      registry,
      manager.Creation(int.to_string(key), settings.workspace, "Session", ""),
      directory: directory <> "/sessions",
      generator: ids.generator(clock.fixed(1), key),
      scope: domain.WorkspacePrivate,
      configuration: "",
    )
  }
  let assert Ok(first) = admit(50) as "the first session is admitted"
  resident(registry, first.registration.id)
  let assert Ok(initial) = process.receive(arrivals, 2000)
    as "the domain's first pass parks inside its finite source resolver"

  // The last dependent retires, so the registry coalesces a close pass and
  // fences the cadence. The parked resolver is what keeps it fenced.
  let assert Ok(_) = manager.stop_session(registry, first.registration.id)
    as "the only session closes cleanly"
  saved(registry, first.registration.id)
  let assert Ok(manager.Summary(
    occupied: 0,
    domain_occupied: 1,
    domain_blocked: 0,
    ..,
  )) = manager.summary(registry)
    as "the fenced domain is retained rather than retired"

  let assert Ok(second) = admit(51)
    as "a new session in the same workspace revives the fenced domain"
  resident(registry, second.registration.id)
  assert process.receive(arrivals, 0) == Error(Nil)

  // The account the fence asked for arrives after revival and is ignored,
  // because the slot's phase is no longer quiescing.
  process.send(initial, Ok([]))
  let assert Ok(final) = process.receive(arrivals, 2000)
    as "the coalesced close pass still runs to completion"
  process.send(final, Ok([]))
  assert process.receive(arrivals, 200) == Error(Nil)
  let assert Ok(manager.Summary(
    occupied: 1,
    resident: 1,
    domain_occupied: 1,
    domain_blocked: 0,
    ..,
  )) = manager.summary(registry)
    as "the account the fence asked for does not retire a revived domain"

  // The revived domain's cadence is open again, so the next clean close in
  // this workspace coalesces one more pass instead of being ignored. A
  // revival that left the worker fenced reaches this point and then runs
  // nothing at all.
  let assert Ok(_) = manager.stop_session(registry, second.registration.id)
    as "the revived session closes cleanly"
  saved(registry, second.registration.id)
  let assert Ok(revived) = process.receive(arrivals, 2000)
    as "a revived domain still runs its scheduled maintenance"
  process.send(revived, Ok([]))

  // That pass is also the one the last close's own fence waits on, so its
  // account retires the domain for real this time.
  assert poll.until(within: 2000, every: 1, attempt: fn() {
      case manager.summary(registry) {
        Ok(manager.Summary(domain_occupied: 0, ..)) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(string.inspect(error))
      }
    })
    == poll.Answered(Nil)

  // Shutdown fences the same domain irreversibly, and no admission crosses it.
  let watch = process.monitor(manager.pid(registry))
  manager.shutdown(registry)
  assert admit(52) == Error(manager.Unavailable)
  assert process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down.reason })
    |> process.selector_receive(5000)
    == Ok(process.Normal)
  assert catalogue.close(store) == Ok(Nil)
}

/// A revival withdraws the fence it lifts, and the account of that fence
/// must not settle the next one. The worker sends its reply from its own
/// turn, so nothing at the registry orders a reply decided before the
/// revival against the revival itself; the registry instead listens for
/// each fence on a fresh subject. This fixture holds the earlier subject and
/// delivers an account on it after the second fence stands.
pub fn a_withdrawn_fences_late_account_does_not_settle_the_next_fence_test() {
  let settings = owned_assembly_test.settings()
  let directory = filepath.directory_name(settings.session_path)
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "the joined fixture owns a private domain directory"
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let arrivals = process.new_subject()
  let assert Ok(registry) =
    manager.start(
      store,
      cadenced_assembly(arrivals, "manager-withdraw"),
      epoch: "domain-withdrawal",
      limit: 2,
    )
    as "registry starts"
  let admit = fn(key) {
    manager.create_scoped(
      registry,
      manager.Creation(int.to_string(key), settings.workspace, "Session", ""),
      directory: directory <> "/sessions",
      generator: ids.generator(clock.fixed(1), key),
      scope: domain.WorkspacePrivate,
      configuration: "",
    )
  }
  let assert Ok(first) = admit(60) as "the first session is admitted"
  resident(registry, first.registration.id)
  let assert Ok(withdrawn) =
    manager.settle_subject(registry, first.registration.id)
    as "the fixture holds the subject the first fence will be issued on"
  let assert Ok(initial) = process.receive(arrivals, 2000)
    as "the domain's first pass parks inside its finite source resolver"

  let assert Ok(_) = manager.stop_session(registry, first.registration.id)
    as "the only session closes cleanly, fencing the domain on that subject"
  saved(registry, first.registration.id)
  let assert Ok(second) = admit(61)
    as "a new session in the same workspace revives the fenced domain"
  resident(registry, second.registration.id)
  let assert Ok(standing) =
    manager.settle_subject(registry, second.registration.id)
    as "the revived domain reports the subject its next fence will use"
  assert withdrawn != standing
    as "a revival listens for its next fence on a fresh subject"
  let assert Ok(_) = manager.stop_session(registry, second.registration.id)
    as "the revived session closes cleanly, fencing the domain again"
  saved(registry, second.registration.id)

  // The withdrawn fence's account arrives now, after the second fence was
  // issued. The census that follows is the barrier: it is sent by this
  // process to the same registry process as the account, so it is handled
  // after the account was. These counts cannot distinguish a retained slot
  // from one being closed: the registry ignores the account's Pass payload
  // and treats either Completed or Refused as settlement. The fresh-subject
  // assertion above and the continuing cadence below are the discriminators;
  // a cancelled host cannot run that coalesced pass.
  process.send(withdrawn, distillpass.Refused("decided before the revival"))
  let assert Ok(manager.Summary(
    occupied: 0,
    domain_occupied: 1,
    domain_blocked: 0,
    ..,
  )) = manager.summary(registry)
    as "the domain remains counted and unblocked after the mailbox barrier"

  // The worker finishes the parked pass and the follow-up the two closes
  // coalesced, then answers the standing fence, which retires the domain.
  process.send(initial, Ok([]))
  let assert Ok(follow_up) = process.receive(arrivals, 2000)
    as "the coalesced close pass still runs"
  process.send(follow_up, Ok([]))
  assert poll.until(within: 2000, every: 1, attempt: fn() {
      case manager.summary(registry) {
        Ok(manager.Summary(domain_occupied: 0, ..)) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(string.inspect(error))
      }
    })
    == poll.Answered(Nil)
  manager.shutdown(registry)
  assert catalogue.close(store) == Ok(Nil)
}

// A real domain: live shared history plus a real distillation cadence whose
// pass parks inside a finite source resolver, so a test decides when a fenced
// domain settles instead of racing it.
fn cadenced_assembly(arrivals, lane) -> manager.Assembly(String) {
  manager.Assembly(
    domain_build: fn(selected: domain.Domain, sources, owner) {
      let assert Ok(Nil) =
        bootstrap.ensure_private_directory(filepath.directory_name(
          selected.memory_path,
        ))
        as "domain destinations exist before published resource startup"
      domain_service.build(
        domain_service.Config(
          history: history.SharedConfig(selected.index_path, sources, 5000, 100),
          maintenance: fn(name) {
            let base = distillpass_domain_test.config(name, arrivals, lane)
            Ok(Some(
              distillpass.DomainConfig(
                ..base,
                pipeline: distill.Config(
                  ..base.pipeline,
                  memory_path: selected.memory_path,
                  digest_path: domain.digest_beside(selected.memory_path),
                ),
              ),
            ))
          },
        ),
        owner,
      )
    },
    build: fn(record: catalogue.Registration, _domain, _services, _owner) {
      Ok(record.id)
    },
    fatal: fn(_) { [] },
  )
}

pub fn last_clean_close_waits_coalesced_real_cadence_before_domain_retirement_test() {
  let settings = owned_assembly_test.settings()
  let directory = filepath.directory_name(settings.session_path)
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "the joined fixture owns a private domain directory"
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let arrivals = process.new_subject()
  let owners = process.new_subject()
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(selected, sources, owner) {
          let assert Ok(Nil) =
            bootstrap.ensure_private_directory(filepath.directory_name(
              selected.memory_path,
            ))
            as "domain destinations exist before published resource startup"
          let assert Ok(services) =
            domain_service.build(
              domain_service.Config(
                history: history.SharedConfig(
                  selected.index_path,
                  sources,
                  5000,
                  100,
                ),
                maintenance: fn(name) {
                  let base =
                    distillpass_domain_test.config(
                      name,
                      arrivals,
                      "manager-close",
                    )
                  Ok(Some(
                    distillpass.DomainConfig(
                      ..base,
                      pipeline: distill.Config(
                        ..base.pipeline,
                        memory_path: selected.memory_path,
                        digest_path: domain.digest_beside(selected.memory_path),
                      ),
                    ),
                  ))
                },
              ),
              owner,
            )
            as "real history and cadence publish before beginning effects"
          process.send(owners, #(owner, domain_service.children(services)))
          Ok(services)
        },
        build: fn(record, _, _, _) { Ok(record.id) },
        fatal: fn(_) { [] },
      ),
      epoch: "joined-domain-close",
      limit: 2,
    )
    as "registry starts"
  let admit = fn(key) {
    manager.create_scoped(
      registry,
      manager.Creation(int.to_string(key), settings.workspace, "Session", ""),
      directory: directory <> "/sessions",
      generator: ids.generator(clock.fixed(1), key),
      scope: domain.WorkspacePrivate,
      configuration: "",
    )
  }
  let assert Ok(first) = admit(40) as "first session admitted"
  let assert Ok(second) = admit(41) as "second shares the published domain"
  resident(registry, first.registration.id)
  resident(registry, second.registration.id)
  let assert Ok(#(owner, children)) = process.receive(owners, 1000)
    as "original shared roots are retained"
  assert list.length(children) == 2
  let watch = process.monitor(custody.owner(owner))
  let assert Ok(initial) = process.receive(arrivals, 1000)
    as "the initial real pass parks inside its finite source resolver"

  let assert Ok(_) = manager.stop_session(registry, first.registration.id)
    as "first clean close requests a coalesced pass"
  saved(registry, first.registration.id)
  let assert Ok(_) = manager.stop_session(registry, second.registration.id)
    as "last clean close quiesces the domain"
  saved(registry, second.registration.id)
  let assert Ok(manager.Summary(
    occupied: 0,
    domain_occupied: 1,
    domain_blocked: 0,
    ..,
  )) = manager.summary(registry)
    as "last-close maintenance retains domain capacity"
  assert list.all(children, fn(child) { process.is_alive(child.1) })
  assert process.receive(arrivals, 0) == Error(Nil)
  process.send(initial, Ok([]))
  let assert Ok(final) = process.receive(arrivals, 2000)
    as "quiesce preserves the accepted coalesced final pass"
  assert list.all(children, fn(child) { process.is_alive(child.1) })
  assert process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down.reason })
    |> process.selector_receive(0)
    == Error(Nil)

  process.send(final, Ok([]))
  assert process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down.reason })
    |> process.selector_receive(2000)
    == Ok(process.Normal)
  assert list.all(children, fn(child) { !process.is_alive(child.1) })
  assert poll.until(within: 2000, every: 1, attempt: fn() {
      case manager.summary(registry) {
        Ok(manager.Summary(domain_occupied: 0, ..)) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(string.inspect(error))
      }
    })
    == poll.Answered(Nil)
  assert process.receive(arrivals, 0) == Error(Nil)
  let watch = process.monitor(manager.pid(registry))
  manager.shutdown(registry)
  assert process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down.reason })
    |> process.selector_receive(2000)
    == Ok(process.Normal)
  assert catalogue.close(store) == Ok(Nil)
}
