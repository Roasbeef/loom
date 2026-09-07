//// Catalogue persistence tests use real SQLite while leaving conversation
//// paths unopened. Runtime residency is deliberately absent from these rows.

import core/clock
import core/ids
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile
import sqlight
import storage/catalogue
import storage/catalogue_names_schema
import storage/sql
import storage/sql_schema
import support/fixtures

pub fn embedded_schema_matches_the_sqlc_input_test() {
  let assert Ok(schema) = simplifile.read("sql/schema.sql")
    as "canonical schema is checked in"
  assert sql_schema.schema == schema
  let assert Ok(names) = simplifile.read("sql/catalogue_names.sql")
    as "name migration is checked in"
  assert catalogue_names_schema.schema == names
}

pub fn generated_queries_match_the_sqlc_input_test() {
  let assert Ok(source) = simplifile.read("src/storage/sql/catalogue.sql")
    as "named catalogue queries are checked in"
  let generated = [
    sql.initialize_catalogue_revision().0,
    sql.find_registrations("", "", "").0,
    sql.insert_registration("", "", "", "", "", 0, "").0,
    sql.confirm_registration("").0,
    sql.registration_display_name("").0,
    sql.set_registration_display_name("", "").0,
    sql.registration_page("").0,
    sql.catalogue_revision().0,
    sql.member_registration_page("", "").0,
    sql.increment_catalogue_revision().0,
    sql.workspace_default("").0,
    sql.set_workspace_default("", "").0,
  ]
  assert normalize_queries(source)
    == normalize_queries(string.join(generated, "\n"))
}

// Parrot omits terminators and query-name comments. The statements retain
// their line structure, so compare the same normalized text as the search pilot.
fn normalize_queries(source: String) -> String {
  source
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(fn(line) { line != "" && !string.starts_with(line, "--") })
  |> list.map(fn(line) {
    case string.ends_with(line, ";") {
      True -> string.drop_end(line, 1)
      False -> line
    }
  })
  |> string.join("\n")
}

fn fresh_path(name: String) -> String {
  fixtures.scratch("catalogue-" <> name) <> "/catalogue.db"
}

pub fn display_rename_preserves_creation_retry_and_revision_test() {
  let path = fresh_path("display-rename")
  let assert Ok(store) = catalogue.open(path) as "catalogue opens"
  let record = registration(899)
  assert catalogue.reserve(store, record) == Ok(record)
  let assert Ok(before) = catalogue.page(store, after: "")
    as "original page loads"
  let renamed = catalogue.Registration(..record, name: "review auth")
  assert catalogue.rename(store, record.id, "review auth") == Ok(renamed)
  assert catalogue.get(store, record.id) == Ok(renamed)
  assert catalogue.by_request_key(store, record.request_key) == Ok(record)
  assert catalogue.reserve(store, record) == Ok(record)
  assert catalogue.reserve(store, renamed) == Error(catalogue.Conflict)
  let assert Ok(after) = catalogue.page(store, after: "")
    as "display page loads"
  assert after.records == [renamed]
  assert after.revision == before.revision + 1
  assert catalogue.rename(store, record.id, "review auth") == Ok(renamed)
  assert catalogue.page(store, after: "") == Ok(after)
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(reopened) = catalogue.open(path) as "catalogue reopens"
  assert catalogue.get(reopened, record.id) == Ok(renamed)
  assert catalogue.by_request_key(reopened, record.request_key) == Ok(record)
  assert catalogue.close(reopened) == Ok(Nil)
}

pub fn version_one_catalogue_migrates_without_losing_creation_test() {
  let path = fresh_path("rename-migration")
  let assert Ok(store) = catalogue.open(path) as "fixture catalogue opens"
  let record = registration(898)
  assert catalogue.reserve(store, record) == Ok(record)
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(old) = sqlight.open(path)
    as "fixture downgrades only its new empty table"
  assert sqlight.exec(
      "DROP TABLE catalogue_session_names; PRAGMA user_version=1",
      on: old,
    )
    == Ok(Nil)
  assert sqlight.close(old) == Ok(Nil)
  let assert Ok(migrated) = catalogue.open(path) as "version one migrates"
  assert catalogue.by_request_key(migrated, record.request_key) == Ok(record)
  let assert Ok(_) = catalogue.rename(migrated, record.id, "migrated")
    as "new name table works"
  assert catalogue.close(migrated) == Ok(Nil)
}

