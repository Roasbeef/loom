//// The catalogue's record of the top-level sessions another orchestrator's page
//// started here (protocol-change/094, catalogue version 19).
////
//// The properties pinned here are the ones the protocol rests on. A create is
//// one transaction, so a request id that was seen answers the session it made,
//// two creates at the cap cannot both pass (raced across connections, the only
//// place a race can exist, as `catalogue_parallel_test` explains), archiving
//// frees a place, deleting a session removes its row, and a catalogue at version
//// eighteen gains the table when it opens.

import core/clock
import core/ids
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import sqlight
import storage/catalogue
import storage/domain
import support/fixtures

fn registration(seed: Int, spawner: String, request_id: String) {
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(1000 + seed), seed))
  let id = ids.session_id_to_string(id)
  catalogue.Registration(
    id:,
    path: "/never-opened-relayed/" <> id <> ".db",
    workspace: "/workspace",
    name: "Relayed " <> int.to_string(seed),
    configuration: "",
    created_at: 1000 + seed,
    request_key: catalogue.relayed_key(spawner, request_id),
    state: catalogue.Reserved,
    profile: None,
    model: None,
    executor: "",
    pool: "",
    subtitle: None,
  )
}

fn mapping(record: catalogue.Registration) {
  domain.Domain(
    domain.key(domain.SessionOnly, record.workspace, record.id),
    domain.SessionOnly,
    record.workspace,
    "",
    "/never-opened-relayed/" <> record.id <> "/memory.db",
    "/never-opened-relayed/" <> record.id <> "/search.db",
  )
}

fn limits(max_sessions: Int, max_per_hour: Int, now_ms: Int) {
  catalogue.RelayedLimits(max_sessions:, max_per_hour:, now_ms:)
}

fn request(n: Int) -> String {
  "0198c0de-0000-7000-8000-" <> int.to_string(100_000_000_000 + n)
}

// One create as the registry makes it: mint, then ask the catalogue.
fn create(
  store,
  spawner: String,
  n: Int,
  seed: Int,
  limit: catalogue.RelayedLimits,
) {
  let record = registration(seed, spawner, request(n))
  domain.reserve_relayed(
    store,
    spawner,
    request(n),
    limit,
    record,
    mapping(record),
  )
}

pub fn a_new_create_writes_the_registration_the_mapping_and_the_row_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let assert Ok(catalogue.RelayedMade(record:, registration: saved)) =
    create(store, "laptop", 1, 1, limits(4, 10, 5000))
  assert saved.state == catalogue.Reserved
  assert record.spawner == "laptop"
  assert record.request_id == request(1)
  assert record.session_id == saved.id
  assert record.created_at == 5000

  // All three are there, and the row reads back both ways.
  assert catalogue.get(store, saved.id) |> result_state
    == Ok(catalogue.Reserved)
  let assert Ok(_) = domain.for_session(store, saved.id)
  assert catalogue.relayed_for(store, "laptop", request(1)) == Ok(Some(record))
  assert catalogue.relayed_of(store, saved.id) == Ok(Some(record))
  assert catalogue.close(store) == Ok(Nil)
}

fn result_state(
  found: Result(catalogue.Registration, catalogue.Error),
) -> Result(catalogue.State, catalogue.Error) {
  result.map(found, fn(record) { record.state })
}

