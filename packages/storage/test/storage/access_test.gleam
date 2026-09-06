//// Real SQLite checks for stable identity, revocation, and session isolation.
//// Raw SQL is confined to corruption and schema fixtures; production access
//// always goes through the generated queries on the catalogue connection.

import core/clock
import core/ids
import gleam/dynamic/decode
import gleam/list
import gleam/string
import simplifile
import sqlight
import storage/access
import storage/catalogue
import storage/sql
import support/fixtures

fn path(name: String) {
  fixtures.scratch("access-" <> name) <> "/catalogue.db"
}

fn digest(char: String) {
  let assert Ok(value) = access.credential_digest(string.repeat(char, 64))
    as "fixture digest is valid lowercase SHA-256 hex"
  value
}

fn registration(seed: Int) {
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(0), seed))
  let id = ids.session_id_to_string(id)
  catalogue.Registration(
    id:,
    path: "/never-opened-access-test/" <> id <> ".db",
    workspace: "/workspace",
    name: "session",
    configuration: "",
    created_at: 0,
    request_key: id,
    state: catalogue.Reserved,
  )
}

pub fn member_invitation_recovery_preserves_identity_and_tombstones_test() {
  let file = path("member-invitation")
  let assert Ok(store) = catalogue.open(file) as "catalogue opens"
  let session = registration(911)
  assert catalogue.reserve(store, session) == Ok(session)
  let assert Ok(member) =
    access.invite_member(
      store,
      "stable-member",
      "Member",
      digest("b"),
      session.id,
      access.Observer,
    )
    as "invitation atomically creates identity, credential, and membership"
  assert access.invite_member(
      store,
      "stable-member",
      "Changed",
      digest("c"),
      session.id,
      access.Operator,
    )
    == Error(catalogue.Conflict)
  assert access.authenticate(store, digest("c")) == Error(catalogue.Missing)
  assert access.authorization(store, member.id, session.id)
    == Ok(access.Participant(access.Observer))
  assert catalogue.close(store) == Ok(Nil)

  // The caller retains the recovery ID even if it never received the bearer.
  let assert Ok(store) = catalogue.open(file) as "invitation survives restart"
  assert access.rotate_member(store, member.id, digest("d")) == Ok(member)
  assert access.authenticate(store, digest("b")) == Error(catalogue.Missing)
  assert access.authenticate(store, digest("d")) == Ok(member)
  assert access.revoke_member(store, member.id) == Ok(member)
  assert access.authenticate(store, digest("d")) == Error(catalogue.Missing)
  assert access.invite_member(
      store,
      member.id,
      "Reuse",
      digest("e"),
      session.id,
      access.Operator,
    )
    == Error(catalogue.Conflict)
  assert access.rotate_member(store, member.id, digest("b"))
    == Error(catalogue.Conflict)
  assert access.rotate_member(store, member.id, digest("f")) == Ok(member)
  assert access.authorization(store, member.id, session.id)
    == Ok(access.Participant(access.Observer))
  assert catalogue.close(store) == Ok(Nil)
}

