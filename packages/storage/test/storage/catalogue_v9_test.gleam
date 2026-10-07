//// Real SQLite controls distinguish the two catalogue version-nine layouts.
//// Stored registrations, defaults, domains and member projections survive the
//// missing-column migration; refusal and a failed second DDL change no schema.

import core/clock
import core/ids
import core/workspace
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import sqlight
import storage/access
import storage/catalogue
import storage/domain
import support/fixtures

pub fn main_v9_retains_profiles_and_local_authority_test() {
  migrate(
    "main",
    workspace.LocalBinding("/local"),
    Some("deepseek"),
    "ALTER TABLE catalogue_sessions DROP COLUMN workspace_binding; PRAGMA user_version=9",
  )
}

pub fn integration_v9_retains_registered_authority_and_defaults_profile_test() {
  let assert Ok(selector) = workspace.selector("linux", "project")
    as "selector is valid"
  let assert Ok(binding) = workspace.registered_binding(selector, 17, 23)
    as "original registered epochs are valid"
  migrate(
    "integration",
    workspace.Registered(binding),
    None,
    "ALTER TABLE catalogue_sessions DROP COLUMN profile; PRAGMA user_version=9",
  )
}

pub fn current_v10_retains_registered_profile_and_reopens_idempotently_test() {
  let assert Ok(selector) = workspace.selector("linux", "project")
    as "selector is valid"
  let assert Ok(binding) = workspace.registered_binding(selector, 17, 23)
    as "original registered epochs are valid"
  migrate("current", workspace.Registered(binding), Some("glm-5_3"), "")
}

fn migrate(
  name: String,
  binding: workspace.Binding,
  profile: Option(String),
  downgrade: String,
) -> Nil {
  let path = fixtures.scratch("catalogue-v9-" <> name) <> "/catalogue.db"
  let assert Ok(store) = catalogue.open(path) as "populated catalogue opens"
  let record = registration(1, binding, profile)
  let plain = registration(2, workspace.LocalBinding("/other"), None)
  let key = workspace.binding_key(binding)
  let shared =
    domain.Domain(
      domain.key(domain.WorkspacePrivate, key, ""),
      domain.WorkspacePrivate,
      key,
      "/config",
      "/never-opened/memory.db",
      "/never-opened/index.db",
    )
  assert domain.reserve_session(store, record, shared) == Ok(record)
  assert catalogue.reserve(store, plain) == Ok(plain)
  assert catalogue.set_workspace_default(store, key, record.id) == Ok(record)
  let assert Ok(displayed) =
    catalogue.rename(store, record.id, "Original label")
    as "original display override is retained"
  assert catalogue.remember_folder(store, "/original/folder") == Ok(Nil)

  // Member projections select the same profile and typed binding as owner pages.
  let assert Ok(digest) = access.credential_digest(string.repeat("a", 64))
    as "owner credential is valid"
  let assert Ok(owner) = access.bootstrap_owner(store, "owner", "Owner", digest)
    as "owner authentication predates migration"
  let assert Ok(member_digest) =
    access.credential_digest(string.repeat("b", 64))
    as "member credential is valid"
  let assert Ok(member) =
    access.invite_member(
      store,
      "member",
      "Member",
      access.DigestEnrollment(member_digest),
      record.id,
      access.Operator,
    )
    as "member authorization predates migration"
  let assert Ok(before) = catalogue.page(store, after: "")
    as "owner page predates migration"
  let assert Ok(member_before) =
    catalogue.member_page(store, member.id, after: "")
    as "member page predates migration"
  assert catalogue.close(store) == Ok(Nil)

  // Only the column absent from the actual branch layout is removed.
  let assert Ok(old) = sqlight.open(path) as "fixture connection opens"
  assert sqlight.exec(downgrade, on: old) == Ok(Nil)
  assert sqlight.close(old) == Ok(Nil)
  let assert Ok(migrated) = catalogue.open(path)
    as "known branch layout migrates"
  let assert Ok(columns) = sqlight.open(path)
    as "migrated columns are readable before any row decoder"
  assert numbers(
      columns,
      "SELECT COUNT(*) FROM pragma_table_info('catalogue_sessions') WHERE name IN ('profile','workspace_binding')",
    )
    == [2]
  assert sqlight.close(columns) == Ok(Nil)
  assert catalogue.get(migrated, record.id) == Ok(displayed)
  assert catalogue.get(migrated, plain.id) == Ok(plain)
  assert catalogue.by_request_key(migrated, record.request_key) == Ok(record)
  assert catalogue.page(migrated, after: "") == Ok(before)
  assert catalogue.member_page(migrated, member.id, after: "")
    == Ok(member_before)
  assert catalogue.workspace_default(migrated, key) == Ok(displayed)
  assert domain.for_session(migrated, record.id) == Ok(shared)
  assert access.authenticate(migrated, digest) == Ok(owner)
  assert access.authorization(migrated, member.id, record.id)
    == Ok(access.Participant(access.Operator))
  assert catalogue.recent_folders(migrated)
    == Ok([catalogue.Recent(1, "/original/folder")])
  assert catalogue.close(migrated) == Ok(Nil)

  // Version ten's second open changes neither rows nor the schema counter.
  let assert Ok(check) = sqlight.open(path) as "migrated schema is readable"
  assert numbers(check, "PRAGMA user_version") == [10]
  assert numbers(
      check,
      "SELECT COUNT(*) FROM pragma_table_info('catalogue_sessions') WHERE name IN ('profile','workspace_binding')",
    )
    == [2]
  let schema = numbers(check, "PRAGMA schema_version")
  assert sqlight.close(check) == Ok(Nil)
  let assert Ok(reopened) = catalogue.open(path) as "version ten reopens"
  assert catalogue.get(reopened, record.id) == Ok(displayed)
  assert catalogue.close(reopened) == Ok(Nil)
  let assert Ok(check) = sqlight.open(path) as "reopened schema is readable"
  assert numbers(check, "PRAGMA schema_version") == schema
  assert sqlight.close(check) == Ok(Nil)
}

