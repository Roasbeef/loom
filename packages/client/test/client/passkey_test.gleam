//// The pure checks of a passkey registration and sign-in
//// (`client/daemon/passkey`), against keys the tests make with `kryptos`: one
//// accepted ceremony of each kind, then one test per way a ceremony can be
//// refused, then two properties over the counter and the signature.

import client/daemon/passkey
import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import kryptos/ec
import kryptos/ecdsa
import kryptos/hash
import qcheck

/// The qcheck seed the counter property is drawn from.
const counter_seed = 127_001

/// The qcheck seed the signature-mutation property is drawn from.
const mutation_seed = 127_002

/// The qcheck seed the whole-range counter property is drawn from.
const wide_seed = 127_003

const origin = "https://box.tail0a99b.ts.net"

const rp_id = "box.tail0a99b.ts.net"

const challenge = "dGhlLWNoYWxsZW5nZS1pc3N1ZWQtYnktdGhlLWRhZW1vbg"

// The flags a user-verified, user-present assertion carries.
const verified_present = 5

// The same with the attested credential data flag, as a registration has.
const verified_present_attested = 69

fn expected() -> passkey.Expected {
  passkey.Expected(origin:, rp_id:, challenge:)
}

fn client_data(kind: String, challenge: String, origin: String) -> BitArray {
  json.object([
    #("type", json.string(kind)),
    #("challenge", json.string(challenge)),
    #("origin", json.string(origin)),
    #("crossOrigin", json.bool(False)),
  ])
  |> json.to_string
  |> bit_array.from_string
}

fn rp_hash(id: String) -> BitArray {
  crypto.hash(crypto.Sha256, bit_array.from_string(id))
}

// Authenticator data without credential data: the fixed 37 bytes.
fn authenticator_data(id: String, flags: Int, count: Int) -> BitArray {
  <<rp_hash(id):bits, flags:8, count:32>>
}

// Authenticator data of a registration: the fixed part, a model id, the
// credential id and a stand-in for the COSE key, which the daemon does not read.
fn attested_data(credential: BitArray, flags: Int, count: Int) -> BitArray {
  let length = bit_array.byte_size(credential)
  <<
    authenticator_data(rp_id, flags, count):bits,
    0:size(128),
    length:16,
    credential:bits,
    "cose-key-bytes":utf8,
  >>
}

fn pair() -> #(ec.PrivateKey, BitArray) {
  let #(private, public) = ec.generate_key_pair(ec.P256)
  let assert Ok(der) = ec.public_key_to_der(public) as "a P-256 key has DER"
  #(private, der)
}

// A signed assertion over `data` and `client`.
fn assertion(
  private: ec.PrivateKey,
  data: BitArray,
  client: BitArray,
) -> passkey.Assertion {
  let message = <<data:bits, crypto.hash(crypto.Sha256, client):bits>>
  passkey.Assertion(
    client_data: client,
    authenticator_data: data,
    signature: ecdsa.sign(private, message, hash.Sha256),
  )
}

fn good_client() -> BitArray {
  client_data("webauthn.get", challenge, origin)
}

pub fn a_good_assertion_verifies_and_reports_its_counter_test() {
  let #(private, der) = pair()
  let data = authenticator_data(rp_id, verified_present, 7)
  let signed = assertion(private, data, good_client())
  assert passkey.verify_assertion(
      expected(),
      passkey.Stored(public_key: der, sign_count: 6),
      signed,
    )
    == Ok(7)
}

pub fn the_challenge_is_read_from_the_client_data_test() {
  assert passkey.challenge_of(good_client()) == Ok(challenge)
  assert passkey.challenge_of(<<"not json":utf8>>) == Error(Nil)
  assert passkey.challenge_of(<<"{\"type\":\"webauthn.get\"}":utf8>>)
    == Error(Nil)
}

