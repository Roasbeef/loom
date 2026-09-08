//// Admission tests use real durable metadata and controlled assembly barriers.
//// They prove reservation and custody ordering without claiming native resource
//// retirement or integration with the daemon listener.

import client/daemon/domain as domain_service
import client/daemon/lifetime
import client/daemon/manager
import client/distill
import client/internal/ffi_os
import client/internal/instance_owner as custody
import core/clock
import core/ids
import gleam/erlang/process.{type Monitor}
import gleam/int
import gleam/list
import gleam/string
import simplifile
import storage/access
import storage/catalogue
import storage/domain
import weft/poll

fn registration(seed: Int) -> catalogue.Registration {
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed:)
  let #(id, _) = ids.mint_session(generator)
  let id = ids.session_id_to_string(id)
  catalogue.Registration(
    id:,
    path: "/unopened-daemon-manager-test/" <> id <> ".db",
    workspace: "/workspace/project",
    name: "session " <> int.to_string(seed),
    configuration: "",
    created_at: 1_700_000_000_000,
    request_key: "request-" <> int.to_string(seed),
    state: catalogue.Reserved,
  )
}

fn saved(store: catalogue.Catalogue, seed: Int) -> catalogue.Registration {
  let record = raw_saved(store, seed)
  let selected =
    domain.Domain(
      domain.key(domain.SessionOnly, record.workspace, record.id),
      domain.SessionOnly,
      record.workspace,
      "",
      "/fixture-domains/" <> record.id <> "/memory.db",
      "/fixture-domains/" <> record.id <> "/search.db",
    )
  assert domain.bind(store, record.id, selected) == Ok(selected)
  record
}

fn raw_saved(store: catalogue.Catalogue, seed: Int) -> catalogue.Registration {
  let record = registration(seed)
  assert catalogue.reserve(store, record) == Ok(record)
  let assert Ok(record) = catalogue.confirm(store, record.id)
    as "fixture represents initialized metadata without opening its path"
  record
}

fn start(
  store: catalogue.Catalogue,
  limit: Int,
  build: fn(catalogue.Registration, custody.Owner) -> Result(String, String),
) -> manager.Manager(String) {
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, owner) { build(record, owner) },
        fatal: fn(_) { [] },
      ),
      epoch: "daemon-test",
      limit:,
    )
    as "registry starts without invoking assembly"
  registry
}

fn down(watch: Monitor) -> process.Down {
  let assert Ok(down) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(2000)
    as "owned process retires within the test deadline"
  down
}

fn stop(registry: manager.Manager(String)) -> Nil {
  let watch = process.monitor(manager.pid(registry))
  manager.shutdown(registry)
  let assert process.ProcessDown(reason: process.Normal, ..) = down(watch)
    as "shutdown joins all successful custody scopes"
  Nil
}

fn await_status(
  registry: manager.Manager(String),
  id: String,
  expected: manager.Status,
) -> Nil {
  let outcome =
    poll.until(within: 2000, every: 1, attempt: fn() {
      case manager.get(registry, id) {
        Ok(manager.View(status:, ..)) if status == expected -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(string.inspect(error))
      }
    })
  assert outcome == poll.Answered(Nil)
}