pub fn unsupported_v9_layouts_refuse_without_advancing_or_mutating_test() {
  let layouts = [
    #("mixed", "PRAGMA user_version=9"),
    #(
      "absent",
      "ALTER TABLE catalogue_sessions DROP COLUMN workspace_binding; ALTER TABLE catalogue_sessions DROP COLUMN profile; PRAGMA user_version=9",
    ),
    #(
      "no-folders",
      "DROP TABLE catalogue_recent_folders; ALTER TABLE catalogue_sessions DROP COLUMN profile; PRAGMA user_version=9",
    ),
    #(
      "bad-binding",
      "ALTER TABLE catalogue_sessions DROP COLUMN profile; ALTER TABLE catalogue_sessions DROP COLUMN workspace_binding; ALTER TABLE catalogue_sessions ADD COLUMN workspace_binding INTEGER; PRAGMA user_version=9",
    ),
    #(
      "bad-profile",
      "ALTER TABLE catalogue_sessions DROP COLUMN workspace_binding; ALTER TABLE catalogue_sessions DROP COLUMN profile; ALTER TABLE catalogue_sessions ADD COLUMN profile TEXT DEFAULT ''; PRAGMA user_version=9",
    ),
  ]
  list.each(layouts, fn(layout) {
    let path =
      fixtures.scratch("catalogue-v9-refused-" <> layout.0) <> "/catalogue.db"
    let assert Ok(store) = catalogue.open(path) as "fixture catalogue opens"
    let record = registration(3, workspace.LocalBinding("/local"), None)
    assert catalogue.reserve(store, record) == Ok(record)
    assert catalogue.close(store) == Ok(Nil)
    let assert Ok(old) = sqlight.open(path) as "fixture connection opens"
    assert sqlight.exec(layout.1, on: old) == Ok(Nil)
    let schema = numbers(old, "PRAGMA schema_version")
    assert sqlight.close(old) == Ok(Nil)

    // Unsupported shape is refused before a migration writes any addition.
    assert catalogue.open(path) == Error(catalogue.Unsupported)
    let assert Ok(check) = sqlight.open(path)
      as "refused catalogue remains readable"
    assert numbers(check, "PRAGMA user_version") == [9]
    assert numbers(check, "PRAGMA schema_version") == schema
    let assert Ok(rows) =
      sqlight.query(
        "SELECT session_id FROM catalogue_sessions",
        on: check,
        with: [],
        expecting: decode.at([0], decode.string),
      )
      as "original registration remains stored"
    assert rows == [record.id]
    assert sqlight.close(check) == Ok(Nil)
  })
}