pub fn an_assertion_for_another_origin_is_refused_test() {
  let #(private, der) = pair()
  let data = authenticator_data(rp_id, verified_present, 7)
  let stored = passkey.Stored(public_key: der, sign_count: 0)

  // Another scheme, another host and another port each differ from the page's
  // origin, as does a frame of another origin that says so.
  let other = [
    "http://box.tail0a99b.ts.net",
    "https://evil.example",
    "https://box.tail0a99b.ts.net:8443",
    origin <> "/",
  ]
  list.each(other, fn(wrong) {
    let client = client_data("webauthn.get", challenge, wrong)
    assert passkey.verify_assertion(
        expected(),
        stored,
        assertion(private, data, client),
      )
      == Error(passkey.WrongOrigin)
  })

  let framed =
    json.object([
      #("type", json.string("webauthn.get")),
      #("challenge", json.string(challenge)),
      #("origin", json.string(origin)),
      #("crossOrigin", json.bool(True)),
    ])
    |> json.to_string
    |> bit_array.from_string
  assert passkey.verify_assertion(
      expected(),
      stored,
      assertion(private, data, framed),
    )
    == Error(passkey.WrongOrigin)
}

pub fn an_assertion_for_another_relying_party_is_refused_test() {
  let #(private, der) = pair()
  let data = authenticator_data("evil.example", verified_present, 7)
  assert passkey.verify_assertion(
      expected(),
      passkey.Stored(public_key: der, sign_count: 0),
      assertion(private, data, good_client()),
    )
    == Error(passkey.WrongRelyingParty)
}

pub fn an_assertion_without_user_verification_or_presence_is_refused_test() {
  let #(private, der) = pair()
  let stored = passkey.Stored(public_key: der, sign_count: 0)

  // Present but not verified, and verified but not present.
  let unverified = authenticator_data(rp_id, 1, 7)
  assert passkey.verify_assertion(
      expected(),
      stored,
      assertion(private, unverified, good_client()),
    )
    == Error(passkey.UserNotVerified)
  let absent = authenticator_data(rp_id, 4, 7)
  assert passkey.verify_assertion(
      expected(),
      stored,
      assertion(private, absent, good_client()),
    )
    == Error(passkey.UserNotPresent)
}

pub fn an_assertion_for_another_challenge_or_ceremony_is_refused_test() {
  let #(private, der) = pair()
  let data = authenticator_data(rp_id, verified_present, 7)
  let stored = passkey.Stored(public_key: der, sign_count: 0)
  let replayed = client_data("webauthn.get", "an-older-challenge", origin)
  assert passkey.verify_assertion(
      expected(),
      stored,
      assertion(private, data, replayed),
    )
    == Error(passkey.WrongChallenge)
  let created = client_data("webauthn.create", challenge, origin)
  assert passkey.verify_assertion(
      expected(),
      stored,
      assertion(private, data, created),
    )
    == Error(passkey.WrongCeremony)
  let garbage = <<"{":utf8>>
  assert passkey.verify_assertion(
      expected(),
      stored,
      assertion(private, data, garbage),
    )
    == Error(passkey.MalformedClientData)
}

pub fn a_short_authenticator_data_is_refused_test() {
  let #(private, der) = pair()
  let short = <<rp_hash(rp_id):bits, verified_present:8>>
  assert passkey.verify_assertion(
      expected(),
      passkey.Stored(public_key: der, sign_count: 0),
      assertion(private, short, good_client()),
    )
    == Error(passkey.MalformedAuthenticatorData)
}

pub fn a_counter_that_does_not_increase_is_refused_test() {
  let #(private, der) = pair()
  let at = fn(stored, reported) {
    passkey.verify_assertion(
      expected(),
      passkey.Stored(public_key: der, sign_count: stored),
      assertion(
        private,
        authenticator_data(rp_id, verified_present, reported),
        good_client(),
      ),
    )
  }

  // A synced passkey that reports zero is accepted beside a stored zero, and
  // every other pair must go up.
  assert at(0, 0) == Ok(0)
  assert at(5, 6) == Ok(6)
  assert at(5, 5) == Error(passkey.CounterNotIncreased)
  assert at(5, 4) == Error(passkey.CounterNotIncreased)
  assert at(5, 0) == Error(passkey.CounterNotIncreased)
  assert at(0, 1) == Ok(1)
}

