//// Real SQLite checks for stable identity, revocation, and session isolation.
//// Raw SQL is confined to corruption and schema fixtures; production access
//// always goes through the generated queries on the catalogue connection.

import core/clock
import core/ids
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

fn browser(char: String) {
  let assert Ok(value) = access.browser_digest(string.repeat(char, 64))
    as "fixture login digest is valid lowercase SHA-256 hex"
  value
}

fn enrolled(char: String) {
  access.DigestEnrollment(digest(char))
}

fn claim_of(char: String) {
  let assert Ok(value) = access.claim_digest(string.repeat(char, 64))
    as "fixture claim digest is valid lowercase SHA-256 hex"
  value
}

// An open claim expiring at instant 1000. Every claim in these tests is
// presented at an instant chosen relative to that.
fn claimed_by(char: String) {
  access.ClaimEnrollment(claim_of(char), 1000)
}

// Plain equality stands in for the daemon's constant-time comparison; the
// storage decisions are the same under either.
fn same(a: String, b: String) -> Bool {
  a == b
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
    profile: option.None,
    executor: "",
    pool: "",
    subtitle: option.None,
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
      enrolled("b"),
      session.id,
      access.Observer,
    )
    as "invitation atomically creates identity, credential, and membership"
  assert access.invite_member(
      store,
      "stable-member",
      "Changed",
      enrolled("c"),
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
  assert access.rotate_member(store, member.id, enrolled("d")) == Ok(member)
  assert access.authenticate(store, digest("b")) == Error(catalogue.Missing)
  assert access.authenticate(store, digest("d")) == Ok(member)
  assert access.revoke_member(store, member.id) == Ok(member)
  assert access.authenticate(store, digest("d")) == Error(catalogue.Missing)
  assert access.invite_member(
      store,
      member.id,
      "Reuse",
      enrolled("e"),
      session.id,
      access.Operator,
    )
    == Error(catalogue.Conflict)
  assert access.rotate_member(store, member.id, enrolled("b"))
    == Error(catalogue.Conflict)
  assert access.rotate_member(store, member.id, enrolled("f")) == Ok(member)
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
      enrolled("b"),
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
  assert access.rotate_member(store, owner.id, enrolled("b"))
    == Error(catalogue.Conflict)
  assert access.revoke_member(store, owner.id) == Error(catalogue.Conflict)
  assert access.authenticate(store, digest("a")) == Ok(owner)
  assert access.invite_member(
      store,
      "absent",
      "Absent",
      enrolled("c"),
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
  let assert Error(_) = access.rotate_member(store, member.id, enrolled("e"))
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
    sql.access_credential("", "").0,
    sql.access_credential_any_kind("").0,
    sql.insert_access_credential("", "", "").0,
    sql.revoke_access_credential("").0,
    sql.revoke_member_credentials("").0,
    sql.access_membership("", "").0,
    sql.grant_access_membership("", "", "").0,
    sql.revoke_access_membership("", "").0,
    sql.access_claim("").0,
    sql.insert_access_claim("", "", 0).0,
    sql.bind_access_claim(None, None, "").0,
    sql.void_member_claims("").0,
    sql.active_member_credentials("").0,
    sql.claim_memberships("").0,
    sql.principal_listing("").0,
    sql.principal_active_credential("", None).0,
    sql.principal_open_claim("").0,
    sql.principal_memberships("", "").0,
    sql.membered_sessions().0,
    sql.insert_access_login("", "", None, None).0,
    sql.insert_access_login_from("", "", None, None, None).0,
    sql.principal_logins("", None, "").0,
    sql.principal_login_count("", None).0,
    sql.principal_login_by_fingerprint("", "").0,
    sql.revoke_principal_logins("").0,
    sql.active_login_count().0,
    sql.revoke_all_logins().0,
    sql.login_resumed_at("").0,
    sql.stamp_login_resumed(None, "").0,

    sql.session_members("", "").0,
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
    #(sql.access_credential("", "").0, [
      sqlight.text(string.repeat("a", 64)),
      sqlight.text("bearer"),
    ]),
    #(sql.access_membership("", "").0, [
      sqlight.text("member"),
      sqlight.text("session"),
    ]),
    #(sql.access_claim("").0, [sqlight.text(string.repeat("a", 64))]),
    #(sql.claim_memberships("").0, [sqlight.text("member")]),
    #(sql.principal_listing("").0, [sqlight.text("")]),
    #(sql.principal_memberships("", "").0, [
      sqlight.text("member"),
      sqlight.text(""),
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

pub fn archived_memberships_are_filtered_before_pagination_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let records =
    list.index_map(list.repeat(Nil, 105), fn(_, index) {
      registration(index + 400)
    })
  let assert Ok(member) =
    access.create_member(store, "reader", "Reader", digest("c"))
    as "reader exists"
  list.each(records, fn(record) {
    let assert Ok(_) = catalogue.reserve(store, record)
      as "registration is retained"
    assert access.grant(store, member.id, record.id, access.Observer) == Ok(Nil)
  })
  let sorted = list.sort(records, fn(a, b) { string.compare(a.id, b.id) })
  let hidden = list.take(sorted, 102)
  list.each(hidden, fn(record) {
    assert catalogue.set_visibility(store, record.id, catalogue.Archived)
      == Ok(record)
  })
  let assert Ok(page) = catalogue.member_page(store, member.id, after: "")
    as "hidden memberships do not consume the page limit"
  assert page.records == list.drop(sorted, 102)
  let assert Ok(first) = list.first(hidden) as "one archived row is selected"
  assert catalogue.set_visibility(store, first.id, catalogue.Active)
    == Ok(first)
  let assert Ok(restored) = catalogue.member_page(store, member.id, after: "")
    as "restoration recovers existing membership without a new grant"
  assert restored.records == [first, ..list.drop(sorted, 102)]
  assert catalogue.close(store) == Ok(Nil)
}

