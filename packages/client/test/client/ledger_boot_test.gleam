//// Starting the ledger process from a daemon's `[distribution]` table
//// (protocol-change/086): what a daemon with a ledger file, a `ca` file and a
//// real authority key does, and each way the files can disagree. The ledger is
//// signed with a real ECDSA key, since the point is that the verifier the
//// daemon builds from the `ca` file accepts what the authority signed.

import client/distribution
import client/internal/ffi_pki
import client/ledger_boot
import client/ledger_service
import client/membership_entry.{Genesis, Upsert}
import client/membership_signing
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import support/membership_fixture as fixture
import support/remote_fixtures
import telemetry/log

// A log of genesis and two members, signed by `key`, whose genesis names
// `named`'s certificate as the authority.
fn signed_log(key: String, named: String) -> List(BitArray) {
  let assert Ok(sign) = membership_signing.signer(key)
  let assert Ok(authority_pin) = membership_signing.authority_pin(named)
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

fn text_of(lines: List(BitArray)) -> String {
  string.concat(
    list.map(lines, fn(line) {
      let assert Ok(text) = bit_array.to_string(line)
      text <> "\n"
    }),
  )
}

// A directory holding the authority's certificate as `ca.pem` and a ledger
// signed by it.
fn files(label: String, lines: List(BitArray), certificate: String) {
  let directory = remote_fixtures.scratch(label)
  let assert Ok(Nil) = simplifile.write(directory <> "/ca.pem", certificate)
  let assert Ok(Nil) =
    simplifile.write(directory <> "/ledger.log", text_of(lines))
  directory
}

pub fn a_table_without_a_ledger_starts_nothing_test() {
  let text =
    "[distribution]\nnode = \"a@10.0.0.1\"\nca = \"/c/ca.pem\"\n"
    <> "certificate = \"/c/cert.pem\"\nkey = \"/c/key.pem\"\n"
    <> "cookie = \"/c/cookie\"\n[[distribution.peers]]\nnode = \"b@10.0.0.2\"\n"
    <> "sha256 = \""
    <> string.repeat("00", 32)
    <> "\"\n"
  let assert Ok(Some(config)) = distribution.parse(text)
  assert ledger_boot.start(config, log.discard()) == Ok(None)
}

pub fn a_ledger_signed_by_the_ca_starts_the_process_test() {
  let #(certificate, key) = ffi_pki.authority("boot authority")
  let directory = files("boot-ok", signed_log(key, certificate), certificate)
  let assert Ok(Some(service)) =
    ledger_boot.start_at(
      directory <> "/ledger.log",
      directory <> "/ca.pem",
      log.discard(),
    )
  let assert Ok(head) = ledger_service.head(service, 5000)
  assert head.seq == 2

  // The fixed name is registered, which is what a peer addresses.
  assert process.named(ledger_service.default_name())
    == Ok(ledger_service.pid(service))

  // The test is the process that linked it, and a normal exit does not take
  // a linked process with it.
  process.unlink(ledger_service.pid(service))
  process.kill(ledger_service.pid(service))
}

pub fn a_ledger_signed_by_another_authority_is_refused_with_its_line_test() {
  let #(certificate, _) = ffi_pki.authority("boot authority")
  let #(other_certificate, other_key) = ffi_pki.authority("another authority")
  let directory =
    files("boot-other", signed_log(other_key, other_certificate), certificate)
  let assert Error(reason) =
    ledger_boot.start_at(
      directory <> "/ledger.log",
      directory <> "/ca.pem",
      log.discard(),
    )
  assert string.contains(reason, "not a valid ledger: line 1")
  assert string.contains(reason, "bad_signature")
}

pub fn a_ledger_that_names_another_certificate_is_refused_test() {
  // Signed by the right key, but the genesis names a different certificate:
  // the file belongs to some other deployment's authority.
  let #(certificate, key) = ffi_pki.authority("boot authority")
  let #(other_certificate, _) = ffi_pki.authority("another authority")
  let directory =
    files("boot-named", signed_log(key, other_certificate), certificate)
  let assert Error(reason) =
    ledger_boot.start_at(
      directory <> "/ledger.log",
      directory <> "/ca.pem",
      log.discard(),
    )
  assert string.contains(reason, "other than the certificate")
}

pub fn a_missing_file_or_ca_is_an_operator_sentence_test() {
  let #(certificate, key) = ffi_pki.authority("boot authority")
  let directory =
    files("boot-missing", signed_log(key, certificate), certificate)
  let assert Error(reason) =
    ledger_boot.start_at(
      directory <> "/absent.log",
      directory <> "/ca.pem",
      log.discard(),
    )
  assert string.contains(reason, "distribution.ledger")
  assert string.contains(reason, "could not be read")

  let assert Error(reason) =
    ledger_boot.start_at(
      directory <> "/ledger.log",
      directory <> "/absent.pem",
      log.discard(),
    )
  assert string.contains(reason, "distribution.ca could not be read")

  let assert Ok(Nil) = simplifile.write(directory <> "/ca.pem", "not a pem")
  let assert Error(reason) =
    ledger_boot.start_at(
      directory <> "/ledger.log",
      directory <> "/ca.pem",
      log.discard(),
    )
  assert string.contains(reason, "does not hold a certificate")
}