pub fn domain_configuration_is_selected_at_creation_not_open_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let registry = start(store, 3, fn(record, _) { Ok(record.id) })
  let requests = [
    #(
      901,
      "/same-workspace",
      "/explicit.toml",
      "/default.toml",
      "/explicit.toml",
    ),
    #(
      902,
      "/same-workspace",
      "/later.toml",
      "/changed-default.toml",
      "/explicit.toml",
    ),
    #(903, "/empty-workspace", "", "", ""),
  ]
  let records =
    list.map(requests, fn(example) {
      let assert Ok(view) =
        manager.create_scoped(
          registry,
          manager.Creation(
            int.to_string(example.0),
            example.1,
            "Session",
            example.2,
          ),
          directory: "/domain-selection/sessions",
          generator: ids.generator(clock.fixed(1), example.0),
          scope: domain.WorkspacePrivate,
          configuration: example.3,
        )
        as "creation selects domain metadata"
      let assert Ok(selected) =
        manager.session_domain(registry, view.registration.id)
        as "mapping exists before open completes"
      assert selected.configuration == example.4
      #(view.registration.id, selected)
    })
  stop(registry)
  let restored =
    start(store, 3, fn(_, _) { panic as "restore must stay metadata-only" })
  list.each(records, fn(record) {
    assert manager.session_domain(restored, record.0) == Ok(record.1)
  })
  stop(restored)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn private_domain_requires_explicit_stopped_isolation_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = raw_saved(store, 897)
  let private =
    domain.Domain(
      domain.key(domain.WorkspacePrivate, record.workspace, record.id),
      domain.WorkspacePrivate,
      record.workspace,
      "/owner/config.toml",
      "/owner/aggregate/memory.db",
      "/owner/aggregate/search.db",
    )
  assert domain.bind(store, record.id, private) == Ok(private)
  let assert Ok(owner) = access.credential_digest(string.repeat("a", 64))
    as "owner digest"
  let assert Ok(member) = access.credential_digest(string.repeat("b", 64))
    as "member digest"
  let assert Ok(_) = access.bootstrap_owner(store, "owner", "Owner", owner)
    as "owner exists"
  let registry = start(store, 1, fn(record, _) { Ok(record.id) })
  let invite =
    manager.Invite("member", "Member", member, record.id, access.Observer)
  assert manager.administer(registry, owner, "daemon-test", invite)
    == Error(manager.IsolationRequired)
  let assert Ok(known) = access.credential_digest(string.repeat("c", 64))
    as "known member digest"
  let assert Ok(_) = access.create_member(store, "known", "Known", known)
    as "previously known principal"
  assert manager.administer(
      registry,
      owner,
      "daemon-test",
      manager.SetRole("known", record.id, access.Operator),
    )
    == Error(manager.IsolationRequired)
  let assert Ok(manager.Opening(operation)) = manager.open(registry, record.id)
    as "explicit admission"
  await_status(registry, record.id, manager.Resident(operation))
  assert manager.isolate(
      registry,
      owner,
      "daemon-test",
      record.id,
      "/new-state",
    )
    == Error(manager.AdminUnavailable)
  let assert Ok(_) = manager.stop_session(registry, record.id)
    as "ordered stop starts"
  await_status(registry, record.id, manager.Saved)
  let assert Ok(isolated) =
    manager.isolate(registry, owner, "daemon-test", record.id, "/new-state")
    as "stopped isolation succeeds"
  assert isolated.scope == domain.SessionOnly
  assert isolated.configuration == private.configuration
  assert isolated.memory_path != private.memory_path
  assert domain.get(store, private.id) == Ok(private)
  assert manager.isolate(
      registry,
      owner,
      "daemon-test",
      record.id,
      "/different-state",
    )
    == Ok(isolated)
  let assert Ok(_) = manager.administer(registry, owner, "daemon-test", invite)
    as "explicit isolation permits invitation"
  assert simplifile.is_file(isolated.memory_path) == Ok(False)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn owner_admin_rechecks_epoch_and_authority_before_mutation_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let session = raw_saved(store, 899)
  let assert Ok(_) =
    domain.bind(
      store,
      session.id,
      domain.Domain(
        domain.key(domain.SessionOnly, session.workspace, session.id),
        domain.SessionOnly,
        session.workspace,
        "",
        "/admin-domain/memory.db",
        "/admin-domain/search.db",
      ),
    )
    as "sharing fixture has explicit session-only metadata"
  let assert Ok(owner_digest) = access.credential_digest(string.repeat("a", 64))
    as "owner digest is valid"
  let assert Ok(member_digest) =
    access.credential_digest(string.repeat("b", 64))
    as "member digest is valid"
  let assert Ok(replacement) = access.credential_digest(string.repeat("c", 64))
    as "replacement digest is valid"
  let assert Ok(_) =
    access.bootstrap_owner(store, "owner", "Owner", owner_digest)
    as "owner exists"
  let registry =
    start(store, 2, fn(_, _) {
      panic as "administration never opens a conversation"
    })
  let invite =
    manager.Invite(
      "member",
      "Member",
      member_digest,
      session.id,
      access.Observer,
    )
  assert manager.administer(registry, owner_digest, "previous", invite)
    == Error(manager.AdminStaleEpoch)
  assert manager.authenticate(registry, member_digest)
    == Error(manager.Catalogue(catalogue.Missing))
  let assert Ok(member) =
    manager.administer(registry, owner_digest, "daemon-test", invite)
    as "owner invitation commits in the current epoch"
  assert manager.administer(
      registry,
      member_digest,
      "daemon-test",
      manager.RotateMember(member.id, replacement),
    )
    == Error(manager.AdminForbidden)
  assert manager.administer(
      registry,
      owner_digest,
      "daemon-test",
      manager.RotateMember("owner", replacement),
    )
    == Error(manager.AdminMetadata(catalogue.Conflict))
  assert manager.administer(
      registry,
      owner_digest,
      "daemon-test",
      manager.SetRole(member.id, session.id, access.Operator),
    )
    == Ok(member)
  assert manager.session_authority(registry, member_digest, session.id)
    == Ok(#(member, access.Participant(access.Operator)))
  assert manager.administer(
      registry,
      owner_digest,
      "daemon-test",
      manager.RevokeMembership(member.id, session.id),
    )
    == Ok(member)
  assert manager.session_authority(registry, member_digest, session.id)
    == Error(manager.Catalogue(catalogue.Missing))
  assert manager.administer(
      registry,
      owner_digest,
      "daemon-test",
      manager.RevokeMember(member.id),
    )
    == Ok(member)
  assert manager.authenticate(registry, member_digest)
    == Error(manager.Catalogue(catalogue.Missing))
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn credential_and_session_authority_reads_do_not_open_sessions_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let first = saved(store, 500)
  let second = saved(store, 501)
  let assert Ok(owner_digest) = access.credential_digest(string.repeat("a", 64))
    as "fixture uses a valid digest representation"
  let assert Ok(member_digest) =
    access.credential_digest(string.repeat("b", 64))
    as "member has a separate credential digest"
  let assert Ok(owner) =
    access.bootstrap_owner(store, "owner", "Owner", owner_digest)
    as "the durable owner is established before serving"
  let assert Ok(member) =
    access.create_member(store, "reader", "Reader", member_digest)
    as "the participant has no implicit session access"
  let assert Ok(Nil) = access.grant(store, member.id, first.id, access.Observer)
    as "membership grants only the selected session"
  let builds = process.new_subject()
  let registry =
    start(store, 2, fn(record, _) {
      process.send(builds, record.id)
      Ok(record.id)
    })

  assert manager.authenticate(registry, owner_digest) == Ok(owner)
  assert manager.session_authority(registry, owner_digest, second.id)
    == Ok(#(owner, access.Owner))
  assert manager.session_authority(registry, member_digest, first.id)
    == Ok(#(member, access.Participant(access.Observer)))
  assert manager.session_authority(registry, member_digest, second.id)
    == Error(manager.Catalogue(catalogue.Missing))
  assert manager.session_authority(registry, owner_digest, "missing")
    == Error(manager.Catalogue(catalogue.Missing))
  let assert Ok(#(_, member_page)) =
    manager.authorized_page(registry, member_digest, after: "")
    as "membership is applied before pagination"
  assert member_page == [manager.View(first, manager.Saved)]
  let assert Ok(#(_, owner_page)) =
    manager.authorized_page(registry, owner_digest, after: "")
    as "the owner can list every registration"
  assert list.length(owner_page) == 2
  assert manager.summary(registry)
    == Ok(manager.Summary(
      admission: manager.Accepting,
      capacity: 2,
      occupied: 0,
      opening: 0,
      resident: 0,
      stopping: 0,
      blocked: 0,
      domain_capacity: 2,
      domain_occupied: 0,
      domain_blocked: 0,
    ))
  assert process.receive(builds, 0) == Error(Nil)
  assert manager.resolve(registry, first.id) == Error(manager.Unavailable)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn restored_metadata_does_not_start_saved_sessions_test() {
  let assert Ok(Nil) = simplifile.create_directory_all("build/test_db")
    as "fixture directory exists"
  let path =
    "build/test_db/admission-"
    <> int.to_string(ffi_os.system_time_ms())
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
    <> ".db"
  let assert Ok(store) = catalogue.open(path) as "metadata database opens"
  let record = saved(store, 1)
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(restored) = catalogue.open(path) as "metadata survives restart"
  let builds = process.new_subject()
  let registry =
    start(restored, 1, fn(record, _) {
      process.send(builds, record.id)
      Ok(record.id)
    })

  assert manager.get(registry, record.id)
    == Ok(manager.View(record, manager.Saved))
  assert manager.page(registry, after: "")
    == Ok(#(3, [manager.View(record, manager.Saved)]))
  assert manager.resolve(registry, record.id) == Error(manager.Unavailable)
  assert simplifile.is_file(record.path) == Ok(False)
  assert process.receive(builds, 0) == Error(Nil)
  stop(registry)
  assert catalogue.close(restored) == Ok(Nil)
}

pub fn creation_retry_preserves_reservation_before_and_after_assembly_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let arrivals = process.new_subject()
  let registry =
    start(store, 1, fn(record, _) {
      let release = process.new_subject()
      process.send(arrivals, #(record, release))
      let assert Ok(Nil) = process.receive(release, 2000)
        as "test releases initialization within its deadline"
      Ok(record.id)
    })
  let request =
    manager.Creation("create-once", "/workspace/project", "first", "")
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed: 411)
  let assert Ok(manager.View(record, manager.Opening(operation))) =
    manager.create(
      registry,
      request,
      directory: "/private/sessions",
      generator:,
    )
    as "creation reserves metadata before running the builder"
  let assert Ok(#(built, release)) = process.receive(arrivals, 1000)
    as "builder receives the original reservation"
  assert built == record
  assert record.state == catalogue.Reserved
  let later = ids.generator(clock.fixed(at: 1_800_000_000_000), seed: 999)

  assert manager.create(
      registry,
      request,
      directory: "/private/sessions",
      generator: later,
    )
    == Ok(manager.View(record, manager.Opening(operation)))
  assert manager.create(
      registry,
      manager.Creation(..request, name: "different"),
      directory: "/private/sessions",
      generator: later,
    )
    == Error(manager.Catalogue(catalogue.Conflict))
  assert process.receive(arrivals, 0) == Error(Nil)
  process.send(release, Nil)
  await_status(registry, record.id, manager.Resident(operation))

  let saved = catalogue.Registration(..record, state: catalogue.Saved)
  assert manager.create(
      registry,
      request,
      directory: "/private/sessions",
      generator: later,
    )
    == Ok(manager.View(saved, manager.Resident(operation)))
  assert manager.set_default(registry, record.workspace, record.id)
    == Ok(manager.View(saved, manager.Resident(operation)))
  stop(registry)

  let builds = process.new_subject()
  let restarted =
    start(store, 1, fn(record, _) {
      process.send(builds, record.id)
      Ok(record.id)
    })
  assert manager.workspace_default(restarted, record.workspace)
    == Ok(manager.View(saved, manager.Saved))
  assert process.receive(builds, 0) == Error(Nil)
  stop(restarted)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn reserved_creation_requires_explicit_retry_after_capacity_refusal_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let occupied = saved(store, 412)
  let builds = process.new_subject()
  let registry =
    start(store, 1, fn(record, _) {
      process.send(builds, record.id)
      Ok(record.id)
    })
  let assert Ok(manager.Opening(operation)) =
    manager.open(registry, occupied.id)
    as "first session owns the only capacity slot"
  await_status(registry, occupied.id, manager.Resident(operation))
  let assert Ok(_) = process.receive(builds, 1000) as "first assembly ran"
  let request =
    manager.Creation("capacity-retry", "/workspace/project", "second", "")
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed: 413)
  assert manager.create(
      registry,
      request,
      directory: "/private/sessions",
      generator:,
    )
    == Error(manager.Capacity)
  let assert Ok(reserved) = catalogue.by_request_key(store, request.request_key)
    as "capacity refusal retains its durable creation identity"
  assert reserved.state == catalogue.Reserved
  let assert Ok(_) = manager.stop_session(registry, occupied.id)
    as "stop requests cleanup"
  await_status(registry, occupied.id, manager.Saved)
  assert manager.open(registry, reserved.id) == Error(manager.NotInitialized)
  assert process.receive(builds, 0) == Error(Nil)

  let assert Ok(manager.View(retried, manager.Opening(next))) =
    manager.create(
      registry,
      request,
      directory: "/private/sessions",
      generator: ids.generator(clock.fixed(at: 1_800_000_000_000), seed: 414),
    )
    as "explicit create retry initializes the same reservation"
  assert retried == reserved
  await_status(registry, reserved.id, manager.Resident(next))
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn blocked_builder_preserves_listing_and_other_session_admission_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let first = saved(store, 2)
  let second = saved(store, 3)
  let started = process.new_subject()
  let builds = process.new_subject()
  let registry =
    start(store, 2, fn(record, _) {
      process.send(builds, record.id)
      case record.id == first.id {
        True -> {
          let release = process.new_subject()
          process.send(started, release)
          process.receive_forever(release)
        }
        False -> Nil
      }
      Ok(record.id)
    })
  let assert Ok(manager.Opening(operation)) = manager.open(registry, first.id)
    as "first open reserves one operation before assembly finishes"
  let assert Ok(release) = process.receive(started, 1000)
    as "first builder is held at the barrier"

  assert manager.open(registry, first.id) == Ok(manager.Opening(operation))
  let assert Ok(#(6, views)) = manager.page(registry, after: "")
    as "a blocked builder cannot block metadata reads"
  assert list.length(views) == 2
  let assert Ok(manager.Opening(second_operation)) =
    manager.open(registry, second.id)
    as "another session gets its independent builder"
  await_status(registry, second.id, manager.Resident(second_operation))
  assert manager.resolve(registry, second.id) == Ok(second.id)
  assert process.receive(builds, 1000) == Ok(first.id)
  assert process.receive(builds, 1000) == Ok(second.id)
  assert process.receive(builds, 0) == Error(Nil)

  process.send(release, Nil)
  await_status(registry, first.id, manager.Resident(operation))
  assert manager.open(registry, first.id) == Ok(manager.Resident(operation))
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn stopping_retains_capacity_until_original_custody_retires_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let first = saved(store, 4)
  let second = saved(store, 5)
  let draining = process.new_subject()
  let built = process.new_subject()
  let registry =
    start(store, 1, fn(record, owner) {
      let assert Ok(Nil) =
        custody.publish(owner, custody.Storage, fn() {
          let release = process.new_subject()
          process.send(draining, release)
          process.receive_forever(release)
          Ok(Nil)
        })
        as "cleanup barrier is owned before result publication"
      process.send(built, custody.owner(owner))
      Ok(record.id)
    })
  let assert Ok(manager.Opening(operation)) = manager.open(registry, first.id)
    as "first instance admitted"
  let assert Ok(owner) = process.receive(built, 1000) as "custody published"
  let watch = process.monitor(owner)
  await_status(registry, first.id, manager.Resident(operation))
  assert manager.stop_if_incarnation(registry, first.id, operation)
    == Ok(manager.Stopping(operation))
  let assert Ok(release) = process.receive(draining, 1000)
    as "cleanup is still pending"

  assert manager.open(registry, first.id) == Error(manager.Unavailable)
  assert manager.open(registry, second.id) == Error(manager.Capacity)
  assert manager.resolve(registry, first.id) == Error(manager.Unavailable)
  assert process.is_alive(owner)
  process.send(release, Nil)
  let assert process.ProcessDown(reason: process.Normal, ..) = down(watch)
    as "original custody has now proved complete retirement"
  await_status(registry, first.id, manager.Saved)

  assert manager.operation(registry, first.id, operation)
    == Error(manager.StaleOperation)

  await_domains_retired(registry)
  let assert Ok(manager.Opening(reopened)) = manager.open(registry, first.id)
    as "same saved identity can reopen after confirmed retirement"
  assert reopened != operation
  await_status(registry, first.id, manager.Resident(reopened))
  assert manager.stop_if_incarnation(registry, first.id, operation)
    == Error(manager.StaleOperation)
  assert manager.resolve_incarnation(registry, first.id, reopened)
    == Ok(first.id)
  assert manager.resolve_incarnation(registry, first.id, operation)
    == Error(manager.StaleOperation)
  assert manager.resolve_incarnation(registry, first.id, reopened)
    == Ok(first.id)
  assert manager.operation(registry, first.id, operation)
    == Error(manager.StaleOperation)
  assert manager.operation(registry, first.id, reopened)
    == Ok(manager.View(first, manager.Resident(reopened)))
  assert manager.resolve(registry, first.id) == Ok(first.id)
  let _closing = manager.stop_session(registry, first.id)
  let assert Ok(release) = process.receive(draining, 1000)
    as "second incarnation has its own cleanup"
  process.send(release, Nil)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn failed_cleanup_retains_capacity_and_does_not_release_storage_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let first = saved(store, 6)
  let second = saved(store, 7)
  let released = process.new_subject()
  let registry =
    start(store, 1, fn(record, owner) {
      let assert Ok(Nil) =
        custody.publish(owner, custody.Runtime, fn() {
          Error("injected missing drain proof")
        })
        as "runtime boundary refuses to claim retirement"
      let assert Ok(Nil) =
        custody.publish(owner, custody.Storage, fn() {
          process.send(released, Nil)
          Ok(Nil)
        })
        as "storage release is behind the runtime barrier"
      Ok(record.id)
    })
  let assert Ok(manager.Opening(operation)) = manager.open(registry, first.id)
    as "instance admitted"
  await_status(registry, first.id, manager.Resident(operation))
  let _closing = manager.stop_session(registry, first.id)
  let blocked =
    poll.until(within: 2000, every: 1, attempt: fn() {
      case manager.get(registry, first.id) {
        Ok(manager.View(status: manager.RecoveryBlocked(reason), ..)) ->
          poll.Done(reason)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(string.inspect(error))
      }
    })
  let assert poll.Answered(reason) = blocked as "failed drain becomes blocked"
  assert manager.operation(registry, first.id, operation)
    == Ok(manager.View(first, manager.RecoveryBlocked(reason)))
  assert manager.operation(registry, first.id, "different-operation")
    == Error(manager.StaleOperation)
  assert string.contains(reason, "injected missing drain proof")
  assert manager.open(registry, first.id) == Error(manager.Unavailable)
  assert manager.open(registry, second.id) == Error(manager.Capacity)
  assert manager.resolve(registry, first.id) == Error(manager.Unavailable)
  assert process.receive(released, 0) == Error(Nil)

  // Shutdown must also preserve the blocked reservation. Its holder deliberately
  // survives until this test VM exits; there is no safe replacement verdict.
  manager.shutdown(registry)
  assert manager.get(registry, first.id)
    == Ok(manager.View(first, manager.RecoveryBlocked(reason)))
  assert catalogue.close(store) == Ok(Nil)
}

pub fn stop_during_assembly_never_publishes_a_late_resident_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = saved(store, 11)
  let assembling = process.new_subject()
  let draining = process.new_subject()
  let registry =
    start(store, 1, fn(record, owner) {
      let assert Ok(Nil) =
        custody.publish(owner, custody.Storage, fn() {
          let release = process.new_subject()
          process.send(draining, release)
          process.receive_forever(release)
          Ok(Nil)
        })
        as "partial assembly retains its cleanup capability"
      let release = process.new_subject()
      process.send(assembling, release)
      process.receive_forever(release)
      Ok(record.id)
    })
  let assert Ok(manager.Opening(operation)) = manager.open(registry, record.id)
    as "opening accepted"
  let assert Ok(release_build) = process.receive(assembling, 1000)
    as "assembly is parked before its successful result"
  assert manager.stop_session(registry, record.id)
    == Ok(manager.Stopping(operation))
  process.send(release_build, Nil)
  let assert Ok(release_drain) = process.receive(draining, 1000)
    as "builder completed and its cleanup remains pending"

  // The builder sent success before it handled cancellation. That queued result
  // cannot undo the registry's already accepted stop or expose a dying instance.
  await_status(registry, record.id, manager.Stopping(operation))
  assert manager.resolve(registry, record.id) == Error(manager.Unavailable)
  assert manager.open(registry, record.id) == Error(manager.Unavailable)
  process.send(release_drain, Nil)
  await_status(registry, record.id, manager.Saved)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn registry_death_requests_cleanup_without_losing_builder_custody_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = saved(store, 8)
  let built = process.new_subject()
  let closed = process.new_subject()
  let registry =
    start(store, 1, fn(record, owner) {
      let assert Ok(Nil) =
        custody.publish(owner, custody.Storage, fn() {
          process.send(closed, Nil)
          Ok(Nil)
        })
        as "independent cleanup holds partial resources"
      let release = process.new_subject()
      process.send(built, #(release, custody.owner(owner)))
      process.receive_forever(release)
      Ok(record.id)
    })
  process.unlink(manager.pid(registry))
  let assert Ok(manager.Opening(_)) = manager.open(registry, record.id)
    as "builder admitted"
  let assert Ok(#(release, owner)) = process.receive(built, 1000)
    as "assembly has published resources but has not returned"
  let watch = process.monitor(owner)
  let registry_watch = process.monitor(manager.pid(registry))
  process.kill(manager.pid(registry))
  let _gone = down(registry_watch)

  assert manager.get(registry, record.id) == Error(manager.Unavailable)
  assert manager.open(registry, record.id) == Error(manager.Unavailable)
  assert manager.stop_session(registry, record.id) == Error(manager.Unavailable)
  assert manager.page(registry, after: "") == Error(manager.Unavailable)
  assert manager.resolve(registry, record.id) == Error(manager.Unavailable)
  assert process.receive(closed, 0) == Error(Nil)
  process.send(release, Nil)
  assert process.receive(closed, 1000) == Ok(Nil)
  let assert process.ProcessDown(reason: process.Normal, ..) = down(watch)
    as "registry loss cancels and drains its independent custody scope"
  assert catalogue.close(store) == Ok(Nil)
}

pub fn uninitialized_and_unknown_sessions_do_not_consume_capacity_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let pending = registration(9)
  assert catalogue.reserve(store, pending) == Ok(pending)
  let ready = saved(store, 10)
  let builds = process.new_subject()
  let registry =
    start(store, 1, fn(record, _) {
      process.send(builds, record.id)
      Ok(record.id)
    })
  assert manager.open(registry, pending.id) == Error(manager.NotInitialized)
  assert manager.open(registry, "unknown")
    == Error(manager.Catalogue(catalogue.Missing))
  assert manager.stop_session(registry, "unknown")
    == Error(manager.Catalogue(catalogue.Missing))
  assert process.receive(builds, 0) == Error(Nil)
  let assert Ok(manager.Opening(operation)) = manager.open(registry, ready.id)
    as "refused requests left the sole capacity slot free"
  await_status(registry, ready.id, manager.Resident(operation))
  assert process.receive(builds, 1000) == Ok(ready.id)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn outer_shutdown_waits_for_registry_to_drain_before_normal_exit_test() {
  process.trap_exits(True)
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = saved(store, 12)
  let draining = process.new_subject()
  let assert Ok(daemon) =
    lifetime.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, owner) {
          let assert Ok(Nil) =
            custody.publish(owner, custody.Storage, fn() {
              let release = process.new_subject()
              process.send(draining, release)
              process.receive_forever(release)
              Ok(Nil)
            })
            as "original custody owns the delayed drain"
          Ok(record.id)
        },
        fatal: fn(_) { [] },
      ),
      epoch: "lifetime-test",
      limit: 1,
    )
    as "daemon lifetime starts"
  let registry = lifetime.registry(daemon)
  let watch = process.monitor(lifetime.witness(daemon))
  let assert Ok(manager.Opening(operation)) = manager.open(registry, record.id)
    as "instance admitted"
  await_status(registry, record.id, manager.Resident(operation))

  // Outer cancellation kills the managed worker, which is the registry's
  // starter. That parent loss must request ordered shutdown, not normal exit.
  lifetime.shutdown(daemon)
  let assert Ok(release) = process.receive(draining, 1000)
    as "registry has begun shutdown after starter loss"
  assert manager.open(registry, record.id) == Error(manager.Unavailable)
  assert manager.get(registry, record.id)
    == Ok(manager.View(record, manager.Stopping(operation)))
  assert process.is_alive(lifetime.witness(daemon))
  let no_proof =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(20)
  assert no_proof == Error(Nil)
  process.send(release, Nil)
  let assert process.ProcessDown(reason: process.Normal, ..) = down(watch)
    as "outer normal exit follows all original custody proofs"
  assert catalogue.close(store) == Ok(Nil)
  process.trap_exits(False)
}

pub fn registry_kill_loses_outer_proof_even_when_inner_cleanup_finishes_test() {
  process.trap_exits(True)
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = saved(store, 13)
  let built = process.new_subject()
  let draining = process.new_subject()
  let assert Ok(daemon) =
    lifetime.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, owner) {
          let assert Ok(Nil) =
            custody.publish(owner, custody.Storage, fn() {
              let release = process.new_subject()
              process.send(draining, release)
              process.receive_forever(release)
              Ok(Nil)
            })
            as "cleanup survives registry loss"
          process.send(built, custody.owner(owner))
          Ok(record.id)
        },
        fatal: fn(_) { [] },
      ),
      epoch: "lifetime-test",
      limit: 1,
    )
    as "daemon lifetime starts"
  let registry = lifetime.registry(daemon)
  let watch = process.monitor(lifetime.witness(daemon))
  let assert Ok(manager.Opening(operation)) = manager.open(registry, record.id)
    as "instance admitted"
  let assert Ok(owner) = process.receive(built, 1000) as "custody published"
  let inner_watch = process.monitor(owner)
  await_status(registry, record.id, manager.Resident(operation))
  process.kill(manager.pid(registry))
  let outer = down(watch)
  assert outer.reason != process.Normal
  let assert Ok(release) = process.receive(draining, 1000)
    as "inner scope still performs independent cleanup"
  assert process.is_alive(owner)
  process.send(release, Nil)
  let assert process.ProcessDown(reason: process.Normal, ..) = down(inner_watch)
    as "inner cleanup can succeed after the aggregate proof was lost"

  // The production root knows only its original outer verdict. Later inner
  // success is not a new aggregate proof and cannot authorize lock release.
  assert !process.is_alive(lifetime.witness(daemon))
  assert outer.reason != process.Normal
  assert catalogue.close(store) == Ok(Nil)
  process.trap_exits(False)
}

pub fn registry_kill_with_failed_cleanup_never_proves_outer_retirement_test() {
  process.trap_exits(True)
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = saved(store, 14)
  let built = process.new_subject()
  let released = process.new_subject()
  let assert Ok(daemon) =
    lifetime.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, owner) {
          let assert Ok(Nil) =
            custody.publish(owner, custody.Runtime, fn() {
              Error("injected lifetime drain failure")
            })
            as "runtime cleanup can fail after the registry dies"
          let assert Ok(Nil) =
            custody.publish(owner, custody.Storage, fn() {
              process.send(released, Nil)
              Ok(Nil)
            })
            as "storage remains behind failed runtime cleanup"
          process.send(built, owner)
          Ok(record.id)
        },
        fatal: fn(_) { [] },
      ),
      epoch: "lifetime-test",
      limit: 1,
    )
    as "daemon lifetime starts"
  let registry = lifetime.registry(daemon)
  let watch = process.monitor(lifetime.witness(daemon))
  let assert Ok(manager.Opening(operation)) = manager.open(registry, record.id)
    as "instance admitted"
  let assert Ok(owner) = process.receive(built, 1000) as "custody published"
  await_status(registry, record.id, manager.Resident(operation))
  process.kill(manager.pid(registry))
  assert down(watch).reason != process.Normal
  let assert custody.RecoveryBlocked(custody.Failed(custody.Runtime, reason)) =
    custody.close(owner, within_ms: 1000)
    as "inner cleanup retains its unresolved reservation"
  assert reason == "injected lifetime drain failure"
  assert process.receive(released, 0) == Error(Nil)
  assert process.is_alive(custody.owner(owner))
  assert catalogue.close(store) == Ok(Nil)
  process.trap_exits(False)
}

