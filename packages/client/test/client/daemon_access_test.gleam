//// The owner's listing over the daemon's real router and SQLite catalogue,
//// and the shared access command that reads it (protocol-change/053 phase 2).
////
//// The commands under test are `principals.list` and
//// `principals.memberships`, owner-only reads that carry a credential's
//// fingerprint, the instant a claim was redeemed, and a claim's remaining
//// life, and never a claim or a bearer. The same fixture drives
//// `loomd access` and `loom access` through `host/access` and compares what
//// each prints, including against a remote-style connection that reads the
//// owner token from a private file.

import broker/token as vault
import client/daemon/admin
import client/daemon/manager
import client/daemon/protocol
import client/daemon/root
import client/daemon_claim_test as claims
import client/daemon_server_test as wire
import core/clock
import core/ids
import core/json.{type JsonValue}
import core/workspace
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import host/access
import host/bootstrap
import host/claim
import host/endpoint
import storage/access as store_access
import storage/catalogue
import storage/domain

fn field(value: JsonValue, key: String) -> JsonValue {
  let assert json.Object(fields) = value as "the value is an object"
  let assert Ok(found) = list.key_find(fields, key) as "the field is present"
  found
}

fn has_field(value: JsonValue, key: String) -> Bool {
  let assert json.Object(fields) = value as "the value is an object"
  list.key_find(fields, key) != Error(Nil)
}

fn address(port: Int) -> String {
  "ws://127.0.0.1:" <> int.to_string(port) <> "/v2/control"
}

fn owner_digest(owner: String) -> store_access.Digest {
  let assert Ok(digest) = store_access.credential_digest(claim.digest(owner))
    as "the owner digest is valid"
  digest
}

// A session in the `session_only` domain, which is what an invitation needs.
fn shared_session(
  ready: root.Ready(String),
  seed: Int,
  name: String,
) -> String {
  let assert Ok(view) =
    manager.create_scoped(
      ready.registry,
      manager.Creation(
        "access-" <> int.to_string(seed),
        workspace.LocalBinding("/workspace"),
        name,
        "",
        None,
      ),
      directory: ready.sessions_directory,
      generator: ids.generator(clock.fixed(1), seed),
      scope: domain.SessionOnly,
      configuration: "",
    )
    as "a shared session exists to invite into"
  view.registration.id
}

fn administer(ready: root.Ready(String), owner: String, action) {
  let assert Ok(_) =
    manager.administer(ready.registry, owner_digest(owner), ready.epoch, action)
    as "the owner's administration succeeds"
  Nil
}

// Every line of a listing, through the shared command's own exchange.
fn owner_lines(
  port: Int,
  owner: String,
  ready: root.Ready(String),
  arguments: List(String),
) -> List(JsonValue) {
  let assert Ok(request) = access.parse(arguments, access.Loom)
    as "the command parses"
  let assert Ok(lines) =
    access.exchange(address(port), owner, ready.epoch, request)
    as "the owner's read succeeds"
  lines
}

fn row(lines: List(JsonValue), id: String) -> JsonValue {
  let assert Ok(found) =
    list.find(lines, fn(line) {
      has_field(line, "principal_id")
      && field(line, "principal_id") == json.String(id)
    })
    as "the principal is listed"
  found
}

// One request on an authenticated control socket, answered by the next frame.
fn control(port: Int, credential: String, id: Int, command: String, body) {
  let #(socket, response) = wire.connect(port, credential, "/v2/control")
  assert string.contains(response, "101 Switching Protocols")
  let _hello = wire.frame(socket, within_ms: 1000)
  wire.send(socket, id, command, body, within_ms: 2000)
}

fn refusal_code(reply: JsonValue) -> JsonValue {
  assert field(reply, "event") == json.String("error")
  field(field(reply, "body"), "code")
}

// Whether a run of at least `size` lowercase hexadecimal characters occurs.
fn has_hex_run(text: String, size: Int) -> Bool {
  let #(longest, _) =
    list.fold(string.to_graphemes(text), #(0, 0), fn(state, char) {
      let #(longest, run) = state
      case string.contains("0123456789abcdef", char) {
        True -> #(int.max(longest, run + 1), run + 1)
        False -> #(longest, 0)
      }
    })
  longest >= size
}

