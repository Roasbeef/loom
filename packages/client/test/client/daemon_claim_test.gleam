//// The claim flow over the daemon's real router and SQLite catalogue
//// (protocol-change/053). Each test names one threat the proposal lists and
//// asserts the refusal; the assembly is inert, as in the wire fixture these
//// build on, except where a resident session is needed to show a claimed
//// member's attachment closing on revocation.

import broker/token as vault
import client/daemon/admin
import client/daemon/manager
import client/daemon/root
import client/daemon_server_test as wire
import client/session_socket_test
import core/clock
import core/ids
import core/json.{type JsonValue}
import core/workspace
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import host/bootstrap
import host/claim
import simplifile
import sqlight
import storage/access
import storage/domain
import support/internal/ffi_daemon_socket
import support/internal/ffi_ws
import tui/claim as loom_claim
import weft
import weft/poll

fn field(value: JsonValue, key: String) -> JsonValue {
  let assert json.Object(fields) = value as "the frame is an object"
  let assert Ok(found) = list.key_find(fields, key) as "the field is present"
  found
}

fn has_field(value: JsonValue, key: String) -> Bool {
  let assert json.Object(fields) = value as "the frame is an object"
  list.key_find(fields, key) != Error(Nil)
}

fn address(port: Int) -> String {
  "ws://127.0.0.1:" <> int.to_string(port) <> "/v2/control"
}

fn shared_session(ready: root.Ready(String), seed: Int) -> String {
  let assert Ok(view) =
    manager.create_scoped(
      ready.registry,
      manager.Creation(
        "claim-" <> int.to_string(seed),
        workspace.LocalBinding("/workspace"),
        "S",
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

// Invites through the shipped CLI parser and exchange, and answers the reply
// and the claim token it carries.
fn invite(port, owner, epoch, session, principal, role) {
  let assert Ok(request) =
    admin.parse(["invite", session, principal, role, principal])
    as "the shipped parser accepts a claim invitation"
  let assert Ok(reply) = admin.exchange(address(port), owner, epoch, request)
    as "the owner's invitation succeeds"
  let assert json.String(token) = field(reply, "claim")
    as "the invitation reply carries a claim"
  #(reply, token)
}

// Opens `/v2/claim` with a raw socket, reads the hello, sends one
// `credentials.claim`, and answers the reply frame.
@internal
pub fn redeem(port: Int, token: String, digest: String) -> JsonValue {
  redeem_named(port, token, digest, None)
}

// The same exchange with the optional `name` the invitee chose in the body.
fn redeem_named(
  port: Int,
  token: String,
  digest: String,
  name: Option(String),
) -> JsonValue {
  let socket = claim_socket(port, token)
  let hello = wire.frame(socket, within_ms: 2000)
  assert field(hello, "event") == json.String("hello")
  assert field(field(hello, "body"), "protocol") == json.Int(2)
  let reply =
    wire.send(
      socket,
      1,
      "credentials.claim",
      json.Object(case name {
        Some(chosen) -> [
          #("credential_digest", json.String(digest)),
          #("name", json.String(chosen)),
        ]
        None -> [#("credential_digest", json.String(digest))]
      }),
      within_ms: 5000,
    )
  let _ = ffi_ws.tcp_close(socket)
  reply
}

// Upgrades `token` on the claim route, waiting out an earlier redemption.
// Closing a claim socket here does not end the daemon's process for it at
// once, and until that process is gone the claim is still in flight, so an
// upgrade straight after an earlier `redeem` of the same claim is answered
// 409 by design (`second_in_flight_upgrade_for_one_claim_is_refused_test`
// pins that refusal). Only a 409 is waited out; any other answer is the
// test's to judge, so a refusal the flow means to give still fails here.
fn claim_socket(port: Int, token: String) {
  let assert poll.Answered(socket) =
    poll.until(within: 3000, every: 20, attempt: fn() {
      let #(socket, response) = wire.connect(port, token, "/v2/claim")
      case string.contains(response, "409 ") {
        True -> {
          let _ = ffi_ws.tcp_close(socket)
          poll.Retry
        }

        False -> {
          assert string.contains(response, "101 Switching Protocols")
          poll.Done(socket)
        }
      }
    })
    as "the claim's earlier socket ends within three seconds"
  socket
}

fn refusal_code(reply: JsonValue) -> JsonValue {
  assert field(reply, "event") == json.String("error")
  field(field(reply, "body"), "code")
}

fn upgrade_status(port: Int, token: String, path: String) -> String {
  let #(socket, response) = wire.connect(port, token, path)
  let _ = ffi_ws.tcp_close(socket)
  response
}

fn bearer() -> #(String, String) {
  let credential = claim.random_credential()
  #(credential, claim.digest(credential))
}

pub fn invitation_and_rotation_replies_carry_a_claim_and_no_bearer_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let session = shared_session(ready, 1)
    let #(reply, token) =
      invite(port, owner, ready.epoch, session, "alice", "observer")
    assert claim.validate_token(token) == Ok(Nil)
    assert field(reply, "expires_in_ms") == json.Int(86_400_000)
    assert field(reply, "claim_command")
      == json.String("loom claim --addr " <> address(port))
    assert !string.contains(json.to_string(reply), "bearer")

    // The invited principal has no credential until it claims, so nothing
    // the invitation produced authenticates.
    assert credential_count(ready.state_root, "alice") == 0
    assert string.contains(
      upgrade_status(port, token, "/v2/control"),
      "401 Unauthorized",
    )

    let assert Ok(rotate) = admin.parse(["rotate", "alice", "--ttl", "30m"])
      as "rotation takes a lifetime"
    let assert Ok(rotated) =
      admin.exchange(address(port), owner, ready.epoch, rotate)
      as "rotation issues a new claim"
    let assert json.String(second) = field(rotated, "claim")
      as "rotation reply carries a claim"
    assert second != token
    assert field(rotated, "expires_in_ms") == json.Int(1_800_000)
    assert !has_field(rotated, "bearer")
    Nil
  })
}