pub fn failed_second_v8_ddl_rolls_back_the_first_addition_test() {
  let path = fixtures.scratch("catalogue-v8-second-ddl") <> "/catalogue.db"
  let assert Ok(store) = catalogue.open(path) as "fixture catalogue opens"
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(old) = sqlight.open(path) as "actual SQLite fixture opens"
  let assert Ok(options) =
    sqlight.query(
      "PRAGMA compile_options",
      on: old,
      with: [],
      expecting: decode.at([0], decode.string),
    )
    as "actual SQLite column bound is readable"
  let assert Ok(limit) =
    list.find(options, string.starts_with(_, "MAX_COLUMN="))
    as "SQLite reports its actual column bound"
  let assert Ok(limit) = int.parse(string.replace(limit, "MAX_COLUMN=", ""))
    as "column bound is an integer"
  let extra =
    int.range(from: 0, to: limit - 9, with: [], run: fn(all, i) {
      ["injected_" <> int.to_string(i) <> " TEXT", ..all]
    })

  // CREATE TABLE can fill the existing table's column bound without affecting
  // recent-folders creation. The subsequent profile ALTER must then fail.
  assert sqlight.exec(
      "DROP TABLE catalogue_recent_folders; DROP TABLE catalogue_sessions; CREATE TABLE catalogue_sessions(session_id TEXT, path TEXT, workspace TEXT, name TEXT, configuration TEXT, created_at INTEGER, request_key TEXT, state TEXT, workspace_binding TEXT NULL,"
        <> string.join(extra, ",")
        <> "); PRAGMA user_version=8",
      on: old,
    )
    == Ok(Nil)
  let schema = numbers(old, "PRAGMA schema_version")
  assert sqlight.close(old) == Ok(Nil)
  let assert Error(catalogue.Database(reason)) = catalogue.open(path)
    as "the actual second DDL failure refuses migration"
  assert string.contains(reason, "too many columns")
  let assert Ok(check) = sqlight.open(path)
    as "rolled-back catalogue is readable"
  assert numbers(check, "PRAGMA user_version") == [8]
  assert numbers(check, "PRAGMA schema_version") == schema
  assert numbers(
      check,
      "SELECT COUNT(*) FROM sqlite_schema WHERE name='catalogue_recent_folders'",
    )
    == [0]
  assert numbers(
      check,
      "SELECT COUNT(*) FROM pragma_table_info('catalogue_sessions') WHERE name='profile'",
    )
    == [0]
  assert sqlight.close(check) == Ok(Nil)
}

fn numbers(connection: sqlight.Connection, query: String) -> List(Int) {
  let assert Ok(values) =
    sqlight.query(
      query,
      on: connection,
      with: [],
      expecting: decode.at([0], decode.int),
    )
    as "fixture numeric metadata is readable"
  values
}

fn registration(
  seed: Int,
  binding: workspace.Binding,
  profile: Option(String),
) -> catalogue.Registration {
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(1), seed))
  let id = ids.session_id_to_string(id)
  catalogue.Registration(
    id:,
    path: "/never-opened/" <> id <> ".db",
    workspace: binding,
    name: "Session",
    configuration: "/config",
    profile:,
    created_at: 1,
    request_key: id,
    state: catalogue.Reserved,
    subtitle: None,
  )
}
