//// Custody of the authority key: the sealed envelope, the directory it lives
//// in, and the signer it hands back.
////
//// The passphrase that opens a key is the secret, and the file is attacked
//// offline, so these tests are about what a file with a wrong passphrase or a
//// changed byte does, what a reader accepts as an envelope at all, and what
//// permissions the directory and the files get.

import client/authority_key.{
  AlreadyKept, FieldInvalid, KeysNotExact, NotAnEnvelope, NotAnObject,
  PassphraseTooLong, PassphraseTooShort, Rejected, UnsupportedFormat,
  WrongDeployment,
}
import client/internal/ffi_os
import client/internal/ffi_pki
import client/membership_entry.{Authentic, Forged}
import client/membership_signing
import gleam/int
import gleam/result
import gleam/string
import host/bootstrap
import simplifile

const deployment = "3f9c0a7be1d24c58a6f01b92c4d7e833"

const other_deployment = "0000000000000000000000000000ffff"

fn scratch(label: String) -> String {
  let directory =
    "build/authority-key-"
    <> label
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let assert Ok(absolute) = bootstrap.absolute_path(directory)
  absolute
}

fn discard(directory: String) {
  let assert Ok(Nil) = simplifile.delete(directory)
  Nil
}

fn secret(text: String) -> authority_key.Passphrase {
  let assert Ok(passphrase) = authority_key.passphrase(text)
  passphrase
}

fn mode_of(path: String) -> Int {
  let assert Ok(info) = simplifile.file_info(path)
  int.bitwise_and(info.mode, 0o777)
}