pub fn claim_binds_once_and_a_replay_is_refused_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let session = shared_session(ready, 2)
    let #(_, token) =
      invite(port, owner, ready.epoch, session, "alice", "operator")
    let #(credential, digest) = bearer()
    let reply = redeem(port, token, digest)
    assert field(reply, "event") == json.String("credentials.claim")
    assert field(reply, "reply_to") == json.Int(1)
    let body = field(reply, "body")
    assert field(body, "principal_id") == json.String("alice")
    assert field(body, "fingerprint")
      == json.String(string.slice(digest, 0, 16))
    assert field(body, "sessions")
      == json.Array([
        json.Object([
          #("session_id", json.String(session)),
          #("role", json.String("operator")),
        ]),
      ])
    assert string.contains(
      upgrade_status(port, credential, "/v2/control"),
      "101 Switching Protocols",
    )

    // A lost reply is recovered with the same digest: the same body again.
    assert redeem(port, token, digest) == reply

    // A replay of the spent claim with any other digest binds nothing.
    let #(other, other_digest) = bearer()
    assert refusal_code(redeem(port, token, other_digest))
      == json.String("conflict")
    assert string.contains(
      upgrade_status(port, other, "/v2/control"),
      "401 Unauthorized",
    )
    assert credential_count(ready.state_root, "alice") == 1
    Nil
  })
}

// The name `principals.list` reports for one principal, read as the owner.
fn listed_name(port: Int, owner: String, id: String) -> JsonValue {
  let #(socket, response) = wire.connect(port, owner, "/v2/control")
  assert string.contains(response, "101 Switching Protocols")
  let _hello = wire.frame(socket, within_ms: 1000)
  let reply =
    wire.send(socket, 1, "principals.list", json.Object([]), within_ms: 2000)
  let _ = ffi_ws.tcp_close(socket)
  let assert json.Array(rows) = field(field(reply, "body"), "principals")
    as "the owner's listing carries the principals"
  let assert Ok(found) =
    list.find(rows, fn(row) { field(row, "principal_id") == json.String(id) })
    as "the principal is listed"
  field(found, "name")
}

