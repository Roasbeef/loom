//// Seeding the directory store from a version 12 catalogue
//// (protocol-change/079), over a real registry and a one-member Khepri store
//// in the test VM. Each custody row becomes the record the table in
//// `client/directory/migrate` names, a conflict is left standing and reported,
//// the marker is written last, and a second run does nothing. The store is a
//// VM-wide singleton, so the module is serial.

import client/daemon/domain as domain_service
import client/daemon/manager
import client/directory/migrate
import client/directory/ownership
import client/directory/record.{Moving, Record, Serving}
import client/directory/store
import client/orchestrators
import core/clock
import core/ids
import gleam/option.{None, Some}
import simplifile
import storage/catalogue
import storage/domain
import support/remote_fixtures
import telemetry/log

const alpha = "alpha@10.0.0.1"

const bravo = "bravo@10.0.0.4"

const stranger = "zeta@10.0.0.9"

fn op(n: Int) -> String {
  "0192f3c1-0000-7000-8000-00000000000" <> int_digit(n)
}

fn int_digit(n: Int) -> String {
  case n {
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    _ -> "5"
  }
}

fn absolute(path: String) -> String {
  let assert Ok(cwd) = simplifile.current_directory() as "a working directory"
  cwd <> "/" <> path
}

fn registry(
  directory: String,
) -> #(catalogue.Catalogue, manager.Manager(String)) {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, _owner, _directory) {
          Ok(record.id)
        },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
      epoch: "migrate-test",
      limit: 2,
    )
    as "the registry starts"
  let _ = directory
  #(store, registry)
}

// A confirmed registration, on the executor `box` unless `executor` is empty.
fn registered(
  store: catalogue.Catalogue,
  directory: String,
  seed: Int,
  executor: String,
) -> String {
  let #(minted, _) =
    ids.mint_session(ids.generator(clock.fixed(1_700_000_000_000), seed))
  let id = ids.session_id_to_string(minted)
  let record =
    catalogue.Registration(
      id:,
      path: directory <> "/" <> id <> ".db",
      workspace: case executor {
        "" -> directory
        _ -> "repo"
      },
      name: "seeded",
      configuration: "",
      profile: None,
      executor:,
      pool: "",
      created_at: 1_700_000_000_000,
      request_key: "key-" <> id,
      state: catalogue.Reserved,
      subtitle: None,
    )
  let selected = manager.session_only_domain(record, "", directory)
  let assert Ok(_) = domain.reserve_session(store, record, selected)
    as "reserved"
  let assert Ok(_) = catalogue.confirm(store, id) as "confirmed"
  id
}

pub fn a_catalogue_seeds_one_record_per_remote_session_test() {
  let directory = absolute(remote_fixtures.scratch("migrate"))
  let assert Ok(Nil) = store.start_system(directory <> "/directory")
    as "the Ra system starts"
  let assert Ok(Nil) = store.boot(10_000) as "a one-member store starts"
  let #(catalog, registry) = registry(directory)
  let own = ownership.over_store(bravo)

  let resident = registered(catalog, directory, 1, "box")
  let local = registered(catalog, directory, 2, "")

  // Imported, with the sender's moving record already in the store.
  let arriving = registered(catalog, directory, 3, "box")
  let assert Ok(_) =
    catalogue.import_session(catalog, arriving, op: op(1), from: "alpha")
    as "imported"
  let assert Ok(Nil) =
    store.create(
      arriving,
      Record(owner: alpha, state: Moving(op: op(1), to: bravo)),
    )
    as "the sender seeded first"

  // Imported, with nothing in the store yet.
  let arrived = registered(catalog, directory, 4, "box")
  let assert Ok(_) =
    catalogue.import_session(catalog, arrived, op: op(2), from: "alpha")
    as "imported"

  // Moving, not yet activated.
  let leaving = registered(catalog, directory, 5, "box")
  let assert Ok(_) =
    catalogue.begin_move(catalog, leaving, op: op(3), to: "alpha")
    as "moving"

  // Moving, and the receiver already seeded its own record.
  let gone = registered(catalog, directory, 6, "box")
  let assert Ok(_) = catalogue.begin_move(catalog, gone, op: op(4), to: "alpha")
    as "moving"
  let assert Ok(Nil) = store.create(gone, Record(owner: alpha, state: Serving))
    as "the receiver seeded first"

  // Moved away: nothing to write.
  let moved = registered(catalog, directory, 7, "box")
  let assert Ok(_) =
    catalogue.begin_move(catalog, moved, op: op(5), to: "alpha")
    as "moving"
  let assert Ok(_) = catalogue.finish_move(catalog, moved, op: op(5)) as "moved"

  // A restored backup: another daemon's record for a session this one serves.
  let doubled = registered(catalog, directory, 8, "box")
  let assert Ok(Nil) =
    store.create(doubled, Record(owner: stranger, state: Serving))
    as "someone else holds it"

  let listed = [orchestrators.plain("alpha", alpha)]
  let assert Ok(migrate.Done(written:, conflicts:)) =
    migrate.seed(registry, own, listed, log.discard())
    as "the catalogue seeds"
  assert conflicts == [doubled]
  assert written == 4
  assert store.read(resident) == Ok(Some(Record(owner: bravo, state: Serving)))
  assert store.read(local) == Ok(None)
  assert store.read(arriving) == Ok(Some(Record(owner: bravo, state: Serving)))
  assert store.read(arrived) == Ok(Some(Record(owner: bravo, state: Serving)))
  assert store.read(leaving)
    == Ok(Some(Record(owner: bravo, state: Moving(op: op(3), to: alpha))))
  assert store.read(gone) == Ok(Some(Record(owner: alpha, state: Serving)))
  assert store.read(moved) == Ok(None)
  assert store.read(doubled)
    == Ok(Some(Record(owner: stranger, state: Serving)))
  assert store.migrated(bravo) == Ok(True)

  // A second run reads the marker and writes nothing.
  assert migrate.seed(registry, own, listed, log.discard())
    == Ok(migrate.AlreadyDone)
  store.stop()
}

pub fn a_seed_without_a_quorum_writes_no_marker_test() {
  let directory = absolute(remote_fixtures.scratch("migrate-starved"))
  let assert Ok(Nil) = store.start_system(directory <> "/directory")
    as "the Ra system starts"
  let assert Ok(Nil) = store.boot(10_000) as "a one-member store starts"
  let #(catalog, registry) = registry(directory)
  let _resident = registered(catalog, directory, 9, "box")
  store.stop()
  let assert Error(_) =
    migrate.seed(registry, ownership.over_store(bravo), [], log.discard())
    as "a store that cannot be read stops the run"
  Nil
}