pub fn read_snapshots_do_not_reserve_the_writer_but_mutations_do_test() {
  let path = fresh_path("read-snapshot")
  let assert Ok(store) = catalogue.open(path) as "catalogue opens in WAL mode"
  let record = registration(805)
  assert catalogue.reserve(store, record) == Ok(record)
  assert catalogue.set_workspace_default(store, record.workspace, record.id)
    == Ok(record)
  let assert Ok(before) = catalogue.page(store, after: "")
    as "initial snapshot is readable"
  let assert Ok(writer) = sqlight.open(path)
    as "independent connection can contend"
  assert catalogue.statement(store, #("PRAGMA busy_timeout = 1", [])) == Ok(Nil)
  assert sqlight.exec("BEGIN IMMEDIATE", on: writer) == Ok(Nil)

  // A read snapshot coexists with the pending writer. Read-then-write operations
  // must instead acquire write intent before reading the registration they change.
  assert catalogue.page(store, after: "") == Ok(before)
  assert catalogue.workspace_default(store, record.workspace) == Ok(record)
  let assert Error(catalogue.Database(_)) = catalogue.confirm(store, record.id)
    as "a mutation cannot silently start as a read snapshot"
  assert sqlight.exec("ROLLBACK", on: writer) == Ok(Nil)
  let assert Ok(_) = catalogue.confirm(store, record.id)
    as "write succeeds after contention ends"
  assert sqlight.close(writer) == Ok(Nil)
  assert catalogue.close(store) == Ok(Nil)
}

fn registration(seed: Int) -> catalogue.Registration {
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed:)
  let #(id, _) = ids.mint_session(generator)
  let id = ids.session_id_to_string(id)
  catalogue.Registration(
    id:,
    path: "/unopened-loom-catalogue-test/" <> id <> ".db",
    workspace: "/workspace/quoted ' project",
    name: "review ' \" ; SELECT café",
    configuration: "/configuration/loom.toml",
    created_at: 1_700_000_000_000,
    request_key: "request-" <> int.to_string(seed),
    state: catalogue.Reserved,
  )
}

pub fn restore_lists_reservations_without_opening_sessions_test() {
  let path = fresh_path("restore")
  let assert Ok(store) = catalogue.open(path) as "fresh catalogue opens"
  let record = registration(1)
  assert catalogue.reserve(store, record) == Ok(record)
  assert simplifile.is_file(record.path) == Ok(False)
  assert catalogue.close(store) == Ok(Nil)

  let assert Ok(restored) = catalogue.open(path) as "saved catalogue reopens"
  assert catalogue.page(restored, after: "")
    == Ok(catalogue.Page(revision: 1, records: [record]))
  assert catalogue.get(restored, record.id) == Ok(record)
  assert simplifile.is_file(record.path) == Ok(False)
  assert catalogue.close(restored) == Ok(Nil)
}

pub fn completed_creation_retries_preserve_identity_and_revision_test() {
  let assert Ok(store) = catalogue.open(fresh_path("retry"))
    as "catalogue opens"
  let record = registration(2)
  let saved = catalogue.Registration(..record, state: catalogue.Saved)
  assert catalogue.reserve(store, record) == Ok(record)
  assert catalogue.confirm(store, record.id) == Ok(saved)
  assert catalogue.confirm(store, record.id) == Ok(saved)
  assert catalogue.reserve(store, record) == Ok(saved)
  assert catalogue.page(store, after: "")
    == Ok(catalogue.Page(revision: 2, records: [saved]))
  assert catalogue.close(store) == Ok(Nil)
}