pub fn a_claim_with_a_name_sets_it_and_one_without_keeps_the_inviters_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let session = shared_session(ready, 30)
    let #(_, named) =
      invite(port, owner, ready.epoch, session, "alice", "operator")
    let #(_, plain) =
      invite(port, owner, ready.epoch, session, "bob", "observer")

    // The reply, the owner's listing and the member's own attachment all
    // carry the chosen name, trimmed.
    let #(credential, digest) = bearer()
    let reply = redeem_named(port, named, digest, Some("  Alex Doe "))
    assert field(reply, "event") == json.String("credentials.claim")
    assert field(field(reply, "body"), "name") == json.String("Alex Doe")
    assert listed_name(port, owner, "alice") == json.String("Alex Doe")
    assert string.contains(
      upgrade_status(port, credential, "/v2/control"),
      "101 Switching Protocols",
    )

    // No name keeps the one the invitation gave.
    let #(_, other) = bearer()
    let kept = redeem(port, plain, other)
    assert field(field(kept, "body"), "name") == json.String("bob")
    assert listed_name(port, owner, "bob") == json.String("bob")
    Nil
  })
}

pub fn a_refused_name_binds_nothing_and_the_claim_stays_open_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let session = shared_session(ready, 31)
    let #(_, token) =
      invite(port, owner, ready.epoch, session, "alice", "observer")
    let #(credential, digest) = bearer()

    // Each refusal has one code and names no digest and no name.
    let refused = fn(name) {
      let reply = redeem_named(port, token, digest, Some(name))
      assert refusal_code(reply) == json.String("invalid_name")
      assert !string.contains(json.to_string(reply), digest)
      Nil
    }
    refused("")
    refused("   ")
    refused("two\nlines")
    refused("bell\u{7}")
    refused(string.repeat("a", 257))
    refused("Alex\u{202E}")
    refused("\u{200B}")
    assert credential_count(ready.state_root, "alice") == 0
    assert listed_name(port, owner, "alice") == json.String("alice")
    assert string.contains(
      upgrade_status(port, credential, "/v2/control"),
      "401 Unauthorized",
    )

    // A name that is not text is a malformed message, also before any write.
    let socket = claim_socket(port, token)
    let _hello = wire.frame(socket, within_ms: 2000)
    let malformed =
      wire.send(
        socket,
        1,
        "credentials.claim",
        json.Object([
          #("credential_digest", json.String(digest)),
          #("name", json.Int(7)),
        ]),
        within_ms: 5000,
      )
    let _ = ffi_ws.tcp_close(socket)
    assert refusal_code(malformed) == json.String("bad_request")
    assert credential_count(ready.state_root, "alice") == 0

    // The claim is still redeemable, by the same digest and a good name.
    let reply = redeem_named(port, token, digest, Some("Alex"))
    assert field(field(reply, "body"), "name") == json.String("Alex")
    assert credential_count(ready.state_root, "alice") == 1
    Nil
  })
}

pub fn a_replay_with_the_same_digest_answers_the_same_body_and_never_renames_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let session = shared_session(ready, 32)
    let #(_, token) =
      invite(port, owner, ready.epoch, session, "alice", "observer")
    let #(_, digest) = bearer()
    let first = redeem_named(port, token, digest, Some("Alex"))
    assert field(field(first, "body"), "name") == json.String("Alex")

    // A lost reply is retried with the same name, another, or none: the body
    // is the first one, and the principal keeps the name it was bound with.
    assert redeem_named(port, token, digest, Some("Alex")) == first
    assert redeem_named(port, token, digest, Some("Someone Else")) == first
    assert redeem_named(port, token, digest, None) == first
    assert listed_name(port, owner, "alice") == json.String("Alex")
    Nil
  })
}

pub fn claim_is_not_a_bearer_and_a_bearer_is_not_a_claim_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let session = shared_session(ready, 3)
    let #(_, token) =
      invite(port, owner, ready.epoch, session, "alice", "observer")
    assert string.contains(
      upgrade_status(port, token, "/v2/control"),
      "401 Unauthorized",
    )
    assert string.contains(
      upgrade_status(port, token, "/v2/sessions/" <> session <> "/ws"),
      "401 Unauthorized",
    )

    // The owner's own bearer is not a claim, and an unknown claim is refused
    // before any socket is opened for it.
    assert string.contains(
      upgrade_status(port, owner, "/v2/claim"),
      "401 Unauthorized",
    )
    let unknown = claim.mint_token(vault.production_entropy())
    assert string.contains(
      upgrade_status(port, unknown, "/v2/claim"),
      "401 Unauthorized",
    )

    // Even after it is spent, the claim string authenticates nothing.
    let #(_, digest) = bearer()
    assert field(redeem(port, token, digest), "event")
      == json.String("credentials.claim")
    assert string.contains(
      upgrade_status(port, token, "/v2/control"),
      "401 Unauthorized",
    )
    Nil
  })
}