// Reads one claim row's state and bound instant through raw SQL, the way an
// owner's listing will.
fn claim_state(file: String, char: String) {
  let assert Ok(db) = sqlight.open(file) as "claim inspection opens"
  let assert Ok(rows) =
    sqlight.query(
      "SELECT state, claimed_at_ms FROM access_claims WHERE digest = ?",
      on: db,
      with: [sqlight.text(string.repeat(char, 64))],
      expecting: {
        use state <- decode.field(0, decode.string)
        use at <- decode.field(1, decode.optional(decode.int))
        decode.success(#(state, at))
      },
    )
    as "claim rows are readable"
  assert sqlight.close(db) == Ok(Nil)
  rows
}

fn credential_rows(file: String, principal: String) {
  let assert Ok(db) = sqlight.open(file) as "credential inspection opens"
  let assert Ok(rows) =
    sqlight.query(
      "SELECT state FROM access_credentials WHERE principal_id = ?",
      on: db,
      with: [sqlight.text(principal)],
      expecting: decode.at([0], decode.string),
    )
    as "credential rows are readable"
  assert sqlight.close(db) == Ok(Nil)
  rows
}

fn claim_fixture(name: String, seed: Int) {
  let file = path(name)
  let assert Ok(store) = catalogue.open(file) as "catalogue opens"
  let session = registration(seed)
  assert catalogue.reserve(store, session) == Ok(session)
  let assert Ok(member) =
    access.invite_member(
      store,
      "invitee",
      "Invitee",
      claimed_by("1"),
      session.id,
      access.Observer,
    )
    as "a claim invitation creates the member and an open claim"
  #(file, store, session, member)
}

pub fn invited_member_has_no_credential_until_its_claim_binds_test() {
  let #(file, store, session, member) = claim_fixture("claim-binds", 931)

  // Nothing the invitation created authenticates: there is no credential row,
  // and the claim's own digest is not a credential.
  assert credential_rows(file, member.id) == []
  assert access.authenticate(store, digest("1")) == Error(catalogue.Missing)
  assert access.claim_known(store, claim_of("1")) == Ok(Nil)
  assert claim_state(file, "1") == [#("open", None)]

  let expected =
    access.Claimed(member, [access.Membership(session.id, access.Observer)])
  assert access.claim(store, claim_of("1"), digest("b"), None, 999, same)
    == Ok(expected)
  assert access.authenticate(store, digest("b")) == Ok(member)
  assert credential_rows(file, member.id) == ["active"]
  assert claim_state(file, "1") == [#("claimed", Some(999))]
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_claim_with_a_name_sets_it_and_one_without_keeps_the_inviters_test() {
  let #(_, store, session, member) = claim_fixture("claim-name", 940)

  // The name is trimmed, then written with the credential, so the principal
  // the claim answers already carries it and so does a later lookup.
  let renamed = access.Principal(..member, display_name: "Alex Doe")
  assert access.claim(
      store,
      claim_of("1"),
      digest("b"),
      Some("  Alex Doe \t"),
      10,
      same,
    )
    == Ok(
      access.Claimed(renamed, [access.Membership(session.id, access.Observer)]),
    )
  assert access.authenticate(store, digest("b")) == Ok(renamed)
  assert access.get(store, member.id) == Ok(renamed)
  assert catalogue.close(store) == Ok(Nil)

  // Without a name the inviter's stays.
  let #(_, other, _, kept) = claim_fixture("claim-no-name", 941)
  let assert Ok(access.Claimed(answered, _)) =
    access.claim(other, claim_of("1"), digest("b"), None, 10, same)
  assert answered == kept
  assert catalogue.close(other) == Ok(Nil)
}

pub fn a_refused_name_binds_nothing_and_leaves_the_claim_open_test() {
  let #(file, store, _, member) = claim_fixture("claim-bad-name", 942)
  let refused = fn(name) {
    access.claim(store, claim_of("1"), digest("b"), Some(name), 10, same)
  }
  assert refused("") == Error(access.InvalidClaimName)
  assert refused("   ") == Error(access.InvalidClaimName)
  assert refused("tab\there") == Error(access.InvalidClaimName)
  assert refused("line\nbreak") == Error(access.InvalidClaimName)
  assert refused("nul\u{0}") == Error(access.InvalidClaimName)
  assert refused("c1\u{85}x") == Error(access.InvalidClaimName)
  assert refused(string.repeat("a", 257)) == Error(access.InvalidClaimName)
  assert refused("Alex\u{202E}") == Error(access.InvalidClaimName)
  assert refused("\u{200B}") == Error(access.InvalidClaimName)
  assert refused(" \u{FEFF}\u{2060} ") == Error(access.InvalidClaimName)
  assert refused("a\u{AD}b") == Error(access.InvalidClaimName)
  assert refused("a\u{2028}b") == Error(access.InvalidClaimName)
  assert refused("a\u{61C}b") == Error(access.InvalidClaimName)

  // The limit is in bytes, not characters: 129 two-byte letters are 258.
  assert refused(string.repeat("é", 129)) == Error(access.InvalidClaimName)

  // No credential, no claim state change, and the name is the inviter's.
  assert credential_rows(file, member.id) == []
  assert claim_state(file, "1") == [#("open", None)]
  assert access.get(store, member.id) == Ok(member)

  // The same claim still redeems, with a name at the byte limit.
  let limit = string.repeat("é", 128)
  let assert Ok(access.Claimed(answered, _)) =
    access.claim(store, claim_of("1"), digest("b"), Some(limit), 10, same)
  assert answered.display_name == limit
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_stored_name_with_an_invisible_character_still_decodes_test() {
  let #(file, store, _, member) = claim_fixture("claim-old-name", 944)
  let assert Ok(Nil) =
    access.revoke_member(store, member.id) |> result.replace(Nil)
  let old_name = "Alex\u{202E}"

  // A row written before new names were held to the stricter rule.
  let assert Ok(db) = sqlight.open(file) as "a separate connection opens"
  assert sqlight.query(
      "UPDATE access_principals SET display_name = ? WHERE principal_id = ?",
      on: db,
      with: [sqlight.text(old_name), sqlight.text(member.id)],
      expecting: decode.success(Nil),
    )
    == Ok([])
  assert sqlight.close(db) == Ok(Nil)

  // It still decodes and lists; only a new write is refused.
  let assert Ok(found) = access.get(store, member.id)
  assert found.display_name == old_name
  let assert Ok(page) = access.principals_page(store, "", 0)
  assert list.any(page.entries, fn(row) {
    row.principal.display_name == old_name
  })
  assert access.rename(store, member.id, old_name)
    == Error(catalogue.Invalid(
      "display name must be nonblank, at most 256 bytes, and contain no controls or invisible characters",
    ))
  assert access.invite_member(
      store,
      "other",
      "Bad\u{200B}",
      claimed_by("2"),
      "unused",
      access.Observer,
    )
    == Error(catalogue.Invalid(
      "display name must be nonblank, at most 256 bytes, and contain no controls or invisible characters",
    ))
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_replay_never_renames_the_bound_principal_test() {
  let #(_, store, _, _) = claim_fixture("claim-replay-name", 943)
  let assert Ok(first) =
    access.claim(store, claim_of("1"), digest("b"), Some("Alex"), 10, same)

  // The lost-reply replay, with the same name or another or none, answers the
  // principal as it stands.
  assert access.claim(store, claim_of("1"), digest("b"), Some("Alex"), 20, same)
    == Ok(first)
  assert access.claim(
      store,
      claim_of("1"),
      digest("b"),
      Some("Other"),
      20,
      same,
    )
    == Ok(first)
  assert access.claim(store, claim_of("1"), digest("b"), None, 20, same)
    == Ok(first)
  assert access.get(store, first.principal.id) == Ok(first.principal)
  assert first.principal.display_name == "Alex"
  assert catalogue.close(store) == Ok(Nil)
}

pub fn claim_binds_once_and_repeats_only_for_its_own_credential_test() {
  let #(file, store, session, member) = claim_fixture("claim-once", 932)
  let expected =
    access.Claimed(member, [access.Membership(session.id, access.Observer)])
  assert access.claim(store, claim_of("1"), digest("b"), None, 10, same)
    == Ok(expected)

  // A lost reply is recovered with the same digest, even after the claim's
  // expiry instant: expiry bounds an open claim, not a bound one.
  assert access.claim(store, claim_of("1"), digest("b"), None, 5000, same)
    == Ok(expected)

  // A replay with any other digest is refused and binds nothing.
  assert access.claim(store, claim_of("1"), digest("c"), None, 20, same)
    == Error(access.ConflictingClaim)
  assert access.authenticate(store, digest("c")) == Error(catalogue.Missing)
  assert credential_rows(file, member.id) == ["active"]

  // Once the bound credential is revoked the claim answers nothing at all.
  assert access.revoke_member(store, member.id) == Ok(member)
  assert access.claim(store, claim_of("1"), digest("b"), None, 30, same)
    == Error(access.UnknownClaim)
  assert access.claim(store, claim_of("1"), digest("c"), None, 30, same)
    == Error(access.UnknownClaim)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn claim_refuses_its_own_digest_test() {
  let #(file, store, _session, member) = claim_fixture("claim-self", 933)

  // Binding the SHA-256 of the claim string would make the claim string, which
  // sits in a chat log, a durable bearer.
  assert access.claim(store, claim_of("1"), digest("1"), None, 10, same)
    == Error(access.ConflictingClaim)
  assert credential_rows(file, member.id) == []
  assert access.authenticate(store, digest("1")) == Error(catalogue.Missing)
  assert claim_state(file, "1") == [#("open", None)]
  let assert Ok(_) =
    access.claim(store, claim_of("1"), digest("b"), None, 10, same)
    as "the refused attempt left the claim open for the invitee"
  assert catalogue.close(store) == Ok(Nil)
}

pub fn expired_claim_is_refused_and_stays_unbound_test() {
  let #(file, store, _session, member) = claim_fixture("claim-expired", 934)
  assert access.claim(store, claim_of("1"), digest("b"), None, 1000, same)
    == Error(access.ExpiredClaim)
  assert access.claim(store, claim_of("1"), digest("b"), None, 99_999, same)
    == Error(access.ExpiredClaim)
  assert credential_rows(file, member.id) == []
  assert claim_state(file, "1") == [#("open", None)]
  let assert Ok(_) =
    access.claim(store, claim_of("1"), digest("b"), None, 999, same)
    as "the last instant before expiry still binds"
  assert catalogue.close(store) == Ok(Nil)
}

pub fn rotation_and_revocation_void_the_open_claim_test() {
  let #(file, store, session, member) = claim_fixture("claim-void", 935)

  // Rotation voids the delivered claim before it issues the next one.
  assert access.rotate_member(store, member.id, claimed_by("2")) == Ok(member)
  assert access.claim_known(store, claim_of("1")) == Error(catalogue.Missing)
  assert access.claim(store, claim_of("1"), digest("b"), None, 10, same)
    == Error(access.UnknownClaim)
  assert claim_state(file, "1") == [#("void", None)]
  let assert Ok(_) =
    access.claim(store, claim_of("2"), digest("b"), None, 10, same)
    as "the rotated claim binds"

  // Rotating a claimed member revokes the bound credential; its old claim
  // then answers nothing, and the new one stays open.
  assert access.rotate_member(store, member.id, claimed_by("3")) == Ok(member)
  assert access.authenticate(store, digest("b")) == Error(catalogue.Missing)
  assert access.claim(store, claim_of("2"), digest("b"), None, 10, same)
    == Error(access.UnknownClaim)

  // Revocation voids an open claim as well.
  assert access.revoke_member(store, member.id) == Ok(member)
  assert access.claim(store, claim_of("3"), digest("c"), None, 10, same)
    == Error(access.UnknownClaim)
  assert claim_state(file, "3") == [#("void", None)]
  assert access.authorization(store, member.id, session.id)
    == Ok(access.Participant(access.Observer))
  assert catalogue.close(store) == Ok(Nil)
}

pub fn claim_refuses_a_digest_that_is_already_a_credential_test() {
  let #(file, store, _session, member) = claim_fixture("claim-reuse", 936)
  let assert Ok(other) =
    access.create_member(store, "other", "Other", digest("0"))
    as "another member holds a credential"
  assert access.claim(store, claim_of("1"), digest("0"), None, 10, same)
    == Error(access.ConflictingClaim)
  assert access.authenticate(store, digest("0")) == Ok(other)

  // A tombstone is refused too: rows are never deleted, so a revoked digest
  // cannot come back through a claim.
  assert access.revoke_member(store, other.id) == Ok(other)
  assert access.claim(store, claim_of("1"), digest("0"), None, 10, same)
    == Error(access.ConflictingClaim)
  assert credential_rows(file, member.id) == []
  assert catalogue.close(store) == Ok(Nil)
}

pub fn claim_refuses_a_member_that_already_holds_a_credential_test() {
  let #(file, store, _session, member) = claim_fixture("claim-active", 937)
  assert catalogue.close(store) == Ok(Nil)

  // The API never lets an open claim coexist with an active credential, so
  // the fixture writes one directly to exercise the check that guards it.
  let assert Ok(db) = sqlight.open(file) as "fault fixture opens"
  assert sqlight.exec(
      "INSERT INTO access_credentials(digest, principal_id, state) VALUES ('"
        <> string.repeat("e", 64)
        <> "', 'invitee', 'active')",
      on: db,
    )
    == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
  let assert Ok(store) = catalogue.open(file) as "catalogue reopens"
  assert access.claim(store, claim_of("1"), digest("b"), None, 10, same)
    == Error(access.ConflictingClaim)
  assert access.authenticate(store, digest("b")) == Error(catalogue.Missing)
  assert access.authenticate(store, digest("e")) == Ok(member)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn enrollment_by_digest_creates_the_credential_and_no_claim_test() {
  let file = path("digest-enrollment")
  let assert Ok(store) = catalogue.open(file) as "catalogue opens"
  let session = registration(938)
  assert catalogue.reserve(store, session) == Ok(session)
  let assert Ok(member) =
    access.invite_member(
      store,
      "enrolled",
      "Enrolled",
      enrolled("b"),
      session.id,
      access.Operator,
    )
    as "enrollment by digest binds the invitee's own credential"
  assert access.authenticate(store, digest("b")) == Ok(member)
  let assert Ok(db) = sqlight.open(file) as "claim table opens"
  assert sqlight.query(
      "SELECT digest FROM access_claims",
      on: db,
      with: [],
      expecting: decode.at([0], decode.string),
    )
    == Ok([])
  assert sqlight.close(db) == Ok(Nil)

  // Rotation by digest revokes the first credential; a tombstone is refused.
  assert access.rotate_member(store, member.id, enrolled("c")) == Ok(member)
  assert access.authenticate(store, digest("b")) == Error(catalogue.Missing)
  assert access.authenticate(store, digest("c")) == Ok(member)
  assert access.rotate_member(store, member.id, enrolled("b"))
    == Error(catalogue.Conflict)
  assert access.authenticate(store, digest("c")) == Ok(member)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn open_claim_redeems_after_the_catalogue_reopens_test() {
  let #(file, store, session, member) = claim_fixture("claim-restart", 939)
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(store) = catalogue.open(file) as "catalogue reopens"
  assert access.claim(store, claim_of("1"), digest("b"), None, 10, same)
    == Ok(
      access.Claimed(member, [access.Membership(session.id, access.Observer)]),
    )
  assert catalogue.close(store) == Ok(Nil)
}

pub fn claim_reply_lists_sixteen_memberships_in_session_order_test() {
  let #(_file, store, first, member) = claim_fixture("claim-memberships", 940)
  let records =
    list.index_map(list.repeat(Nil, 20), fn(_, index) {
      registration(index + 1001)
    })
  list.each(records, fn(record) {
    let assert Ok(_) = catalogue.reserve(store, record) as "session saved"
    assert access.grant(store, member.id, record.id, access.Operator) == Ok(Nil)
  })
  let assert Ok(claimed) =
    access.claim(store, claim_of("1"), digest("b"), None, 10, same)
    as "the claim binds"
  let expected =
    [first.id, ..list.map(records, fn(record) { record.id })]
    |> list.sort(string.compare)
    |> list.take(access.claim_membership_limit)
  assert list.map(claimed.memberships, fn(row) { row.session_id }) == expected
  assert catalogue.close(store) == Ok(Nil)
}

pub fn database_enforces_claim_invariants_test() {
  let #(file, store, _session, _member) =
    claim_fixture("claim-constraints", 941)
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(db) = sqlight.open(file) as "constraint fixture opens"
  assert sqlight.exec("PRAGMA foreign_keys=ON", on: db) == Ok(Nil)
  let assert Error(_) =
    sqlight.exec(
      "INSERT INTO access_claims(digest, principal_id, expires_at_ms, state) VALUES ('"
        <> string.repeat("2", 64)
        <> "', 'invitee', 5, 'open')",
      on: db,
    )
    as "a member has at most one open claim"
  let assert Error(_) =
    sqlight.exec(
      "UPDATE access_claims SET state = 'claimed', claimed_at_ms = 1",
      on: db,
    )
    as "a claimed row names its credential"
  assert sqlight.exec(
      "INSERT INTO access_credentials(digest, principal_id, state) VALUES ('"
        <> string.repeat("1", 64)
        <> "', 'invitee', 'active')",
      on: db,
    )
    == Ok(Nil)
  let assert Error(_) =
    sqlight.exec(
      "UPDATE access_claims SET state = 'claimed', claimed_at_ms = 1, credential_digest = digest",
      on: db,
    )
    as "a claim cannot bind its own digest"
  assert sqlight.close(db) == Ok(Nil)
}

pub fn corrupt_claim_rows_are_refused_totally_test() {
  let #(file, store, _session, _member) = claim_fixture("claim-corrupt", 942)
  assert catalogue.close(store) == Ok(Nil)
  corrupt(file, "UPDATE access_claims SET state = 'pending'")
  let assert Ok(store) = catalogue.open(file) as "corrupt claim is decoded"
  let assert Error(access.ClaimStore(catalogue.Invalid(_))) =
    access.claim(store, claim_of("1"), digest("b"), None, 10, same)
    as "an unknown claim state never binds"
  let assert Error(catalogue.Invalid(_)) =
    access.claim_known(store, claim_of("1"))
    as "an unknown claim state never passes the upgrade filter"
  assert access.authenticate(store, digest("b")) == Error(catalogue.Missing)
  assert catalogue.close(store) == Ok(Nil)
}

fn credential_of(row: access.Listing) {
  row.credential
}

fn numbered_digest(index: Int) {
  let assert Ok(value) =
    access.credential_digest(string.pad_start(
      string.lowercase(int.to_base16(index)),
      64,
      "0",
    ))
    as "numbered digest is valid lowercase hex"
  value
}

pub fn listing_reports_each_principals_credential_state_test() {
  let #(_file, store, session, _member) = claim_fixture("listing-states", 950)
  let assert Ok(_) =
    access.bootstrap_owner(store, "owner", "Owner", digest("0"))
    as "the owner is created"

  // One member bound a claim, one was enrolled by digest, and one was revoked.
  // The fixture's own member still holds an open claim.
  let assert Ok(_) =
    access.invite_member(
      store,
      "bound",
      "Bound",
      claimed_by("2"),
      session.id,
      access.Observer,
    )
    as "second invitation"
  let assert Ok(_) =
    access.claim(store, claim_of("2"), digest("c"), None, 500, same)
    as "the second claim binds"
  let assert Ok(_) =
    access.invite_member(
      store,
      "enrolled",
      "Enrolled",
      enrolled("d"),
      session.id,
      access.Observer,
    )
    as "digest invitation"
  let assert Ok(_) =
    access.invite_member(
      store,
      "revoked",
      "Revoked",
      enrolled("e"),
      session.id,
      access.Observer,
    )
    as "third invitation"
  let assert Ok(_) = access.revoke_member(store, "revoked")
    as "the third member is revoked"

  // At instant 400 the open claim, which expires at 1000, has 600 ms left.
  let assert Ok(early) = access.principals_page(store, "", 400)
    as "listing reads"
  assert early.remainder == access.Exhausted
  assert list.map(early.entries, fn(row) { row.principal.id })
    == ["bound", "enrolled", "invitee", "owner", "revoked"]
  assert list.map(early.entries, credential_of)
    == [
      access.CredentialActive(string.repeat("c", 16), Some(500)),
      access.CredentialActive(string.repeat("d", 16), None),
      access.CredentialClaimOpen(600),
      access.CredentialActive(string.repeat("0", 16), None),
      access.CredentialNone,
    ]

  // At its expiry instant the same claim is expired, and stays a claim row.
  let assert Ok(late) = access.principals_page(store, "", 1000)
    as "listing reads after the expiry"
  assert list.contains(
    list.map(late.entries, credential_of),
    access.CredentialClaimExpired,
  )
  assert catalogue.close(store) == Ok(Nil)
}

pub fn listing_pages_resume_after_the_last_principal_test() {
  let #(_file, store, session, _member) = claim_fixture("listing-pages", 951)
  list.index_map(list.repeat(Nil, 104), fn(_, index) { index + 1 })
  |> list.each(fn(index) {
    let id = "m" <> string.pad_start(int.to_string(index), 3, "0")
    let assert Ok(_) =
      access.invite_member(
        store,
        id,
        id,
        access.DigestEnrollment(numbered_digest(index)),
        session.id,
        access.Observer,
      )
      as "member invited"
    Nil
  })

  // 105 principals: the fixture's member and 104 more. A full page reports
  // that another follows, and the next page starts after the last row.
  let assert Ok(first) = access.principals_page(store, "", 0) as "first page"
  assert list.length(first.entries) == access.listing_limit
  assert first.remainder == access.Remaining
  let assert Ok(last) = list.last(first.entries)
  let assert Ok(second) = access.principals_page(store, last.principal.id, 0)
    as "second page"
  assert list.length(second.entries) == 5
  assert second.remainder == access.Exhausted
  assert catalogue.close(store) == Ok(Nil)
}

pub fn memberships_page_names_sessions_and_pages_by_session_test() {
  let #(_file, store, first, member) = claim_fixture("membership-page", 952)
  let records =
    list.index_map(list.repeat(Nil, 104), fn(_, index) {
      registration(index + 2001)
    })
  list.each(records, fn(record) {
    let assert Ok(_) = catalogue.reserve(store, record) as "session saved"
    assert access.grant(store, member.id, record.id, access.Operator) == Ok(Nil)
  })
  let assert Ok(renamed) = list.first(records)
  let assert Ok(_) = catalogue.rename(store, renamed.id, "Renamed")
    as "display name override"
  let assert Ok(page) = access.memberships_page(store, member.id, "")
    as "first page"
  assert list.length(page.entries) == access.listing_limit
  assert page.remainder == access.Remaining
  let ids = list.map(page.entries, fn(row) { row.session_id })
  assert ids == list.sort(ids, string.compare)
  let assert Ok(last) = list.last(page.entries)
  let assert Ok(rest) =
    access.memberships_page(store, member.id, last.session_id)
    as "second page"
  assert list.length(rest.entries) == 5
  assert rest.remainder == access.Exhausted

  // The override shows where the row appears, and the original name elsewhere.
  let everything = list.append(page.entries, rest.entries)
  let assert Ok(row) =
    list.find(everything, fn(row) { row.session_id == renamed.id })
  assert row.name == "Renamed"
  assert row.role == access.Operator
  let assert Ok(original) =
    list.find(everything, fn(row) { row.session_id == first.id })
  assert original.name == "session"
  assert original.role == access.Observer
  assert catalogue.close(store) == Ok(Nil)
}

pub fn session_members_page_lists_one_sessions_members_in_principal_order_test() {
  let #(_file, store, first, _invitee) = claim_fixture("session-members", 954)
  let other = registration(955)
  assert catalogue.reserve(store, other) == Ok(other)

  // Two more members in the first session and one in the other, so the page
  // shows the first session's members and no one else's.
  list.each([#("zed", "a"), #("amy", "e")], fn(row) {
    let assert Ok(_) =
      access.invite_member(
        store,
        row.0,
        "Name of " <> row.0,
        claimed_by(row.1),
        first.id,
        access.Operator,
      )
      as "the member is invited"
    Nil
  })
  let assert Ok(elsewhere) =
    access.invite_member(
      store,
      "bob",
      "Bob",
      claimed_by("b"),
      other.id,
      access.Observer,
    )
    as "a member of the other session"
  let assert Ok(page) = access.session_members_page(store, first.id, "")
    as "the first session's members"
  assert page.remainder == access.Exhausted
  assert page.entries
    == [
      access.SessionMember("amy", "Name of amy", access.Operator),
      access.SessionMember("invitee", "Invitee", access.Observer),
      access.SessionMember("zed", "Name of zed", access.Operator),
    ]
  assert !list.any(page.entries, fn(row) { row.principal_id == elsewhere.id })

  // The cursor is the last principal read, and a role change shows at once.
  let assert Ok(rest) = access.session_members_page(store, first.id, "invitee")
    as "the page after a cursor"
  assert list.map(rest.entries, fn(row) { row.principal_id }) == ["zed"]
  assert access.grant(store, "invitee", first.id, access.Operator) == Ok(Nil)
  let assert Ok(changed) = access.session_members_page(store, first.id, "amy")
    as "the changed role"
  assert list.map(changed.entries, fn(row) { row.role })
    == [access.Operator, access.Operator]
  assert catalogue.close(store) == Ok(Nil)
}

pub fn session_members_page_pages_and_refuses_unknown_sessions_test() {
  let #(_file, store, session, _invitee) =
    claim_fixture("session-members-bounds", 956)
  let ids =
    list.index_map(list.repeat(Nil, 104), fn(_, index) {
      "member-" <> string.pad_start(int.to_string(index), 3, "0")
    })
  list.each(ids, fn(id) {
    let assert Ok(unique) =
      access.claim_digest(string.pad_start(string.slice(id, 7, 3), 64, "1"))
      as "a distinct claim digest"
    let assert Ok(_) =
      access.invite_member(
        store,
        id,
        "Member",
        access.ClaimEnrollment(unique, 1000),
        session.id,
        access.Observer,
      )
      as "the member is invited"
    Nil
  })
  let assert Ok(page) = access.session_members_page(store, session.id, "")
    as "the first page"
  assert list.length(page.entries) == access.listing_limit
  assert page.remainder == access.Remaining
  let assert Ok(last) = list.last(page.entries)
  let assert Ok(rest) =
    access.session_members_page(store, session.id, last.principal_id)
    as "the second page"

  // The invitee and 104 members make 105 rows in all.
  assert list.length(rest.entries) == 5
  assert rest.remainder == access.Exhausted
  let absent = registration(957)
  assert access.session_members_page(store, absent.id, "")
    == Error(catalogue.Missing)
  assert access.session_members_page(store, session.id, "bad id")
    == Error(catalogue.Invalid(
      "principal ID must be 1-128 ASCII identifier bytes",
    ))
  assert catalogue.close(store) == Ok(Nil)
}

pub fn memberships_page_refuses_unknown_principals_and_lists_none_for_owner_test() {
  let #(_file, store, _session, _member) =
    claim_fixture("membership-owner", 953)
  let assert Ok(_) =
    access.bootstrap_owner(store, "owner", "Owner", digest("0"))
    as "the owner is created"
  let assert Ok(page) = access.memberships_page(store, "owner", "")
    as "owner lists"
  assert page == access.MembershipPage([], access.Exhausted)
  assert access.memberships_page(store, "nobody", "")
    == Error(catalogue.Missing)
  assert access.principals_page(store, "bad id", 0)
    == Error(catalogue.Invalid(
      "principal ID must be 1-128 ASCII identifier bytes",
    ))
  assert catalogue.close(store) == Ok(Nil)
}

// A row written the way the browser login will write it. The SQL is direct
// because a claim cannot give one principal a bearer and a browser row
// together, and the listing and rule-3 tests need both.
fn insert_credential(
  file: String,
  hex: String,
  principal: String,
  kind: String,
) {
  let assert Ok(db) = sqlight.open(file) as "credential fixture opens"
  assert sqlight.exec(
      "INSERT INTO access_credentials(digest, principal_id, state, kind) VALUES ('"
        <> string.repeat(hex, 64)
        <> "', '"
        <> principal
        <> "', 'active', '"
        <> kind
        <> "')",
      on: db,
    )
    == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
}

pub fn a_credential_authenticates_only_as_the_kind_it_was_made_as_test() {
  let #(file, store, session, member) = claim_fixture("kind-claim", 960)
  let expected =
    access.Claimed(member, [access.Membership(session.id, access.Observer)])
  assert access.claim_login(
      store,
      claim_of("1"),
      browser("b"),
      None,
      10,
      5000,
      same,
    )
    == Ok(expected)
  assert access.authenticate(store, browser("b")) == Ok(member)

  // The same digest presented as a bearer finds no row. This is the lookup
  // that keeps a login's public identifier from authenticating on /v2.
  assert access.authenticate(store, digest("b")) == Error(catalogue.Missing)

  // A bearer row is no more a browser row, and rotation revokes the browser
  // row with the rest, whichever kind it was.
  assert access.rotate_member(store, member.id, enrolled("d")) == Ok(member)
  assert access.authenticate(store, digest("d")) == Ok(member)
  assert access.authenticate(store, browser("d")) == Error(catalogue.Missing)
  assert access.authenticate(store, browser("b")) == Error(catalogue.Missing)
  assert credential_rows(file, member.id) == ["revoked", "active"]
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_digest_held_as_either_kind_is_never_free_for_another_credential_test() {
  let #(file, store, _session, member) = claim_fixture("kind-reuse", 961)
  assert catalogue.close(store) == Ok(Nil)
  insert_credential(file, "e", member.id, "browser")
  let assert Ok(store) = catalogue.open(file) as "catalogue reopens"

  // Digests are one key across both kinds, so a claim presenting a browser
  // row's digest as a bearer is the claim's conflict, not a store failure.
  assert access.claim(store, claim_of("1"), digest("e"), None, 10, same)
    == Error(access.ConflictingClaim)
  assert access.authenticate(store, digest("e")) == Error(catalogue.Missing)
  assert access.get(store, member.id) == Ok(member)
  assert catalogue.close(store) == Ok(Nil)
}

// 053's rule 3 is that a member has an open claim and no credential, and a
// login is a credential. A member whose only active credential is a login
// therefore binds no claim, as a member holding a bearer binds none, whichever
// kind of credential the claim would bind.
pub fn a_browser_row_blocks_a_claim_of_either_kind_test() {
  let #(file, store, _session, member) = claim_fixture("kind-blocks", 962)
  assert catalogue.close(store) == Ok(Nil)
  insert_credential(file, "0", member.id, "browser")
  let assert Ok(store) = catalogue.open(file) as "catalogue reopens"
  assert access.claim(store, claim_of("1"), digest("b"), None, 10, same)
    == Error(access.ConflictingClaim)
  assert access.claim_login(
      store,
      claim_of("1"),
      browser("c"),
      None,
      10,
      5000,
      same,
    )
    == Error(access.ConflictingClaim)

  // Nothing was bound, and the claim is still open.
  assert credential_rows(file, member.id) == ["active"]
  assert claim_state(file, "1") == [#("open", None)]
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_bearer_row_blocks_a_browser_claim_test() {
  let #(file, store, _session, member) = claim_fixture("kind-bearer", 963)
  assert catalogue.close(store) == Ok(Nil)
  insert_credential(file, "0", member.id, "bearer")
  let assert Ok(store) = catalogue.open(file) as "catalogue reopens"
  assert access.claim_login(
      store,
      claim_of("1"),
      browser("c"),
      None,
      10,
      5000,
      same,
    )
    == Error(access.ConflictingClaim)
  assert credential_rows(file, member.id) == ["active"]
  assert catalogue.close(store) == Ok(Nil)
}

// A claim bound as a login records when the login ends, as `issue_login`
// does, so the principal's sign-ins list it with its expiry and it stops
// listing once that instant passes. A bearer claim presenting a browser digest,
// and a browser claim presenting a bearer, bind nothing.
pub fn a_claim_bound_as_a_login_ends_at_its_expiry_test() {
  let #(file, store, session, member) = claim_fixture("claim-login-ends", 965)
  let expected =
    access.Claimed(member, [access.Membership(session.id, access.Observer)])
  assert access.claim(store, claim_of("1"), browser("b"), None, 10, same)
    == Error(
      access.ClaimStore(catalogue.Invalid(
        "a bearer claim presents a bearer digest",
      )),
    )
  assert access.claim_login(
      store,
      claim_of("1"),
      digest("b"),
      None,
      10,
      5000,
      same,
    )
    == Error(
      access.ClaimStore(catalogue.Invalid(
        "a browser claim presents a browser digest",
      )),
    )
  assert credential_rows(file, member.id) == []
  assert claim_state(file, "1") == [#("open", None)]

  assert access.claim_login(
      store,
      claim_of("1"),
      browser("b"),
      None,
      10,
      5000,
      same,
    )
    == Ok(expected)
  let assert Ok(live) = access.signins_page(store, member.id, "", 4999)
  assert live.entries
    == [access.Signin(string.repeat("b", 16), 10, None, Some(5000), None)]

  // The listing shows the claim redeemed, as the credential the claim made, and
  // counts the one login.
  let assert Ok(listing) = access.principals_page(store, "", 20)
  let assert Ok(listed) =
    list.find(listing.entries, fn(row) { row.principal.id == member.id })
  assert listed.credential
    == access.CredentialActive(string.repeat("b", 16), Some(10))
  assert listed.logins == 1
  let assert Ok(ended) = access.signins_page(store, member.id, "", 5001)
  assert ended.entries == []

  // Once the login has ended the principal has no credential to list, as it has
  // no login to count: an expired claim-bound login is not "active".
  let assert Ok(after) = access.principals_page(store, "", 5001)
  let assert Ok(gone) =
    list.find(after.entries, fn(row) { row.principal.id == member.id })
  assert gone.credential == access.CredentialNone
  assert gone.logins == 0

  // The replay of a lost reply, with the same digest, answers the same success
  // and writes nothing; another digest is the claim's conflict.
  assert access.claim_login(
      store,
      claim_of("1"),
      browser("b"),
      None,
      20,
      9000,
      same,
    )
    == Ok(expected)
  assert access.claim_login(
      store,
      claim_of("1"),
      browser("c"),
      None,
      20,
      9000,
      same,
    )
    == Error(access.ConflictingClaim)
  assert credential_rows(file, member.id) == ["active"]
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_login_is_counted_beside_the_bearer_and_never_in_its_place_test() {
  let #(file, store, session, member) = claim_fixture("kind-listing", 964)
  let expected =
    access.Claimed(member, [access.Membership(session.id, access.Observer)])
  assert access.claim(store, claim_of("1"), digest("b"), None, 10, same)
    == Ok(expected)
  assert catalogue.close(store) == Ok(Nil)

  // The login's row sorts before the bearer's, so a listing that ignored the
  // kind would show it.
  insert_credential(file, "0", member.id, "browser")
  let assert Ok(store) = catalogue.open(file) as "catalogue reopens"
  let assert Ok(page) = access.principals_page(store, "", 20)
  let assert Ok(listed) =
    list.find(page.entries, fn(row) { row.principal.id == member.id })
  assert listed.credential
    == access.CredentialActive(string.repeat("b", 16), Some(10))
  assert listed.logins == 1
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_member_with_only_a_login_lists_no_credential_and_one_login_test() {
  let #(file, store, _session, member) = claim_fixture("kind-only", 965)
  assert catalogue.close(store) == Ok(Nil)
  insert_credential(file, "0", member.id, "browser")
  let assert Ok(store) = catalogue.open(file) as "catalogue reopens"

  // The open claim is what the listing reports: the login is no credential of
  // the kind 053 reports, and shows only in the count beside it.
  let assert Ok(page) = access.principals_page(store, "", 20)
  let assert Ok(listed) =
    list.find(page.entries, fn(row) { row.principal.id == member.id })
  assert listed.credential == access.CredentialClaimOpen(980)
  assert listed.logins == 1
  assert catalogue.close(store) == Ok(Nil)
}

pub fn the_bearer_paths_refuse_a_browser_digest_test() {
  let path = path("bearer-only")
  let assert Ok(store) = catalogue.open(path) as "catalogue opens"
  assert access.bootstrap_owner(store, "owner", "Owner", browser("a"))
    == Error(catalogue.Invalid("a browser login is not a bearer credential"))
  let assert Ok(owner) =
    access.bootstrap_owner(store, "owner", "Owner", digest("a"))
    as "the owner has a bearer"
  assert access.create_member(store, "alice", "Alice", browser("b"))
    == Error(catalogue.Invalid("a browser login is not a bearer credential"))
  assert access.rotate_credential(store, digest("a"), browser("c"))
    == Error(catalogue.Invalid("a browser login is not a bearer credential"))
  assert access.rotate_credential(store, browser("a"), digest("c"))
    == Error(catalogue.Invalid("a browser login is not a bearer credential"))
  assert access.authenticate(store, digest("a")) == Ok(owner)
  assert catalogue.close(store) == Ok(Nil)
}

fn login_fixture(name: String) {
  let store_path = path(name)
  let assert Ok(store) = catalogue.open(store_path) as "catalogue opens"
  let assert Ok(owner) =
    access.bootstrap_owner(store, "owner", "Owner", digest("a"))
    as "the owner exists"
  let assert Ok(alice) =
    access.create_member(store, "alice", "Alice", digest("b"))
    as "a member exists"
  #(store_path, store, owner, alice)
}

pub fn issue_login_writes_one_browser_row_that_authenticates_as_a_browser_test() {
  let #(file, store, _owner, alice) = login_fixture("issue-login")
  assert access.issue_login(store, alice.id, browser("1"), 100, 5000, None)
    == Ok(Nil)
  assert access.authenticate(store, browser("1")) == Ok(alice)

  // The bearer and the login are different credentials of one principal, and
  // neither stands in for the other.
  assert access.authenticate(store, digest("b")) == Ok(alice)
  assert access.authenticate(store, digest("1")) == Error(catalogue.Missing)
  assert credential_rows(file, alice.id) == ["active", "active"]

  // A digest in use as either kind, a bearer-made digest, an unknown principal
  // and a malformed parent are each refused with nothing written.
  assert access.issue_login(store, alice.id, browser("1"), 100, 5000, None)
    == Error(catalogue.Conflict)
  assert access.issue_login(store, alice.id, browser("b"), 100, 5000, None)
    == Error(catalogue.Conflict)
  assert access.issue_login(store, alice.id, digest("2"), 100, 5000, None)
    == Error(catalogue.Invalid("a login row is a browser credential"))
  assert access.issue_login(store, "nobody", browser("2"), 100, 5000, None)
    == Error(catalogue.Missing)
  assert access.issue_login(store, alice.id, browser("2"), 100, 5000, Some("x"))
    == Error(catalogue.Invalid("fingerprint must be 16 lowercase hex bytes"))
  assert credential_rows(file, alice.id) == ["active", "active"]
  assert catalogue.close(store) == Ok(Nil)
}

pub fn signins_list_the_principals_own_active_unexpired_logins_in_order_test() {
  let #(_file, store, owner, alice) = login_fixture("signins")
  let parent = string.repeat("1", 16)
  assert access.issue_login(store, alice.id, browser("3"), 300, 9000, None)
    == Ok(Nil)
  assert access.issue_login(
      store,
      alice.id,
      browser("1"),
      100,
      9000,
      Some(string.repeat("3", 16)),
    )
    == Ok(Nil)
  assert access.issue_login(store, alice.id, browser("2"), 200, 400, None)
    == Ok(Nil)
  assert access.issue_login(store, owner.id, browser("4"), 150, 9000, None)
    == Ok(Nil)

  // Fingerprint order, the owner's login and the login that expired at 400
  // are absent, and a login that came from a device link names its parent.
  let assert Ok(page) = access.signins_page(store, alice.id, "", 500)
  assert page.remainder == access.Exhausted
  assert page.entries
    == [
      access.Signin(parent, 100, None, Some(9000), Some(string.repeat("3", 16))),
      access.Signin(string.repeat("3", 16), 300, None, Some(9000), None),
    ]

  // Judged at an earlier instant the third login is still listed, and a page
  // after a fingerprint starts past it.
  let assert Ok(all) = access.signins_page(store, alice.id, "", 300)
  assert list.map(all.entries, fn(row) { row.fingerprint })
    == [
      string.repeat("1", 16),
      string.repeat("2", 16),
      string.repeat("3", 16),
    ]
  let assert Ok(rest) =
    access.signins_page(store, alice.id, string.repeat("1", 16), 300)
  assert list.map(rest.entries, fn(row) { row.fingerprint })
    == [string.repeat("2", 16), string.repeat("3", 16)]
  assert access.signins_page(store, "nobody", "", 0) == Error(catalogue.Missing)
  assert access.signins_page(store, alice.id, "zz", 0)
    == Error(catalogue.Invalid("fingerprint must be 16 lowercase hex bytes"))
  assert catalogue.close(store) == Ok(Nil)
}

pub fn principals_list_counts_logins_beside_the_bearer_test() {
  let #(_file, store, _owner, alice) = login_fixture("login-count")
  assert access.issue_login(store, alice.id, browser("1"), 100, 9000, None)
    == Ok(Nil)
  assert access.issue_login(store, alice.id, browser("2"), 100, 400, None)
    == Ok(Nil)
  let assert Ok(page) = access.principals_page(store, "", 500)
  let assert Ok(listed) =
    list.find(page.entries, fn(row) { row.principal.id == alice.id })
  assert listed.credential
    == access.CredentialActive(string.repeat("b", 16), None)
  assert listed.logins == 1
  let assert Ok(owner_row) =
    list.find(page.entries, fn(row) { row.principal.id == "owner" })
  assert owner_row.logins == 0
  assert catalogue.close(store) == Ok(Nil)
}

pub fn revoke_login_revokes_one_of_the_principals_own_logins_only_test() {
  let #(file, store, owner, alice) = login_fixture("revoke-login")
  assert access.issue_login(store, alice.id, browser("1"), 100, 9000, None)
    == Ok(Nil)
  assert access.issue_login(store, alice.id, browser("2"), 100, 9000, None)
    == Ok(Nil)
  assert access.issue_login(store, owner.id, browser("4"), 100, 9000, None)
    == Ok(Nil)
  let one = string.repeat("1", 16)

  // Another principal's fingerprint and the bearer's are not this principal's
  // logins, so neither matches.
  assert access.revoke_login(store, alice.id, string.repeat("4", 16))
    == Error(catalogue.Missing)
  assert access.revoke_login(store, alice.id, string.repeat("b", 16))
    == Error(catalogue.Missing)
  assert access.revoke_login(store, alice.id, "zz")
    == Error(catalogue.Invalid("fingerprint must be 16 lowercase hex bytes"))

  assert access.revoke_login(store, alice.id, one) == Ok(browser("1"))
  assert access.authenticate(store, browser("1")) == Error(catalogue.Missing)
  assert access.authenticate(store, browser("2")) == Ok(alice)
  assert access.authenticate(store, browser("4")) == Ok(owner)
  assert access.authenticate(store, digest("b")) == Ok(alice)

  // Revoking it again is idempotent, and the row stays as a tombstone.
  assert access.revoke_login(store, alice.id, one) == Ok(browser("1"))
  assert credential_rows(file, alice.id) == ["active", "revoked", "active"]
  assert catalogue.close(store) == Ok(Nil)
}

pub fn revoke_logins_signs_a_principal_out_everywhere_and_keeps_its_bearer_test() {
  let #(_file, store, owner, alice) = login_fixture("revoke-logins")
  assert access.issue_login(store, alice.id, browser("1"), 100, 9000, None)
    == Ok(Nil)
  assert access.issue_login(store, alice.id, browser("2"), 100, 50, None)
    == Ok(Nil)
  assert access.issue_login(store, owner.id, browser("4"), 100, 9000, None)
    == Ok(Nil)

  // Both of Alice's active logins are counted, the expired one included, since
  // each is revoked.
  assert access.revoke_logins(store, alice.id) == Ok(2)
  assert access.authenticate(store, browser("1")) == Error(catalogue.Missing)
  assert access.authenticate(store, browser("2")) == Error(catalogue.Missing)
  assert access.authenticate(store, digest("b")) == Ok(alice)
  assert access.authenticate(store, browser("4")) == Ok(owner)
  assert access.revoke_logins(store, alice.id) == Ok(0)
  assert access.revoke_logins(store, "nobody") == Error(catalogue.Missing)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn revoke_all_logins_revokes_every_browser_row_and_no_bearer_test() {
  let #(file, store, owner, alice) = login_fixture("revoke-all-logins")
  assert access.issue_login(store, alice.id, browser("1"), 100, 9000, None)
    == Ok(Nil)
  assert access.issue_login(store, owner.id, browser("4"), 100, 9000, None)
    == Ok(Nil)
  assert access.revoke_all_logins(store) == Ok(2)
  assert access.authenticate(store, browser("1")) == Error(catalogue.Missing)
  assert access.authenticate(store, browser("4")) == Error(catalogue.Missing)
  assert access.authenticate(store, digest("a")) == Ok(owner)
  assert access.authenticate(store, digest("b")) == Ok(alice)
  assert credential_rows(file, alice.id) == ["active", "revoked"]

  // Nothing active is left to revoke, and a revoked row is not listed.
  assert access.revoke_all_logins(store) == Ok(0)
  let assert Ok(page) = access.signins_page(store, alice.id, "", 0)
  assert page.entries == []
  assert catalogue.close(store) == Ok(Nil)
}

pub fn resumed_writes_at_most_once_an_hour_test() {
  let #(_file, store, _owner, alice) = login_fixture("resumed")
  assert access.issue_login(
      store,
      alice.id,
      browser("1"),
      100,
      99_999_999,
      None,
    )
    == Ok(Nil)
  let window = access.resume_stamp_window_ms
  assert access.resumed(store, browser("1"), 1000) == Ok(access.Stamped)
  assert access.resumed(store, browser("1"), 1000 + window - 1)
    == Ok(access.Unchanged)

  // The instant stayed where the first resume put it, so the window is
  // counted from it and not from the visits it refused. The login's expiry is
  // fixed when it is made, and no resume moves it.
  let assert Ok(page) = access.signins_page(store, alice.id, "", 0)
  assert list.map(page.entries, fn(row) { row.last_resumed_ms }) == [Some(1000)]
  assert list.map(page.entries, fn(row) { row.expires_at_ms })
    == [Some(99_999_999)]
  assert access.resumed(store, browser("1"), 1000 + window)
    == Ok(access.Stamped)
  let assert Ok(later) = access.signins_page(store, alice.id, "", 0)
  assert list.map(later.entries, fn(row) { row.last_resumed_ms })
    == [Some(1000 + window)]
  assert list.map(later.entries, fn(row) { row.expires_at_ms })
    == [Some(99_999_999)]

  // Only a login row has a resume to record.
  assert access.resumed(store, browser("9"), 1) == Error(catalogue.Missing)
  assert access.resumed(store, digest("b"), 1)
    == Error(catalogue.Invalid("a login row is a browser credential"))
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_claim_bound_as_a_login_records_when_it_began_test() {
  let #(_file, store, session, member) = claim_fixture("claim-login", 966)
  let expected =
    access.Claimed(member, [access.Membership(session.id, access.Observer)])
  assert access.claim_login(
      store,
      claim_of("1"),
      browser("b"),
      None,
      77,
      900,
      same,
    )
    == Ok(expected)
  let assert Ok(page) = access.signins_page(store, member.id, "", 78)
  assert list.map(page.entries, fn(row) { row.issued_at_ms }) == [77]
  assert list.map(page.entries, fn(row) { row.expires_at_ms }) == [Some(900)]
  assert catalogue.close(store) == Ok(Nil)
}