pub fn an_assertion_signed_by_another_key_is_refused_test() {
  let #(_, der) = pair()
  let #(stranger, _) = pair()
  let data = authenticator_data(rp_id, verified_present, 7)
  assert passkey.verify_assertion(
      expected(),
      passkey.Stored(public_key: der, sign_count: 0),
      assertion(stranger, data, good_client()),
    )
    == Error(passkey.BadSignature)
}

pub fn an_assertion_whose_data_changed_after_signing_is_refused_test() {
  let #(private, der) = pair()
  let signed =
    assertion(
      private,
      authenticator_data(rp_id, verified_present, 7),
      good_client(),
    )
  let changed =
    passkey.Assertion(
      ..signed,
      authenticator_data: authenticator_data(rp_id, verified_present, 8),
    )
  assert passkey.verify_assertion(
      expected(),
      passkey.Stored(public_key: der, sign_count: 0),
      changed,
    )
    == Error(passkey.BadSignature)
}

pub fn a_stored_key_that_is_not_p256_is_refused_test() {
  let #(private, _) = pair()
  let data = authenticator_data(rp_id, verified_present, 7)
  let signed = assertion(private, data, good_client())

  // A P-384 key and a secp256k1 key are valid keys of other curves and other
  // sizes, and so is a string of bytes that is no key at all.
  let #(_, p384) = ec.generate_key_pair(ec.P384)
  let #(_, koblitz) = ec.generate_key_pair(ec.Secp256k1)
  let assert Ok(p384_der) = ec.public_key_to_der(p384) as "P-384 has DER"
  let assert Ok(koblitz_der) = ec.public_key_to_der(koblitz) as "k1 has DER"
  list.each([p384_der, koblitz_der, <<1, 2, 3>>], fn(der) {
    assert passkey.verify_assertion(
        expected(),
        passkey.Stored(public_key: der, sign_count: 0),
        signed,
      )
      == Error(passkey.UnsupportedKey)
  })
}

pub fn a_good_registration_yields_its_key_and_counter_test() {
  let #(_, der) = pair()
  let credential = <<"credential-id-bytes":utf8>>
  let registration =
    passkey.Registration(
      credential_id: credential,
      client_data: client_data("webauthn.create", challenge, origin),
      authenticator_data: attested_data(
        credential,
        verified_present_attested,
        0,
      ),
      public_key: der,
    )
  assert passkey.verify_registration(expected(), registration)
    == Ok(passkey.Registered(public_key: der, sign_count: 0))
}

pub fn a_registration_that_is_wrong_is_refused_test() {
  let #(_, der) = pair()
  let credential = <<"credential-id-bytes":utf8>>
  let good =
    passkey.Registration(
      credential_id: credential,
      client_data: client_data("webauthn.create", challenge, origin),
      authenticator_data: attested_data(
        credential,
        verified_present_attested,
        0,
      ),
      public_key: der,
    )
  assert result.is_ok(passkey.verify_registration(expected(), good))

  // Without the attested credential data, with another credential id, for
  // another origin, as a sign-in, without verification and with a key of
  // another curve.
  let bare = authenticator_data(rp_id, verified_present, 0)
  assert passkey.verify_registration(
      expected(),
      passkey.Registration(..good, authenticator_data: bare),
    )
    == Error(passkey.MissingCredential)
  assert passkey.verify_registration(
      expected(),
      passkey.Registration(..good, credential_id: <<"another-id":utf8>>),
    )
    == Error(passkey.CredentialMismatch)
  assert passkey.verify_registration(
      expected(),
      passkey.Registration(
        ..good,
        client_data: client_data("webauthn.create", challenge, "https://x.y"),
      ),
    )
    == Error(passkey.WrongOrigin)
  assert passkey.verify_registration(
      expected(),
      passkey.Registration(..good, client_data: good_client()),
    )
    == Error(passkey.WrongCeremony)
  assert passkey.verify_registration(
      expected(),
      passkey.Registration(
        ..good,
        authenticator_data: attested_data(credential, 65, 0),
      ),
    )
    == Error(passkey.UserNotVerified)
  let #(_, p384) = ec.generate_key_pair(ec.P384)
  let assert Ok(p384_der) = ec.public_key_to_der(p384) as "P-384 has DER"
  assert passkey.verify_registration(
      expected(),
      passkey.Registration(..good, public_key: p384_der),
    )
    == Error(passkey.UnsupportedKey)
}