pub fn outer_lifetime_survives_repeated_incarnations_with_one_registry_test() {
  process.trap_exits(True)
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = saved(store, 15)
  let assert Ok(daemon) =
    lifetime.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, _) { Ok(record.id) },
        fatal: fn(_) { [] },
      ),
      epoch: "lifetime-test",
      limit: 1,
    )
    as "daemon lifetime starts"
  let registry = lifetime.registry(daemon)
  let witness = lifetime.witness(daemon)
  let watch = process.monitor(witness)
  let _last =
    int.range(from: 0, to: 32, with: "", run: fn(previous, _) {
      let assert Ok(manager.Opening(operation)) =
        manager.open(registry, record.id)
        as "each cycle can reuse the sole live reservation"
      assert operation != previous
      await_status(registry, record.id, manager.Resident(operation))
      assert manager.stop_session(registry, record.id)
        == Ok(manager.Stopping(operation))
      await_status(registry, record.id, manager.Saved)
      await_domains_retired(registry)
      assert process.is_alive(witness)
      operation
    })

  // Only the registry is adopted into the outer scope. Incarnation monitors
  // stay in its bounded slot map and are removed after each normal retirement.
  lifetime.shutdown(daemon)
  let assert process.ProcessDown(reason: process.Normal, ..) = down(watch)
    as "the unchanged outer witness retires after all repeated opens"
  assert catalogue.close(store) == Ok(Nil)
  process.trap_exits(False)
}