pub fn conflicting_keys_identities_and_paths_do_not_mutate_test() {
  let assert Ok(store) = catalogue.open(fresh_path("conflicts"))
    as "catalogue opens"
  let first = registration(3)
  let second = registration(4)
  assert catalogue.reserve(store, first) == Ok(first)
  assert catalogue.reserve(
      store,
      catalogue.Registration(..first, name: "changed"),
    )
    == Error(catalogue.Conflict)
  assert catalogue.reserve(
      store,
      catalogue.Registration(..first, request_key: "another"),
    )
    == Error(catalogue.Conflict)
  assert catalogue.reserve(
      store,
      catalogue.Registration(..second, path: first.path),
    )
    == Error(catalogue.Conflict)
  assert catalogue.page(store, after: "")
    == Ok(catalogue.Page(revision: 1, records: [first]))
  assert catalogue.reserve(store, second) == Ok(second)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn metadata_pages_are_bounded_and_revisioned_test() {
  let assert Ok(store) = catalogue.open(fresh_path("pages"))
    as "catalogue opens"
  int.range(from: 10, to: 113, with: Nil, run: fn(_acc, seed) {
    let record = registration(seed)
    assert catalogue.reserve(store, record) == Ok(record)
  })
  let assert Ok(first) = catalogue.page(store, after: "") as "first page reads"
  assert list.length(first.records) == catalogue.page_limit
  assert first.revision == 103
  let assert Ok(last) = list.last(first.records)
    as "the first page has a cursor"
  let assert Ok(second) = catalogue.page(store, after: last.id)
    as "remaining page reads"
  assert list.length(second.records) == 3
  assert second.revision == first.revision
  let assert Ok(Nil) = catalogue.confirm(store, last.id) |> result.replace(Nil)
    as "confirmation changes durable metadata"
  let assert Ok(changed) = catalogue.page(store, after: last.id)
    as "page rereads"
  assert changed.revision == 104
  assert catalogue.close(store) == Ok(Nil)
}

pub fn unrelated_database_is_refused_without_schema_changes_test() {
  let path = fresh_path("unrelated")
  let assert Ok(db) = sqlight.open(path) as "unrelated SQLite file opens"
  let assert Ok(Nil) = sqlight.exec("CREATE TABLE keep_me(value TEXT)", on: db)
    as "unrelated schema exists"
  assert sqlight.close(db) == Ok(Nil)
  assert catalogue.open(path) == Error(catalogue.Unsupported)

  let assert Ok(db) = sqlight.open(path) as "unrelated file remains readable"
  assert sqlight.query(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
      on: db,
      with: [],
      expecting: decode.at([0], decode.string),
    )
    == Ok(["keep_me"])
  assert sqlight.close(db) == Ok(Nil)
}

pub fn unsupported_catalogue_version_is_refused_test() {
  let path = fresh_path("version")
  let assert Ok(store) = catalogue.open(path) as "catalogue opens"
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(db) = sqlight.open(path) as "test fixture opens"
  assert sqlight.exec("PRAGMA user_version=99", on: db) == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
  assert catalogue.open(path) == Error(catalogue.Unsupported)
}

pub fn malformed_persisted_state_is_an_error_not_a_partial_record_test() {
  let path = fresh_path("corrupt")
  let assert Ok(store) = catalogue.open(path) as "catalogue opens"
  let record = registration(5)
  assert catalogue.reserve(store, record) == Ok(record)
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(db) = sqlight.open(path) as "corruption fixture opens"
  assert sqlight.exec(
      "PRAGMA ignore_check_constraints=ON; UPDATE catalogue_sessions SET state='live'",
      on: db,
    )
    == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)

  let assert Ok(store) = catalogue.open(path)
    as "metadata header still validates"
  let assert Error(catalogue.Invalid(_)) = catalogue.page(store, after: "")
    as "unsupported row state cannot become runtime liveness"
  assert catalogue.close(store) == Ok(Nil)
}

pub fn request_lookup_recovers_original_creation_metadata_after_restart_test() {
  let path = fresh_path("request_lookup")
  let assert Ok(store) = catalogue.open(path) as "catalogue opens"
  let record = registration(120)
  assert catalogue.by_request_key(store, record.request_key)
    == Error(catalogue.Missing)
  assert catalogue.reserve(store, record) == Ok(record)
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(restored) = catalogue.open(path)
    as "reservation survives restart"
  assert catalogue.by_request_key(restored, record.request_key) == Ok(record)

  // A retried request reuses this original identity, path and timestamp. A
  // changed request carrying the same key must not overwrite the reservation.
  assert catalogue.reserve(restored, record) == Ok(record)
  assert catalogue.reserve(
      restored,
      catalogue.Registration(..record, name: "changed"),
    )
    == Error(catalogue.Conflict)
  assert catalogue.by_request_key(restored, record.request_key) == Ok(record)
  let saved = catalogue.Registration(..record, state: catalogue.Saved)
  assert catalogue.confirm(restored, record.id) == Ok(saved)
  assert catalogue.by_request_key(restored, record.request_key) == Ok(saved)
  assert catalogue.reserve(restored, record) == Ok(saved)
  assert catalogue.page(restored, after: "") == Ok(catalogue.Page(2, [saved]))
  assert simplifile.is_file(record.path) == Ok(False)
  assert catalogue.close(restored) == Ok(Nil)
}