pub fn claim_bound_to_its_own_digest_is_refused_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let session = shared_session(ready, 4)
    let #(_, token) =
      invite(port, owner, ready.epoch, session, "alice", "observer")

    // The SHA-256 of the claim string would turn the string itself, which
    // sits in a chat log, into a durable bearer.
    assert refusal_code(redeem(port, token, claim.digest(token)))
      == json.String("conflict")
    assert string.contains(
      upgrade_status(port, token, "/v2/control"),
      "401 Unauthorized",
    )
    assert credential_count(ready.state_root, "alice") == 0
    let #(_, digest) = bearer()
    assert field(redeem(port, token, digest), "event")
      == json.String("credentials.claim")
    Nil
  })
}

pub fn concurrent_claims_with_different_digests_bind_exactly_one_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let session = shared_session(ready, 5)
    let #(_, token) =
      invite(port, owner, ready.epoch, session, "alice", "observer")
    let bearers = list.map(list.repeat(Nil, 4), fn(_) { bearer() })
    let outcomes =
      bearers
      |> list.map(fn(pair) { fn() { Ok(attempt(port, token, pair.1)) } })
      |> weft.new
      |> weft.deadline(15_000)
      |> weft.start
    let answers =
      list.map(outcomes, fn(outcome) {
        let assert weft.Completed(value:, ..) = outcome
          as "every attempt reports its outcome"
        value
      })
    assert list.count(answers, fn(answer) { answer == "claimed" }) == 1
    assert list.all(answers, fn(answer) {
      answer == "claimed" || answer == "in_flight" || answer == "conflict"
    })

    // Exactly one of the four credentials authenticates.
    let admitted =
      list.count(bearers, fn(pair) {
        string.contains(
          upgrade_status(port, pair.0, "/v2/control"),
          "101 Switching Protocols",
        )
      })
    assert admitted == 1
    assert credential_count(ready.state_root, "alice") == 1
    Nil
  })
}

fn attempt(port: Int, token: String, digest: String) -> String {
  let #(socket, response) = wire.connect(port, token, "/v2/claim")
  case string.contains(response, "101 Switching Protocols") {
    False -> {
      let _ = ffi_ws.tcp_close(socket)
      case string.contains(response, "409 ") {
        True -> "in_flight"
        False -> response
      }
    }
    True -> {
      let _hello = wire.frame(socket, within_ms: 5000)
      let reply =
        wire.send(
          socket,
          1,
          "credentials.claim",
          json.Object([#("credential_digest", json.String(digest))]),
          within_ms: 5000,
        )
      let _ = ffi_ws.tcp_close(socket)
      case field(reply, "event") {
        json.String("credentials.claim") -> "claimed"
        _refused -> {
          let assert json.String(code) = refusal_code(reply)
            as "a refusal names its code"
          code
        }
      }
    }
  }
}

pub fn expired_claim_is_refused_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let session = shared_session(ready, 6)

    // The wire bounds a lifetime to at least five minutes, so the expired
    // claim is issued through the registry with an instant already past.
    let token = claim.mint_token(vault.production_entropy())
    let assert Ok(claim_digest) = access.claim_digest(claim.digest(token))
      as "the claim digest is valid"
    let assert Ok(owner_digest) = access.credential_digest(claim.digest(owner))
      as "the owner digest is valid"
    let enrollment =
      access.ClaimEnrollment(claim_digest, bootstrap.system_time_ms() - 1)
    let assert Ok(_) =
      manager.administer(
        ready.registry,
        owner_digest,
        ready.epoch,
        manager.Invite("late", "Late", enrollment, session, access.Observer),
      )
      as "the owner invites with a claim that has already expired"
    let #(_, digest) = bearer()
    assert refusal_code(redeem(port, token, digest)) == json.String("expired")
    assert credential_count(ready.state_root, "late") == 0
    Nil
  })
}