/// One registry turn answers every question a socket frame's authority rests
/// on: the daemon's lifetime, the session's retained incarnation, and the
/// credential's current membership.
///
/// Each refusal is distinct, because the transport reports "revoked" and
/// "stale" to the attached client in different words, and a collapsed answer
/// that could not tell them apart would report a revocation as an outage.
pub fn one_turn_answers_epoch_incarnation_and_authority_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = saved(store, 700)
  let assert Ok(owner_digest) = access.credential_digest(string.repeat("a", 64))
    as "owner digest is valid"
  let assert Ok(member_digest) =
    access.credential_digest(string.repeat("b", 64))
    as "member digest is valid"
  let assert Ok(owner) =
    access.bootstrap_owner(store, "owner", "Owner", owner_digest)
    as "the durable owner is established"
  let assert Ok(member) =
    access.create_member(store, "reader", "Reader", member_digest)
    as "the participant exists"
  let assert Ok(Nil) =
    access.grant(store, member.id, record.id, access.Observer)
    as "membership grants only this session"
  let registry = start(store, 2, fn(record, _) { Ok(record.id) })

  // Nothing is resident, so the credential is never read: the answer is
  // already no, and reading it would make a stale socket a membership probe.
  assert manager.frame_authority(
      registry,
      epoch: "daemon-test",
      id: record.id,
      incarnation: "daemon-test:0",
      digest: owner_digest,
    )
    == Error(manager.StaleIncarnation)

  let assert Ok(manager.Opening(operation)) = manager.open(registry, record.id)
    as "explicit admission"
  await_status(registry, record.id, manager.Resident(operation))

  assert manager.frame_authority(
      registry,
      epoch: "daemon-test",
      id: record.id,
      incarnation: operation,
      digest: owner_digest,
    )
    == Ok(#(owner, access.Owner))
  assert manager.frame_authority(
      registry,
      epoch: "daemon-test",
      id: record.id,
      incarnation: operation,
      digest: member_digest,
    )
    == Ok(#(member, access.Participant(access.Observer)))
  assert manager.frame_authority(
      registry,
      epoch: "previous",
      id: record.id,
      incarnation: operation,
      digest: owner_digest,
    )
    == Error(manager.StaleEpoch)
  assert manager.frame_authority(
      registry,
      epoch: "daemon-test",
      id: record.id,
      incarnation: "daemon-test:99",
      digest: owner_digest,
    )
    == Error(manager.StaleIncarnation)

  // Revocation is answered by the very next frame check. It reaches the
  // catalogue through `administer`, which is the only way a running daemon
  // writes the credential, principal and membership tables, and which drops
  // the registry's remembered authorities as it goes. Revoking behind the
  // registry's back by writing `store` directly is not a path any production
  // caller has, and a test that took it would be pinning the mechanism rather
  // than the property.
  assert manager.administer(
      registry,
      owner_digest,
      "daemon-test",
      manager.RevokeMembership(member.id, record.id),
    )
    == Ok(member)
  assert manager.frame_authority(
      registry,
      epoch: "daemon-test",
      id: record.id,
      incarnation: operation,
      digest: member_digest,
    )
    == Error(manager.Unauthorized)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

/// A remembered frame authority does not outlive the slot it was resolved for.
///
/// The memo is keyed by credential and session, not by incarnation, so an entry
/// left behind by a retired slot would be read again when the same session
/// reopens. This fixture revokes while nothing is resident — the window in which
/// the registry sees no `Administer` and drops nothing — and the reopened
/// session must refuse the member. It also pins the bound on the memo: entries
/// belong to resident sessions, not to every session the daemon has ever held.
pub fn a_retired_slot_takes_its_remembered_authority_with_it_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = saved(store, 720)
  let assert Ok(owner_digest) = access.credential_digest(string.repeat("c", 64))
    as "owner digest is valid"
  let assert Ok(member_digest) =
    access.credential_digest(string.repeat("d", 64))
    as "member digest is valid"
  let assert Ok(_owner) =
    access.bootstrap_owner(store, "owner", "Owner", owner_digest)
    as "the durable owner is established"
  let assert Ok(member) =
    access.create_member(store, "reader", "Reader", member_digest)
    as "the participant exists"
  let assert Ok(Nil) =
    access.grant(store, member.id, record.id, access.Observer)
    as "membership grants only this session"
  let registry = start(store, 1, fn(record, _) { Ok(record.id) })

  let assert Ok(manager.Opening(operation)) = manager.open(registry, record.id)
    as "explicit admission"
  await_status(registry, record.id, manager.Resident(operation))
  assert manager.frame_authority(
      registry,
      epoch: "daemon-test",
      id: record.id,
      incarnation: operation,
      digest: member_digest,
    )
    == Ok(#(member, access.Participant(access.Observer)))

  // The slot retires, and with it the answer just remembered for this member.
  let _closing = manager.stop_session(registry, record.id)
  await_status(registry, record.id, manager.Saved)
  await_domains_retired(registry)

  // Writing the catalogue directly is the point of the fixture rather than an
  // impersonation of a production path: it changes membership without the
  // `Administer` message that would drop the memo wholesale, so only the
  // removal at slot retirement can be what makes the next answer current.
  assert access.revoke_membership(store, member.id, record.id) == Ok(Nil)

  let assert Ok(manager.Opening(reopened)) = manager.open(registry, record.id)
    as "the saved identity reopens under a new incarnation"
  await_status(registry, record.id, manager.Resident(reopened))
  assert manager.frame_authority(
      registry,
      epoch: "daemon-test",
      id: record.id,
      incarnation: reopened,
      digest: member_digest,
    )
    == Error(manager.Unauthorized)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

/// Domain source enumeration walks its pages on the builder's own process.
///
/// A hundred and twenty sources span two pages, so a walk that stopped at the
/// first one would answer with a hundred and would look exactly like a domain
/// that is smaller than it is.
pub fn domain_sources_are_enumerated_across_pages_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let records = shared_domain_sessions(store, 120)
  let enumerated = process.new_subject()
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, sources, _) {
          process.send(enumerated, sources())
          Ok(domain_service.inert())
        },
        build: fn(record, _domain, _services, _) { Ok(record.id) },
        fatal: fn(_) { [] },
      ),
      epoch: "domain-sources",
      limit: 2,
    )
    as "registry starts"
  let assert Ok(first) = list.first(records) as "the fixture has a session"
  let assert Ok(manager.Opening(operation)) = manager.open(registry, first.id)
    as "opening one session builds the shared domain"
  let assert Ok(Ok(sources)) = process.receive(enumerated, 5000)
    as "the domain builder resolves its own sources"
  assert list.length(sources) == 120
  assert list.contains(
    list.map(sources, fn(source: distill.Source) { source.path }),
    first.path,
  )
  await_status(registry, first.id, manager.Resident(operation))
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