pub fn the_listing_reports_each_credential_state_and_the_claim_instant_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let session = shared_session(ready, 20, "Listed")
    let before = bootstrap.system_time_ms()

    // Alice redeems her claim; Bob's stays open; Carol is enrolled by digest;
    // Dan's claim expired unredeemed; Erin's claim was voided by revocation.
    let assert Ok(invite_alice) =
      admin.parse(["invite", session, "alice", "operator", "Alice"])
    let assert Ok(invited) =
      admin.exchange(address(port), owner, ready.epoch, invite_alice)
    let assert json.String(alice_claim) = field(invited, "claim")
    let alice_credential = claim.random_credential()
    let alice_digest = claim.digest(alice_credential)
    assert field(claims.redeem(port, alice_claim, alice_digest), "event")
      == json.String("credentials.claim")
    let after = bootstrap.system_time_ms()

    let assert Ok(invite_bob) =
      admin.parse(["invite", session, "bob", "observer", "Bob"])
    let assert Ok(bob_invited) =
      admin.exchange(address(port), owner, ready.epoch, invite_bob)
    let assert json.String(bob_claim) = field(bob_invited, "claim")
    let carol_digest = claim.digest(claim.random_credential())
    let assert Ok(invite_carol) =
      admin.parse([
        "invite", session, "carol", "observer", "Carol", "--credential-digest",
        carol_digest,
      ])
    let assert Ok(_) =
      admin.exchange(address(port), owner, ready.epoch, invite_carol)
    let expired = claim.mint_token(vault.production_entropy())
    let assert Ok(expired_digest) =
      store_access.claim_digest(claim.digest(expired))
    administer(
      ready,
      owner,
      manager.Invite(
        "dan",
        "Dan",
        store_access.ClaimEnrollment(expired_digest, before - 1),
        session,
        store_access.Observer,
      ),
    )
    let assert Ok(invite_erin) =
      admin.parse(["invite", session, "erin", "observer", "Erin"])
    let assert Ok(_) =
      admin.exchange(address(port), owner, ready.epoch, invite_erin)
    let assert Ok(revoke_erin) = admin.parse(["revoke-credentials", "erin"])
    let assert Ok(_) =
      admin.exchange(address(port), owner, ready.epoch, revoke_erin)

    let lines = owner_lines(port, owner, ready, ["list"])
    assert list.length(lines) == 6
    let listed = fn(id) { field(row(lines, id), "credential") }

    // The owner's credential is an active one with a fingerprint and no claim.
    let owners =
      list.filter(lines, fn(line) {
        field(line, "kind") == json.String("owner")
      })
    let assert [owner_row] = owners as "exactly one owner is listed"
    assert field(owner_row, "credential")
      == json.Object([
        #("state", json.String("active")),
        #("fingerprint", json.String(string.slice(claim.digest(owner), 0, 16))),
      ])

    // Alice's redeemed claim shows the credential she bound and when.
    let alice = listed("alice")
    assert field(alice, "state") == json.String("active")
    assert field(alice, "fingerprint")
      == json.String(string.slice(alice_digest, 0, 16))
    let assert json.Int(claimed_at) = field(alice, "claimed_at_ms")
    assert claimed_at >= before && claimed_at <= after

    // Bob's open claim shows only how long it has left.
    let bob = listed("bob")
    assert field(bob, "state") == json.String("claim_open")
    let assert json.Int(left) = field(bob, "expires_in_ms")
    assert left > 86_000_000 && left <= 86_400_000
    assert !has_field(bob, "fingerprint")

    // An enrolled credential is active and was bound by no claim.
    assert listed("carol")
      == json.Object([
        #("state", json.String("active")),
        #("fingerprint", json.String(string.slice(carol_digest, 0, 16))),
      ])
    assert listed("dan")
      == json.Object([#("state", json.String("claim_expired"))])
    assert listed("erin") == json.Object([#("state", json.String("none"))])

    // The whole frame, read raw, holds no claim and no 64-character value.
    let frame = control(port, owner, 1, "principals.list", json.Object([]))
    assert field(frame, "event") == json.String("principals.list")
    let assert [owner_row] =
      list.filter(lines, fn(line) {
        field(line, "kind") == json.String("owner")
      })
    let assert json.String(owner_id) = field(owner_row, "principal_id")

    // The owner's principal ID is 64 random hex characters, but it is an
    // identity and not a credential, so it is set aside before the scan.
    let text = string.replace(json.to_string(frame), owner_id, "")
    assert !string.contains(text, "loomclaim_")
    assert !has_hex_run(text, 64) as text
    assert !string.contains(text, carol_digest)
    assert !string.contains(text, alice_digest)
    assert !string.contains(text, alice_claim)
    assert !string.contains(text, bob_claim)
    assert !string.contains(text, alice_credential)
    assert !string.contains(text, owner)
    assert !has_field(field(frame, "body"), "next")
    Nil
  })
}

pub fn a_member_cannot_list_principals_or_memberships_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let session = shared_session(ready, 21, "Members")
    let assert Ok(invite) =
      admin.parse(["invite", session, "alice", "operator", "Alice"])
    let assert Ok(invited) =
      admin.exchange(address(port), owner, ready.epoch, invite)
    let assert json.String(token) = field(invited, "claim")
    let credential = claim.random_credential()
    assert field(claims.redeem(port, token, claim.digest(credential)), "event")
      == json.String("credentials.claim")

    // Neither command answers a member, not even about the member itself.
    assert refusal_code(control(
        port,
        credential,
        1,
        "principals.list",
        json.Object([]),
      ))
      == json.String("forbidden")
    assert refusal_code(control(
        port,
        credential,
        2,
        "principals.memberships",
        json.Object([#("principal_id", json.String("alice"))]),
      ))
      == json.String("forbidden")

    // Refusal comes before any parameter is judged, so a member learns
    // nothing about which principals exist.
    assert refusal_code(control(
        port,
        credential,
        3,
        "principals.memberships",
        json.Object([#("principal_id", json.String("nobody"))]),
      ))
      == json.String("forbidden")
    Nil
  })
}

pub fn memberships_list_the_sessions_of_one_principal_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let first = shared_session(ready, 22, "First")
    let second = shared_session(ready, 23, "Second")
    let assert Ok(invite) =
      admin.parse(["invite", first, "alice", "observer", "Alice"])
    let assert Ok(_) = admin.exchange(address(port), owner, ready.epoch, invite)
    administer(
      ready,
      owner,
      manager.SetRole("alice", second, store_access.Operator),
    )
    let lines = owner_lines(port, owner, ready, ["show", "alice"])
    let entries =
      [#(first, "First", "observer"), #(second, "Second", "operator")]
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    let expected =
      list.map(entries, fn(entry) {
        json.Object([
          #("session_id", json.String(entry.0)),
          #("name", json.String(entry.1)),
          #("role", json.String(entry.2)),
        ])
      })
    assert lines == expected

    // A cursor resumes after a session, and the owner has no memberships.
    let assert [#(earlier, _, _), #(later, later_name, later_role)] = entries
    assert owner_lines(port, owner, ready, ["show", "alice", "--after", earlier])
      == [
        json.Object([
          #("session_id", json.String(later)),
          #("name", json.String(later_name)),
          #("role", json.String(later_role)),
        ]),
      ]
    let owner_rows =
      owner_lines(port, owner, ready, ["list"])
      |> list.filter(fn(line) { field(line, "kind") == json.String("owner") })
    let assert [owner_row] = owner_rows
    let assert json.String(owner_id) = field(owner_row, "principal_id")
    assert owner_lines(port, owner, ready, ["show", owner_id]) == []
    Nil
  })
}

pub fn members_list_the_principals_of_one_session_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let first = shared_session(ready, 24, "First")
    let second = shared_session(ready, 25, "Second")
    let assert Ok(invite_alice) =
      admin.parse(["invite", first, "alice", "observer", "Alice"])
    let assert Ok(_) =
      admin.exchange(address(port), owner, ready.epoch, invite_alice)
    let assert Ok(invite_bob) =
      admin.parse(["invite", first, "bob", "operator", "Bob"])
    let assert Ok(_) =
      admin.exchange(address(port), owner, ready.epoch, invite_bob)
    let assert Ok(invite_carol) =
      admin.parse(["invite", second, "carol", "observer", "Carol"])
    let assert Ok(_) =
      admin.exchange(address(port), owner, ready.epoch, invite_carol)

    // The session's own members, in principal order, and no one else's.
    let expected = fn(id, name, role) {
      json.Object([
        #("principal_id", json.String(id)),
        #("name", json.String(name)),
        #("role", json.String(role)),
      ])
    }
    assert owner_lines(port, owner, ready, ["members", first])
      == [
        expected("alice", "Alice", "observer"),
        expected("bob", "Bob", "operator"),
      ]
    assert owner_lines(port, owner, ready, ["members", second])
      == [expected("carol", "Carol", "observer")]

    // A cursor resumes after a principal, and a role change shows at once.
    assert owner_lines(port, owner, ready, [
        "members",
        first,
        "--after",
        "alice",
      ])
      == [expected("bob", "Bob", "operator")]
    administer(
      ready,
      owner,
      manager.SetRole("alice", first, store_access.Operator),
    )
    assert owner_lines(port, owner, ready, ["members", first, "--after", "a"])
      == [
        expected("alice", "Alice", "operator"),
        expected("bob", "Bob", "operator"),
      ]

    // The raw reply names the session and carries no credential, claim or
    // fingerprint, only identities, names and roles.
    let frame =
      control(
        port,
        owner,
        1,
        "sessions.members",
        json.Object([#("session_id", json.String(first))]),
      )
    assert field(frame, "event") == json.String("sessions.members")
    assert field(field(frame, "body"), "session_id") == json.String(first)

    // The scope the session was created with rides along, so a page can tell a
    // session that may be shared from one that may not before anyone presses.
    assert field(field(frame, "body"), "scope") == json.String("session_only")
    let text = json.to_string(frame)
    assert !string.contains(text, "loomclaim_")
    assert !string.contains(text, "fingerprint")
    assert !has_hex_run(string.replace(text, first, ""), 64) as text
    assert !has_field(field(frame, "body"), "next")
    Nil
  })
}

