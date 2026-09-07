//// Durable creation recovery across reservation and identity publication.
//// Real catalogues and conversation databases survive registry replacement;
//// controlled assembly callbacks expose the two pre-confirmation boundaries.
//// Original custody, not a caller timeout, gates reuse of a partial database.
//// These tests do not replace whole-VM or native-helper crash acceptance.

import broker/token
import client/daemon/domain as domain_service
import client/daemon/manager
import client/internal/ffi_os
import client/internal/instance_owner as custody
import core/clock
import core/ids
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import session/session
import simplifile
import storage/catalogue
import storage/domain
import storage/sqlite
import support/internal/ffi_soak
import weft/poll

fn directory() {
  let assert Ok(here) = simplifile.current_directory()
    as "the fixture has a canonical package directory"
  let path =
    here
    <> "/build/test_db/creation-recovery-"
    <> bit_array.base16_encode(token.production_entropy()(16))
  assert simplifile.create_directory_all(path <> "/sessions") == Ok(Nil)
  path
}

fn request(key: String) {
  manager.Creation(key, "/workspace/creation-recovery", "saved draft", "")
}

fn create(registry, directory, request, seed) {
  manager.create(
    registry,
    request,
    directory: directory <> "/sessions",
    generator: ids.generator(clock.fixed(1_700_000_000_000), seed:),
  )
}

fn start(store, build) {
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _, _, owner) { build(record, owner) },
        fatal: fn(_) { [] },
      ),
      epoch: "creation-recovery-"
        <> int.to_string(ffi_os.unique_positive_integer()),
      limit: 1,
    )
    as "the registry restores metadata without running assembly"
  registry
}

// A different PID triggers cleanup, so observe delivery of our original
// monitor before releasing the crash. This helper never accepts a late noproc.
fn watch(pid) {
  let monitor = process.monitor(pid)
  let assert Ok(watchers) =
    decode.run(
      ffi_soak.process_info(pid, atom.create("monitored_by")),
      decode.at([1], decode.list(decode.dynamic)),
    )
    as "the live original owner reports its incoming monitors"
  assert list.any(watchers, fn(watcher) {
    string.inspect(watcher) == string.inspect(process.self())
  })
  monitor
}

fn down(monitor) {
  let assert Ok(down) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(5000)
    as "the original monitored process retires within the test deadline"
  down.reason
}

fn stop(registry) {
  let monitor = watch(manager.pid(registry))
  manager.shutdown(registry)
  assert down(monitor) == process.Normal
}