pub fn revoked_and_rotated_claims_are_refused_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let session = shared_session(ready, 7)
    let #(_, revoked) =
      invite(port, owner, ready.epoch, session, "alice", "observer")
    let assert Ok(revoke) = admin.parse(["revoke-credentials", "alice"])
      as "revocation parses"
    let assert Ok(_) = admin.exchange(address(port), owner, ready.epoch, revoke)
      as "the owner revokes the member"

    // A voided claim no longer passes the upgrade's filter.
    assert string.contains(
      upgrade_status(port, revoked, "/v2/claim"),
      "401 Unauthorized",
    )

    // Rotation voids the delivered claim and issues the next one.
    let assert Ok(rotate) = admin.parse(["rotate", "alice"]) as "rotate parses"
    let assert Ok(rotated) =
      admin.exchange(address(port), owner, ready.epoch, rotate)
      as "the owner rotates"
    let assert json.String(current) = field(rotated, "claim")
      as "a new claim is issued"
    let assert Ok(_) = admin.exchange(address(port), owner, ready.epoch, rotate)
      as "the owner rotates again"
    assert string.contains(
      upgrade_status(port, current, "/v2/claim"),
      "401 Unauthorized",
    )

    // A claimed claim whose credential was revoked answers `not_found`.
    let #(_, bound) =
      invite(port, owner, ready.epoch, session, "bob", "observer")
    let #(_, digest) = bearer()
    assert field(redeem(port, bound, digest), "event")
      == json.String("credentials.claim")
    let assert Ok(revoke_bob) = admin.parse(["revoke-credentials", "bob"])
      as "revocation parses"
    let assert Ok(_) =
      admin.exchange(address(port), owner, ready.epoch, revoke_bob)
      as "the owner revokes bob"
    assert refusal_code(redeem(port, bound, digest)) == json.String("not_found")
    Nil
  })
}

pub fn second_in_flight_upgrade_for_one_claim_is_refused_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let session = shared_session(ready, 8)
    let #(_, token) =
      invite(port, owner, ready.epoch, session, "alice", "observer")
    let #(first, response) = wire.connect(port, token, "/v2/claim")
    assert string.contains(response, "101 Switching Protocols")

    // While the first socket is open, a second upgrade for the same claim is
    // refused before any socket or permit is given to it.
    assert string.contains(upgrade_status(port, token, "/v2/claim"), "409 ")
    let _ = ffi_ws.tcp_close(first)

    // Once the first socket's process is gone, the claim is admitted again.
    assert poll.until(within: 3000, every: 20, attempt: fn() {
        case
          string.contains(
            upgrade_status(port, token, "/v2/claim"),
            "101 Switching Protocols",
          )
        {
          True -> poll.Done(Nil)
          False -> poll.Retry
        }
      })
      == poll.Answered(Nil)
    Nil
  })
}

pub fn claim_socket_without_a_command_closes_after_two_seconds_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let session = shared_session(ready, 9)
    let #(_, token) =
      invite(port, owner, ready.epoch, session, "alice", "observer")
    let #(socket, response) = wire.connect(port, token, "/v2/claim")
    assert string.contains(response, "101 Switching Protocols")
    let opened = bootstrap.monotonic_time_ms()
    let _hello = wire.frame(socket, within_ms: 2000)

    // Nothing is sent. The daemon closes the socket on its own: a close frame
    // or the TCP close itself, never this read's own five-second timeout.
    let closed = case ffi_ws.tcp_receive(socket, 1, 5000) {
      Ok(<<0x88>>) -> True
      Ok(_) -> False
      Error(reason) -> reason == atom.to_dynamic(atom.create("closed"))
    }
    let elapsed = bootstrap.monotonic_time_ms() - opened
    let _ = ffi_ws.tcp_close(socket)
    assert closed
    assert elapsed >= 1500
    assert elapsed < 4500
    Nil
  })
}