// Changes the first character of one binary field of an envelope to another
// character of the alphabet, so the text stays a canonical encoding of the
// same number of bytes and only the value moves.
fn tamper(text: String, key: String) -> String {
  let marker = "\"" <> key <> "\":\""
  let assert [before, after] = string.split(text, marker)
    as "The key appears once."
  let assert Ok(#(first, rest)) = string.pop_grapheme(after)
  let changed = case first {
    "A" -> "B"
    _ -> "A"
  }
  before <> marker <> changed <> rest
}

pub fn a_sealed_key_opens_with_its_passphrase_test() {
  let #(_, key) = ffi_pki.authority("custody test authority")
  let text =
    authority_key.seal(key, secret("correct horse battery"), deployment)
  assert authority_key.open(text, secret("correct horse battery"), deployment)
    == Ok(key)
  assert string.starts_with(
    text,
    "{\"format\":\"loom-authority-key/1\",\"deployment\":\"" <> deployment,
  )
  assert !string.contains(text, "PRIVATE KEY")
}

pub fn two_seals_of_one_key_differ_test() {
  let #(_, key) = ffi_pki.authority("custody test authority")
  let passphrase = secret("correct horse battery")
  assert authority_key.seal(key, passphrase, deployment)
    != authority_key.seal(key, passphrase, deployment)
}

pub fn a_wrong_passphrase_is_refused_test() {
  let #(_, key) = ffi_pki.authority("custody test authority")
  let text =
    authority_key.seal(key, secret("correct horse battery"), deployment)
  assert authority_key.open(text, secret("correct horse batterz"), deployment)
    == Error(Rejected)
}

pub fn a_changed_field_is_refused_test() {
  let #(_, key) = ffi_pki.authority("custody test authority")
  let passphrase = secret("correct horse battery")
  let text = authority_key.seal(key, passphrase, deployment)
  assert authority_key.open(tamper(text, "ciphertext"), passphrase, deployment)
    == Error(Rejected)
  assert authority_key.open(tamper(text, "salt"), passphrase, deployment)
    == Error(Rejected)
  assert authority_key.open(tamper(text, "nonce"), passphrase, deployment)
    == Error(Rejected)
  assert authority_key.open(tamper(text, "tag"), passphrase, deployment)
    == Error(Rejected)
}

// The deployment id is authenticated with the ciphertext, so a file edited to
// claim another id fails to open under that id, and a file for another
// deployment is named as such.
pub fn the_deployment_is_bound_to_the_key_test() {
  let #(_, key) = ffi_pki.authority("custody test authority")
  let passphrase = secret("correct horse battery")
  let text = authority_key.seal(key, passphrase, deployment)
  assert authority_key.open(text, passphrase, other_deployment)
    == Error(WrongDeployment)
  let edited = string.replace(text, deployment, other_deployment)
  assert authority_key.open(edited, passphrase, other_deployment)
    == Error(Rejected)
}

pub fn an_envelope_has_exactly_the_keys_of_its_format_test() {
  let #(_, key) = ffi_pki.authority("custody test authority")
  let passphrase = secret("correct horse battery")
  let text = authority_key.seal(key, passphrase, deployment)
  let refused = fn(text, expected) {
    assert authority_key.open(text, passphrase, deployment) == Error(expected)
  }
  refused("not json", NotAnEnvelope(NotAnObject))
  refused("[]", NotAnEnvelope(NotAnObject))
  refused(
    string.replace(text, "loom-authority-key/1", "loom-authority-key/2"),
    UnsupportedFormat,
  )
  refused(
    string.replace(text, "\"tag\":", "\"extra\":1,\"tag\":"),
    NotAnEnvelope(KeysNotExact),
  )
  refused(
    string.replace(text, "\"nonce\":", "\"other\":"),
    NotAnEnvelope(KeysNotExact),
  )
}

pub fn an_envelope_with_a_weak_or_malformed_field_is_refused_test() {
  let #(_, key) = ffi_pki.authority("custody test authority")
  let passphrase = secret("correct horse battery")
  let text = authority_key.seal(key, passphrase, deployment)
  let refused = fn(text, key) {
    assert authority_key.open(text, passphrase, deployment)
      == Error(NotAnEnvelope(FieldInvalid(key)))
  }

  // The count is what slows a guessing attack, so a file that lowers it is
  // refused without being tried.
  refused(
    string.replace(text, "\"iterations\":600000", "\"iterations\":1000"),
    "iterations",
  )
  refused(
    string.replace(text, "\"iterations\":600000", "\"iterations\":99999999"),
    "iterations",
  )
  refused(
    string.replace(text, "\"iterations\":600000", "\"iterations\":\"many\""),
    "iterations",
  )

  // Lengths, padding and non-canonical encodings of the binary fields.
  refused(string.replace(text, "\"salt\":\"", "\"salt\":\"AA"), "salt")
  refused(string.replace(text, "\"nonce\":\"", "\"nonce\":\"A"), "nonce")
  refused(string.replace(text, "\"tag\":\"", "\"tag\":\"AA"), "tag")
  refused(
    string.replace(text, "\"ciphertext\":\"", "\"ciphertext\":\"=="),
    "ciphertext",
  )
  refused(
    string.replace(
      text,
      "\"deployment\":\"" <> deployment,
      "\"deployment\":\"XY",
    ),
    "deployment",
  )
}

pub fn a_passphrase_has_a_length_test() {
  assert authority_key.passphrase("short") == Error(PassphraseTooShort)
  assert authority_key.passphrase(string.repeat("a", 1025))
    == Error(PassphraseTooLong)
  assert result.is_ok(authority_key.passphrase(string.repeat("a", 12)))
  assert result.is_ok(authority_key.passphrase(string.repeat("a", 1024)))
}

pub fn a_passphrase_file_must_be_private_test() {
  let base = scratch("passphrase")
  let path = base <> "/passphrase"
  let assert Ok(Nil) = simplifile.write(path, "correct horse battery\n")

  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o644)
  let assert Error(authority_key.Io(_, _)) =
    authority_key.passphrase_from_file(path)

  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o600)
  let assert Ok(passphrase) = authority_key.passphrase_from_file(path)
  let #(_, key) = ffi_pki.authority("custody test authority")

  // One trailing newline is not part of the passphrase.
  let text =
    authority_key.seal(key, secret("correct horse battery"), deployment)
  assert authority_key.open(text, passphrase, deployment) == Ok(key)

  // A passphrase that is too short is refused whatever it was read from.
  let assert Ok(Nil) = simplifile.write(path, "short\n")
  assert authority_key.passphrase_from_file(path) == Error(PassphraseTooShort)
  discard(base)
}