pub fn a_member_cannot_list_a_sessions_members_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let session = shared_session(ready, 26, "Closed")
    let assert Ok(invite) =
      admin.parse(["invite", session, "alice", "operator", "Alice"])
    let assert Ok(invited) =
      admin.exchange(address(port), owner, ready.epoch, invite)
    let assert json.String(token) = field(invited, "claim")
    let credential = claim.random_credential()
    assert field(claims.redeem(port, token, claim.digest(credential)), "event")
      == json.String("credentials.claim")

    // A member is refused even for the session it holds, and even for a session
    // that does not exist, so it learns nothing about either.
    let absent =
      ids.session_id_to_string(
        ids.mint_session(ids.generator(clock.fixed(0), 27)).0,
      )
    assert refusal_code(control(
        port,
        credential,
        1,
        "sessions.members",
        json.Object([#("session_id", json.String(session))]),
      ))
      == json.String("forbidden")
    assert refusal_code(control(
        port,
        credential,
        2,
        "sessions.members",
        json.Object([#("session_id", json.String(absent))]),
      ))
      == json.String("forbidden")
    Nil
  })
}

pub fn unknown_sessions_and_bad_members_requests_are_refused_to_the_owner_test() {
  wire.fixture(fn(_, _ready, port, owner) {
    let absent =
      ids.session_id_to_string(
        ids.mint_session(ids.generator(clock.fixed(0), 28)).0,
      )
    assert refusal_code(control(
        port,
        owner,
        1,
        "sessions.members",
        json.Object([#("session_id", json.String(absent))]),
      ))
      == json.String("not_found")
    assert refusal_code(control(
        port,
        owner,
        2,
        "sessions.members",
        json.Object([#("session_id", json.String("not-a-session"))]),
      ))
      == json.String("bad_request")
    assert refusal_code(control(
        port,
        owner,
        3,
        "sessions.members",
        json.Object([
          #("session_id", json.String(absent)),
          #("after", json.String("bad id")),
        ]),
      ))
      == json.String("bad_request")
  })
}

pub fn unknown_principals_and_bad_cursors_are_refused_to_the_owner_test() {
  wire.fixture(fn(_, _ready, port, owner) {
    assert refusal_code(control(
        port,
        owner,
        1,
        "principals.memberships",
        json.Object([#("principal_id", json.String("nobody"))]),
      ))
      == json.String("not_found")
    assert refusal_code(control(
        port,
        owner,
        2,
        "principals.list",
        json.Object([#("after", json.String("bad id"))]),
      ))
      == json.String("bad_request")
    assert refusal_code(control(
        port,
        owner,
        3,
        "principals.memberships",
        json.Object([
          #("principal_id", json.String("nobody")),
          #("after", json.String("not-a-session")),
        ]),
      ))
      == json.String("bad_request")
    Nil
  })
}

// A principal ID of 128 bytes with a running number in it.
fn long_id(index: Int) -> String {
  string.pad_end(
    "m" <> string.pad_start(int.to_string(index), 4, "0"),
    128,
    "x",
  )
}

// The widest name a principal may have once encoded: 256 quotation marks, each
// escaped to two bytes.
fn wide_name() -> String {
  string.repeat("\"", 256)
}

fn digest_of(index: Int) -> store_access.Digest {
  let assert Ok(digest) =
    store_access.credential_digest(string.pad_start(
      string.lowercase(int.to_base16(index)),
      64,
      "0",
    ))
    as "the numbered digest is valid"
  digest
}

fn array_of(value: JsonValue, key: String) -> List(JsonValue) {
  let assert json.Array(items) = field(field(value, "body"), key)
    as "the body carries the array"
  items
}

// Pages through a listing with raw frames, answering every page's row array.
fn pages(port, owner, command, base, key, cursor_key, id_key) {
  page_from(port, owner, command, base, key, cursor_key, id_key, "", 1, [])
}

fn page_from(
  port,
  owner,
  command,
  base,
  key,
  cursor_key,
  id_key,
  after,
  id,
  seen,
) {
  let body = case after {
    "" -> json.Object(base)
    cursor -> json.Object([#(cursor_key, json.String(cursor)), ..base])
  }
  let reply = control(port, owner, id, command, body)
  assert field(reply, "event") == json.String(command)
  let rows = array_of(reply, key)

  // Every page, whatever its rows hold, stays inside the 60,000-byte budget.
  assert string.byte_size(json.to_string(json.Array(rows))) <= 60_000
  let seen = list.append(seen, [rows])
  case has_field(field(reply, "body"), "next") {
    False -> seen
    True -> {
      let assert json.String(cursor) = field(field(reply, "body"), "next")
      let assert Ok(last) = list.last(rows)
      assert field(last, id_key) == json.String(cursor)
      assert id < 40
      page_from(
        port,
        owner,
        command,
        base,
        key,
        cursor_key,
        id_key,
        cursor,
        id + 1,
        seen,
      )
    }
  }
}

pub fn principal_pages_stay_within_the_budget_and_resume_after_the_cursor_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let session = shared_session(ready, 24, "Wide")
    list.index_map(list.repeat(Nil, 100), fn(_, index) { index + 1 })
    |> list.each(fn(index) {
      administer(
        ready,
        owner,
        manager.Invite(
          long_id(index),
          wide_name(),
          store_access.DigestEnrollment(digest_of(index)),
          session,
          store_access.Observer,
        ),
      )
    })

    // 100 members plus the owner. Each row is about 750 bytes, so 60,000
    // bytes cut a page well before the catalogue's own 100-row limit.
    let listed =
      pages(
        port,
        owner,
        "principals.list",
        [],
        "principals",
        "after",
        "principal_id",
      )
    assert list.length(listed) >= 2
    let ids =
      list.flatten(listed)
      |> list.map(fn(line) {
        let assert json.String(id) = field(line, "principal_id")
        id
      })
    assert list.length(ids) == 101
    assert ids == list.sort(ids, string.compare)
    assert list.unique(ids) == ids
    Nil
  })
}

pub fn membership_pages_stay_within_the_budget_and_resume_after_the_cursor_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let first = shared_session(ready, 1000, wide_name())
    let assert Ok(invite) =
      admin.parse(["invite", first, "alice", "observer", "Alice"])
    let assert Ok(_) = admin.exchange(address(port), owner, ready.epoch, invite)

    // The registry's capacity limits resident sessions, not rows, but a
    // reservation still counts toward it, so the remaining rows go straight
    // into the catalogue the daemon reads.
    let assert Ok(store) = catalogue.open(ready.state_root <> "/catalogue.db")
      as "the fixture administration opens the daemon's catalogue"
    let sessions =
      list.index_map(list.repeat(Nil, 104), fn(_, index) { index + 1001 })
      |> list.map(fn(seed) {
        let #(id, _) = ids.mint_session(ids.generator(clock.fixed(0), seed))
        let id = ids.session_id_to_string(id)
        let assert Ok(_) =
          catalogue.reserve(
            store,
            catalogue.Registration(
              id:,
              path: "/never-opened-access-test/" <> id <> ".db",
              workspace: workspace.LocalBinding("/workspace"),
              name: wide_name(),
              configuration: "",
              created_at: 0,
              request_key: id,
              state: catalogue.Reserved,
              profile: option.None,
              subtitle: option.None,
            ),
          )
          as "the session is reserved"
        assert store_access.grant(store, "alice", id, store_access.Operator)
          == Ok(Nil)
        id
      })
    assert catalogue.close(store) == Ok(Nil)
    let expected = list.sort([first, ..sessions], string.compare)
    let listed =
      pages(
        port,
        owner,
        "principals.memberships",
        [#("principal_id", json.String("alice"))],
        "memberships",
        "after",
        "session_id",
      )
    assert list.length(listed) >= 2
    let ids =
      list.flatten(listed)
      |> list.map(fn(line) {
        let assert json.String(id) = field(line, "session_id")
        id
      })
    assert ids == expected
    Nil
  })
}

// ---------------------------------------------------------------- the CLIs

type Printed {
  Out(String)
  Err(String)
}

// Runs one command on a console that collects, and answers what each stream
// received, in order, with the exit outcome.
fn printed(
  program: access.Program,
  arguments: List(String),
) -> #(access.Outcome, List(String), List(String)) {
  let inbox: Subject(Printed) = process.new_subject()
  let console =
    access.Console(
      out: fn(line) { process.send(inbox, Out(line)) },
      err: fn(line) { process.send(inbox, Err(line)) },
    )
  let outcome = access.run_on(console, arguments, program, decodes)
  let #(out, err) = drain(inbox, [], [])
  #(outcome, out, err)
}

fn drain(inbox, out, err) {
  case process.receive(inbox, 0) {
    Ok(Out(line)) -> drain(inbox, [line, ..out], err)
    Ok(Err(line)) -> drain(inbox, out, [line, ..err])
    Error(Nil) -> #(list.reverse(out), list.reverse(err))
  }
}

fn decodes(envelope: String) -> Result(Nil, String) {
  protocol.decode(envelope)
  |> result.replace(Nil)
  |> result.replace_error("invalid or oversized administration argument")
}

// A private state directory that looks like a running daemon's: the endpoint
// record names this fixture's listener and epoch, and `owner.token` holds the
// owner credential. That is all `discover` reads.
fn published_state(port: Int, epoch: String, owner: String) -> String {
  let assert Ok(directory) =
    bootstrap.absolute_path(
      "build/access-state-"
      <> int.to_string(bootstrap.system_time_ms())
      <> "-"
      <> int.to_string(int.random(1_000_000_000)),
    )
    as "the state directory has an absolute path"
  assert bootstrap.ensure_private_directory(directory) == Ok(Nil)
  let assert Ok(directory) = bootstrap.canonical_directory(directory)
  let assert Ok(paths) = endpoint.paths(directory)
  assert bootstrap.atomic_write_private(paths.token, owner) == Ok(Nil)
  let assert Ok(fence) = endpoint.observe(bootstrap.current_process_id())
    as "this VM has a native birth fence"
  let assert Ok(Nil) =
    endpoint.write(paths, endpoint.Ready(fence, "127.0.0.1", port, epoch, None))
  directory
}

fn token_file(owner: String) -> String {
  let assert Ok(directory) =
    bootstrap.absolute_path(
      "build/access-token-" <> int.to_string(int.random(1_000_000_000)),
    )
  assert bootstrap.ensure_private_directory(directory) == Ok(Nil)
  let path = directory <> "/owner.token"
  assert bootstrap.atomic_write_private(path, owner) == Ok(Nil)
  path
}

pub fn both_programs_print_the_same_lines_for_the_same_command_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let session = shared_session(ready, 30, "Same")
    let absent =
      ids.session_id_to_string(
        ids.mint_session(ids.generator(clock.fixed(0), 32)).0,
      )
    let state = published_state(port, ready.epoch, owner)
    let remote = [
      "--addr",
      address(port),
      "--token-file",
      token_file(owner),
    ]
    let assert Ok(invite) =
      admin.parse(["invite", session, "alice", "operator", "Alice"])
    let assert Ok(invited) =
      admin.exchange(address(port), owner, ready.epoch, invite)

    // The claim is redeemed first: an open claim's remaining lifetime moves
    // with the clock, so a listing that showed it could not be compared.
    let assert json.String(token) = field(invited, "claim")
    assert field(
        claims.redeem(port, token, claim.digest(claim.random_credential())),
        "event",
      )
      == json.String("credentials.claim")

    // Each command runs as `loomd access`, as `loom access` on the same state
    // directory, and as `loom access` over an address and a token file.
    let commands = [
      ["list"],
      ["list", "--after", "alice"],
      ["show", "alice"],
      ["members", session],
      ["members", session, "--after", "alice"],
      ["members", absent],
      ["set-role", session, "alice", "operator"],
      ["revoke-credentials", "alice"],
      ["show", "nobody"],
      ["rotate", "nobody"],
    ]
    list.each(commands, fn(command) {
      let loomd = printed(access.Loomd, ["--state-dir", state, ..command])
      let loom = printed(access.Loom, ["--state-dir", state, ..command])
      let over_address = printed(access.Loom, list.append(remote, command))
      assert loomd == loom as string.inspect(#(command, loomd, loom))
      assert loom == over_address
        as string.inspect(#(command, loom, over_address))
    })

    // The list is non-empty and succeeded, so the comparison above is not
    // between three identical failures.
    let #(outcome, out, _) =
      printed(access.Loomd, ["--state-dir", state, "list"])
    assert outcome == access.Succeeded
    assert list.length(out) == 2
    let #(refused, _, err) =
      printed(access.Loomd, ["--state-dir", state, "show", "nobody"])
    assert refused == access.Failed
    assert err == ["access: not_found"]
    Nil
  })
}

pub fn an_invitation_over_an_address_names_that_address_and_redeems_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let session = shared_session(ready, 31, "Remote")
    let remote = ["--addr", address(port), "--token-file", token_file(owner)]
    let #(outcome, out, err) =
      printed(
        access.Loom,
        list.append(remote, ["invite", session, "alice", "observer", "Alice"]),
      )
    assert outcome == access.Succeeded
    let assert [line] = out as "one line is printed"
    let assert Ok(reply) = json.parse(line)
    assert field(reply, "claim_command")
      == json.String("loom claim --addr " <> address(port))

    // The claim command carries no token, and the loopback note is for a
    // command that discovered its address locally, which this one did not.
    let assert json.String(token) = field(reply, "claim")
    assert !string.contains(string.replace(line, token, ""), "loomclaim_")
    assert err == ["principal recovery ID: alice"]
    let credential = claim.random_credential()
    assert field(claims.redeem(port, token, claim.digest(credential)), "event")
      == json.String("credentials.claim")

    // The listing now shows the redeemed claim's instant, over the address.
    let #(listed, lines, _) =
      printed(access.Loom, list.append(remote, ["list"]))
    assert listed == access.Succeeded
    let assert Ok(alice) =
      list.find_map(lines, fn(line) {
        let assert Ok(value) = json.parse(line)
        case has_field(value, "principal_id") {
          True ->
            case field(value, "principal_id") == json.String("alice") {
              True -> Ok(value)
              False -> Error(Nil)
            }
          False -> Error(Nil)
        }
      })
    assert has_field(field(alice, "credential"), "claimed_at_ms")
    Nil
  })
}

pub fn a_remote_command_with_the_wrong_token_prints_no_token_test() {
  wire.fixture(fn(_, _ready, port, _owner) {
    let wrong = string.repeat("a", 64)
    let #(outcome, out, err) =
      printed(access.Loom, [
        "--addr",
        address(port),
        "--token-file",
        token_file(wrong),
        "list",
      ])
    assert outcome == access.Failed
    assert out == []
    assert err == ["access: control connection failed; request not sent"]
    assert !string.contains(string.join(err, "\n"), wrong)
    Nil
  })
}

pub fn the_usage_constants_match_the_shared_module_test() {
  assert admin.usage == access.usage(access.Loomd)
}