pub fn a_resent_request_answers_the_same_session_and_writes_nothing_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let assert Ok(catalogue.RelayedMade(record:, ..)) =
    create(store, "laptop", 1, 1, limits(4, 10, 5000))

  // The resend carries a registration of its own minting, which the catalogue
  // must not use: the first one stands, even when the caps are full.
  assert create(store, "laptop", 1, 2, limits(1, 1, 9000))
    == Ok(catalogue.RelayedFound(record:))
  assert catalogue.relayed_held(store, "laptop") == Ok(1)
  assert catalogue.relayed_since(store, "laptop", 0) == Ok(1)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_request_id_belongs_to_one_spawner_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let assert Ok(catalogue.RelayedMade(..)) =
    create(store, "laptop", 1, 1, limits(4, 10, 5000))
  assert create(store, "desk", 1, 2, limits(4, 10, 5000))
    == Error(catalogue.Conflict)
  assert catalogue.relayed_held(store, "desk") == Ok(0)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_malformed_spawner_or_request_id_is_refused_and_writes_nothing_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = registration(1, "laptop", "ok")
  let assert Error(catalogue.Invalid(_)) =
    domain.reserve_relayed(
      store,
      "laptop",
      "",
      limits(4, 10, 1),
      record,
      mapping(record),
    )
  let assert Error(catalogue.Invalid(_)) =
    domain.reserve_relayed(
      store,
      "laptop",
      "not a request id",
      limits(4, 10, 1),
      record,
      mapping(record),
    )
  let assert Error(catalogue.Invalid(_)) =
    domain.reserve_relayed(
      store,
      "Laptop",
      "ok",
      limits(4, 10, 1),
      record,
      mapping(record),
    )
  assert catalogue.get(store, record.id) == Error(catalogue.Missing)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn the_session_cap_counts_what_is_not_archived_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let assert Ok(catalogue.RelayedMade(registration: first, ..)) =
    create(store, "laptop", 1, 1, limits(2, 10, 5000))
  let assert Ok(catalogue.RelayedMade(..)) =
    create(store, "laptop", 2, 2, limits(2, 10, 5000))
  assert create(store, "laptop", 3, 3, limits(2, 10, 5000))
    == Ok(catalogue.RelayedCapped(cap: catalogue.RelayedSessions, limit: 2))

  // A capped create left nothing behind, not even its registration.
  assert catalogue.get(store, registration(3, "laptop", request(3)).id)
    == Error(catalogue.Missing)

  // Another spawner counts apart.
  let assert Ok(catalogue.RelayedMade(..)) =
    create(store, "desk", 4, 4, limits(2, 10, 5000))

  // Archiving frees the place at once, because the count joins the archive
  // state, and restoring takes it back.
  let assert Ok(_) =
    catalogue.set_visibility(store, first.id, catalogue.Archived)
  assert catalogue.relayed_held(store, "laptop") == Ok(1)
  let assert Ok(catalogue.RelayedMade(..)) =
    create(store, "laptop", 3, 3, limits(2, 10, 5000))
  assert catalogue.close(store) == Ok(Nil)
}

pub fn the_hourly_cap_counts_the_rolling_hour_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let assert Ok(catalogue.RelayedMade(..)) =
    create(store, "laptop", 1, 1, limits(10, 2, 1000))
  let assert Ok(catalogue.RelayedMade(..)) =
    create(store, "laptop", 2, 2, limits(10, 2, 2000))
  assert create(store, "laptop", 3, 3, limits(10, 2, 3000))
    == Ok(catalogue.RelayedCapped(cap: catalogue.RelayedPerHour, limit: 2))

  // The session cap is judged first, so a full spawner reports that cap.
  assert create(store, "laptop", 3, 3, limits(2, 2, 3000))
    == Ok(catalogue.RelayedCapped(cap: catalogue.RelayedSessions, limit: 2))

  // The window is the hour before the clock, exclusive of its start. At 999
  // ms past the first creation's hour both rows still count, and at the
  // first creation's hour exactly the first has left it.
  let hour = catalogue.relayed_hour_ms
  assert create(store, "laptop", 3, 3, limits(10, 2, 999 + hour))
    == Ok(catalogue.RelayedCapped(cap: catalogue.RelayedPerHour, limit: 2))
  let assert Ok(catalogue.RelayedMade(..)) =
    create(store, "laptop", 3, 3, limits(10, 2, 1000 + hour))
  assert catalogue.close(store) == Ok(Nil)
}

pub fn deleting_a_session_removes_its_row_and_frees_the_place_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let assert Ok(catalogue.RelayedMade(registration: first, record:)) =
    create(store, "laptop", 1, 1, limits(1, 10, 5000))
  assert create(store, "laptop", 2, 2, limits(1, 10, 5000))
    == Ok(catalogue.RelayedCapped(cap: catalogue.RelayedSessions, limit: 1))

  // The connection enforces foreign keys, so the delete would be refused if
  // the row were left behind to reference the registration.
  let assert Ok(_) = catalogue.delete(store, first.id)
  assert catalogue.relayed_of(store, first.id) == Ok(None)
  assert catalogue.relayed_for(store, "laptop", record.request_id) == Ok(None)
  let assert Ok(catalogue.RelayedMade(..)) =
    create(store, "laptop", 2, 2, limits(1, 10, 5000))
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_page_lists_newest_first_and_continues_after_the_last_row_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let made =
    list.map([1, 2, 3, 4, 5], fn(n) {
      let assert Ok(catalogue.RelayedMade(registration: saved, ..)) =
        create(store, "laptop", n, n * 10, limits(10, 10, 5000 + n))
      saved.id
    })
  let assert Ok(catalogue.RelayedMade(..)) =
    create(store, "desk", 9, 90, limits(10, 10, 5000))
  let newest_first = list.sort(made, fn(a, b) { string.compare(b, a) })

  let assert Ok(first) =
    catalogue.relayed_page(store, "laptop", after: "", limit: 2)
  assert list.map(first, fn(row) { row.record.session_id })
    == list.take(newest_first, 2)
  let assert Ok(last) = list.last(first)
  let assert Ok(rest) =
    catalogue.relayed_page(
      store,
      "laptop",
      after: last.record.session_id,
      limit: 10,
    )
  assert list.map(rest, fn(row) { row.record.session_id })
    == list.drop(newest_first, 2)

  // Only the spawner's own rows, with the archive state and the name.
  let assert Ok(archived) = list.first(newest_first)
  let assert Ok(_) =
    catalogue.set_visibility(store, archived, catalogue.Archived)
  let assert Ok(all) =
    catalogue.relayed_page(store, "laptop", after: "", limit: 64)
  assert list.length(all) == 5
  let assert Ok(head) = list.first(all)
  assert head.visibility == catalogue.Archived
  assert head.name == "Relayed 50"
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_page_is_never_larger_than_the_bound_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let assert Ok(rows) =
    catalogue.relayed_page(store, "laptop", after: "", limit: 10_000)
  assert rows == []
  assert catalogue.relayed_page_limit == 64
  let assert Error(catalogue.Invalid(_)) =
    catalogue.relayed_page(store, "Bad Name", after: "", limit: 4)
  assert catalogue.close(store) == Ok(Nil)
}