pub fn a_kept_key_is_private_and_never_replaced_test() {
  let base = scratch("keep")
  let directory = authority_key.default_directory(base, deployment)
  assert directory == base <> "/.loom/authority/" <> deployment
  let #(certificate, key) = ffi_pki.authority("custody test authority")
  let passphrase = secret("correct horse battery")
  let kept =
    authority_key.Kept(
      deployment:,
      key:,
      certificate:,
      ledger: "line one\nline two\n",
      cookie: "a-cookie-of-sixteen-characters",
    )

  let assert Ok(path) = authority_key.keep(directory, kept, passphrase)
  assert path == directory <> "/key.enc"
  assert authority_key.is_kept(directory)
  assert mode_of(directory) == 0o700
  assert mode_of(path) == 0o600
  assert mode_of(directory <> "/ca.pem") == 0o600
  assert mode_of(directory <> "/ledger.log") == 0o600
  assert simplifile.read(directory <> "/ca.pem") == Ok(certificate)
  assert simplifile.read(directory <> "/ledger.log")
    == Ok("line one\nline two\n")
  assert mode_of(directory <> "/cookie") == 0o600
  assert authority_key.cookie(directory) == Ok("a-cookie-of-sixteen-characters")

  // A second keep, even with the same key and passphrase, writes nothing.
  let before = simplifile.read(path)
  assert authority_key.keep(directory, kept, passphrase)
    == Error(AlreadyKept(path))
  assert simplifile.read(path) == before
  assert authority_key.load(directory, deployment, passphrase) == Ok(key)
  discard(base)
}

pub fn a_key_file_that_others_can_read_is_not_opened_test() {
  let base = scratch("readable")
  let directory = authority_key.default_directory(base, deployment)
  let #(certificate, key) = ffi_pki.authority("custody test authority")
  let passphrase = secret("correct horse battery")
  let assert Ok(path) =
    authority_key.keep(
      directory,
      authority_key.Kept(
        deployment:,
        key:,
        certificate:,
        ledger: "",
        cookie: "c",
      ),
      passphrase,
    )
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o640)
  let assert Error(authority_key.Io(_, _)) =
    authority_key.load(directory, deployment, passphrase)
  discard(base)
}

// The seam: a directory and a passphrase become a `Signer`, and what it signs
// verifies under the authority certificate, which is the only thing a node
// holds.
pub fn the_signer_signs_for_the_authority_certificate_test() {
  let base = scratch("signer")
  let directory = authority_key.default_directory(base, deployment)
  let #(certificate, key) = ffi_pki.authority("custody test authority")
  let passphrase = secret("correct horse battery")
  let assert Ok(_) =
    authority_key.keep(
      directory,
      authority_key.Kept(
        deployment:,
        key:,
        certificate:,
        ledger: "",
        cookie: "c",
      ),
      passphrase,
    )

  let assert Ok(sign) = authority_key.signer(directory, deployment, passphrase)
  let assert Ok(signature) = sign(<<"message":utf8>>)
  let assert Ok(verify) = membership_signing.verifier(certificate)
  assert verify(<<"message":utf8>>, signature) == Authentic
  assert verify(<<"other":utf8>>, signature) == Forged

  assert authority_key.signer(directory, deployment, secret("wrong passphrase"))
    |> result.is_error
  discard(base)
}

pub fn a_sealed_value_that_is_not_a_key_cannot_sign_test() {
  let base = scratch("notakey")
  let directory = authority_key.default_directory(base, deployment)
  let passphrase = secret("correct horse battery")
  let assert Ok(_) =
    authority_key.keep(
      directory,
      authority_key.Kept(
        deployment:,
        key: "not a key",
        certificate: "",
        ledger: "",
        cookie: "",
      ),
      passphrase,
    )
  assert authority_key.signer(directory, deployment, passphrase)
    |> result.map(fn(_) { Nil })
    == Error(authority_key.NotASigningKey)
  discard(base)
}