/// The bounded source cap survives moving the walk off the registry: an
/// oversized domain is refused rather than truncated to an
/// authorized-looking prefix.
pub fn an_oversized_domain_refuses_its_source_enumeration_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let records = shared_domain_sessions(store, 513)
  let enumerated = process.new_subject()
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, sources, _) {
          process.send(enumerated, sources())
          Ok(domain_service.inert())
        },
        build: fn(record, _domain, _services, _) { Ok(record.id) },
        fatal: fn(_) { [] },
      ),
      epoch: "domain-cap",
      limit: 2,
    )
    as "registry starts"
  let assert Ok(first) = list.first(records) as "the fixture has a session"
  let assert Ok(manager.Opening(operation)) = manager.open(registry, first.id)
    as "opening one session builds the shared domain"
  assert process.receive(enumerated, 10_000)
    == Ok(Error("domain exceeds the bounded source limit"))
  await_status(registry, first.id, manager.Resident(operation))
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

// Every registration shares one workspace, so all of them bind to the same
// `WorkspacePrivate` domain and its source enumeration has to page.
fn shared_domain_sessions(
  store: catalogue.Catalogue,
  count: Int,
) -> List(catalogue.Registration) {
  let anchor = raw_saved(store, 6000)
  let shared =
    domain.Domain(
      domain.key(domain.WorkspacePrivate, anchor.workspace, anchor.id),
      domain.WorkspacePrivate,
      anchor.workspace,
      "",
      "/fixture-domains/shared/memory.db",
      "/fixture-domains/shared/search.db",
    )
  assert domain.bind(store, anchor.id, shared) == Ok(shared)
  let rest =
    list.index_map(list.repeat(Nil, count - 1), fn(_, offset) {
      let index = offset + 1
      let record = raw_saved(store, 6000 + index)
      assert domain.bind(store, record.id, shared) == Ok(shared)
      record
    })
  [anchor, ..rest]
}