// SQLite reports a lock held by another connection as a busy error that the
// caller is expected to retry, and the transaction that met it wrote nothing.
// The daemon holds one connection and never meets it; this race opens a dozen.
fn create_when_free(store, n: Int, left: Int) {
  case create(store, "laptop", n, n, limits(3, 100, 5000)) {
    Error(catalogue.Database(_)) if left > 0 -> {
      process.sleep(20)
      create_when_free(store, n, left - 1)
    }
    outcome -> outcome
  }
}

pub fn racing_creates_across_connections_fill_exactly_the_cap_test() {
  let path = fixtures.scratch("relayed-race") <> "/catalogue.db"
  let assert Ok(seed) = catalogue.open(path) as "catalogue opens"
  assert catalogue.close(seed) == Ok(Nil)
  let attempts = [1, 2, 3, 4, 5, 6]
  let results = process.new_subject()
  list.each(attempts, fn(n) {
    process.spawn(fn() {
      let assert Ok(store) = catalogue.open(path) as "own connection opens"
      let outcome = create_when_free(store, n, 50)
      let _ = catalogue.close(store)
      process.send(results, outcome)
    })
  })
  let outcomes =
    list.map(attempts, fn(_) {
      let assert Ok(outcome) = process.receive(results, 20_000)
      outcome
    })
  let made =
    list.count(outcomes, fn(outcome) {
      case outcome {
        Ok(catalogue.RelayedMade(..)) -> True
        _ -> False
      }
    })
  let capped =
    list.count(outcomes, fn(outcome) {
      outcome
      == Ok(catalogue.RelayedCapped(cap: catalogue.RelayedSessions, limit: 3))
    })
  let other =
    list.filter(outcomes, fn(outcome) {
      case outcome {
        Ok(catalogue.RelayedMade(..)) -> False
        Ok(catalogue.RelayedCapped(..)) -> False
        _ -> True
      }
    })
  assert other == []
  assert made == 3
  assert capped == 3
  let assert Ok(check) = catalogue.open(path) as "catalogue reopens"
  assert catalogue.relayed_held(check, "laptop") == Ok(3)
  assert catalogue.close(check) == Ok(Nil)
}

pub fn version_eighteen_catalogue_gains_the_relayed_table_test() {
  let path = fixtures.scratch("relayed-migration") <> "/catalogue.db"
  let assert Ok(store) = catalogue.open(path) as "fixture catalogue opens"
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(old) = sqlight.open(path) as "fixture connection opens"
  assert sqlight.exec(
      "DROP TABLE catalogue_relayed_sessions; PRAGMA user_version=18",
      on: old,
    )
    == Ok(Nil)
  assert sqlight.close(old) == Ok(Nil)

  // The migration adds the table and moves the version in one step, and the
  // migrated catalogue records a relayed session.
  let assert Ok(migrated) = catalogue.open(path) as "version eighteen migrates"
  let assert Ok(catalogue.RelayedMade(..)) =
    create(migrated, "laptop", 1, 1, limits(4, 10, 5000))
  assert catalogue.close(migrated) == Ok(Nil)
  let assert Ok(check) = sqlight.open(path) as "version is readable"
  assert sqlight.query(
      "PRAGMA user_version",
      on: check,
      with: [],
      expecting: decode.at([0], decode.int),
    )
    == Ok([catalogue.current_version])
  assert sqlight.close(check) == Ok(Nil)
}
