//// The membership ledger under the real authority key: a certificate and key
//// minted by `ffi_pki`, ECDSA signatures from OTP, and the ledger rules
//// applied to lines they sign. The rules themselves are tested with a fake
//// scheme in `membership_ledger_test`; this file shows the real scheme meets
//// the same interface.

import client/internal/ffi_pki
import client/membership_entry.{Authentic, BadSignature, Forged, Genesis, Upsert}
import client/membership_ledger
import client/membership_signing
import gleam/bit_array
import gleam/list
import support/membership_fixture as fixture

fn authority() -> #(String, String) {
  ffi_pki.authority("membership test authority")
}

// A log of a few entries signed by the authority, as lines.
fn signed_log(certificate: String, key: String) -> List(BitArray) {
  let assert Ok(sign) = membership_signing.signer(key)
  let assert Ok(authority_pin) = membership_signing.authority_pin(certificate)
  let first =
    fixture.entry(
      0,
      membership_entry.genesis_prev(),
      Genesis(deployment: fixture.deployment, authority: authority_pin),
    )
  let assert Ok(genesis) = membership_entry.seal(first, sign)
  let hub = fixture.entry(1, genesis.id, Upsert(fixture.member("hub", [])))
  let assert Ok(hub) = membership_entry.seal(hub, sign)
  let laptop =
    fixture.entry(2, hub.id, Upsert(fixture.member("laptop", ["hub"])))
  let assert Ok(laptop) = membership_entry.seal(laptop, sign)
  list.map([genesis, hub, laptop], membership_entry.line)
}

pub fn a_log_signed_by_the_authority_replays_test() {
  let #(certificate, key) = authority()
  let lines = signed_log(certificate, key)
  let assert Ok(verify) = membership_signing.verifier(certificate)
  let assert Ok(ledger) = membership_ledger.replay(lines, verify)
  assert membership_ledger.head(ledger).seq == 2
  assert list.map(membership_ledger.members(ledger), fn(member) { member.name })
    == ["hub", "laptop"]
  let assert Ok(pin) = membership_signing.authority_pin(certificate)
  assert membership_ledger.authority(ledger) == pin
}

pub fn a_signature_fits_the_wire_bound_test() {
  let #(_, key) = authority()
  let assert Ok(sign) = membership_signing.signer(key)
  list.each(list.repeat(Nil, 50), fn(_) {
    let assert Ok(signature) = sign(<<"x":utf8>>)
    assert bit_array.byte_size(signature)
      <= membership_entry.max_signature_bytes
  })
}

pub fn another_authority_is_a_forgery_test() {
  let #(certificate, key) = authority()
  let #(other_certificate, _) = authority()
  let lines = signed_log(certificate, key)
  let assert Ok(verify) = membership_signing.verifier(other_certificate)
  let assert [genesis, ..] = lines
  assert membership_ledger.begin(genesis, verify)
    == Error(membership_ledger.Unreadable(BadSignature))
}

pub fn a_flipped_signature_is_a_forgery_test() {
  let #(certificate, key) = authority()
  let assert Ok(sign) = membership_signing.signer(key)
  let assert Ok(verify) = membership_signing.verifier(certificate)
  let message = membership_entry.signing_input(<<"body":utf8>>)
  let assert Ok(signature) = sign(message)
  assert verify(message, signature) == Authentic

  let assert <<first, rest:bytes>> = signature
  assert verify(message, <<{ first + 1 }, rest:bits>>) == Forged
  assert verify(message, <<>>) == Forged
  assert verify(<<"other":utf8>>, signature) == Forged
}

pub fn a_signature_without_the_domain_prefix_is_a_forgery_test() {
  let #(certificate, key) = authority()
  let assert Ok(sign) = membership_signing.signer(key)
  let assert Ok(verify) = membership_signing.verifier(certificate)
  let assert Ok(bare) = sign(<<"body":utf8>>)
  assert verify(membership_entry.signing_input(<<"body":utf8>>), bare) == Forged
}

pub fn a_key_or_certificate_that_does_not_parse_is_refused_early_test() {
  assert membership_signing.signer("not a key") == Error(Nil)
  assert result_is_error(membership_signing.verifier("not a certificate"))
  assert membership_signing.authority_pin("not a certificate") == Error(Nil)
}

fn result_is_error(result: Result(a, Nil)) -> Bool {
  case result {
    Ok(_) -> False
    Error(Nil) -> True
  }
}

pub fn a_certificate_is_not_a_signing_key_test() {
  let #(certificate, _) = authority()
  assert membership_signing.signer(certificate) == Error(Nil)
}

pub fn flipping_a_bit_of_a_signed_line_is_refused_test() {
  let #(certificate, key) = authority()
  let lines = signed_log(certificate, key)
  let assert Ok(verify) = membership_signing.verifier(certificate)
  let assert [genesis, hub, ..] = lines
  let assert Ok(ledger) = membership_ledger.begin(genesis, verify)

  let assert <<first, rest:bytes>> = hub
  let flipped = <<{ first + 1 }, rest:bits>>
  let assert Error(_) = membership_ledger.accept(ledger, flipped, verify)
}
