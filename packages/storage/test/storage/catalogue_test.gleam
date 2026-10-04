//// Catalogue persistence tests use real SQLite while leaving conversation
//// paths unopened. Runtime residency is deliberately absent from these rows.

import core/clock
import core/ids
import core/tx
import core/workspace
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import sqlight
import storage/access
import storage/catalogue
import storage/catalogue_archives_schema
import storage/catalogue_claims_schema
import storage/catalogue_credential_kinds_schema
import storage/catalogue_logins_schema
import storage/catalogue_names_schema
import storage/catalogue_recent_folders_schema
import storage/catalogue_subtitles_schema
import storage/catalogue_workspace_bindings_schema
import storage/domain
import storage/sql
import storage/sql_schema
import storage/sqlite
import storage/storage
import support/fixtures

pub fn embedded_schema_matches_the_sqlc_input_test() {
  let assert Ok(schema) = simplifile.read("sql/schema.sql")
    as "canonical schema is checked in"
  assert sql_schema.schema == schema
  let assert Ok(names) = simplifile.read("sql/catalogue_names.sql")
    as "name migration is checked in"
  assert catalogue_names_schema.schema == names
  let assert Ok(archives) = simplifile.read("sql/catalogue_archives.sql")
    as "archive migration is checked in"
  assert catalogue_archives_schema.schema == archives
  let assert Ok(claims) = simplifile.read("sql/catalogue_claims.sql")
    as "claim migration is checked in"
  assert catalogue_claims_schema.schema == claims
  let assert Ok(kinds) = simplifile.read("sql/catalogue_credential_kinds.sql")
    as "credential-kind migration is checked in"
  assert catalogue_credential_kinds_schema.schema == kinds
  let assert Ok(subtitles) = simplifile.read("sql/catalogue_subtitles.sql")
    as "subtitle migration is checked in"
  assert catalogue_subtitles_schema.schema == subtitles
  let assert Ok(logins) = simplifile.read("sql/catalogue_logins.sql")
    as "login migration is checked in"
  assert catalogue_logins_schema.schema == logins
  let assert Ok(folders) = simplifile.read("sql/catalogue_recent_folders.sql")
    as "recent folders migration is checked in"
  assert catalogue_recent_folders_schema.schema == folders
  let assert Ok(bindings) =
    simplifile.read("sql/catalogue_workspace_bindings.sql")
    as "binding migration is checked in"
  assert catalogue_workspace_bindings_schema.schema == bindings
}