pub fn claim_lifetime_bounds_and_exclusive_enrollment_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let session = shared_session(ready, 10)
    let #(socket, response) = wire.connect(port, owner, "/v2/control")
    assert string.contains(response, "101 Switching Protocols")
    let _hello = wire.frame(socket, within_ms: 1000)
    let base = [
      #("session_id", json.String(session)),
      #("name", json.String("Member")),
      #("role", json.String("observer")),
      #("epoch", json.String(ready.epoch)),
    ]
    let invite_with = fn(id, principal, extra) {
      wire.send(
        socket,
        id,
        "sessions.invite",
        json.Object([
          #("principal_id", json.String(principal)),
          ..list.append(base, extra)
        ]),
        within_ms: 2000,
      )
    }
    let #(credential, digest) = bearer()
    assert refusal_code(
        invite_with(1, "short", [#("claim_ttl_ms", json.Int(299_999))]),
      )
      == json.String("bad_request")
    assert refusal_code(
        invite_with(2, "long", [#("claim_ttl_ms", json.Int(604_800_001))]),
      )
      == json.String("bad_request")
    assert refusal_code(
        invite_with(3, "both", [
          #("claim_ttl_ms", json.Int(300_000)),
          #("credential_digest", json.String(digest)),
        ]),
      )
      == json.String("bad_request")

    // The daemon's own reply, read off the wire rather than through the CLI
    // that re-encodes it, carries a claim and no bearer.
    let plain = invite_with(5, "plain", [])
    assert field(plain, "event") == json.String("sessions.invite")
    let assert json.String(issued) = field(field(plain, "body"), "claim")
      as "the raw invitation reply carries a claim"
    assert claim.validate_token(issued) == Ok(Nil)
    assert !has_field(field(plain, "body"), "bearer")
    assert !string.contains(json.to_string(plain), "bearer")

    // Enrollment by digest: the credential exists at once and no claim does.
    let enrolled =
      invite_with(4, "enrolled", [#("credential_digest", json.String(digest))])
    assert field(enrolled, "event") == json.String("sessions.invite")
    assert !has_field(field(enrolled, "body"), "claim")
    assert !has_field(field(enrolled, "body"), "bearer")
    let _ = ffi_ws.tcp_close(socket)
    assert string.contains(
      upgrade_status(port, credential, "/v2/control"),
      "101 Switching Protocols",
    )
    Nil
  })
}

pub fn catalogue_holds_digests_and_never_a_token_or_credential_test() {
  wire.fixture(fn(_, ready, port, owner) {
    let session = shared_session(ready, 11)
    let #(_, token) =
      invite(port, owner, ready.epoch, session, "alice", "observer")
    let #(credential, digest) = bearer()
    assert field(redeem(port, token, digest), "event")
      == json.String("credentials.claim")
    let #(_, refused) = bearer()
    assert refusal_code(redeem(port, token, refused)) == json.String("conflict")

    // Every file the daemon keeps under its state root, the catalogue and
    // its write-ahead log included, holds the claim and the credential only
    // as digests.
    let assert Ok(files) = simplifile.get_files(ready.state_root)
      as "the state root is readable"
    list.each(files, fn(path) {
      let assert Ok(bytes) = simplifile.read_bits(path) as "state file reads"
      assert !contains(bytes, bit_array.from_string(token))
      assert !contains(bytes, bit_array.from_string(credential))
    })
    Nil
  })
}

pub fn claimed_member_attaches_with_its_role_and_revocation_closes_it_test() {
  session_socket_test.fixture(fn(port, owner, session, epoch, _) {
    let #(_, token) = invite(port, owner, epoch, session, "reader", "observer")
    let directory =
      "build/test_db/claim-invitee-"
      <> bit_array.base16_encode(vault.production_entropy()(6))
    let assert Ok(remote) =
      loom_claim.remote(loom_claim.Options(address(port), "", directory, ""))
      as "the invitee's private remote directory is prepared"
    let assert Ok(claimed) = loom_claim.redeem(remote, token, "")
      as "loom claim binds a credential it drew itself"
    assert claimed.sessions == [loom_claim.Membership(session, "observer")]
    let assert Ok(bytes) =
      bootstrap.read_private_bounded(loom_claim.credential_path(remote), 64)
      as "the credential file is private"
    let assert Ok(credential) = bit_array.to_string(bytes)
      as "the credential is text"

    // The stored credential attaches with exactly the granted role.
    let #(socket, response) =
      wire.connect(port, credential, "/v2/sessions/" <> session <> "/ws")
    assert string.contains(response, "101 Switching Protocols")
    let begin = wire.subscribe(socket, 1, session, within_ms: 2000)
    assert field(field(begin, "body"), "role") == json.String("observer")

    let assert Ok(revoke) = admin.parse(["revoke-credentials", "reader"])
      as "revocation parses"
    let assert Ok(_) = admin.exchange(address(port), owner, epoch, revoke)
      as "the owner revokes the claimed credential"

    // The next frame on the attachment is refused and the socket closes.
    let text =
      json.to_string(
        json.Object([
          #("v", json.Int(2)),
          #("id", json.Int(2)),
          #("cmd", json.String("snapshot_next")),
          #(
            "body",
            json.Object([
              #("snapshot_id", field(field(begin, "body"), "snapshot_id")),
              #("index", json.Int(0)),
            ]),
          ),
        ]),
      )
    let payload = bit_array.from_string(text)
    let size = bit_array.byte_size(payload)
    assert ffi_daemon_socket.send(socket, <<
        0x81,
        1:1,
        size:7,
        0:32,
        payload:bits,
      >>)
      == Ok(Nil)
    let assert Ok(<<0x88, _>>) = ffi_ws.tcp_receive(socket, 2, 2000)
      as "the revoked attachment is closed"
    let _ = ffi_ws.tcp_close(socket)
    let _ = simplifile.delete(directory)
    Nil
  })
}

pub fn loom_claim_sends_the_name_and_keeps_the_claim_after_a_refused_one_test() {
  session_socket_test.fixture(fn(port, owner, session, epoch, _) {
    let #(_, token) = invite(port, owner, epoch, session, "reader", "observer")
    let directory =
      "build/test_db/claim-named-"
      <> bit_array.base16_encode(vault.production_entropy()(6))
    let assert Ok(remote) =
      loom_claim.remote(loom_claim.Options(address(port), "", directory, ""))
      as "the invitee's private remote directory is prepared"

    // A refused name is not a final refusal: the credential file stays, so
    // the rerun below redeems the same open claim with the same credential.
    let assert Error(loom_claim.Invalid(_)) =
      loom_claim.redeem(remote, token, "   ")
      as "a blank name is refused by the daemon and reported as invalid"
    let assert Ok(kept) =
      bootstrap.read_private_bounded(loom_claim.credential_path(remote), 64)
      as "the credential survives the refused name"
    let assert Ok(claimed) = loom_claim.redeem(remote, token, "Alex Doe")
      as "the rerun binds with a good name"
    assert claimed.name == "Alex Doe"
    let assert Ok(bound) =
      bootstrap.read_private_bounded(loom_claim.credential_path(remote), 64)
      as "the credential file is still there"
    assert bound == kept
    let _ = simplifile.delete(directory)
    Nil
  })
}

fn credential_count(state_root: String, principal: String) -> Int {
  let assert Ok(db) = sqlight.open(state_root <> "/catalogue.db")
    as "a separate read connection opens"
  let assert Ok(rows) =
    sqlight.query(
      "SELECT count(*) FROM access_credentials WHERE principal_id = ?",
      on: db,
      with: [sqlight.text(principal)],
      expecting: decode.at([0], decode.int),
    )
    as "credential rows count"
  assert sqlight.close(db) == Ok(Nil)
  let assert [count] = rows as "one count row"
  count
}

fn contains(haystack: BitArray, needle: BitArray) -> Bool {
  let size = bit_array.byte_size(needle)
  contains_from(haystack, needle, size, 0, bit_array.byte_size(haystack) - size)
}

fn contains_from(haystack, needle, size, offset, last) -> Bool {
  case offset > last {
    True -> False
    False ->
      case bit_array.slice(haystack, offset, size) == Ok(needle) {
        True -> True
        False -> contains_from(haystack, needle, size, offset + 1, last)
      }
  }
}