pub fn authorization_reads_one_snapshot_without_reserving_the_writer_test() {
  let file = path("authorization-snapshot")
  let assert Ok(store) = catalogue.open(file) as "catalogue opens"
  let session = registration(451)
  assert catalogue.reserve(store, session) == Ok(session)
  let assert Ok(member) =
    access.invite_member(
      store,
      "snapshot-member",
      "Member",
      digest("b"),
      session.id,
      access.Operator,
    )
    as "the member exists before authority is resolved"
  let assert Ok(writer) = sqlight.open(file)
    as "an independent connection can contend for the writer"
  assert catalogue.statement(store, #("PRAGMA busy_timeout = 1", [])) == Ok(Nil)
  assert sqlight.exec("BEGIN IMMEDIATE", on: writer) == Ok(Nil)

  // Three lookups answer one question, so they read one deferred snapshot. A
  // read snapshot coexists with the pending writer; taking the writer instead
  // would fail immediately against this busy timeout.
  assert access.authorization(store, member.id, session.id)
    == Ok(access.Participant(access.Operator))
  assert sqlight.exec("ROLLBACK", on: writer) == Ok(Nil)
  assert sqlight.close(writer) == Ok(Nil)

  // The snapshot is a real transaction on this connection, which is why the
  // module's no-nesting rule applies to authorization as well: called inside a
  // catalogue transaction it is refused rather than reading outside the cut.
  assert catalogue.statement(store, #("BEGIN DEFERRED", [])) == Ok(Nil)
  let assert Error(catalogue.Database(_)) =
    access.authorization(store, member.id, session.id)
    as "a nested authorization read is refused, not silently unwrapped"
  assert catalogue.statement(store, #("ROLLBACK", [])) == Ok(Nil)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn member_admin_excludes_owner_and_rolls_back_failed_insert_test() {
  let file = path("member-atomic")
  let assert Ok(store) = catalogue.open(file) as "catalogue opens"
  let assert Ok(owner) =
    access.bootstrap_owner(store, "owner", "Owner", digest("a"))
    as "owner exists"
  assert access.rotate_member(store, owner.id, digest("b"))
    == Error(catalogue.Conflict)
  assert access.revoke_member(store, owner.id) == Error(catalogue.Conflict)
  assert access.authenticate(store, digest("a")) == Ok(owner)
  assert access.invite_member(
      store,
      "absent",
      "Absent",
      digest("c"),
      registration(912).id,
      access.Observer,
    )
    == Error(catalogue.Missing)
  assert access.get(store, "absent") == Error(catalogue.Missing)
  assert access.authenticate(store, digest("c")) == Error(catalogue.Missing)
  let assert Ok(member) =
    access.create_member(store, "member", "Member", digest("d"))
    as "member exists before fault injection"
  assert catalogue.close(store) == Ok(Nil)

  // Failing after revocation tests transaction rollback, not just preflight.
  let assert Ok(db) = sqlight.open(file) as "fault fixture opens"
  assert sqlight.exec(
      "CREATE TRIGGER refuse_credential BEFORE INSERT ON access_credentials BEGIN SELECT RAISE(ABORT, 'injected insertion failure'); END",
      on: db,
    )
    == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
  let assert Ok(store) = catalogue.open(file)
    as "catalogue reopens with injected failure"
  let assert Error(_) = access.rotate_member(store, member.id, digest("e"))
    as "credential insertion fails after revocation"
  assert access.authenticate(store, digest("d")) == Ok(member)
  assert access.authenticate(store, digest("e")) == Error(catalogue.Missing)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn owner_identity_survives_reopen_rotation_and_retry_test() {
  let file = path("owner")
  let assert Ok(store) = catalogue.open(file) as "fresh catalogue opens"
  let assert Ok(owner) =
    access.bootstrap_owner(store, "owner-id", "Local", digest("a"))
    as "the initial owner is durable"
  assert owner.kind == access.OwnerPrincipal
  assert catalogue.close(store) == Ok(Nil)

  let assert Ok(store) = catalogue.open(file) as "catalogue reopens"
  assert access.owner(store) == Ok(owner)
  assert access.bootstrap_owner(
      store,
      "another-id",
      "Another name",
      digest("a"),
    )
    == Ok(owner)
  assert access.bootstrap_owner(
      store,
      "another-id",
      "Another name",
      digest("b"),
    )
    == Error(catalogue.Conflict)
  assert access.rotate_credential(store, digest("a"), digest("b")) == Ok(owner)
  assert access.authenticate(store, digest("a")) == Error(catalogue.Missing)
  assert access.authenticate(store, digest("b")) == Ok(owner)
  assert access.bootstrap_owner(
      store,
      "another-id",
      "Another name",
      digest("a"),
    )
    == Error(catalogue.Conflict)
  assert catalogue.close(store) == Ok(Nil)

  let assert Ok(store) = catalogue.open(file) as "rotation survives reopen"
  assert access.owner(store) == Ok(owner)
  assert access.authenticate(store, digest("b")) == Ok(owner)
  assert access.authenticate(store, digest("a")) == Error(catalogue.Missing)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn membership_pagination_filters_before_limit_and_invalidates_cursors_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let records =
    list.index_map(list.repeat(Nil, 205), fn(_, index) {
      registration(index + 1)
    })
  list.each(records, fn(record) {
    let assert Ok(_) = catalogue.reserve(store, record)
      as "registration is saved metadata only"
  })
  let assert Ok(member) =
    access.create_member(store, "reader", "Reader", digest("c"))
    as "reader exists without ambient membership"
  let sorted = list.sort(records, fn(a, b) { string.compare(a.id, b.id) })
  let visible = list.drop(sorted, 103)
  list.each(visible, fn(record) {
    assert access.grant(store, member.id, record.id, access.Observer) == Ok(Nil)
  })

  let assert Ok(first) = catalogue.member_page(store, member.id, after: "")
    as "more than a global page of hidden rows cannot hide the member page"
  assert first.records == list.take(visible, 100)
  let assert Ok(last) = list.last(first.records)
    as "first page has a visible cursor"
  let assert Ok(second) =
    catalogue.member_page(store, member.id, after: last.id)
    as "continuation names only visible registrations"
  assert second.records == list.drop(visible, 100)
  assert second.revision == first.revision

  let assert Ok(selected) = list.first(visible)
    as "one visible registration is selected"
  assert access.grant(store, member.id, selected.id, access.Observer) == Ok(Nil)
  assert catalogue.member_page(store, member.id, after: "") == Ok(first)
  assert access.revoke_membership(store, member.id, selected.id) == Ok(Nil)
  let assert Ok(changed) = catalogue.member_page(store, member.id, after: "")
    as "revocation invalidates pagination and removes the record"
  assert changed.revision == first.revision + 1
  assert changed.records == list.take(list.drop(visible, 1), 100)
  assert access.revoke_membership(store, member.id, selected.id) == Ok(Nil)
  assert catalogue.member_page(store, member.id, after: "") == Ok(changed)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn revocation_tombstones_prevent_reuse_and_failed_rotation_is_atomic_test() {
  let assert Ok(store) = catalogue.open(path("revocation")) as "catalogue opens"
  let assert Ok(first) =
    access.create_member(store, "first", "First", digest("a"))
    as "first member exists"
  let assert Ok(_second) =
    access.create_member(store, "second", "Second", digest("b"))
    as "second member exists"
  assert access.rotate_credential(store, digest("a"), digest("b"))
    == Error(catalogue.Conflict)
  assert access.authenticate(store, digest("a")) == Ok(first)
  assert access.revoke_credential(store, digest("a")) == Ok(Nil)
  assert access.revoke_credential(store, digest("a")) == Ok(Nil)
  assert access.authenticate(store, digest("a")) == Error(catalogue.Missing)
  assert access.create_member(store, "third", "Third", digest("a"))
    == Error(catalogue.Conflict)
  assert access.get(store, "third") == Error(catalogue.Missing)
  assert access.rotate_credential(store, digest("a"), digest("c"))
    == Error(catalogue.Missing)
  assert access.revoke_credential(store, digest("f"))
    == Error(catalogue.Missing)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn membership_roles_are_session_scoped_and_owner_needs_existing_session_test() {
  let assert Ok(store) = catalogue.open(path("membership")) as "catalogue opens"
  let first = registration(1)
  let second = registration(2)
  assert catalogue.reserve(store, first) == Ok(first)
  assert catalogue.reserve(store, second) == Ok(second)
  let assert Ok(owner) =
    access.bootstrap_owner(store, "owner", "Owner", digest("a"))
    as "owner exists"
  let assert Ok(member) =
    access.create_member(store, "member", "Observer", digest("b"))
    as "member exists"
  assert access.authorization(store, member.id, first.id)
    == Error(catalogue.Missing)
  assert access.grant(store, member.id, first.id, access.Observer) == Ok(Nil)
  assert access.authorization(store, member.id, first.id)
    == Ok(access.Participant(access.Observer))
  assert access.authorization(store, member.id, second.id)
    == Error(catalogue.Missing)
  assert access.grant(store, member.id, second.id, access.Operator) == Ok(Nil)
  assert access.grant(store, member.id, first.id, access.Operator) == Ok(Nil)
  assert access.authorization(store, member.id, first.id)
    == Ok(access.Participant(access.Operator))
  assert access.revoke_membership(store, member.id, first.id) == Ok(Nil)
  assert access.revoke_membership(store, member.id, first.id) == Ok(Nil)
  assert access.authorization(store, member.id, first.id)
    == Error(catalogue.Missing)
  assert access.authorization(store, member.id, second.id)
    == Ok(access.Participant(access.Operator))
  assert access.authorization(store, owner.id, first.id) == Ok(access.Owner)
  assert access.authorization(store, owner.id, registration(3).id)
    == Error(catalogue.Missing)
  assert access.grant(store, owner.id, first.id, access.Observer)
    == Error(catalogue.Conflict)
  assert access.grant(store, "absent", first.id, access.Observer)
    == Error(catalogue.Missing)
  assert access.grant(store, member.id, registration(3).id, access.Observer)
    == Error(catalogue.Missing)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn display_name_changes_do_not_replace_principal_identity_test() {
  let assert Ok(store) = catalogue.open(path("name")) as "catalogue opens"
  let assert Ok(member) =
    access.create_member(store, "member", "Before", digest("a"))
    as "member exists"
  let renamed = access.Principal(..member, display_name: "Café reviewer")
  assert access.rename(store, member.id, renamed.display_name) == Ok(renamed)
  assert access.authenticate(store, digest("a")) == Ok(renamed)
  assert member.display_name == "Before"
  assert catalogue.close(store) == Ok(Nil)
}

pub fn invalid_input_never_creates_principals_or_accepts_plaintext_test() {
  list.each(
    [
      "plaintext-secret",
      string.repeat("A", 64),
      string.repeat("g", 64),
      string.repeat("a", 63),
    ],
    fn(value) {
      let assert Error(catalogue.Invalid(_)) = access.credential_digest(value)
        as "only canonical hash representations are accepted"
    },
  )
  let assert Ok(store) = catalogue.open(path("invalid")) as "catalogue opens"
  list.each(["", " ", "line\nname", string.repeat("n", 257)], fn(name) {
    let assert Error(catalogue.Invalid(_)) =
      access.create_member(store, "member", name, digest("a"))
      as "invalid display names are refused"
  })
  list.each(["", "space id", string.repeat("x", 129)], fn(id) {
    let assert Error(catalogue.Invalid(_)) =
      access.create_member(store, id, "Valid", digest("a"))
      as "invalid stable identifiers are refused"
  })
  assert access.get(store, "member") == Error(catalogue.Missing)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn database_enforces_single_owner_and_membership_references_test() {
  let file = path("constraints")
  let assert Ok(store) = catalogue.open(file) as "catalogue opens"
  let assert Ok(_) =
    access.bootstrap_owner(store, "owner", "Owner", digest("a"))
    as "owner exists"
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(db) = sqlight.open(file) as "constraint fixture opens"
  let assert Error(_) =
    sqlight.exec(
      "INSERT INTO access_principals VALUES ('second', 'Second', 'owner')",
      on: db,
    )
    as "the unique partial index prevents a second owner"
  assert sqlight.exec("PRAGMA foreign_keys=ON", on: db) == Ok(Nil)
  let assert Error(_) =
    sqlight.exec(
      "INSERT INTO access_memberships VALUES ('owner', 'absent', 'observer')",
      on: db,
    )
    as "session membership cannot reference an absent registration"
  assert sqlight.close(db) == Ok(Nil)
}

pub fn corrupted_persisted_authority_is_refused_totally_test() {
  let file = path("corrupt")
  let assert Ok(store) = catalogue.open(file) as "catalogue opens"
  let session = registration(10)
  assert catalogue.reserve(store, session) == Ok(session)
  let assert Ok(_) =
    access.create_member(store, "member", "Member", digest("a"))
    as "member exists"
  assert access.grant(store, "member", session.id, access.Observer) == Ok(Nil)
  assert catalogue.close(store) == Ok(Nil)
  corrupt(file, "UPDATE access_memberships SET role='owner'")
  let assert Ok(store) = catalogue.open(file)
    as "corrupt role remains readable for total refusal"
  let assert Error(catalogue.Invalid(_)) =
    access.authorization(store, "member", session.id)
    as "unknown role cannot become owner or observer"
  assert catalogue.close(store) == Ok(Nil)
  corrupt(file, "UPDATE access_credentials SET state='pending'")
  let assert Ok(store) = catalogue.open(file)
    as "corrupt credential state is decoded"
  let assert Error(catalogue.Invalid(_)) =
    access.authenticate(store, digest("a"))
    as "unknown credential state never becomes active"
  assert catalogue.close(store) == Ok(Nil)
  corrupt(
    file,
    "UPDATE access_credentials SET state='active'; UPDATE access_principals SET kind='admin'",
  )
  let assert Ok(store) = catalogue.open(file)
    as "corrupt principal kind is decoded"
  let assert Error(catalogue.Invalid(_)) =
    access.authenticate(store, digest("a"))
    as "unknown principal kind never gains authority"
  assert catalogue.close(store) == Ok(Nil)
}

fn corrupt(file: String, statement: String) {
  let assert Ok(db) = sqlight.open(file) as "corruption fixture opens"
  assert sqlight.exec(
      "PRAGMA ignore_check_constraints=ON; " <> statement,
      on: db,
    )
    == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
}

pub fn generated_access_queries_match_sqlc_input_test() {
  let assert Ok(source) = simplifile.read("src/storage/sql/access.sql")
    as "auth query source exists"
  let generated = [
    sql.access_owner().0,
    sql.access_principal("").0,
    sql.insert_access_principal("", "", "").0,
    sql.rename_access_principal("", "").0,
    sql.access_credential("").0,
    sql.insert_access_credential("", "").0,
    sql.revoke_access_credential("").0,
    sql.revoke_member_credentials("").0,
    sql.access_membership("", "").0,
    sql.grant_access_membership("", "", "").0,
    sql.revoke_access_membership("", "").0,
  ]
  assert normalize(source) == normalize(string.join(generated, "\n"))
}

pub fn authorization_lookups_use_bounded_indexes_test() {
  let file = path("plans")
  let assert Ok(store) = catalogue.open(file) as "catalogue schema exists"
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(db) = sqlight.open(file) as "query-plan fixture opens"
  let queries = [
    #(sql.access_owner().0, []),
    #(sql.access_principal("").0, [sqlight.text("member")]),
    #(sql.access_credential("").0, [sqlight.text(string.repeat("a", 64))]),
    #(sql.access_membership("", "").0, [
      sqlight.text("member"),
      sqlight.text("session"),
    ]),
  ]
  list.each(queries, fn(query) {
    let assert Ok(details) =
      sqlight.query(
        "EXPLAIN QUERY PLAN " <> query.0,
        on: db,
        with: query.1,
        expecting: decode.at([3], decode.string),
      )
      as "SQLite explains each production-generated lookup"
    assert list.any(details, fn(detail) { string.contains(detail, "SEARCH") })
    assert !list.any(details, fn(detail) { string.contains(detail, "SCAN") })
  })
  assert sqlight.close(db) == Ok(Nil)
}

fn normalize(source: String) {
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