pub fn version_three_catalogue_migrates_claims_without_losing_principals_test() {
  let path = fresh_path("claim-migration")
  let assert Ok(store) = catalogue.open(path) as "fixture catalogue opens"
  let record = registration(894)
  assert catalogue.reserve(store, record) == Ok(record)
  let assert Ok(owner_digest) = access.credential_digest(string.repeat("a", 64))
    as "owner digest is valid"
  let assert Ok(member_digest) =
    access.credential_digest(string.repeat("b", 64))
    as "member digest is valid"
  let assert Ok(owner) =
    access.bootstrap_owner(store, "owner", "Owner", owner_digest)
    as "the owner predates the migration"
  let assert Ok(member) =
    access.invite_member(
      store,
      "member",
      "Member",
      access.DigestEnrollment(member_digest),
      record.id,
      access.Operator,
    )
    as "a version-three member predates the migration"
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(old) = sqlight.open(path) as "fixture connection opens"
  assert sqlight.exec(
      "DROP TABLE catalogue_recent_folders; ALTER TABLE catalogue_sessions DROP COLUMN workspace_binding; ALTER TABLE access_credentials DROP COLUMN issued_by; ALTER TABLE access_credentials DROP COLUMN expires_at_ms; ALTER TABLE access_credentials DROP COLUMN last_resumed_ms; ALTER TABLE access_credentials DROP COLUMN issued_at_ms; ALTER TABLE access_credentials DROP COLUMN kind; DROP TABLE catalogue_session_subtitles; DROP TABLE access_claims; PRAGMA user_version=3",
      on: old,
    )
    == Ok(Nil)
  assert sqlight.close(old) == Ok(Nil)

  // The migration adds the claim table and moves the version in one step,
  // leaving every principal, credential and membership as it was.
  let assert Ok(migrated) = catalogue.open(path) as "version three migrates"
  assert access.authenticate(migrated, owner_digest) == Ok(owner)
  assert access.authenticate(migrated, member_digest) == Ok(member)
  assert access.authorization(migrated, member.id, record.id)
    == Ok(access.Participant(access.Operator))
  let assert Ok(claim) = access.claim_digest(string.repeat("c", 64))
    as "claim digest is valid"
  assert access.rotate_member(
      migrated,
      member.id,
      access.ClaimEnrollment(claim, 1000),
    )
    == Ok(member)
  assert access.claim_known(migrated, claim) == Ok(Nil)
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

pub fn generated_queries_match_the_sqlc_input_test() {
  let assert Ok(source) = simplifile.read("src/storage/sql/catalogue.sql")
    as "named catalogue queries are checked in"
  let generated = [
    sql.initialize_catalogue_revision().0,
    sql.find_registrations("", "", "").0,
    sql.insert_registration("", "", "", "", "", 0, "").0,
    sql.insert_registered_registration("", "", "", Some(""), "", "", 0, "").0,
    sql.confirm_registration("").0,
    sql.registration_display_name("").0,
    sql.registration_subtitle("").0,
    sql.insert_registration_subtitle("", "").0,
    sql.delete_session_subtitle("").0,
    sql.set_registration_display_name("", "").0,
    sql.registration_page("", 0).0,
    sql.catalogue_revision().0,
    sql.member_registration_page("", "").0,
    sql.increment_catalogue_revision().0,
    sql.workspace_default("").0,
    sql.set_workspace_default("", "").0,
    sql.delete_session_default("").0,
    sql.delete_session_memberships("").0,
    sql.delete_session_domain("").0,
    sql.delete_session_display_name("").0,
    sql.delete_registration("").0,
    sql.session_archive("").0,
    sql.archive_session("").0,
    sql.restore_session("").0,
    sql.recent_folders().0,
    sql.insert_recent_folder("").0,
    sql.delete_recent_folder("").0,
    sql.forget_recent_folder(0).0,
    sql.trim_recent_folders(0).0,
  ]
  assert normalize_queries(source)
    == normalize_queries(string.join(generated, "\n"))
}

// Parrot omits terminators and query-name comments. The statements retain
// their line structure, so compare the same normalized text as the search pilot.
fn normalize_queries(source: String) -> String {
  source
  |> string.replace("@after", "?1")
  |> string.replace("@archived", "?2")
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
      "DROP TABLE catalogue_recent_folders; ALTER TABLE catalogue_sessions DROP COLUMN workspace_binding; ALTER TABLE access_credentials DROP COLUMN issued_by; ALTER TABLE access_credentials DROP COLUMN expires_at_ms; ALTER TABLE access_credentials DROP COLUMN last_resumed_ms; ALTER TABLE access_credentials DROP COLUMN issued_at_ms; ALTER TABLE access_credentials DROP COLUMN kind; DROP TABLE catalogue_session_subtitles; DROP TABLE access_claims; DROP TABLE catalogue_session_archives; DROP TABLE catalogue_session_names; PRAGMA user_version=1",
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
  assert catalogue.set_workspace_default(
      store,
      workspace.binding_key(record.workspace),
      record.id,
    )
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
  assert catalogue.workspace_default(
      store,
      workspace.binding_key(record.workspace),
    )
    == Ok(record)
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
    workspace: workspace.LocalBinding("/workspace/quoted ' project"),
    name: "review ' \" ; SELECT café",
    configuration: "/configuration/loom.toml",
    created_at: 1_700_000_000_000,
    request_key: "request-" <> int.to_string(seed),
    state: catalogue.Reserved,
    subtitle: option.None,
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
  assert catalogue.workspace_default(
      store,
      workspace.binding_key(first.workspace),
    )
    == Error(catalogue.Missing)
  assert catalogue.set_workspace_default(
      store,
      workspace.binding_key(first.workspace),
      first.id,
    )
    == Ok(first)
  assert catalogue.set_workspace_default(
      store,
      workspace.binding_key(first.workspace),
      first.id,
    )
    == Ok(first)
  let assert Ok(page) = catalogue.page(store, after: "") as "revision reads"
  assert page.revision == 3
  assert catalogue.set_workspace_default(
      store,
      workspace.binding_key(first.workspace),
      second.id,
    )
    == Ok(second)
  assert catalogue.close(store) == Ok(Nil)

  let assert Ok(restored) = catalogue.open(path) as "default survives restart"
  assert catalogue.workspace_default(
      restored,
      workspace.binding_key(first.workspace),
    )
    == Ok(second)
  assert catalogue.set_workspace_default(
      restored,
      workspace.binding_key(first.workspace),
      second.id,
    )
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
    catalogue.Registration(
      ..registration(124),
      workspace: workspace.LocalBinding("/other/project"),
    )
  assert catalogue.reserve(store, first) == Ok(first)
  assert catalogue.reserve(store, second) == Ok(second)
  assert catalogue.set_workspace_default(
      store,
      workspace.binding_key(first.workspace),
      first.id,
    )
    == Ok(first)
  assert catalogue.set_workspace_default(
      store,
      workspace.binding_key(first.workspace),
      second.id,
    )
    == Error(catalogue.Conflict)
  assert catalogue.set_workspace_default(
      store,
      workspace.binding_key(second.workspace),
      first.id,
    )
    == Error(catalogue.Conflict)
  assert catalogue.set_workspace_default(
      store,
      workspace.binding_key(first.workspace),
      "missing",
    )
    == Error(catalogue.Missing)
  assert catalogue.workspace_default(
      store,
      workspace.binding_key(first.workspace),
    )
    == Ok(first)
  assert catalogue.workspace_default(
      store,
      workspace.binding_key(second.workspace),
    )
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
  assert catalogue.set_workspace_default(
      store,
      workspace.binding_key(record.workspace),
      record.id,
    )
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
  assert catalogue.workspace_default(
      store,
      workspace.LocalKey("/wrong/workspace"),
    )
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
  assert catalogue.workspace_default(
      store,
      workspace.LocalKey("/wrong/workspace"),
    )
    == Error(catalogue.Invalid("workspace default refers to a missing session"))
  assert simplifile.is_file(record.path) == Ok(False)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn archive_preserves_metadata_and_default_is_not_restored_test() {
  let path = fresh_path("archive")
  let assert Ok(store) = catalogue.open(path) as "catalogue opens"
  let original = registration(896)
  assert catalogue.reserve(store, original) == Ok(original)
  let assert Ok(saved) = catalogue.confirm(store, original.id)
    as "file is saved"
  let assert Ok(renamed) = catalogue.rename(store, saved.id, "keep my history")
    as "display label is set"
  assert catalogue.set_workspace_default(
      store,
      workspace.binding_key(saved.workspace),
      saved.id,
    )
    == Ok(renamed)
  let assert Ok(before) = catalogue.page(store, after: "")
    as "active page loads"

  assert catalogue.set_visibility(store, saved.id, catalogue.Archived)
    == Ok(renamed)
  assert catalogue.visibility(store, saved.id) == Ok(catalogue.Archived)
  assert catalogue.get(store, saved.id) == Ok(renamed)
  assert catalogue.by_request_key(store, original.request_key) == Ok(saved)
  assert catalogue.reserve(store, original) == Ok(saved)
  assert catalogue.workspace_default(
      store,
      workspace.binding_key(saved.workspace),
    )
    == Error(catalogue.Missing)
  assert catalogue.set_workspace_default(
      store,
      workspace.binding_key(saved.workspace),
      saved.id,
    )
    == Error(catalogue.Conflict)
  let assert Ok(hidden) = catalogue.page(store, after: "")
    as "active page loads"
  assert hidden.records == []
  assert hidden.revision == before.revision + 1
  assert catalogue.archived_page(store, after: "")
    == Ok(catalogue.Page(hidden.revision, [renamed]))
  assert catalogue.set_visibility(store, saved.id, catalogue.Archived)
    == Ok(renamed)
  assert catalogue.page(store, after: "") == Ok(hidden)
  assert catalogue.close(store) == Ok(Nil)

  let assert Ok(reopened) = catalogue.open(path) as "archive survives restart"
  assert catalogue.visibility(reopened, saved.id) == Ok(catalogue.Archived)
  assert catalogue.set_visibility(reopened, saved.id, catalogue.Active)
    == Ok(renamed)
  assert catalogue.set_visibility(reopened, saved.id, catalogue.Active)
    == Ok(renamed)
  assert catalogue.workspace_default(
      reopened,
      workspace.binding_key(saved.workspace),
    )
    == Error(catalogue.Missing)
  assert catalogue.page(reopened, after: "")
    == Ok(catalogue.Page(hidden.revision + 1, [renamed]))
  assert catalogue.archived_page(reopened, after: "")
    == Ok(catalogue.Page(hidden.revision + 1, []))
  assert catalogue.set_visibility(reopened, saved.id, catalogue.Archived)
    == Ok(renamed)
  assert catalogue.delete(reopened, saved.id) == Ok(renamed)
  assert catalogue.get(reopened, saved.id) == Error(catalogue.Missing)
  assert catalogue.close(reopened) == Ok(Nil)
}

pub fn version_two_catalogue_migrates_archive_without_losing_names_test() {
  let path = fresh_path("archive-migration")
  let assert Ok(store) = catalogue.open(path) as "fixture catalogue opens"
  let record = registration(895)
  assert catalogue.reserve(store, record) == Ok(record)
  let assert Ok(renamed) = catalogue.rename(store, record.id, "saved label")
    as "version two display metadata exists"
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(old) = sqlight.open(path) as "fixture connection opens"
  assert sqlight.exec(
      "DROP TABLE catalogue_recent_folders; ALTER TABLE catalogue_sessions DROP COLUMN workspace_binding; ALTER TABLE access_credentials DROP COLUMN issued_by; ALTER TABLE access_credentials DROP COLUMN expires_at_ms; ALTER TABLE access_credentials DROP COLUMN last_resumed_ms; ALTER TABLE access_credentials DROP COLUMN issued_at_ms; ALTER TABLE access_credentials DROP COLUMN kind; DROP TABLE catalogue_session_subtitles; DROP TABLE access_claims; DROP TABLE catalogue_session_archives; PRAGMA user_version=2",
      on: old,
    )
    == Ok(Nil)
  assert sqlight.close(old) == Ok(Nil)

  let assert Ok(migrated) = catalogue.open(path) as "version two migrates"
  assert catalogue.get(migrated, record.id) == Ok(renamed)
  assert catalogue.by_request_key(migrated, record.request_key) == Ok(record)
  assert catalogue.visibility(migrated, record.id) == Ok(catalogue.Active)
  assert catalogue.set_visibility(migrated, record.id, catalogue.Archived)
    == Ok(renamed)
  assert catalogue.close(migrated) == Ok(Nil)
}

pub fn archive_and_restore_preserve_committed_conversation_bytes_test() {
  let directory = fixtures.scratch("archived-conversation")
  let assert Ok(cwd) = simplifile.current_directory()
    as "fixture cwd is available"
  let path = cwd <> "/" <> directory <> "/conversation.db"
  let assert Ok(conversation) =
    sqlite.open(
      sqlite.config(path:, owner: "archive-fixture"),
      clock.fixed(1000),
    )
    as "a real conversation opens"
  let #(entry, _) =
    fixtures.message_entry(fixtures.new_ctx(), None, "retain this answer")
  let assert Ok(_) =
    storage.commit(conversation, tx.Tx([tx.InsertEntry(entry)], []))
    as "history is committed before archival"
  assert storage.close(conversation) == Ok(Nil)
  let assert Ok(before) = simplifile.read_bits(path)
    as "closed conversation bytes are readable"
  let assert Ok(store) = catalogue.open(directory <> "/catalogue.db")
    as "catalogue opens separately"
  let original = catalogue.Registration(..registration(897), path:)
  assert catalogue.reserve(store, original) == Ok(original)
  let assert Ok(saved) = catalogue.confirm(store, original.id)
    as "conversation is saved"

  assert catalogue.set_visibility(store, saved.id, catalogue.Archived)
    == Ok(saved)
  assert simplifile.read_bits(path) == Ok(before)
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(reopened) = catalogue.open(directory <> "/catalogue.db")
    as "catalogue reopens"
  assert catalogue.set_visibility(reopened, saved.id, catalogue.Active)
    == Ok(saved)
  assert simplifile.read_bits(path) == Ok(before)
  assert catalogue.close(reopened) == Ok(Nil)
}

pub fn version_four_catalogue_migrates_subtitles_without_losing_names_test() {
  let path = fresh_path("subtitle-migration")
  let assert Ok(store) = catalogue.open(path) as "fixture catalogue opens"
  let record = registration(880)
  assert catalogue.reserve(store, record) == Ok(record)
  let assert Ok(renamed) = catalogue.rename(store, record.id, "kept label")
    as "version four display metadata exists"
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(old) = sqlight.open(path) as "fixture connection opens"
  assert sqlight.exec(
      "DROP TABLE catalogue_recent_folders; ALTER TABLE catalogue_sessions DROP COLUMN workspace_binding; ALTER TABLE access_credentials DROP COLUMN issued_by; ALTER TABLE access_credentials DROP COLUMN expires_at_ms; ALTER TABLE access_credentials DROP COLUMN last_resumed_ms; ALTER TABLE access_credentials DROP COLUMN issued_at_ms; ALTER TABLE access_credentials DROP COLUMN kind; DROP TABLE catalogue_session_subtitles; PRAGMA user_version=4",
      on: old,
    )
    == Ok(Nil)
  assert sqlight.close(old) == Ok(Nil)

  // The migration adds the table and moves the version together, leaves the
  // existing row with no subtitle, and the table then takes its first write.
  let assert Ok(migrated) = catalogue.open(path) as "version four migrates"
  assert catalogue.get(migrated, record.id) == Ok(renamed)
  let assert Ok(seeded) =
    catalogue.seed_subtitle(migrated, record.id, "Port the parser")
    as "the new table works"
  assert seeded.subtitle == option.Some("Port the parser")
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

pub fn the_first_prompt_seeds_the_subtitle_once_test() {
  let path = fresh_path("subtitle-once")
  let assert Ok(store) = catalogue.open(path) as "catalogue opens"
  let record = registration(881)
  assert catalogue.reserve(store, record) == Ok(record)
  let assert Ok(before) = catalogue.page(store, after: "")
    as "original page loads"
  let assert Ok(seeded) =
    catalogue.seed_subtitle(
      store,
      record.id,
      "  Fix  the flaky\tretry test\nthen ship it",
    )
    as "the first prompt seeds"
  let expected =
    catalogue.Registration(
      ..record,
      subtitle: option.Some("Fix the flaky retry test"),
    )
  assert seeded == expected
  assert catalogue.get(store, record.id) == Ok(expected)
  let assert Ok(after) = catalogue.page(store, after: "")
    as "the seeded page loads"
  assert after.records == [expected]
  assert after.revision == before.revision + 1

  // A later prompt, and the same prompt again, change nothing: not the
  // subtitle and not the revision a list cursor is held against.
  assert catalogue.seed_subtitle(store, record.id, "A different prompt")
    == Ok(expected)
  assert catalogue.seed_subtitle(store, record.id, "Fix the flaky retry test")
    == Ok(expected)
  assert catalogue.page(store, after: "") == Ok(after)

  // The subtitle is display metadata over the creation record: a creation
  // retry still finds the record it reserved.
  assert catalogue.by_request_key(store, record.request_key) == Ok(record)
  assert catalogue.reserve(store, record) == Ok(record)
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(reopened) = catalogue.open(path) as "catalogue reopens"
  assert catalogue.get(reopened, record.id) == Ok(expected)
  assert catalogue.seed_subtitle(reopened, record.id, "After a restart")
    == Ok(expected)
  assert catalogue.close(reopened) == Ok(Nil)
}

pub fn a_prompt_with_no_text_leaves_the_subtitle_to_the_next_one_test() {
  let assert Ok(store) = catalogue.open(fresh_path("subtitle-blank"))
    as "catalogue opens"
  let record = registration(882)
  assert catalogue.reserve(store, record) == Ok(record)
  let assert Ok(before) = catalogue.page(store, after: "")
    as "original page loads"
  assert catalogue.seed_subtitle(store, record.id, " \n\t \u{200B}\u{202E} ")
    == Ok(record)
  assert catalogue.page(store, after: "") == Ok(before)
  let assert Ok(seeded) = catalogue.seed_subtitle(store, record.id, "\n\nreal")
    as "the next prompt seeds"
  assert seeded.subtitle == option.Some("real")
  assert catalogue.seed_subtitle(store, "no-such-session", "hello")
    == Error(catalogue.Missing)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_subtitle_is_cut_on_a_word_and_never_past_sixty_characters_test() {
  // Exactly sixty characters is kept whole.
  let exact = string.repeat("abcdefghi ", 6) <> "x"
  assert string.length(exact) == 61
  let sixty = string.drop_end(exact, 1) |> string.trim_end
  assert string.length(sixty) == 59
  let whole = sixty <> "x"
  assert string.length(whole) == 60
  assert catalogue.subtitle_from_prompt(whole) == option.Some(whole)

  // Past the limit the last whole word that fits stays, and an ellipsis marks
  // the cut inside the limit.
  let long =
    "Refactor the session catalogue so that every listing reads one snapshot"
  let assert option.Some(cut) = catalogue.subtitle_from_prompt(long)
  assert cut == "Refactor the session catalogue so that every listing reads…"
  assert string.length(cut) <= catalogue.subtitle_limit

  // A limit that falls on the gap between two words keeps both sides whole.
  let gap = string.repeat("a", 59) <> " bbbb"
  assert catalogue.subtitle_from_prompt(gap)
    == option.Some(string.repeat("a", 59) <> "…")

  // One word longer than the limit is cut where it reaches it.
  let assert option.Some(word) =
    catalogue.subtitle_from_prompt(string.repeat("z", 200))
  assert word == string.repeat("z", 59) <> "…"

  // A cut never splits a character drawn as one, and counts code points, so
  // the stored text always satisfies the table's own length check. Twenty-nine
  // letters with an accent are 58 code points; a thirtieth would make 60 with
  // the ellipsis still to come.
  let accented = "e\u{301}"
  let assert option.Some(marks) =
    catalogue.subtitle_from_prompt(string.repeat(accented, 40))
  assert marks == string.repeat(accented, 29) <> "…"
  assert list.length(string.to_utf_codepoints(marks)) == 59
}

pub fn a_subtitle_drops_controls_and_direction_marks_test() {
  assert catalogue.subtitle_from_prompt("") == option.None
  assert catalogue.subtitle_from_prompt("\u{202E}\u{200B}\u{7}") == option.None
  assert catalogue.subtitle_from_prompt("run \u{202E}gnp.exe\u{7} now")
    == option.Some("run gnp.exe now")
  assert catalogue.subtitle_from_prompt("\r\n  \r\nsecond line\r\nthird")
    == option.Some("second line")
}

pub fn a_stored_subtitle_that_breaks_the_rule_reads_as_absent_test() {
  let path = fresh_path("subtitle-corrupt")
  let assert Ok(store) = catalogue.open(path) as "catalogue opens"
  let record = registration(883)
  assert catalogue.reserve(store, record) == Ok(record)
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(raw) = sqlight.open(path) as "raw connection opens"
  assert sqlight.exec(
      "INSERT INTO catalogue_session_subtitles VALUES ('"
        <> record.id
        <> "', 'bell' || char(7))",
      on: raw,
    )
    == Ok(Nil)
  assert sqlight.close(raw) == Ok(Nil)
  let assert Ok(reopened) = catalogue.open(path) as "catalogue reopens"
  assert catalogue.get(reopened, record.id) == Ok(record)
  let assert Ok(page) = catalogue.page(reopened, after: "")
    as "a listing survives the bad row"
  assert page.records == [record]
  assert catalogue.close(reopened) == Ok(Nil)
}

pub fn deleting_a_session_removes_its_subtitle_test() {
  let path = fresh_path("subtitle-delete")
  let assert Ok(store) = catalogue.open(path) as "catalogue opens"
  let record = registration(884)
  assert catalogue.reserve(store, record) == Ok(record)
  let assert Ok(_) = catalogue.seed_subtitle(store, record.id, "gone soon")
    as "the subtitle is written"
  let assert Ok(_) = catalogue.delete(store, record.id)
    as "the session is deleted"
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(raw) = sqlight.open(path) as "raw connection opens"
  assert sqlight.query(
      "SELECT count(*) FROM catalogue_session_subtitles",
      on: raw,
      with: [],
      expecting: decode.at([0], decode.int),
    )
    == Ok([0])
  assert sqlight.close(raw) == Ok(Nil)
}

pub fn a_display_name_refuses_controls_and_direction_marks_test() {
  let assert Ok(store) = catalogue.open(fresh_path("name-rule"))
    as "catalogue opens"
  let record = registration(885)
  assert catalogue.reserve(store, record) == Ok(record)
  let assert Ok(_) = catalogue.rename(store, record.id, "review auth 日本語")
    as "an ordinary name is accepted"
  let refused = [
    "",
    "   ",
    "line\nbreak",
    "bell\u{7}",
    "tab\there",
    "reversed \u{202E}name",
    "zero\u{200B}width",
    "joiner\u{2060}word",
    string.repeat("x", 257),
  ]
  list.each(refused, fn(name) {
    let assert Error(catalogue.Invalid(_)) =
      catalogue.rename(store, record.id, name)
      as "an unwritable name is refused before any write"
    Nil
  })
  assert catalogue.rename(store, "no-such-session", "fine")
    == Error(catalogue.Missing)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn version_five_catalogue_migrates_every_credential_to_bearer_test() {
  let path = fresh_path("kind-migration")
  let assert Ok(store) = catalogue.open(path) as "fixture catalogue opens"
  let assert Ok(owner_digest) = access.credential_digest(string.repeat("a", 64))
    as "owner digest is valid"
  let assert Ok(owner) =
    access.bootstrap_owner(store, "owner", "Owner", owner_digest)
    as "the owner predates the migration"
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(old) = sqlight.open(path) as "fixture connection opens"
  assert sqlight.exec(
      "DROP TABLE catalogue_recent_folders; ALTER TABLE catalogue_sessions DROP COLUMN workspace_binding; ALTER TABLE access_credentials DROP COLUMN issued_by; ALTER TABLE access_credentials DROP COLUMN expires_at_ms; ALTER TABLE access_credentials DROP COLUMN last_resumed_ms; ALTER TABLE access_credentials DROP COLUMN issued_at_ms; ALTER TABLE access_credentials DROP COLUMN kind; PRAGMA user_version=5",
      on: old,
    )
    == Ok(Nil)
  assert sqlight.close(old) == Ok(Nil)

  // The migration adds the columns with the bearer default and moves the
  // version in one step, so the owner's credential keeps authenticating as
  // the only kind that existed, and as no other.
  let assert Ok(migrated) = catalogue.open(path) as "version five migrates"
  assert access.authenticate(migrated, owner_digest) == Ok(owner)
  let assert Ok(as_login) = access.browser_digest(string.repeat("a", 64))
    as "the same text is a valid login digest"
  assert access.authenticate(migrated, as_login) == Error(catalogue.Missing)
  assert catalogue.close(migrated) == Ok(Nil)

  // Opening the migrated catalogue again changes nothing.
  let assert Ok(again) = catalogue.open(path) as "version six reopens"
  assert access.authenticate(again, owner_digest) == Ok(owner)
  assert catalogue.close(again) == Ok(Nil)
  let assert Ok(check) = sqlight.open(path) as "kinds are readable"
  assert sqlight.query(
      "SELECT kind, issued_at_ms IS NULL, last_resumed_ms IS NULL FROM access_credentials",
      on: check,
      with: [],
      expecting: {
        use kind <- decode.field(0, decode.string)
        use issued <- decode.field(1, decode.int)
        use resumed <- decode.field(2, decode.int)
        decode.success(#(kind, issued, resumed))
      },
    )
    == Ok([#("bearer", 1, 1)])
  assert sqlight.close(check) == Ok(Nil)
}

pub fn version_six_catalogue_gains_the_login_columns_test() {
  let path = fresh_path("login-migration")
  let assert Ok(store) = catalogue.open(path) as "fixture catalogue opens"
  let assert Ok(owner_digest) = access.credential_digest(string.repeat("a", 64))
    as "owner digest is valid"
  let assert Ok(owner) =
    access.bootstrap_owner(store, "owner", "Owner", owner_digest)
    as "the owner predates the migration"
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(old) = sqlight.open(path) as "fixture connection opens"
  assert sqlight.exec(
      "DROP TABLE catalogue_recent_folders; ALTER TABLE catalogue_sessions DROP COLUMN workspace_binding; ALTER TABLE access_credentials DROP COLUMN issued_by; ALTER TABLE access_credentials DROP COLUMN expires_at_ms; PRAGMA user_version=6",
      on: old,
    )
    == Ok(Nil)
  assert sqlight.close(old) == Ok(Nil)

  // The migration adds the columns, empty for every row that existed, and the
  // columns work: a login is written with its expiry and its parent.
  let assert Ok(migrated) = catalogue.open(path) as "version six migrates"
  assert access.authenticate(migrated, owner_digest) == Ok(owner)
  let assert Ok(login) = access.browser_digest(string.repeat("b", 64))
    as "login digest is valid"
  assert access.issue_login(
      migrated,
      owner.id,
      login,
      10,
      20,
      option.Some(string.repeat("c", 16)),
    )
    == Ok(Nil)
  assert catalogue.close(migrated) == Ok(Nil)
  let assert Ok(check) = sqlight.open(path) as "columns are readable"
  assert sqlight.query(
      "SELECT kind, expires_at_ms, issued_by FROM access_credentials ORDER BY kind",
      on: check,
      with: [],
      expecting: {
        use kind <- decode.field(0, decode.string)
        use expires <- decode.field(1, decode.optional(decode.int))
        use parent <- decode.field(2, decode.optional(decode.string))
        decode.success(#(kind, expires, parent))
      },
    )
    == Ok([
      #("bearer", option.None, option.None),
      #("browser", option.Some(20), option.Some(string.repeat("c", 16))),
    ])
  assert sqlight.close(check) == Ok(Nil)
}

pub fn version_seven_catalogue_retains_display_and_auth_when_binding_migrates_test() {
  let path = fresh_path("workspace-binding-migration")
  let assert Ok(store) = catalogue.open(path) as "fixture catalogue opens"
  let record = registration(879)
  assert catalogue.reserve(store, record) == Ok(record)
  let assert Ok(_) = catalogue.rename(store, record.id, "retained label")
    as "display override predates the migration"
  let assert Ok(displayed) =
    catalogue.seed_subtitle(store, record.id, "Retain workspace authority")
    as "subtitle predates the migration"
  let assert Ok(owner_digest) = access.credential_digest(string.repeat("a", 64))
    as "owner digest is valid"
  let assert Ok(owner) =
    access.bootstrap_owner(store, "owner", "Owner", owner_digest)
    as "owner predates the migration"
  let assert Ok(login) = access.browser_digest(string.repeat("b", 64))
    as "login digest is valid"
  assert access.issue_login(
      store,
      owner.id,
      login,
      10,
      20,
      option.Some(string.repeat("c", 16)),
    )
    == Ok(Nil)
  let assert Ok(signins) = access.signins_page(store, owner.id, "", 11)
    as "browser login metadata is readable"
  let assert Ok(before) = catalogue.page(store, after: "")
    as "display page is readable"
  assert catalogue.close(store) == Ok(Nil)

  // Version seven already owns subtitles and login metadata. Both subsequent
  // migrations must preserve those existing layers.
  let assert Ok(old) = sqlight.open(path) as "fixture connection opens"
  assert sqlight.exec(
      "DROP TABLE catalogue_recent_folders; ALTER TABLE catalogue_sessions DROP COLUMN workspace_binding; PRAGMA user_version=7",
      on: old,
    )
    == Ok(Nil)
  assert sqlight.close(old) == Ok(Nil)
  let assert Ok(migrated) = catalogue.open(path) as "version seven migrates"
  assert catalogue.get(migrated, record.id) == Ok(displayed)
  assert catalogue.by_request_key(migrated, record.request_key) == Ok(record)
  assert catalogue.page(migrated, after: "") == Ok(before)
  assert access.authenticate(migrated, owner_digest) == Ok(owner)
  assert access.signins_page(migrated, owner.id, "", 11) == Ok(signins)
  assert catalogue.close(migrated) == Ok(Nil)

  // A second open validates the stamped version and the retained local binding.
  let assert Ok(reopened) = catalogue.open(path) as "current version reopens"
  assert catalogue.get(reopened, record.id) == Ok(displayed)
  assert catalogue.close(reopened) == Ok(Nil)
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

pub fn main_version_eight_preserves_recent_folders_when_binding_migrates_test() {
  migrate_version_eight_fixture(
    fresh_path("main-eight"),
    registration(873),
    "ALTER TABLE catalogue_sessions DROP COLUMN workspace_binding; PRAGMA user_version=8",
    ["/recent/folder"],
  )
}

pub fn integration_version_eight_preserves_registered_authority_when_folders_migrate_test() {
  let assert Ok(selected) = workspace.selector("linux", "project")
    as "the registered selector is valid"
  let assert Ok(bound) = workspace.registered_binding(selected, 2, 3)
    as "both retained epochs are valid"
  migrate_version_eight_fixture(
    fresh_path("integration-eight"),
    catalogue.Registration(
      ..registration(874),
      workspace: workspace.Registered(bound),
    ),
    "DROP TABLE catalogue_recent_folders; PRAGMA user_version=8",
    [],
  )
}

// Each historical version-eight layout lacks a different schema addition.
// The same populated fixture proves the upgrade retains creation, domain,
// display, default and authentication data while installing the missing one.
fn migrate_version_eight_fixture(
  path: String,
  record: catalogue.Registration,
  downgrade: String,
  recent: List(String),
) -> Nil {
  let assert Ok(store) = catalogue.open(path) as "fixture catalogue opens"
  let key = workspace.binding_key(record.workspace)
  let shared =
    domain.Domain(
      domain.key(domain.WorkspacePrivate, key, ""),
      domain.WorkspacePrivate,
      key,
      "",
      "/catalogue-migration/memory.db",
      "/catalogue-migration/search.db",
    )
  assert domain.reserve_session(store, record, shared) == Ok(record)
  assert catalogue.set_workspace_default(store, key, record.id) == Ok(record)
  let assert Ok(_) = catalogue.rename(store, record.id, "retained label")
    as "display override predates the migration"
  let assert Ok(displayed) =
    catalogue.seed_subtitle(store, record.id, "Retain authority")
    as "subtitle predates the migration"
  assert catalogue.remember_folder(store, "/recent/folder") == Ok(Nil)

  // Both credential kinds and member authorization must survive either layout.
  let assert Ok(digest) = access.credential_digest(string.repeat("a", 64))
    as "owner digest is valid"
  let assert Ok(owner) = access.bootstrap_owner(store, "owner", "Owner", digest)
    as "owner predates the migration"
  let assert Ok(member_digest) =
    access.credential_digest(string.repeat("c", 64))
    as "member digest is valid"
  let assert Ok(member) =
    access.invite_member(
      store,
      "member",
      "Member",
      access.DigestEnrollment(member_digest),
      record.id,
      access.Operator,
    )
    as "member authorization predates the migration"
  let assert Ok(login) = access.browser_digest(string.repeat("b", 64))
    as "login digest is valid"
  assert access.issue_login(
      store,
      owner.id,
      login,
      10,
      20,
      Some(string.repeat("d", 16)),
    )
    == Ok(Nil)
  let assert Ok(signins) = access.signins_page(store, owner.id, "", 11)
    as "login metadata is readable"
  let assert Ok(before) = catalogue.page(store, after: "")
    as "display page loads"
  assert catalogue.close(store) == Ok(Nil)

  // The fixture removes only the schema absent from this historical branch.
  let assert Ok(old) = sqlight.open(path) as "fixture connection opens"
  assert sqlight.exec(downgrade, on: old) == Ok(Nil)
  assert sqlight.close(old) == Ok(Nil)
  let assert Ok(migrated) = catalogue.open(path)
    as "known version eight migrates"
  assert catalogue.get(migrated, record.id) == Ok(displayed)
  assert catalogue.by_request_key(migrated, record.request_key) == Ok(record)
  assert catalogue.page(migrated, after: "") == Ok(before)
  assert catalogue.workspace_default(migrated, key) == Ok(displayed)
  assert domain.for_session(migrated, record.id) == Ok(shared)
  assert access.authenticate(migrated, digest) == Ok(owner)
  assert access.authenticate(migrated, member_digest) == Ok(member)
  assert access.authorization(migrated, member.id, record.id)
    == Ok(access.Participant(access.Operator))
  assert access.signins_page(migrated, owner.id, "", 11) == Ok(signins)
  let assert Ok(folders) = catalogue.recent_folders(migrated)
    as "folder schema is available"
  assert paths(folders) == recent
  assert catalogue.remember_folder(migrated, "/new/folder") == Ok(Nil)
  assert catalogue.close(migrated) == Ok(Nil)

  // The new version reopens with the exact binding, including registered epochs.
  let assert Ok(reopened) = catalogue.open(path) as "upgraded catalogue reopens"
  assert catalogue.get(reopened, record.id) == Ok(displayed)
  assert catalogue.close(reopened) == Ok(Nil)
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

pub fn ambiguous_version_eight_is_refused_without_schema_changes_test() {
  let layouts = [
    #("mixed", "PRAGMA user_version=8"),
    #(
      "absent",
      "DROP TABLE catalogue_recent_folders; ALTER TABLE catalogue_sessions DROP COLUMN workspace_binding; PRAGMA user_version=8",
    ),
  ]
  list.each(layouts, fn(layout) {
    let #(name, downgrade) = layout
    let path = fresh_path("ambiguous-eight-" <> name)
    let assert Ok(store) = catalogue.open(path) as "fixture catalogue opens"
    let record = registration(875)
    assert catalogue.reserve(store, record) == Ok(record)
    assert catalogue.close(store) == Ok(Nil)
    let assert Ok(old) = sqlight.open(path) as "fixture connection opens"
    assert sqlight.exec(downgrade, on: old) == Ok(Nil)
    let assert Ok(before) =
      sqlight.query(
        "PRAGMA schema_version",
        on: old,
        with: [],
        expecting: decode.at([0], decode.int),
      )
      as "schema version is readable"
    assert sqlight.close(old) == Ok(Nil)

    // Neither a mixed version eight nor one missing both additions is guessed.
    assert catalogue.open(path) == Error(catalogue.Unsupported)
    let assert Ok(check) = sqlight.open(path)
      as "refused database remains readable"
    assert sqlight.query(
        "PRAGMA user_version",
        on: check,
        with: [],
        expecting: decode.at([0], decode.int),
      )
      == Ok([8])
    assert sqlight.query(
        "PRAGMA schema_version",
        on: check,
        with: [],
        expecting: decode.at([0], decode.int),
      )
      == Ok(before)
    assert sqlight.query(
        "SELECT session_id FROM catalogue_sessions",
        on: check,
        with: [],
        expecting: decode.at([0], decode.string),
      )
      == Ok([record.id])
    assert sqlight.close(check) == Ok(Nil)
  })
}

pub fn migrations_end_at_the_current_version_test() {
  // The versions are consecutive and the last is the one a catalogue is
  // stamped with, so a migration added without raising `current_version`, or
  // a version raised without a migration, fails here and not on a user's disk.
  let versions = list.map(catalogue.migrations(), fn(migration) { migration.0 })
  let expected =
    int.range(
      from: 2,
      to: catalogue.current_version + 1,
      with: [],
      run: fn(all, n) { [n, ..all] },
    )
    |> list.reverse
  assert versions == expected
}

pub fn version_four_catalogue_migrates_through_subtitles_and_kinds_test() {
  let path = fresh_path("both-migrations")
  let assert Ok(store) = catalogue.open(path) as "fixture catalogue opens"
  let assert Ok(owner_digest) = access.credential_digest(string.repeat("a", 64))
    as "owner digest is valid"
  let assert Ok(owner) =
    access.bootstrap_owner(store, "owner", "Owner", owner_digest)
    as "the owner predates the migrations"
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(old) = sqlight.open(path) as "fixture connection opens"
  assert sqlight.exec(
      "DROP TABLE catalogue_recent_folders; ALTER TABLE catalogue_sessions DROP COLUMN workspace_binding; ALTER TABLE access_credentials DROP COLUMN issued_by; ALTER TABLE access_credentials DROP COLUMN expires_at_ms; ALTER TABLE access_credentials DROP COLUMN last_resumed_ms; ALTER TABLE access_credentials DROP COLUMN issued_at_ms; ALTER TABLE access_credentials DROP COLUMN kind; DROP TABLE catalogue_session_subtitles; PRAGMA user_version=4",
      on: old,
    )
    == Ok(Nil)
  assert sqlight.close(old) == Ok(Nil)

  // One open applies both migrations in order and stamps the final version.
  let assert Ok(migrated) = catalogue.open(path) as "version four migrates"
  assert access.authenticate(migrated, owner_digest) == Ok(owner)
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

fn paths(recent: List(catalogue.Recent)) -> List(String) {
  list.map(recent, fn(entry) { entry.workspace })
}

pub fn recent_folders_are_newest_first_deduplicated_and_bounded_test() {
  let path = fresh_path("recent-folders")
  let assert Ok(store) = catalogue.open(path) as "fixture catalogue opens"
  assert catalogue.recent_folders(store) == Ok([])

  // Remembering a folder again moves it to the front instead of listing it
  // twice.
  assert catalogue.remember_folder(store, "/home/o/a") == Ok(Nil)
  assert catalogue.remember_folder(store, "/home/o/b") == Ok(Nil)
  assert catalogue.remember_folder(store, "/home/o/a") == Ok(Nil)
  let assert Ok(listed) = catalogue.recent_folders(store) as "the list reads"
  assert paths(listed) == ["/home/o/a", "/home/o/b"]

  // The list never holds more than the bound, and it is the oldest that goes.
  let many =
    int.range(
      from: 0,
      to: catalogue.recent_folder_limit + 3,
      with: [],
      run: fn(all, n) { ["/home/o/n" <> int.to_string(n), ..all] },
    )
    |> list.reverse
  assert list.try_each(many, catalogue.remember_folder(store, _)) == Ok(Nil)
  let assert Ok(kept) = catalogue.recent_folders(store)
    as "the bounded list reads"
  assert list.length(kept) == catalogue.recent_folder_limit
  assert list.first(paths(kept)) == Ok("/home/o/n12")
  assert !list.contains(paths(kept), "/home/o/a")
  assert catalogue.close(store) == Ok(Nil)
}

pub fn recent_folders_survive_a_restart_and_forget_one_test() {
  let path = fresh_path("recent-folders-restart")
  let assert Ok(store) = catalogue.open(path) as "fixture catalogue opens"
  assert catalogue.remember_folder(store, "/home/o/a") == Ok(Nil)
  assert catalogue.remember_folder(store, "/home/o/b") == Ok(Nil)
  assert catalogue.close(store) == Ok(Nil)

  let assert Ok(store) = catalogue.open(path) as "the catalogue reopens"
  let assert Ok([newest, oldest]) = catalogue.recent_folders(store)
    as "both folders survive"
  assert newest.workspace == "/home/o/b"
  assert oldest.workspace == "/home/o/a"
  assert newest.id != oldest.id
  assert catalogue.forget_folder(store, newest.id) == Ok(Nil)
  assert catalogue.forget_folder(store, 9999) == Ok(Nil)
  let assert Ok(left) = catalogue.recent_folders(store) as "one is left"
  assert left == [oldest]
  assert catalogue.close(store) == Ok(Nil)

  let assert Ok(store) = catalogue.open(path) as "a forgotten folder stays gone"
  assert catalogue.recent_folders(store) == Ok([oldest])
  assert catalogue.close(store) == Ok(Nil)
}

// A folder remembered again is a new entry: the identity a page held for the old
// one reaches nothing, so a stale press cannot forget the refreshed entry.
pub fn remembering_again_retires_the_old_identity_test() {
  let path = fresh_path("recent-folders-identity")
  let assert Ok(store) = catalogue.open(path) as "fixture catalogue opens"
  assert catalogue.remember_folder(store, "/home/o/a") == Ok(Nil)
  let assert Ok([first]) = catalogue.recent_folders(store) as "one entry"
  assert catalogue.remember_folder(store, "/home/o/a") == Ok(Nil)
  let assert Ok([second]) = catalogue.recent_folders(store) as "still one"
  assert second.id != first.id
  assert catalogue.forget_folder(store, first.id) == Ok(Nil)
  assert catalogue.recent_folders(store) == Ok([second])
  assert catalogue.close(store) == Ok(Nil)
}

pub fn an_empty_or_oversize_folder_is_not_remembered_test() {
  let path = fresh_path("recent-folders-invalid")
  let assert Ok(store) = catalogue.open(path) as "fixture catalogue opens"
  assert catalogue.remember_folder(store, "")
    == Error(catalogue.Invalid("recent folder is empty or too long"))
  assert catalogue.remember_folder(store, string.repeat("a", 4097))
    == Error(catalogue.Invalid("recent folder is empty or too long"))
  assert catalogue.recent_folders(store) == Ok([])
  assert catalogue.close(store) == Ok(Nil)
}
