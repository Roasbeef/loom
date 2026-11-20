//// Real SQLite checks for the passkey table (protocol-change/127): what a
//// write refuses, what a read decodes, the per-principal bound, and that one
//// principal cannot remove another's passkey.

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import sqlight
import storage/access
import storage/catalogue
import support/fixtures

fn digest(char: String) {
  let assert Ok(value) = access.credential_digest(string.repeat(char, 64))
    as "fixture digest is valid lowercase SHA-256 hex"
  value
}

// An opened catalogue with the owner and one member.
fn fixture(name: String) {
  let file = fixtures.scratch("passkey-" <> name) <> "/catalogue.db"
  let assert Ok(store) = catalogue.open(file) as "catalogue opens"
  let assert Ok(owner) =
    access.bootstrap_owner(store, "owner", "Owner", digest("a"))
    as "the owner exists"
  let assert Ok(alice) =
    access.create_member(store, "alice", "Alice", digest("b"))
    as "a member exists"
  #(file, store, owner, alice)
}

// A fixture credential id: twenty-two base64url characters of one letter.
fn id(char: String) -> String {
  string.repeat(char, 22)
}

// A fixture key of the size a P-256 key in SubjectPublicKeyInfo DER has. The
// storage layer judges the size and not the curve, which the daemon checks.
fn key(byte: Int) -> BitArray {
  list.repeat(byte, 91)
  |> list.fold(<<>>, fn(bits, value) { <<bits:bits, value>> })
}

pub fn a_passkey_is_stored_read_back_and_counted_test() {
  let #(_file, store, owner, _alice) = fixture("roundtrip")
  assert access.passkeys(store, owner.id) == Ok([])
  assert access.add_passkey(
      store,
      owner.id,
      id("A"),
      key(7),
      0,
      "  Phone ",
      100,
    )
    == Ok(Nil)

  // The row reads back as written, with the label trimmed and no use recorded.
  assert access.passkey(store, id("A"))
    == Ok(access.Passkey(
      credential_id: id("A"),
      principal_id: owner.id,
      public_key: key(7),
      sign_count: 0,
      label: "Phone",
      created_at_ms: 100,
      last_used_ms: None,
    ))

  // A use moves the counter and the instant, and nothing else.
  assert access.passkey_used(store, id("A"), 5, 900) == Ok(Nil)
  let assert Ok(used) = access.passkey(store, id("A")) as "the passkey exists"
  assert used.sign_count == 5
  assert used.last_used_ms == Some(900)
  assert used.label == "Phone"
  assert access.passkey_used(store, id("B"), 5, 900) == Error(catalogue.Missing)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_passkey_write_that_is_wrong_writes_nothing_test() {
  let #(_file, store, owner, _alice) = fixture("refusals")
  let add = fn(principal, credential, public, count, label) {
    access.add_passkey(store, principal, credential, public, count, label, 100)
  }

  // A duplicate id, an unknown principal, a short key, a malformed id, a bad
  // counter and bad labels are each refused.
  assert add(owner.id, id("A"), key(1), 0, "One") == Ok(Nil)
  assert add(owner.id, id("A"), key(2), 0, "Two") == Error(catalogue.Conflict)
  assert add("nobody", id("B"), key(1), 0, "Two") == Error(catalogue.Missing)
  assert add(owner.id, id("B"), <<1, 2, 3>>, 0, "Two")
    == Error(catalogue.Invalid("a passkey public key is a 91-byte P-256 key"))
  assert add(owner.id, "short", key(1), 0, "Two")
    == Error(catalogue.Invalid("a credential id is 16-512 base64url characters"))
  assert add(owner.id, id("B"), key(1), -1, "Two")
    == Error(catalogue.Invalid(
      "a signature counter is an unsigned 32-bit integer",
    ))
  assert result.is_error(add(owner.id, id("B"), key(1), 0, " "))
  assert result.is_error(add(
    owner.id,
    id("B"),
    key(1),
    0,
    string.repeat("x", 33),
  ))
  assert result.is_error(add(owner.id, id("B"), key(1), 0, "tab\there"))
  assert list.length(result.unwrap(access.passkeys(store, owner.id), [])) == 1
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_principal_holds_at_most_the_passkey_limit_test() {
  let #(_file, store, owner, _alice) = fixture("limit")
  let letters = ["A", "B", "C", "D", "E", "F", "G", "H"]
  assert list.length(letters) == access.passkey_limit
  list.each(letters, fn(letter) {
    assert access.add_passkey(
        store,
        owner.id,
        id(letter),
        key(1),
        0,
        "Key " <> letter,
        100,
      )
      == Ok(Nil)
  })
  assert result.is_error(access.add_passkey(
    store,
    owner.id,
    id("I"),
    key(1),
    0,
    "Ninth",
    100,
  ))

  // The listing is oldest first, then by credential id.
  let assert Ok(held) = access.passkeys(store, owner.id) as "the list reads"
  assert list.map(held, fn(row) { row.credential_id }) == list.map(letters, id)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_passkey_is_removed_only_by_its_own_principal_test() {
  let #(_file, store, owner, alice) = fixture("remove")
  assert access.add_passkey(store, owner.id, id("A"), key(1), 0, "One", 100)
    == Ok(Nil)
  let fingerprint = access.passkey_fingerprint(id("A"))
  assert string.length(fingerprint) == 16

  // Another principal naming the fingerprint, and a malformed one, remove
  // nothing.
  assert access.remove_passkey(store, alice.id, fingerprint)
    == Error(catalogue.Missing)
  assert result.is_error(access.remove_passkey(store, owner.id, "x"))
  assert result.is_ok(access.passkey(store, id("A")))
  assert access.remove_passkey(store, owner.id, fingerprint) == Ok(Nil)
  assert access.passkey(store, id("A")) == Error(catalogue.Missing)
  assert access.remove_passkey(store, owner.id, fingerprint)
    == Error(catalogue.Missing)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_passkey_row_that_does_not_decode_is_not_a_passkey_test() {
  let #(file, store, owner, _alice) = fixture("corrupt")
  assert catalogue.close(store) == Ok(Nil)

  // A label with a control character, which the table's CHECK allows and the
  // decoder refuses, written behind the module's back.
  let assert Ok(connection) = sqlight.open(file) as "the file opens"
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO access_passkeys(credential_id, principal_id, public_key, sign_count, label, created_at_ms) VALUES ('"
        <> id("A")
        <> "', '"
        <> owner.id
        <> "', '"
        <> string.repeat("A", 122)
        <> "', 0, 'a' || char(9) || 'b', 1)",
      on: connection,
    )
    as "the row is written"
  let assert Ok(Nil) = sqlight.close(connection) as "the file closes"
  let assert Ok(store) = catalogue.open(file) as "the catalogue reopens"
  assert result.is_error(access.passkey(store, id("A")))
  assert result.is_error(access.passkeys(store, owner.id))
  assert catalogue.close(store) == Ok(Nil)
}