pub fn workspace_default_persists_and_only_changes_revision_when_changed_test() {
  let path = fresh_path("workspace_default")
  let assert Ok(store) = catalogue.open(path) as "catalogue opens"
  let first = registration(121)
  let second = registration(122)
  assert catalogue.reserve(store, first) == Ok(first)
  assert catalogue.reserve(store, second) == Ok(second)
  assert catalogue.workspace_default(store, first.workspace)
    == Error(catalogue.Missing)
  assert catalogue.set_workspace_default(store, first.workspace, first.id)
    == Ok(first)
  assert catalogue.set_workspace_default(store, first.workspace, first.id)
    == Ok(first)
  let assert Ok(page) = catalogue.page(store, after: "") as "revision reads"
  assert page.revision == 3
  assert catalogue.set_workspace_default(store, first.workspace, second.id)
    == Ok(second)
  assert catalogue.close(store) == Ok(Nil)

  let assert Ok(restored) = catalogue.open(path) as "default survives restart"
  assert catalogue.workspace_default(restored, first.workspace) == Ok(second)
  assert catalogue.set_workspace_default(restored, first.workspace, second.id)
    == Ok(second)
  let assert Ok(page) = catalogue.page(restored, after: "")
    as "revision survives"
  assert page.revision == 4
  assert catalogue.by_request_key(restored, second.request_key) == Ok(second)
  assert simplifile.is_file(first.path) == Ok(False)
  assert simplifile.is_file(second.path) == Ok(False)
  assert catalogue.close(restored) == Ok(Nil)
}

pub fn workspace_default_refuses_another_workspace_without_mutation_test() {
  let assert Ok(store) = catalogue.open(fresh_path("wrong_workspace"))
    as "catalogue opens"
  let first = registration(123)
  let second =
    catalogue.Registration(..registration(124), workspace: "/other/project")
  assert catalogue.reserve(store, first) == Ok(first)
  assert catalogue.reserve(store, second) == Ok(second)
  assert catalogue.set_workspace_default(store, first.workspace, first.id)
    == Ok(first)
  assert catalogue.set_workspace_default(store, first.workspace, second.id)
    == Error(catalogue.Conflict)
  assert catalogue.set_workspace_default(store, second.workspace, first.id)
    == Error(catalogue.Conflict)
  assert catalogue.set_workspace_default(store, first.workspace, "missing")
    == Error(catalogue.Missing)
  assert catalogue.workspace_default(store, first.workspace) == Ok(first)
  assert catalogue.workspace_default(store, second.workspace)
    == Error(catalogue.Missing)
  let assert Ok(page) = catalogue.page(store, after: "") as "revision unchanged"
  assert page.revision == 3
  assert catalogue.close(store) == Ok(Nil)
}

pub fn corrupt_default_mapping_is_refused_on_read_test() {
  let path = fresh_path("corrupt_default")
  let assert Ok(store) = catalogue.open(path) as "catalogue opens"
  let record = registration(125)
  assert catalogue.reserve(store, record) == Ok(record)
  assert catalogue.set_workspace_default(store, record.workspace, record.id)
    == Ok(record)
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(db) = sqlight.open(path) as "corruption fixture opens"
  assert sqlight.exec(
      "UPDATE catalogue_defaults SET workspace='/wrong/workspace'",
      on: db,
    )
    == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
  let assert Ok(store) = catalogue.open(path)
    as "catalogue header remains valid"
  assert catalogue.workspace_default(store, "/wrong/workspace")
    == Error(catalogue.Invalid("workspace default refers to another workspace"))
  assert catalogue.close(store) == Ok(Nil)

  let assert Ok(db) = sqlight.open(path) as "dangling fixture opens"
  assert sqlight.exec(
      "UPDATE catalogue_defaults SET session_id='missing'",
      on: db,
    )
    == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
  let assert Ok(store) = catalogue.open(path) as "catalogue reopens"
  assert catalogue.workspace_default(store, "/wrong/workspace")
    == Error(catalogue.Invalid("workspace default refers to a missing session"))
  assert simplifile.is_file(record.path) == Ok(False)
  assert catalogue.close(store) == Ok(Nil)
}
