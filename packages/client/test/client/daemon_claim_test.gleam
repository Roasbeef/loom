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
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/int
import gleam/list
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
      manager.Creation("claim-" <> int.to_string(seed), "/workspace", "S", ""),
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
  let #(socket, response) = wire.connect(port, token, "/v2/claim")
  assert string.contains(response, "101 Switching Protocols")
  let hello = wire.frame(socket, within_ms: 2000)
  assert field(hello, "event") == json.String("hello")
  assert field(field(hello, "body"), "protocol") == json.Int(2)
  let reply =
    wire.send(
      socket,
      1,
      "credentials.claim",
      json.Object([#("credential_digest", json.String(digest))]),
      within_ms: 5000,
    )
  let _ = ffi_ws.tcp_close(socket)
  reply
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
      loom_claim.remote(loom_claim.Options(address(port), "", directory))
      as "the invitee's private remote directory is prepared"
    let assert Ok(claimed) = loom_claim.redeem(remote, token)
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
    let begin =
      wire.send(
        socket,
        1,
        "subscribe",
        json.Object([#("session", json.String(session))]),
        within_ms: 2000,
      )
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