fn counter_config(seed: Int) -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_test_count(60)
  |> qcheck.with_seed(qcheck.seed(seed))
}

/// Seeded by `counter_seed`: a stored and a reported counter drawn from a range
/// beside zero, where the equal and the zero cases are common. The answer
/// follows the rule exactly.
pub fn the_counter_rule_holds_beside_zero_test() {
  let #(private, der) = pair()
  let counters = qcheck.bounded_int(from: 0, to: 4)
  qcheck.run(
    counter_config(counter_seed),
    qcheck.tuple2(counters, counters),
    fn(counted) { counter_follows_rule(private, der, counted.0, counted.1) },
  )
}

/// Seeded by `wide_seed`: the same rule over the whole unsigned 32-bit range.
pub fn the_counter_rule_holds_over_the_whole_range_test() {
  let #(private, der) = pair()
  let counters = qcheck.bounded_int(from: 0, to: 4_294_967_295)
  qcheck.run(
    counter_config(wide_seed),
    qcheck.tuple2(counters, counters),
    fn(counted) { counter_follows_rule(private, der, counted.0, counted.1) },
  )
}

// One assertion at counters `stored` and `reported`: accepted exactly when the
// rule accepts the pair, and refused for the counter and nothing else.
fn counter_follows_rule(
  private: ec.PrivateKey,
  der: BitArray,
  stored: Int,
  reported: Int,
) -> Nil {
  let outcome =
    passkey.verify_assertion(
      expected(),
      passkey.Stored(public_key: der, sign_count: stored),
      assertion(
        private,
        authenticator_data(rp_id, verified_present, reported),
        good_client(),
      ),
    )

  case stored == 0 && reported == 0 || reported > stored {
    True -> {
      assert outcome == Ok(reported)
      Nil
    }
    False -> {
      assert outcome == Error(passkey.CounterNotIncreased)
      Nil
    }
  }
}

/// Seeded by `mutation_seed`: changing any one bit of the signature makes a
/// good assertion refused.
pub fn no_single_bit_change_of_a_signature_verifies_test() {
  let #(private, der) = pair()
  let signed =
    assertion(
      private,
      authenticator_data(rp_id, verified_present, 7),
      good_client(),
    )
  let stored = passkey.Stored(public_key: der, sign_count: 0)
  assert result.is_ok(passkey.verify_assertion(expected(), stored, signed))

  let signature_bits = bit_array.byte_size(signed.signature) * 8
  qcheck.run(
    counter_config(mutation_seed),
    qcheck.bounded_int(from: 0, to: signature_bits - 1),
    fn(bit) {
      let changed =
        passkey.Assertion(..signed, signature: flip(signed.signature, bit))
      assert result.is_error(passkey.verify_assertion(
        expected(),
        stored,
        changed,
      ))
      Nil
    },
  )
}

// The bytes with bit `index` flipped, counting from the first byte's top bit.
fn flip(bytes: BitArray, index: Int) -> BitArray {
  let before = index / 8
  let assert Ok(head) = bit_array.slice(bytes, 0, before) as "head is in range"
  let assert Ok(<<byte:8>>) = bit_array.slice(bytes, before, 1)
    as "the byte is in range"
  let tail_from = before + 1
  let assert Ok(tail) =
    bit_array.slice(bytes, tail_from, bit_array.byte_size(bytes) - tail_from)
    as "the tail is in range"
  let mask = int.bitwise_shift_left(1, 7 - index % 8)
  <<head:bits, { int.bitwise_exclusive_or(byte, mask) }:8, tail:bits>>
}