fn resident(registry, id) {
  assert poll.until(within: 5000, every: 1, attempt: fn() {
      case manager.get(registry, id) {
        Ok(manager.View(status: manager.Resident(_), ..)) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
    == poll.Answered(Nil)
}

// This is the production storage acquisition/publication/transfer/identity
// sequence, stopped before runtime construction and catalogue confirmation.
fn initialize(record: catalogue.Registration, owner: custody.Owner) {
  let assert Ok(#(opened, retire, transfer)) =
    session.open_sqlite_custody(
      path: record.path,
      owner: "creation-writer-"
        <> int.to_string(ffi_os.unique_positive_integer()),
      lease_ttl_ms: 60_000,
      clock: clock.fixed(1000),
    )
    as "one original connection acquires the real writer lease"
  assert custody.publish(owner, custody.Storage, fn() {
      retire() |> result.map_error(string.inspect)
    })
    == Ok(Nil)
  let assert Ok(storage_owner) = transfer()
    as "published custody owns storage independently of its builder"
  let assert Ok(id) = ids.parse_session_id(record.id)
    as "the catalogue reservation supplies the canonical identity"
  let assert Ok(_) = session.ensure_reserved_id(opened, id)
    as "the conversation persists that exact identity before confirmation"
  #(opened, storage_owner)
}

fn retry_after_restart(
  directory: String,
  record: catalogue.Registration,
  selected: domain.Domain,
) {
  let assert Ok(store) = catalogue.open(directory <> "/catalogue.db")
    as "a fresh catalogue connection reads the durable reservation"
  let builds = process.new_subject()
  let registry =
    start(store, fn(record, owner) {
      let _ = initialize(record, owner)
      process.send(builds, record.id)
      Ok(record.id)
    })
  assert catalogue.by_request_key(store, record.request_key) == Ok(record)
  assert domain.for_session(store, record.id) == Ok(selected)
  // The record is still `catalogue.Reserved`, and the status says so. It owns
  // no slot either, so reading liveness alone once answered `Saved` here —
  // the same answer an openable session gets, for a row `open` refuses.
  assert manager.get(registry, record.id)
    == Ok(manager.View(record, manager.Reserved))
  let assert Ok(#(_, views)) = manager.page(registry, after: "")
    as "listing remains available for an uninitialized reservation"
  assert list.any(views, fn(view) { view.registration == record })
  assert manager.open(registry, record.id) == Error(manager.NotInitialized)
  assert process.receive(builds, 0) == Error(Nil)

  // A different generator cannot turn the retry into a second database. Only
  // explicit create may cross the reserved-to-initialized boundary.
  let assert Ok(manager.View(retried, manager.Opening(_))) =
    create(registry, directory, request(record.request_key), 999)
    as "the original creation key resumes its original reservation"
  assert retried == record
  resident(registry, record.id)
  assert process.receive(builds, 1000) == Ok(record.id)
  assert process.receive(builds, 0) == Error(Nil)
  assert domain.for_session(store, record.id) == Ok(selected)
  assert catalogue.by_request_key(store, record.request_key)
    == Ok(catalogue.Registration(..record, state: catalogue.Saved))
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(#(Some(id), _)) = sqlite.identity(record.path)
    as "the reopened database retains its reserved identity"
  assert id == record.id
}

/// A crash after durable reservation cannot mint a different identity on retry.
///
/// ## Examples
///
/// `scripts/test.sh client --match reserved_creation_survives_registry_crash`.
pub fn reserved_creation_survives_registry_crash_before_assembly_test() {
  let directory = directory()
  let assert Ok(store) = catalogue.open(directory <> "/catalogue.db")
    as "the creation catalogue is on disk"
  let owners = process.new_subject()
  let registry =
    start(store, fn(record, owner) {
      process.send(owners, #(record.id, custody.owner(owner)))
      Ok(record.id)
    })
  let assert Ok(manager.View(blocker, _)) =
    create(registry, directory, request("occupy-capacity"), 801)
    as "a fixture instance holds the sole assembly slot"
  resident(registry, blocker.id)
  let assert Ok(#(_, owner)) = process.receive(owners, 1000)
    as "the original fixture custodian is published"
  let owner_watch = watch(owner)

  assert create(registry, directory, request("reserved-before-crash"), 802)
    == Error(manager.Capacity)
  let assert Ok(record) =
    catalogue.by_request_key(store, "reserved-before-crash")
    as "capacity refusal leaves the committed creation identity"
  assert record.state == catalogue.Reserved
  let assert Ok(selected) = domain.for_session(store, record.id)
    as "domain mapping commits with the reservation"
  assert simplifile.is_file(record.path) == Ok(False)
  assert process.receive(owners, 0) == Error(Nil)

  process.unlink(manager.pid(registry))
  let registry_watch = watch(manager.pid(registry))
  process.kill(manager.pid(registry))
  assert down(registry_watch) == process.Killed
  assert down(owner_watch) == process.Normal
  assert simplifile.is_file(record.path) == Ok(False)
  assert catalogue.close(store) == Ok(Nil)
  retry_after_restart(directory, record, selected)
}

/// Identity publication survives builder death without releasing a live lease.
///
/// ## Examples
///
/// `scripts/test.sh client --match identity_before_confirmation_survives_crash`.
pub fn identity_before_confirmation_survives_crash_and_restart_test() {
  let directory = directory()
  let assert Ok(store) = catalogue.open(directory <> "/catalogue.db")
    as "the interrupted creation catalogue is on disk"
  let initialized = process.new_subject()
  let draining = process.new_subject()
  let registry =
    start(store, fn(record, owner) {
      let #(opened, storage_owner) = initialize(record, owner)
      assert custody.publish(owner, custody.Runtime, fn() {
          let release = process.new_subject()
          process.send(draining, release)
          let assert Ok(Nil) = process.receive(release, 5000)
            as "only the test releases the original cleanup barrier"
          Ok(Nil)
        })
        == Ok(Nil)
      process.send(initialized, #(process.self(), owner, opened, storage_owner))
      let assert Ok(Nil) = process.receive(process.new_subject(), 5000)
        as "the test kills this builder before it can publish success"
      Ok(record.id)
    })
  let assert Ok(manager.View(record, manager.Opening(operation))) =
    create(registry, directory, request("identity-before-confirmation"), 803)
    as "creation reserves before starting the partial real assembly"
  let assert Ok(#(builder, owner, opened, storage_owner)) =
    process.receive(initialized, 5000)
    as "identity and storage custody are published before the crash"
  let assert Ok(selected) = domain.for_session(store, record.id)
    as "the original domain mapping is durable"
  let assert Ok(id) = ids.parse_session_id(record.id) as "identity is canonical"
  assert session.id(opened) == Ok(Some(id))
  assert catalogue.by_request_key(store, record.request_key) == Ok(record)
  let owner_watch = watch(custody.owner(owner))
  let storage_watch = watch(storage_owner)
  let builder_watch = watch(builder)
  process.kill(builder)
  assert down(builder_watch) == process.Killed
  let assert Ok(release) = process.receive(draining, 5000)
    as "builder death begins cleanup without releasing storage"
  assert custody.close(owner, within_ms: 20) == custody.StillClosing
  let assert Error(session.SqliteOpenFailed(sqlite.LeaseHeld(..))) =
    session.open_sqlite_owned(
      record.path,
      "competing-writer",
      60_000,
      clock.fixed(1001),
    )
    as "the partial database cannot acquire a competing writer"
  assert session.id(opened) == Ok(Some(id))
  assert create(registry, directory, request(record.request_key), 998)
    == Ok(manager.View(record, manager.Opening(operation)))
    as "retry joins the original reservation while its custody is unconfirmed"
  assert process.receive(initialized, 0) == Error(Nil)
    as "a repeated creation cannot start a second builder"
  assert catalogue.by_request_key(store, record.request_key) == Ok(record)

  process.send(release, Nil)
  assert down(storage_watch) == process.Normal
  assert down(owner_watch) == process.Normal
  stop(registry)
  assert catalogue.close(store) == Ok(Nil)
  retry_after_restart(directory, record, selected)
}