// Saved describes the session. Reopening also requires the last shared domain's
// original normal retirement, observed without repeating an admission request.
fn await_domains_retired(registry) {
  assert poll.until(within: 2000, every: 1, attempt: fn() {
      case manager.summary(registry) {
        Ok(manager.Summary(domain_occupied: 0, ..)) -> poll.Done(Nil)
        Ok(manager.Summary(domain_blocked: blocked, ..)) if blocked > 0 ->
          poll.Fail("domain cleanup lost retirement proof")
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(string.inspect(error))
      }
    })
    == poll.Answered(Nil)
}

// A daemon killed with SIGKILL leaves two shapes of durable wreckage behind:
// registrations whose creation never reconciled, and databases whose writer
// lease was never released. The first shape is what these two tests are about;
// the second reaches the registry as a builder error.
pub fn incomplete_reservation_lists_as_reserved_rather_than_saved_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let pending = registration(931)
  assert catalogue.reserve(store, pending) == Ok(pending)
  let ready = saved(store, 932)
  let registry = start(store, 2, fn(record, _) { Ok(record.id) })

  // The rows a terminal renders. The reservation must not wear the same label
  // as the session beside it, because only one of the two can be opened, and
  // reading liveness alone reported both of them as saved.
  let assert Ok(#(_revision, rows)) = manager.page(registry, after: "")
    as "listing reads metadata without opening either path"
  let labelled = list.map(rows, fn(row) { #(row.registration.id, row.status) })
  assert list.key_find(labelled, pending.id) == Ok(manager.Reserved)
  assert list.key_find(labelled, ready.id) == Ok(manager.Saved)

  // And the label tells the truth: the reservation is still not openable.
  assert manager.open(registry, pending.id) == Error(manager.NotInitialized)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn failed_builder_answers_its_own_operation_rather_than_stale_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = saved(store, 941)

  // What a stranded writer lease looks like from here: the builder reaches
  // the session's own database and is refused by its dead predecessor.
  let registry = start(store, 1, fn(_record, _) { Error("storage refused") })
  let assert Ok(manager.Opening(operation)) = manager.open(registry, record.id)
    as "admission accepts the open before the builder runs"

  // Cleanup drains and deletes the slot, usually before the requesting
  // terminal polls at all. That is what used to make a failure indistinguishable
  // from a request some replacement had overtaken.
  await_status(registry, record.id, manager.Saved)
  assert manager.operation(registry, record.id, operation)
    == Error(manager.StartFailed)

  // One open is all the memo answers for; anything else is genuinely stale.
  assert manager.operation(registry, record.id, "another-operation")
    == Error(manager.StaleOperation)
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
}
